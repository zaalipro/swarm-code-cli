# pass71 owner I notes

Owner I: interaction. Branch `p71/I`, worktree `/Users/zaali/dev/swarm-code-cli-wt/p71-I`, from
main 6e8dad1.

## Landed

| task | what | commit |
| --- | --- | --- |
| I1 (R1) | Ctrl-C ladder: closing a layer, clearing a draft or stopping a turn never arms the quit (and disarms an armed one); two idle presses in 1.5 s quit, asking when runs are live | 24baf42 |
| I2 (R2) | Enter before the workspace watch is ready is one deferred send, replayed when the watch is ready | 24baf42 |
| I3 | Ctrl-C (and Esc) right after Enter stops the turn that Enter started, before it is on screen | 24baf42 |
| I4 | Ctrl-X / `$VISUAL` checked in the pass-71 release; no code change needed (below) | none |
| I5 | Binding help (Ctrl-C, Enter), README key table, `docs/keybindings.md` regenerated | 323371e |

### I1 as built (`ui/reducer.ex`)

- The first `{:interrupt, :ctrl_c}` clause (confirming the quit question already on screen) is
  unchanged: mashing Ctrl-C still confirms "Stop N live runs and quit?".
- Otherwise the ladder works out what the press does: close the top layer; else clear the draft
  (undoable; not when the draft is the send in flight, see I3); else stop the turn in view; else,
  with no live turn, stop the turn Enter just sent (I3). If it did any of these it does not arm, and
  an armed quit is disarmed (`{:cancel_timer, id}`, the quit hint is removed).
- Only an idle press arms (`state.quit_armed`, notice "Press Ctrl-C again to quit."); an idle press
  while armed quits through `exit_requested/2` (asks when `live_run_count/1 > 0` or drafts are dirty).
- A press whose stop is already on its way (the stop request is pending, so `stop_turn` emits
  nothing) is idle: Ctrl-C, Ctrl-C quickly after a stop arms but does not quit; a third quits (asks
  if the run is still live).

### I2 as built

- `Keymap.Special.run(:activate, …, %{focus: "composer"})`: when no Send target is drawn and
  `Keymap.deferrable_send?/1` (conversation destination, workspace watch `:frozen`/`:resyncing`,
  draft not blank and not already pending) → action `:defer_send` (validated in `UI.Action`).
- The reducer keeps `state.deferred_send = {draft_key, text}` (one at most; a second Enter replaces
  it) and says "Sends once the conversation has loaded."
