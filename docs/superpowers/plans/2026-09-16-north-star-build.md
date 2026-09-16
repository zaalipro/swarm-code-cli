# North star build: contract, waves, ownership

Date: 2026-09-16. Implements `2026-09-16-tui-north-star.md` phases A–G and
feeds the companion (`2026-09-16-companion-build.md`) with real facts.

## What the daemon already stores (verified against the canonical database)

- `nodes` of kind `agent`: `name` ("Lead", "integrations-ops", "Judge · round 1"),
  `role` (lead | sub | worker | assistant), `title`, `status`, `progress` (0–100),
  `tokens_in/out`, `cost_usd`, `depth`, `parent_id`, `started_at/finished_at`,
  `changes_stat`, `error`, `phase`.
- `nodes` of kind `op` (tool calls): `op_type` (llm, read_file, grep, run_command,
  edit_file, write_file, web_search, web_fetch, list_dir, spawn_agent,
  structured_output, git_log, …), `title` ("grep Bootstrap|…", "read docs/…"),
  `detail`, `result`, `input`, `status`, timings, `parent_id` (the agent).
  `op_type = "llm"` is the agent thinking ("thinking" title).
- `checkpoints`: `run_id`, `node_id`, `path`, `previous_content`, `restorable`.
  This is the changes ledger and the rewind source.
- Judge agents' `result` is JSON `{"checks": [{"key", "note", …}]}`; runs carry
  `consensus`, `consensus_config` (`checks` keys), `model`, tokens, cost.
- `messages`: role user/assistant/error/tool, content, reasoning, tokens, cost.

Nothing needs a migration. The work is the wire contract and the screens.

## Wire contract (body_version stays 1; every addition has a default)

Field names are the wire keys. Times are unix milliseconds. Unknown → `nil`.

**TranscriptItem** (+):
- `kind`: `:text | :thinking | :tool | :error | :system` — message user/assistant →
  `:text`; op with op_type `llm` → `:thinking`; other ops → `:tool`; message role
  error → `:error`; system → `:system`.
- `tool`: `nil` or `%DTO.ToolCall{name, title, detail, status, started_at, finished_at,
  duration_ms, result_bytes, files}` — `name` = op_type; `title`/`detail` ≤ 200
  chars; `files` = paths parsed from `input` JSON for read_file/edit_file/
  write_file/list_dir (else `[]`); `status` = node status enum as on items.
- `agent_id`: the op's parent agent node id, or the message's run root node; `nil`
  when unknown.
- `tokens_in`, `tokens_out`: integers, 0 default.
- `at`: milliseconds (node started_at, else inserted_at), 0 default.

**AgentSummary** (+): `name`, `role` (`:lead | :sub | :worker | :assistant | :judge |
:unknown`; a worker whose name starts with "Judge" is `:judge`), `title`, `step`
(title of the newest running child op, else the status word), `progress` (0–100),
`tokens_in`, `tokens_out`, `cost_usd` (float or nil), `started_at`, `finished_at`,
`parent_id`, `depth`, `changes_stat`, `error` (≤ 200 chars).

**RunSummary** (+): `tokens_in`, `tokens_out`, `cost_usd`, `model`, `agents_total`,
`agents_running`, `needs` (pending interactions on this run), `changes` (checkpoint
count), `started_at`, `finished_at`, `consensus` (bool), `error`.

**WorkspaceSnapshot** (+): `changes: [DTO.Change]`, `verdicts: [DTO.Verdict]`.
- `DTO.Change{id, run_id, agent_id, path, restorable, at, revision}` — one per
  checkpoint of the runs in the snapshot (newest 200). Path relative to the
  project root when it is inside it; worktree paths are shown relative to the
  worktree.
- `DTO.Verdict{id (judge node id), run_id, round, status, checks: [%{key, ok, note}],
  summary, revision}` — parsed from the judge node's `result` JSON; `ok` is
  `true|false|nil`; `summary` ≤ 400 chars.

**Deltas** (+): `change_upsert`, `change_remove`, `verdict_upsert` with the same
entity shapes; the backend publishes them from `refresh/1` like the others.

**Read model** (+): `changes: %{id => Change}`, `verdicts: %{id => Verdict}`.

## Waves and ownership (one shared tree, nobody commits, orchestrator integrates)

