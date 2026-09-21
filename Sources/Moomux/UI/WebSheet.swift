import SwiftUI
import WebKit

/// A ticket or PR opened in the app rather than in the browser's twentieth tab.
/// It is the real web app, so editing works — but WKWebView's cookie jar is not
/// Safari's, so each site wants a login of its own the first time. The default
/// data store keeps that across launches.
///
/// Esc closes it (the Done button's `.cancelAction`), which is the whole point:
/// a glance costs nothing to undo. "Open Externally" is the escape hatch for
/// anything the web view cannot do, and goes through `TerminalLink.open` so an
/// Asana link still lands in the Asana desktop app.
struct WebSheet: View {
    @Environment(\.dismiss) private var dismiss
    let link: String
    let url: URL

    var body: some View {
        VStack(spacing: 0) {
            // The bar is at the top because it is the escape hatch you reach for
            // *before* reading: anything the web view cannot do (an SSO login, a
            // file upload) is one click away, and the link itself is that click.
            HStack {
                Button { TerminalLink.open(link); dismiss() } label: {
                    Text(url.absoluteString)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                // `.link` draws it accented *and* takes first responder on open,
                // so the URL sat behind a focus ring looking like an editable
                // address field. Plain text plus the hand cursor says link here.
                .buttonStyle(.plain)
                // It takes first responder on open otherwise, and a focus ring
                // around the URL reads as an editable address field.
                .focusEffectDisabled()
                .help("Open externally")
                .onHover { NSCursor.pointingHand.set(); if !$0 { NSCursor.arrow.set() } }
                Spacer()
                Button("Open Externally") { TerminalLink.open(link); dismiss() }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            WebView(url: url)
        }
        .frame(minWidth: 820, idealWidth: 1000, minHeight: 560, idealHeight: 720)
    }
}

private struct WebView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.load(URLRequest(url: url))
        return view
    }

    /// Only ever loads once. SwiftUI re-runs this on every store tick, and
    /// re-loading would throw away whatever the user was typing.
    func updateNSView(_ view: WKWebView, context: Context) {
        guard view.url == nil, !view.isLoading else { return }
        view.load(URLRequest(url: url))
    }
}
