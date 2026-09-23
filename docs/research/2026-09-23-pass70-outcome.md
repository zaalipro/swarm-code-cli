# Pass 70 outcome: a useful CLI, checked by using it

QA and design review on `p70/integrate`, after the finisher (8c0734e). The release was driven for
real in a sandbox (`HOME=/private/tmp/p70cli/qa/home`, a fresh copy of the 53-migration database, the
throwaway `ailogic` project copied to `/private/tmp/p70cli/qa/ailogic`) under GNU screen. Every frame
was rendered to PNG with a small VT emulator (`/private/tmp/p70cli/qa/vt.py`). 14 of the 15 allowed
real prompts were used, all on `deepseek-v4-pro`. Every screen session was closed through the TUI's
own quit path. Nothing touched `~/Library/Application Support/SwarmCode`.

Using it turned up eighteen defects, all fixed on the branch as Q1 to Q18. Q19 fixes the
`--resume` sentence and two stale test warnings. Q21 tightens Q13 after review. Each fix has a
regression test that fails without it.

## What the owner will notice

- **Typing keeps up.** Before, 40 characters typed at normal speed took about 4 s to show, because
  every key re-projected the whole scene (`typelat.sh`: 4.1 s on `rel-base`, 0.2 s after Q4).
- **The view follows what you send.** A prompt sent while scrolled up used to be drawn below the
  bottom edge. PgDn past the end left one line above a blank page. Now sending follows the stream
  again, and PgDn onto the last screen resumes following (Q1).
- **Time moves.** The saved session's clock was frozen at launch. Elapsed time stayed at `0.0s`, and
  "Finished · Swarm finished …" or "Project trusted; approval mode auto" stayed on the status line for
  the rest of the session, hiding the key hints. Now elapsed time ticks every second while a turn is
  live, and toasts and feedback fade after 6 s (Q2).
- **Queueing works.** Tab, Alt-Enter and `/queue` put a prompt behind the running turn, and it starts
  by itself when the turn ends. The daemon used to refuse `queue` (Q3).
- **Pickers are useful.**
  - `/resume` lists conversations only (not every run of the open one), shows when each one last
    moved, and is titled "Conversations" (Q10).
  - A long title gives way to that detail instead of the detail being cut at the border (Q14, Q17).
  - `/model` opens with the model in use as the first row. In the owner's database it was about row
    140 (Q5, Q15).
- **The status row tells you how to stop.** While a turn streams, "Esc interrupt" leads the row, even
  on an 80-column terminal where only one hint fits. Idle, it is gone (Q7, Q16).
- **Smaller things.**
  - A stopped answer says "stopped" once, not twice (Q6).
  - Enter on an edit in select mode opens its diff (Q9).
  - `-p` suggests the approval mode after the one in force when a command is denied (Q8).
  - The agent card no longer repeats itself or says "no tools used yet" on a finished agent (Q11).
  - `SWARM_ASCII=1` reaches the ASCII glyph tier in the release (Q12).
- **Start-up is forgiving.**
  - `/resume⏎` typed while swarmcode is still starting no longer leaves a line break in the draft.
    The shell's cooked mode had turned Enter into Ctrl-J (Q18).
  - A stray or corrupted file where `swarm_code.db` belongs gets its own sentence. It no longer says
    "comes from a SwarmCode version this swarmcode does not know" (Q13).
  - `--resume 7d01acff` says a whole id is needed and where to find one (Q19).

## Before and after

All captures are under `/private/tmp/p70cli/qa/cap/`. Each PNG has a `.txt` twin with the screen as
text. `a*` captures come from `rel-base` (the finisher's tree). `b*` come from `rel-q4` (after Q1 to
Q4), `f*` from `rel-final` (Q1 to Q13), `g*` from `rel-final2` (Q1 to Q16) and `h2`/`k1` from
`rel-final3` (everything).

