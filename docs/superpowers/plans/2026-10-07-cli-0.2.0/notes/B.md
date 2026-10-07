# cli020 lane B notes: headless, launcher, onboarding, `ncode config`, signals, exit summary

Branch `cli020/B` from M1 `3008f352`, worktree `~/dev/swarm-code-cli-wt/cli020-B`. Every task
B1-B23 has a commit (`git log 3008f352..cli020/B`); the last is `cli020 B: done`. Nothing was
merged, pushed or installed. Scratch files (the gate script and its log) live under
`~/.cache/ncode/cli020/B/`.

## What each task did (one line each; the commits carry the detail)

| Task | Where | What |
| --- | --- | --- |
| B1 B2 | `release.ex` `read_prompt/3`, `configure_io/1`; launcher `SWARM_STDIN_PIPED` | `-p -` reads UTF-8 stdin (256 KiB bound, empty/not-UTF-8/too-big sentences); `-p TEXT` with a pipe or file on stdin sends `TEXT\n\n<stdin>…</stdin>`; stdio encoding is `:unicode` for every headless call |
| B3 | `plain/one_shot.ex` | denied and blocked (`blocked by `/`hook blocked: `) tool calls are counted; one stderr line at the end (`N tool call(s) were denied (approval mode M): …` + the allow hint); `--fail-on-denied` (launcher, release, OneShot, plain session) exits 1 on a done run with denials |
| B4 | launcher `json_failure`, `Headless.json_failure/3` | with `--json` every failure (launcher usage errors too) prints the `not_started` object on stdout |
| B5 | `one_shot.ex` | the JSON `text` is the exact reply (no `clean/1`) |
| B6 | `plain/session.ex` | `--plain` counts refused sends and accepted denials (`{:summary, …}` before `{:closed, …}`); at EOF it waits (10 min bound) for live chat runs and an unpaused queue |
| B7 | `plain/session.ex` | `output_deadline` (default 30 s): a slow stdout is backpressure, not a failure |
| B8 | `plain/presenter.ex` `once/4` | the opening transcript prints each RUN/AGENT/TEXT once; golden regenerated |
| B9 | new `release/signals.ex` | SIGTERM/SIGHUP trapped for `-p`, `--plain` and the TUI; live runs stopped; exit 143/129; 10 s halt watchdog |
| B10 | new `release/socket_sweep.ex` | stale `/tmp/scl-p-*`/`scl-h-*` folders (own uid, >60 s, socket dead) removed at start |
| B11 | `session_selection.ex` `created`, `discard/1` | a failed start deletes the conversation (and project) it created |
| B12 | `persisted_session.ex` `prepare/2` | interactive TUI without a provider (also without endpoint/model) opens Settings › Providers with the notice |
| B13 | `session_configuration.ex` | bare `OPENAI_API_KEY`/`ANTHROPIC_API_KEY` onboard with their standard endpoint; `override_source/1`; preset display names; endpoint/model sentences |
| B14 | `scripts/dev/load_provider_env.sh` | loads per variable (no early return); a missing named file returns 2 |
| B15 | `release.ex` `flush_logs/1`; `report/2` | logs flushed (2 s bound) before every halt; `Details:` only for a non-empty log and never for provider/endpoint/model refusals or usage errors |
| B16 | launcher, `release.ex` | `help`, `version`, `-v`, `doctor`; unknown word sentence; `--help` examples, short flags, exit codes 4/129/143 |
| B17 | `config_command.ex` | get/list of a DB key while a session holds the lease exit 3 with the sentence; doctor levels (ok/note/problem), hint column, newer-database and app-open rows, own checks when a session is open; project hint; `keys` help line |
| B18 | `settings/providers.ex`, `config_command.ex` | presets by id or name (case/space/hyphen-insensitive), `presets: …` on a miss, `--base-url`, `--kind`; a transport failure says `could not reach HOST (…); the key was not saved. Use --no-test …` |
| B19 | launcher, `release.ex`, `session_selection.ex` `resolve/2`, `persisted_session.ex` `resolve_resume/2` | `--resume` takes an exact title or a 6+ char id prefix; ambiguous lists 5; bare `--resume` opens the picker (`SWARM_RESUME_PICKER=1`) |
| B20 | launcher `starting_line`; `summary_text/1` | `Starting ncode…` on a tty; erased with `\r\e[2K` by the summary and by a failure before the full screen |
| B21 | `persisted_session.ex` `summary/3`, `summary_text/1`, `exit_transcript/1` | last N exchanges (SQL as specified, 4,000 B each, 24 KiB total, CSI/OSC + control filter) and the `Spent` line; §8.4 fields pass through `start_preferences/3` and the fallback launch map |
| B22 | `plain/command.ex`, `plain/presenter.ex` | `approve-run`, `always-prefix`, `deny-stop` only when `Keymap.decisions/1` offers them; the presenter lists the offered decisions |
| B23 | launcher, `release.ex`, `headless.ex`, `one_shot.ex` | `--output-format text|json|stream-json`, `--max-turns N`, `--max-budget-usd X`, `--approval MODE` (exported, refused until F8) |

