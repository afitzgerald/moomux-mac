import BackgroundTasks
import MoomuxKit
import SwiftUI
import WebKit

/// The iPhone front end.
///
/// Same one-way flow as the Mac app — `moomux serve` → `MoomuxClient` →
/// `AppState` → views — with two differences forced by the platform. The
/// transport is TCP across a tailnet rather than a unix socket, and there is
/// no `.exec` terminal: attaching waits on the core's `Attach` stream, which
/// does not exist yet. Everything the wire already serves works today.
@main
struct MoomuxiOSApp: App {
    @State private var computers = ComputerStore()
    @State private var app: AppState?
    /// The release notes to show at launch; see `WhatsNew.takeUnseen`.
    @State private var unseenNotes: [WhatsNew.Release]?
    /// A pairing link waiting on Connect or Cancel, or why one was refused.
    @State private var link: LinkPrompt?
    /// The name a pairing link's computer is saved under, editable in its alert.
    @State private var linkName = ""
    /// Until the launch `.task` has decided whether to reconnect. The Connect
    /// screen is drawn for that first frame even when a remembered core is
    /// about to replace it, and must not prompt for or start the camera.
    @State private var launching = true
    /// Add computer: the Connect screen in place of the list, with a Cancel.
    /// In place rather than as a sheet, so the link alert has a screen to
    /// show over.
    @State private var adding = false
    @Environment(\.scenePhase) private var scenePhase

