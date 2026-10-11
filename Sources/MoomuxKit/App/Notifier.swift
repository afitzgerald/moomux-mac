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
        center?.delegate = self
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
        guard let center else { return }
        Task { try? await center.setBadgeCount(count) }
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
            center.removeDeliveredNotifications(withIdentifiers: change.ended)
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
            post(session, to: center)
        }
    }

    /// Of the sessions that just started waiting, the ones worth a banner: not
    /// archived, and not the one in front of you. A session the store does not
    /// know is already gone from `started` by the caller's lookup.
    nonisolated static func bannered(_ started: [Session], focused: Session.ID?) -> [Session] {
        started.filter { !$0.archived && $0.id != focused }
    }

    private func post(_ session: Session, to center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        // Session name first: macOS truncates a long title, and the project
        // prefix used to be all that survived.
        content.title = session.name
        content.subtitle = session.project
        content.body = "needs input"
        content.sound = .default
        // Identifier = session id: a re-post replaces rather than stacks, and
        // it is how a tap finds its way back to a session.
        let request = UNNotificationRequest(identifier: session.id, content: content, trigger: nil)
        // No authorization check here: `add` returns no error while denied, so
        // there is nothing to learn from asking. `init` did the asking.
        Task { try? await center.add(request) }
    }

    // MARK: Foreground banners

    #if os(iOS)
    /// Without this iOS drops every banner while the app is in front, and the
    /// foreground is most of the time the phone is watching at all. `report`
    /// has already left out the session whose pane is on screen. macOS keeps
    /// the system's default — a banner there is for when you are elsewhere.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        done([.banner, .list, .sound])
    }
    #endif

    // MARK: Tapping a banner

    /// Come forward with that session selected — which on iOS is what makes
    /// the list push that session's pane, since nothing there reads a
    /// selection except the observer `SessionListView` installs on it.
    /// `NSApp.activate()` rather than
    /// `activate(ignoringOtherApps:)`, which is deprecated at the 14.0
    /// deployment target and would cost a warning.
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler done: @escaping () -> Void
    ) {
        let id = response.notification.request.identifier
        Task { @MainActor in
            app?.selectedSessionID = id
            #if os(macOS)
            NSApp.activate()
            NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
            #endif
            // iOS brings the app forward itself when a banner is tapped; there
            // is no window to order front.
            done()
        }
    }

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
    }
}
