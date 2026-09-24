# Pass 72 outcome: the side agent panel, the agent overlay and hint keys

Finisher report on `p72/integrate` (worktree `/Users/zaali/dev/swarm-code-cli-wt/p72-F`). The branch
starts from main `c50b289` (the pass 72 plan). The three owners' branches were merged in plan order
with `--no-ff`:

- `p72/S` (1921e6a): the data. Merged as 91f4983.
- `p72/P` (9359672): the panel. Merged as c32919b.
- `p72/O` (99daa9f): the overlay and the keys. Merged as 5549e1a.

None of the three merges had a conflict. After them come the finisher commits F1 to F20.

The sandbox setup:

- `HOME=/Users/zaali/.cache/p70cli/p72-F/home`, a copy of the 57-migration sandbox database.
- A scratch copy of `ailogic` at `/Users/zaali/.cache/p70cli/p72-F/ailogic`.
- `deepseek-v4-pro` in approval mode `auto`, after `/trust` on the scratch copy.
- GNU screen with `-L` raw logs, rendered by the spec's `tools/vt.py` and `svg2png.py`.

Ten real prompts were used, the plan's limit:

- Eight were `/swarm` runs of four read-only reviewers.
- One `/trust`, which calls no model.
- One accidental chat turn ("nel compact"). The typing raced a lagging approval card; the cause
  was the resync storm described under F15 to F18.

Nothing touched the real database, `~/dev/ailogic`, `~/dev/swarm-code` or `scripts/install.sh`.
Every screen session was closed through the TUI's own quit path. The only exception was a leftover
VM from the first, failed 80x24 start; I killed that one by its pid.

## What the owner will notice

- **The panel is direction D.** Three examples from real runs:
  - Four reviewers show as `◐ thinking` with their latest thought, each with a 12-cell pulse lane.
  - The Lead shows `◌ waiting on 4 agents`.
  - The foot says `reported ▰▰▰▰ 4 of 4 · the Lead merged the findings`.

  Finished agents give their finding and `path:line` refs. The panel shows no operations, no tool
  chips and no branch, worktree or id text. The transcript has one line per agent, with the same
  glyph, word and sentence as the panel.
- **A request that waits on you is pinned at the top.** The band reads `! NEEDS YOU · tests`,
  then the literal command, then the reason, then `^N answer`. The strip under 120 columns ends in
  `! 1 needs you ^N`.
- **Ctrl-F then a letter opens an agent.** The needs-you agent gets `s` first, and the letters
  never answer a request.
  - The overlay shows the agent's story lane, brief, findings, grouped activity, files, tokens,
    context and turns.
  - `[` and `]` step through the agents. `o` shows the raw operations. `x` stops the agent after
    asking.
  - Typing steers only this agent. Live, the web reviewer's next thought was "Let me think about
    the router pipelines", and no other reviewer mentioned them.
  - `y` or `A` in the band answers the request. Esc gives back the chat draft.
- **Ctrl-F now also works over the approval card** (F13). Before this, Ctrl-F did nothing while a
  worker's card was open, and that is exactly when you need it most.
- **Ctrl-B cycles full → compact → hidden.** `/panel compact` survives a restart through
  `cli.json` (mode 0600).
- **Sessions no longer die mid-swarm with "the daemon connection closed"** (F15). This was the
  close S, P and O each saw once. The cause was the revision race described below.
- **A busy swarm no longer freezes the screen.** Before F18 a four-agent swarm caused 28 overflow
  resyncs in three minutes, and each one was a 470 KB snapshot. Esc took 10–20 s, and Ctrl-C
  could not quit ("The daemon refused that request") while a resync was in flight. After F18 a
  seven-minute four-agent swarm had no resyncs at all.
