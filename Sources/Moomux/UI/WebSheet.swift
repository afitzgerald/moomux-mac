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
    /// The window behind the sheet, tracked so the sheet can follow it.
    @State private var host: CGRect = WebSheet.hostWindow?.frame ?? .zero

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
            PageView(url: url)
        }
        // Scales with the window behind it, and stays draggable in between: a
        // sheet is only user-resizable when its content has a flexible max, and
        // it takes its size from `ideal` — which is why the parent's frame is
        // @State rather than read once. Setting the sheet window's frame
        // directly does not hold: SwiftUI restores the size it cached when the
        // sheet was presented, measured, so the ideal is what has to change.
        .frame(minWidth: Self.minSize.width, idealWidth: Self.size(in: host).width, maxWidth: .infinity,
               minHeight: Self.minSize.height, idealHeight: Self.size(in: host).height, maxHeight: .infinity)
        .background(SheetSizer(host: $host))
    }

    static let minSize = CGSize(width: 640, height: 480)

    /// The window the sheet will cover: visible, not a panel, not itself a sheet.
    static var hostWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && !($0 is NSPanel) && $0.sheetParent == nil }
    }

    /// Nearly the window, with enough margin left to show what it is covering.
    /// A zero host (no window found) falls back to something laptop-sized.
    static func size(in host: CGRect) -> CGSize {
        guard !host.isEmpty else { return CGSize(width: 1000, height: 720) }
        return CGSize(width: max(minSize.width, host.width - 48),
                      height: max(minSize.height, host.height - 48))
    }

    static func demo() {
        assert(size(in: CGRect(x: 100, y: 200, width: 1400, height: 900))
               == CGSize(width: 1352, height: 852))
        assert(size(in: CGRect(x: 0, y: 0, width: 300, height: 200)) == minSize,
               "never smaller than the sheet's own minimum")
        assert(size(in: .zero) == CGSize(width: 1000, height: 720), "no window to measure")
    }
}

/// Reports the window behind the sheet, and every resize of it.
/// A zero-sized view purely to reach `window.sheetParent` — SwiftUI offers no
/// route to the sheet's own `NSWindow`.
private struct SheetSizer: NSViewRepresentable {
    @Binding var host: CGRect

    func makeNSView(context: Context) -> NSView { SheetSizerView { host = $0 } }
    func updateNSView(_ view: NSView, context: Context) {}
}

private final class SheetSizerView: NSView {
    private let report: (CGRect) -> Void
    private var observer: NSObjectProtocol?

    init(report: @escaping (CGRect) -> Void) {
        self.report = report
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Registered against *every* window rather than the parent: at the moment
    /// the content view lands in the sheet window, `sheetParent` is still nil —
    /// AppKit sets it as `beginSheet` runs — so subscribing to the parent here
    /// subscribes to nothing. Resolving it per notification is what works.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard window != nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let sheet = self?.window, let parent = sheet.sheetParent,
                  parent === note.object as? NSWindow else { return }
            // Both halves are needed. `setFrame` alone is undone the next time
            // SwiftUI lays the sheet out — it restores the size it cached when
            // the sheet was presented — and the state alone arrives a layout
            // pass too late, so the sheet lands on the *previous* size.
            self?.report(parent.frame)
            let size = WebSheet.size(in: parent.frame)
            sheet.setFrame(CGRect(x: parent.frame.midX - size.width / 2,
                                  y: sheet.frame.maxY - size.height,
                                  width: size.width, height: size.height),
                           display: true)
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

/// Not `WebView`: SwiftUI has shipped a `WebView` of its own since macOS 26, and
/// overload resolution picks theirs over a private one with the same memberwise
/// init — which then fails to build against this bundle's 14.0 target.
private struct PageView: NSViewRepresentable {
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
