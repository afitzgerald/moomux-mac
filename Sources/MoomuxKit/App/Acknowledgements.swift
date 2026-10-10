import SwiftUI

/// The app's own LICENSE and the third-party notices, as bundled by `make app`,
/// `make ios` and the Xcode target. MIT and the BSD licenses in the notices
/// require them to ship with the binary; this is where a user can read them.
///
/// Shown as the files' plain text, in monospace: the notices are mostly license
/// text and one table, which reads fine raw, and rendering Markdown tables is
/// something SwiftUI's `AttributedString` does not do.
public enum Acknowledgements {
    public static let text: String = ["LICENSE", "THIRD_PARTY_NOTICES.md"]
        .compactMap { name -> String? in
            let file = name as NSString
            let ext = file.pathExtension
            guard let url = Bundle.main.url(forResource: file.deletingPathExtension,
                                            withExtension: ext.isEmpty ? nil : ext) else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        .joined(separator: "\n\n")
}

public struct AcknowledgementsSheet: View {
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Acknowledgements").font(.title2.bold())
            ScrollView {
                Text(Acknowledgements.text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        #if os(macOS)
        .frame(width: 620)
        .frame(minHeight: 240, maxHeight: 560)
        #else
        .presentationDetents([.large])
        #endif
    }
}
