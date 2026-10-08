# CLI 0.2.0 fix round (2026-10-08): binding brief

Base: CLI `main` = `0442eb0e` (the merged 0.2.0: contract `00_contract.md`, outcome
`docs/research/2026-10-07-cli020-outcome.md`, lane notes `notes/*.md`). Desktop `main` = `894bc461`
(pass 72 + pass 73), unchanged by this round. Evidence: the QA result
`~/.cache/ncode/cli020/qa-result.json`, the finisher result `~/.cache/ncode/cli020/fin-result.json`,
QA logs and shots under `~/.cache/ncode/cli020/qa/`.

Owner decisions: A5 is in this round (yesterday's "lets do this tomorrow"). Everything else is a
bug or polish item from the 0.2.0 QA; nothing here is a new feature. 0.2.0 is not tagged yet: this
round finishes it.

The rules of `00_contract.md` §2 (hard rules), §3 (provenance rule), §4.1 (worktree recipe), §4.4
(suite slots) and §9.1 (focused tests, gates) apply unchanged. Commit messages start
`cli020 <task id>:`; each lane ends with `cli020 <lane>: done`.

## Lanes and ownership

| Lane | Branch / worktree | Owns |
| --- | --- | --- |
| R | `cli020/fixR`, `~/dev/swarm-code-cli-wt/fix-R` | `ui/renderer/**` (including the RatatuiPort owner), `ui/session_runtime.ex`, `ui/effect_runner.ex`, `native/terminal_port/**`, `scripts/dev/test_terminal_*_pty.py` |
| L | `cli020/fixL`, `~/dev/swarm-code-cli-wt/fix-L` | `dmn/llm.ex`, `dmn/llm/**`, `dmn/daemon/runtime/run.ex`, `dmn/providers/provider.ex`, `provenance/**`, `SOURCE_AUTHORIZATION.md` (only if a pin changes), their tests |
| S | `cli020/fixS`, `~/dev/swarm-code-cli-wt/fix-S` | `dmn/daemon/service/**`, `dmn/daemon/foundation_gate.ex`, `dmn/daemon/schema/**`, `ui/data_source/**`, `core/protocol/**`, `apps/swarm_code_core/test/**/drift*` |
| U | `cli020/fixU`, `~/dev/swarm-code-cli-wt/fix-U` | `ui/reducer.ex`, `ui/reducer/**`, `ui/keymap*`, `ui/projector*`, `ui/layout*`, `ui/paint*`, `ui/slash_palette.ex`, `ui/state.ex`, `ui/composer.ex`, `ui/hint.ex` |
| W | site `cli020/G` (existing worktree `~/dev/llmotions-wt/cli020-G`) | `content/ncode/docs/shared/*.md`, `content/ncode/install.sh.in`, generated `code/docs/**` |

A file outside your row: write the need in your notes (`notes/fix-<lane>.md` in your worktree)
and make the smallest change only if the fix is impossible without it; the integrator resolves.

## R: terminal robustness (Opus)

- **R1** `RatatuiPort.Owner.control/2` does `true = Port.command(port, …, [:nosuspend])`. On a
  busy port this crashes the owner (`:terminal_protocol_failed`), and the TUI dies. Under macOS
  small pipes (an app holding many pipes made new pipes 512 bytes; seen 2026-10-07) the port is
  busy often. Give `control/2` the same bounded busy-port retry `grant/1` has. Draw frames must
  never crash the owner: a frame that cannot be written is superseded by the next one (keep the
  newest frame, never queue unboundedly, never drop a control message that changes terminal modes).
- **R2** Root-cause QA's unexplained close: Esc during a long stream ended with
  `terminal owner stopped: :draw` and "The terminal stopped responding" (QA session home2 logs
  under `~/.cache/ncode/cli020/qa/`). Reproduce with a PTY test whose reader stops reading for
  1-2 s while a long stream draws and Esc is pressed. Fix the cause (a 500 ms port-write timeout
  that kills the session when the terminal is merely slow is a bug: a slow terminal must slow the
  TUI, not end it; a terminal that is gone must still end it cleanly).
- **R3** Tests: an owner unit test for the busy-port path, and the PTY reproduction above as a
  regression in `scripts/dev/test_terminal_port_pty.py` (or a new PTY script) that passes.

## L: A5, the live runtime uses the synced LLM (Opus)

- **L1** Point `Daemon.Runtime.Run` (and every other live-runtime caller of the frozen `dmn/llm/**`)
  at the synced `SwarmCode.Domain.LLM` stack, which carries BUGS-28, 29, 49, 50, 51, 52 and 77.
  Remove the 13 frozen LLM ledger entries and their files once nothing calls them, through the
  provenance tooling (`repin`/ledger edit rules in AGENTS.md); never hand-edit
  `extracted-files.json` hashes.
- **L2** The frozen `llm/http.ex` carries CLI-specific behaviour (a monotonic, suspend-aware
  deadline; read `notes/A.md` A5 rows 3-11). Keep every CLI-specific behaviour that the synced
  stack lacks, as a recorded CLI provenance patch on the synced file (the AGENTS.md patch rule),
  with a test. List each kept behaviour in your notes.
- **L3** Tests through the live runtime on loopback servers (`SwarmCode.Test.LoopbackHTTP`): a
  retried request resends exactly what was sent (28); a cut-off tool call is reported, not run
  (29); a stalled stream ends at the no-progress deadline (49); pool checkout timeouts retry (50);
  the per-model effort/caps rejections (51, 52, 77). Then the full precommit (slot).

## S: daemon, wire and gate (Sonnet)

- **S1** `--approval <mode>` (B23/F8) must reach prompts drained from the queue
  (`PersistedBackend.start_queued`), workflow runs started in that session, and `/compact`.
- **S2** The retry status line says `retrying 2/5 · server`; it must name the HTTP status when there
  is one (`retrying 2/5 · HTTP 500`), else the reason word. The final failure block already says
  HTTP 500; keep it.
- **S3** Shift-Tab to Auto on an untrusted project: keep the desktop's behaviour (a manual mode pick
  marks the project trusted) and make the daemon's notice say so, e.g.
  `Approvals: read-only → auto · this project is now trusted`. No silent trust.
