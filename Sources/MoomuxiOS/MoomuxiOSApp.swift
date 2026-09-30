import BackgroundTasks
import MoomuxKit
import SwiftUI

/// The iPhone front end.
///
/// Same one-way flow as the Mac app — `moomux serve` → `MoomuxClient` →
/// `AppState` → views — with two differences forced by the platform. The
/// transport is TCP across a tailnet rather than a unix socket, and there is
/// no `.exec` terminal: attaching waits on the core's `Attach` stream, which
/// does not exist yet. Everything the wire already serves works today.
@main
struct MoomuxiOSApp: App {
    @State private var endpoint = EndpointStore()
    @State private var app: AppState?
    /// The release notes to show at launch; see `WhatsNew.takeUnseen`.
    @State private var unseenNotes: [WhatsNew.Release]?
    @Environment(\.scenePhase) private var scenePhase

    /// In `init`, not a view's `.task`: `BGTaskScheduler` refuses a
    /// registration made after launch finishes, and a late one fails silently
    /// — refresh then never runs, which looks exactly like iOS throttling it.
    init() {
        BackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let app {
                    SessionListView(app: app, endpoint: endpoint, disconnect: { self.app = nil })
                } else {
                    ConnectView(endpoint: endpoint, connect: connect)
                }
            }
            .task {
                if endpoint.remembered { connect() }
                let unseen = WhatsNew.takeUnseen()
                if unseen.show { unseenNotes = WhatsNew.releases(after: unseen.seen) }
            }
            .sheet(isPresented: Binding(get: { unseenNotes != nil }, set: { if !$0 { unseenNotes = nil } })) {
                WhatsNewSheet(releases: unseenNotes ?? [])
            }
        }
        .onChange(of: scenePhase) { old, phase in
            // iOS only honours a refresh request from an app on its way out.
            if phase == .background { BackgroundRefresh.schedule() }
            // Leaving the background, not merely a pulled-down Notification
            // Centre (`active` → `inactive` → `active`): the stream may be
            // dead without knowing it yet. See `AppState.resume`. On the way
            // out rather than on reaching `active`, which a system alert over
            // the app — the notification prompt, a permission sheet — can
            // hold off indefinitely.
            if old == .background, phase != .background { app?.resume() }
        }
    }

    private func connect() {
        let state = AppState(client: MoomuxClient(endpoint: endpoint.resolved))
        state.start()
        app = state
        BackgroundRefresh.app = state
    }
}

// MARK: - Background refresh

/// Banners and the badge while the phone is in a pocket.
///
/// iOS suspends the app and holds no connection for it, so the `Watch` stream
/// stops and nothing notices a session starting to wait. A `BGAppRefreshTask`
/// wakes the app now and then — at the system's discretion, never sooner than
/// the 15 minutes asked for and often much later — and `AppState.pollOnce`
/// takes one snapshot through the same path the stream uses.
///
/// Ceiling: this is polling, not push. A banner can be late by however long
/// iOS waits, and the badge is as fresh as the last refresh it granted. Real
/// delivery means APNs and a relay, which is out of scope (docs/macos-vs-ios.md D5).
enum BackgroundRefresh {
    static let identifier = "app.moomux.Moomux.refresh"

    /// The connected store, if the app was suspended with one — the usual
    /// case, and the one that can tell a new wait from an old one. nil after
    /// a cold background launch, where a throwaway store only sets the badge.
    @MainActor static weak var app: AppState?

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            // Rescheduled first, so a refresh that fails or is cut off cannot
            // end the chain.
            schedule()
            let work = Task { @MainActor in
                let store = app ?? cold()
                let ok = (try? await store?.pollOnce()) != nil
                task.setTaskCompleted(success: ok)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor private static func cold() -> AppState? {
        let endpoint = EndpointStore()
        guard endpoint.remembered else { return nil }
        return AppState(client: MoomuxClient(endpoint: endpoint.resolved))
    }
}

// MARK: - Where the core is

/// Host and port, in `UserDefaults`.
///
/// Not in the Keychain: a tailnet address is not a secret, and there is no
/// token to store — the core authorizes by asking Tailscale who the peer is,
/// so the phone proves itself by being on the tailnet at all.
@Observable
final class EndpointStore {
    var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "coreHost") }
    }
    var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: "corePort") }
    }

    /// `ipc.TailnetPort`. The core's tailnet listener is on a fixed port, so
    /// this is a default rather than something anyone should have to know —
    /// the field stays editable only for a bridge or a second core.
    static let defaultPort = MoomuxClient.tailnetPort

    init() {
        host = UserDefaults.standard.string(forKey: "coreHost") ?? ""
        // `integer(forKey:)`, not `object(forKey:) as? Int`: a value from the
        // launch-argument domain (`-corePort 8765`, how the screenshot seam
        // sets it) arrives as a string, so the cast fails and silently takes
        // the default — which looks exactly like the core being unreachable.
        // 0 means unset, since no port is 0.
        let stored = UserDefaults.standard.integer(forKey: "corePort")
        port = stored > 0 ? stored : EndpointStore.defaultPort
    }

    /// The port too, not just the host: `UInt16(clamping:)` below turns a
    /// mistyped 458760 into 65535 and connects *there*, so the only symptom
    /// of a fat-fingered field is "cannot connect" pointing at the wrong
    /// thing. Refusing it keeps Connect disabled instead.
    var remembered: Bool { !host.trimmed.isEmpty && (1...65535).contains(port) }

    var resolved: MoomuxClient.Endpoint {
        .tcp(host: host.trimmed, port: UInt16(clamping: port))
    }
}

struct ConnectView: View {
    @Bindable var endpoint: EndpointStore
    let connect: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("100.71.5.0 or a MagicDNS name", text: $endpoint.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", value: $endpoint.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                } header: {
                    Text("Core")
                } footer: {
                    Text("The machine running `moomux serve` with `tailnet_listen = true`, "
                         + "reached over your tailnet. Nothing is stored but the address — the "
                         + "core authorizes by asking Tailscale who you are.")
                }

                Button("Connect", action: connect)
                    .disabled(!endpoint.remembered)
            }
            .navigationTitle("Moomux")
        }
    }
}
