# Lane R notes (cli020 fix round): terminal robustness

Branch `cli020/fixR` from CLI main `55dbe5a2`, worktree `~/dev/swarm-code-cli-wt/fix-R`.
Brief: `01_fix_round.md` R1-R3. Nothing outside the R row was edited (see "Needs outside R").

## Root cause of the QA close (R2)

QA session home2 (2026-10-07, `~/.cache/ncode/cli020/qa/home2`), `cli.log`:
`20:28:03.178 (stop) :draw` then `terminal owner stopped: :draw`, `session closed:
:terminal_unavailable`. The order of events, from file times:

| Time | Event |
| --- | --- |
| 20:28:01 | `r2-14-writing-header.txt` (the harness's `shot`, during a long stream at 80 ms/word) |
| 20:28:02 | `r2-14-writing-header.json` (`capture`: the last PTY read before the PNG) |
| 20:28:03 | `r2-14-writing-header.png` (the PNG render: about a second with no PTY read) |
| 20:28:03.178 | the owner stops with `:draw` |
| 20:28:07 | `ctl2/cmd.json` holds `[["key","ESC"],…]`: the Esc was sent after the close |

So the Esc did not cause the close; the reader stall did. The chain (each step read in
the code or measured):

1. A macOS pty holds about 1 KiB of output the terminal has not read (measured: a raw slave
   in non-blocking mode accepted 1024 bytes, then EAGAIN). Any frame larger than that needs
   the terminal to read while it is written.
2. The native session wrote frames through `FdWriter`, which gave every write 500 ms
   (`tty.rs`), then `painter.draw(...).map_err(|_| 3)` turned the timeout into failure code 3
   (`session.rs`), which the owner maps to `:draw` and stops on (`owner.ex` `record({:error, 1,
   code})`). A terminal that pauses its reader for 500 ms ended the session.
3. A second, BEAM-side cause showed up in the reproduction: the runtime's draw deadline is
   `close_ms` after its request (1 s by default and in the dev live session, 3 s in the
   release), while the owner answered a slow paint only 1 s after the frame was built and
   never answered a request queued behind it. In the reproduction (dev live session) the
   runtime gave up first: `session closed: :draw_failed`, then the native `:draw` 0.9 s later.

Reproduction, before the fix (`scripts/dev/test_terminal_stall_pty.py`, log
`~/.cache/ncode/cli020/fix-R/stall-before.log`): the screen froze at `1.1s` and `w0049`, then
`[error] session closed: :draw_failed`, `(stop) :draw`, `** (Mix) Development live terminal failed`.

## What changed

Native (`native/terminal_port/src/tty.rs`, `session.rs`):

- `FdWriter::patient/1`: no time bound while the terminal is alive. It fails when the terminal
  is gone (a write error such as EIO, or POLLHUP/POLLERR from poll; measured: after the master
  closes, poll reports POLLHUP and write returns EIO) and when the helper is terminating
  (SIGTERM from the owner's reap, or from the guard once the BEAM's pipe closed; both existed).
- The session's terminal output (frames, titles, OSC 9/bell, OSC 52, the kitty probe) uses it.
- Restoration stays bounded: the title restore now writes through a bounded `FdWriter` (it is
  part of restoration and runs before `guard::modes(None)`), and the guard's own writes
  (activate, restore, mouse, kitty push) and the BEAM pipe keep `FdWriter::new` (500 ms).
- Darwin's `poll` does not support `/dev/tty` (measured: POLLNVAL at once on `/dev/tty`,
  POLLOUT on `/dev/ttys003`). The stand-alone mode opens `/dev/tty`; on POLLNVAL the patient
  writer sleeps 10 ms instead of spinning (a really invalid descriptor fails the write, EBADF).
  The BEAM handoff reopens the named tty, where poll works.

Owner (`ui/renderer/ratatui_port/owner.ex`):