- **Findings read as findings** (F19). A report that opened with narration ("I've reviewed the
  web layer.") now gives the panel its first numbered finding. For example: `lib/ailogic/accounts/
  user.ex:51 — Mass-assignment privilege escalation…`.
- **`cli.log` says why a session closed** (F2, F12, F14, F16). The app's own `Logger` lines were
  all dropped before, because the `:default` handler kept only OTP reports. The log now shows:
  - `watch_ready rejected: revision`
  - `watch queue overflow: 128 deltas … %{"node_upsert" => 128}`
  - `the daemon asked for a fresh workspace snapshot (overflow)`
  - `closing the daemon connection: …`

## Finisher commits

| Commit | What |
| --- | --- |
| F1 5cdcbc9 | `reported` counts only `done` agents (P→S 1); a finding skips the engine's branch and patch notes (P→S 2). |
| F2 d0584dc | The daemon data source and the session runtime log why they close (P→S 3). |
| F3 9e9fd2d | Hint badges key on `Hint.labels/1` targets in the panel and the strip. Before this, real hint mode drew no agent badge. |
| F4 6238933 | A pending request wins over the wire's `working` (O→P 3); the panel reads `reported` from the wire. |
| F5 43e50a9 | `Layout.for_state/1` everywhere (P→O 1); the tests follow the 46-column panel (P→O 3). |
| F6 f194188 | The overlay is drawn over the shell (O→P 1); prompts centre over the chat (P→O 6); Ctrl-B has its palette key (O→P 2). |
| F7 b0c8f6a | `x` in the overlay stops its agent through the undrawn `stop_agent` action (P→O 4). |
| F8 c6bc0e7 | Releases and dev sessions read `cli.json` (O→F 1); the help text names Ctrl-F and Ctrl-B (O→F 2). |
| F9 92a53a3 | Regression tests for F3–F7 (each fails without its fix). |
| F10 a65fd97 | The panel and the overlay read the published wire fields, not `Map.get` fallbacks. |
| F11 0c56df3 | The saved-session PTY suite expects the panel to repeat the reply (`» …`), as in the D2 chat frame. |
| F12 cedf8b1 | `cli.log` keeps the app's `Logger` messages (explicit handler filters). |
| F13 e319edc | Ctrl-F over the approval card (dialog context and typing grace); the letter opens the overlay; `y` there answers. |
| F14 6313edd | A rejected daemon event names the failed check in `cli.log`. |
| F15 80f4fbc | A `watch_ready` names its own body's revision. A rewatch mid-run was rejected and closed the session. |
| F16 cca4841 | `cli.log` says when and why the daemon asks for a fresh snapshot. |
| F17 ef114a9 | The backend sends a window of 8 deltas ahead of the credit instead of 1. |
| F18 1be246a | A changed run re-sends only the transcript items that changed. Before, every item went out on every refresh, about 10 a second. |
| F19 28c1cb1 | A narrated report opening gives way to the first numbered finding. |
| F20 6ff30f1 | AGENTS.md and README: the panel facts, the watch flow control, the `cli.log` lines, Ctrl-F over a card. |
| F21 6fe73cf | This report. |
| F22 92a22a9 | ExUnit `tmp_dir` output is no longer tracked. O's preference tests and F12's log test had left files in `apps/swarm_code_cli/tmp`; they are now ignored by `.gitignore`. |

Each bug fix has a regression test:

- `apps/swarm_code_cli/test/swarm_code_cli/ui/pass72_finisher_test.exs` (8 tests)
- `persisted_backend_test.exs`, three new tests:
  - the revision race, under a concurrent writer
  - the delta window
  - only changed items re-sent
- `pass72_panel_facts_test.exs` and `pass72_panel_wire_test.exs` (F1, F19)
- `daemon_test.exs` and `daemon_codec_test.exs` (F2, F14)
- `persisted_session_release_test.exs` (F12)
- `panel_test.exs` (F3)

For each one I checked that it fails on the code before its fix. The exceptions are F2 and F14:
their tests check log lines that did not exist before.

The test `assistant text streams before provider finish` needed a change after F18. Its helper now
also accepts streamed text that arrives as `stream_append` deltas, which is what the client
renders; before, it accepted only a re-sent item body. The test's intent is unchanged: the client
sees the partial text before the run finishes.

## Acceptance

The PNGs are under `/Users/zaali/.cache/p70cli/p72-F/`. The release at
`/Users/zaali/.cache/p70cli/rel-p72/` was first built from 28c1cb1 (F19) for QA, then rebuilt from b8294d9 (G21) after
the QA fixes. See "QA findings after the finisher" for the new PNGs.

| # | Item | Result | Evidence |
| --- | --- | --- | --- |
| 1 | `mix precommit`, `check_terminal_port.sh`, `swarm_code.keymap --check`, PTY suites | pass | See "Verification". |
| 2 | A real swarm matches D2 frames 1–3 in structure; nothing past the pane; no operations; one transcript line per agent, no isolation text | pass | Frame 1: `r2.png`. Frame 2: `r3.png` (band with the literal `mix test test/ailogic_test.exs`, `^N answer`, `1 needs you`, `tests is paused on you`). Frame 3: `f3.png` and `f4.png` (findings with file:line, `reported 4 of 4`, then "the Lead merged the findings"). The transcript shows `├ ◐ engine thinking …` with one line per agent. |
| 3 | Ctrl-F badges; the letter opens the overlay; `[`/`]`; `o`; the steer reaches one agent; Esc restores the chat scroll and draft | pass, with a caveat | Badges: `h1.png` (s = tests, then f g h j) and `w7`. Overlay: `o1.png` (D2 overlay frame 2 shape). `]`: `x2`. `o`: `x3.png`. Steer: `x4`/`x5`; in the DB only web-review's later thought mentions the router pipelines. Esc: `x8.png` (the chat draft "draft kept here" is back). The exact scroll could not be judged live, because that session was in the resync storm fixed by F18 and each resync re-anchors the transcript. O's unit test pins the exact scroll and draft. |
| 4 | An approval shows in the band with the literal command; `y` from the overlay approves; `A` always-allows the family | pass | `A`: `o1.png` then `o2.png`; the band showed `$ mix test test/ailogic_test.exs`, and `A always "mix test"` answered it. `y`: `u3`, then `u4` shows the tests reviewer running `mix hex.info`, reached through Ctrl-F over the card after F13. |
| 5 | Ctrl-B cycles; `/panel compact` persists; mixed load fits in compact at 160x45 and 120x36; the strip under 120 columns | pass | Compact: `b1.png`. Hidden: `b2`. `cli.json` went `{"panel":"compact"}` → `hidden` → `full`, mode 0600. `/panel compact` then a restart came back compact (`c1`). Live compact with 9 runs at 120x36: `m120.png`. Mixed load (swarms, goal, consensus, workflow) in compact: `shots/panel_heavy-160x45-truecolor-compact.png` and `shots/panel_heavy-120x36-truecolor-compact.png`. These use Demo data: a live goal and workflow would have gone past the prompt limit. Strip: `n1.png` (`! 1 needs you ^N`). |
| 6 | NO_COLOR and the ASCII tier render every state with its word | pass | Live `NO_COLOR=1 SWARM_ASCII=1`: `a1.png` (`v` done, `x` stopped, `####` gauge, every state with its word). P's goldens cover every state under NO_COLOR and ASCII across all ten scenes. |

