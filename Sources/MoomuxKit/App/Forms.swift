import Foundation

/// The state behind the two forms that ask more than one question, and the
/// rules that decide what they send.
///
/// Pure and here rather than in `@State` next to the controls, because these
/// rules are not the app's to invent: every one of them mirrors a specific
/// piece of `internal/tui`, and a front end that gets one wrong produces
/// sessions and projects that behave differently from the same fields typed
/// into the TUI. Being pure is what lets `demo()` pin them.

// MARK: - New session

/// Mirrors the TUI's new-session form. The picker *contents* come from the
/// core (`AppState.agentNames` / `models(for:)` / `thinking(for:)`); what lives
/// here is which of them is chosen and how the project's config seeds it.
public struct NewSessionForm: Equatable, Sendable {
    public var project = ""
    public var name = ""
    /// A branch that already exists, to resume rather than cut. With no name,
    /// the core names the session after it.
    public var existingBranch = ""
    /// Empty means the project's own base branch.
    public var baseBranch = ""
    /// Starts on the config's `last_agent`, the agent the last session was
    /// created with — one global value, not the project's. Empty only until
    /// that preset runs, and it blocks Create.
    public var agent = ""
    /// The selected entry from the agent's model list. "default" passes no
    /// `--model` flag at all.
    public var model = defaultChoice
    /// The free-text model for an agent with no list worth offering
    /// (opencode). Kept apart from `model` so switching agents back and forth
    /// does not lose either one.
    public var modelText = ""
    /// A chosen model that a new table or a hidden-models change dropped from
    /// the shown list. Offered right after "default" for `extraAgent` only,
    /// and sent as-is.
    public private(set) var extraModel = ""
    private var extraAgent = ""
    public var thinking = defaultChoice
    public var ticket = ""
    public var pr = ""
    public var prompt = ""
    /// Press Enter after typing the prompt. Starts at the config's
    /// `auto_submit_default` and is changed per session under More options —
    /// never written back, so one session's choice is not the next one's.
    public var autoSubmit = false
    /// What `presetAgent` last chose, so a re-run can tell a value the user
    /// picked from one it seeded — and whether that was the agent it was
    /// asked for or only a fallback.
    private var seededAgent = ""
    private var seedSettled = false
    /// The project's base branch as last filled in, so switching project
    /// replaces it only while the user has not typed over it.
    private var seededBaseBranch = ""

    /// The one string that means "pass nothing" in both the model and thinking
    /// lists. It is the core's spelling, not ours — see `agentOptionsTable`.
    public static let defaultChoice = "default"

    public init() {}

    /// Presets the agent from `lastAgent` (the config's `last_agent`; nil
    /// while no config has arrived), as `internal/tui` opens its form. Re-run
    /// when the table or the config arrives late, it moves the agent only
    /// while the first preset was a fallback and the user has not picked one,
    /// or when the table no longer offers it. A `last_agent` written by a
    /// create elsewhere must not flip a sheet someone is typing into. Model
    /// and thinking are never remembered: a fresh form starts both on
    /// "default".
    public mutating func presetAgent(_ lastAgent: String?, agentNames: [String]) {
        let retry = agent.isEmpty || (agent == seededAgent && !seedSettled)
        guard retry || !agentNames.contains(agent) else { return }
        let want = lastAgent ?? ""
        agent = agentNames.contains(want) ? want : (agentNames.first ?? want)
        seededAgent = agent
        seedSettled = lastAgent != nil && agent == want
    }

    /// Fills the base branch in with the project's own, so it can be edited
    /// rather than guessed at from a placeholder — unless the user has already
    /// typed one, which a project switch must not silently undo.
    public mutating func seedBaseBranch(_ p: Project?) {
        let value = p?.isPlain == false ? p?.baseBranch ?? "" : ""
        if baseBranch == seededBaseBranch { baseBranch = value }
        seededBaseBranch = value
    }

    /// The base branch differs from what the project filled in.
    public var baseBranchEdited: Bool { baseBranch != seededBaseBranch }

