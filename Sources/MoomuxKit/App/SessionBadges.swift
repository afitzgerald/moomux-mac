import SwiftUI

/// One session's badge row, in both apps: ticket, PR (carrying its own merge/CI
/// state), then `internal/tui/list.go`'s two git icons — ± for a dirty worktree,
/// ↑ for commits not on the remote — and an archive box only in a search, the
/// one list that mixes archived rows in with live ones.
///
/// Shared so the order, the colours and the rules cannot drift between the Mac
/// sidebar and the phone's list, which they had begun to as two copies. What
/// differs is passed in: the spacing, and how a tag is drawn — a clickable link
/// on the Mac (`TagIcon`), a plain glyph on the phone, where the row's own tap
/// attaches and a 12pt target beside it would be a mis-tap waiting to happen.
public struct SessionBadges<Tag: View>: View {
    let app: AppState
    let session: Session
    let spacing: CGFloat
    /// symbol, link, help → the drawn tag. `link` is the ticket or PR value
    /// as the user set it; `help` already carries the PR's summary.
    let tag: (_ symbol: String, _ link: String, _ help: String) -> Tag

    public init(app: AppState, session: Session, spacing: CGFloat,
                @ViewBuilder tag: @escaping (_ symbol: String, _ link: String, _ help: String) -> Tag) {
        self.app = app
        self.session = session
        self.spacing = spacing
        self.tag = tag
    }

    public var body: some View {
        HStack(spacing: spacing) {
            if let ticket = session.ticket, !ticket.isEmpty {
                tag("ticket", ticket, ticket)
                    .foregroundStyle(.secondary)
            }
            if let pr = session.pr, !pr.isEmpty {
                let info = app.views[session.id]?.pr
                let badge = PRInfo.badge(info)
                tag(badge.symbol, pr, SessionBadges.prHelp(badge, summary: info?.summary))
                    .foregroundStyle(SessionTheme.pr(badge, app.palette))
            }
            // SF Symbols rather than the literal glyphs, so they weigh and
            // align like the row's other icons. Both can show at once: they
            // are different work in different places.
            if let git = app.gitBadges(for: session) {
                if git.dirty { glyph("plusminus", "Uncommitted changes", SessionTheme.gitWarn(app.palette)) }
                if git.unpushed { glyph("arrow.up", "Unpushed commits", SessionTheme.gitWarn(app.palette)) }
            }
            if session.archived && app.searching {
                Image(systemName: "archivebox")
                    .foregroundStyle(.tertiary)
                    .help("Archived")
                    .accessibilityLabel("Archived")
            }
        }
    }

    private func glyph(_ symbol: String, _ label: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .foregroundStyle(color)
            .help(label)
            .accessibilityLabel(label)
    }

    /// The PR badge's own words, plus the core's one-line summary when it has one.
    static func prHelp(_ badge: PRInfo.Badge, summary: String?) -> String {
        guard let summary, !summary.isEmpty else { return badge.help }
        return "\(badge.help) — \(summary)"
    }
}

/// The cow mark plus a line in a speech bubble, standing in for a title on
/// both apps: the session's quip, or its state when there is no quip. Fill
/// only, no stroke — a border reads as another toolbar button.
///
/// The mark is passed in because each app loads it its own way: the Mac reads
/// the SVG from its bundle, and `UIImage` cannot, so `make ios` rasterizes the
/// same file to a PNG. `compact` is the phone's smaller toolbar.
public struct CowQuip: View {
    let saying: String
    let mark: Image?
    let compact: Bool

    public init(saying: String, mark: Image?, compact: Bool = false) {
        self.saying = saying
        self.mark = mark
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: compact ? 6 : 8) {
            if let mark {
                let side: CGFloat = compact ? 22 : 28
                mark.resizable().scaledToFit().frame(width: side, height: side)
            }
            Text(saying)
                .font(compact ? .footnote : .callout)
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .padding(.leading, 6 + (compact ? 6 : 8))  // the bubble's tail, then air
                .padding(.trailing, compact ? 9 : 10)
                .padding(.vertical, compact ? 3 : 4)
                .background(SpeechBubble().fill(Color.secondary.opacity(0.15)))
        }
    }
}

extension SessionBadges where Tag == Never {
    public static func demo() {
        assert(prHelp(.open, summary: nil) == PRInfo.Badge.open.help)
        assert(prHelp(.open, summary: "") == PRInfo.Badge.open.help, "an empty summary adds nothing")
        assert(prHelp(.open, summary: "2 checks failing") == "\(PRInfo.Badge.open.help) — 2 checks failing")
    }
}
