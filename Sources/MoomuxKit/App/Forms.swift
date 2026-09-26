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
    /// Empty means "not chosen yet", which only happens for a project with
    /// `prompt_agent` set — and blocks Create until the user picks one.
    public var agent = ""
    public var dangerous = false
    /// The selected entry from the agent's model list. "default" passes no
    /// `--model` flag at all.
    public var model = defaultChoice
    /// The free-text model for an agent with no list worth offering
    /// (opencode). Kept apart from `model` so switching agents back and forth
    /// does not lose either one.
    public var modelText = ""
    public var thinking = defaultChoice
    public var ticket = ""
    public var pr = ""
    public var prompt = ""
    /// Press Enter after typing the prompt. Starts at the config's
    /// `auto_submit_default` and is changed per session under More options —
    /// never written back, so one session's choice is not the next one's.
    public var autoSubmit = false
    /// What `applyProjectDefaults` last chose, so `agentNamesChanged` can tell
    /// a value the user picked from one it seeded.
    private var seededAgent = ""
    private var seededDangerous = false
    /// The project's base branch as last filled in, so switching project
    /// replaces it only while the user has not typed over it.
    private var seededBaseBranch = ""

    /// The one string that means "pass nothing" in both the model and thinking
    /// lists. It is the core's spelling, not ours — see `agentOptionsTable`.
    public static let defaultChoice = "default"

    public init() {}

    /// Seeds the agent controls from the chosen project, exactly as
    /// `newFormApplyProjectDefaults` does.
    ///
    /// The `prompt_agent` branch is the subtle one: a project that insists on
    /// an explicit agent every time gets *no* preselection **and no inherited
    /// `dangerous`** — the TUI only copies `p.Dangerous` in the else branch.
    /// Inheriting it there would arm `--dangerously-skip-permissions` for an
    /// agent the user has not chosen yet.
    public mutating func applyProjectDefaults(_ p: Project?, agentNames: [String]) {
        guard let p else {
            agent = ""
            dangerous = false
            return
        }
        if p.promptAgent {
            agent = ""
            dangerous = false
        } else {
            // An agent the core no longer offers would leave the picker with no
            // valid selection; claude is the TUI's fallback too.
            agent = agentNames.contains(p.agentName) ? p.agentName : (agentNames.first ?? "claude")
            dangerous = p.dangerous
        }
        seededAgent = agent
        seededDangerous = dangerous
    }

    /// The core's agent table arrived or changed under an open form — it lands
    /// one round trip after the window, so a form opened in that gap was
    /// seeded against the fallback table. Re-seed only if the user has not
    /// touched the agent controls: a late table must never flip a choice they
    /// made, least of all the dangerous flag. A chosen agent the table no
    /// longer offers is cleared rather than replaced, which blocks Create until
    /// they pick again instead of silently choosing for them.
    public mutating func agentNamesChanged(_ p: Project?, agentNames: [String]) {
        if agent == seededAgent && dangerous == seededDangerous {
            applyProjectDefaults(p, agentNames: agentNames)
        } else if !agent.isEmpty && !agentNames.contains(agent) {
            agent = ""
        }
    }

    /// Fills the base branch in with the project's own, so it can be edited
    /// rather than guessed at from a placeholder — unless the user has already
    /// typed one, which a project switch must not silently undo. Not part of
    /// `applyProjectDefaults`, which a late agent table re-runs.
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

    /// Only a new branch is cut from the base, so a resume sends none.
    public var baseBranchToSend: String { existingBranch.isEmpty ? baseBranch : "" }

    /// Keeps the model and thinking selections valid after the agent changes:
    /// the lists differ per agent, and a stale selection would be sent as a
    /// flag value the new agent has never heard of.
    public mutating func clampChoices(models: [String], thinking: [String]) {
        if !models.isEmpty, !models.contains(model) { model = models.first ?? Self.defaultChoice }
        if !thinking.isEmpty, !thinking.contains(self.thinking) {
            self.thinking = thinking.first ?? Self.defaultChoice
        }
    }

    /// What to send as the model: the free-text field for an agent with no
    /// list, the picked entry otherwise. `internal/tui/update.go` makes exactly
    /// this swap on `agent != "opencode"`, keyed off the list being empty here
    /// so a future agent without models needs no change.
    public func modelToSend(hasModelList: Bool) -> String {
        hasModelList ? model : modelText
    }

    /// Every field but the project is optional: an empty name is the core's
    /// to fill — from the branch, else the prompt, else an assigned one — so
    /// only a `prompt_agent` project blocks, until an agent is chosen.
    public var canCreate: Bool {
        !project.isEmpty && !agent.isEmpty
    }

    public static func demo() {
        let names = ["claude", "codex", "opencode"]
        var form = NewSessionForm()
        form.project = "moomux"

        // An ordinary project preselects its agent and inherits its dangerous flag.
        form.applyProjectDefaults(
            Project(repo: "/src", agent: "codex", dangerous: true), agentNames: names)
        assert(form.agent == "codex")
        assert(form.dangerous, "a dangerous project's sessions are dangerous by default")

        // prompt_agent forces a choice — and must not carry the flag over with
        // no agent chosen to apply it to.
        form.applyProjectDefaults(
            Project(repo: "/src", agent: "codex", dangerous: true, promptAgent: true),
            agentNames: names)
        assert(form.agent.isEmpty, "prompt_agent means no preselection")
        assert(!form.dangerous, "dangerous must not be inherited without an agent")
        assert(!form.canCreate, "no agent chosen yet")
        form.agent = "claude"
        form.name = "x"
        assert(form.canCreate)

        // An unset agent is claude, and an agent the core dropped falls back
        // rather than leaving the picker on a value that cannot be selected.
        form.applyProjectDefaults(Project(repo: "/src"), agentNames: names)
        assert(form.agent == "claude")
        form.applyProjectDefaults(Project(repo: "/src", agent: "gone"), agentNames: names)
        assert(form.agent == "claude")


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
        base.seedBaseBranch(Project(repo: "/b", baseBranch: "develop"))
        assert(base.baseBranch == "develop", "untouched, it follows the project")
        base.baseBranch = "release/2"
        assert(base.baseBranchEdited)
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
        switching.clampChoices(models: ["default", "gpt"], thinking: ["default", "high"])
        assert(switching.model == "default" && switching.thinking == "default")
        // A valid selection survives.
        switching.model = "gpt"
        switching.clampChoices(models: ["default", "gpt"], thinking: ["default", "high"])
        assert(switching.model == "gpt")
        // An agent with no model list keeps whatever the picker had — its
        // control is the text field, and that is what gets sent.
        switching.clampChoices(models: [], thinking: ["default"])
        assert(switching.model == "gpt")
        switching.modelText = "anthropic/claude-x"
        assert(switching.modelToSend(hasModelList: false) == "anthropic/claude-x")
        assert(switching.modelToSend(hasModelList: true) == "gpt")

        // A table arriving late re-seeds an untouched form: seeded against the
        // fallback ["claude"], a codex project gets codex once the real one lands.
        let codexProject = Project(repo: "/src", agent: "codex", dangerous: true)
        var late = NewSessionForm()
        late.applyProjectDefaults(codexProject, agentNames: ["claude"])
        assert(late.agent == "claude")
        late.agentNamesChanged(codexProject, agentNames: names)
        assert(late.agent == "codex" && late.dangerous)
        // ...but never overrides a choice, and never re-arms dangerous.
        late.agent = "opencode"
        late.dangerous = false
        late.agentNamesChanged(codexProject, agentNames: names)
        assert(late.agent == "opencode" && !late.dangerous, "a late table must not undo the user")
        // A chosen agent the table dropped is cleared, which blocks Create.
        late.name = "x"
        late.project = "moomux"
        late.agentNamesChanged(codexProject, agentNames: ["claude", "codex"])
        assert(late.agent.isEmpty && !late.canCreate && !late.dangerous)
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
    /// Empty means claude (the core's own default at rest).
    public var agent = ""
    /// The TUI's "ask each time" agent entry: `prompt_agent`, which makes the
    /// agent row of every new-session form start unset.
    public var askAgent = false
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
