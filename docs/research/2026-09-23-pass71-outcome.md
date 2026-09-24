# Pass 71 outcome: the second round

Finisher report on `p71/integrate` (worktree `/Users/zaali/dev/swarm-code-cli-wt/p71-F`), from main
`6e8dad1` plus the three owners' branches merged in order with `--no-ff`:

- `p71/S` (2d8217c): service and runtime.
- `p71/I` (b64c0b3): interaction.
- `p71/V` (2195dcd): visuals.

There were no merge conflicts.

The finisher then did three things:

- Did the owners' cross-requests and the partial V4/V5 wiring.
- Fixed both P0 findings and nine of the ten P1 findings from the dogfood review
  (`~/.cache/p70cli/ (was /private/tmp/p70cli/, wiped by a reboot) round2/review.md`).
- Ran the plan's acceptance items 2 to 6 on a release built from this branch.

The sandbox setup:

- `HOME=/private/tmp/p70cli/p71-F/home`, a copy of the 53-migration sandbox database.
- A scratch `ailogic` copy at `/private/tmp/p70cli/p71-F/ailogic`.
- GNU screen, with raw logs rendered by `/private/tmp/p70cli/ux/vt.py`.
- 10 real prompts on `deepseek-v4-pro`, one of them a small `/swarm`. The first attempt at
  acceptance item 4 died before it sent anything (see "Still open").
- Every screen session was closed through the TUI's own quit path.
- Nothing touched the real database, `~/dev/ailogic` or `scripts/install.sh`.

## What the owner will notice

- **Long answers are whole.**
  - A 2.7 KB answer now shows to its last sentence. Before, anything past 2 KB was cut mid-word with
    no marker. Prompts and replies now travel up to 8 KB.
  - Past 8 KB the reply ends with "… N kB more · Enter opens it all".
  - A command's output says how much is left ("… 20+ more lines, 3.1 kB more · Enter opens"), and
    Enter opens it whole. An expanded row shows 20 lines, not 5 (F1).
- **Edits show their change in place.** In a real session the edit row now shows its first hunk:
  `@@ -1,3 +1,4 @@`, then `+# p71f check` in the diff colours. V drew the hunk, but the daemon never
  sent it (F5).
- **Quitting is calmer (R1, I).**
  - A Ctrl-C that stops a turn, clears the draft or closes a layer never arms the quit. Two idle
    presses quit.
  - Quitting with a live run asks first. The summary lists what was stopped (S4) and names the
    conversation to resume: `swarmcode … --resume <id>` (F18, F21).
- **Enter while the app is starting works (R2, I).** The prompt waits and is sent once the
  conversation has loaded.
- **The side pane earns its space (R3, V).** A single-agent turn shows a compact run card and its
  changes. A swarm shows the hive.
  - Rails are thin `▏` at the rich tier. The rich tier now actually reaches real sessions: the
    launchers set it from `TERM` and truecolor (F4). Before, every real session drew at the measured
    tier.
- **Code blocks are cards** with a language chip (R4, V).
- **The run tabs are the runs.** A finished chat or goal turn no longer gets a tab with a frozen
  clock. Live runs, swarms and workflows keep theirs, and so does the run in view (F11).
- **Opening a conversation shows its latest turn**, not its first prompt (F10).
- **Select mode steps over what is drawn.** `j`/`k` no longer land on a silent "thought" or a
  worker's hidden calls (F13).
- **Commands the model runs make normal files.** The release's `umask 077` stays on SwarmCode's own
  data, but `touch` in the project now makes `-rw-r--r--` again (F6).
- **Polling a background command no longer asks** to run `$ true` (F6). A background command or a
  poll without an exit code shows a clock instead of a green check, and a poll says "still running"
  (F12).
- **A denied command stays in the transcript** as `✕ run mkdir …`. Before, it vanished until the
  conversation was reopened (F17).
- **A stopped swarm keeps its workers' work.**
  - Each finished worker's report shows under its lane, up to 12 rows, then "… N more rows · l opens
    the lane".
  - There is one stop line, not "Swarm stopped by user." followed by "stopped by you" (F14, F20).
- **`-p` is its own conversation.** It starts a new conversation unless `-c`, `--resume` or
  `SWARM_CONVERSATION` names one. In a full-access project it says so on stderr before the turn (F9).
