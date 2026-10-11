import SwiftUI

/// Release notes, shown at launch for every release since the one last seen,
/// and on demand from the Help menu.
///
/// The notes are baked into the bundle as `WhatsNew.md` by the Release
/// workflow, not fetched at runtime: that works offline, needs no token for a
/// private repo, and always matches the build. The file holds the last several
/// releases, newest first, each under a `# vX.Y.Z` line — every merge to main
/// is its own release, so an upgrade that skips a few would otherwise show only
/// the last PR. A local build has no file, so it never shows the sheet and never
/// marks a version seen.
///
/// Shared by the Mac and iPhone apps, and self-contained on purpose — nothing
/// else from MoomuxKit — so the file can be copied into another app as is. The
/// wiring (a sheet, a menu item, a launch check) is per app.
public enum WhatsNew {
    public struct Section: Hashable, Sendable {
        public var title: String
        public var items: [String]
    }

    public struct Release: Hashable, Sendable {
        public var version: String
        public var sections: [Section]
    }

    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    /// Newest first, as baked. A release with nothing user-facing is not here.
    public static let releases: [Release] = {
        guard let url = Bundle.main.url(forResource: "WhatsNew", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }()

    private static let seenKey = "WhatsNew.lastSeenVersion"

    /// The releases newer than `seen`, up to the running one. Nothing seen yet
    /// — a fresh install, or the first upgrade to a version with this sheet —
    /// shows the running release alone rather than the whole baked history.
    public static func releases(after seen: String?, in all: [Release] = releases, current: String = version) -> [Release] {
        guard let seen else { return all.filter { $0.version == current } }
        return all.filter {
            $0.version.compare(seen, options: .numeric) == .orderedDescending
                && $0.version.compare(current, options: .numeric) != .orderedDescending
        }
    }

    /// What to show at launch, if anything: the version last seen before this
    /// one. Marks this one seen as it answers, so quitting with the sheet up
    /// does not show it again.
    public static func takeUnseen(_ defaults: UserDefaults = .standard, in all: [Release] = releases,
                                  current: String = version) -> (show: Bool, seen: String?) {
        let seen = defaults.string(forKey: seenKey)
        guard !all.isEmpty, seen != current else { return (false, seen) }
        defaults.set(current, forKey: seenKey)
        return (!releases(after: seen, in: all, current: current).isEmpty, seen)
    }

    /// GitHub's generated-notes markdown, one body per `# vX.Y.Z` line, cut down
    /// to what a user reads: the `###` categories `.github/release.yml` defines
    /// and their bullets, minus the " by @author in <PR url>" tail — a PR link
    /// means nothing to someone who cannot see the repo. "New Contributors" and
    /// "Full Changelog" go too.
    public static func parse(_ markdown: String) -> [Release] {
        var releases: [Release] = []
        var skipping = false
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") {
                let tag = line.dropFirst(2)
                releases.append(Release(version: String(tag.hasPrefix("v") ? tag.dropFirst() : tag), sections: []))
                skipping = false
            } else if line.hasPrefix("## ") {
                skipping = line == "## New Contributors"
            } else if skipping || releases.isEmpty {
                continue
            } else if line.hasPrefix("### ") {
                releases[releases.count - 1].sections.append(Section(title: String(line.dropFirst(4)), items: []))
            } else if line.hasPrefix("* ") || line.hasPrefix("- ") {
                let item = String(line.dropFirst(2))
                    .replacingOccurrences(of: #" by @\S+ in \S+$"#, with: "", options: .regularExpression)
                // A release from before .github/release.yml has no categories.
                if releases[releases.count - 1].sections.isEmpty {
                    releases[releases.count - 1].sections.append(Section(title: "", items: []))
                }
                releases[releases.count - 1].sections[releases[releases.count - 1].sections.count - 1].items.append(item)
            }
        }
        return releases.compactMap { release in
            let sections = release.sections.filter { !$0.items.isEmpty }
            return sections.isEmpty ? nil : Release(version: release.version, sections: sections)
        }
    }

