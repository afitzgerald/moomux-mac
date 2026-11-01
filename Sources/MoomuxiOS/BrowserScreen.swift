import MoomuxKit
import Network
import SwiftUI
import WebKit

/// A browser whose every connection is made by the computer: the core's
/// CONNECT proxy (`BrowserAddress.proxyPort`) resolves and dials each name, so
/// `localhost:3000/app` and names in its `/etc/hosts` open here as
/// they do in the Mac's own browser, with nothing bound beyond loopback.
struct BrowserScreen: View {
    let computer: Computers.Computer
    /// Built in `.task`, not `init`: the destination closure re-runs on every
    /// snapshot, and `@State` would keep only the first of many pages built.
    @State private var page: WebPage?

    var body: some View {
        Group {
            // Not empty while it is nil: `.task` never runs on an empty Group.
            if let page { BrowserPage(computer: computer, page: page) } else { Color.clear }
        }
        .task {
            guard page == nil else { return }
            // One store per computer, keyed by its id: logins persist across
            // launches, and one computer's cookies never reach another's
            // servers. `forget` removes it.
            let store = WKWebsiteDataStore(forIdentifier: computer.id)
            store.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: .hostPort(
                host: NWEndpoint.Host(computer.host),
                port: NWEndpoint.Port(rawValue: BrowserAddress.proxyPort)!))]
            var config = WebPage.Configuration()
            config.websiteDataStore = store
            page = WebPage(configuration: config)
        }
    }
}

private struct BrowserPage: View {
    let computer: Computers.Computer
    let page: WebPage
    @State private var address = ""
    @State private var failure: String?
    @State private var loading: Task<Void, Never>?
    @FocusState private var editing: Bool

    /// Per computer: a URL names that computer's servers. `-browserURL` is
    /// the screenshot seam's fallback.
    private var lastURLKey: String { "browserURL.\(computer.id)" }

    var body: some View {
        WebView(page)
            .webViewBackForwardNavigationGestures(.enabled)
            .overlay {
                if let failure {
                    ContentUnavailableView("Couldn't open page", systemImage: "network.slash",
                                           description: Text("\(failure)\n\nIs the server running, and is \(computer.displayName)'s moomux new enough to serve the browser proxy?"))
                        .background(.background)
                } else if page.url == nil {
                    ContentUnavailableView("Open a dev server", systemImage: "safari",
                                           description: Text("URLs resolve on \(computer.displayName), so localhost and /etc/hosts names work."))
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    TextField("localhost:3000/app", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($editing)
                        .onSubmit { open(address) }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .glassEffect()
                    Button {
                        failure = nil
                        page.reload()
                    } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.glass)
                        .disabled(page.url == nil)
                        .accessibilityLabel("Reload")
                }
                .padding()
            }
            .navigationTitle(page.title.isEmpty ? "Browser" : page.title)
            .navigationBarTitleDisplayMode(.inline)
            // Any navigation that lands — a link, a swipe back, a redirect —
            // clears an earlier failure and is what gets remembered.
            .onChange(of: page.url) { _, url in
                guard let url else { return }
                failure = nil
                UserDefaults.standard.set(url.absoluteString, forKey: lastURLKey)
                if !editing { address = url.absoluteString }
            }
            .task {
                let defaults = UserDefaults.standard
                address = defaults.string(forKey: lastURLKey) ?? defaults.string(forKey: "browserURL") ?? ""
                if !address.isEmpty { open(address) }
            }
            .onDisappear { loading?.cancel() }
    }

    private func open(_ typed: String) {
        guard let url = BrowserAddress.url(typed) else { return }
        failure = nil
        // A newer load cancels the older one inside WebKit, and that
        // cancellation must not draw an error over the page that replaced it.
        loading?.cancel()
        loading = Task {
            do {
                for try await _ in page.load(URLRequest(url: url)) {}
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
                failure = error.localizedDescription
            }
        }
    }
}
