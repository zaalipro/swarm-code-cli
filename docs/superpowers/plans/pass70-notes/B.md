# pass70 owner B notes

Owner B: runtime, storage safety, terminal robustness, launcher. Branch `p70/B`, merged
`p70-A-sync` at 28b244f. Every task B1–B10 landed; nothing is blocked.

## Landed

| Task | Commits | What |
|---|---|---|
| B1 P0 | 3f13afb | Killing a guarded-checkout holder no longer crashes the pool connection (the MatchError) or pins cleanup. Changes: the vendored exqlite `disconnect/2` always returns `:ok`; prepared statements are unpinned on bound connections (`ref: nil` after execute); CrossAppLease retires a replaced slot's handle that SQLite refused to close and closes it at drain; RepoLauncher cleanup is bounded (50 attempts, with a VM-wide GC at attempt 10), and `close/1` returns `:ok \| {:error, :cleanup_unconfirmed}`. Regression test: close is `:ok` in under 3 s after a kill. |
| B2 P0 | 2346fe4 | The terminal owner never ends the session over a frame. A paint or encode error keeps the previous plan, adds one reverse-video error line and logs once per reason. A busy port or a stale slot answers `:stale_revision`, and a draw that arrives while one is pending is queued (newest wins). A 1 s soft deadline answers stale; only 60 s of silence counts as a dead terminal. The port's OS process is reaped with TERM, then KILL after 500 ms. The tty opens `O_NONBLOCK`, then goes back to blocking (rel F17). |
| B3 + B9 P0/P1 | 2774270 | Failures print one line, `swarmcode: <sentence>`, then the action and `Details: <log>`, with exit status 1 (failure), 2 (usage) or 3 (startup refused); never a stack trace. Logger writes to `~/Library/Logs/SwarmCode/cli.log` (XDG state on Linux): 0600 file, 0700 directory, 3 × 2 MiB rotation, and never to the tty. Exit summary: title, last prompt, files changed, "Stopped N live runs", first-run note, `swarmcode --continue`. `SWARM_RELEASE_MODE` selects the tui, headless or plain entry. |
| B4 P0 | ee16835 | Decision D3: the database picks the model. `SWARM_*` never write provider rows or rewrite conversations. `SWARM_MODEL_OVERRIDE` is an in-memory session override resolved against the DB providers. First-run onboarding happens only when no usable provider exists. `load_provider_env.sh` passes only `SWARM_*`, `OPENAI_*` and `ANTHROPIC_*` out of the env file, evaluated in a clean child shell. |
| B5 P0 | 52b570a | The global dir is resolved at run time: macOS `~/Library/Application Support/SwarmCode`, else `XDG_CONFIG_HOME` or `~/.config/swarm-code`, else absolute `SWARM_CODE_CONFIG_DIR`. The builder's home no longer ends up in `sys.config`. |
| B6 P0 | 9aa8f22, 387e8c4 | Runtime children: `Tools.BackgroundProcs`, `Hooks.TaskSupervisor`, `LSP.Supervisor`. `SwarmCode.Daemon.Boot` gives desktop Bootstrap parity and `SwarmCode.Daemon.Shutdown` gives desktop Quit parity; both are wired into the saved session. A's requests are done: backup verification skips FTS5 shadow tables, and the session_selection test expects `read_only`. |
| B7 P1 | 255bc65, c843b4c | `RELEASE_DISTRIBUTION=none` and `umask 077`; the COOKIE is 0600 (build and install). A second `swarmcode` exits 3 with "Another swarmcode (process N, since HH:MM) is already using your conversations." The locked-branch audit pins the new `rel/env.sh.eex`, and the release test moved out of the audit's reserved path. |
| B8 P1 | 8c309dd | The port writes only changed cells. Each dirty row repaints one span, widened to whole glyphs of both frames, with one cursor move, SGR only on a style change, and implicit advance over exact ASCII. Wide or non-ASCII glyphs reserve their columns and re-anchor; an old uncertain glyph is erased with ECH. |
| B10 P2 | 0eaa8d5, (fix below) | Clipboard copy writes OSC 52. Opt-in SGR wheel reports, `SWARM_MOUSE=1`. |

## Contracts (for C, D, E and the finisher)

- **Exit statuses** (`SwarmCodeCLI.Release.PersistedSession`): 0 ok, 1 failure, 2 usage, 3 startup
  refused (another swarmcode/desktop holds the data, schema from a newer/older app, no provider).
- `PersistedSession.with_saved_session(opts \\ [], fun) :: {:ok, term} | {:error, failure}`:
  - boots exactly like the TUI: log file, lease, migrations, selection, provider resolution and
    `Boot.run/0`
  - calls `fun.(%{project:, conversation:, notice:})`
  - then runs `Shutdown.run/0` (it stops live runs, so `fun` must wait for its own runs) and
    closes storage
  - opts: `:project_root`, `:conversation` (`:latest | :new | uuid`)
  - never raises
