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