    /// Inline markdown only, links dropped: a PR title is anyone's text, and a
    /// live link here would open without going through `TerminalLink`.
    public static func text(_ item: String) -> AttributedString {
        var text = (try? AttributedString(markdown: item, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(item)
        text.link = nil
        return text
    }

    public static func demo() {
        let body = """
        # v0.0.97
        <!-- Release notes generated using configuration in .github/release.yml at main -->

        ## What's Changed
        ### New
        * Send PR links to `MergeRight` by @afitzgerald in https://github.com/o/r/pull/99
        ### Fixed
        * Keep a held delete key repeating by @someone-else in https://github.com/o/r/pull/97
        ### Empty
        ## New Contributors
        * @someone-else made their first contribution in https://github.com/o/r/pull/97

        **Full Changelog**: https://github.com/o/r/compare/v0.0.96...v0.0.97

        # v0.0.96
        ## What's Changed

        # v0.0.10
        ## What's Changed
        * One by @a in https://x/1
        """
        let all = parse(body)
        assert(all == [
            Release(version: "0.0.97", sections: [
                Section(title: "New", items: ["Send PR links to `MergeRight`"]),
                Section(title: "Fixed", items: ["Keep a held delete key repeating"]),
            ]),
            // 0.0.96 was all `internal`, so it is not here.
            Release(version: "0.0.10", sections: [Section(title: "", items: ["One"])]),
        ])
        assert(parse("* before any version\n**Full Changelog**: https://x").isEmpty)

        // Numeric, not lexical: 0.0.10 is newer than 0.0.9.
        assert(releases(after: "0.0.9", in: all, current: "0.0.97").map(\.version) == ["0.0.97", "0.0.10"])
        assert(releases(after: "0.0.10", in: all, current: "0.0.97").map(\.version) == ["0.0.97"])
        assert(releases(after: nil, in: all, current: "0.0.97").map(\.version) == ["0.0.97"])
        // An all-internal running release has nothing to say to a new install.
        assert(releases(after: nil, in: all, current: "0.0.96").isEmpty)

        // The launch check marks the running version seen as it answers, so the
        // sheet shows once per upgrade — and a local build, with no notes baked
        // in, neither shows it nor marks anything.
        let suite = "moomux.selftest.whatsnew.\(getpid())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        assert(takeUnseen(defaults, in: [], current: "0.0.97") == (false, nil))
        assert(defaults.string(forKey: seenKey) == nil, "a build with no notes marks nothing seen")
        assert(takeUnseen(defaults, in: all, current: "0.0.97") == (true, nil), "a fresh install sees its release")
        assert(takeUnseen(defaults, in: all, current: "0.0.97") == (false, "0.0.97"), "and only once")
        assert(takeUnseen(defaults, in: all, current: "0.0.96") == (false, "0.0.97"),
               "a release with nothing user-facing is marked seen but not shown")
        defaults.set("0.0.9", forKey: seenKey)
        assert(takeUnseen(defaults, in: all, current: "0.0.97") == (true, "0.0.9"))

        assert(text("See [docs](file:///etc/passwd) and `code`").link == nil)
        assert(String(text("See [docs](https://x) now").characters) == "See docs now")
    }
}

public struct WhatsNewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let releases: [WhatsNew.Release]

    public init(releases: [WhatsNew.Release]) { self.releases = releases }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(releases.count == 1 ? "What's New in \(releases[0].version)" : "What's New")
                .font(.title2.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(releases, id: \.version) { release in
                        VStack(alignment: .leading, spacing: 10) {
                            if releases.count > 1 {
                                Text(release.version).font(.title3.bold()).foregroundStyle(.secondary)
                            }
                            ForEach(Array(release.sections.enumerated()), id: \.offset) { _, section in
                                VStack(alignment: .leading, spacing: 6) {
                                    if !section.title.isEmpty { Text(section.title).font(.headline) }
                                    // By position: two PRs can share a title.
                                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                                        Label {
                                            Text(WhatsNew.text(item))
                                        } icon: {
                                            Text("•").foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
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
        .frame(width: 440)
        .frame(minHeight: 180, maxHeight: 480)
        #else
        .presentationDetents([.medium, .large])
        #endif
    }
}