- `PersistedSession.report(failure) :: status` prints the failure; `log_path/0` returns the log
  path.
- `SWARM_RELEASE_MODE` selects the entry through the fixed table in
  `PersistedSession.run_entry/1`:
  - `tui` (default): `PersistedSession.run/0`
  - `headless`: `SwarmCodeCLI.Release.Headless.run/0`
  - `plain`: `SwarmCodeCLI.Release.Headless.run_plain/0`
  - every entry returns an exit status; the application calls `System.stop(status)`
  - an unknown mode, or an entry not built yet, is exit 2
  - the table lives under `release/`, the directory the UI architecture test lets look modules up
- `SwarmCode.Daemon.Service.SessionConfiguration`:
  - `overlay(conversation)`: applies the session override in memory
  - `override/0`: `%{provider_id, model}` or nil
  - `clear_override/0`
  - `notice/0`: the first-run sentence, or nil
- `SwarmCode.Daemon.RepoLauncher.close/1 :: :ok | {:error, :cleanup_unconfirmed}` (20 s bound).
- `SwarmCode.Daemon.Boot.run(opts) :: %{interrupted: n, failed: [step]}`:
  - runs `mark_interrupted`, `reconcile_scheduled`, `seed_defaults`, `adopt_legacy_search_key`,
    `start_mcp`, `sweep_researches`, `prune_attachments`, plus the delayed isolation sweep
  - retries each step after 100, 250 and 500 ms; a failing step never stops the session
  - it does not start the Scheduler or the Watchdog (the desktop owns scheduled work)
- `SwarmCode.Daemon.Shutdown.run(opts) :: %{paused:, stopped:, reaped:}`:
  - pauses workflows, runs `Engine.stop_all`, then kills background commands
  - waits up to 10 s for flush
  - stops the runs, research, MCP and LSP subtrees
- Clipboard copy: send `{:terminal_copy, text}` to the terminal pid the runtime registered
  (`state.terminal`).
  - This is the renderer-neutral form. The UI architecture test forbids naming `RatatuiPort`
    outside `ui/renderer/ratatui_port/`, which is why there is no facade module.
  - `RatatuiPort.Owner.copy(pid, text) :: :ok | {:error, :invalid_text}` is the same message plus
    validation in the caller.
  - `text` is 1..65,536 bytes of UTF-8; LF and TAB are the only controls allowed, and CRLF
    becomes LF.
  - Asynchronous. Invalid text is logged and dropped. The text is also dropped while the terminal
    is suspended, and terminals without OSC 52 ignore it.
- Owner `flags: %{mouse?: true}` (saved session: `SWARM_MOUSE=1`):
  - a wheel notch arrives as `{:mouse, :wheel_up | :wheel_down, nil, column, row, modifiers}`,
    already valid in `UI.Input`
  - clicks are consumed
  - `caps.mouse == :best_effort`
- Wire additions:
  - init flag bit 16
  - command tag 7: Copy `1, 7, gen::64, token::64, len::32, text`
  - input payload 6: `6, dir(0 up / 1 down), mods, col::16, row::16`
  - the guard's mode byte 8 still means restore

## Requests for other owners

- **C** (backend/dispatcher):
  - Before every `Engine.start_*` and in `effective_model_name`, pass the freshly loaded
    conversation through `SessionConfiguration.overlay/1`. The `--model` override lives only
    in memory.
  - After a successful `/model` choice, call `SessionConfiguration.clear_override/0`.
  - Show `SessionConfiguration.notice/0` once as a toast.
- **C**: `service/wire_contract_test.exs` fails 10 tests on `checkpoints.conversation_id`. See
  A's notes; the fixture must set the ownership ids on the struct.
- **D**:
  - The release still passes `banner: :persisted_banner`, and at ≥ 120 columns the header reads
    "SWARMCODE  SAVED · DEV · Build". Its words should not say DEV in a release. Either D
    renames the chrome, or D/E agree on a release banner and B passes it; a one-line change in
    `persisted_session.ex`.
  - The final paint on quit reads "DETACHED — RUNS CONTINUE", but quitting now stops the runs
    (`Shutdown`). The exit summary says "Stopped N live runs."
- **E**:
  - `bin/swarmcode` (rel overlay) should:
    - set `SWARM_MODEL_OVERRIDE` for `--model`
    - set `SWARM_CONVERSATION` for `--new`, `--resume <id>` and `--continue`
    - say in `--help` that providers come from the database (the old help still lists
      `SWARM_MODEL (required)`)
    - drop `SWARM_APPROVAL` from the help; the project's mode rules (D4)
  - Implement `SwarmCodeCLI.Release.Headless.run/0` and `run_plain/0` per the entry table, or
    build them on `with_saved_session/2`.
  - Route `{:mouse, :wheel_up | :wheel_down, …}`: `Keymap.route` ignores mouse today. Use
    `{:terminal_copy, text}` for `y`.
  - The runtime's own stderr lines ("SwarmCode closed: …") and `begin_shutdown(:invalid_scene)`
    in `session_runtime.ex` still use the old wording.
  - Seen in the sandbox (old UI):
    - Ctrl-C answers "DETACH REQUIRES CONFIRMATION"
    - `/quit` is "REJECTED"
    - opening an approval with `n` at 80×24 shows "Read-only at this size"
    - after Esc, `n`/`N` say "Nothing is waiting on you" while the run still waits (the
      interaction left the read model)
    - Esc then `q` quits
