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

    var body: some Scene {
        WindowGroup {
            Group {
                if let app {
                    SessionListView(app: app, endpoint: endpoint, disconnect: { self.app = nil })
                } else {
                    ConnectView(endpoint: endpoint, connect: connect)
                }
            }
            .task { if endpoint.remembered { connect() } }
        }
    }

    private func connect() {
        let state = AppState(client: MoomuxClient(endpoint: endpoint.resolved))
        state.start()
        app = state
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
    static let defaultPort = 45876

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
