# Pass 73 outcome: the owner's eleven notes

Finisher report on `p73/integrate` (worktree `/Users/zaali/dev/swarm-code-cli-wt/p73-F`). The branch
starts from main `30b27fc` (the pass 73 plan). The four owners' branches were merged in plan order
with `--no-ff`:

- `p73/S` (bd7a51d): daemon and wire. Merged as 83f7f1c.
- `p73/K` (92016df): keys, input, commands, state. Merged as 33c4d1e.
- `p73/V1` (ee5c444): transcript and cards. Merged as 5a918c4.
- `p73/V2` (af00d9f): chrome. Merged as 4cfe99e.

None of the four merges had a conflict, and the merged tree compiled with `--warnings-as-errors`
(the `valid_origin?/2` warning V1 and V2 saw came from merging K's tag before K's later commits).
After the merges come the finisher commits F1 to F10, listed at the end.

The sandbox setup:

- `HOME=/Users/zaali/.cache/p70cli/p73-F/home`, a copy of the 57-migration sandbox database.
- A scratch copy of `ailogic` at `/Users/zaali/.cache/p70cli/p73-F/ailogic`.
- `deepseek-v4-pro`, `/trust` on the scratch copy (read-only → auto).
- The release built from this branch, copied to `/Users/zaali/.cache/p70cli/rel-p73/`. The final
  copy includes F9. F10 changes only one help sentence, so it is not in that copy. After QA #1 the
  polisher rebuilt it at G14 (b109fc4); see "QA #1 and the polish". After QA #2 the second
  polisher rebuilt it at G28 (aac8306); see "QA #2 and the second polish".
- GNU screen with `-L` raw logs, rendered to PNG by the spec's `tools/vt.py` and `svg2png.py`. The
  finisher's scratch copy of `vt.py` (`/Users/zaali/.cache/p70cli/p73-F/tools/vt.py`) adds ECH
  (`CSI n X`), which the port uses to blank cells. Without ECH the replay leaves stale text that the
  terminal never shows. The replay draws no background fills, so light-theme text reads dark on
  black in the PNGs.
- Screenshots are under `/Users/zaali/.cache/p70cli/p73-F/shots/` (`NAME.png`, `NAME.txt`,
  `NAME.raw`). Below, a screenshot is named without its directory, as `c0.png`.
- Real prompts: 8 in total, all in session 1 (20:49–21:26):
  1. the `/swarm` of four reviewers, each told to run a multi-line `cd lib && python3 -c "…"`;
  2. "write a workflow that runs mix format --check-formatted and then mix test …", which the
     keyword sent as `/create-workflow`;
  3. `/plan add input validation to the ticket API controllers`;
  4. a steer during the plan ("keep the plan under eight steps …");
  5. `/compact`, which was queued;
  6. the `curl … | head -3` turn;
  7. the README append and `git diff`;
  8. "count from 1 to 60", stopped with Esc.

  The workflow `/format-and-test` ran when the author's `workflow run` was approved.

  Sessions 2 to 4 only restarted the release and used no prompts.

## What the owner will notice

- While a swarm, a `/create-workflow` turn and a `/plan` ran side by side with four approvals
  waiting, nothing was refused. `/compact` said "queued · sends after the running turn" and drained
  afterwards. A plain message went to the running turn, marked "→ to the running turn". The
  session stayed up for 37 minutes and closed only when told to. No frame and no toast says
  "daemon" or "refused" (`grep -il daemon shots/*.txt` finds nothing).
- The approval card is framed above the composer, with one blank row between them. It shows at
  most six command lines and even key chips. Only the letters of the decisions it offers answer
  it. Enter with a draft sends the draft. With the draft empty, Enter shows the whole command, and
  Enter again folds it back.
- `/diff`, `/theme` and `/mouse` act at once, say so on the status row and are kept in
  `cli.json` (mode 0600).
- The trackpad scrolls the chat from its bottom row: the first notch moves three rows (F9).

## The notes

### T1 `/diff`

- **What changed.** K added the `show_diffs` preference (`/diff`, `/diff on|off`, cli.json). V1
  made every tool row a single line when it is off, without in-place hunks, file previews or
  "… N more lines" tails.
- **Evidence.**
  - `u3.png`: the "Diffs hidden · /diff shows them" toast; the edit and `git diff` rows are one
    line each.
  - `y0.png`: after a restart the rows are still one line.
  - Session 4: `da.png` is the restart with `show_diffs:false`. `db.png` is `/diff on`: "Diffs
    shown · /diff hides them", and the `@@ -19,3 +19,4 @@` hunk is back under the edit and both
    `git diff` rows.
  - Tests: `pass73_transcript_test.exs`, `pass73_preferences_test.exs`, `pass73_keys_test.exs`.
- **Open.** The core catalogue (`swarm_code_core/lib/swarm_code/commands.ex`) still describes
  `/diff` as "The files this conversation changed". K asked for new wording, and the finisher
  left it out: `/diff` is a client command, and the palette already shows the client's words for
  `diff`, `theme`, `mouse` and `approval`, whatever the catalogue says. Changing the shared
  catalogue would also change the desktop's list.

### T2 `/theme`