- R1: `control/2` no longer does `true = Port.command(…)`. Controls (shutdown, suspend, resume,
  redraw, and the mouse mode change, which was dropped on a busy port before) go into a
  bounded outbox: at most one of each kind, a shutdown replaces everything still waiting, a
  newer mouse choice replaces an older one (back to the terminal's current state means
  nothing is sent). The port is retried every 10 ms by one `:busy_retry` timer (it also
  replaces `grant/1`'s `:grant` timer, which could pile up one chain per failed grant). The
  token is taken when the port accepts the command, so tokens stay increasing whatever was
  sent in between, and the awaited `control` gets that token (`{:shutdown, nil, rt}` until
  then). The wait is bounded by the deadline of the phase the control opened (3 s for
  shutdown/suspend/resume, then `:terminal_timeout`). While a control waits, paints are
  answered stale (controls first) and no credit is granted (the retry grants after them).
- Frames never crash the owner: a frame the busy port cannot take is answered stale and the
  runtime's next request draws the newest state (unchanged behaviour, now tested); at most
  one queued request is kept.
- R2: every draw request is answered inside the runtime's deadline. The soft deadline is
  400 ms (was 1 s) and counts from the request, not from the end of the paint build; a request
  queued behind a waiting paint gets its own 400 ms deadline (`queued_timer`), after which it
  is answered stale and the runtime asks again. The 60 s hard deadline after the soft one is
  unchanged: a terminal that reads nothing for a minute ends the session as before.
- `terminate/2`: when the port refuses the final shutdown (busy: the helper is not reading),
  the helper is reaped at once (SIGTERM, then SIGKILL after 500 ms; SIGTERM restores the
  terminal) instead of being awaited for 3 s for an exit that cannot come.

## Tests (R3)

- Owner unit tests, new `test/swarm_code_cli/ui/renderer/ratatui_port/busy_port_test.exs`
  (6 tests, a helper written to `tmp_dir` that reads nothing until a gate file exists, so the
  port is really busy: `:erlang.port_info(port, :queue_size) > 8192`): controls on a busy port
  wait, keep their order and change the modes; a newer mode change replaces the waiting one;
  shutdown and suspend are delivered once the port drains and their restored records match;
  a frame the busy port cannot take is answered stale and the next request paints; every
  request (in flight and queued) is answered within 900 ms. Watched failing first on the old
  owner, 6 of 6: three controls crashed it (`:terminal_protocol_failed`), the deadline test got
  no answer within 900 ms, the mouse test found no outbox, and the busy-frame test missed its
  answer within ExUnit's default 100 ms (a 500x200 frame takes about 130 ms to build; that
  wait is now 3 s, and the test also needs the new `{:sent, :credit}` observer event). While
  making them pass, a helper path with an apostrophe (the test name) broke the gated shell
  script; the path is now shell-quoted.
- `owner_test.exs` "a stalled native reader cannot block the owner's shutdown deadline": the
  expected stop reason changes from `:terminal_protocol_failed` (the R1 crash) to
  `:terminal_timeout` (the shutdown waited until its deadline), still within 4.5 s.
- Cargo (`tests/tty_output.rs`, module `patience`, 4 tests): a patient write waits out a pty
  reader that stalls 1.2 s; a bounded write still gives up; a patient write ends when the pty
  master closes and when a pipe's reader closes. Watched failing (no `FdWriter::patient`).
- `scripts/dev/test_terminal_port_pty.py`: new `test_slow_terminal_delays_the_paint_and_keeps_input`
  (the reader stops 1.5 s during a frame, Esc typed in the middle: no answer during the stall,
  `painted` after it, then the Esc event and another frame) and
  `test_terminal_gone_during_a_waiting_frame_ends_the_port` (master closed while a frame waits).
  `test_undrained_terminal_restoration_retry_has_bounded_failure` encoded the 500 ms failure
  as expected; it became `test_undrained_terminal_waits_and_termination_restores_within_bounds`
  (an undrained terminal keeps the frame waiting for 1.5 s with no answer, then SIGTERM ends it
  with bounded restoration, exact termios, no `painted`, the writer reaped). The two stalled
  tests failed on the old binary (it emitted Failure code 6 after 500 ms). The holder now
  ignores SIGHUP after spawning the port, so a test can hang up the terminal and still read
  the port's exit status (the port keeps its own SIGHUP handler).
- New `scripts/dev/test_terminal_stall_pty.py` (the brief's reproduction, full TUI): the dev
  live session with a loopback OpenAI-compatible stream of 400 words 15 ms apart; once the
  stream draws, the test stops reading the PTY for 1.5 s and sends Esc after 0.75 s. It asserts
  the session stays alive, the card shows `stopped` while it runs, the stream was cut before
  its last word, no `stopped responding`/`session closed`/`draw_failed` text appeared, and a
  clean quit (exit 0, termios restored, no process left). Failed before the fix (see above),
  passes after (the turn stops at about w0100, 1.8 s).

## Deviations and decisions

- Two existing tests encoded the bugs and were changed, not just extended: the port PTY
  undrained-terminal test (expected the 500 ms failure) and the owner's stalled-reader test
  (expected the R1 crash reason). Both keep their purpose: bounded restoration and a bounded
  shutdown against a helper that never reads.
- The owner's soft draw deadline went from 1 s to 400 ms. In the dev live session (`close_ms`
  default 1 s) the old value raced the runtime's deadline and lost; 400 ms leaves room for a
  paint build. Changing `close_ms` in `scripts/dev/live_session.exs` (not in this row) was not
  needed once the owner answers every request within its bound.
- `session_runtime.ex` and `effect_runner.ex` are unchanged: the runtime's draw deadline is a
  correct guard against an unresponsive owner once the owner guarantees its answer.