## Verification

- `mise exec -- mix precommit` on 6ff30f1, with `_build/prod` removed: see the last section.
- `scripts/dev/check_terminal_port.sh`: pass.
- `(cd apps/swarm_code_cli && mix swarm_code.keymap --check)`: `docs/keybindings.md` matches, after
  it was regenerated for F7 and F13.
- PTY suites:
  - `test_terminal_port_pty.py`, `test_terminal_demo_pty.py` and `test_live_session_pty.py`: pass.
  - `test_saved_session_pty.py`: pass after F11. It had counted the reply once on the whole screen,
    and the panel repeats it by design.
- Performance, same database copy:
  - The workspace snapshot takes about 80 ms on main and on this branch.
  - The projector takes 40–60 ms per frame on this branch (test env). On main it takes 61–78 ms,
    with the old inspector.
  - The panel's own plan takes 6–9 ms.

## QA findings after the finisher (G1–G21)

QA's report is `/Users/zaali/.cache/p70cli/p72-Q/qa.md`. Every P0 and P1 item and the cheap P2
items were fixed, each with a regression test. Where QA and the plan disagree, I followed the plan
and say so in the table.

| QA | Priority | Outcome | Commit |
| --- | --- | --- | --- |
| Q1 `^F` + digit strands the user in a run view | P0 | Fixed. The digit keeps the chat and scrolls it to the run's first item. A run from another chat opens that chat. Enter with a draft in a run view now says why nothing was sent. | 97685a5 G1 |
| Q2 the Lead sorts after the agents that need you | P1 | Fixed. `[`/`]`, "Nth of M" and the tree follow the run block: Lead first, then children, siblings by start. G21 fixes a gap found in the live check: persisted workers point at the Lead's spawn op, so they drew flat. They now nest by depth. | bf86113 G2, b8294d9 G21 |
| Q3 the shared prefix is never trimmed | P1 | Fixed. The prefix and suffix are trimmed when 3+ siblings share them. The team header reads `4 × reviewer-*`. Short names stay distinct, and the band's name column fits them. I kept the 3-sibling threshold (plan over QA): D2's research frame keeps `reader-docs`/`reader-code` whole. | 7069673, de5d3cd G3 |
| Q4 findings as raw JSON; the path repeated | P1 | Fixed. JSON findings, whole or cut by the 4 KB head, become a numbered list or "No findings." The path moves to the refs as a basename. | c4757bc G4 |
| Q5 LIFE draws idle while thinking/waiting | P1 | Fixed, except one part. Open agents run to the clock, and an in-flight detail request goes stale after 10 s, another generation, or leaving, so it no longer blocks the next. This stale request caused the client fallback. Deferred: an approval wait that has been answered still draws as tools, because persisting the wait needs a domain change. | 324379e G6 |
| Q6 transcript agent lines clipped without … | P1 | Fixed. The sentence is cut with … and the meta is kept. | bb6c637 G5 |
| Q7 latency under 2–3 live runs | P1 | Fixed. The safe-text mark check has an ASCII fast path, and `Width.take_prefix` is linear. Appends to one stream are joined. On the 1500-item scene, chat went from 76–96 ms to 30–37 ms, and the overlay from 139–171 ms to 50–55 ms. | 31b6ee6 G14 |
| Q8 "ran" for commands that did not run | P1 | Fixed. Commands read asked to run, running, blocked, you denied, stopped, failed or ran. Tool names are humanized, and find_files counts as a search. | eeca0c3 G7 |
| Q9 hint letters on undrawn rows | P1 | Fixed. Letters follow the band's drawn rows, in order. | de60efe G8 |
| Q10 transcript order regressions | P1 | Fixed. Late workers are drawn before the stop notice. Streamed steps keep their place. An ask says its question once. | 519be2e G9 |
| Q11 typing at a card answers it | P1 | Fixed. At a card that opened by itself, only y Y A d D n answer, and only while the draft is empty. ^N to another chat opens that chat. | 44e5bc0, eef3579 G10 |
| Q12 overlay steer invisible | P1 | Fixed. The steer is echoed in the overlay (`› you: “…”`), and the chat shows "steered to <name>". A daemon test checks that the steer reaches only its target. Deferred: persisting the target on the message is a domain change. | 9827a17 G11 |
| Q13 "now" is the model's narration | P1 | Fixed. Narration openers become verb phrases, empty narration falls back to the recent tool, and ": 1." lists are handled. | 465444c G12 |
| Q14 the header loses the agent on a long title | P1 | Fixed. The run title is trimmed first, and the run clock moves to the meta row. | a4429c9 G13 |
| Q15 `A always` leaves identical pending requests | P2 | Fixed. The same family already waiting in the run is settled too. | 320617b G15 |
| Q16 `⬢` in the tab strip | P2 | Deferred. 13 tests from earlier passes pin the logo and the tab counts as the shell's design (W5 Change 2). This is outside the panel's scope. | — |
| Q17 the beam survives SIGHUP | P2 | Fixed. Output writes have a timeout, and `System.stop` has a 10 s `System.halt` fallback. Live: the beam exited 4 s after `screen -X quit`. | 92a528c G17 |
| Q18 hint footer spacing | P2 | Fixed. The footer reads `s-l open  1-5 run  ^F again: needs you  Esc`. Deferred: the narrow D10 sheet. | de60efe G8 |
| Q19 band reason cut; workflow_control called "a command" | P2 | Fixed. NeedsYou carries an optional `tool`, so the band reads "wants to use workflow control", and the reason is "· auto asks". The flaky steer test also got headroom. | e974b9f G18, a8010c7 G19 |
| Q20 counts disagree | P2 | Deferred. The counts and token semantics need a shared count source. | — |
| Q21 card docked, not inline | P2 | Deferred. The D9 inline card is a layout change. | — |
| Q22 overlay details | P2 | Deferred. RESULT is still flattened markdown, and the finished agent's composer hint, the LIFE story brackets and Ctrl-U remain. | — |
| Q23 "stopped stopped" | P2 | Fixed. The line reads "before it finished". | 961cd7a G20 |
| Q24 palette overflow and duplicates | P2 | Deferred (palette, not the panel). | — |
| Q25 empty workflow parameters in titles | P2 | Fixed. `Model.title/1` drops empty `key=` in the panel, strip, shapes, tabs and overlay. | a4429c9 G13 |
| Q26 mono-tier glyphs | P2 | Deferred. The tier's glyph set is measured under Width.cells, and changing it needs the width work. | — |
| Q27 the 60 s lane is always ▂ | P2 | Deferred. This is a design question for D2's rhythm. | — |