- **What changed.** V2 added `Theme.mode/3` (`SWARM_THEME` > cli.json > desktop settings > dark)
  and `Theme.switch_words/2`. The port owner repaints on `{:terminal_preferences, …}`. K made
  `state.theme_mode` start as the painted theme (V2's request K-3), through
  `PersistedSession.start_preferences/3`. F6 gives the dev live launcher the same start.
- **Evidence.**
  - `u0.png`: "Dark theme · /theme switches back", with the screen repainted.
  - `lc.png`: `SWARM_THEME=light` starts light although cli.json says dark.
  - `le.png`: `/theme` then repaints dark live and says "Dark theme · SWARM_THEME=light still
    wins at the next launch".
  - `wl.png`: a restart without the variable is dark, from cli.json.
  - `cli.json` is `-rw-------` `{"mouse":true,"show_diffs":true,"theme":"dark"}`.
  - Tests: `pass73_mouse_test.exs` ("the launcher: SWARM_THEME > cli.json > desktop > dark"),
    `pass73_preferences_test.exs`, `pass73_theme_test.exs`.

### T3 / T8 Nothing is refused while work runs

- **What changed.**
  - S: `PersistedBackend.dispatch_send`. Run-launching commands start beside the live runs. A
    plain message during the chat turn is a steer (`Engine.steer/4`). `/compact` during a turn,
    and a message during a compaction, go on the conversation queue. `Outcome.disposition` and
    `Outcome.reason` carry the result, the transcript has `target_kind: :steer`, and the workspace
    has `queued_texts`.
  - K: `Composer.enter_action/1` answers steer, queue or run, and `Reducer.Deliveries` reads the
    disposition.
  - V1: the "→ to the running turn" and "queued · sends after the running turn" marks.
  - V2: `Status.refusal_words/2`.
  - Finisher: F3 remembers only a send that started a run as the turn Ctrl-C stops (S's request
    K4). F5 shows a refusal in the daemon's words and keeps the reason
    (`State.mutation_reasons`, V2's request K-1), and never says "the daemon". F7 hints `/com`
    Enter behind a live chat turn as "queue", the way the daemon treats it.
- **Evidence.**
  - `b1.png`: `/swarm` started ("Esc stop the swarm").
  - `c1.png`: `/create-workflow` started beside it ("2 runs · 6 agents · 6 live").
  - `d1.png`: `/plan` started as a third run while four approvals waited.
  - `f1.png`: `/compact` queued (the status reads "Queued · sends after the running turn", the
    transcript mark and "1 queued" on the edge row).
  - `g0.png` / `g1.png`: a plain message was hinted "Enter steer", confirmed "Sent to the running
    turn.", and marked "→ to the running turn".
  - Tests: `pass73_delivery_test.exs`, `pass73_finisher_test.exs` ("refusals in words", "where a
    send went"), `pass73_refusal_words_test.exs`, and S's `pass73_send_routing_test.exs`.

### T4 Enter completes

- **What changed.** K: Enter on the open `/` list takes the highlighted command. It runs a command
  that takes no argument and leaves `/<name> ` for one that needs an argument.
- **Evidence.**
  - `a1.png`: `/tru`, then "Enter run" runs `/trust`.
  - `a2.png`: the toast "Project trusted · Approvals: read-only → auto · edits go ahead, commands
    ask first".
  - `f0.png`: `/compact` in the list shows "Enter run".
  - `z0.png`: `/consens` shows "Enter complete".
  - `z1.png`: the composer then holds `/consensus `.
  - F7 found and fixed a false hint: `/com` behind a live chat turn said "run" while the transcript
    said queued.
  - Tests: `pass73_composer_test.exs`, `composer_first_test.exs`.

### T5 The word "workflow"

- **What changed.** K's `WorkflowKeyword` routes a message containing the word `workflow` to
  `/create-workflow`, and Ctrl-S sends it as a plain message. V2 added the hint row and bold
  `run_workflow` runs in the composer. V1 highlights the word in the sent message.
- **Evidence.**
  - `c0.png`: the row above the composer reads "workflow · sends as /create-workflow · Ctrl-S
    plain message", the status row "Enter run", and "workflow" is bold in the draft.
  - `c1.png`: the send ran as `/create-workflow …`.
  - K's live check sent a plain message with Ctrl-S. The finisher did not repeat that check.
  - Tests: `pass73_workflow_keyword_test.exs`, `pass73_composer_keyword_test.exs`.
- **Open.** The plain presenter (`-p` / `--plain`) sends the text as typed. The keyword applies
  only to the full-screen composer.

### T6 Footer hints are true

- **What changed.** V2's `Status.composer_hints/1` follows K's `enter_action/esc_action`. F2 adds
  "Enter show all" on a card that cuts its command. F7 adds "queue" for `/com` during a turn.
- **Evidence.**
  - Empty and idle: `a0.png` ("Ctrl-P palette"), `t1.png`.
  - A draft while idle: `b0.png`, `v0.png` ("Enter send").
  - Empty with a live turn: `w0.png` ("Esc stop Assistant").
  - A draft with a live turn: `g0.png` ("Esc stop Planner · Enter steer").
  - The palette open: `f0.png`, `t2.png` ("Enter run"), `z0.png` ("Enter complete").
  - An approval pending: `j0.png` / `k0.png` ("Esc later · ? keys"), `h1.png` ("Enter act"), and
    `m1.png` at 120x36 ("Enter send · Esc later" with a draft under the card).
  - `i2.png`: "Esc stop Workflow author" names the role.
  - Tests: `pass73_hints_test.exs`, and `pass73_finisher_test.exs` ("the status row says what
    Enter does on the card").

### T7 The approval card

- **What changed.**
  - V1: `ApprovalCard.layout/2` draws a framed card in main, with a header (glyph, agent, verb),
    the reason quoted or in the rule's words, the command in a code block of at most six lines,
    even chips, a footer ("in the project · auto asks", "1 of 4 waiting · n next") and one blank
    row. The edge row is left to the composer.
  - K: `/approval` with no argument opens a picker of the three modes on the current one (K10).
  - V2: `Status.policy_words/3`.
  - Finisher:
    - F1: `Composer.edge/2` gives the edge row back to the hive strip or hairline (V1's request
      to V2), and `card_blocks/3` is removed.
    - F2: the card's own keys are exactly the decisions it offers (`Keymap.card_answers/2`, V1's
      "a letter typed on an open card is eaten"). Enter under the card with a draft sends the
      draft (`typing_under_card?/1`, `sending_under_card?/3`). With the draft empty, Enter on a
      card that cuts its command toggles `selection["approval_all"]`
      (`{:approval_show_all, id}`, `Keymap.show_all?/2`, V1's request). F10 says so in the key
      reference.
    - F5: the policy toast says what the new mode means (V2's request K-5).
    - F7: the picker is titled "Approvals · who asks before what runs", not "Actions:
      approvals:".
- **Evidence.**
  - `j0.png` (160x45): "! Workflow author wants to run workflow run" framed, with the reason on
    its own line and "y once  Y this run  d deny  D deny & stop".
  - `m0.png` / `m1.png` / `m2.png` (120x36): "! controllers wants to run a command" with the quoted
    reason and the five-line `cd lib && python3 -c "…" | head -20` in the code block, then the
    blank row, then the composer.
  - `r0.png`: the picker with "✓ Auto" marked.
  - `r1.png` / `r2.png` / `r3.png`: "Approvals: auto → read-only" and back, both in the transcript
    and as the toast, and the card footer changed to "read-only asks".
  - `a2.png`: the toast with the meaning.
  - Tests: `pass73_card_test.exs`; `pass73_finisher_test.exs` ("Enter on the approval card");
    `pass73_keys_test.exs`; `composer_first_test.exs` (letters that are not decisions type into
    the draft).
- **Not seen live.** "Enter show all". None of the live cards cut its command at the sizes used,
  and at 120x24 no card came up. `pass73_finisher_test.exs` covers it on the screenshot-11 scene
  at 120x24, through `Keymap.resolve/3` and `Reducer.update/2`.

### T9 Trackpad scrolling

- **What changed.**
  - K: wheel reports are on by default, `/mouse on|off` is kept in cli.json, and `SWARM_MOUSE`
    wins over it. K8 starts a move from the following view's top row, and K9 stopped `/mouse` and
    `/theme` from closing the session.
  - V2: the port's tag-8 wheel command (`Wire.mouse/3`).
  - V1: `state.panel_scroll`, with the needs-you band pinned.
  - Finisher:
    - F6: the help sheet ends with the mouse note while reports are on (K's request F2).
    - F9, found in this live check: a tool-using turn leaves thinking items that draw nothing,
      and `Scroll` counted each as one row. Over a turn that ended in three of them, the first
      notch from the bottom moved nothing, and every later notch lost a row per such item. Now
      such an item counts 0 rows, and the follow view's top is found from the last item that
      draws a row. Found with a dump of the live `SessionRuntime` state; the new
      `Pass73MouseTest` case fails without the fix.
- **Evidence.**
  - Before F9, `wg.png` / `wh.png`: after one and then four more notches the view had not moved.
  - `wi.png` / `wj.png`: PgUp, then one notch moved three rows.
  - After F9, on the rebuilt release: `lm.png` is the bottom, `wl.png` is one notch up (three
    rows), and `wm.png` is one notch down (back to the bottom).
  - `hc.png`: the help sheet's mouse note.
  - Session 4 (`dc` / `dd`): `/mouse off` shows "Wheel scrolling off · the terminal selects text
    again", the port writes `?1000l ?1002l ?1003l ?1006l`, and cli.json has `"mouse":false`.
    `/mouse on` shows "Wheel scrolling on · Shift- or Option-drag selects text", writes
    `?1000h ?1006h`, and cli.json has `"mouse":true`.
  - cli.log: "terminal wheel reports off/on".
  - Tests: `pass73_mouse_test.exs`, `pass73_panel_scroll_test.exs`,
    `pass73_preferences_runtime_test.exs`.
- **Open.** The panel wheel was not seen live: the panel never overflowed in this sandbox. The
  test covers it.

### T10 The broken layout (screenshot 11)

- **What changed.**
  - V1: `Panel.Name` gives an agent one name in the card, band, tree, hint and chat. The band
    flattens a command to one row with "…". The in-chat run is named by its role label ("Workflow
    author", "Planner").
  - F1: the edge row belongs to the composer.
- **Evidence.**
  - `m2.png`: "! 5 NEED YOU · oldest first". Each band row is one line, and the card and the band
    name "controllers" and "live" the same way.
  - `i2.png`: the panel's "Workflow author" and the status row's "Esc stop Workflow author".
  - `e1.png` / `h3.png`: "Esc stop Planner".
  - Tests: `pass73_names_test.exs`, `pass73_card_test.exs`.
- **Open.** A GFM table row with more cells than its header (a `|` inside a code span) still draws
  the extra cell as a column (V1's leftover in `projector/markdown.ex`; not in this pass's tasks).

### T11 The session died

- **What changed.** S found and fixed the cause, and `pass73_session_flow_test.exs` reproduces it
  through the real client, socket and backend. After a watch overflowed, the client acknowledged
  deltas of the dropped watch, and the daemon closed the connection without a log line. S also
  fixed eight more ways a busy session closed or refused (see `pass73-notes/S.md`), and every
  close is now logged with a redacted reason on both sides.
  - F4 (S's request K5): a run already asked to stop is no longer "the turn", so the next Ctrl-C
    stops another run or arms the quit. The stale live run S saw was not reproduced; the fix makes
    the ladder independent of it.
- **Evidence.**
  - Session 1 ran 37 minutes with three live runs, four to six approvals waiting and the
    `/format-and-test` workflow. It did not close until it was quit.
  - The Ctrl-C ladder live: `w1.png` "Stopping the turn.", `w2.png`, then "Press Ctrl-C again to
    quit." (`wk.png`).
  - Every quit logged `SwarmCode daemon: the client closed its connection (0 watches, 0 requests
    in flight)` or `(while an ack was answered)`, and `data source lost: the data source announced
    it closed`, in `home/Library/Logs/SwarmCode/cli.log`.
  - Tests: `pass73_connection_test.exs`, `pass73_session_flow_test.exs`, and
    `pass73_finisher_test.exs` ("Ctrl-C after a stop").
- **Open.**
  - A forced daemon-side close could not be caused from outside: the release has no
    distribution, and nothing overflowed in 37 minutes. S's `capture_log` tests assert each close
    reason.
  - Every normal quit also logs `data source lost` as a warning.

## Also fixed in the live check

- F8: an answer longer than 2 KB was split at its step's 2 KB preview. `Turns.decompose/2` took
  the preview off the answer as the step's words, so each half parsed its backticks on its own.
  `r0.png` shows the `/compact` summary as "5. `li", a blank row, then "b/ailogic_web/…—
  optionally add:bad_requesthandling so{:error,". After the fix it reads whole (`y1.png` /
  `y2.png`). Test: `projector/workspace_turns_test.exs`.

## Acceptance

| # | Item | Result | Evidence |
| --- | --- | --- | --- |
| 1 | precommit, port check, keymap check, PTY suites | pass | After QA #2: `mix precommit` exit 0 at aac8306 without `_build/prod`: core 148/0, daemon 1013/0, CLI 1815/0 (7 properties); port check and keymap check pass (see "QA #2 and the second polish"). After QA #1: `mix precommit` exit 0 at 9c29311 without `_build/prod`: core 148/0, daemon 1011/0, CLI 1801/0 (7 properties); port check and keymap check pass (see "QA #1 and the polish"). Before: `mix precommit` exit 0 at 7309405 without `_build/prod`: core 148/0, daemon 1011/0, CLI 1783/0 (7 properties). `check_terminal_port.sh` exit 0 (cargo fmt, 45 Rust tests, 58 crates / 108 licence texts). `mix swarm_code.keymap --check` matches. PTY suites: port 16, demo 8, live 1, saved 1, all OK after F9 |
| 2 | `/swarm` + `/create-workflow` + an approval, then `/plan`, `/compact`, a plain message; 10 minutes with 3 live runs; close reasons in cli.log | pass (the forced close could not be caused) | `b1`, `c1`, `d1`, `f1`, `g0`, `g1`; 37 minutes with three live runs; quit-time lines in cli.log; S's close-reason tests |
| 3 | `/diff` off/on, kept across a restart; `/theme` live and kept; `SWARM_THEME` precedence | pass | `u3`, `y0`, `da`, `db`; `u0`, `lc`, `le`, `wl`; cli.json 0600 |
| 4 | `/com` + Enter runs `/compact`; `/consens` + Enter leaves `/consensus ` | pass (under an auto-opened approval card only since G11, QA Q1-01; under a card focused with Ctrl-N or `n` since G21, QA Q2-01, polish shot `e6`) | `f0`, `f1` (queued behind the turn, hinted "queue" since F7), `z0`, `z1`; `a1` (`/tru`); polish shots `a1`, `f1`, `f2` |
| 5 | "workflow" highlighted, sent as `/create-workflow`, opt-out key | pass (Ctrl-S under an approval card and its hint row only since G11, QA Q1-02) | `c0`, `c1`; K's live check; polish shots `k1`, `k3` |
| 6 | Footer hints in the six states | pass | `a0`, `b0`, `w0`, `g0`, `f0`, `j0`, `h1`, `m1` |
| 7 | Card at 160x45 and 120x36, ≤ 6 lines, chips, blank row, `/approval` picker, policy notice | pass ("Enter shows all" seen live by QA #1 and the polisher, "Enter fold" since G13) | `j0`, `m0`, `m1`, `m2`, `r0`–`r3`, `a2` |
| 8 | Wheel in the transcript, the panel and the overlay; `/mouse off` | partial before F9, pass after it for the transcript and overlay; notches past the bottom are not stored since G12 (QA Q1-03); the panel wheel was not seen live | `wg`/`wh` → F9 → `lm`, `wl`, `wm`; `hc`; `dc`/`dd` with the port's `?1000l…`/`?1000h` |
| 9 | Screenshot-11 scenario renders cleanly | pass | `m0`–`m2` (card, band, names), `i2` (Workflow author); `pass73_finisher_test.exs` on `Pass73Scenes.screenshot_11/2` |

## Finisher commits

| Commit | What |
| --- | --- |
| 3e53eb4 | F1: the approval card leaves the edge row to the composer (V1's request to V2); `Composer.card_blocks/3` removed |
| 05b02ca | F2: the card's keys are the decisions it offers; Enter under it sends the draft, and on a blank draft shows the whole command (V1's requests to K) |
| cb41e25 | F3: only a send that started a run is remembered as the turn a Ctrl-C stops (S's request K4) |
| 99ef425 | F4: a run already asked to stop is no longer the turn, so the next Ctrl-C stops another or arms the quit (S's request K5) |
| aa9b66d | F5: every refusal says why in the daemon's words, never "the daemon"; the policy toast says what the new mode means (V2's K-1, K-5; S's K1) |
| 72eae1b | F6: the help sheet ends with the mouse note; the dev live launcher starts theme, wheel and diffs like the release (K's F2, F4) |
| 7c51364 | F7: `/com` Enter behind a live chat turn is hinted "queue"; the `/approval` picker is titled "Approvals" (live check) |
| 503f1a9 | F8: an answer longer than 2 KB is drawn whole, not split at its step's preview (live check) |
| 7db0c80 | F9: an item that draws nothing takes no row in the scroll, so the first wheel notch from the bottom moves three rows (live check) |
| 7309405 | F10: AGENTS.md, README and the key reference say what pass 73 changed |

## QA #1 and the polish (G11 to G15)

QA #1 (`/Users/zaali/.cache/p70cli/p73-Q1/qa.md`) ran the F9 release for 28.5 minutes with three
live runs and found one P0, two P1s and nine P2s. The polisher fixed all three P0/P1 findings and
the cheap P2s, each with a regression test in `pass73_qa1_test.exs` (keys through `Keymap.resolve/3`
and `Reducer.update/2`, drawn rows painted like the golden scenes). Without the fixes, 17 of its 18
tests fail. One P2 contradicts the plan and was left as the plan says.

| ID | Sev | Finding | Result |
| --- | --- | --- | --- |
| Q1-01 | P0 | `/com` + Enter under an auto-opened approval card was refused ("There is no /com") while the hint said "Enter run" | fixed in 7881b05 (G11): `SlashPalette.context/1` accepts the draft under that card, so the list is drawn under the card's blank row, and Enter completes, runs or queues. The list row says "Enter queue" as the status row does (it said "Tab complete" behind a live turn, even without a card) |
| Q1-02 | P1 | under that card only printable keys, Backspace and Enter reached the draft; Ctrl-S did nothing; Ctrl-C closed the card; no workflow hint row | fixed in 7881b05 (G11): with a draft under the card, the composer's editing and sending keys resolve against the composer (arrows, Home/End, Ctrl-A/E/U/W, undo, new line, Tab, Ctrl-S, Alt-Enter). Esc, PgUp/PgDn and the global chords stay the card's. Ctrl-C clears the draft before it puts the card aside. The workflow hint takes the edge row, and the status row drops "n next" and "? keys" while those letters type |
| Q1-03 | P1 | wheel-down past the bottom was stored, so the next wheel-ups did nothing, and wheeling back never followed again | fixed in 105b782 (G12): `Pages.refollow/7` follows again after a line move down that ends on the last screen, once the chat is longer than a page or the view was following. A chat that fits one page keeps the exact anchor of a detached line move (`ThreeRunScenarioTest`) |
| Q1-04 | P2 | the card's "1 of N waiting" left out the ones set aside, unlike the band and the status row | fixed in 5ca7518 (G13): the footer counts `Status.waiting_count/1`, which is what `n` walks |
| Q1-05 | P2 | "Enter show all" stayed on the status row once the card showed all | fixed in 5ca7518 (G13): `enter_action/1` answers `:fold`, worded "Enter fold". `pass73_finisher_test.exs` now expects `:fold` on the expanded card |
| Q1-06 | P2 | a message sent plainly with Ctrl-S still shows "workflow" highlighted | not changed, following the plan. T5 says the word is highlighted "in the sent user message", and V1's `pass73_transcript_test.exs` asserts it for a plain message. A routed message is already told apart by its `/create-workflow` prefix, which is highlighted too |
| Q1-07 | P2 | the workflow-run card read "wants to run workflow run" with raw `name:`/`continue:` lines | fixed in 5ca7518 (G13): "wants to run the workflow /format-check" (or "a one-off workflow"). The body shows only the args, source and budget, and a call with nothing to show keeps one gap |
| Q1-08 | P2 | Ctrl-B at a narrow width (strip → off → strip) wrote `"panel":"full"` over `/panel compact` | fixed in b109fc4 (G14): `State.panel_shown` remembers the last shape that was not hidden |
| Q1-09 | P2 | a stale "Not sent: …" hid the true hints for minutes | fixed in b109fc4 (G14): a settled draft refusal leaves the status row once that draft is edited, or once another request the user started is on its way (an answer, a send, a stop). Background queries do not count |
| Q1-10 | P2 | a resumed transcript starts mid-conversation, and a run's late stop note lands inside a later block (pre-existing) | deferred. `PersistedBackend.snapshot` sends the last `limit` items with no `before_cursor`. The fix needs a transcript cursor on the wire and daemon paging. This is not a pass 73 note |
| Q1-11 | P2 | small visual issues | partly. The lower-case "workflow" (and "consensus", "research") speaker is capitalised in b109fc4 (G14), and `RepresentativeScenesTest` follows. Deferred: mid-word soft wrap in the composer (the editor's grapheme wrap drives the caret's visual lines); hint digits skipping folded runs, and the panel's in-chat mark after a digit jump (the pass 72 hint and panel models); the `/plan` echo and the mode label, which come from the daemon's stored text and workspace mode |
| Q1-12 | P2 | unused `Context` alias in `status_hints_test.exs` | fixed in b109fc4 (G14) |

G15 (9c29311) updates AGENTS.md: the keys a draft under the card takes, and Enter folds.

Final checks at 9c29311, without `_build/prod`:

- `mise exec -- mix precommit` exit 0: core 148/0, daemon 1011/0, CLI 1801/0 (7 properties).
  The only warnings are the daemon tests' known migration-module redefinitions; the unused
  alias is gone.
- `scripts/dev/check_terminal_port.sh` exit 0: cargo fmt, 58 Rust tests, 58 crates and 108
  licence texts.
- `mix swarm_code.keymap --check`: `docs/keybindings.md` matches the binding table.
- Running `mix test` inside `apps/swarm_code_cli` alone fails the Companion and data-source
  files (`:public_key` and the daemon's test support are not loaded). From the umbrella root
  they pass (32/0).

### The live check after the polish

- Release rebuilt at b109fc4 and copied to `/Users/zaali/.cache/p70cli/rel-p73/` (the only
  change after it is AGENTS.md). `_build/prod` removed.
- Sandbox: `HOME=/Users/zaali/.cache/p70cli/p73-F/polish1/home` (a fresh copy of `sandbox-home`,
  desktop mode light), a scratch `ailogic` copy, `deepseek-v4-pro`, `/trust`, GNU screen `g1` at
  160x45 (90x30 through `stty -f /dev/ttys001`).
- Shots: `/Users/zaali/.cache/p70cli/p73-F/polish1/shots/`, rendered with QA's `vt.py` and
  `svg2png_bg.py`.
- Real prompts, 4 in total:
  1. a `/swarm` of three reviewers, each running a python3 script of 16 or more lines;
  2. a question naming "workflow", sent with Ctrl-S under the card;
  3. `/compact`, reached as `/com` + Enter under the card;
  4. "make a tiny workflow named format-check … then run it once".

What each shot shows:

- `a1.png`: `/com` under the controller card. The list is drawn under the card's blank row, and
  the list row and the status row say "Enter run".
- `f2.png`: behind the Compactor turn, the same draft says "Enter queue" on the list row and the
  status row.
- `f1`: `/com` + Enter ran `/compact` (Compactor thinking) with the card still open. `cli.log`
  has no `unknown_command` for it.
- `b1`: ←← X, then Ctrl-A Y, gave `Y/cXom`. `b2`: Ctrl-E Ctrl-U emptied the draft, and the card
  stayed. `f3`: Ctrl-C cleared `/com`, and the card stayed.
- `k1.png`: "workflow · sends as /create-workflow · Ctrl-S plain message" above the composer,
  under the card. `k3`: Ctrl-S sent the message plainly, the Assistant answered, and the card
  stayed.
- `c1`: Enter on the blank draft showed all 18 lines, and the status row said "Enter fold · Esc
  later". The next Enter folded the card and the row said "Enter show all" again (read from the
  row; that shot was overwritten).
- `n1`–`n3`: `/nosuch` was refused. "Not sent: There is no /nosuch…" was still there after 8 s
  (`n2`). Typing `x` brought back "Enter run · Esc later" (`n3`).
- `e1`: Esc set the controller card aside. The test card opened with "1 of 3 waiting · n next",
  and the status row said "3 waiting".
- `w1` / `w2` at 90x30: Ctrl-B gave "Panel off.", then "Panel strip (compact at 120 columns and
  wider)."; cli.json went `{"panel":"hidden"}` → `{"panel":"compact"}`.
- Wheel: six wheel-downs at the bottom left the view unchanged (`wb_before`/`wb_after`). The
  first wheel-up after them moved three rows (`wt_base` → `wt_1`, via `wheeltest.sh`). Wheeling
  back reached the bottom (`wd2`). After an up and a down notch, the growing workflow block was
  drawn at the bottom (`fy`).
- `c2.png`: "! Workflow author wants to run the workflow /format-check", with no `continue` line.
  `j2`: the run's block is headed "⧉ Workflow".
- Quit through "Stop 2 live runs and quit?" and X. `cli.log` has only the deliberate `/nosuch`
  refusal and the usual quit lines.

## QA #2 and the second polish (G21 to G29)

QA #2 (`/Users/zaali/.cache/p70cli/p73-Q2/qa.md`) ran the G14 release for 28 minutes with two to
four live runs and up to five approvals waiting. It found no P0, two P1s and nine P2s, and
confirmed QA #1's P0/P1 fixes live. The second polisher fixed both P1s and seven P2s, each with a
regression test: `pass73_qa2_test.exs` (keys through `Keymap.resolve/3` and `Reducer.update/2`,
drawn rows painted like the golden scenes), `pass73_qa2_runtime_test.exs` (the session's cli.log
line), and in the daemon `pass73_send_routing_test.exs` (a real backend and a loopback provider)
and `pass73_qa2_panel_facts_test.exs`. Each finding's test fails without its fix; the follow half
of Q2-05 pins behaviour that already held. Two P2s are deferred.

| ID | Sev | Finding | Result |
| --- | --- | --- | --- |
| Q2-01 | P1 | on a card focused with Ctrl-N or `n`, typed letters were decisions: "hey" approved a command, `/consens` walked the cards | fixed in ce16f42 (G21): `Keymap.typing_over_card?/3` and `typing_under_card?/1` apply to every approval card on top, whether it opened by itself or the user focused it. Its own keys (the decisions it offers, `n`, `?`) act only on an empty draft; every other key, and every key once the draft has text, is the composer's, and Enter sends that draft. The old `a` (allow once) is removed from the binding table, because it could only type now; `docs/keybindings.md` is regenerated. `?` is one of the card's keys, because the status row says "? keys" and `?` used to type instead, on both cards. QA's other idea (carry `auto_opened` along `n`) is not needed once the rule covers every card. QA #1's Q1-09 test now answers the card with the action its `y` gives on an empty draft (`y` types over a draft now). AGENTS.md and README say it |
| Q2-02 | P1 | a `/plan` started beside a `/swarm` and a `/create-workflow` planned "all three asks" | fixed in ade7f9d (G22), in the daemon's domain (`Engine.do_start_chat_turn/4`, recorded as the `engine.ex` provenance patch). In the model's history of a new turn, a user message whose run is still registered beside it (the message launched or steered that run) is read as a note: `[An earlier message, handled by a separate swarm run that is still running on its own. It is not part of the current request; do not plan, answer or act on it here: "…"]`. The stored message is unchanged. The desktop has the same behaviour and is not changed (read-only) |
| Q2-03 | P2 | the question dialog cut the question to its title line, broke options inside words and left about ten empty rows | fixed in 60ee09c (G26) and 6f09ed2 (G27): a question that does not fit the title leads the body, wrapped at words, and the title names who asks (`ApprovalCard.who/2`); options wrap at words (`Prose.wrap/3`); the dialog is as tall as its rows. A short question stays the title (`DialogChromeTest`). QA also asked to mark the first option on open; that is not done, because a question opens on Cancel on purpose (Enter must not answer by accident), so the footer says "5 choices · Down picks one · Esc closes" instead of "1 of 5" |
| Q2-04 | P2 | the workflow-run card showed "args: {}" and "auto runs safe commands" | fixed in de3de00 (G23): empty args are left out, and the rule reads "auto asks before a workflow runs" |
| Q2-05 | P2 | a resync the client started ("reconnecting") was not logged, and the chat stopped following after it | fixed in 43a9894 (G24): `Watch.resync/3` keeps its reason on the watch (`:gap`, `:snapshot_required`, `:overflow`, `:unbounded`, `:retry`), and the session logs `SwarmCode: asked the daemon for a fresh workspace snapshot (a delta arrived out of order)`. The lost follow did not reproduce: the snapshot keeps `Scroll.follow?`, and a test pins it. QA could not tell whether the resync or Ctrl-N caused it |
| Q2-06 | P2 | the card always said "1 of N waiting" | fixed in de3de00 (G23): the card counts its place in the walk `n` takes (`Keymap.Special.waiting_ids/1`: tab order, then by id). QA #1's Q1-04 test now expects "2 of 2" on the second card. The card that opens by itself is the oldest request, which is not always first in tab order, so it can read "2 of 2"; `n` then wraps to "1 of 2" |
| Q2-07 | P2 | raw workflow tool names in the band, the run row and the transcript rows | fixed in de3de00 (G23): the band's request reads "/quick-check" (the daemon's `PanelFacts`) with "run a workflow · auto asks", the run row "wants to run a workflow", and the overlay and the older dialog title use the card's words. The tool rows read "list workflows", "check workflow", "save workflow quick-check" and "run workflow quick-check" |
| Q2-08 | P2 | the `/approval` picker filtered on typed text but showed nothing of it ("NO RESULTS") | fixed in 2e1213e (G25): typed text filters the three modes by name ("au" is Auto), and the title shows it ("Approvals: au") |
| Q2-09 | P2 | the panel's cost and the status row's cost differ, with no label | deferred. The two numbers have different scopes: the panel's row 0 (the D1 frame) sums the run in chat and every live run, of any conversation; the status row is this conversation's total, finished runs included. Either label would be wrong in one direction, so this is the owner's call on the D1 row |
| Q2-10 | P2 | rows the running turn added after a steer had no agent header | fixed in 60ee09c (G26) and aac8306 (G28): after a steer that the run's own rows follow, one line "✳ Planner continued" says whose they are. G28 (found by the precommit) keeps it off a message followed by another message. V1's steer-spacing test in `pass73_transcript_test.exs` now expects the line between the mark's blank row and the work |
| Q2-11 | P2 | typing showed slowly under load | deferred. It was not measured, and part of the load came from another workflow on the machine. AGENTS.md asks for a locked before/after fixture, memory and query counts for performance work; this needs its own measured pass |

### The live check after the second polish

- The release was built at 60ee09c (G26) for the live check. It was then rebuilt at aac8306 (G27
  names who asks in a question's title; G28 keeps "continued" to a steer) and copied to
  `/Users/zaali/.cache/p70cli/rel-p73/`. The final copy booted, continued the conversation and
  quit cleanly. `_build/prod` is removed.
- Sandbox: `HOME=/Users/zaali/.cache/p70cli/p73-F/polish2/home` (a fresh copy of `sandbox-home`,
  desktop mode light), a scratch `ailogic` copy, `deepseek-v4-pro`, `/trust`, GNU screen `g2` at
  160x45. Shots are in `/Users/zaali/.cache/p70cli/p73-F/polish2/shots/`, rendered with QA's
  `vt.py` and `svg2png_bg.py`.
- Real prompts, 5 in total: a `/swarm` of two agents whose commands ask; a `/plan` beside it; a
  steer to the Planner under a card; "make a tiny project workflow named quick-check … then run
  it once" (routed to `/create-workflow`); and an `ask_user` question.

What each shot shows:

- `e3.png` (Q2-01): Esc twice, then Ctrl-N focused the deps-agent card ("1 of 2 waiting"). "hey"
  is the draft, 2 are still waiting, and the status row says "Enter steer · Esc later".
- `e6` (Q2-01, Q2-06): `n` walked to the tests-agent card ("2 of 2 waiting"). `/consens` is the
  draft, the `/` list is open under the card, and the row says "Enter complete".
- `w5` / `w6` (Q2-02): the Planner read only the ticket controllers, and its plan is "--verbose
  (query param) request timings for the ticket API", with no part for the swarm's two agents.
- `a2` (Q2-10): under the steer "Also keep the plan under six steps …" with "→ to the running
  turn", the line "✳ Planner continued" heads the Planner's next rows.
- `w1` / `w2.png` (Q2-04, Q2-06, Q2-07): the rows "list workflows", "check workflow", "save workflow
  quick-check" and "run workflow quick-check"; the card "Workflow author wants to run the workflow
  /quick-check" with "auto asks before a workflow runs", no args line and "1 of 2 waiting"; the
  band row "Workflow author /quick-check" and the run row "wants to run a workflow".
- `k2.png` (Q2-08): the picker titled "Approvals: au" with only "✓ Auto".
- `q1.png` / `q2` (Q2-03): the Assistant's 50-word question wrapped whole in the body, four
  options wrapped at words, "Your answer:", then "5 choices · Down picks one · Esc closes". The
  box ends at its rows. Down gives "1 of 5 · Enter chooses".
- cli.log stayed empty for the whole session (no resync, no refusal) until the quit lines.
- Every screen session started for the check is closed, and no release process is left.

Final checks at aac8306 (G28), without `_build/prod`:

- `mise exec -- mix precommit` exit 0: core 148 tests, 0 failures; daemon 1013 tests, 0
  failures; CLI 7 properties, 1815 tests, 0 failures. The only warnings are the daemon tests'
  known migration-module redefinitions. (The first run, at 6f09ed2, failed two CLI tests on G26's
  "continued" line; G28 fixed them.)
- `scripts/dev/check_terminal_port.sh` exit 0: cargo fmt, 58 Rust tests, 58 crates and 108
  licence texts.
- `mix swarm_code.keymap --check`: `docs/keybindings.md` matches the binding table (regenerated in
  G21 without the `a` row).
- G29 changes only this file.

## Requests between owners

| From → to | Request | What happened |
| --- | --- | --- |
| V1 → V2 | `Composer.edge/2` leaves the edge row to the composer | F1 |
| V1 → K | Enter shows all | F2 |
| V1 → K | a letter typed on an open card is eaten | F2 (`card_answers/2`, `typing_under_card?/1`) |
| V1, V2 → K | `valid_origin?/2` clauses not grouped | already fixed on K's final branch; the merged tree compiles with `--warnings-as-errors` |
| V2 → K | K-1 `mutation_reasons` | F5 (stores `outcome.reason.text` when S sends one, else the admission code) |
| V2 → K | K-3 `theme_mode` starts as painted | done by K (`start_preferences/3`); F6 does the same in the dev launcher |
| V2 → K | K-5 policy toast | F5 |
| S → K | 1 a refusal shows its words | done by K in `Reducer.Deliveries`; F5 makes the toast read the same words |
| S → K | 2 `enter_action` follows the daemon | done by K (`rewind` dropped from `@after_turn`); F7 for the palette's completion |
| S → K | 3 marks from `disposition` | done by K and V1 |
| S → K | 4 `note_sent_turn` only for `nil`/`:started` | F3 |
| S → K | 5 Ctrl-C ladder after a stop | F4 |
| S → V1 | steer mark, `queued_texts` | done by V1 |
| S → V2 | no "daemon refused" | done by V2 (`refusal_words/2`), F5 |
| K → V2 | port owner handles `{:terminal_preferences, …}`, tag-8 mouse | done by V2 |
| K → S | catalogue words for `/diff` | not done, see T1 |
| K → finisher | F1 panel scroll | done by V1 (`pass73_panel_scroll_test.exs`) |
| K → finisher | F2 help mouse note, F3 AGENTS.md, F4 dev launcher | F6, F10, F6 |

## What is open

- The core catalogue's `/diff` description (T1). The palette shows the client's words.
- `-p`/`--plain` does not route the word "workflow" (T5).
- The panel wheel was not seen live, because nothing overflowed. A forced daemon-side close could
  not be caused from outside (T9, T11). Tests cover both.
- "Enter shows all" on a card was not seen live by the finisher (T7). QA #1 and the polisher saw
  it live, and it says "Enter fold" since G13.
- The GFM table extra-cell leftover in `projector/markdown.ex` (V1).
- The stale live run behind S's K5 report was not found. F4 makes Ctrl-C independent of it.
- A normal quit logs `data source lost: the data source announced it closed` as a warning. It is
  noise, not an error.
- The release copy at `/Users/zaali/.cache/p70cli/rel-p73/` is built at G28 (aac8306). G29 changes
  only this file.
- From QA #1:
  - Q1-06: a Ctrl-S message keeps the highlight, as the plan's T5 says.
  - Q1-10: a resumed transcript cannot page in older items (daemon paging, pre-existing).
  - Q1-11: the composer wraps inside words; hint digits skip folded runs; the panel's in-chat mark
    does not follow a digit jump; the `/plan` echo and the mode label come from the daemon.
- Seen in the polish live check (`c2.png`): the panel's NEEDS YOU band still named a workflow-run
  approval "workflow run" / "approve: work…". Fixed in G23 (QA Q2-07).
- From QA #2:
  - Q2-09: the panel's cost (the runs it shows) and the status row's cost (this conversation) have
    different scopes and no label; the D1 row is the owner's call.
  - Q2-11: typing under load is not measured; it needs a measured pass with a locked fixture.
  - Q2-02 changed the daemon's copy of the desktop engine (a provenance patch); the desktop itself
    still gives a new turn the launch messages of runs in flight as asks.
  - The card that opens by itself is the oldest request, and its place in `n`'s walk (tab order)
    can be "2 of 2".
  - A question opens on Cancel, not on its first option (kept on purpose, see Q2-03).
