# pass70 owner C notes (service boundary)

Branch `p70/C`, worktree `/Users/zaali/dev/swarm-code-cli-wt/p70-C`.

## Landed

| task | status | commits |
| --- | --- | --- |
| C1 DTO + wire additions, fake parity | done, tag `p70-C-wire` = `89aa263` | 89aa263 |
| C2 approvals end to end | done: op-node admission, full card, five decisions (engine's own after A-sync), F11, mark_seen, mode + trust as operations | 5b98942, 68da489 |
| C3 conversations list/new/open, project.update, mark_seen | done | 4bfb4c4, 8ae724e |
| C4 rel F4 tripwires (daemon + client) | done | 8626a41 |
| C5 subscriptions (notifications, mcp, research, workflows, toast, waiting, rate limits) | done | 8ef394b |
| (merge) `p70-A-sync` | merged after tagging `p70-C-wire` | 09b353d |
| C6 HEAD projection fields | done: stop reasons, error kinds, labels, agent model, background commands (rate limits in C5) | f49a893 |
| C7 slash registry + dispatcher | done | a51de47 |
| C8 Full detail, run-scoped Changes with diffs, @path | done | a0377f3, d254bb3 |
| C10 `Domain.Tools.Path` in the persisted service | done | 47af032 |
| C9 incremental projection | not done (see Left) | — |
| socket acceptance for every new operation | done | 4b6208d |

(kept current; the table grows as tasks land)

## C1 contract (tag `p70-C-wire`) — for D and E

Every new DTO field has a wire default, so an older daemon (or a test map
without the key) still decodes. All new fields are optional/`nil` unless noted.
Names below are the Elixir struct fields; the JSON keys are the same words.

### Approval card — `DTO.Approval` (inside `PendingInteraction.approval`)

| field | type | meaning |
| --- | --- | --- |
| `tool` | text | op type, e.g. `run_command`, `edit_file` (existing) |
| `permission` | `:read \| :write \| :execute` | (`:read` is new) |
| `arguments_preview` | text | JSON of the call, bounded (existing) |
| `command` | text ≤ 4096 or nil | the shell command of a `run_command` |
| `cwd` | text ≤ 1024 or nil | `workdir` relative to the project root, `"."` for the root |
| `reason` | text ≤ 1024 or nil | the model's `justification` (why it wants this) |
| `command_family` | text ≤ 200 or nil | what `A` remembers (`"mix test"`); nil = offer no `A` |
| `classification` | `:safe \| :normal \| :dangerous \| :unknown` | `CommandSafety` class; `:unknown` before A-sync |
| `agent_id` / `agent_name` | id / text or nil | the agent that asks (`"worker-b"`, `"assistant"`) |
| `requested_at` | unix ms or nil | when it started waiting |
| `allowed_decisions` | list ⊆ `[:approve, :approve_run, :always_prefix, :deny, :deny_stop]` | what the service accepts for this request, in card order; `[]` from an old daemon = fall back to `PendingInteraction.allowed_actions` (`:approve`, `:deny`). Relation: `:always_prefix` is present only with a non-blank `command_family`. |

Key mapping (decision D4): `y` → `:approve`, `Y` → `:approve_run`, `A` →
`:always_prefix`, `d` → `:deny`, `D` → `:deny_stop`, `n` → next interaction
(client only). Only offer a key whose decision is in `allowed_decisions`.

### Resolving: request kind (my `Request`, not `Intent`)

```elixir
%Request{kind: {:resolve_approval, run_id, node_id, interaction_id, expected_revision, decision},
         origin: {:interaction, interaction_id, expected_revision}, expected_response: :outcome}
# decision ∈ :approve | :approve_run | :always_prefix | :deny | :deny_stop
#            (:always_allow is accepted as the legacy name of :approve_run)
```

`node_id` is the interaction's `node_id` (the **op** node). The service picks
the family for `:always_prefix` itself; the client never sends one.
`Request.validate/1` accepts the widened decisions directly, so this works
even before `Intent` learns them (E: please widen `Intent.validate/1`'s
`{:resolve_approval, …}` decision guard to the same set if the reducer
validates intents before building the request).

### Conversations

```elixir
# list (response :conversation_list → DTO.ConversationList)
%Request{kind: {:conversation_list, cursor_or_nil, page_size, byte_limit},
         origin: {:conversation, :list}, expected_response: :conversation_list}
# create + open (outcome identifiers: [new_conversation_id])
%Request{kind: {:conversation_new}, origin: {:conversation, :new}, expected_response: :outcome}
# open (outcome identifiers: [conversation_id])
%Request{kind: {:conversation_open, conversation_id}, origin: {:conversation, :open},
         expected_response: :outcome}
```

Scope: any of global / project / conversation (the shell's global scope is
fine). After an `:accepted` open/new the **service has switched** its current
conversation: the client re-scopes its workspace watch to
`{:conversation, new_id}` (new generation) and drops the old one; the shell
watch (global) is resynced by the service automatically (you get a normal
`watch_ready`). `conversation_new` = create **and** open.

`DTO.ConversationList`: `project` (name), `current_id`, `items`
(`[DTO.ConversationSummary]`), plus the usual page fields (`state`,
`before_cursor`, `after_cursor`, `request_id`, `error`, `presence`,
`covered_ids`, `through_sequence`). Newest first (`updated_at` desc).
Keyset: pass `after_cursor` back as `cursor` for the next page.

`DTO.ConversationSummary`: `id`, `title` (≤ 256 B), `created_at`,
`updated_at` (unix ms), `run_count`, `live` (boolean — the plan's `live?`),
`waiting` (count of requests waiting for a person), `unread` (boolean),
`current` (boolean, at most one per page).

### Runs, agents, tool calls, changes

- `DTO.RunSummary` + `stop_reason`, `error_kind`, `stop_label` (human label,
  e.g. `"turn limit"`, `"rate limit"`, `"stopped"`), `provider_name`,
  `retry_at` (unix ms). `model` already existed.
- `DTO.AgentSummary` + `model`, `provider_name`, `stop_reason`, `error_kind`,
  `stop_label`, `retry_at`.
- `DTO.ToolCall` + `added`, `removed` (line counts of an edit, nil when not an
  edit), `diff_ref` (`DTO.DetailRef`, id `"<op_node_id>:diff"`), `exit_code`
  (0..255 or nil), `background` (boolean, the command was handed to the
  background).
- `DTO.Change` + `op_id`, `file_state` (`:created | :modified | :deleted |
  :unknown`), `added`, `removed`, `diff_ref` (id `"<checkpoint_id>:diff"`).

Diffs load with the existing detail query, no new operation:
`{:query_detail, diff_ref.id, offset, bytes}` / `origin: {:query, :detail}` /
`:detail_window`. The text is a unified diff (`--- a/…`, `+++ b/…`, `@@`).

### Workspace and shell snapshots

`DTO.WorkspaceSnapshot` and `DTO.WorkspaceMetadata` (the `workspace_metadata`
delta merges into the snapshot) + `approval_mode` (`:read_only | :auto |
:full_access`), `trusted` (boolean, nil when the domain has no trust yet),
`chat_provider` (provider name of `chat_model`), `context_used` /
`context_window` (tokens, the status-line gauge), `cost_usd` (conversation
total), `title` (conversation title). The snapshot alone also has
`background: [DTO.BackgroundCommand]` for its runs.

`DTO.ShellSnapshot` + `rate_limits: [DTO.RateLimit]`.

`DTO.BackgroundCommand`: `id`, `run_id`, `agent_id`, `pid` (OS pid), `command`
(≤ 512 B), `cwd`, `state` (`:running | :exited | :killed | :unknown`),
`exit_code`, `started_at`, `output_bytes`, `revision`.

`DTO.RateLimit`: `provider_id`, `provider` (name), `scope` (`"requests"`,
`"tokens"`, …), `used_percent` (0..100 float), `resets_at`, `retry_at` (unix ms
or nil), `revision`.

### New delta kinds (E: `ReadModel.delta/3` must handle them)

| kind | body | watch | envelope |
| --- | --- | --- | --- |
| `:toast` | `DTO.Toast` | shell only | `entity_id` = toast id |
| `:rate_limit` | `DTO.RateLimit` | shell only | `entity_id` = `provider_id`, `run_id` nil |
| `:background_upsert` | `DTO.BackgroundCommand` | workspace / run inspector | `entity_id` = id, `run_id` = its run |
| `:background_remove` | nil | workspace / run inspector | `entity_id`, `run_id` |

`DTO.Toast`: `id`, `level` (`:info | :success | :waiting | :warning |
:error`), `title` (≤ 200 B), `text` (≤ 1 KiB), `run_id`, `conversation_id`
(what it is about; may be another conversation, e.g. "waiting for you"
elsewhere), `at` (unix ms), `revision`. Toasts have no snapshot.

**Request to E (important):** `ReadModel.delta/3` has no catch-all today, so an
unknown delta kind is a `FunctionClauseError` in the reducer. Please add
clauses for the four kinds above **and** a final catch-all
`def delta(model, _slot, %Delta{}), do: {:ok, model, [], []}` so a newer daemon
never crashes an older reducer. `workspace_metadata` arriving on a non-
workspace slot also has no clause.

### Project approval mode and trust

```elixir
%Request{kind: {:project_update, approval_mode_or_nil, trusted_or_nil},
         origin: {:project, :update}, expected_response: :outcome}
# approval_mode ∈ nil | :read_only | :auto | :full_access; trusted ∈ nil | true
# at least one non-nil. Trusting a read_only project lifts it to :auto
# (desktop Projects.trust/1). Any scope but a run's.
```

The service answers `:accepted` with a notice feedback, publishes a
`workspace_metadata` delta with the new `approval_mode`/`trusted`, and a
`toast`.

### Seen marks

The existing intent `{:mark_seen, kind, id, revision}` (kind `:conversation |
:run | :activity`, origin `{:seen, kind, id, revision}`) now has a wire body
(`"mark_seen"`); any scope.

### `@path` completion (C8)

`{:feature_query, :files, query_text, nil, 20, 65_536}` with origin
`{:feature, :files}` → `DTO.LibrarySnapshot{feature: :files}`; each item's
`id`/`title` is a project-relative path, `matches` (new, `LibraryItem`) the
grapheme indices of `title` the query matched. `:files` was added to the
feature enums (`Request`, `LibrarySnapshot`, `Feedback`).

### Expected-response `:conversation_list` (E: effect runner)

`EffectRunner.error_body/3` needs a clause:
`:conversation_list -> struct!(DTO.ConversationList, attrs)` — admission
failures otherwise hit a `CaseClauseError`. (Both data sources already build
this failure body themselves.)

### Wire ops (core `ServiceRequest`) and capabilities

| wire op | atom | params | capability |
| --- | --- | --- | --- |
| `conversation.list` | `:conversation_list` | `cursor`, `page_size`, `byte_limit` | `conversation.list` |
| `conversation.new` | `:conversation_new` | none | `conversation.new` |
| `conversation.open` | `:conversation_open` | `conversation_id` (scope relaxed to global/project/conversation) | `conversation.open` |
| `mark_seen` | `:mark_seen` | `kind`, `id`, `revision` | `mark_seen` |
| `project.update` | `:project_update` | `approval_mode`, `trusted` | `project.update` |
| `approval.resolve` | — | `decision` ∈ `approve approve_run always_prefix deny deny_stop` | — |
| `feature.query` | — | `feature` may be `files` | — |

### Fake data source

`Fake.Session` (new) holds the synthetic session facts: two conversations
(`Authentication review` = a, current; `Session storage research` = b),
`approval_mode: :auto`, `trusted: true`, a running background command on run
a2, an `llmotions` rate-limit window at 62 %. The catalogue approval carries a
full card (`mix test …`, family `mix test`, all five decisions). The edit tool
item and the checkpoints carry line counts and `diff_ref`s whose details load.
`conversation_new/open`, `project_update` (metadata delta + toast),
`:always_prefix` (toast) and `:deny_stop` (run stops) all work.

### Conversation switch semantics (C3, for D and E)

- One persisted service serves one conversation at a time; `conversation.open`
  / `conversation.new` switch it. After the `:accepted` outcome:
  - watches in **global/project** scope (the shell) get `snapshot_required`
    (reason `epoch_changed`); the client data source re-watches them itself
    (fresh wire ref, same UI ref, `:resyncing` delivery first, then a normal
    `:watch_ready`). Nothing for the reducer to do but render `:resyncing`.
  - watches in the **old conversation's** scope go silent (their scope is no
    longer a member). The reducer must unwatch them and watch
    `{:conversation, new_id}` with a new generation. Queries against the old
    conversation are answered `not_allowed`.
- The status-line facts ride on `workspace_metadata`: `approval_mode`,
  `trusted` (nil before A-sync), `chat_provider`, `context_used` (newest model
  call's input tokens), `context_window` (the harness's trim budget for the
  chat model, i.e. where history starts being dropped), `cost_usd`
  (conversation total), `title`.
- `project.update` answers `:accepted` with a `notice` feedback, broadcasts a
  `workspace_metadata` delta and a `toast` (shell watch only).
- `mark_seen`: `conversation` must be the open one; `run`/`activity` a run of
  it. Not ledgered (idempotent).

### Reliability (C4)

- A request that times out (30 s default deadline now, client and service),
  crashes or answers untyped fails **alone**: reads get an error frame
  (`deadline_expired` / `source_unavailable`), commands an `outcome_unknown`
  result with `corrective_action: refresh`, watches `snapshot_required`. The
  connection stays open.
- A watch queue overflow → `snapshot_required` (reason `overflow`) → client
  re-watch; never a close.

### Subscriptions (C5, for D and E)

Everything below reaches the **shell** watch only, as `toast` or `rate_limit`
deltas (see the C1 table):

| source | delta |
| --- | --- |
| `Notifications.notify_finished/1` | toast `:success`, title "Finished" |
| `Notifications.notify/1` | toast `:info` |
| ui `{:toast, text}` (watchdog "Workflow … resumed") | toast `:info` |
| ui `{:waiting_changed}` when **another** conversation starts waiting | toast `:waiting`, title "Waiting for you", `conversation_id` + `run_id` set, text "<title> needs an approval/an answer" (once per conversation until it stops waiting) |
| ui `{:rate_limit, provider_id, snapshot}` (synced LLM.HTTP) | `rate_limit` delta; the shell snapshot's `rate_limits` holds the last per provider |
| mcp `{:mcp_status, id, {:error, _}}` / later `:ready` | toast `:warning` "MCP server failed" once / `:success` "MCP server ready" |
| ui research/workflow run changes | projection refresh (no delta of their own) |

### HEAD projection fields (C6)

- `RunSummary` / `AgentSummary`: `stop_reason` (an `LLM.Error` orchestration
  reason: `user_stopped`, `turn_budget`, `doom_loop`, `spawn_timeout`, …),
  `error_kind` (a provider error kind: `rate_limit`, `context_overflow`, …),
  `stop_label` (the desktop chip text: "turn limit", "rate limit", "stopped",
  …). A stopped run with no kind is `user_stopped`/"stopped".
- `AgentSummary.model`: the model the RunServer put on the node (virtual, from
  `nodes_upsert`); nil until the service has seen the agent start.
  `provider_name`/`retry_at` stay nil (not recorded by the domain).
- `WorkspaceSnapshot.background` + `background_upsert` / `background_remove`
  deltas (workspace and inspector watches): what `Tools.BackgroundProcs` lists
  for the projected runs; id `"<run_id>:<os_pid>"`, `state: :running`,
  `exit_code`/`cwd`/`agent_id` nil, `output_bytes` 0. Rechecked every 5 s
  while any is listed (the table has no events). Needs B6's runtime child;
  empty without it.

### Slash commands (C7, for E)

`SwarmCode.Commands` gains `new`, `clear`, `resume [conversation]`,
`resume-run` (the old `/resume`), `approval [read-only|auto|full]`, `trust`,
`diff`, `cost`, `search <words>`, `export [file]`, `agents`, `help`, `quit`.
`Commands.client?/1` and a `client: true` key on catalogue entries and parse
results mark what the terminal should do itself:

| command | parse action | client? | the reducer should | the service (if sent anyway) |
| --- | --- | --- | --- | --- |
| `/new`, `/clear` | `:new_conversation` | yes | send `{:conversation_new}` and re-scope to the outcome's id | creates + switches; outcome `identifiers: [id]`, feedback navigate `:conversations` |
| `/resume` | `:select_conversation` | yes | open the conversation picker (`{:conversation_list, …}`) | feedback navigate `:conversations`, identifiers `[]` |
| `/resume <x>` | `:open_conversation` (`conversation: x`) | **no** (`client: false`) | send it | id / id prefix (≥ 4) / title words in this project → switches; `identifiers: [id]`, navigate `:conversations`; else rejected |
| `/diff` | `:show_changes` | yes | open Changes (`{:feature_query, :changes, …}` in the conversation scope) | feedback navigate `:changes` |
| `/help` | `:help` | yes | show its own help | report "Commands" (every entry, `/name args — desc`) |
| `/quit` | `:quit` | yes | quit | rejected (`client_only` → `not_allowed`) |
| `/approval` | `:show_approval` | no | send | report: mode, trust, what it means, remembered families |
| `/approval <m>` | `:set_approval` | no | send (or `{:project_update, m, nil}`) | notice "Approval mode: …", metadata delta, toast |
| `/trust` | `:trust_project` | no | send (or `{:project_update, nil, true}`) | notice, metadata delta, toast |
| `/cost` | `:show_cost` | no | send | report: total and per model |
| `/search <w>` | `:search` | no | send | report: this project's conversations whose messages match (FTS), each with a `/resume <id8>` line |
| `/export [f]` | `:export` | no | send | report "Exported" + the path; `~/Downloads/<title>_<date>.md` (or the project root), a named file only inside the project with `.md/.markdown/.txt`, never over an existing file |
| `/agents` | `:list_agents` | no | send | report: agent definitions |

`DTO.Feedback.feature` gains `:conversations` (a navigate feedback: the
picker when `identifiers == []`, else the conversation the service switched
to). The reducer's `settle_command/3` shows feedback only when
`feedback.conversation_id` is nil or the current one: the service keeps it
nil for these.

### Full detail, changes and diffs, @path (C8)

- Full detail of an agent/op item now loads: the service reads exactly the
  text the item's `detail_ref.total_bytes` measured (it prepended the node
  name before, so every window's total mismatched and the reducer dropped it).
- A **finished** run's `Change`: `op_id`, `file_state`, `added`, `removed`,
  `diff_ref` (`"<checkpoint_id>:diff"`, `total_bytes` exact). Its edit op's
  `ToolCall`: `added`, `removed`, `diff_ref` (`"<op_id>:diff"`). A live run's
  changes have `diff_ref: nil`, `file_state: :unknown` until the run is over
  (the after side is still moving). Both load with the normal detail query in
  the conversation scope or the run's inspector scope; the text is a unified
  diff (`--- a/<path>` / `+++ b/<path>` / `@@`), 16 KiB windows are fine.
- Changes (`{:feature_query, :changes, id, …}`) in a conversation or run scope
  lists the files its runs changed (newest first, title = project-relative
  path, subtitle = the run's prompt, status `created`/`changed`), with
  `detail` = the unified diff of the item asked for by `id`. The project scope
  still lists the Git tree.
- `@path`: `{:feature_query, :files, query_or_nil, nil, 20, 65_536}` →
  `LibrarySnapshot{feature: :files}`; items ranked by the synced
  `FuzzyMatch`; `matches` = grapheme indices to highlight (the query as one
  piece when the path has it, file name first). No query lists the shallowest
  paths first. The index is the confined `.gitignore`-aware walk (≤ 50 000,
  rewalked at most every 30 s).

## Consumed contracts

- A2 (after A-sync): `RunServer.pending_interactions/1` approval rows gain
  `tool`, `command`, `cwd`, `reason`, `command_family`, `classification`,
  `permission`, `requested_at`. C reads them with `Map.get/3`, so the backend
  compiles before and after the sync.

## Requests for other owners

- E: `ReadModel.delta/3` clauses for `toast`, `rate_limit`,
  `background_upsert`, `background_remove` plus a catch-all (see above).
- E: `EffectRunner.error_body/3` clause for `:conversation_list`.
- E: `Intent.validate/1` decision guard widened to `:approve | :approve_run |
  :always_prefix | :deny | :deny_stop | :always_allow` if the reducer validates
  the intent before building the `Request`.
- E: after an accepted `conversation_new`/`conversation_open` (or a slash
  outcome with navigate `:conversations` and `identifiers: [id]`), unwatch
  the old conversation's watches and watch `{:conversation, id}` with a new
  generation; the shell watch resyncs by itself.
- E (tests): `test/swarm_code_cli/ui/slash_palette_test.exs` pins the builtin
  count and the last entry. With C7: line 39 `length(entries) == 31` (was 19)
  and line 71 `SlashPalette.selected(last).name == "quit"` (was "compact").
- E: handle the `client: true` slash commands locally (table above).
- B (blocking for real sessions): B6's runtime children
  (`Hooks.TaskSupervisor`, `Tools.BackgroundProcs`, `LSP.Supervisor`). Without
  `Hooks.TaskSupervisor` every tool call crashes after it runs; C's tests
  start it themselves when it is missing.
- B (tests): `session_selection_test.exs:18` expects `"auto"`; the synced
  `Projects` creates projects `read_only` (A's note).
- B: `apps/swarm_code_daemon/lib/swarm_code/daemon/backup/gate.ex:1668` has an
  unreachable clause warning under Elixir 1.18.4; `compile --warnings-as-errors`
  on a clean build fails on it.
- A / finisher (provenance): re-record the ledger sha256 of the two
  manifest-listed files below (`mix swarm_code.provenance.verify` fails until
  then).

## Manifest-listed files edited

- `apps/swarm_code_core/lib/swarm_code/commands.ex` (C7: the session commands).
- `apps/swarm_code_daemon/lib/swarm_code/daemon/service/command_dispatcher.ex`
  (C7: their execution; C10: `Domain.Tools.Path`).

## Verification

- C1: `mix test apps/swarm_code_core/test/swarm_code/protocol` 76/0;
  `mix test apps/swarm_code_cli/test` 1198 tests, 0 failures (5 properties);
  `mix test apps/swarm_code_daemon/test/swarm_code/daemon/service` 85/0.
- C2–C4: `mix test apps/swarm_code_daemon/test/swarm_code/daemon/service
  apps/swarm_code_cli/test/swarm_code_cli/ui/data_source` 183/0 (includes
  `pass70_approval_test` 4, `pass70_conversation_test` 7, the rewritten
  listener overflow/timeout tests and two daemon re-watch tests).
- Final, on the merged tree (p70-A-sync + C): `mix test` (umbrella) —
  core `145 tests, 0 failures`; daemon `660 tests, 3 failures`; cli
  `5 properties, 1202 tests, 2 failures`. None in C's files:
  - daemon `SessionSelectionTest` "creates a project and resumes …" (B's
    test; the synced `Projects` creates projects read-only, A's note);
  - daemon `Backup.GateTest` × 2 ("fresh unprobed WAL …", "a genuine current
    ready decision backs up all 57 migrations …": B's gate cannot back up the
    FTS5 shadow tables, A's note);
  - cli `SlashPaletteTest` × 2 (E's test pins 19 builtins and "compact" as the
    last; C7 adds 12 — see the request to E).
  New C tests: `pass70_approval_test` 5, `pass70_conversation_test` 14,
  `pass70_session_commands_test` 8, `pass70_changes_test` 5,
  `pass70_socket_test` 3, `pass70_wire_test` 9, `pass70_fake_test` 9,
  `commands_test` 4 new.
- `mix format --check-formatted`: clean. `mix compile --warnings-as-errors`:
  clean (the `backup/gate.ex:1668` warning shows only on a forced build, B's).
- `mix swarm_code.provenance.verify` will fail until the two manifest-listed
  files' sha256 are re-recorded (A/finisher).

## Left

- C9 (P2, arch F14) incremental projection: not done. A `nodes_patch` carries
  only the streaming columns (status, progress, detail, tokens, cost, turn),
  not `updated_at`, `result` or `error`, so the in-memory result cannot equal a
  reload (revisions and the record text derive from those). An exact
  incremental path needs the RunServer to put `updated_at` in the patch (A's
  domain) or the service to keep raw node rows; the golden-equivalence test
  should compare `state.runs` after patches with a fresh `reload/1`.
- Slash commands and diffs run inside the persisted backend's `handle_call`
  (DB reads, `/export` file write, diff computation for up to 50 finished-run
  checkpoints per reload). Bounded, but the AGENTS rule wants owned tasks for
  filesystem/long DB work; this is the same place the pre-pass dispatcher ran.
- A finished run's diff whose file changed on disk afterwards (with no later
  checkpoint of that path) is computed again with a different size; a detail
  view opened on the old `diff_ref` then needs reopening.
- `RunSummary.provider_name`/`retry_at`, `AgentSummary.provider_name`/
  `retry_at`, `ToolCall.exit_code`/`background`, `BackgroundCommand.cwd`/
  `exit_code`/`output_bytes` stay nil/0 from the persisted service (the domain
  records none of them).
- No real-provider smoke session was run (no sandbox session started); all
  verification is on fixtures and loopback providers.
