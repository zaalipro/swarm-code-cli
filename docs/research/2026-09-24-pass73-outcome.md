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
  copy includes F9. F10 changes only one help sentence, so it is not in that copy.
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
| 1 | precommit, port check, keymap check, PTY suites | pass | `mix precommit` exit 0 at 7309405 without `_build/prod`: core 148/0, daemon 1011/0, CLI 1783/0 (7 properties). `check_terminal_port.sh` exit 0 (cargo fmt, 45 Rust tests, 58 crates / 108 licence texts). `mix swarm_code.keymap --check` matches. PTY suites: port 16, demo 8, live 1, saved 1, all OK after F9 |
| 2 | `/swarm` + `/create-workflow` + an approval, then `/plan`, `/compact`, a plain message; 10 minutes with 3 live runs; close reasons in cli.log | pass (the forced close could not be caused) | `b1`, `c1`, `d1`, `f1`, `g0`, `g1`; 37 minutes with three live runs; quit-time lines in cli.log; S's close-reason tests |
| 3 | `/diff` off/on, kept across a restart; `/theme` live and kept; `SWARM_THEME` precedence | pass | `u3`, `y0`, `da`, `db`; `u0`, `lc`, `le`, `wl`; cli.json 0600 |
| 4 | `/com` + Enter runs `/compact`; `/consens` + Enter leaves `/consensus ` | pass | `f0`, `f1` (queued behind the turn, hinted "queue" since F7), `z0`, `z1`; `a1` (`/tru`) |
| 5 | "workflow" highlighted, sent as `/create-workflow`, opt-out key | pass (the Ctrl-S opt-out was checked live by K, not by the finisher) | `c0`, `c1`; K's live check |
| 6 | Footer hints in the six states | pass | `a0`, `b0`, `w0`, `g0`, `f0`, `j0`, `h1`, `m1` |
| 7 | Card at 160x45 and 120x36, ≤ 6 lines, chips, blank row, `/approval` picker, policy notice | pass ("Enter shows all" is covered by tests only) | `j0`, `m0`, `m1`, `m2`, `r0`–`r3`, `a2` |
| 8 | Wheel in the transcript, the panel and the overlay; `/mouse off` | partial before F9, pass after it for the transcript and overlay; the panel wheel was not seen live | `wg`/`wh` → F9 → `lm`, `wl`, `wm`; `hc`; `dc`/`dd` with the port's `?1000l…`/`?1000h` |
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
- "Enter shows all" on a card was not seen live (T7). The test drives the screenshot-11 scene.
- The GFM table extra-cell leftover in `projector/markdown.ex` (V1).
- The stale live run behind S's K5 report was not found. F4 makes Ctrl-C independent of it.
- A normal quit logs `data source lost: the data source announced it closed` as a warning. It is
  noise, not an error.
- The release copy at `/Users/zaali/.cache/p70cli/rel-p73/` is built at F9. F10 changes one help
  sentence and is not in it.
