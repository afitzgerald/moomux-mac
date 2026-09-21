#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import SwiftUI

/// The colors this app draws sessions with, shared by both front ends.
///
/// Every one of them comes from the core's `Themes` table — no hardcoded
/// palette, and no literal hex outside `resolve`, which honours both halves of
/// a served light/dark pair. It lives in the Kit rather than in the Mac's
/// `Theme` precisely because a second copy on the phone is how the two front
/// ends' dots would drift apart, which is the thing the core splitting `warn`
/// out of `done` was meant to end.
public enum SessionTheme {

    /// The agent-state colors, from the palette the core serves for the
    /// config's current theme. Nil before `Themes` has answered, which falls
    /// back to SwiftUI's own semantic colors — literally what the "default"
    /// palette encodes, so the zero state is the right one.
    public static func color(_ state: AgentState, _ palette: ThemePalette?) -> Color {
        resolve(palette?.color(for: state)) ?? {
            switch state {
            case .needsInput: return .orange
            case .working: return .accentColor
            case .done: return .green
            case .parked, .unknown: return .secondary
            }
        }()
    }

    /// The ± and ↑ badges. `internal/tui/list.go` draws both in `warnStyle`,
    /// built from the palette's *warn* entry, so this is that same join.
    public static func gitWarn(_ palette: ThemePalette?) -> Color {
        resolve(palette?.warn) ?? .orange
    }

    /// The PR icon. Merged is the palette's `done`, conflicts and failing CI
    /// its `warn` — the same entries the git badges and state dots use.
    public static func pr(_ badge: PRInfo.Badge, _ palette: ThemePalette?) -> Color {
        switch badge {
        case .merged: return resolve(palette?.done) ?? .green
        case .conflicts, .failing, .comments: return gitWarn(palette)
        // Pending is not a problem, so it stays secondary: warn here would put
        // an amber icon on every PR for the minutes its checks run.
        case .open, .closed, .pending: return .secondary
        }
    }

    /// A served color as SwiftUI sees it. `system` wins when the core names
    /// one — that is how the state dots keep following the user's live accent
    /// instead of a frozen #007aff. Otherwise the light/dark pair, as a
    /// dynamic platform color so the half is resolved at draw time and no view
    /// has to observe the color scheme.
    public static func resolve(_ c: ThemeColor?) -> Color? {
        guard let c else { return nil }
        switch c.system {
        case "accent": return .accentColor
        case "green": return .green
        case "orange": return .orange
        case "secondary": return .secondary
        default: break
        }
        guard channels(c.light) != nil, channels(c.dark) != nil else { return nil }
        #if canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return nsColor(dark ? c.dark : c.light) ?? .labelColor
        })
        #else
        return Color(uiColor: UIColor { traits in
            let dark = traits.userInterfaceStyle == .dark
            return uiColor(dark ? c.dark : c.light) ?? .label
        })
        #endif
    }

    /// "#rrggbb" only — the one format the core sends for a non-ANSI theme.
    /// Parsed once here so both platforms' color types are built from the same
    /// validation, and a rejected hex reads as "no color" so the caller's
    /// semantic fallback wins.
    static func channels(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var h = Substring(hex)
        guard h.first == "#" else { return nil }
        h = h.dropFirst()
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xff) / 255,
                Double((v >> 8) & 0xff) / 255,
                Double(v & 0xff) / 255)
    }

    #if canImport(AppKit)
    static func nsColor(_ hex: String) -> NSColor? {
        guard let c = channels(hex) else { return nil }
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
    #else
    static func uiColor(_ hex: String) -> UIColor? {
        guard let c = channels(hex) else { return nil }
        return UIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
    }
    #endif

    /// A regression here is silent by construction — a hex the parser rejects
    /// falls through to the SwiftUI semantic color and still renders something
    /// plausible — so the parser gets asserts rather than a screenshot.
    public static func demo() {
        assert(channels("#076678") != nil)
        assert(channels("12") == nil, "an ANSI index is not hex")
        assert(channels("#12345") == nil && channels("#1234567") == nil, "six digits or nothing")
        assert(channels("076678") == nil, "the # is required")
        assert(channels("#gggggg") == nil)
        assert(channels("#ffffff")?.b == 1)
        assert(channels("#ff0000")?.b == 0, "channels in RGB order")

        // system beats hex, and only for the names the core actually sends.
        assert(resolve(ThemeColor(light: "#ff0000", dark: "#ff0000", system: "accent")) == .accentColor)
        assert(resolve(ThemeColor(light: "#ff0000", dark: "#ff0000", system: "chartreuse")) != nil,
               "an unfamiliar system name falls back to the pair, not to nil")
        assert(resolve(nil) == nil)
        // The ANSI theme never reaches here (`ThemePalette.resolved` swaps it
        // for default), but a half it could not parse must read as "no color"
        // so the caller's semantic fallback wins.
        assert(resolve(ThemeColor(light: "11", dark: "11")) == nil)
        assert(resolve(ThemeColor(light: "#83a598", dark: "")) == nil, "both halves or neither")
    }
}