- **S4** A database file whose mode is not 0600 is refused with the generic "comes from an ncode
  version this ncode does not know" sentence. Give it its own sentence and action
  (`chmod 600 <path>`), checked before the schema sentence.
- **S5** `DriftTest` leaves directories in `apps/swarm_code_core/tmp/`; use `tmp_dir`/`on_exit` so
  nothing remains.

## U: client UI (Sonnet)

- **U1** Shift-Tab: the daemon's answer overwrites the client's D6 notice. Show one notice that
  carries both (the mode and the scope `(this project)`), never two that replace each other.
- **U2** The failure hint says `r retries`, but `r` is a select-mode key; in the composer it types
  `r`. Make the hint name the key that works where the focus is (`Ctrl-P → Retry` in the
  composer, `r` in select mode).
- **U3** After a rewind the header crumb still names the rewound run until the next turn; it must
  follow the rewind at once.
- **U4** `/effort` with no effort set shows no `default` row; add it (selected when the effort is nil).
- **U5** The rewind, queue, history and resume list dialogs take the full height; size them to
  their content (with the existing max). `N of M` counts only selectable rows. The queue list gets
  a row cursor; Enter on a row moves that prompt into the composer for editing (removing it from
  the queue through the existing `queue.edit` op), `d` drops it, and the footer says exactly that.
- **U6** The resume picker title reads `Conversations:  `; drop the colon and the spaces.
- **U7** The run view's composer hint `Alt-Left goes back` only works in select mode; make
  Alt-Left work from the composer when the draft is empty, or show the hint only where it works.
- **U8** Stale `queued · sends after the running turn` rows can remain in the run view after the
  queue drained; they must disappear with the queue entry.

## W: site docs (Sonnet)

- **W1** The stale shared partials from G's notes item 2: `shared/mcp.md` (Read-only asks, not
  "blocked"), `shared/providers.md` (Worker model / Validator model words), `shared/tools.md`
  (worker wording), `shared/project-config.md` (the new hook events and the `permissions` key, or
  link to `cli/project.md`), `shared/checkpoints.md` (rewind also removes the turns). Then
  `python3 tools/build_ncode.py` and the site gates of contract §4.3. Do not deploy.
- **W2** Delete `content/ncode/install.sh.in` (the unused 0.1.0 template, G notes item 3) if
  nothing reads it (grep `tools/`).
- **W3** Do not touch `code/install.sh`'s checksum, `names.json` or `releases.md`; packaging does.

## After the lanes

Integrator (Opus): `cli020/fix` from `0442eb0e`, merge R, L, S, U; repin conflicts through the
tool; compile, format, focused seams, then the full gates of contract §9.3 step 2 and the release
build of step 3. QA (Opus): all 21 scenarios of the 2026-10-07 QA again, plus the R and L
reproductions on the release. Packaging (Sonnet): the 0.2.0 tarball, stamped into the site
installer, no upload. Audit (Haiku): checksums, binary minimum macOS, transcript models.
