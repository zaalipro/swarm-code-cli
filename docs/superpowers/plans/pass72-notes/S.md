# Pass 72, owner S (data): notes

Branch `p72/S`, worktree `/Users/zaali/dev/swarm-code-cli-wt/p72-S`. Tag `p72-S-wire` = the wire
contract below compiles, round-trips and exists in the fake data source.

## Contract (what P and O read)

All new fields have wire defaults, so an older daemon still decodes. Read them with
`Map.get(struct, :field, default)` until you merge `p72-S-wire`.

### `DTO.AgentSummary` (new fields)

| field | type | meaning |
| --- | --- | --- |
| `panel_state` | `:working \| :thinking \| :waiting \| :needs_you \| :done \| :failed \| :stopped \| :queued \| :paused` | the one P3 state. **Not `state`**: `state` keeps the runtime status (`:running`, `:waiting_approval`, …) other code uses. `:waiting` = waiting on other agents (◌). `:stopped` = the user stopped it (not a failure): draw it with ✗ and the word "stopped", or ⏸ — P decides; it is not `:failed`. Default `:working`. |
| `now` | text ≤ 80 bytes | one plain sentence with a verb, already chosen by R2: needs you → "wants to run a command" / "wants to edit lib/y.ex" / "has a question for you" (the band carries the literal text); failed → "failed: <first sentence of the error>"; done → the finding (else "done"); queued/paused/stopped → the word; waiting → "waiting on 3 agents" / "waiting on data-review" / "waiting for a message"; thinking → the freshest complete sentence of the reasoning (else "thinking"); working → "reading lib/x.ex", `searching "Escape"`, "running mix test test/…", "editing lib/y.ex", "fetching hexdocs.pm", …. Never an id, branch or worktree path. `""` from an older daemon. |
| `lane` | list of `:think \| :tools \| :write \| :wait_you \| :idle`, 12 or `[]` | the last 60 s in 5 s cells, **oldest first**, ending at `lane_at`. `[]` = no lane (done, failed, stopped, queued, or nothing recorded): draw no lane. |
| `lane_at` | unix ms or nil | a cell boundary at or after the agent's last recorded op event (not the clock; bodies change only when the DB does) |
| `lane_now` | kind | what is still going on at `lane_at` |
| `finding` | text ≤ 160 bytes or nil | first real sentence of a done agent's result (headings/bullets/markdown stripped) |
| `finding_refs` | list of ≤ 5 `"path:line"` | cited by the result, in order, unique, relative paths |
| `files_changed` | count | distinct files the agent wrote (checkpoints) |
| `elapsed_ms` | count or nil | only once finished; a live agent's is `now - started_at` (see `Lane.elapsed_ms/2`) |
| `tokens` | count | `tokens_in + tokens_out` |

Existing fields cover the rest of P1: `name`, `role`, `parent_id`, `depth`, `model`, `cost_usd`,
`started_at`, `finished_at`, `changes_stat`.

**Rolling the lane (P):** `SwarmCodeCLI.UI.DataSource.Lane.window(agent, now_ms, 12 | 8)` returns the
kinds to draw, oldest first, rolled forward to the client's clock (each whole cell since `lane_at`
repeats `lane_now`); `[]` means draw no lane. `Lane.elapsed_ms(agent, now_ms)` for the meta. Both
pure; the clock is the caller's (the projector's `now` fact).

### `DTO.RunSummary` (new fields)

| field | type | meaning |
| --- | --- | --- |
| `needs_you` | list of `DTO.NeedsYou`, oldest first, ≤ 20 | the band (P2) |
| `reported` / `total` | counts | sub-agents (not the root) finished / spawned; `total == 0` = not a team |
| `phases` | list of `DTO.Phase` | a workflow's declared phases; `[]` otherwise |
| `phase` | text ≤ 120 or nil | the workflow's current phase |
| `goal_iteration` / `goal_iterations` | count or nil | this run's place among its goal's runs, and how many the goal has had. No maximum: the domain records none (so no "3/5"). |
| `goal_status` | text ≤ 32 or nil | the goal's status (`active`, `done`, …) |
| `round` / `rounds` | count or nil | consensus: judged rounds so far (Judge agents) / configured rounds |
| `verdict` | text ≤ 400 or nil | the latest judge's summary (goal or consensus) |

Not recorded by the domain, so omitted (P5): workflow retry countdown/count, goal criteria with
"met in", consensus positions/`moved_from`/"k of n on X", research found/read/used/domains/sections.
The existing `verdicts` (checks with ok/note) are still on the workspace snapshot for criteria.

### `DTO.NeedsYou`

`agent_id` (id or nil), `node_id` (the waiting node: an approval's op, a question's node — the one
`approval.resolve` / `question.answer` name), `agent_name`, `kind` (`:approval \| :question \| :gate`;
`:gate` is reserved for workflow gates and not emitted yet), `text` ≤ 1024 bytes (the literal command,
else `edit <path>` / the tool; a question's prompt; control characters and runs of whitespace fold to
one space, nothing else changes), `reason` ≤ 512 (the approval's justification), `requested_at` (unix
ms). Answering still goes through the run's `PendingInteraction` (same `node_id`).

### `DTO.Phase`