## Deviations (the smallest change that keeps the contract's intent)

1. **Test paths.** The contract names `test/swarm_code_cli/release/*_test.exs`; that directory is a
   `locked_branch_test` conditional path (it asserts `conditional_paths == […/release]` and fails
   when the directory exists). Every new release test is under `test/swarm_code_cli/entry/`
   (`read_prompt`, `io_encoding`, `headless_json`, `signals`, `socket_sweep`, `report_details`,
   `resume_selection`, `exit_summary`), moved in `175e23e`.
2. **B1/B2 tests-first.** Their code was written before their tests (same commit); every later task
   wrote the test first and watched it fail.
3. **B3/B6 `--plain --fail-on-denied`** is a `{:summary, %{refused:, denied:}}` notification the
   plain session sends before `{:closed, reason}`, not new close reasons.
4. **B11** deletes with `Repo.delete_all` in one immediate transaction: `Conversations.delete/1`
   needs Engine, LSP and cache processes that are not up when a start fails.
5. **B12** also opens Providers for `:model_required` and `:endpoint_required` on the interactive
   TUI: with B13, an exported `OPENAI_API_KEY` alone (no model) would otherwise still exit 3. The
   PTY test waits for `Settings › Providers` and `No provider yet`: the notice toast sits under the
   Settings layer and is not on screen.
6. **B16** tests are in `entry/launcher_test.exs` (the launcher stub harness), not
   `scripts/dev/test_launcher_environment.py`.
7. **B17** `config list` with the lease held prints the cli keys on stdout and exits 3 with the
   sentence when the listed section has database keys (the `(unavailable…)` rows are gone).
   Doctor's levels and hints are decided in the client (`ConfigCommand.doctor_level/1`); the
   daemon's `settings/doctor.ex` is not lane B's file and is unchanged. Search, MCP servers, the
   research folder and a keyless provider beside a usable one are notes; no provider, a broken
   project file or cli.json, the config folder, a newer database (`:schema_incompatible`) and
   the open app (`:desktop_active`) are problems (exit 1). The newer-database/app rows come from
   the foundation's refusal codes, so a pristine install with a provider exits 0.
8. **B19** resolution lives in `SessionSelection.resolve/2` (daemon, read-only SQL) and is called
   from `PersistedSession.open_session/3`, the one place every mode (TUI, `-p`, `--plain`)
   passes; the release and the launcher accept any non-blank value without control characters.
   Bare `--resume` with `-p`, `--plain` or without a terminal is a usage error naming the picker.
9. **B20**'s launcher half (`starting_line`) went into the B19 commit `50a3006`; the release half
   is in `c5d84ae`. A failure before the full screen also erases the line (only when stdout is a
   terminal and the session is not a test boot).
10. **B21** reads `exit_transcript` from cli.json's validated values: until E26 adds the registry
    key, `CliFile.read_all/1` reports it as unknown and the default 3 applies. Besides the
    control-character filter of `one_shot.ex` `clean/1`, CSI and OSC sequences are removed whole
    (else `\e[31m` would leave `[31m` in the scrollback). Continuation lines of a `›`/`$` row are
    indented two spaces. A clipped row ends with `…`.
