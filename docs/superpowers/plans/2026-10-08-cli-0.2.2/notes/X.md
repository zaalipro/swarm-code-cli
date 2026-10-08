# cli022 lane X notes (pickers, argument dropdown, scheduled defaults)

Branch `cli022/X` from CLI `main` `4fd44d18`, worktree `~/dev/swarm-code-cli-wt/cli022-X`
(contract §4.1 recipe). Not merged. Done: F1, F2, F3. Open: the `default · <current default>`
words of F1 (needs a value from the daemon, below) and the live "set high, pick default, status
line shows the default level" check (needs lane Y's F4 and a Fake fix, below).

## What changed

### F1 (parity P4): scheduled-task defaults

- `ui/library.ex` `new_form(:schedules)`:
  - `timezone` is no longer `"Etc/UTC"`/required: it starts blank, is optional and its label says
    `Timezone (blank = this Mac's)`. A blank zone is submitted as nil and the daemon fills it:
    `Scheduled.Task.changeset` does `put_default(:timezone, Next.local_zone())`, which is the
    function the desktop's `scheduled_live.ex` `zone()` calls. Root cause of not computing it in
    the form: `ui/**` may not reference the daemon (`ui/architecture_test.exs` scans `lib/` for
    `swarm_code_daemon`, `:code.`, `Module.concat`, `ensure_loaded`), the CLI app depends on core
    only, and `Next.local_zone/0` lives in the daemon's synced domain. So there is exactly one
    implementation of "the Mac's zone", the desktop's, and it cannot drift.
  - `effort` is a choice with `default` first and as the initial value (label
    `Effort (default follows Settings)`). `FeatureForm.parse_value(:choice, …)` submits the
    choice `default` as nil (`ui/feature_form.ex`, a 3-line clause; the brief named the initial
    value at `feature_form.ex:18` as the trap). The stored value is therefore nil and the task
    follows Settings' `default_scheduled_effort` (`scheduled.ex:661-668`).
- `Library.schedule_form/1` gives a daemon-supplied form (`FeatureCatalog.schedule_form`, which
  has `effort` as `low|medium|high|max` and a blank value for an unset effort) the same `default`
  choice, and shows a blank effort as `default`. The reducer applies it to every `:schedules`
  form it opens (new and edit), so editing a task can also give its effort back to the default.
  The daemon's own `fresh` "new" item is only sent without a conversation scope; the CLI's
  library is conversation-scoped, so in practice `Library.new_form(:schedules)` is the form used.

### F2: `default` row in the effort pickers and commands

- `core/commands.ex` (frozen entry, repinned): `/effort default` and `/worker_effort default`
  (also `/swarm_effort default`, any case) parse to `:set_effort` with `effort: nil`, whatever
  levels the model offers; the usage text is `[default|low|medium|high|max]`.
- `daemon/service/command_dispatcher.ex` (frozen entry, repinned), `execute(:set_effort)`: a nil
  effort writes `%{effort: nil}` / `%{swarm_effort: nil}` (it used to call `Atom.to_string/1`).
  Checked end to end: `Conversations.update` casts the nil, `validate_format` skips nil, the
  `quiet_update` path stores it (`command_dispatcher_test.exs`: "cli022 F2 …" set high/max, clear,
  clear again). `Atom.to_string(nil)` would have stored the string `"nil"`; the test pins that.
- `Reducer.EffortPicker.rows/2`: `["default" | levels]` always (it was only added while the
  effort was nil). `command/2` accepts `default`. `{:effort_pick, "default"}`: nil effort -> only
  closes (nothing to change); a level is set -> sends `/effort default` (`/worker_effort default`).
  The dialog (`projector/dialog.ex effort_picker`) always draws the `default` row; the cursor
  opens on the current row (`default` while nothing is set).
