import CoreGraphics

/// The sidebar's one layout rule.
///
/// Every row — project header, folder header, project subheader, session — is
/// laid out as `[indent][disclosure][icon][name]`, where the disclosure and
/// icon columns are **fixed widths** that a row leaves empty rather than
/// skipping. So a name's x depends on its nesting level and nothing else: not
/// on whether the row has a chevron, not on whether a project set an emoji,
/// and not on the glyph metrics of whatever font the user picked. A session
/// row has no chevron, so it pays for that column in its leading padding.
///
/// This replaces two constants that had to be tuned against each other (a
/// per-level step plus a fudge for the missing chevron) and still came out
/// wrong whenever a row's prefix changed width.
public enum SidebarGrid {
    /// The size the phone's list draws at. The Mac derives every column from
    /// `AppState.listFontSize`, which is adjustable there; the phone has no
    /// such control yet, so it pins one value rather than hardcoding pixel
    /// widths that would drift the moment it gains one.
    public static let phoneFont: Double = 15

    /// The gap between columns, and between the icon and the name.
    public static let gap: CGFloat = 4

    /// One level of nesting. The only knob: everything else follows from the
    /// columns. 1.25em lands on the 16pt Finder uses at the system font size,
    /// and scales with the sidebar font.
    public static func step(_ font: Double) -> CGFloat { CGFloat(font) * 1.25 }
    /// The disclosure triangle's column, occupied or not.
    public static func disclosure(_ font: Double) -> CGFloat { CGFloat(font) }
    /// The folder glyph / project emoji / session state dot column.
    public static func icon(_ font: Double) -> CGFloat { CGFloat(font) * 1.25 }

    /// A header's leading inset at `level`.
    public static func indent(_ level: Int, _ font: Double) -> CGFloat {
        CGFloat(level) * step(font)
    }

    /// A session row's, which is a header's plus the chevron column it has no
    /// chevron for — that is what puts its dot one clean step right of the
    /// icon of the header it belongs to.
    public static func rowIndent(_ level: Int, _ font: Double) -> CGFloat {
        indent(level, font) + disclosure(font) + gap
    }
}