    /// What the Name field shows when empty: where the core will get one.
    public var namePlaceholder: String {
        if !existingBranch.isEmpty { return "from the branch" }
        return prompt.trimmed.isEmpty ? "assigned" : "from the prompt"
    }

    /// Adds an attached file's path to the end of the prompt, spaced off
    /// whatever is there, the way a file dropped on a terminal lands.
    public mutating func appendPath(_ path: String) {
        let lead = prompt.last.map { $0.isWhitespace ? "" : " " } ?? ""
        prompt += lead + path + " "
    }

    /// Only a new branch is cut from the base, so a resume sends none. Nor
    /// does an untouched field: empty means the project's own, which the core
    /// reads fresh — and when that one has gone stale, its refusal then says
    /// to fix the project's settings rather than this field.
    public var baseBranchToSend: String { existingBranch.isEmpty && baseBranchEdited ? baseBranch : "" }

    /// The model picker's entries: `shown` (the agent's list minus hidden
    /// models) with the extra model right after "default" —
    /// `newFormModelChoices`.
    public func modelChoices(_ shown: [String]) -> [String] {
        guard !extraModel.isEmpty, extraAgent == agent, !shown.isEmpty, !shown.contains(extraModel)
        else { return shown }
        return [shown[0], extraModel] + shown.dropFirst()
    }

    /// Keeps the model and thinking selections valid by value, never by index.
    /// After the agent or the model changes (`keep` false), a model the
    /// choices lack becomes "default". After the table or the hidden list
    /// changes (`keep` true), it stays chosen as the extra entry instead —
    /// `restoreFormSelection`. Thinking is per model: a level the model's list
    /// lacks becomes "default".
    public mutating func clampChoices(models shown: [String], thinking: (String) -> [String],
                                      keep: Bool = false) {
        if !shown.isEmpty, !modelChoices(shown).contains(model) {
            if keep && model != Self.defaultChoice {
                extraModel = model
                extraAgent = agent
            } else {
                model = Self.defaultChoice
            }
        }
        let levels = thinking(model)
        if !levels.isEmpty, !levels.contains(self.thinking) { self.thinking = Self.defaultChoice }
    }

    /// What to send as the model: the free-text field for an agent with no
    /// list, the picked entry otherwise. `internal/tui/update.go` makes exactly
    /// this swap on `agent != "opencode"`, keyed off the list being empty here
    /// so a future agent without models needs no change.
    public func modelToSend(hasModelList: Bool) -> String {
        hasModelList ? model : modelText
    }

    /// The core's refusal names the base branch the form sent, rather than the
    /// project's stale one (`baseBranchToSend` sends none for that). Matches
    /// the core's wording since moomux#329; an older core gets no highlight.
    public static func blamesBaseBranchField(_ error: String) -> Bool {
        error.contains("fix the base branch field")
    }

    /// Every field but the project is optional: an empty name is the core's
    /// to fill — from the branch, else the prompt, else an assigned one.
    public var canCreate: Bool {
        !project.isEmpty && !agent.isEmpty && promptProblem == nil
    }

    /// Long text belongs in an attached file, which the agent reads, not in
    /// the prompt: it is typed into the agent's pane, and the phone's editor
    /// was killed by the watchdog laying out a long one.
    public static let promptLimit = 4000

    public var promptProblem: String? {
        prompt.count <= Self.promptLimit ? nil
            : "The prompt is \(prompt.count) characters; the limit is \(Self.promptLimit). Attach long text as a file."
    }