11. **B22** checks the new verbs against `Keymap.decisions/1` (the full screen's rule), which
    needs `allowed_decisions` on the interaction or its approval; the old `approve`/`deny`/
    `always-allow` verbs are unchanged. The presenter's command lines now list
    `Keymap.decisions/1` (same output when no `allowed_decisions` is sent; golden unchanged).
12. **B23 stream-json** feeds the workspace watch's deliveries through a `Plain.Presenter`
    (`format: :ndjson`) and writes each record as `{"stream","text"}` (the `--plain --ndjson`
    shape), then `{"type":"summary", …the --json object…}`. It covers the conversation the
    one-shot opened (a new one unless `-c`/`--resume`), not only the run. `--max-budget-usd`
    stop words: `ncode: stopped at --max-budget-usd X (the run cost $Y).` (the contract fixes only
    the turns sentence). The "no cost" line is said once, when an owned run ended with a nil
    cost. A launcher usage error with `--output-format stream-json` prints the not_started object
    with `"type":"summary"`. The untrusted-project refusal of `--approval auto|full` (exit 3) is
    not implemented: it needs F8's dispatch option and lands with the stub's removal.

## Stubs the finisher removes (§8.1)

- **B23 `--approval`**: `SwarmCodeCLI.Release.headless_approval/1` (private, `release.ex`) returns
  `{:error, "--approval needs the 0.2.0 engine."}` (stderr `ncode: --approval needs the 0.2.0
  engine.`, exit 2) when the flag or `SWARM_HEADLESS_APPROVAL` is set. After A'1: return
  `{:ok, Map.put(options, :approval, mode)}`, pass `approval_mode:` from `headless_options/1` via
  `Headless.run_session/3` into `OneShot` and from there into the dispatch (F8), refuse
  `auto`/`full_access` in an untrusted project with `/approval`'s sentence (exit 3), and replace
  the test `release_test.exs` "--approval waits for the 0.2.0 engine".
- **B21 `"shell"` rows**: the exit transcript reads `role IN ('user','assistant','shell')`; until
  the finisher flips C's `shell_message_role/0`, `!cmd` rows are stored as `swarm` and do not
  show (the test inserts `shell` rows directly).
- **B13 `SessionConfiguration.override_source/1`** exists for C13 (no stub; listed for the merge).
- **B21 `exit_transcript`**: inert until E26 registers the cli.json key (default 3 meanwhile).

## AGENTS.md text for the finisher (CLI repo)

> - **Headless (`-p`).** The launcher owns the grammar and exports; the release re-validates.
>   `-p TEXT` with a pipe or file on stdin sends the stdin after the prompt
>   (`SWARM_STDIN_PIPED=1`, set only by the launcher); `-p -` reads the prompt from stdin.
>   `--json`/`--output-format json` print one object even on failure (`state: not_started`);
>   `--output-format stream-json` prints the `--plain --ndjson` records and ends with
>   `{"type":"summary",…}`. `--max-turns`/`--max-budget-usd` stop the owned run (exit 1);
>   `--fail-on-denied` fails a done run that had denials. Denials are said in one stderr line.
> - **Exit codes:** 0 done, 1 failed, 2 usage, 3 refused, 4 changed elsewhere (`ncode config`),
>   129 SIGHUP, 143 SIGTERM (`Release.Signals`; SIGINT stays under `+Bd`).
> - **New release tests go under `apps/swarm_code_cli/test/swarm_code_cli/entry/`**:
>   `test/swarm_code_cli/release/` is a locked-branch conditional path and must not exist.
> - `--resume` takes an exact title or a 6+ character id prefix (`SessionSelection.resolve/2`);
>   bare `--resume` opens the picker (`SWARM_RESUME_PICKER=1`, TUI only).
> - The TUI exit summary (`PersistedSession.summary_text/1`) starts with `\r\e[2K` (it erases
>   the launcher's `Starting ncode…`), then the last `exit_transcript` exchanges, then the block
>   with `Spent`. Never in `-p`/`--plain`.
> - `Details: <cli.log>` is printed only for a non-empty log and never for refusals the sentence
>   itself fixes; logs are flushed before every `System.halt`.
> - Stale `/tmp/scl-p-*`/`scl-h-*` folders are swept at start (`Release.SocketSweep`).

## Tests and gates run (final state, before the done commit)

- `mise exec -- mix format --check-formatted`: clean (after one `mix format` of
  `entry/headless_json_test.exs`). `mise exec -- mix compile --warnings-as-errors`: rc 0.
- `locked_branch_test.exs`: 8 tests, 0 failures. Plain golden
  (`test/fixtures/plain/three_run_output.txt`, regenerated in B8): the demo still produces it
  byte for byte after B22/B23.
- CLI app, one call: `test/swarm_code_cli/entry`, `plain`, `demo`, `persisted_session_release_test`,
  `ui/pass73_mouse_test`, `c74_acceptance_test`: 258 tests, 0 failures.
- Daemon app, one call: `session_selection_test`, `session_configuration_test`,
  `settings/c74_providers_test`, `settings/c74_values_test`: 53 tests, 0 failures.
- `scripts/dev/test_launcher_environment.py`: 7 OK. `scripts/dev/test_saved_session_pty.py`:
  2 OK (the B12 fresh-database case among them; test storage under a temp root, never HOME).
- No full suite (§4.4). No release was built or run, no install.sh, no real provider call.
- Noise seen and not chased: `c74_config_command_test.exs` logs a few
  `Exqlite.Connection … database is locked` reconnect errors while passing (seen with the
  committed tree too; whether M1 already logs them was not checked).

## Assumptions

- Verified: the workspace watch receives `agent_update` deltas (`persisted_backend.ex`
  `broadcast/2`, slot `"workspace"` takes every kind but activity/toast/rate_limit), so
  `--max-turns` can read the lead's `turn` from the read model.
- Verified: startup refusals carry `:code` (`PersistedSession.startup_failure/2`), and the codes
  `:desktop_active`, `:schema_incompatible`, `:data_lease_held` exist (`foundation_gate.ex`,
  `Schema.Refusal`).
- Verified: `CliFile.read_all/1` drops keys the registry does not know (so `exit_transcript`
  needs E26).
- Guessed: real daemons send `allowed_decisions` on approvals that offer `approve_run`/
  `always_prefix`/`deny_stop` (the codec decodes the field; the demo sends it); without it the
  plain verbs are refused, as the full screen does.
- Guessed: ids are stored lowercase in SQLite (`Ecto.UUID` text); the prefix match lowercases
  the input and the fixture test passes.