### Wave 1 — contract (parallel)

| Agent | Owns | Delivers |
| --- | --- | --- |
| D1 daemon | `apps/swarm_code_daemon/lib/swarm_code/daemon/service/**`, `apps/swarm_code_daemon/test/swarm_code/daemon/service/**` | persisted and live backends emit every field above; projection queries join what is needed; deltas for changes/verdicts; tests on the encoders |
| C1 client data | `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/**`, `ui/read_model.ex` (or wherever the read model struct lives), `ui/reducer/watch.ex`, `test/fixtures/fake/**`, `test/support/**` (Fixtures.representative), `test/swarm_code_cli/ui/data_source/**` | DTO modules and codec accept and validate every field; new Delta kinds; read model stores changes/verdicts; the fake data source and `Fixtures.representative` produce rich, realistic values (named agents with steps and gauges, tool one-liners with durations, three changes, one verdict); tests |

### Wave 2 — screens (after C1; parallel)

| Agent | Owns | Delivers |
| --- | --- | --- |
| U1 transcript | `ui/projector/workspace.ex`, `ui/projector/composer.ex`, `ui/projector/run_row.ex`, `ui/projector/support.ex` (glyph additions only), their tests, `test/.../paint/**` for those | speaker lines (`you · 14:58`, agent name · step), tool one-liners (`▸ scout-1  grep "Repo\."  41 hits  0.4s ✓`, `▾` expanded via `{:expand, id, bool}`, first five lines then `… N more`), thinking collapsed under one dim line, error items red, streaming caret `▍` on the streaming item, no left gutter (text at column 2), one blank row between turns, run card title cut on a word boundary, one "Full text" action with a clear label, plain words everywhere |
| U2 hive | `ui/projector/inspector.ex` (+ new `ui/projector/inspector/*.ex`), `ui/projector/runs_dashboard.ex`, `ui/projector/run_palette.ex`, their tests | inspector agents tab becomes the hive: one lane per agent (`⬢ lead  planning  ▇▇▇▇  1.8k`), lane colour by index, waiting lanes in warning colour, judge `⚖`; changes tab lists `DTO.Change` rows with the agent chip and `o` opening the checkpoint detail; timeline tab lists transcript events by agent; a verdict card (criteria × ok) on the thread tab of a consensus run; the runs dashboard shows one cell per agent per run (`⬢⬢⬢⬡`), elapsed, and a `!` when needs > 0 |
| U3 shell | `ui/projector/shell.ex`, `ui/projector/status.ex`, `ui/projector/dialog.ex`, `ui/keymap/bindings.ex`, `ui/keymap/special.ex`, `ui/reducer.ex`, `ui/reducer/commands.ex`, `ui/action.ex`, `docs/keybindings.md` (regenerate), their tests | tab row: `⬢3`, elapsed, `!N`; header: tokens/cost when known; status words: "Waiting for you · N", never `NEEDS 0`; `n`/`N` jump to the next/previous pending interaction across runs (new special); approval dialog shows command, directory, risk line, agent reason, `y/Y/a/d` keys; question dialog shows options with digits |
| C2 companion | `apps/swarm_code_cli/lib/swarm_code_cli/companion/view.ex`, `apps/swarm_code_cli/priv/companion/**`, `test/swarm_code_cli/companion/**` | view carries real agents (name, role, step, progress, tokens), changes, verdicts, tokens/cost; the page drops "not reported by the daemon yet" where data now exists; fixture updated |

### Wave 3 — integration (orchestrator)

Format, `mix compile --warnings-as-errors`, umbrella suite, `mix swarm_code.keymap --write`,
the fake demo screenshot, a real saved session in GNU screen (boot, palette, hive,
changes, companion page screenshot), commit.

## Rules for every agent

- Never touch `/Users/zaali/dev/swarm-code` (read-only reference). Work in
  `/Users/zaali/dev/swarm-code-cli` only. Never commit or `git add`.
- Edit only your files. A transient compile error from another agent's half-written
  file: wait 30 s and retry, never "fix" it.
- Run tests from the umbrella root: `unset MIX_QUIET && mise exec -- mix test <path>`.
  `ui/renderer/locked_branch_test.exs` fails while `_build/prod` exists; expected.