    public static func demo() {
        let names = ["claude", "codex", "opencode"]
        var form = NewSessionForm()
        form.project = "moomux"

        // The agent is the last one used, whatever the project.
        assert(!form.canCreate, "no agent until the preset runs")
        form.presetAgent("codex", agentNames: names)
        assert(form.agent == "codex")
        // An agent the core no longer offers falls back to the table's first.
        var gone = NewSessionForm()
        gone.presetAgent("agy", agentNames: names)
        assert(gone.agent == "claude")
        form.agent = "claude"
        form.name = "x"
        assert(form.canCreate)
        form.prompt = String(repeating: "a", count: promptLimit)
        assert(form.canCreate && form.promptProblem == nil, "the limit itself is allowed")
        form.prompt += "a"
        assert(!form.canCreate && form.promptProblem != nil, "one over refuses")
        form.prompt = ""

        // No name is fine: the core names it, and the placeholder says from what.
        var unnamed = NewSessionForm()
        unnamed.project = "moomux"
        unnamed.agent = "claude"
        assert(unnamed.canCreate && unnamed.namePlaceholder == "assigned")
        unnamed.prompt = "Add dark mode"
        assert(unnamed.namePlaceholder == "from the prompt")
        unnamed.existingBranch = "alan/x"
        assert(unnamed.namePlaceholder == "from the branch")

        // An attached file lands at the end, one space either side.
        var attach = NewSessionForm()
        attach.appendPath("/t/a.png")
        attach.appendPath("/t/b.pdf")
        assert(attach.prompt == "/t/a.png /t/b.pdf ", attach.prompt)
        attach.prompt = "look at\n"
        attach.appendPath("/t/c.jpg")
        assert(attach.prompt == "look at\n/t/c.jpg ", attach.prompt)
        attach.prompt = "look at"
        attach.appendPath("/t/c.jpg")
        assert(attach.prompt == "look at /t/c.jpg ", attach.prompt)

        // The base branch follows the project until the user types over it.
        var base = NewSessionForm()
        base.seedBaseBranch(Project(repo: "/a", baseBranch: "main"))
        assert(base.baseBranch == "main" && !base.baseBranchEdited)
        assert(base.baseBranchToSend.isEmpty, "the project's own goes unsent: the core reads it fresh")
        base.seedBaseBranch(Project(repo: "/b", baseBranch: "develop"))
        assert(base.baseBranch == "develop", "untouched, it follows the project")
        base.baseBranch = "release/2"
        assert(base.baseBranchEdited && base.baseBranchToSend == "release/2")
        base.seedBaseBranch(Project(repo: "/a", baseBranch: "main"))
        assert(base.baseBranch == "release/2", "a typed base branch survives a project switch")
        base.seedBaseBranch(Project(kind: "plain", repo: "/p", baseBranch: "main"))
        assert(base.baseBranch == "release/2")
        var plain = NewSessionForm()
        plain.seedBaseBranch(Project(kind: "plain", repo: "/p", baseBranch: "main"))
        assert(plain.baseBranch.isEmpty, "a plain project has no branches")
        base.existingBranch = "alan/x"
        assert(base.baseBranchToSend.isEmpty, "resuming cuts nothing")

        // Switching agents must not carry a model the new one has never heard of.
        var switching = NewSessionForm()
        switching.model = "opus"
        switching.thinking = "ultrathink"
        switching.clampChoices(models: ["default", "gpt"], thinking: { _ in ["default", "high"] })
        assert(switching.model == "default" && switching.thinking == "default")
        // A valid selection survives.
        switching.model = "gpt"
        switching.clampChoices(models: ["default", "gpt"], thinking: { _ in ["default", "high"] })
        assert(switching.model == "gpt")
        // A model dropped from the list (hidden, or gone from a new table)
        // falls back to "default", not to whatever sat at its index.
        switching.clampChoices(models: ["default", "o3", "o4"], thinking: { _ in ["default"] })
        assert(switching.model == "default")
        // Thinking follows the model: a level the new model has is kept, one it
        // lacks resets to "default".
        let perModel: (String) -> [String] = {
            ["big": ["default", "high", "max"], "small": ["default"]][$0] ?? ["default", "high"]
        }
        switching.model = "big"
        switching.thinking = "high"
        switching.clampChoices(models: ["default", "big", "small"], thinking: perModel)
        assert(switching.thinking == "high")
        switching.model = "default"
        switching.clampChoices(models: ["default", "big", "small"], thinking: perModel)
        assert(switching.thinking == "high", "the default model's list has it too")
        switching.model = "small"
        switching.clampChoices(models: ["default", "big", "small"], thinking: perModel)
        assert(switching.thinking == "default")
        // An agent with no model list keeps whatever the picker had — its
        // control is the text field, and that is what gets sent.
        switching.model = "gpt"
        switching.clampChoices(models: [], thinking: { _ in ["default"] })
        assert(switching.model == "gpt")
        switching.modelText = "anthropic/claude-x"
        assert(switching.modelToSend(hasModelList: false) == "anthropic/claude-x")
        assert(switching.modelToSend(hasModelList: true) == "gpt")

        // A table or hidden-list change keeps a chosen model that left the
        // list, as the extra entry, and keeps thinking by value.
        var kept = NewSessionForm()
        kept.agent = "claude"
        kept.model = "opus"
        kept.thinking = "high"
        kept.clampChoices(models: ["default", "sonnet"], thinking: { _ in ["default", "high"] }, keep: true)
        assert(kept.model == "opus" && kept.thinking == "high")
        assert(kept.modelChoices(["default", "sonnet"]) == ["default", "opus", "sonnet"])

        // A table or config arriving late re-presets a form whose first preset
        // was a fallback...
        var late = NewSessionForm()
        late.presetAgent("codex", agentNames: ["claude"])
        assert(late.agent == "claude")
        late.presetAgent("codex", agentNames: names)
        assert(late.agent == "codex")
        var noConfig = NewSessionForm()
        noConfig.presetAgent(nil, agentNames: names)
        assert(noConfig.agent == "claude")
        noConfig.presetAgent("codex", agentNames: names)
        assert(noConfig.agent == "codex", "the config's first answer still lands")
        // ...but a settled preset stays put when a create elsewhere moves
        // last_agent: the sheet is someone's half-typed session.
        noConfig.presetAgent("opencode", agentNames: names)
        assert(noConfig.agent == "codex", "a later last_agent must not flip an open sheet")
        // ...but never overrides a choice the table still offers.
        late.agent = "opencode"
        late.presetAgent("claude", agentNames: names)
        assert(late.agent == "opencode", "a late preset must not undo the user")
        late.presetAgent("claude", agentNames: ["claude", "codex"])
        assert(late.agent == "claude", "a picked agent the table dropped is re-preset")
    }
}