- **Finisher**: `apps/swarm_code_daemon/test/support/schema_fixture.ex` is shared. A added the
  four prefix versions; B made `row_counts/1` skip FTS5 shadow tables, mirroring the backup gate.
  Keep both on merge.

## Manifest-listed files edited

None. `vendor/exqlite` is not a provenance entry; its patch is recorded in
`vendor/exqlite/SWARM_PATCHES.md`. `domain/runtime.ex` and `domain/paths.ex` are CLI-owned.

## Verification

- Focused suites, all green:
  - `repo_launcher_test` (3)
  - `boot_test` (2)
  - `shutdown_test` (1)
  - `session_configuration_test` (5)
  - `session_selection_test`
  - `domain_paths_test` (4)
  - `backup/*` + `foundation_gate_test` (58 + 34)
  - `service/*`: all pass except C's 10 `wire_contract` tests
  - CLI `renderer/ratatui_port/*` (29)
  - `locked_branch_test`
  - `persisted_session_release_test` (4)
- Rust: `scripts/dev/check_terminal_port.sh`, which runs fmt, all crate tests and the license
  check (17 output, 10 protocol and 21 input tests among them). The PTY suite
  `test_terminal_port_pty.py` has 15 tests, including OSC 52 and the wheel; 5 of 6 runs were OK.
  One run had a `response timeout` in a test the log did not name. The new test passed 12 times
  out of 12.
- `scripts/dev/test_launcher_environment.py` includes the env-scrub test. It fails on the old
  loader.
- Sandbox release (HOME under `/private/tmp/p70cli/p70-B`, a copy of a 53-DB, `~/dev/ailogic`
  scratch copy). Real prompts used: 5 of 10.
  - Pre-sync: a TUI prompt answered "pong". Exit summary, exit 0. Providers, settings and other
    conversations were byte-identical despite `SWARM_*`. The log is 0600. A second session exits
    3 with the lease sentence. Non-TTY exits 2.
  - Post-sync: the launch backed up the DB and migrated it 53 → 57. Boot recovery ran and the
    session opened. On quit with a waiting run, the summary said "Stopped 1 live run."
  - B4 env check: I launched with `env -i` plus a dummy shell-exported `GITHUB_ACCESS_TOKEN`
    and `SWARM_ENV_FILE=~/.secrets`, and a model-run `run_command` of
    `env | cut -d= -f1 | sort` (names only). The tool result in the DB lists only:
    `_ __CF_USER_TEXT_ENCODING GIT_TERMINAL_PROMPT HOME LANG LOGNAME OLDPWD PATH PWD SHELL SHLVL
    SWARM_BASE_URL SWARM_EFFORT SWARM_ENV_FILE SWARM_MODEL SWARM_PROJECT_ROOT SWARM_PROVIDER
    SWARM_RELEASE_TUI SWARM_TERMINAL_PORT TERM USER`.
    - No `GITHUB_ACCESS_TOKEN`: removed by the domain scrub.
    - No `DEPLOY_HOST`, `CLI_DEFAULT`, `TBH_*` or `LLMOTIONS_BASE_URL`: the loader never loads
      them.
    - No `*_API_KEY`: scrubbed.
    - The sandbox project was set to `full_access` for this check, because the old UI could not
      approve.
  - B8 before/after, same session and 160×45 screen:
    - a keystroke took 11,917 B with the old painter and 83 B with the new one
    - a 12-line streamed answer took 1,562,475 B with the old painter and 13,905 B with the new
      one
    - the synthetic budget test (truecolor, one glyph per char) measured 54 B per keystroke, a
      worst streamed delta of 8.3 KB, and 13.9 KB for a full frame
  - Every screen session I started is closed. I killed only pids I started.
- Full umbrella suite, format and warnings: see the final section below.

## Leftovers

- The PTY "pty closed during bind" case from B2 was not added.
- `scripts/dev/test_saved_session_pty.py` is stale: it expects 46 migrations and the old UI, and
  was not rerun.
- `Boot.run` runs `Providers.seed_defaults/0` on an empty database, exactly like the desktop, so
  a brand-new install gets the keyless `llmotions` row. The first-run onboarding then adds or
  fills the `SWARM_*` row.
- Wheel reports are off by default: they disable the terminal's own selection. E decides whether
  the TUI asks for them.
