# cli021 lane K notes: desktop pass 74 (K1-K6), then the CLI sync (K7)

Desktop: branch `pass74/engine` from `b44bc5e4` (worktree `~/dev/swarm-code-wt/pass74`), done
commit `956f3826` (`pass 74: done`), merged into desktop `main` with `--no-ff` as
**Fm2 = `a93d6d8ee74358749e157e91dea46ad8c0d66722`** (same tree as the done commit). CLI: branch
`cli021/sync` from CLI `main` `b6f8c79a` (worktree `~/dev/swarm-code-cli-wt/cli021-sync`), not
merged. Logs: `~/.cache/ncode/cli021/K/`.

## Desktop pass 74 (commits on `pass74/engine`)

| Task | Commit | What |
| --- | --- | --- |
| K1 | `cf447a18` | `Context.default_window/0` = 1,000,000; `Context.effective_window/2` = the configured `settings.pricing[model]["context_window"]` else that default; `budget/2` = 75 % (750,000 by default; was 160,000 `claude*`, 900,000 `[1m]`, 120,000 otherwise; `budget/0` was 120,000). The overflow retry trims to `Context.overflow_budget/3`: 0.6 of what was *sent* (the old 0.6 × budget trimmed nothing under the 1 M default), or the provider's own numbers (`N tokens > M maximum`, `maximum context length is M … resulted in / you requested N tokens`) with a fifth to spare when they ask for more. The agent keeps that budget for the rest of its run (`overflow_budget` in its state). Settings → Pricing field title names the default. |
| K2 | `05da91d2` | Read-only row: "asks before every write and command". |
| K3 | `60bdba43` | `Workflows.launch/1` `attrs[:approval_mode]`, checked by the now public `Engine.check_approval_mode/2` (shared with F8) before anything is written, carried to the run as `approval_override`. |
| K4 | `03246a26` | `HTTP` retry callback: `HTTP <status>` when the retry came from a status, else the reason word (fix S2 upstreamed). |
| K5 | `d02a5392` | Tests only (loopback `/v1/models` with `ms/glm-5.2`-style ids, list replaced, failed fetch keeps the list, fetch-all, vanished model keeps working). The desktop already did all of it. |
| K6 | `b89bec7c` | Version 0.2.2 (mix.exs, MCP/LSP clientInfo, footer tests, README/AGENTS names); CHANGELOG `## ncode 0.2.2 — 2026-10-08` above `## pass 74 (CLI 0.2.1 shared engine)`. |

## K7 CLI sync

- `mix swarm_code.provenance.sync --ref a93d6d8e… --upstream ~/dev/swarm-code`: updated from
  upstream 6 (`engine/agent_server.ex`, `engine/context.ex`, `lsp/client.ex`, `mcp/client.ex`,
  `workflows.ex`, mapped `engine/context_test.exs`), merged with the CLI patch 15 (headers only
  except `engine.ex`, which took K3's `check_approval_mode/2` around the CLI hunk), one conflict:
  `domain/llm/http.ex` (both sides added `shown_reason/2`). Resolved by taking the desktop's
  side; **the S2 hunk is gone from `provenance/patches/.../llm/http.ex.diff`** (only L2 remains).
- New CLI patches (2): `domain/mcp/client.ex` and `domain/lsp/client.ex` keep the CLI's own
  version in `clientInfo` (`"0.2.0"` today; the desktop now says 0.2.2). Recorded by syncing at
  Fm2 again. **Integrator:** when stamping 0.2.1, change the literal in both files and the
  `version_test.exs` expectation, then re-run `sync --ref a93d6d8e…` to re-record. (A8 had no
  patch here because the desktop and CLI were both 0.2.0.)
- `a93d6d8e…` is the seventh `@adaptation_pins` entry (`core/governance/provenance.ex`) and has a
  `SOURCE_AUTHORIZATION.md` addendum (263 of 287 ledger entries record it; 23 `fb1b4ff8`, 1
  `4c7c577a`). `source-policy.json` records no pins (same as A1/A'1). No migration: the schema
  contract stays `desktop-4c7c577`.

## For other lanes and the integrator

- **C3** can read the window with `SwarmCode.Domain.Engine.Context.effective_window(model,
  settings)` (configured, else 1,000,000) and `Context.default_window/0`; `Context.window/2`
  is still "configured or nil". The desktop's validation is `Setting.changeset` (8,000 to
  2,000,000, "context_window must be a whole number between 8000 and 2000000").
- **K3's one CLI line (fix-S open item S1)**, not done here (C's frozen file, repin needed):
  `daemon/service/command_dispatcher.ex` `execute(conv, %{action: :run_workflow} …, _)` (the
  `Workflows.launch(%{…})` at ~line 477) should pass `approval_mode: Keyword.get(opts,
  :approval_mode)` (the third argument is `_` today) and map `{:error, :untrusted_project}` /
  `{:error, :invalid_approval_mode}`.