// MARK: - Project

/// Mirrors the TUI's new-project / edit-project forms.
///
/// Validation is deliberately only the half a client can check without the
/// core's config in hand: name shape, and that the two required fields are
/// filled. Everything else — the duplicate name, whether the path is a git
/// repo, whether a worktree-mode flip is safe — is the core's, and its refusal
/// is the message the user sees. Two validators would be two rules to drift.
public struct ProjectForm: Equatable, Sendable {
    public var name = ""
    public var repo = ""
    public var baseBranch = ""
    public var branchPrefix = ""
    /// Not edited here any more: the core keeps one global agent
    /// (`last_agent`) and a current core neither sends nor reads these. Carried
    /// through only so a save against an older core does not delete them —
    /// `UpdateProject` replaces the whole record. Delete with `Project.agent`.
    var agent = ""
    var askAgent = false
    public var dangerous = false
    public var noWorktree = false
    /// Empty means "auto" — the core picks a deterministic glyph.
    public var emoji = ""
    /// Display state the form does not edit but must not drop: `UpdateProject`
    /// replaces the whole project record, so a save that left these out would
    /// silently un-collapse it — or, against a core old enough to still serve
    /// a per-project folder table, delete that (see `Project.folders`).
    var folders: [String: FolderMeta]?
    var collapsed = false
    /// nil for a new project; the name being edited otherwise. Editing cannot
    /// change the name (the core keys projects by it), so the field is
    /// read-only there, and it cannot change the kind either.
    public var editing: String?

    public init() {}

    /// The edit form, seeded from what the core has.
    public init(editing name: String, _ p: Project) {
        self.editing = name
        self.name = name
        repo = p.repo
        baseBranch = p.baseBranch ?? ""
        branchPrefix = p.branchPrefix ?? ""
        agent = p.agent ?? ""
        askAgent = p.promptAgent
        dangerous = p.dangerous
        noWorktree = p.noWorktree
        emoji = p.emoji ?? ""
        folders = p.folders
        collapsed = p.collapsed
    }

