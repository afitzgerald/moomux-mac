#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import UserNotifications

/// Banners for sessions that start waiting on you while you are elsewhere.
///
/// The whole UserNotifications surface lives here, the way libghostty lives in
/// `UI/TerminalPane.swift`: `UNUserNotificationCenter.current()` **traps** in a
/// binary with no bundle identifier — `swift run`, and `--selftest`, which
/// `Scripts/selfcheck.sh` execs from `.build`. `center` is nil there and every
/// path is guarded on it, so nothing outside this file may reach the center.
@MainActor
public final class Notifier: NSObject, UNUserNotificationCenterDelegate {

    private weak var app: AppState?
    private let center: UNUserNotificationCenter?

    public init(app: AppState) {
        self.app = app
        center = Bundle.main.bundleIdentifier == nil ? nil : .current()
        super.init()
        // The phone has one delegate for every store (`TapRouter`): a store
        // per computer, and the last one made would otherwise take every tap.
        #if os(macOS)
        center?.delegate = self
        #endif
        // Asked once at startup rather than at the first banner. `.badge` is the
        // reason it cannot wait: macOS suppresses `NSDockTile.badgeLabel`
        // entirely for an app whose badge permission is off, and a session that
        // is *already* waiting when the app opens sets the badge without ever
        // being a transition, so no banner would ever have asked. After the
        // first answer the system returns it without prompting again.
        if let center {
            Task { _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge]) }
        }
    }

    /// The phone's answer to the Mac's dock tile. Driven by
    /// `AppState.updateDockBadge` and **not** from `report`, which only runs
    /// when the view map changed: `needsInputCount` filters `visibleSessions`,
    /// so archiving the one waiting session leaves the views identical and
    /// would strand the badge at 1. Needs the `.badge` authorization `init` asks for, same as the dock tile does.
    public func setBadge(_ count: Int) {
        Notifier.setBadge(count, for: app?.notificationKey ?? "")
    }

    /// Each computer's count, keyed by `AppState.notificationKey`; the icon
    /// shows their sum. Saved, so a relaunch on one computer does not drop
    /// the others' shares until background refresh gets to them. Ceiling: a
    /// share is as fresh as the last time that computer was polled.
    private static var badges = UserDefaults.standard.dictionary(forKey: badgesKey) as? [String: Int] ?? [:]
    private static let badgesKey = "badgeShares"

    public static func setBadge(_ count: Int, for key: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        badges[key] = count
        UserDefaults.standard.set(badges, forKey: badgesKey)
        let total = badges.values.reduce(0, +)
        Task { try? await UNUserNotificationCenter.current().setBadgeCount(total) }
    }

    /// A computer is gone: its share of the badge, and its banners, which a
    /// tap could no longer take anywhere. `""` is the banners posted before
    /// computers had keys.
    public static func forget(_ key: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        setBadge(0, for: key)
        badges[key] = nil
        UserDefaults.standard.set(badges, forKey: badgesKey)
        UNUserNotificationCenter.current().getDeliveredNotifications { delivered in
            let ids = delivered.map(\.request.identifier).filter { tapped($0).key == key }
            if !ids.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    /// A banner's identifier: the session id, behind its computer's key when
    /// the store has one, so the same session name on two computers is two
    /// banners and a tap knows which computer to switch to.
    nonisolated static func identifier(key: String, session: Session.ID) -> String {
        key.isEmpty ? session : "\(key)|\(session)"
    }

    /// `identifier` backwards. The key is a UUID, which has no `|`, so the
    /// first one is the split whatever the session id holds.
    public nonisolated static func tapped(_ identifier: String) -> (key: String, session: Session.ID) {
        guard let bar = identifier.firstIndex(of: "|") else { return ("", identifier) }
        return (String(identifier[..<bar]), String(identifier[identifier.index(after: bar)...]))
    }

    /// Post for every session that just *became* blocked; clear the banner for
    /// every one that stopped being.
    public func report(previous: [Session.ID: SessionView], current: [Session.ID: SessionView]) {
        guard let center, let app else { return }
        let change = Notifier.transitions(from: previous.mapValues(\.state),
                                          to: current.mapValues(\.state))
        // Guarded, not because an empty removal does anything, but because it
        // is an XPC round trip per watcher tick — tens a second, and every one
        // of them logged. Nothing to remove is the overwhelmingly common case.
        if !change.ended.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: change.ended.map {
                Notifier.identifier(key: app.notificationKey, session: $0)
            })
        }
        // A banner for the window you are already looking at is noise. On the
        // phone that is the pane on screen; every other session still banners
        // in the foreground (`willPresent` below).
        #if os(macOS)
        let focused = NSApp.isActive ? app.selectedSessionID : nil
        #else
        let focused = UIApplication.shared.applicationState == .active ? app.paneOnScreen : nil
        #endif
        for session in Notifier.bannered(change.started.compactMap(app.session(id:)), focused: focused) {
            post(session, to: center, app: app)
        }
    }

    /// Of the sessions that just started waiting, the ones worth a banner: not
    /// archived, and not the one in front of you. A session the store does not
    /// know is already gone from `started` by the caller's lookup.
    nonisolated static func bannered(_ started: [Session], focused: Session.ID?) -> [Session] {
        started.filter { !$0.archived && $0.id != focused }
    }

    private func post(_ session: Session, to center: UNUserNotificationCenter, app: AppState) {
        let content = UNMutableNotificationContent()
        // Session name first: macOS truncates a long title, and the project
        // prefix used to be all that survived.
        content.title = session.name
        content.subtitle = app.computerName.isEmpty ? session.project : "\(session.project) · \(app.computerName)"
        content.body = "needs input"
        content.sound = .default
        // Identifier = session id (and computer): a re-post replaces rather
        // than stacks, and it is how a tap finds its way back to a session.
        let request = UNNotificationRequest(identifier: Notifier.identifier(key: app.notificationKey, session: session.id),
                                            content: content, trigger: nil)
        // No authorization check here: `add` returns no error while denied, so
        // there is nothing to learn from asking. `init` did the asking.
        Task { try? await center.add(request) }
    }

    // MARK: Tapping a banner

    /// Come forward with that session selected. Mac only: the phone's taps
    /// go through `TapRouter`, which knows which computer one came from.
    /// `NSApp.activate()` rather than
    /// `activate(ignoringOtherApps:)`, which is deprecated at the 14.0
    /// deployment target and would cost a warning.
    #if os(macOS)
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler done: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        Task { @MainActor in
            app?.selectedSessionID = id
            NSApp.activate()
            NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
            done()
        }
    }
    #endif

    #if os(iOS)
    /// The phone's notification delegate, for the life of the app: installed
    /// in the app's `init`, because iOS wants one before launch finishes and
    /// a tap that cold-launches the app arrives before any store exists.
    public static func listenForTaps() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = TapRouter.shared
    }

    /// Where taps go, banner identifier and all (see `tapped`). One that
    /// landed before this was set is handed over now.
    public static func onTap(_ sink: @escaping (String) -> Void) {
        TapRouter.shared.sink = sink
        if let id = TapRouter.shared.pending {
            TapRouter.shared.pending = nil
            sink(id)
        }
    }
    #endif

    // MARK: The pure half

    /// The transitions worth acting on: sessions that just entered
    /// needs-input, and sessions that just left it.
    ///
    /// A session must already be in `old` for a start to count. That is both the
    /// dedup (sitting in needs-input is not a transition) and the launch guard:
    /// the first snapshot seeds rather than firing a banner for every session
    /// that was already waiting when the app opened — the menu-bar count is
    /// what says that.
    nonisolated static func transitions(
        from old: [String: AgentState], to new: [String: AgentState]
    ) -> (started: [String], ended: [String]) {
        var started: [String] = [], ended: [String] = []
        for (id, state) in new where old[id] != nil && old[id] != state {
            if state == .needsInput { started.append(id) }
            if old[id] == .needsInput { ended.append(id) }
        }
        return (started.sorted(), ended.sorted())  // sorted so demo() can assert
    }

    public nonisolated static func demo() {
        let a = "p:a", b = "p:b"
        // First sight of a session seeds; it never banners.
        assert(transitions(from: [:], to: [a: .needsInput]).started.isEmpty)
        // A real transition fires once, and sitting there does not re-fire.
        assert(transitions(from: [a: .working], to: [a: .needsInput]).started == [a])
        assert(transitions(from: [a: .needsInput], to: [a: .needsInput]).started.isEmpty)
        // Leaving needs-input clears the banner and is not itself one.
        let t = transitions(from: [a: .needsInput], to: [a: .working])
        assert(t.started.isEmpty && t.ended == [a], "\(t)")
        // Another session's churn is ignored.
        assert(transitions(from: [a: .working, b: .working],
                           to: [a: .working, b: .needsInput]).started == [b])
        // A session that is simply gone (deleted, or filtered out) is not a
        // transition either.
        let u = transitions(from: [a: .needsInput, b: .working], to: [b: .working])
        assert(u.started.isEmpty && u.ended.isEmpty, "\(u)")

        // Archived sessions and the focused one never banner; `focused` is nil
        // whenever the app is not in front, and then everything else does.
        func session(_ id: String, archived: Bool = false) -> Session {
            try! Wire.decoder.decode(Session.self, from: Data(
                #"{"id":"\#(id)","project":"p","name":"\#(id)","archived":\#(archived)}"#.utf8))
        }
        let started = [session(a), session(b), session("p:c", archived: true)]
        assert(bannered(started, focused: nil).map(\.id) == [a, b])
        assert(bannered(started, focused: a).map(\.id) == [b], "the session in front is not news")

        // A banner carries its computer, and a tap finds both halves again,
        // whatever the session id holds. No key (the Mac) is the bare id.
        let key = UUID().uuidString
        assert(identifier(key: "", session: a) == a)
        let tap = tapped(identifier(key: key, session: "p|x:y"))
        assert(tap.key == key && tap.session == "p|x:y", "\(tap)")
        assert(tapped(a) == ("", a))
    }
}

#if os(iOS)
/// The phone's only notification delegate. A tap goes to the app, which knows
/// which computer it came from; one that lands before the app is listening (a
/// cold launch) waits in `pending`. Every banner shows in the foreground too,
/// since that is most of the time the phone is watching at all; `report` has
/// already left out the session whose pane is on screen.
private final class TapRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = TapRouter()
    // Main actor only; the delegate callbacks hop there before touching them.
    @MainActor var pending: String?
    @MainActor var sink: ((String) -> Void)?

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler done: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        Task { @MainActor in
            if let sink { sink(id) } else { pending = id }
            done()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        done([.banner, .list, .sound])
    }
}
#endif
