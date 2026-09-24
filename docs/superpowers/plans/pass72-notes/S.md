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

## Tasks

- S1 wire contract + fake parity: done (tag `p72-S-wire`).

## Requests for others

(none yet)

## What is left

See the task list above.
