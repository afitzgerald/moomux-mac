import SwiftUI

/// "5h 40%  Week 53%" — the headline quota windows, plus any carve-out at warn
/// or above, each in its level's colour.
/// One view for both front ends so the Mac's toolbar and the phone's read
/// alike; the detail around it (a tooltip, a menu) is each platform's own.
public struct UsageLine: View {
    let usage: Usage
    let agent: String
    let palette: ThemePalette?
    let now: Date
    let free: Bool

    public init(_ usage: Usage, agent: String = "Claude", palette: ThemePalette?, now: Date = Date(), free: Bool = false) {
        self.usage = usage
        self.agent = agent
        self.palette = palette
        self.now = now
        self.free = free
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Text(agent)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if usage.status == .signedOut {
                Label("Signed out", systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.secondary)
            } else {
                if !usage.isCurrent && usage.status != .idle {
                    Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.secondary)
                }
                // The name is the label and the number is the reading, so the
                // number carries the weight — one run of same-coloured words
                // reads as a sentence rather than as two figures.
                ForEach(Array(usage.inline(now: now).enumerated()), id: \.offset) { _, window in
                    let style = SessionTheme.usage(usage.level(of: window, now: now), palette)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(window.name).font(.caption).foregroundStyle(.secondary)
                            Text("\(usage.percent(of: window, free: free))%")
                                .foregroundStyle(usage.isCurrent ? style.color : .secondary)
                                .fontWeight(style.bold ? .semibold : .medium)
                        }
                        GeometryReader { geometry in
                            let fraction = CGFloat(max(0, min(100, usage.percent(of: window, free: free)))) / 100
                            Capsule().fill(.primary.opacity(0.12))
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(usage.isCurrent ? style.color.opacity(style.bold ? 0.9 : 0.5) : Color.secondary.opacity(0.4))
                                        .frame(width: geometry.size.width * fraction)
                                }
                        }
                        .frame(height: 3)
                    }
                }
                if usage.inline(now: now).isEmpty && usage.tokens != nil {
                    Text("Tokens").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let numbers = usage.status == .signedOut ? []
            : usage.inline(now: now).map { "\($0.name) \(usage.percent(of: $0, free: free)) percent \(free ? "free" : "used")" }
        return "\(agent) usage: " + (numbers + [usage.tokens?.detail, usage.status == .signedOut ? "\(agent) is signed out" : usage.problem].compactMap { $0 }).joined(separator: ", ")
    }
}