| Area | Before | After |
|---|---|---|
| PgDn past the end | `a1-p2-done.png` (one line above a blank page) | covered by `pass70_qa_scroll_test.exs`; `b1-queue2.png` follows the queued turn |
| Frozen clock, stuck toast | `a1-80x24.png`, `a1-resume.png` ("Finished · Swarm finished …" long after the swarm) | `f1-live1.png` → `f1-live2.png` (2.2 s → 5.4 s), `k1-done-80x24.png` (hints back) |
| Queue | `a1-queue.png` ("Command rejected: not allowed") | `b1-queue.png`, `b1-queue2.png` (QUEUED starts after the poem) |
| Typing latency | 4.1 s for 40 keys (`typelat.sh` on `rel-base`) | 0.2 s; `b1-typed.png` |
| `/resume` | `a1-resume.png` ("Search: #", seven "Run: …" rows) | `f1-resume.png` (Q10: conversations, "open"), `g1-resume-q14.png` (Q14), `h2-resume.png` (Q17: "… 13 runs · open │") |
| `/model` | `a1-model.png` | `f1-model.png` (Q5: provider first, but the model in use still below the fold); Q15 by `model_picker_test.exs` |
| Live status row at 80x24 | `f1-live1.png` ("Enter send" while thinking) | `k1-live-80x24.png` ("Esc interrupt"), `k1-done-80x24.png` ("Enter send" once idle) |
| Typed-ahead Enter | `h1-typeahead-before.png` ("/resume" then "X" on a second line) | `h2-typeahead-after.png` (draft "/resume", completion open, no line break) |
| Inspector card | `a1-swarm2.png` | `f1-inspector.png` |
| Resizes | `a1-80x24.png`, `a1-120x36.png`, `a1-200x55.png` | `f1-80x24.png`, `f1-first.png` (120x36) |
| NO_COLOR | `a3-nocolor.png` (0 colour SGR in the raw log) | unchanged |

The design was checked against the audit's section 4 sketches and the desktop's `themes.css` tokens.
New chrome uses `UI.Theme` roles only (`text_faint` for details, `accent` for the Esc key) and
measures with `Width.cells`. Glyphs that show as boxes in the PNGs (⬤ in the tab row) are missing
from the emulator's font, not from the terminal.

## Acceptance (plan section 5)

| # | Result | Evidence |
|---|---|---|
| 1 | pass | `mix precommit` green: core 146, daemon 931 and CLI 1429 tests (+ 5 properties), 0 failures; `provenance.sync --check`, schema snapshot and unicode checks pass. `check_terminal_port.sh`: cargo fmt, cargo test and licenses pass. `mix swarm_code.keymap --check` matches `docs/keybindings.md`. PTY suites pass: saved session (1), terminal port (15), live session (1), terminal demo (8), launcher environment (5). |
| 2 | pass | Fresh 53-migration copy migrated to 57, after a verified backup and a manifest with mode 0600. The TUI opened on the desktop's default provider (`deepseek-v4-pro`), with `SWARM_*` loaded from `~/.secrets`. After every session, the `providers` dump is byte-identical to the one taken before, and all 84 pre-existing conversation rows are identical. The only new row is the QA conversation. |
| 3 | partial | "Create notes/x.md with two lines then run ls -la notes" was approved with `y` from the composer, and the run finished. A follow-up edit showed `+1 −1`. `A` and `D` were not exercised live, to stay within the prompt budget. |
| 4 | partial | Ctrl-R (`n1-ctrl-r.png`) and Ctrl-G (`n1-ctrl-g.png`) were opened on the sandbox conversation (14 runs, including a two-worker swarm). A resize to 250x70 with the dashboard open (`n1-250x70-dash.png`, `n1-250x70.png`) did not crash. Conversation 7d01acff itself was not opened: `--resume` takes whole ids only (Q19 now says so), and its project is not the sandbox copy. |
| 5 | pass | Text → tool → text on a card: `f1-live3.png` shows a `✓ list lib` row and then the answer, with one header row per turn. Code block: `a1-p1-up2.png`. Status line: `Build · auto · deepseek-v4-pro · ctx ▬▭▭▭▭▭ 11k/120k · $0.49`. |
| 6 | partial | Esc then `please` types it (`n1-please.png`). The first Ctrl-C interrupts the streaming turn, and the exit summary is printed (`f1-exit.png`). The second Ctrl-C quits without asking, because the first one already stopped the only live run. See the open items. |
| 7 | pass | `-p` answered and exited 0. A bad flag exits 2. A directory that does not exist exits 2. `--resume` with an invalid id exits 2. A refused start-up (a second instance) exits 3 with one sentence. `-p --json` puts a denial on stderr. |
| 8 | pass | A second `swarmcode` in another terminal exits 3 and names the holder in one sentence. |
| 9 | pass | One keystroke at 160x45 wrote 129 bytes (`raw-n1.log`, 23462 → 23591). Whole sessions with streamed replies stayed under 1 MB of terminal output: 151 KB for `raw-b1.log` (the poem at 120x36) and 302 KB for `raw-a1.log` (a swarm and resizes up to 200x55). |
| 10 | partial | `test_launcher_environment.py` ("only provider variables leave the private file") passes. Code review found the `load_provider_env.sh` whitelist and the synced engine's env scrub intact. A model-run `env` was deliberately not done live, because it would send the provider-key environment to the model provider. |
| 11 | pass | Covered by `repo_launcher_test.exs` (B1, a process killed holding a checkout), `listener_test.exs` and `daemon_test.exs` (C4, a consumer that falls behind and a slow request), all green. No live session closed in about 25 minutes of use. |