`name` ≤ 120, `state` (`:done \| :running \| :waiting \| :paused \| :failed \| :queued`),
`agent_count`, `live`, `done` (agents whose `phase` column is this phase). Not `agents`: the codec's
page-size check reads any `agents` key as a list.

### Agent detail (the overlay's data, P8): `{:agent_detail, run_id, node_id}`

Request (CLI): `%Request{kind: {:agent_detail, run_id, node_id}, origin: {:query, :agent_detail},
expected_response: :agent_detail, scope: <conversation or that run>}` issued as a `{:query, request}`
effect; the response `Delivery` body is `DTO.AgentDetail`. Wire op `agent.detail` (`run_id`,
`node_id`), capability `:query`, answered by a job (never inside the backend's callback); an unknown
node, an agent of another run, or the unsaved runtime answers `not_allowed` (a failed request is a
`DTO.AgentDetail{state: :error, error: %AdmissionError{}}` like every page). The fake answers it too.

`DTO.AgentDetail`: `state`/`request_id`/`error` (the request's), `run_id`, `agent_id`, `name`,
`role`, `model`, `panel_state`, `now`, `parent_name`, `brief` ≤ 4096 (its task/prompt; `brief_bytes`
the whole size), `needs_you` (its band entries: `reason` = why it asks), `findings` (list of
`DTO.Finding{n, severity :high|:medium|:low|nil, text ≤ 400, ref "path:line"|nil}` parsed from the
numbered/bulleted items of its result; severity only when the item names one), `result` ≤ 8192 (the
result's head, markdown kept; `result_bytes` the whole), `agent_error`, `activity` (list of
`DTO.ActivityGroup{kind :read|:search|:explore|:think|:said|:command|:edit|:web|:agents|:ask|:other,
title ("read 3 files", "searched 2 patterns", "thought ×3", "ran mix test", "edited lib/y.ex",
"said"), items (≤ 12 paths/patterns/commands), count, started_at, duration_ms, quote (a thought's
first sentence, a command's last output line, the words it said), state :running|:waiting|:done|
:failed}` oldest first, ≤ 200), `operations` (the raw ops for `o`: `DTO.OpLine{id, op_type, title,
status :running|:waiting|:done|:failed|:stopped|:queued, started_at, duration_ms}`, newest 200 oldest
first), `life` (≤ 120 lane kinds over its whole life, bucket `life_bucket_ms` (whole seconds, ≥ 1 s)
from `life_started_at`), `think_ms` ("thought 41 s of 1:37"), `files_read`, `files_searched`
(patterns, quoted), `files_changed` (paths it wrote), `changes_stat`, `tokens_in`, `tokens_out`,
`cost_usd`, `context_used` (the tokens its newest think sent) and `context_window` (the model's
working window, `Context.budget/2`), `turn`/`max_turns` (only when a turn limit is set; there is no
token budget in the domain), `started_at`, `finished_at`.

Not in the detail (the client has it): neighbours in panel order (`PanelOrder.entries/1`), the
mini tree (the run's agents are in the workspace snapshot's `agents`), search hit counts (the domain
does not record them reliably, so they are omitted).

### Steering one agent

Already on the wire and in the engine (desktop spec 13 §3.6): `{:steer, run_id, node_id, text,
attachments}` → `run.steer` with `node_id` → `Engine.steer(…, node_id:)` → `RunServer.steer/4`
delivers the text to that agent only (a queued agent gets it with its opening messages; a finished
one answers not_allowed). The daemon admits any agent of the run. The steer is persisted as a user
message of that run (the desktop's behaviour). The origin must be a valid draft key; the overlay
composer can use `{:draft, {conversation_id, {:thread, node_id}}}` (a valid `DraftKey` today).
The fake now admits an agent id of the run as a steer target too.

## Tasks

- S1 wire contract + fake parity (tag `p72-S-wire`): `436737d`, notes `db2f541`.
- S2 needs_you with the literal approval/question text: in S1 (`PanelFacts.needs_you/4`, the
  persisted and the unsaved backends, the fake from its pending interactions): done.
- S3 lane buckets from stored operations: in S1 (`PanelFacts.lane/4`, anchored at the last recorded
  event; `Lane.window/3` rolls it on the client): done.
- S4 now/finding/finding_refs, scrubbed of ids/branches/worktrees: in S1: done.
- S5 agent detail request: `baa0525`: done.
- S6 single-agent steering: `1a9e8a5` (verified path + fake + codec test): done.

## Requests for others

- **O, `ui/effect_runner.ex` `error_body/3`** (the `case request.expected_response do` at ~line 125):
  add a clause, or a failed agent-detail request raises `CaseClauseError` in the runner:
  ```elixir
        :agent_detail ->
          struct!(DTO.AgentDetail, attrs)
  ```
- **O, reducer:** the `{:agent_detail, %DTO.AgentDetail{}}` response (reducer.ex ~1068 matches
  `{request.expected_response, delivery.body}`) is new; store it for the overlay keyed by
  `{run_id, agent_id}` and ignore a stale one (request id / generation). Answer band items through
  the run's `PendingInteraction` whose `node_id` equals `NeedsYou.node_id`.
- **P:** the state is `panel_state` (not `state`); the lane to draw is
  `Lane.window(agent, now_ms, 12 | 8)` (not `agent.lane` directly); a workflow phase's size is
  `agent_count`. `:stopped` exists (user-stopped, not failed).

## What is left

See the task list above.