- Never print API keys or `~/.secrets`. Never start the real saved session; use
  fixtures, the fake source, and unit tests.
- Every new glyph must have an ASCII fallback in `Support.glyphs` and pass the
  width-safe check the catalogue enforces.

## Status (2026-09-16, end of the build)

Delivered, on one commit after this plan:

- **Wave 1** (D1, C1): the wire contract above, both daemon backends, the client
  DTOs, deltas, read model, fake source and `Fixtures.representative`.
- **U1 transcript**: speaker lines with local times, tool one-liners with
  durations and outcomes, expandable results and thinking, streaming caret,
  run cards in plain words, no left gutter. New `projector/workspace/turns.ex`;
  `scroll_metrics.ex` measures through it so anchors and painted rows agree.
- **U2 hive**: the inspector's agents tab is the hive (one lane per agent,
  lane colours, judge `⚖`, waiting lanes in warning); changes tab from
  `DTO.Change` with agent chips and blast radius; timeline tab; verdict card;
  dashboard and palette rows carry `⬢N`, elapsed and `!`.
- **U3 shell**: status row leads with `Waiting for you · N` (never a zero);
  tabs carry `⬢N`, elapsed (or the finished run's duration) and `!N`, titles
  cut on a word boundary at 24 cells, badges shed below 120/100 columns; the
  title row shows `12k tokens · $0.42` once known; `n`/`N` walk the pending
  approvals and questions across runs (`{:open_interaction, id}` navigates and
  opens the dialog, `:nothing_waiting` says so); the approval card is titled
  "<agent> wants to run a command" with the command, tool line, a risk line
  and the decision keys. `docs/keybindings.md` regenerated.
- **C2 companion**: the view carries agents, changes, verdicts and spend; the
  page renders tool one-liners, the verdict scorecard, the waiting card and
  timed change rows. `scripts/dev/companion_fixture.exs` writes both fixtures
  from the real view builder so the preview cannot drift from the live page.
- **Runtime**: a live session (init `now` of 0) reads the wall clock at each
  commit, so elapsed times move; scripted sessions keep their fixed clock.

Deferred (not on the wire or not in scope): approval reason and working
directory (no wire field); per-agent focus action; the companion `act` route;
the timeline scrubber strip in the inspector; a "no output for 40 s" stall
notice; `RunDetailSnapshot` still carries no changes/verdicts; `agent_update`
deltas are not published live; the judge approve/revise word has no wire field;
`ui/transcript.ex` is unused and kept.

Follow-ups the same evening: the protocol's JSON entry cap (8,192 → 65,536) so
an ordinary saved conversation's snapshot can be published at all, with every
silent close on either side now named on stderr; and the main screen brought to
the mock (flush-left transcript, one-row run headline instead of the card and
kind banners, top-anchored turns, hive before verdict, a rule for the strip).

Later the same night, from a screenshot of a live swarm run:

- **Live agents.** The persisted backend publishes an `agent_update` delta for
  every agent whose summary changed on a refresh, so the hive lanes and the
  speaker names follow a running swarm instead of saying `assistant`/`tool`
  until the next snapshot. The client's delta envelope rule for agents now
  accepts the conversation id the daemon stamps on every delta.
- **Agent items.** An agent node's transcript text is what it produced
  (result, else detail, then error), never its name: "Lead" over three blank
  rows is gone. The run's root agent is retired from the transcript the
  moment its assistant message exists, empty or streaming, so a chat turn
  no longer paints two "Assistant · thinking" lines for one answer.
- **Reading order.** `Turns.order/1` reads each run as prompt, work, words:
  the daemon creates a chat turn's answer before its tool calls, and the
  companion sorts the same way.
- **Chrome.** One action row under the headline (Pause/Stop/Inspect, then
  the composer's, what waits, and the full-text openers); a request that went
  through paints no notice (`OK ACCEPTED` is gone, pending and failures
  stay); the title row leads with the project's name once the daemon says it
  (`SAVED · DEV` remains only for sessions without a project) and names the
  sub agents' model when it differs from the chat model.
- **Wire.** Workspace metadata and snapshot carry `project` and `models`
  (every configured provider's models, ≤ 400, as `provider_id`/`provider`/
  `model`), the ground for `/model` and `/swarm_model` and the picker.
