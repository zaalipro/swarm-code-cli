# CLI 0.2.2 (2026-10-08): binding brief

The owner approved "Yes, start now" for the small open items left after CLI 0.2.1 (published
2026-10-08: CLI main `81bfe5dc` = tag v0.2.1, pushed; desktop main `a93d6d8e` = 0.2.2, pushed;
neither changes in this round). Sources: QA result `~/.cache/ncode/cli021/wf-result.json`
(`qa.open`, `integ.open`, parity P4), QA shots `~/.cache/ncode/cli021/qa/shots/`, the 0.2.1 brief
`../2026-10-08-cli-0.2.1/00_brief.md` and its lane notes `notes/{B,C,U,K}.md`.

Rules unchanged from `../2026-10-07-cli-0.2.0/00_contract.md`: §2 hard rules, §3 provenance rule,
§4.1 worktree recipe, §4.4 suite slots, §9 gates. Commit messages `cli022 <task id>:`; each lane
ends with `cli022 <lane>: done`. CLI-only round: the desktop is not edited. If a root cause lies in
a file synced from the desktop (`provenance/extracted-files.json` lists it as synced, not
CLI-owned), stop on that item, write the exact desktop change needed in your notes and return it
as open; do not patch synced engine behaviour in the CLI.

## Lanes and ownership

| Lane | Branch / worktree | Owns |
| --- | --- | --- |
| X | `cli022/X`, `~/dev/swarm-code-cli-wt/cli022-X` | `ui/library.ex`, `ui/reducer/effort_picker.ex`, `ui/projector/dialog.ex` (effort picker only), `ui/slash_args.ex`, `ui/slash_palette.ex`, `ui/projector/composer.ex` (slash popup only), `ui/reducer.ex` (slash/effort parts), `core/commands.ex` (repin), `command_dispatcher.ex` effort clauses only (repin), their tests |
| Y | `cli022/Y`, `~/dev/swarm-code-cli-wt/cli022-Y` | `dmn/daemon/service/**` (except the effort clauses above), `core/protocol/**`, `ui/data_source/**`, `ui/read_model.ex`, `release/persisted_session.ex`, `ui/projector/vitals.ex`, the status line's effort fact, their tests |

A need outside your row: record it in `notes/<lane>.md`, make the smallest change only if
unavoidable; the integrator resolves (repins go through `mix swarm_code.provenance.repin`).

## X: pickers, dropdown, scheduled defaults (Sonnet)

- **F1 (parity P4)** A new scheduled task made in the CLI (`ui/library.ex` `new_form(:schedules)`,
  timezone value `"Etc/UTC"` at ~line 64, effort choice value `"medium"` at ~line 81) must match the
  desktop: the effort is unset by default, so the task follows Settings' `default_scheduled_effort`
  (show the choice as `default · <current default>`, and submitting it stores nil); the timezone
  defaults to the Mac's local zone (desktop: `scheduled_live.ex:79` `zone()` =
  `Next.local_zone()`, `:1091-1117` `new_task_form`, `:401-405`/`:494-500`;
  `scheduled.ex:661-668` `task.effort || settings.default_scheduled_effort`). A form field's value
  is submitted as an initial value (`ui/feature_form.ex:18`): make sure "default" really stores nil.
- **F2** The effort pickers (chat and worker, `projector/dialog.ex` ~1416 shows `default` only when
  the value is nil) always offer a `default` row; picking it clears the conversation's value so it
  follows the global default (desktop meaning of nil effort; check the desktop composer's effort
  control for the same choice and copy its words). `/effort default` and `/worker_effort default`
  do the same, and the B3 argument dropdown lists `default` for both. The status line then shows
  the effective effort (see F4). Tests: reducer + PTY (set high, then pick default, status line
  shows the default level).
- **F3** The argument dropdown opens with its cursor on the current value (not the first row), and
  marks the current value with a muted `●` before the description instead of the words
  `(current)` (U4 polish; `projector/composer.ex` `slash_popup/3`, rows carry `current?`). Enter on
  an untouched dropdown therefore re-runs the current value; that is fine. Esc unchanged.

## Y: truthful effort, quit summary, sparkline (Opus)

- **F4** With `NCODE_EFFORT=medium` set and no `/effort` yet, the status line shows no effort and
  the `/effort` dropdown marks no current value (QA 0.2.1, GUESSED cause: the conversation effort
  the client receives is nil until set). Root-cause it in code (what NCODE_EFFORT means is in the
  CLI docs/env code and `docs/settings.md`; compare how `NCODE_MODEL` shows as `env NCODE_MODEL
  wins while set` in settings). Expected: the client receives the effective effort for each slot
  (conversation value, else env, else the global default) plus its source, the status line shows
  it, and the picker/dropdown mark it (hand X the field name through notes; X marks `current?`
  from it). If an env value overrides a later `/effort`, say so in the notice like the model does.
- **F5** After `/rewind` restored `NOTES.md` to its original content, the quit summary still says
  `Files changed 1 · NOTES.md` (`release/persisted_session.ex:1070`). Root-cause where the list
  comes from; the summary must report the net change: a file whose content equals its state before
  the session is not "changed" (if the cheap rule is "drop files a rewind restored", use it and
  say so). Test with a rewind in a persisted session.
- **F6** The vitals sparkline shows fewer bars than calls (QA: the worker showed 2 bars after 4
  worker calls). Root-cause in C2's sampling (`DTO.Vitals/ModelSpeed`, 12-sample history, at most
  1 update/s): decide what one bar means (one finished model call, or one measured second) from
  the desktop speed monitor (`lib/swarm_code_web/components/speed_monitor.ex` in
  `~/dev/swarm-code`, read-only) and make the history follow it without dropping samples between
  ticks. Also: a single sample draws as a full-height block; scale a lone sample to half height or
  draw it as the newest bar on an empty track, whichever reads calmer (U's `vitals.ex`).

## After the lanes

Integrator + QA (Opus, one agent): `cli022/integration` from CLI main `81bfe5dc`, merge X then Y,
resolve, version 0.2.2 stamped like f6b957cb did 0.2.1 (four mix.exs, MCP/LSP clientInfo patch
literals re-recorded with `sync --ref a93d6d8e`, version tests, README), CHANGELOG/outcome section,
full gates of contract §9.3 step 2, the release build, then live QA of F1-F6 in the sandbox harness
(`~/.cache/ncode/cli021/qa/`) with shots in `~/.cache/ncode/cli022/qa/shots/`, plus a short
regression of 0.2.1's items (effort picker arrows, `/panel` dropdown, fetch result line, vitals at
120x40). Packaging (Sonnet): CLI 0.2.2 tarball, `cli022/site` branch stamped from the then-current
`ncode/site`, no upload. Audit (Haiku): checksums, minimum macOS, versions, transcript models.