    /// In `init`, not a view's `.task`: `BGTaskScheduler` refuses a
    /// registration made after launch finishes, and a late one fails silently
    /// — refresh then never runs, which looks exactly like iOS throttling it.
    init() {
        BackgroundRefresh.register()
        Notifier.listenForTaps()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let app, !adding {
                    SessionListView(app: app, computers: computers, select: select,
                                    add: { adding = true }, forget: forget)
                        // A link swaps the store in one step, with no Connect
                        // screen in between to reset the list's navigation.
                        .id(ObjectIdentifier(app))
                } else {
                    // The camera stops while anything is up over it.
                    ConnectView(paused: launching || link != nil || unseenNotes != nil,
                                scanned: scanned, connect: connect(host:port:),
                                cancel: app == nil ? nil : { adding = false })
                }
            }
            .task {
                Notifier.onTap(tapped)
                // `app == nil`: a link confirmed or a banner tapped before this
                // ran has already connected, to the computer it named.
                if app == nil { connect() }
                let unseen = WhatsNew.takeUnseen()
                if unseen.show, link == nil { unseenNotes = WhatsNew.releases(after: unseen.seen) }
                launching = false
            }
            .onChange(of: computers.saved) { relabel() }
            .onOpenURL { offer($0) }
            // Never connects without asking: Tailscale vouches for the phone
            // to the computer, not the other way round, and a link that
            // silently repointed the phone would send someone else's server
            // every prompt, photo and keystroke.
            .alert(link?.title ?? "", isPresented: Binding(get: { link != nil }, set: { if !$0 { link = nil } }),
                   presenting: link) { prompt in
                if case let .connect(pairing) = prompt {
                    // The placeholder is what an empty name falls back to.
                    TextField(pairing.name, text: $linkName)
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

    /// To the current computer, if there is one.
    private func connect() {
        guard let computer = computers.saved.current else { return }
        let state = AppState(client: MoomuxClient(endpoint: computer.endpoint))
        state.notificationKey = computer.id.uuidString
        state.start()
        app = state
        BackgroundRefresh.app = state
        BackgroundRefresh.others[computer.id] = nil
        relabel()
    }

    /// Disconnect, then Connect to whichever computer is current now. The
    /// store left behind goes to background refresh with its views, so the
    /// computer just left can banner from the next refresh rather than only
    /// seeding.
    private func reconnect() {
        app?.stop()
        if let app, let id = UUID(uuidString: app.notificationKey) { BackgroundRefresh.others[id] = app }
        app = nil
        adding = false
        connect()
    }

    private func select(_ id: UUID) {
        computers.saved.select(id)
        reconnect()
    }

    /// Its banners' share of the badge goes with it. Forgetting the one on
    /// screen moves to the next, or back to the camera after the last.
    private func forget(_ id: UUID) {
        computers.saved.forget(id)
        BackgroundRefresh.others[id] = nil
        Notifier.forget(id.uuidString)
        // The Browser's cookies and logins for it; a re-pair gets a new id.
        Task { try? await WKWebsiteDataStore.remove(forIdentifier: id) }
        guard app?.notificationKey == id.uuidString else { return }
        app?.stop()
        app = nil
        connect()
    }

    /// Enter address manually. A typed address has no name but itself.
    private func connect(host: String, port: Int) {
        computers.saved.add(host: host, port: port, name: "")
        reconnect()
    }

    /// Banners name the computer once there are two to tell apart.
    private func relabel() {
        let stores = [app].compactMap { $0 } + BackgroundRefresh.others.values
        stores.forEach(computers.saved.label)
    }

    /// A banner tap: to the computer it came from, then the session. One
    /// posted before computers had keys has none, and means this one.
    private func tapped(_ identifier: String) {
        let tap = Notifier.tapped(identifier)
        if let id = UUID(uuidString: tap.key), app?.notificationKey != tap.key {
            // Forgotten since it was posted.
            guard computers.saved.list.contains(where: { $0.id == id }) else { return }
            select(id)
        } else if app == nil {
            connect()
        }
        adding = false
        app?.selectedSessionID = tap.session
    }

    /// Every pairing link lands here, opened from outside or scanned.
    private func offer(_ url: URL) {
        // A pairing link outranks the release notes: the alert would wait
        // under (or be dropped by) a sheet. They are already marked seen, so
        // they simply yield.
        unseenNotes = nil
        do {
            let pairing = try PairingLink(url: url)
            // A computer already saved at this address offers its own rename.
            let saved = computers.saved.list.first { $0.host == pairing.host && $0.port == Int(pairing.port) }
            linkName = saved.map(\.customName).flatMap { $0.isEmpty ? nil : $0 } ?? pairing.name
            link = .connect(pairing)
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

    /// A new computer is added; one already saved (same address) is switched
    /// to, its code name refreshed and any rename kept. On a cold launch the
    /// remembered core may already be connecting; reconnecting is what makes
    /// the link win. The code's own name left as it is, or cleared, is no
    /// rename, so a later rescan keeps refreshing it.
    private func connect(to pairing: PairingLink) {
        computers.saved.add(host: pairing.host, port: Int(pairing.port), name: pairing.name)
        if let id = computers.saved.currentID {
            computers.saved.rename(id, to: linkName.trimmed == pairing.name ? "" : linkName)
        }
        reconnect()
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
    /// case, and the one that can tell a new wait from an old one.
    @MainActor static weak var app: AppState?
    /// A store per other computer, kept between refreshes for the same
    /// reason: one with views can tell a new wait from an old one, a new one
    /// only seeds and sets the badge. A switch leaves the store it
    /// disconnected here. Ceiling: gone when iOS ends the app, so the first
    /// refresh after a cold background launch only seeds.
    @MainActor static var others: [UUID: AppState] = [:]

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            // Rescheduled first, so a refresh that fails or is cut off cannot
            // end the chain.
            schedule()
            let work = Task { @MainActor in task.setTaskCompleted(success: await pollAll()) }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Every saved computer at once, so one that is asleep does not use up
    /// the time the others had. A success if any answered.
    @MainActor private static func pollAll() async -> Bool {
        let saved = ComputerStore.load()
        others = others.filter { id, _ in saved.list.contains { $0.id == id } }
        let stores = saved.list.map { computer -> AppState in
            if let app, app.notificationKey == computer.id.uuidString { return app }
            let store = others[computer.id] ?? AppState(client: MoomuxClient(endpoint: computer.endpoint))
            store.notificationKey = computer.id.uuidString
            others[computer.id] = store
            return store
        }
        stores.forEach(saved.label)
        return await withTaskGroup(of: Bool.self) { group in
            for store in stores {
                group.addTask { @MainActor in (try? await store.pollOnce()) != nil }
            }
            return await group.reduce(false) { $0 || $1 }
        }
    }
}

// MARK: - Where the cores are

/// The saved computers, in `UserDefaults`.
///
/// Not in the Keychain: a tailnet address is not a secret, and there is no
/// token to store — the core authorizes by asking Tailscale who the peer is,
/// so the phone proves itself by being on the tailnet at all.
@MainActor @Observable
final class ComputerStore {
    var saved: Computers {
        didSet { save() }
    }

    private static let key = "computers"

    init() {
        let defaults = UserDefaults.standard
        saved = Self.load()
        // The one-computer keys this replaced, once; and the screenshot seam
        // (`-coreHost 127.0.0.1 -corePort 8765`), which arrives in the
        // argument domain on every launch and switches to that core.
        let arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        if saved.list.isEmpty || arguments["coreHost"] != nil,
           let host = defaults.string(forKey: "coreHost"), !host.trimmed.isEmpty {
            // `integer(forKey:)`, not `object(forKey:) as? Int`: a launch
            // argument arrives as a string, so the cast fails and silently
            // takes the default — which looks exactly like the core being
            // unreachable. 0 means unset, since no port is 0.
            let port = defaults.integer(forKey: "corePort")
            saved.add(host: host, port: port > 0 ? port : MoomuxClient.tailnetPort,
                      name: defaults.string(forKey: "coreName") ?? "")
            for old in ["coreHost", "corePort", "coreName"] { defaults.removeObject(forKey: old) }
            save()
            // Banners from before computers had keys: a tap could open the
            // right session id on the wrong computer.
            Notifier.forget("")
        }
    }

    /// The list as saved, without the migration: background refresh reads,
    /// and only the app writes.
    static func load() -> Computers {
        UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(Computers.self, from: $0) } ?? Computers()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: Self.key)
    }
}

extension Computers {
    /// Banners name the computer once there are two to tell apart.
    @MainActor func label(_ store: AppState) {
        let computer = list.first { $0.id.uuidString == store.notificationKey }
        store.computerName = list.count > 1 ? computer?.displayName ?? "" : ""
    }
}

/// The camera, one line, and the address behind a button: pairing is the way
/// in, typing is the fallback. Also what Add computer opens, with a Cancel.
struct ConnectView: View {
    /// Keeps the camera off: at launch, and while an alert or a sheet is up.
    let paused: Bool
    /// What the camera read, unfiltered: the app decides what is a link.
    let scanned: (String) -> Void
    /// A typed host and port.
    let connect: (String, Int) -> Void
    /// Back to the list; nil when there is no computer to go back to.
    let cancel: (() -> Void)?
    @State private var camera = ScanAvailability.current
    @State private var manual = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                PairingScanner(camera: $camera, paused: paused || manual, onCode: scanned)
                Text("Run `moomux pair` on your computer and scan the code.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Enter address manually") { manual = true }
                Link("New to Tailscale?", destination: URL(string: "https://tailscale.com/download")!)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .navigationTitle("Moomux")
            .toolbar {
                if let cancel {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                }
            }
            .sheet(isPresented: $manual) { ManualConnectSheet(connect: connect) }
        }
    }
}

/// A host and port for a computer the phone has no code from. Starts empty:
/// it adds a computer, and a typed address that matches a saved one simply
/// switches to it.
private struct ManualConnectSheet: View {
    let connect: (String, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @State private var port = MoomuxClient.tailnetPort

    var body: some View {
        NavigationStack {
            Form {
                TextField("100.71.5.0 or a MagicDNS name", text: $host)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", value: $port, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
            }
            .navigationTitle("Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        dismiss()
                        connect(host, port)
                    }
                    .disabled(!Computers.valid(host: host, port: port))
                }
            }
        }
        .presentationDetents([.medium])
    }
}
