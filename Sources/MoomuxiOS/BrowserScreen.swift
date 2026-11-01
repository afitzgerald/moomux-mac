import MoomuxKit
import Network
import SwiftUI
import WebKit

/// A browser whose every connection is made by the computer: the core's
/// CONNECT proxy (`BrowserAddress.proxyPort`) resolves and dials each name, so
/// `localhost:3000/app` and names in its `/etc/hosts` open here as
/// they do in the Mac's own browser, with nothing bound beyond loopback.
///
/// One per session, from the pane's ⋯ menu or a tapped dev-server link: it
/// reopens on that session's last URL, and keeps its own cookies and logins
/// (`BrowserStores`). Cookies are scoped by host, not port, so in one store
/// every `localhost` server would read and overwrite the others' logins.
struct BrowserScreen: View {
    let computer: Computers.Computer
    let sessionID: Session.ID
    /// A link tapped in the pane; nil reopens the session's last URL.
    let url: URL?
    /// Built in `.task`, not `init`: the destination closure re-runs on every
    /// snapshot, and `@State` would keep only the first of many pages built.
    @State private var page: WebPage?
    @State private var storeID: UUID?

    var body: some View {
        Group {
            // Not empty while it is nil: `.task` never runs on an empty Group.
            if let page, let storeID {
                BrowserPage(computer: computer, storeID: storeID, url: url, page: page)
            } else {
                Color.clear
            }
        }
        .task {
            guard page == nil else { return }
            // One store per session: logins persist across launches and stay
            // with the session. `BrowserStores.sweep` removes it once the
            // session is gone.
            let id = BrowserStores.id(computer: computer.id, session: sessionID)
            let store = WKWebsiteDataStore(forIdentifier: id)
            store.proxyConfigurations = [ProxyConfiguration(httpCONNECTProxy: .hostPort(
                host: NWEndpoint.Host(computer.host),
                port: NWEndpoint.Port(rawValue: BrowserAddress.proxyPort)!))]
            var config = WebPage.Configuration()
            config.websiteDataStore = store
            storeID = id
            page = WebPage(configuration: config)
        }
    }
}

private struct BrowserPage: View {
    let computer: Computers.Computer
    let storeID: UUID
    let url: URL?
    let page: WebPage
    @State private var address = ""
    @State private var failure: String?
    @State private var loading: Task<Void, Never>?
    @FocusState private var editing: Bool

    /// Per session, since each worktree runs its own server; it goes when
    /// the session's store does. `-browserURL` is the screenshot seam's
    /// fallback.
    private var lastURLKey: String { BrowserStores.urlKey(storeID) }

    var body: some View {
        VStack(spacing: 0) {
            // The strip under the drag indicator: something solid to pull the
            // sheet down by, where the page's own scrolling would take it.
            Text(page.title.isEmpty ? "Browser" : page.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.top, 18).padding(.bottom, 8).padding(.horizontal)
                .background(.bar)
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
            HStack {
                TextField("localhost:3000/app", text: $address)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($editing)
                    .onSubmit { open(address) }
                    .font(.body.monospaced())
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    // Opaque, not glass: over a page the text took on
                    // whatever colour was behind it and could not be read.
                    .background(Color(.secondarySystemBackground), in: .capsule)
                Button {
                    failure = nil
                    page.reload()
                } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(page.url == nil)
                    .accessibilityLabel("Reload")
            }
            .padding(.horizontal).padding(.vertical, 8)
            .background(.bar)
        }
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
                address = url?.absoluteString ?? defaults.string(forKey: lastURLKey)
                    ?? defaults.string(forKey: "browserURL") ?? ""
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

extension BrowserStores {
    /// Removes each stale store (`stale`), and forgets it once it is gone.
    /// One still in use, its sheet up, throws and waits for the next sweep.
    /// On the main actor, as `id` is: both rewrite the one record.
    @MainActor
    static func sweep(computer: UUID, live: Set<Session.ID>?) {
        let ids = stale(computer: computer, live: live)
        guard !ids.isEmpty else { return }
        remove(ids) { drop($0) }
    }

    /// The one store every session on a computer shared before stores were
    /// per session, and its last URL. Run for every paired computer at
    /// launch; delete once no install from before it is left.
    @MainActor
    static func removeShared(computer: UUID) {
        UserDefaults.standard.removeObject(forKey: "browserURL.\(computer)")
        remove([computer]) { _ in }
    }

    /// One removal at a time, and only of a store WebKit lists. `done` runs
    /// for each id that is gone, removed or never there.
    @MainActor
    private static func remove(_ ids: [UUID], done: @escaping @MainActor (UUID) -> Void) {
        let previous = removing
        removing = Task { @MainActor in
            await previous?.value
            let existing = Set(await identifiers())
            for id in ids {
                if existing.contains(id) {
                    guard await remove(id) else { continue }
                }
                done(id)
            }
        }
    }

    /// Before anything in the process has made a WebKit object, WebKit's
    /// static store calls crash the app (a null run loop inside WebKit;
    /// measured, a second or so after every launch). Making the default
    /// store first sets WebKit up. The completion-handler forms, started from
    /// the main actor, because WebKit wants its calls on the main thread and
    /// Swift runs the `async` imports on the global executor.
    @MainActor
    private static func identifiers() async -> [UUID] {
        _ = WKWebsiteDataStore.default()
        return await withCheckedContinuation { done in
            WKWebsiteDataStore.fetchAllDataStoreIdentifiers { done.resume(returning: $0) }
        }
    }

    @MainActor
    private static func remove(_ id: UUID) async -> Bool {
        await withCheckedContinuation { done in
            WKWebsiteDataStore.remove(forIdentifier: id) { done.resume(returning: $0 == nil) }
        }
    }

    @MainActor private static var removing: Task<Void, Never>?
}
