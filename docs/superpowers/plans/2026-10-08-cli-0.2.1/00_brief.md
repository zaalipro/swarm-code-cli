# CLI 0.2.1 + desktop 0.2.2 (2026-10-08): binding brief

Owner report on the installed CLI 0.2.0 (verbatim points):
1. "I cant change effort on cli, modal opens but arrow buttons does nothing."
2. "its still called swarm_effort while it should be worker_effort" (desktop 0.2.0 renamed the slot
   to Worker; the CLI status line still says `agents <model>`).
3. "fetch all provider model list from settings did nothing": the gateway renamed models (for
   example `ms/glm-5.2`, `ms/deepseek-v4.1flash`, `nv/glm-5.3`) and the CLI still lists the old
   names after a fetch. Fact: the real `providers` row for llmotions has `updated_at`
   2026-09-12, so no fetch has saved since then.
4. "when running command like /panel it should show possible options in dropdown like selector,
   also it should highlight command text like /panel in a different color." Today the palette row
   shows `/panel [full|compact|hidden|summaries on|off]` and disappears once an argument is typed.
5. "CLI version lacks some changes we made on desktop" (see the parity list).
6. "context window on CLI shows 120k while deepseek v4 pro has 1m; default 1m context window for
   all models, configurable per model." Fact: desktop `Engine.Context.default_budget/1` returns
   `@budget 120_000` for any model without a configured `settings.pricing[model]["context_window"]`
   (Settings → Pricing already edits that per model; the budget is 75 % of a configured window).
7. "full token per second shown per model in the side panel's top section, and RAM usage in the
   top section of the side panel. It should be beautiful and well organized."

Bases: CLI `main` = `4fc8179f` (= tag v0.2.0, pushed). Desktop `main` = `b44bc5e4` (0.2.1,
released, not pushed). Rules unchanged from `../2026-10-07-cli-0.2.0/00_contract.md`: §2 hard
rules, §3 provenance rule (shared engine behaviour desktop-first, then synced), §4.1 worktree
recipe, §4.4 suite slots, §9 gates. Commit messages `cli021 <task id>:`; each lane ends with
`cli021 <lane>: done` (desktop lane: `pass 74 <task id>:` and `pass 74: done`).

## Lanes and ownership

| Lane | Repo / branch / worktree | Owns |
| --- | --- | --- |
| P | read-only | parity audit (no edits) |
| K | desktop `pass74/engine` (`~/dev/swarm-code-wt/pass74`), then CLI `cli021/sync` (`~/dev/swarm-code-cli-wt/cli021-sync`) | desktop `lib/swarm_code/engine/context.ex`, `engine/agent_server.ex` (auto-compact use of the budget only), `workflows.ex` (+ the run start it calls), `llm/http.ex` and `engine/operation.ex` (retry status words), `providers.ex`, `providers/provider.ex`, `lib/swarm_code_web/components/chat.ex` (the mode menu row only), their tests, CHANGELOG, mix.exs version; on the CLI: the provenance sync and its patches only |
| B | CLI `cli021/B` | `core/commands.ex` (repin), `ui/keymap*`, `ui/reducer.ex`, `ui/reducer/**` (not settings), `ui/composer.ex`, `ui/draft*`, `ui/slash_palette.ex`, `ui/state.ex`, `docs/keybindings.md` |
| C | CLI `cli021/C` | `dmn/daemon/service/**`, `dmn/daemon/service.ex`, `core/protocol/**`, `ui/data_source/**`, `ui/intent.ex`, `ui/request_resolver*`, `ui/read_model.ex`, `ui/watch_state.ex` |
| U | CLI `cli021/U` | `ui/projector*` (workspace, side panel, status line, dialogs), `ui/paint*`, `ui/layout*`, `ui/theme.ex`, `ui/settings/**`, `ui/reducer/settings*`, `core/settings/**`, `docs/settings.md` |

A need outside your row: record it in `notes/<lane>.md`, make the smallest change only if
unavoidable; the integrator resolves.

## K: desktop first (desktop pass 74), then the CLI sync

- **K1** Default context window 1,000,000 tokens for every model without a configured
  `context_window`; the configured per-model value always wins (Settings → Pricing, 8,000 to
  2,000,000). The trim budget stays 75 % of the window; the auto-compact threshold follows it. A
  provider's "context too long" error must still recover through the existing overflow path
  (pass 60/61 classifier): prove it with an `LLM.Fake` test where the provider refuses a long
  history and the turn compacts or trims and succeeds.
- **K2** The mode menu row says Read-only "agents can only read and search" (`chat.ex:5668`); since
  pass 72 it asks first. New words: "asks before every write and command".
- **K3** `Workflows.launch/1` accepts an `approval_mode` override (same values and the same
  untrusted-project refusal as `Engine.start_chat_turn/4`'s F8 option) and carries it to the run.
- **K4** Upstream the CLI's retry status words (fix-round S2: `retrying 2/5 · HTTP 500`, the HTTP
  status when there is one, else the reason word) into the desktop, so the CLI patch on
  `domain/llm/http.ex` can be dropped at the sync.