- Bell, OSC 9 and title notifications stay best-effort on a busy port (dropped, as before):
  they do not change terminal modes. A busy port is rare for them: a slow terminal blocks the
  helper, not the port's queue (the owner sends no new frame or credit while a paint waits).
- Clipboard copy on a busy port still answers `{:error, :busy}` (unchanged).

## Needs outside R (for the integrator)

- AGENTS.md "TUI facts" could carry one line: "A slow terminal slows the TUI: the port's
  frame writes wait for it (a macOS pty holds about 1 KiB), only a gone terminal (EIO/HUP) or
  termination ends them, restoration and guard mode writes stay bounded at 500 ms; the owner
  keeps controls in an outbox while the port is busy and answers every draw request within
  400 ms." Not edited (not in this row; the fix does not need it).

## Residuals (not fixed, with the reason)

- The guard's mode writes (`Tty::activate` at resume, `mouse`, `kitty_push`) keep the 500 ms
  bound, so a `/mouse` toggle, a resume after `$EDITOR`/`!cmd`, or the kitty push after the
  start-up probe, landing exactly while the terminal's reader is stalled with a full pty
  queue, still ends the session (`:restoration`). Each happens right after user input or a
  terminal answer, when the terminal is reading. Making them patient would leave the guard
  unable to watch the BEAM's pipe while it waits (it is single-threaded), so a gone BEAM plus a
  stuck terminal could leave the helper pair behind; that trade was not taken here.
- The BEAM pipe writer (helper to BEAM) keeps 500 ms: the BEAM reads its port promptly and its
  death is EPIPE at once.
- A terminal that reads nothing for 60 s still ends the session (`:terminal_timeout`, "The
  terminal stopped responding"), by design (pass70 B2's hard deadline).
- The small-pipe condition (another app holding many pipes, new pipes 512 bytes) was not
  present today (a fresh pipe took 65,536 bytes), so R1 was verified with a gated helper that
  keeps the port's queue over its busy limit, not under that condition.

## Assumptions

| Assumption | Status | How |
| --- | --- | --- |
| The home2 close came from a reader stall, not from Esc | verified | file times above; the Esc command file is newer than the close |
| A macOS pty holds about 1 KiB of unread output | verified | measured 1024 bytes, then EAGAIN |
| `/dev/tty` gives POLLNVAL on Darwin; the named tty works | verified | measured in a forked session |
| A closed master gives the slave POLLHUP and EIO | verified | measured |
| The release and the dev sessions use `--beam-port` (named tty) | verified | `Owner.init/1` passes `--beam-port`; `Tty::beam_handoff` reopens `ttyname` |
| The port's busy limit is the default `{4096, 8192}` | verified by test | `busy!/2` asserts a queue over 8192 and `Port.command` refuses afterwards |
| The runtime's draw deadline is `close_ms` (1 s default, 3 s release/demo) | verified | `session_runtime.ex` `draw/1`, `persisted_session.ex`, `demo/terminal.ex` |
| No production code sets the owner's `observer` | verified | grep: only tests (the other `observer:` options are the plain session's) |
| The 60 s hard deadline should stay | guessed | the brief asks that a gone terminal still end the session; a minute of no reads is treated as gone, unchanged from pass70 |

## Gates run (worktree, 2026-10-08)

| Gate | Result |
| --- | --- |
| `mix format --check-formatted` (umbrella root) | exit 0 |
| `mix compile --warnings-as-errors` (umbrella root) | exit 0, no warnings |
| `scripts/dev/check_terminal_port.sh` (cargo fmt --check, cargo test --locked, licences) | exit 0, 73 cargo tests |
| `mix test` `ui/renderer/**`, `pass73_theme_test`, `c74_preferences_test`, `architecture_test` | 97 tests, 0 failures |
| `mix test` `persisted_session_release_test`, `demo/terminal_test`, `pass73_mouse_test`, `entry/{report_details,resume_selection,c74_launch,exit_summary,c74_settings_open}_test` | 41 tests, 0 failures |
| PTY `test_terminal_port_pty.py` | 24 OK |
| PTY `test_terminal_demo_pty.py` | 8 OK |
| PTY `test_live_session_pty.py` | 1 OK |
| PTY `test_saved_session_pty.py` | 2 OK |
| PTY `test_terminal_stall_pty.py` (new) | OK, 3 of 3 runs |

PTY suites ran one at a time under a scratch `HOME`, `NCODE_CONFIG_DIR` and an empty
`SWARM_ENV_FILE` (`~/.cache/ncode/cli020/fix-R/pty-home`, wrapper `fix-R/tools/pty.sh`).
Not run: the full suite / `mix precommit` (finisher's slot), `keymap --check` and
`settings --write` (no binding or registry touched), provenance verify/sync (no repin).
