# Fix round, lane U notes (cli020 fix round, 2026-10-08)

Branch `cli020/fixU` from CLI `main` `55dbe5a2`, worktree `~/dev/swarm-code-cli-wt/fix-U`.
Brief: `01_fix_round.md`, tasks U1 to U8. Tests: `ui/cli020/d6_mode_cycle_test.exs` (U1),
`ui/projector_shell_tabline_test.exs` (U3), `ui/cli020/d18_effort_picker_test.exs` (U4),
`cli020/e9_palette_rows_test.exs`, `ui/projector/workspace_turns_test.exs`,
`ui/paint/projector_test.exs` (U2), and the new `ui/fix_round_u_test.exs` (U5 to U8, each at 80x24,
120x36 and 160x48 where it draws).

## Per task

### U1 one Shift-Tab notice
- `State.cycle_notice` (`%{words, mode, at}`) holds the step's own words (mode and scope, e.g.
  `Auto · edits and safe commands run · Shift-Tab: Plan (this project)`) for 5 s.
  `note_policy_change/2` (the daemon's mode change) and `settle_service/3` (its answer to this
  step's `project_update`) keep those words instead of replacing them, in either arrival order.
  The change is still recorded in `policy_notices` (the transcript line).
- Trust remark: the client has no trusted field on the workspace snapshot, so when the daemon's
  answer text says the project was `trusted`, the notice appends ` · this project is now trusted`
  (lane S3 writes `Approvals: read-only → auto · this project is now trusted`). It does not parse
  anything else of the daemon's text. A mode change made some other way afterwards, and a refusal
  (which also clears `cycle_notice`), keep their own words.

### U2 failure hint
- `Turns.next_step_text/2` names `r retries · Ctrl-P Retry failed run` only when `state.focus` is
  `"main"` (select mode, where `r` retries) and `Ctrl-P → Retry failed run` everywhere else (the
  arrow is `->` on an ASCII terminal, `›` where `→` is wide).

### U3 header after a rewind
- The title row's tab for the run in view (`Shell.active_run_id/1`) is dropped when that run is
  `:superseded` and the destination is a conversation (the rewound turn's run). A run opened on
  its own (`{:run, id}`) keeps its tab.

### U4 `/effort` default row
- `EffortPicker.rows/2` adds a leading `default` row while the effort is nil; the picker opens on
  it, draws it ticked, and Enter on it only closes the picker.
- Known limit: nothing resets a set effort to nil. `Commands.parse` (core `commands.ex`, a frozen
  ledger file nobody owns this round) accepts only the five levels, so `default` is shown only
  while the effort is nil and is never offered as a way back.

### U5 list dialogs
- `Dialog`: the rewind, history and queue lists, and (now also at 80x24, class `:narrow`) the
  pickers, are as tall as their rows up to the existing maximum; "N of M" counts only rows a
  cursor can be on (`selectable?/2`: rewind `turn-*`, history `history-*`, queue `queued-*`; the
  query, hint, pause and empty lines are not counted). Rewind's in-body keys line moved into the
  footer (`2 of 3 · ↑↓ choose · Enter rewinds to it · Esc closes`).
- Queue list: the cursor (`state.selection["queue_list"]`) is a drawn row; footer
  `1 of 2 · Enter edits · d drops · Esc closes`. Enter is the new action `{:queue_take}` ->
  `QueueCommands.take_selected/1`: it sends the existing `queue.edit {:drop, n}` and, when that is
  accepted, puts the text in the composer (one undoable replacement; a draft already typed keeps
  its place and the text follows on a new line) and closes the list. A refused edit leaves
  everything as it was; a text of 2000 bytes or more (the daemon cuts queued texts at 2 KB) is not
  taken: the notice says d drops it or let it run.

### U6 resume title
- `switcher_title/1`: a prefix with nothing typed after it is its bare name (`Conversations`,
  `Commands`, `Actions`, `Projects`, `Search results`); with a query it is `Name: query` as before.

### U7 Alt-Left
- `Keymap.Layers.key/3` answers Alt-Left first when no layer is open, the composer has focus and
  the draft is empty: `:back` when there is a history, else (a run view that was opened first)
  navigate to the run's conversation. With a draft it is still the word move. The `:back` binding's
  help line and `docs/keybindings.md` say so (regenerated). `bindings_test.exs` gets an explicit
  exception for that one key (the table declares the word move; the resolver answers back with an
  empty draft).

### U8 stale queued rows
- `Turns.pending_rows/3`: the snapshot's `queued_texts` count only for the conversation that owns
  the snapshot (`snapshot.conversation_id`), so another conversation's queue cannot draw rows in
  a run view; the fallback (`:queued` deliveries) skips any whose text is already a sent user
  message. The real cause in the QA shot was a run view of an older conversation drawing the
  workspace snapshot's queue and the never-pruned `:queued` deliveries.
- Not done: a `:queued` delivery for a message that was dropped (`/queue drop`) and never sent
  stays in `State.deliveries` and can draw in the fallback case (no snapshot queue for that
  conversation). Pruning needs the dropped text at the answer, which races the workspace delta;
  left for the integrator or a later pass.

## Files outside the lane's row (smallest change)
- `ui/action.ex`: the `{:queue_take}` action (type and `validate/1` clause). Unavoidable: the
  queue list's Enter needs an action the reducer can dispatch.
- Test files edited besides the new one: the six listed above and `ui/bindings_test.exs`.

## Gates that ran (fix-U worktree)
- `mix format`; `mix compile --warnings-as-errors`.
- Focused: `apps/swarm_code_cli/test/swarm_code_cli/{ui,cli020}` (2773 tests, 10 properties): green
  except two `d4_copy_test.exs` cases that timed out under machine load and pass alone (5 of 5,
  three times). Also `demo`, `plain`, `companion`, `c74_acceptance`, `c74_settings_docs` (see
  the final report).
- `mix swarm_code.keymap --write`, then `--check` clean (binding help text changed).
- No registry change (no `settings --write`), no provenance file touched (no repin).
- Not run: the full precommit and the PTY suites (integrator).

## Handoffs
- The integrator re-runs `mix swarm_code.keymap --check` after merging R/L/S (none of them edit
  bindings).
- S3's daemon text should keep the word `trusted` in the trust case; U1 keys on that word.