### Live check after the fixes

The check used the sandbox recipe on ailogic, with 6 real prompts and deepseek-v4-pro:

- a 4-reviewer swarm
- a steer
- two command turns
- a 2-worker approval swarm

The release was rebuilt at b8294d9 and copied to `/Users/zaali/.cache/p70cli/rel-p72/`. Then
`_build/prod` was removed. The PNGs:

- `/Users/zaali/.cache/p70cli/p72-F/polish/final-panel-swarm.png`: D2 frame 1. The team header reads `4 × reviewer-*`, and the rows use the short names.
- `/Users/zaali/.cache/p70cli/p72-F/polish/final-hint.png`: `^F` letters in band order, with the footer `s-j open  1 run  ^F again: needs you  Esc`.
- `/Users/zaali/.cache/p70cli/p72-F/polish/final-overlay-steer.png`: the steer echoed in ACTIVITY.
- `/Users/zaali/.cache/p70cli/p72-F/polish/final-chat-steered.png`: "steered to reviewer-controllers" under the user line.
- `/Users/zaali/.cache/p70cli/p72-F/polish/final-overlay-done.png`: the overlay once the agent finished (RESULT, LIFE to the end).
- `/Users/zaali/.cache/p70cli/p72-F/polish/final-chat-stopped.png`: "before it finished" after a stop.
- `/Users/zaali/.cache/p70cli/p72-F/polish/final-card.png`: the approval card for `mix help compile`.
- `/Users/zaali/.cache/p70cli/p72-F/polish/final-always-settled.png`: one `A` settled both workers' identical requests. Typing "hello day" first went to the draft; nothing was answered.
- `/Users/zaali/.cache/p70cli/p72-F/polish/final-overlay-tree.png`: the rebuilt release; WHERE IT SITS nests `├ checker-a` / `╰ checker-b` under the Lead (G21).
- `/Users/zaali/.cache/p70cli/p72-F/polish/final-chat-commands.png`: the command rows in the chat.