- **K5** `Providers.fetch_models/1`: model ids that contain `/` (`ms/glm-5.2`) save, the stored
  list is replaced (a renamed model's old id disappears), and a conversation whose model vanished
  keeps working the way a missing model already does. Tests with a loopback `/v1/models`.
- **K6** Version 0.2.2 (mix.exs, MCP/LSP clientInfo, the version-printing tests, README/AGENTS
  file names) and a CHANGELOG `## ncode 0.2.2 — 2026-10-08` heading above a `## pass 74` entry.
  `mix precommit` green (slot), then merge into desktop `main` (`--no-ff`) = **Fm2**.
- **K7** CLI: `cli021/sync` from CLI `main`; `mix swarm_code.provenance.sync --ref Fm2`; drop
  CLI patches that Fm2 now carries (K4); provenance verify, sync --check, drift; focused domain
  tests; `cli021 K: done`. Do not merge it; the integrator does.

## B: input and commands (CLI)

- **B1** Root-cause and fix the `/effort` picker: arrows do nothing, so the effort cannot be
  changed. The same picker for the worker slot. PTY test that changes the effort with arrows +
  Enter and sees the new value in the status line.
- **B2** The worker slot's commands are `/worker_effort` and `/worker_model` (if a `/swarm_model`
  exists); the `swarm_*` names stay as hidden aliases (not listed, still accepted). Help, palette
  and notices say "worker". Hand U the status-line and settings word changes through notes.
- **B3** Argument dropdown: when the draft is `/<command> ` (with or without a partial argument)
  and the command declares choices (from `commands.ex`'s argument spec: `/panel`, `/effort`,
  `/worker_effort`, `/approval`, `/theme`, `/mouse`, `/consensus`, `/rewind` scopes, and every
  other enumerated one), show a dropdown of the choices under the composer, filtered by the typed
  prefix (multi-word choices like `summaries on|off` expand to `summaries on`, `summaries off`), the
  current value marked. Up/Down move, Tab completes, Enter completes and runs when the command is
  complete, Esc closes the dropdown only. Dynamic choices (models, themes, conversations) come from
  data the client already has.
- **B4** Highlight the command token in the composer: a known `/command` in the command colour
  (the theme's accent role used for commands in the palette), its arguments in normal text, an
  unknown `/word` in the muted/warning role. Typing, editing, cursor and wrapping unchanged.

## C: daemon and wire (CLI)

- **C1** Fetch models: root-cause why fetching (one provider, and "fetch all") saved nothing for
  the llmotions provider (ids with `/`? a swallowed error? the frozen vs synced provider path after
  A5?). Fix it; the settings screen shows the result ("12 models · 3 new · 2 removed") or the
  error sentence. Loopback tests only.
- **C2** Vitals data for U1: per model used by the shown conversation (main, worker, validator and
  any other model its runs used), the latest output tokens/second and a short recent history (up
  to 12 samples), from the synced engine's speed data (`RunServer.worker_speed_role/2`, the
  desktop speed monitor's source, `lib/swarm_code_web/components/speed_monitor.ex` for meaning);
  and memory: the daemon BEAM's total memory, the TUI client's, and the daemon's OS RSS if cheap.
  At most one update per second, only while a client watches; a new wire op/DTO registered in all
  four places (contract §8.2); Fake answers too.
- **C3** Context window: the CLI reads and writes the per-model `context_window` (same validation
  as the desktop) and sends the shown model's window (the configured one, else the 1M default
  from K1 once synced; until then the domain's current default) to the client for the status line.

## U: side panel, status line, settings (CLI)

- **U1** The side panel's top section shows the vitals: RAM and tokens/second per model. Design
  first: write ASCII mockups at panel widths 28, 40 and 56 columns into `notes/U.md` (look at the
  desktop speed monitor and RAM chip for meaning, and at today's side panel and theme), then build
  it with theme roles only (no raw colours), aligned columns, model names truncated with an
  ellipsis, a small sparkline or bar per model, idle models dimmed, RAM as a bar with the number.
  When the panel is hidden or in its one-line strip (auto mode), show a compact form (the busiest
  model's tok/s and RAM) where the strip or status line has room. It must look deliberate and calm,
  not busy.
- **U2** Status line: the worker slot reads `worker <model>` (not `agents`); `ctx` shows used / the
  model's window (`8k/1M`).
- **U3** Settings: the per-model context window is a visible, editable row for each model; the
  fetch result or error of C1 is shown where the fetch was started.
- **U4** B's words for the worker slot and the dropdown's drawing if B hands it over through notes.

## P: parity audit (read-only, first)

List every user-visible desktop behaviour from desktop passes 64-74 (CHANGELOG) that the CLI lacks
or does differently, verified in code on both sides (not from docs). Excluded: desktop-only UI
chrome with no terminal meaning, missions (deferred). Each item: what, desktop evidence, CLI
evidence, the lane that owns the fix (B, C or U), size S/M/L. Lanes may take S items in their own
files; everything else is reported to the owner.

## After the lanes

Integrator: `cli021/integration` from CLI `main`, merge `cli021/sync` (K7) first, then B, C, U;
resolve; version 0.2.1 stamped like A8 did 0.2.0; full gates of contract §9.3 step 2 and the
release build. QA: every item above live in the sandbox harness, the vitals panel at 80x24,
120x40 and 160x48 in two themes, the dropdown on `/panel`, `/effort`, `/approval`, the effort
picker by arrows, a fetch against a loopback gateway whose list renamed models (ids with `/`).
Packaging: CLI 0.2.1 tarball and desktop 0.2.2 DMG, stamped into the site branch, no upload.
Audit (Haiku): checksums, minimum macOS, versions, transcript models.