## Fixes

| Commit | What |
|---|---|
| cb1e023 Q1 | The transcript follows a sent prompt, and PgDn onto the last screen follows again instead of paging onto a blank screen |
| 4850fb8 Q2 | The saved session's clock runs: elapsed time ticks, and toasts and feedback fade after 6 s |
| 7458b9a Q3 | Tab, Alt-Enter and `/queue` queue a prompt behind the running turn (daemon `queue` action, drained when the turn ends) |
| f566cbf Q4 | Plain typing is applied at once and projected once per frame (4.1 s → 0.2 s for 40 keys) |
| 818e047 Q5 | `/model` lists the provider of the model in use first |
| 7f48b83 Q6 | A stopped answer says "stopped" once |
| 26f4a86 Q7 | Esc interrupt is hinted only while a turn streams |
| ec4e953 Q8 | `-p` suggests the approval mode after the one in force when denied |
| cfac356 Q9 | Enter on an edit in select mode opens its diff |
| 41ae350 Q10 | `/resume` lists conversations (not runs), with when each last moved, and is titled "Conversations" |
| eb43f12 Q11 | The agent card stops repeating itself and saying "yet" when done |
| 0266fc6 Q12 | `SWARM_ASCII=1` reaches the ASCII glyph tier in the release |
| 882f826 Q13 | A zero-byte, non-SQLite or corrupted database file gets its own refusal sentence |
| ed8a776 Q14 | A long picker title gives way to its detail |
| 0e14c31 Q15 | The model in use heads the model picker |
| 90a5109 Q16 | Esc interrupt leads the status row while a turn streams, including the one-hint 80-column row |
| 49ca17d Q17 | A picker detail keeps one cell before the border |
| b859f93 Q18 | Enter typed ahead during start-up is Enter, not a Ctrl-J line break (terminal port) |
| a3dcd94 Q19 | `--resume` with a short id says a whole id is needed and where to find one; two stale test warnings removed |
| 8524a71 Q21 | Q13's header check lets a path it cannot read go on to the probe, so an unreadable database is not called a stray file |

## Still open, and why

- **Enter typed ahead before the workspace loads is dropped, not replayed.** After Q18 it no longer
  leaves a line break, and the draft and the completion list are there. But the send target does not
  exist until the workspace watch is ready, so the person presses Enter again. Replaying a deferred
  Enter needs its own state in `SessionRuntime` and a test against the watch lifecycle. That was too
  large for the last hours of a QA pass.
- **A second Ctrl-C after the first one stopped the turn quits without asking, and the exit summary
  does not list the stopped run.** This follows the documented rule ("asks while a run is live"),
  but a person who pressed Ctrl-C twice quickly to stop a turn loses the session. Changing it
  redesigns documented behaviour, so it goes to the owner.
- **No "N queued" indicator in the composer.** Q3 says "Queued; it starts when this turn ends." as
  fading feedback, but after 6 s nothing shows that a prompt is waiting.
- **Carried from the finisher, unchanged:**
  - C9, incremental projection. Q4 removes the per-key cost, but a frame still projects the whole
    scene.
  - D7, a light mode.
  - umask 077 for everything the release writes.
  - Ctrl-C right after Enter.
  - `/diff` below the docking width.
  - All-caps chrome in a few headings.
- **Latent, found in review, not fixed:**
  - The daemon data source compares request deadlines in system time against monotonic time, so
    deadlines effectively never expire.
  - The persisted backend's file index and diff work runs inside its GenServer. That is against the
    ownership rule, and a slow Git call stalls every request.
  - Neither caused a visible failure in the sandbox. Both need a design change and their own tests.
- **Edits show no hunk inline in the transcript.** Enter now opens the pager (Q9), but the diff is
  one key away rather than on screen.
- **A prompt at the right edge loses its timestamp.** A user prompt that fills the row drops its
  `16:36` (seen in `f1-inspector.png`). This is intentional and not a defect, noted for the design
  owner.
