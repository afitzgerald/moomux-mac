import AppKit
import UserNotifications

/// Banners for sessions that start waiting on you while you are elsewhere.
///
/// The whole UserNotifications surface lives here, the way SwiftTerm lives in
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
        for id in change.started {
            guard let session = app.session(id: id), !session.archived else { continue }
            // A banner for the window you are already looking at is noise.
            if NSApp.isActive, app.selectedSessionID == session.id { continue }
            post(session, to: center)
        }
    }

    private func post(_ session: Session, to center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = "\(session.project) · \(session.name)"
        content.body = "needs input"
        content.sound = .default
        if let art = Notifier.bannerArtwork() { content.attachments = [art] }
        // Identifier = session id: a re-post replaces rather than stacks, and
        // it is how a tap finds its way back to a session.
        let request = UNNotificationRequest(identifier: session.id, content: content, trigger: nil)
        // No authorization check here: `add` returns no error while denied, so
        // there is nothing to learn from asking. `init` did the asking.
        Task { try? await center.add(request) }
    }

    /// The app mark, as the banner's thumbnail. Without an attachment macOS
    /// draws only the small app icon; the plate is the same artwork at a size
    /// worth looking at.
    ///
    /// A fresh temp copy per banner because the system *moves* an attachment's
    /// file into its own store — handing it the bundle's copy would delete the
    /// resource, and handing it one temp path twice works exactly once.
    private static func bannerArtwork() -> UNNotificationAttachment? {
        guard let src = Bundle.main.url(forResource: "PeekabooPlate", withExtension: "png")
        else { return nil }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("moomux-banner-\(UUID().uuidString).png")
        guard (try? FileManager.default.copyItem(at: src, to: tmp)) != nil else { return nil }
        guard let art = try? UNNotificationAttachment(identifier: "plate", url: tmp) else {
            try? FileManager.default.removeItem(at: tmp)
            return nil
        }
        return art
    }

    // MARK: Tapping a banner

    /// Come forward with that session selected. `NSApp.activate()` rather than
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
            NSApp.activate()
            NSApp.windows.first { $0.canBecomeKey }?.makeKeyAndOrderFront(nil)
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

    nonisolated static func demo() {
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
    }
}