Pressing `^F 1` in the live swarm kept the chat and scrolled it to the run (Q1). Closing the screen
session ended the beam in about 4 s (Q17).

The live check also showed two things that are not fixed:

- An overlay RESULT that is markdown still reads flat (`## Findings ### 1.`), as recorded under Q22.
- Worker results can carry an integration note about a delta patch ("65 files changed") even when the worker edited nothing. This comes from the domain's worktree isolation and is outside the panel's scope.

## Still open

- **The approval wait counts as tools in the life lane once the approval is answered.** While the
  request waits, the lane shows `▒`. After the answer, the op's span (start to finish, including the
  wait) is drawn as `▅`. Seen in `u4`.
- **The Lead's "now" can be an old thought** while it thinks after the merge. For example: "The task
  is clear: spawn 4…". This comes from S's fallback to the previous sentence.
- **Some findings are still generic.** When a report has no numbered list, the first sentence can be
  a list of paths or "I've read 12+ files…". F19 only covers reports that do list their findings.
- **One stopped swarm put "Swarm stopped by user." before its last agent line** in the transcript
  (`w3.png`). This follows from the item order and was not reproduced.
- **A snapshot that falls back to 2 KB items** (the `capacity_exceeded` path) is now followed only by
  changed items (F18). An unchanged item stays truncated on the client until it changes or is
  opened, where before the next tick re-sent it in full.