- **AGENTS.md** (integrator): the pin sentence "re-synced to `7b8f379f` (desktop pass 72, no
  migration)" gains "then `a93d6d8e` (desktop pass 74, CLI 0.2.1, no migration)"; the S2 bullet
  ("One more patch on `domain/llm/http.ex` (fix S2) … upstream it to the desktop") becomes "fix
  S2 is upstream since desktop pass 74 K4; the patch is gone"; add the clientInfo patch to the
  list of recorded patches.
- **K4 seam:** the retry reason is still display-only; the error class still comes from the
  reason word (`server` → `:overloaded`, `rate limit` → `:rate_limit`).
- **K1 behaviour the CLI inherits:** saved sessions now trim at 750,000 estimated tokens for any
  model without a window, the history read is `4 × budget` bytes (~3 MB) and the compactor's
  window `4 × budget − 40,000`. A smaller real window is learned from the provider's refusal on
  the first overflow of each run.

## Gates that ran

Desktop (`~/dev/swarm-code-wt/pass74`):

- Each task: its test written first and watched failing (K1 7 of 8, K2, K3 4 of 6 with the two
  controls passing, K4 3 of 4, K6 8 of 22); K5's 5 tests passed at once (behaviour already
  there). K1's learned-budget test was mutation-checked (fails with the cap disabled).
- Focused: engine dir 575/0; workflows dir (with K3) 173/0; llm dir with K4 212/0; composer 32/0;
  F8's approval/trust/hooks tests 37/0; K5 5/0; the footer/version tests 22/0.
- `mix precommit` (suite slot `RUNNING K-desktop`): run 1 EXIT 2, 4588 tests, 2 failures, both
  load timing (load average ~17): `run_command_test.exs:29` (4.5 s against a 2.2 s bound) and
  `polish74_ct_stream_golden_test.exs:290` (60 s timeout); both green alone. **Run 2 EXIT 0,
  4588 tests, 0 failures** (`precommit-2.log`).

CLI (`~/dev/swarm-code-cli-wt/cli021-sync`):

- `mix swarm_code.provenance.verify`: "provenance verified" (after a `mix compile`; the first
  run used the stale compiled pin list). `sync --check`: every synced file derives from the
  pinned commit. `drift --strict`: none (desktop main a93d6d8 adds no migration and no domain
  commit since the pin).
- Focused daemon (one app per call): `test/swarm_code/domain`, `test/swarm_code/llm`,
  `fix_s_retry_status_test`, `run_synced_llm_test`, `fix_s_approval_test`,
  `read_only_ask_test`: 423/0; `test/swarm_code/daemon/service` + `daemon/runtime`: 616/0.
- Core `test/swarm_code/governance` + `test/mix/tasks`: 43/0. CLI `version_test.exs`: 2/0 (the
  synced clientInfo still says the CLI's 0.2.0 through the new patch).
- `mix format --check-formatted`: clean. `mix compile --force --warnings-as-errors`: EXIT 0, no
  warnings.
- Not run: the CLI full suite / `mix precommit` (the integrator's, slot rule), PTY suites,
  `check_terminal_port.sh`, keymap/settings generators (nothing of theirs changed).