- **Light mode is reachable.** `SWARM_THEME=light`, or the desktop settings' `mode: light`, paints
  the Carbon light palette (V4 plus F4).
- **`/diff` on a narrow terminal** opens the run's changes as a dialog instead of doing nothing (V5
  plus F3).
- **The queue count shows on the composer rule** ("N queued", S5 plus V5). A queued prompt whose
  start is refused is retried a few times before it is reported (F8).
- **An unknown `--model` is named** in the refusal (F19).

## Acceptance

| # | Result | Evidence |
| --- | --- | --- |
| 1 | pass | `mix precommit` on the merged tree without `_build/prod`: core 146/0, daemon 949/1, cli 1486 + 5 properties/0. The one daemon failure was `backup/gate_test.exs:702`: its first hook wait (5 s) timed out while the backup was still copying, the same cause pass70 Q23 fixed for the file's later waits. F23 raises that wait and the one at line 785 to 30 s, along with their `Task.await`s. The file alone then passed 55/0; it takes 416 s, which is also recorded under "Still open". `scripts/dev/check_terminal_port.sh`: `cargo fmt --check`, `cargo test --locked` and the licence check all pass. `mix swarm_code.keymap --check` matches. PTY suites: `test_terminal_port_pty.py` 15/0, `test_live_session_pty.py` 1/0, `test_saved_session_pty.py` 1/0, `test_terminal_demo_pty.py` 8/0. The demo suite needed F16: under R1 each press stops one of the demo's several live turns before an idle press arms. |
| 2 | pass | `A` on `touch p71f_a.txt` (the card offered `A always "touch"`), then `touch p71f_b.txt` ran without asking (31 ms). `D` on `mkdir p71f_dir` stopped the run, and no directory was made. `env \| cut -d= -f1`, run by the model in a session launched with a clean environment (`env -i`, `SWARM_ENV_FILE=~/.secrets`), listed 26 names. None of the 13 non-provider names in `~/.secrets` were among them. `SWARM_API_KEY` was scrubbed; `SWARM_BASE_URL`, `SWARM_MODEL`, `SWARM_PROVIDER` and `SWARM_EFFORT` remain. A launch from this agent's own shell also showed 5 non-provider names, but that shell had already exported them before the launch; the launcher does not load them. |
| 3 | pass | Ctrl-C while a 1200-word story streamed gave `stopped 13s`. A second Ctrl-C 0.4 s later did not quit. With a swarm live, select-mode `q` asked "Stop 1 live run and quit?". After `X` the summary read `Stopped 1 live run · parallel file summarization · swarm`. Two idle Ctrl-C presses in session `e` quit with exit 0. |
| 4 | pass | `Say pong` plus Enter, typed about 0.3 s after launch, was sent once the conversation loaded and answered `pong` (session `d`). The first attempt, in the first launch of a freshly copied release, closed with "The terminal stopped responding" (see "Still open"). |
| 5 | pass | At 160x45 the single-agent chat showed the compact card: `✳ Assistant ⬤ done`, `elapsed · tokens · cost · files 1`, then `Changes · 1 file · +1 −0` with `M lib/ailogic.ex`. `/swarm` showed the hive: lead, two sub-agents, Current task, Operations. The code block was a card with an `elixir` chip. The edit row showed `@@ -1,3 +1,4 @@ / +# p71f check` inline. The 2750-byte reply was shown whole. The session drew at the rich tier (`▏` rails). At 80x24 the denied row and the stopped turn stayed readable. |
| 6 | pass | Both P0 findings are fixed; see the next table. |

Captures, all rendered with `vt.py`, are in `/private/tmp/p70cli/p71-F/cap/`:

- `d01` (Enter during start-up; compact card).
- `d04-after-A`, `d05` (A always).
- `d08-denied` (R5 before F17).
- `d10-edit`, `d11-edit-top` (code card, whole reply, inline hunk).
- `d12-ctrlc`, `d13-swarm`, `d14-quitask`.
- `e01-swarm-stopped` (R9 reports).
- `e02-denied` (R5 after F17).
- `e03-80x24`.

## Reviewer findings