- **The live backend (the unsaved runtime) still sends one delta per credit.** Only the persisted
  backend got F17 and F18.
- **The strip's D10 hint sheet is not drawn** (P's leftover). Under 120 columns, badges appear
  inline.
- **Leftovers S listed as unrecorded in the domain:**
  - consensus positions, goal criteria and a maximum iteration count
  - workflow retry and deadline
  - research funnel counts
  - a token budget
- **`NeedsYou.kind :gate` is not emitted yet.**
- **Sandbox and scratch files remain** under `/Users/zaali/.cache/p70cli/p72-F/`:
  - the home copy
  - the ailogic copy
  - DB copies
  - scratch perf tests, which are not in the repo

## Precommit

I ran `mise exec -- mix precommit` three times on this branch, with `_build/prod` removed.

- The format check, `compile --warnings-as-errors` and `deps.unlock --check-unused` passed.
- Tests, second run (on F21):
  - core: 147 tests, 0 failures
  - daemon: 982 tests, 0 failures
  - cli: 1630 tests + 7 properties, 1 failure
- `provenance.verify`, `provenance.sync --check`, the schema snapshot and the Unicode checks
  passed.

The one cli failure was `Plain.SessionTest` "reader handles charlist devices…", which waits 2 s for
a reader under full-suite load. O saw the same flake, and this pass does not touch `plain/`. It
passes alone three times out of three.

The first run failed the same test plus `ThreeRunScenarioTest`, which asserts on a scroll snapshot
under load. It also passes alone three times out of three.

A third run on F23 (3abcd0e) passed cleanly: core 147/0, daemon 982/0, cli 1630 + 7 properties/0,
provenance and snapshot checks green, exit 0.

### Final precommit (after G21)

A `mise exec -- mix precommit` run on b8294d9, with `_build/prod` removed, exited 0:

- core: 147 tests, 0 failures
- daemon: 993 tests, 0 failures
- cli: 7 properties, 1649 tests, 0 failures
- unicode-width attestation OK
- 31730 attested pairs verified

Two more checks passed:

- `scripts/dev/check_terminal_port.sh` exited 0: 58 locked crates and 108 license texts.
- `mix swarm_code.keymap --check` exited 0: `docs/keybindings.md` matches the binding table.
