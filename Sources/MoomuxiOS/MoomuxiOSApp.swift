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
    /// A pairing link waiting on Connect or Cancel, or why one was refused.
    @State private var link: LinkPrompt?
    /// Until the launch `.task` has decided whether to reconnect. The Connect
    /// screen is drawn for that first frame even when a remembered core is
    /// about to replace it, and must not prompt for or start the camera.
    @State private var launching = true
    @Environment(\.scenePhase) private var scenePhase

    /// In `init`, not a view's `.task`: `BGTaskScheduler` refuses a
    /// registration made after launch finishes, and a late one fails silently
    /// — refresh then never runs, which looks exactly like iOS throttling it.
    init() {
        BackgroundRefresh.register()
        Notifier.listenForLaunchTap()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let app {
                    SessionListView(app: app, endpoint: endpoint, disconnect: { self.app = nil })
                        // A link swaps the store in one step, with no Connect
                        // screen in between to reset the list's navigation.
                        .id(ObjectIdentifier(app))
                } else {
                    // The camera stops while anything is up over it.
                    ConnectView(endpoint: endpoint, paused: launching || link != nil || unseenNotes != nil,
                                scanned: scanned, connect: connect)
                }
            }
            .task {
                // `app == nil`: a link confirmed before this ran has already
                // connected, to the core it named.
                if app == nil, endpoint.remembered { connect() }
                let unseen = WhatsNew.takeUnseen()
                if unseen.show, link == nil { unseenNotes = WhatsNew.releases(after: unseen.seen) }
                launching = false
            }
            .onOpenURL { offer($0) }
            // Never connects without asking: Tailscale vouches for the phone
            // to the computer, not the other way round, and a link that
            // silently repointed the phone would send someone else's server
            // every prompt, photo and keystroke.
            .alert(link?.title ?? "", isPresented: Binding(get: { link != nil }, set: { if !$0 { link = nil } }),
                   presenting: link) { prompt in
                if case let .connect(pairing) = prompt {
                    Button("Connect") { connect(to: pairing) }
                    Button("Cancel", role: .cancel) {}
                } else {
                    Button("OK", role: .cancel) {}
                }
            } message: { prompt in
                if case let .connect(pairing) = prompt { Text(verbatim: pairing.host) }
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

    /// Every pairing link lands here, opened from outside or scanned.
    private func offer(_ url: URL) {
        // A pairing link outranks the release notes: the alert would wait
        // under (or be dropped by) a sheet. They are already marked seen, so
        // they simply yield.
        unseenNotes = nil
        do {
            link = .connect(try PairingLink(url: url))
        } catch {
            link = .refused(error.localizedDescription)
        }
    }

    /// A code the connect screen's camera read. Every QR code in view gets
    /// here, so only a `moomux://connect` link is acted on, and none while an
    /// alert is already up.
    private func scanned(_ payload: String) {
        guard link == nil, let url = PairingLink.scanned(payload) else { return }
        offer(url)
    }

    /// Disconnect then Connect, as the ⋯ menu would do it. On a cold launch
    /// the remembered core may already be connecting; stopping it here is
    /// what makes the link win.
    private func connect(to pairing: PairingLink) {
        endpoint.host = pairing.host
        endpoint.port = Int(pairing.port)
        endpoint.name = pairing.name
        app?.stop()
        app = nil
        connect()
    }
}

/// What a `moomux://` link asks of the user.
private enum LinkPrompt {
    case connect(PairingLink)
    case refused(String)

    var title: String {
        switch self {
        case let .connect(pairing): "Connect to \(pairing.name)?"
        case let .refused(why): why
        }
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

/// Host, port and the computer's name, in `UserDefaults`.
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
    /// The name a pairing link gave the computer, for the failure lines.
    /// Display only; empty after a manual Connect.
    var name: String {
        didSet { UserDefaults.standard.set(name, forKey: "coreName") }
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
        name = UserDefaults.standard.string(forKey: "coreName") ?? ""
    }

    var displayName: String { name.isEmpty ? host.trimmed : name }

    /// The port too, not just the host: `UInt16(clamping:)` below turns a
    /// mistyped 458760 into 65535 and connects *there*, so the only symptom
    /// of a fat-fingered field is "cannot connect" pointing at the wrong
    /// thing. Refusing it keeps Connect disabled instead.
    var remembered: Bool { !host.trimmed.isEmpty && (1...65535).contains(port) }

    var resolved: MoomuxClient.Endpoint {
        .tcp(host: host.trimmed, port: UInt16(clamping: port))
    }
}

/// Leads with the camera; typing an address is the fallback.
struct ConnectView: View {
    @Bindable var endpoint: EndpointStore
    /// Keeps the camera off: at launch, and while an alert or a sheet is up.
    let paused: Bool
    /// What the camera read, unfiltered: the app decides what is a link.
    let scanned: (String) -> Void
    let connect: () -> Void
    @State private var camera: ScanAvailability
    /// Closed until asked for, even with an address remembered: the fields
    /// keep it, so opening them after a Disconnect is one tap, and the
    /// screen stays about the camera.
    @State private var manual = false

    init(endpoint: EndpointStore, paused: Bool, scanned: @escaping (String) -> Void,
         connect: @escaping () -> Void) {
        self.endpoint = endpoint
        self.paused = paused
        self.scanned = scanned
        self.connect = connect
        _camera = State(initialValue: .current)
    }

    var body: some View {
        NavigationStack {
            Form {
                // One line under the camera says where the code comes from;
                // Tailscale is the footnote, since only a first pair needs it.
                Section {
                    PairingScanner(camera: $camera, paused: paused, onCode: scanned)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(camera.showsViewfinder ? "Scan the code from `moomux pair`."
                                                    : "Run `moomux pair` on your computer.")
                        Text("Both devices need [Tailscale](https://tailscale.com/download), same account.")
                    }
                }

                if manual {
                    Section {
                        TextField("Tailnet address", text: $endpoint.host)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Port", value: $endpoint.port, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                        // A typed address has no name but itself: the failure
                        // lines fall back to the host rather than a stale name.
                        Button("Connect") {
                            endpoint.name = ""
                            connect()
                        }
                        .disabled(!endpoint.remembered)
                    }
                } else {
                    Section {
                        Button("Connect manually") { withAnimation { manual = true } }
                    }
                }
            }
            .navigationTitle("Moomux")
        }
    }
}
