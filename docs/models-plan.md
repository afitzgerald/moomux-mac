# Models, thinking levels and hidden models: plan

The wire contract is the core session's (`make-moomux-auto-install`). This file is only how
this repo implements it. The contract wins on anything that crosses the socket.

- **Wire** (`Core/Models.swift`): `AgentOption.modelNames` / `modelThinking`, `Snapshot.agents`
  (nil = keep the last table), `Config.excludedModels`. `MoomuxClient.setModelExcluded`. Projects
  have no model (moomux main 1be7c3c), so nothing here reads or sends one.
- **Table** (`AppState`): seeded by `AgentOptions` at connect, replaced by each snapshot's
  `agents`. `models(for:)`, `modelLabel`, `thinking(for:model:)`, `modelRows`. No list is
  written down on this side and no agent falls back to another's.
- **Forms** (`App/Forms.swift`, pure): choices kept by value. `clampChoices` resets on an agent
  or model change and keeps (as `extraModel`) on a table or hidden-list change.
- **UI**: display names in both apps' model pickers. Settings → General → Hidden models opens a
  list of per-model toggles that save at once.
- **Also here, though outside the contract** (moomux main 1be7c3c): New Session presets the agent
  from `Config.last_agent` on both apps. The per-session skip-permissions and the `prompt_agent`
  flow are gone, and so is the project sheet's Agent picker. `Project.agent` / `promptAgent` are
  carried through unedited for older cores.
- **Tests**: `demo()` asserts in `Wire`, `MoomuxClient`, `NewSessionForm`, `ProjectForm` and
  `AppState`, run by `make selfcheck`. A live check ran against the branch core on a scratch
  socket, with a hand-written `models.json` changed while a sheet was open.