| Finding | What happened |
| --- | --- |
| R1 P0 replies over 2 KB cut mid-word | Fixed in 32c50fc (F1). Prompts, replies and agent results travel up to 8 KB. A snapshot that would not fit its byte limit falls back to 2 KB. Past the bound the reply ends with a "more · Enter opens it all" row, and Enter or `o` on the item opens the detail. Tests: `persisted_backend_test` "a reply over 2 KB travels whole…", and `workspace_turns_test` "a reply cut past…". |
| R2 P0 "(Enter opens)" never opened, wrong count | Fixed in 32c50fc (F1). Enter on an item with a `detail_ref` opens it (`Keymap.text_target/2`), and `o` prefers the selected item. The count says the bytes left. An expanded row shows 20 lines. Test: `workspace_turns_test` "an output sent in part…". |
| R3 P1 each poll asks to run `$ true` | Fixed in a35c558 (F6). `RunCommand.permission/1` is `:read` whenever `poll` is set without `stop`, because `run/3` never runs `command` when polling. This is a synced file; the edit is recorded as a provenance patch. Test: `pass71_commands_test`. |
| R4 P1 green ✓ while the exit code is pending | Fixed in 0f3dfb7 (F12). The mark is a clock, and a poll says "still running". Folding polls into the command row was not done. Test: `workspace_turns_test` "a background command and a poll…". |
| R5 P1 a denied command disappears live | Fixed in e6e3322 (F17). The cause was that `interaction_remove` took the op's id out of the workspace order, because the approval and the op share the id. Checked live: `✕ run mkdir p71f_dir2`. Test: `read_model_pass71_test`. |
| R6 P1 `-p` appends to the working conversation, silent full access | Fixed in 2bd867d (F9). The launcher exports `SWARM_CONVERSATION=new` for `-p` unless a flag or the variable names one, and a full-access project prints one stderr line. Tests: `launcher_test` "-p alone starts a new conversation", `headless_full_access_test`. |
| R7 P1 umask 077 leaks into agent commands | Fixed in a35c558 (F6). `env.sh` keeps `SWARM_USER_UMASK`, and `run_command` and hook scripts start with `umask <user's>`. `AtomicFile` still makes new files 0600; that is the desktop's own behaviour. Checked live: `touch` gave `-rw-r--r--`. Tests: `pass71_commands_test`, `release_umask_test`, and the locked-branch hash re-pinned. |
| R8 P1 `/resume` opens at the top | Fixed in 974b230 (F10). Navigating forward resets the main scroll to follow, and Back restores the saved scroll. Test: `reducer_navigation_test`. |
| R9 P1 stopping a swarm hides the finished worker's result; two stop lines | Fixed in 619bbf0 and 2b91ad9 (F14, F20). Seen live before F20: the reports showed, but the swarm's `:system` stop message still doubled the line. Test: `workspace_turns_test` "a stopped swarm shows…". |
| R10 P1 swarm budget and live activity | Deferred. A per-swarm budget passed to `spawn_agent` is a domain change (synced engine) with its own design. The worker rows' worktree text is the engine's. A related observation: an isolated worker in the scratch project reported "69 files changed, +417 −17711", because the untracked scratch-copy state was captured in its delta. |
| R11 P1 select mode steps through invisible items | Fixed in d184a9f (F13). The main region's stops are the items that draw a row when unselected. Test: `workspace_turns_test` "select mode steps over…". |
| R12 P1 every chat turn becomes a tab | Fixed in e235f5b (F11). A finished `chat`/`goal` run has no tab unless it is in view. The ctx meter still follows the selected run. Test: `projector_shell_tabline_test` "finished chat turns…". |
| R13 P2 titles mangle identifiers | Deferred (P2; the title comes from the synced `Conversations.set_title_from`). |
| R14 P2 picker chrome | Deferred (P2). |
| R15 P2 a command row repeats its command | Not seen this round: rows showed `exit code 0` in the detail column. No change. |
| R16 P2 provider error printed twice as raw JSON | Deferred (P2). |
| R17 P2 unknown `--model` not named; `-p --json` has no usage | Half fixed in 0e4eb2b (F19): the refusal names the model. The JSON usage, cost and duration fields are deferred. |
| R18 P2 read-only blocks edits silently | Deferred (P2). Seen again: read-only blocks `ls`, and the model asked how to proceed. |
| R19 P2 `/approval` without an argument leaves the draft | Deferred (P2). |
| R20 P2 the summary suggests `--continue` | Fixed in 240a897 and 3457800 (F18, F21). The hint is `swarmcode [DIR] --resume <id>` for the conversation on screen at the end. Tests: `persisted_session_release_test`. |
| R21 P2 slow start | Deferred (P2). No profiling was done this round. |
| R22 P2 empty state repeats hints | Deferred (P2). |