- Desktop meaning: the desktop composer's effort control is a slider with no `default` stop, so
  there are no desktop words to copy; the CLI's words are `default` (row), `Follow the global
  default` (dropdown description) and the notice `Effort follows the default` in the Fake.
- `Fake` (`data_source/fake/session.ex`, Y's file, one hunk): `:set_effort` with a nil effort
  clears the value instead of `Atom.to_string(nil)`, notice `Effort follows the default`.

### F3: dropdown cursor and the muted dot

- `SlashPalette.index/1`: with no saved cursor, the argument list opens on its first
  `current?` row (command lists still on the first row). An edit resets the palette state, so
  typing re-aims the cursor at the current row among the rows that still match. Enter on an
  untouched list re-runs the current value (`arg_enter` takes `selected/1`).
- `SlashArgs`: the `(current)` words are gone (`mark/2` deleted); rows keep `current?`. The
  effort lists start with `default` (current while the stored effort is nil).
- `Composer.slash_popup/3`: an argument row draws `● ` (`text_muted`) before the description on
  the current row and two blanks on the others, so the description column stays aligned; `*`
  where the dot is not one cell (ASCII terminals, wide ambiguous-width policy). Command rows
  (the `/` list) have no mark slot.

## Seam with lane Y (F4): the field names X reads

`EffortPicker.effective/2` is the only reader. It reads the workspace snapshot's
`:effective_effort` (chat) and `:effective_swarm_effort` (worker), a binary or nil, with
`Map.get`, so nothing breaks while the fields do not exist (stub: returns nil). Where it is used:

- the picker's ticked `default` row reads `default · <level>` (label, so it shows in monochrome
  too) with `in use` at the right;
- the dropdown's `default` row describes itself `Follow the global default · <level>` while the
  stored effort is nil.

I mark `default` as the current row while the stored value (`effort`/`swarm_effort`) is nil, and
the stored level otherwise; the effective level is only worded, never ticked. If Y names the fields
differently, change the two atoms in `EffortPicker.effective/2`. If Y wants the effective level
ticked instead (no `default` mark while env/global resolves to a level), that is the one
`current?` computation in `SlashArgs.all(state, "effort")` and `projector/dialog.ex effort_picker`.

## Open / hand-overs

1. `default · <current default>` for the scheduled effort (F1): the CLI does not hold
   `default_scheduled_effort` outside the settings layer, and `LibrarySnapshot`/`FormField` carry
   no such value. The choice reads `default` and its label says `follows Settings`. To show the
   level the daemon has to send it with the schedules library (e.g. a `FormField.hint` or a
   field of the "new" form built where `FeatureCatalog.query_rows(:schedules)` runs, which is a
   synced desktop file, or `Daemon.Service.FeatureRequest` for the CLI) and `Library.new_form/1`
   to take it as an option. Not done: crosses lane Y's wire and the synced catalogue.
2. Demo Fake drops its `workspace_metadata` deltas (`ReadModel.delta/3` ignores a delta whose
   `revision <= snapshot.revision`, and `Script.sequence/2` stamps `script.revision + 1`, below
   the workspace snapshot's revision in the demo). So in the terminal demo a level chosen with
   `/effort high` never reaches the open snapshot: the picker opens on `default` again. Seen in
   the PTY (second picker open showed `✓ default`). The reducer tests cover "set high, then pick
   default" with a snapshot that carries the level; the PTY test covers the dropdown, the
   `/effort default` command, the notice and the picker's default row. A live "set high, pick
   default, status shows the default level" run needs this Fake fix (Y's `data_source/fake/**`)
   plus F4's status line.
3. The persisted-session notice for `/effort <level>` is nothing today (`persisted_backend.ex`
   answers `:updated` without a feedback). Y's F4 notice ("an env value overrides a later
   /effort") belongs there.

## Files touched

`ui/library.ex`, `ui/feature_form.ex` (3 lines, outside the row's list, named by the brief),
`ui/reducer.ex` (`effort_pick` + the schedules form), `ui/reducer/effort_picker.ex`,
`ui/projector/dialog.ex` (picker only), `ui/projector/composer.ex` (slash popup only),
`ui/slash_args.ex`, `ui/slash_palette.ex`, `core/commands.ex`, `daemon/service/command_dispatcher.ex`
(effort clause), `ui/data_source/fake/session.ex` (one hunk), `provenance/extracted-files.json`
(repin of the two frozen entries), tests, `scripts/dev/test_terminal_demo_pty.py` (one new test).

## Tests and gates run

See the end of this file (filled in by the done commit).

- `mix format`, `mix compile --warnings-as-errors --force`: clean.
- `mix swarm_code.provenance.repin` for `core/commands.ex` and `command_dispatcher.ex`, then
  `provenance.verify` and `provenance.sync --check`: both pass.
- `swarm_code.keymap --check`: matches; `swarm_code.settings --write`: `docs/settings.md` unchanged.
- New tests: `core/test/swarm_code/cli022_x_commands_test.exs` (3), `daemon/.../command_dispatcher_test.exs`
  ("cli022 F2 …" clears the stored effort), `cli/test/.../ui/cli022/x1_effort_default_test.exs` (7),
  `x2_dropdown_test.exs` (9), `x3_schedule_form_test.exs` (5); written first and seen failing. Updated
  for the new behaviour: `ui/cli020/d18_effort_picker_test.exs`, `ui/cli021/b1_effort_picker_test.exs`,
  `ui/cli021/b3_arg_dropdown_test.exs`, `cli020/e3_palette_rows_test.exs`.
- Full CLI app suite (`mix test apps/swarm_code_cli/test`, suite slot): 3190 tests + 10 properties,
  3 failures, all in `d18_effort_picker_test.exs` (they encoded the old "no default row while a
  level is set"); fixed, file re-run green (9 tests), cli020/cli021/cli022 ui dirs re-run green.
- Core command tests (45) and `command_dispatcher_test.exs` (11): green.
- PTY: `scripts/dev/test_terminal_demo_pty.py` whole file (11 tests incl. the new
  `test_effort_default_row_and_marked_dropdown`): OK.
- Not run: the daemon and core full suites (only the files above), the other three PTY suites
  (nothing in them touches these paths), `scripts/dev/check_terminal_port.sh` (no Rust change).