- After every transition `replay_deferred/2`: once the watch is `:ready` and the draft is exactly
  the kept text, `Keymap.draft_send/1` builds the same action Send would (local slash commands,
  model picker openers, live-banner library openers, else `{:invoke, {:dispatch, :send, …}, id}`)
  and it is applied. Dropped with a toast when the draft changed ("Not sent: the draft changed after
  Enter."), the watch failed or closed ("Not sent: the conversation did not load."), or another
  conversation opened ("Not sent: another conversation opened first.").
- `Keymap.activate/3`'s send branches moved into `send_target/2`, shared by `draft_send/1`.

### I3 as built

- State fields (block `# pass71-I fields` in `ui/state.ex`): `deferred_send`, `sent_turn`
  (`{conversation, run_id}` of the newest accepted send whose run the read model does not show
  yet), `stop_on_arrival` (`{conversation, {:request, id} | {:run, run_id}}`).
- Ctrl-C (empty draft or the draft is the pending send, no live turn) and Esc (no live turn): if the
  draft's `{:dispatch, :send, …}` mutation is pending → `{:request, id}`; else if `sent_turn` is set
  → `{:run, run_id}`. The notice says "Stopping the turn."; nothing is sent yet.
- `settle_command` → `note_sent_turn/3`: an accepted send's `identifiers: [run_id | _]` (the
  persisted backend's `dispatch_send` answers `accepted(id, [run_id])`) sets `sent_turn` and turns a
  waiting `{:request, id}` into `{:run, run_id}`.
- `track_sent_turn/2` after every transition: clears `sent_turn` once the run is in the read model;
  sends `{:run_control, :stop, run_id}` once that run is there, live and stoppable; drops the stop
  when the run already ended, the send was refused, or the view is another conversation.

## Contracts

- New action `:defer_send`; public `Keymap.draft_send/1` and `Keymap.deferrable_send?/1`.
- `Keymap.live_turn/2` unchanged. `Reducer.live_run_count/1` unchanged.
- Notices (all `{:command_feedback, text}`, fading): "Sends once the conversation has loaded.",
  "Not sent: the draft changed after Enter.", "Not sent: the conversation did not load.",
  "Not sent: another conversation opened first.", "Stopping the turn.". The quit hint
  "Press Ctrl-C again to quit." still does not fade (`State.fading?/1`).

## Requests for other owners

- **S (S4, exit summary):** R1's "the exit summary lists every run it stopped" is S4's
  (`release/persisted_session.ex` `summary/2` / `print_summary/1`). Seen live on p71/I: the summary
  printed the conversation title, "Last prompt" and the resume hint, but not the run a Ctrl-C had
  stopped just before (that one is stopped by the user, not by the quit; S decides whether to list
  it).
- **S (scripts/dev PTY suites):** `test_saved_session_pty.py`, `test_live_session_pty.py` and
  `test_terminal_demo_pty.py` press Ctrl-C up to 8 times 0.3 s apart until the program exits. That
  still works with R1 (idle presses arm, then quit, then confirm), but their comments ("Ctrl-C closes
  a layer or clears the draft; a second press within 1.5 s quits") now describe the old ladder; the
  new one: a press that closes, clears or stops never arms; two idle presses quit.
- **V:** nothing required. The status line may show `state.deferred_send != nil` (e.g. a dim
  "sends when loaded" beside the composer) if you want more than the toast.
- **Finisher:** AGENTS.md's composer-first paragraph (not mine) still says "Ctrl-C clears the draft,
  else interrupts the turn, and a second Ctrl-C within 1.5 s quits"; R1 changes that.

## Manifest-listed files edited

None.

## Verification

- New tests: `ui/pass71_send_race_test.exs` (11: deferred Enter sent on ready, one kept, changed
  draft dropped, failed watch dropped, `/help` typed ahead, blank/ready not deferred; Ctrl-C while
  the send is pending, after accept before the run appears, Esc, refused send / ended run drop the
  stop, mashing). `ui/composer_first_test.exs` ladder tests rewritten for R1 (a clear or a stop does
  not arm; a quick second press after a stop does not quit; a clear inside the window disarms; a
  layer close does not arm). The old code fails the rewritten ladder tests (the clear armed) and the
  new file does not compile against it (no fields/actions).
- Focused: `ui/` + `plain/` suites: 5 properties, 1356 tests, 0 failures.
- Sandbox release (`scripts/dev/build_release.sh`, copied to `/private/tmp/p70cli/p71-I/rel`,
  sandbox HOME `/private/tmp/p70cli/p71-I/home`, scratch ailogic copy, 2 real prompts), GNU screen
  80x24, raw logs rendered with `vt.py`:
  - Ctrl-X with a scripted `$VISUAL` (appends a line): the editor got the terminal (`/dev/ttys…`),
    the 0600 copy, and the draft came back edited; with `VISUAL=vi`: `o second line`, Esc, `:wq`
    → the draft is "first line / second line"; the private copy was removed.
  - Enter typed 1.5 s after launch: "Sends once the conversation has loaded." appeared, then the
    prompt was sent and answered (`pong`).
  - Enter then Ctrl-C at once on a long prompt: the turn shows "stopped 0.1s"; a second Ctrl-C
    0.4 s later did not quit. Two idle Ctrl-C later quit with exit 0 and the summary.
  - Idle double Ctrl-C quits with exit 0 (sessions a, b, c).
  - All screen sessions closed.
- Full umbrella `mix test` at 323371e (no `_build/prod`): core 146 tests, 0 failures; daemon 932
  tests, 0 failures; cli 5 properties, 1441 tests, 0 failures (exit 0).
  `mix format --check-formatted` and `mix compile --warnings-as-errors`: clean.

## Left

- Nothing of I1–I5. The exit summary's stopped-run list is S4.