## Owners' requests

| Request | What happened |
| --- | --- |
| V → I-1: `/diff` below the docking width | daad208 (F3). The reducer opens `{:run_inspector, run, :changes}` when the layout has no inspector. Test: `command_feedback_test`. |
| V → I-2/S-2: light mode into the port owner | c0ae381 (F4). `Owner` takes `theme:`. The release reads the desktop settings' `mode` with a read-only query and passes `Theme.mode(SWARM_THEME, mode)`; the live dev launcher passes `SWARM_THEME` only. Test: `owner_test` "the theme the launcher chose paints the frame". |
| V leftover 2: real sessions drew at the measured tier | c0ae381 (F4). The launchers never took `Capabilities.from_probe/1`, so `glyph_tier` stayed `:measured`. The new `Capabilities.glyph_tier/4` applies the probe's rule. Under GNU screen, pass `TERM=xterm-ghostty COLORTERM=truecolor` in the command. |
| V → S-1: the edit's hunk on the wire | 549eff1 (F5). The facts job adds `hunk` (the first hunk, at most 13 lines and 4 KB) and `diff_lines`, and the DTO and codec carry them. Test: `pass70_changes_test`. |
| I → S: the PTY suites' Ctrl-C comments | f82638e (F15), and 39ce880 (F16) raised the demo suite's press budget. |
| I → finisher: AGENTS.md composer-first text | f82638e (F15), and 1e035e7 (F22) for the other facts that changed. |
| I → S4: the summary lists the runs stopped by the quit | Kept as S built it: runs stopped by a Ctrl-C before the quit are stopped by the user and are not listed. |
| I → V (optional): a hint while a send is deferred | Not done. The toast "Sends once the conversation has loaded." is the cue. |
| S → finisher: the `pass70_qa_queue_test` flake | 707707b (F8). `drain_queue` put a refused start back without arming anything, and dropped a busy pop silently. Both now retry up to 8 times, 250 ms apart, then report. Test: `pass70_qa_queue_test` "a queued prompt whose start is refused…". |
| Task: the unused `alias …DTO` warning | Resolved by the merge. S5 made `pass70_qa_queue_test.exs` use the alias, so the merged tree prints no such warning. The finisher's attempt to drop the alias broke compilation and was reverted. |

## Still open

- **`backup/gate_test.exs` is slow.** 55 tests take 416 s when the file runs alone, all of them
  synchronous. The hook waits are now 30 s, so the slowness no longer causes failures, but the file dominates the daemon
  suite's wall time.
- **First launch of a freshly copied release.** Session `a` closed with "The terminal stopped
  responding" (exit 1). The log shows `:terminal_initialization_failed`: the session runtime ended
  before the port reported Ready. This was the first exec of a just-copied `swarm-terminal-port`
  (macOS scans a new binary), with a prompt already typed. Four later launches, with and without
  typed-ahead input, were fine. Worth a look: the runtime's binding deadline against a slow first
  exec.
- **R10**: a swarm budget, live worker activity and cost per row.
- **The P2s**: R13, R14, R16, R17 (JSON usage), R18, R19, R21, R22.
- **The quit dialog** still says `Esc CANCEL` / `X CONFIRM EXIT` in capitals. The keymap and the
  PTY suites pin the text.
- **From S**:
  - Slash commands (`/export`, `/search`) still run inside the persisted backend's `handle_call`.
  - With S6, a mid-op checkpoint shows on the op's finishing upsert.
  - `persisted_backend_test` "run inspector pages older persisted message records…" failed once under
    load (36 load average during the first precommit) and passes alone. S saw the same.
- **Under heavy load** the first full precommit had 5 daemon failures: two schema-gate
  `cleanup_pending`, two backup-gate timeouts and the paging test above. All passed when rerun alone
  (113/0).
