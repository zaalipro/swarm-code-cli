# pass70 owner C notes (service boundary)

Branch `p70/C`, worktree `/Users/zaali/dev/swarm-code-cli-wt/p70-C`.

## Landed

| task | status | commits |
| --- | --- | --- |
| C1 DTO + wire additions, fake parity | done, tagged `p70-C-wire` | see `git log p70-C-wire` |

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
- B: `apps/swarm_code_daemon/lib/swarm_code/daemon/backup/gate.ex:1668` has an
  unreachable clause warning under Elixir 1.18.4; `compile --warnings-as-errors`
  on a clean build fails on it.

## Manifest-listed files edited

(none so far)

## Verification

- C1: `mix test apps/swarm_code_core/test/swarm_code/protocol` 76/0;
  `mix test apps/swarm_code_cli/test` 1198 tests, 0 failures (5 properties);
  `mix test apps/swarm_code_daemon/test/swarm_code/daemon/service` 85/0.

## Left

(updated as tasks land)
