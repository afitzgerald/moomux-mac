import SwiftUI

/// "5h 40%  Week 53%" — the headline quota windows, plus any carve-out at warn
/// or above, each in its level's colour.
/// One view for both front ends so the Mac's toolbar and the phone's read
/// alike; the detail around it (a tooltip, a menu) is each platform's own.
public struct UsageLine: View {
    let usage: Usage
    let palette: ThemePalette?
    let now: Date
    /// A muted "used" after the numbers, which a bare percent leaves open.
    /// Where there is room for it — the TUI drops it first in its narrow footer,
    /// and the phone's top bar is that footer.
    let saysUsed: Bool

    public init(_ usage: Usage, palette: ThemePalette?, now: Date = Date(), saysUsed: Bool = false) {
        self.usage = usage
        self.palette = palette
        self.now = now
        self.saysUsed = saysUsed
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if usage.status == .signedOut {
                Label("Signed out", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else {
                if !usage.isCurrent {
                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.secondary)
                }
                // The name is the label and the number is the reading, so the
                // number carries the weight — one run of same-coloured words
                // reads as a sentence rather than as two figures.
                ForEach(Array(usage.inline(now: now).enumerated()), id: \.offset) { _, window in
                    let style = SessionTheme.usage(usage.level(of: window, now: now), palette)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(window.name).font(.caption).foregroundStyle(.secondary)
                        Text("\(window.percent)%")
                            .foregroundStyle(usage.isCurrent ? style.color : .secondary)
                            .fontWeight(style.bold ? .semibold : .medium)
                    }
                }
                if saysUsed {
                    Text("used").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let numbers = usage.status == .signedOut ? []
            : usage.inline(now: now).map { "\($0.name) \($0.percent) percent used" }
        return "Claude usage: " + (numbers + [usage.problem].compactMap { $0 }).joined(separator: ", ")
    }
}