    /// The `config.Project` to send. `kind` is never set from here: the core
    /// decides it (`AddProject` → "git", `AddPlainProject` → "plain") and
    /// `UpdateProject` keeps whatever the project already had.
    public var project: Project {
        Project(repo: repo.trimmed,
                branchPrefix: branchPrefix.trimmed.nilIfEmpty,
                baseBranch: baseBranch.trimmed.nilIfEmpty,
                agent: agent.nilIfEmpty,
                dangerous: dangerous,
                promptAgent: askAgent,
                noWorktree: noWorktree,
                emoji: emoji.trimmed.nilIfEmpty,
                folders: folders,
                collapsed: collapsed)
    }

    /// The typed name, else the repo folder's own, with whitespace turned
    /// into hyphens: "~/src/Gift Cards/" → "Gift-Cards". Editing keeps the
    /// name it has — the core has no rename.
    public var nameToSend: String {
        let typed = name.trimmed
        guard typed.isEmpty, editing == nil else { return typed }
        // NSString, not URL: `URL(fileURLWithPath:)` resolves "." against the
        // working directory, which is nothing to do with where the core runs.
        let folder = (repo.trimmed as NSString).lastPathComponent
        guard !repo.trimmed.isEmpty, !["/", "~", ".", ".."].contains(folder) else { return "" }
        return folder.split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }

    /// nil when the form is submittable, otherwise why it isn't. The strings
    /// match `validateProjectLocked`'s wording so the same mistake reads the
    /// same in both front ends.
    public var problem: String? {
        let name = nameToSend
        if name.isEmpty { return "project name required" }
        if name.contains(where: { " \t/\\".contains($0) }) {
            return "project name cannot contain spaces or slashes"
        }
        if repo.trimmed.isEmpty { return "repo path required" }
        return nil
    }

    public static func demo() {
        // No name: the repo folder names it.
        var derived = ProjectForm()
        assert(derived.nameToSend.isEmpty)
        derived.repo = "~/src/Gift Cards/"
        assert(derived.nameToSend == "Gift-Cards" && derived.problem == nil)
        for vague in ["~", ".", "..", "./"] {
            derived.repo = vague
            assert(derived.problem == "project name required", "\(vague) names nothing")
        }
        derived.name = "typed"
        assert(derived.nameToSend == "typed")

        var form = ProjectForm()
        assert(form.problem == "project name required")
        form.name = "my project"
        assert(form.problem == "project name cannot contain spaces or slashes")
        form.name = "a/b"
        assert(form.problem != nil, "a slash would make a bogus branch and path component")
        form.name = "moomux"
        assert(form.problem == "repo path required")
        form.repo = "  ~/src/moomux  "
        assert(form.problem == nil)
        // Whitespace is trimmed, not sent — a path with a trailing space is a
        // different path, and `~` is the core's to expand.
        assert(form.project.repo == "~/src/moomux")
        // An empty optional field must go over as absent, so the core's own
        // default applies rather than an empty string overwriting it.
        assert(form.project.baseBranch == nil)
        assert(form.project.branchPrefix == nil)
        assert(form.project.emoji == nil, #"empty emoji means "auto", not an empty glyph"#)
        assert(form.project.agent == nil)
        assert(form.project.kind == nil, "the kind is the core's to decide")

        // The edit form round-trips what the core has, including the two flags
        // that are easy to lose.
        let stored = Project(kind: "git", repo: "/src/x", branchPrefix: "alan/",
                             baseBranch: "develop", agent: "codex", dangerous: true,
                             promptAgent: true, noWorktree: true, emoji: "🐮",
                             folders: ["wip": FolderMeta(collapsed: true)], collapsed: true)
        let edit = ProjectForm(editing: "x", stored)
        assert(edit.editing == "x")
        assert(edit.askAgent && edit.dangerous && edit.noWorktree)
        assert(edit.emoji == "🐮" && edit.agent == "codex")
        var sent = edit.project
        sent.kind = stored.kind  // the only field the form drops
        assert(sent == stored, "editing and saving unchanged must send back what it was given")
    }
}

extension String {
    public var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    public var nilIfEmpty: String? { isEmpty ? nil : self }
}
