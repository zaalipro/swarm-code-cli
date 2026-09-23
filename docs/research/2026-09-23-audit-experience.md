# SwarmCode CLI: UX audit (ux, 2026-09-23)

Scope: the installed-style release of CLI HEAD cd0b1e8 (`/private/tmp/p70cli/rel-head/bin/swarmcode`),
driven for real in a sandbox HOME (copy of the prod DB) at 160x45, 120x36, 90x30 and 80x24, plus the
cell gallery, the UI pipeline source, the north-star plan and the hive spec, and the desktop tokens.

## 0. Verdict

The owner is right, and it is not a matter of polish. In the default configuration the daily loop is
broken at the two places that matter most:

1. **Any shell command stalls the run for ever.** Approvals cannot be granted from the TUI: `n` opens
   a dialog that says "Read-only at this size; resize to act" at 160x45, and "Approve" from the palette
   answers `ERROR REJECTED`. Root cause is in the daemon (op node id vs agent node ids, section 2.1).
   Every prompt that makes the model run `ls`, `mix test` or `find` hangs until you `/stop` it.
2. **The switchers crash the whole app on a real conversation.** Ctrl-R and Ctrl-G on the owner's
   ailogic conversation `7d01acff…` (10 runs, a failed 14-agent workflow) end the session with
   `:terminal_draw_failed` → `RuntimeError Saved terminal failed`, 4 of 4 launches (Ctrl-R twice,
   Ctrl-G twice, once without screen logging) (section 2.2).

Past those, the transcript does not read like a conversation (all tool rows are hoisted above all
text, every other row is "thinking"), markdown and code render as plain prose, there is no diff view
anywhere, no text copy, no prompt history, no conversation switching, and the keyboard model makes
letters dangerous: one Esc and the next `q`/`p`/`x`/`a` you type quits, pauses, stops or opens a
palette. The screen also talks to itself: `Focus: 10souhkYm5ubb…`, `FOCUS > Run 180bf9b5-…`,
`[INFO] PENDING`, `ERROR REJECTED`, `Settings 1 · available`, raw JSON settings.

The recent investment went into the right-hand hive pane (cards, gauges, sub-agent grid). That pane
is the most finished part of the product and is genuinely close to the desktop. The fix is to turn the
same care onto the chat loop: transcript, approvals, composer, status line, and to stop spending 10 of
24 rows on chrome.

## 1. How this was tested (reproducible)

- Sandbox: `HOME=/private/tmp/p70cli/ux/home` (copy of `sandbox-home`), project
  `/private/tmp/p70cli/ux/ailogic` (scratch copy) and, read-only with no prompts,
  `/Users/zaali/dev/ailogic` with `SWARM_CONVERSATION=7d01acff-1478-49d8-ade8-a20c16ff7be3`.
- Driver: GNU screen 4.00.03 (`-U`, `-L` raw log). Its hardcopy mangles glyphs, so I replayed the raw
  byte log through a small VT emulator (`/private/tmp/p70cli/ux/vt.py`) that reconstructs every cell
  with its true glyph and truecolor fg/bg and renders a PNG. All captures are in
  `/private/tmp/p70cli/ux/cap/` (`s160-*`, `s120-*`, `s90-*`, `s80-*`, `real-*`, `.txt` + `.png`).
  Gallery SVGs rasterised with `/private/tmp/p70cli/ux/svg2png.py` into `/private/tmp/p70cli/ux/gallery/`.
- Real LLM prompts used: 4 (read+markdown, write+shell, /swarm with two workers, edit+shell) plus one
  deliberate provider error (`/model test-model`, connection refused). No keys printed.
- TERM was `xterm-256color`, so the session drew the `:measured` glyph tier; the owner's ghostty gets
  `:rich` (half blocks, smooth gauges). The gallery covers the rich tier.

## 2. Blockers (fix before anything visual)

### 2.1 Approvals cannot be granted (bug, critical)

Evidence (`cap/s160-appr2.txt`, `cap/s160-appr6.txt`, 160x45):

```
    ▸ Assistant  run: ls -la notes  awaiting approval !
    ┌ Read-only at this size; resize to act ─────────────────────────┐
    │FOCUS > Back / Close / Help                                      │
    ...
ERROR REJECTED                      <- after Ctrl-P › Approve, twice
```

- Daemon: `Operation.do_work` asks `RunServer.request_approval(run_id, id, permission)` with the **op
  node id** (`domain/engine/operation.ex:192`); the projection publishes that id as the interaction's
  `node_id` (`daemon/service/persisted_backend.ex:1059-1066`); but `execute/4` rejects any
  `node_id not in run.node_ids` (`persisted_backend.ex:441`) and `run.node_ids` holds **agents only**
  (`persisted_backend.ex:901`, query `n.kind == "agent"` in `persisted_projection.ex:194`). Result:
  `:not_allowed`, shown as `ERROR REJECTED`.
- Client: `n` → `{:open_interaction, id}` navigates to `{:run, id}` first (`ui/reducer.ex:520-541`); the
  run destination drops the interaction from the read model, and `dialog.ex:560-568` then renders the
  fallback title `read_only_resize`, which blames the terminal size for a lookup miss.
- The approval is only shown as a side-pane card with raw JSON (`{"command":"ls -la notes"}`) and no
  key hints; Tab never reaches the `NEEDS APPROVAL` action (Tab toggles composer/main only).
- Also: in the default mode a `write_file` ran without asking while `ls` needed approval, yet the
  launcher help says `SWARM_APPROVAL  ask (default)`. The desktop calls this mode "auto"; the CLI never
  shows the mode on screen and has no way to change it at runtime.

### 2.2 Ctrl-R / Ctrl-G crash the app on a real conversation (bug, critical)

Evidence (`stderr-real.log`, tails of `cap/raw-real-crash1.log`, `raw-real2.log`, `raw-real3.log`):
four launches on conversation `7d01acff…`, Ctrl-R twice and Ctrl-G twice (the last one without
screen logging), four identical exits:

```
[error] GenServer #PID<0.2142.0> terminating ** (stop) :terminal_draw_failed
[notice] Application swarm_code_daemon exited: :stopped
** (RuntimeError) Saved terminal failed  (release/persisted_session.ex:279, from :166)
```

`Owner.dispatch({:draw…})` treats *any* exception in `Paint.build`/`Frame.encode`, and a `false`
from `Port.command(…, [:nosuspend])` (a busy port), as fatal (`ui/renderer/ratatui_port/owner.ex:96,
115-119`), and `persisted_session.ex:163-166` turns the owner's death into a crash of the session.
It reproduced without screen logging, so it is a raise in the draw path for this data (candidates:
the run-row/dashboard projections for a failed workflow run whose tab shows `132:14:22`), not only
backpressure. Whatever the row, one bad row must never kill a coding session: render an error block
for the failing region and keep going; treat a busy port as "skip this frame".

### 2.3 Letters are commands one Esc away (ux, high)

From the composer, `Esc` moves focus to the transcript (`Focus: main`), where bare letters are bound:
`q` quits (and the release then stops every owned run), `x` stop, `p` pause, `a` palette, `o` open,
`n` next waiting, `m` mark seen, `t` inspector, `g` go-to, `i` compose (`docs/keybindings.md:227-303`).
`exit_requested/2` only confirms when the *draft* is dirty (`ui/reducer.ex:1058-1071`); live runs do
not count. Typing "please fix…" after a reflexive Esc pauses the run, expands a row, opens the palette.
Claude Code, Codex and opencode never take the prompt away: scrolling, approvals and commands work
while the prompt keeps focus. On exit the screen even says `DETACHED — RUNS CONTINUE`
(`ui/session_runtime.ex:563`) while the release stops them (`release/persisted_session.ex:196-198`,
stderr: "q stops owned runs").

### 2.4 The screen leaks internals (visual, high)

All seen live at 160x45:

- Status line `Focus: 10souhkYm5ubbK2S2kymlB1Q3zkO6ZUrYfj6MLuDCW4`, `Focus: 180bf9b5-9a2b-…`,
  `Focus: row-16`, `Focus: cmd-diff`, `Focus: cancel`: `projector/status.ex:93-98` prints
  `state.focus` raw.
- Every list marks focus with the literal text `FOCUS > ` and states with `[INFO]`, `ERROR`,
  `! WAITING`: `UI.Theme.cue/3` attaches a SafeText prefix to roles `:focus`, `:info`, `:error`,
  `:warning`, `:accent`… in *every* colour mode (`ui/theme.ex:269-313`, moduledoc "Consumers render
  `prefix` in every color mode"). Correct for `NO_COLOR`, noise in truecolor.
- Palette rows `Conversation 2d8a08b4-5b17-41ac-8134-a3ffb763a3fc`, `Run 180bf9b5-…`, `Full detail`
  twice, `Inspect run` twice, lower-case `inspector width balanced`, and `item 4 of 24` / `Cancel` as
  list rows (`ui/switcher.ex`, `projector/dialog.ex:571-600`). The inspector dialog lists
  `Agent e6375b3c-… · DONE` and Enter does nothing.
- Settings dialog: `Settings 1 · available` … `Settings 4 · available` and a raw JSON dump of
  application defaults (`cap/s120-settings.txt`).
- Errors name providers by hex: `CLI openai_compatible 8d70905d784e4458 request failed after 2
  attempts: connection refused` (also in the model picker rows).
- Header title swaps to `SAVED · DEV` (a dev-launcher banner, `safe_text.ex:614-616`) whenever the
  view is a run destination, in the *installed* release.
- `ERROR REJECTED` stays pinned under the headline for the rest of the session, across runs.

### 2.5 Other correctness problems met on the way (bug)

- `Full detail` / `Full reply` opens `Detail · byte 0 … LOADING` and never loads (`cap/s160-full2.txt`).
- Changes (Ctrl-P › Changes) lists the whole git working tree of the project (21 files of the owner's
  unrelated edits) instead of this run's changes; selecting `Diff` re-lists instead of showing a diff
  (`cap/s160-diff3.txt`). The side pane's changes tab shows `notes/hello.md  Assistant ✓` with no
  +/- counts and no way to open it.
- `x` (stop current run) does nothing from the conversation view; `/stop` works.
- Timeline labels the user's prompt as `Assistant text` (`cap/s160-timeline.txt`).
- A failed workflow's tab keeps counting: `⧉ /design-coloring ⬢14 132:14:22`.
- Dashboard says `3 runs · 0 live` while a swarm waits on you; `1 runs`.
- `_(stopped)_` is printed with literal underscores (emphasis with `_` is not parsed).
- Plausible, not proven: bursts of arrow/j keys move fewer rows than pressed (23 Down → `item 4 of
  24`, 21 `j` → `row-16`). Input is gated on draw credit (`owner.ex:335-340`); worth a PTY test.

## 3. What makes it useless as a daily tool (the non-blocker list)

### 3.1 The transcript is not a conversation

Live, first prompt (`cap/s160-top.txt`), 160x45:

```
  you · 08:33
  Read mix.exs and list the files under lib/ then answer in markdown: …

    ▸ Assistant  thinking
    ▸ Assistant  read mix.exs  94 lines · defmodule Ailogic.MixProject…  6ms ✓
    ▸ Assistant  list lib  ailogic/ ailogic/accounts/ ailogic/audi…  14ms ✓
    ▸ Assistant  thinking
    ▸ Assistant  read lib/ailogic/application.ex  64 lines · defmodule Ailogic.Applicatio…  3ms ✓
    ▸ Assistant  thinking

  Assistant · 08:33
  I'll read the requested files first.          <- said BEFORE the tools, drawn after them
  Dependencies
```

- `Turns.order/1` ranks every item of a run as prompt (0) → all tools/thinking (1) → all words (2)
  (`projector/workspace/turns.ex:126-163`). Interleaving (text, tool, text, tool, answer) is destroyed;
  the pre-tool sentence is shown twice (inside the expanded `thinking` row and in the reply).
- Every model step is a `▸ Assistant  thinking` row: half the rows in a real workflow run
  (`cap/real-a.txt`: 12 of 24 rows read `▸ apply-fixes  thinking`). Each row repeats the speaker.
- While the answer streams, its header says `Assistant · thinking ▮` (mislabelled state).
- The user's message has no surface: same colour and weight as the reply; the desktop draws it as a
  card (`.bubble-user`, `--bg-card`, `app.css:1141-1152, 3866-3871`).
- The selected transcript row has no highlight at all (only `▸`/`▾` changes). With `j`/`k` you cannot
  see where you are.
- A worker's full report is inlined under the lead (`cap/s160-swarm3.txt`, 20 rows of
  `worker-a-accounts` prose inside the lead's turn).

### 3.2 Markdown and code render as prose

`paint/markdown.ex` supports `#` headings, `- * +` bullets, fences, `**`, `*`, and backticks. The
`:code` role is `text_primary` (`theme.ex:246`), so fenced code and inline code look exactly like
prose: no background, no border, no gutter, no syntax colour; the fence language prints as a dim
line (`elixir`). Not handled at all: numbered lists (rendered as plain lines), nested lists, `_em_`,
block quotes, tables (the /swarm prompt asked for a table), links, rules, diff fences. Mid-stream
the raw backtick shows (`(with `ob`).

### 3.3 No diffs anywhere

Edits appear as `edit assets/css/app.css  edited assets/css/app.css: 1 replacemen…`; the gallery's
`+42 −7` exists only in fake data. No inline hunk, no side-by-side, no per-file ledger with counts,
and the Changes dialog cannot open a diff (2.5). For a coding harness this is the core artifact.

### 3.4 Scrollback, copy and leaving the app

- Alternate screen, mouse reporting explicitly off (`native/terminal_port/src/tty.rs:100-110`): the
  wheel does not scroll the transcript, a click does nothing, and when you quit the conversation is
  gone from the terminal. Claude Code and Codex leave the transcript in native scrollback and print a
  resume hint on exit; here the last thing on screen is the misleading `DETACHED — RUNS CONTINUE`.
- Selecting text with the terminal's own selection grabs the side pane's columns on the same rows
  and hard-wrapped lines; there is no copy action (no OSC 52 anywhere in `apps/` or `native/`), no
  "copy code block", no "open in $EDITOR".
- PgUp/PgDn only work after leaving the composer (2.3). `G/End` "follow the stream" is implicit.

### 3.5 Chrome eats the screen

Rows spent before the first transcript line / after the last one:

| size | top chrome | bottom chrome | transcript rows | notes |
|---|---|---|---|---|
| 160x45 | 5 (title, tabs, `Waiting for you · 1`, headline, `ERROR REJECTED`) + actions row | 5 | ~34 | 43 cols of side pane even when it says `No run selected` |
| 90x30 | 5 | 5 | 20 | first answer line on row 24 (`cap/s90-b.txt`) |
| 80x24 | 5 | 5 | 13 | a 3-line prompt plus 1 expanded tool fills it (`cap/s80-a.txt`) |

The prompt is printed three times at the top (tab title, headline, then the `you` turn);
`Waiting for you · 1` three times (banner, composer rule, status line). The actions row
(`Pause  Stop  Inspect  NEEDS APPROVAL  Full reply`) is not reachable by Tab and duplicates bindings.
The tab row and Ctrl-R palette and Ctrl-G dashboard are three renderings of the same run list.

### 3.6 Keyboard discoverability

- The `?` sheet is a 2-column dump of 40 bindings with truncated help ("Move focus on; from the
  transcript, into the c…") and a stray `FOCUS > Cancel` (`cap/s160-help.txt`).
- `a` means "action menu" in the transcript and "Approve" in a dialog; the action menu is the same
  24-row palette as Ctrl-P.
- Alt-1…4 are the only direct run-tab keys (Alt is unreliable on ghostty per AGENTS.md); Alt-H/L/0
  resize the dock (fine, not essential).
- Ctrl-C detaches and ends the session instead of interrupting the current turn (the universal
  expectation in Claude Code/Codex). There is no "Esc interrupts the model".
- Shift-Enter never works (enhanced keys are always unavailable); newline is Ctrl-O only.
- Up on an empty composer does not recall the last prompt (no history: `ui/editor.ex` has only
  undo/redo history). No `@file` mentions, no path completion.
- Slash palette shows 2 rows under the composer (`cap/s160-slash.txt`); 17 builtins, none of the
  session basics: `/new`, `/clear`, `/resume` (pick a conversation), `/help`, `/quit`, `/approval`,
  `/diff`, `/cost`, `/init` (`apps/swarm_code_core/lib/swarm_code/commands.ex:13-36`).

### 3.7 Onboarding, models, status

- First screen (`cap/s160-start.png`) is decent: `READY TO BUILD`, three first steps. But `[INFO]
  FIRST STEPS` (cue prefix), the model printed twice, and a 43-col pane saying `No run selected`.
- `/model` opens a flat list of 145 models with provider hex ids (`test-model  CLI openai_compatible
  8d70905d784e4458`), no grouping by provider, no context/price, and the switch gives no toast. A
  model that cannot connect is offered next to working ones.
- Conversation switching is refused by the backend (REVIEW.md #23); the only way is
  `SWARM_CONVERSATION=<uuid>` at launch. No conversation list at all.
- Status line = `Focus: <id>` + key hints. It lacks what a harness status line is for: approval mode,
  mode (Build/Plan), model, context used, cost, branch, queue, live run elapsed.

### 3.8 Colour and look against the desktop

- `UI.Theme` matches Carbon dark hex for hex (`theme.ex` vs `swarm-code/assets/css/themes.css:20-60`):
  good. But the TUI paints `#141414` into every cell and ignores the desktop's theme/mode (the
  sandbox DB settings say `"mode": "light"`) and the terminal's own background. Offer
  "terminal background" (default colour, no canvas fill) as the default and map the eight desktop
  themes x two modes later.
- The desktop's visual grammar is not carried into the transcript: user bubble card, inline-code
  chip (`.prose-chat :not(pre) > code`), code blocks on `--bg-card`, op rows with coloured status
  chips (`.op-row`, `app.css:1572, 7118`). The side pane already does chips and cards; the transcript
  does none of it.
- The heavy `▬▬▬` composer rule and `▐` rails are the loudest elements on screen; the conversation
  is the quietest.

### 3.9 Performance and output volume (perf)

- The Rust writer repaints every dirty row in full and emits, per cell, `SGR 0` + fg + bg + an
  absolute `CUP` + the glyph, twice for wide cells (`native/terminal_port/src/output.rs:147-222`,
  `style/2` at `:224-238`). Measured: ~690 KB per full 160x45 repaint, 15-30 KB per keystroke,
  3.5 MB while one reply streamed, 50 MB of terminal output in a 25-minute session.
- Typing throughput ~22 chars/s (100 chars via `stuff` took 4.5 s to settle; 50 chars 4.0 s on the big
  conversation). Human typing keeps up; SSH, tmux, screen or a slow emulator will not, and together
  with 2.2 (busy port = fatal) slow terminals are a crash risk.
- Fix: diff at cell-run granularity (ratatui's own diff plus an explicit erase for forced-width
  cells), emit SGR only on change, use relative moves or none within a run. Expect 20-50x less output.

### 3.10 Narrow terminals

At <120 cols the side pane disappears entirely with no strip (the north-star plan promised a one-line
strip). At 90 the tab row shows one tab plus `+4`; the approval card, agents and changes are only
reachable through dialogs. At 80x24 the product is a 13-row window.

## 4. The redesign: 14 moves, highest value first

Constraints respected: glyphs from the `:measured` set (`▐ ▗▖▝▘ ▰▱ ⬤ ⬡ ✦ ✳ ⋔ ✓ ✕ › ◷ ⎇ ▮`) with ASCII
twins, every new glyph measured with `Width.cells/2` under `:narrow` and `:wide`; colours only from
`UI.Theme` roles; bindings only in `Keymap.Bindings`; no Ctrl-K; nothing essential on Alt. Free Ctrl
chords today: T, F, L, X, J (bound: A B C D E G N O P R U W Y Z).

### M1. Approvals that work, drawn where the eye is (bug+ux, owner: daemon + keyboard)

Daemon: accept an interaction whose `node_id` is the op node (add op ids of pending interactions to
the admission check, or key interactions by `interaction_id` alone and look the node up server-side:
`persisted_backend.ex:421-448, 901, 1059`). Client: open the approval without navigating away, or keep
interactions in the read model across destinations (`reducer.ex:520-541`); replace the
`read_only_resize` fallback with "This request is no longer pending" (`dialog.ex:560-568`).
Then draw it in the composer slot, like Claude Code, with the draft preserved underneath:

```
before (side pane, 43 cols, no keys)          after (composer slot, full width)
▐ ? the run wants to run a command            ▐ worker-b wants to run a command                 1 of 2 waiting
▐ {"command":"find lib/ailogic_web/live -…    ▐ $ find lib/ailogic_web/live -name '*.ex' | wc -l
▐ runs a command · needs your permission      ▐ in ~/dev/ailogic · read-only command · "count the LiveViews"
                                              ▐ y once   Y this run   A always "find"   d deny   e edit   n next
```

`A` must remember the command family (the desktop's prefix rule), not the whole `:execute` class
(REVIEW.md #17). Show the approval mode on the status line and add `/approval read-only|auto|full`.

### M2. Composer-first keyboard model (ux, owner: keyboard)

The composer never loses focus by accident. Letters always type.

| key | today | proposed |
|---|---|---|
| Esc | leave composer; letters become commands | interrupt the streaming turn (once), close top layer; never moves focus |
| PgUp/PgDn, Ctrl-U/D (empty draft) | only after Esc | scroll transcript from the composer |
| Ctrl-T | free | select mode: banner `SELECT · j/k move · Enter open · y copy · Esc back` |
| Ctrl-C | detach = end session | clear draft → interrupt turn → second press quits, confirming live runs |
| q | quit from transcript | only in select mode and pickers; quitting with live runs asks |
| Up (empty draft) | nothing | previous prompt (history per conversation) |
| Ctrl-J / `\`+Enter | nothing | newline (keep Ctrl-O) |
| Ctrl-X | free | edit the draft in `$EDITOR` |

Files: `ui/keymap/bindings.ex`, `ui/keymap.ex`, `ui/keymap/special.ex`, `ui/reducer.ex`
(`exit_requested/2` must count live owned runs), `ui/editor.ex` (history ring),
`docs/keybindings.md` (regenerate), `ui/session_runtime.ex:563` (honest exit text).

### M3. A transcript that reads like a conversation (ux, owner: transcript)

Keep daemon order inside a run: text, tools, text, as it happened (drop the prompt/work/words ranking
in `projector/workspace/turns.ex:126-163`). Fold `thinking` into the turn header (`thought 4s`),
show reasoning only on expand. Tool calls of one step form one group under the agent, one row each,
no repeated speaker. The user turn is a card on the `card` surface with the accent rail.

```
before (160x45, live)                                   after
  you · 08:33                                           ▐ you                                            08:33
  Read mix.exs and list the files under lib/ then…      ▐ Read mix.exs and list the files under lib/ then answer…

    ▸ Assistant  thinking                               ⬤ assistant · deepseek-v4.1-flash      17s · 19k tok
    ▸ Assistant  read mix.exs  94 lines · defmodu… ✓      I'll read the requested files first.
    ▸ Assistant  list lib  ailogic/ ailogic/acco… ✓       ✓ read  mix.exs                        94 lines    6ms
    ▸ Assistant  thinking                                 ✓ list  lib/                     2 dirs · 31 files   14ms
    ▸ Assistant  read lib/ailogic/application.ex … ✓      ✓ read  lib/ailogic/application.ex     64 lines    3ms
    ▸ Assistant  thinking
                                                          Dependencies
  Assistant · 08:33                                       • {:phoenix, "~> 1.7.0"} with phoenix_live_view …
  I'll read the requested files first.
  Dependencies                                            ▗ elixir ─────────────────────────────── y copy ▖
  …                                                       ▐ def application do                              
                                                          ▐   [mod: {Ailogic.Application, []}, …]          
                                                          ▝ end ────────────────────────────────────────── ▘
```

Selection gets a row background (`:card` + `:focus` rail), not only `▸/▾`. Streaming header says
`writing ▮`, not `thinking ▮`. Sub-agent reports collapse to one line under the lead
(`✦ worker-a-accounts ✓ 16s · 3 files read · "two Ecto schemas plus…"  Enter opens`).
Files: `projector/workspace/turns.ex`, `projector/workspace.ex`, `paint/blocks.ex`.

### M4. Markdown, code and diffs (visual, owner: transcript)

`paint/markdown.ex`: numbered and nested lists, `_em_`, block quotes (muted rail), tables (columns
sized with `Width.cells`, truncation with `…`), links (text + dim URL), rules. Code: a `code` surface
role on the card background, language chip, `y copy` hint, and a small keyword/string/comment
tokenizer for the top languages (elixir, js/ts, py, rust, sh, json, diff); inline code as a chip
(`#262626` bg). Give `:code` its own style instead of `text_primary` (`theme.ex:246`).
Diffs: edit/write rows show `+3 −1` and expand to a hunk; the changes ledger lists this run's files
with counts and opens a pager with the full diff (fix the daemon feed first, 2.5).

```
✓ edit  lib/ailogic/accounts/user.ex                          +3 −1   4ms
    41   def changeset(user, attrs) do
    42 −   |> validate_required([:email])
    42 +   |> validate_required([:email, :role])
    43 +   |> validate_inclusion(:role, ~w(user admin))
```

### M5. One header row, one status line that earns its place (visual, owner: chrome)

Collapse title + tabs + headline + banner + actions (5-6 rows) into two: a title/tab row and the
turn itself. Feedback (`REJECTED`, `PENDING`, model switched) becomes a 4-second toast on the status
line with a human sentence, never a pinned banner.

```
before (6 rows)
⬢ SWARMCODE  ailogic · Build · deepseek-v4.1-flash · 11k tokens
▐ ✳ Create notes/hello.md… ⬤ ⬢1 !1    ✳ Read mix.exs and list… ⬤ ⬢1 00:17        Ctrl-R runs  Ctrl-G all  Ctrl-P features
Waiting for you · 1
✳ Create notes/hello.md containing two short lines greeting the team, then run the shell command:…  waiting for you
ERROR REJECTED
Pause  Stop  Inspect  NEEDS APPROVAL
...
! WAITING Waiting for you · 1  Focus: composer  Enter Send  Esc Back out  Ctrl-P Palette  Ctrl-O Newline  Tab Next

after (1 row top, 1 row bottom)
⬢ ailogic · main ✓   ▐ ⬤ create notes/hello.md !1 00:42   ✓ read mix.exs 00:17   ⋔ dir summaries ⬢3   +2   Ctrl-R
...
 Build · auto · deepseek-v4.1-flash · ctx ▰▰▱▱▱▱ 19k/128k · $0.04 · 1 waiting (y/d)        Esc interrupt · ? keys
```

Files: `projector/shell.ex`, `projector/status.ex` (never print `state.focus`; delete lines 93-98),
`projector/workspace.ex` (headline and action deck), `projector/run_row.ex`, `safe_text.ex`
(`SAVED · DEV` only for dev launchers).

### M6. Stop the screen talking to itself (visual, owner: chrome)

- `Theme.cue/3` text prefixes (`FOCUS >`, `[INFO]`, `ERROR`, `! WAITING`, accent markers) only when
  `color_mode == :monochrome` or `NO_COLOR`; in colour, focus is a row background plus `▐` rail.
- No UUIDs or opaque ids anywhere: palette rows use titles and relative times; the inspector lists
  agents by name; status shows no focus id.
- Provider names, not `CLI openai_compatible 8d70905d784e4458` (daemon error text and model rows).
- Settings becomes a real form (mode, theme, default models, effort, approval mode) instead of
  `Settings 1 · available` + JSON (`ui/feature_form.ex`, `ui/library.ex`).
- Palette: `item N of M` and `Cancel` leave the list; duplicates get distinct labels
  (`Full reply` / `Full reasoning`); sentence case everywhere.

### M7. Palettes and pickers that feel like a premium launcher (visual+ux, owner: chrome)

```
┌ ⌕ mod                                                            ┐
│ SESSION                                                            │
│ ▐ Switch model…                    deepseek-v4.1-flash      /model │
│   Switch sub-agent model…          deepseek-v4.1-flash /swarm_model│
│ VIEW                                                               │
│   Toggle agents pane                                        Ctrl-B │
└────────────────────────────────────────────────────────────────────┘
```

Groups (Session, Run, View, Library), fuzzy match with matched letters in accent, right-aligned
shortcut or slash alias, selection = card background + rail. Model picker grouped by provider with
names and the current one checked. A conversation picker (`/resume`, Ctrl-P › Open conversation)
listing titles, relative time, run count and a live dot, which needs the backend to allow switching
(REVIEW.md #23, `persisted_backend.ex:1283-1285 member?/2`). Slash popup: 8 rows above the composer, not 2 below.
Files: `ui/switcher.ex`, `projector/dialog.ex`, `projector/composer.ex`, `ui/slash_palette.ex`, `ui/model_picker.ex`,
`apps/swarm_code_core/lib/swarm_code/commands.ex` (+ `/new /resume /clear /approval /diff /cost
/help /quit`).

### M8. The swarm view: hive inline, pane when there is room (ux, owner: transcript + chrome)

The pane is good; keep it at >=140 cols. Below that, draw a one-row hive strip above the composer
(the north-star plan's promise), and in the transcript show each worker as one collapsible lane line.

```
⋔ parallel dir summaries · lead planning · 01:59                                   47k tok · 1 waiting
  ✦ worker-a-accounts  ✓ 16s   3 reads   "two Ecto schemas plus one email helper"            Enter opens
  ✦ worker-b-live      ⌘ waiting: find lib/ailogic_web/live -name '*.ex'                     y/d
  ⬡ merge               queued
── hive ── ⬢ lead ▰▰▰▱  ✦ a ▰▰▰▰ ✓  ✦ b ▰▰▱▱ !  ─────────────────────────────── ]/[ tabs · Ctrl-B pane
```

Truncate sub-agent names only when the column is actually full (today `worker-a-ac…` with 20 free
cells, `projector/inspector/agents.ex`). Fix the dashboard `0 live` count and the ever-ticking clock of
failed runs (`projector/runs_dashboard.ex:456-470`, `projector/run_row.ex:126`).

### M9. Renderer: 20-50x less output and no crash on a bad frame (perf+bug, owner: renderer)

`output.rs:147-222`: diff cells, not rows; emit SGR only when the style changes; one CUP per run of
changed cells; erase explicitly behind forced-width cells. `owner.ex:96-119`: a busy port means
"coalesce and draw the latest state later"; a paint exception renders the previous frame plus an
error line, logs it once, and never stops the session. Budget: <50 KB per streamed delta at 160x45,
<2 KB per keystroke, keystroke-to-paint <16 ms on the 10-run conversation.

### M10. Scrollback, copy, mouse and a clean exit (ux, owner: renderer)

- Mouse: enable SGR mouse (1000+1006) for wheel scroll and click-to-select a row; document that
  Shift-drag keeps native selection (ghostty, iTerm2, kitty, wezterm). Behind a setting.
- Copy: `y` in select mode and `y copy` on code blocks copy through OSC 52 (bounded, SafeText-checked),
  with a toast; `o` opens the item in a pager; Ctrl-X opens the draft in `$EDITOR`.
- Exit: after leaving the alternate screen, print a 5-10 line summary to the main screen (last prompt,
  last answer head, files changed, `swarmcode --resume <id>` / `SWARM_CONVERSATION=<id>`), so the
  terminal's own scrollback keeps something. Replace `DETACHED — RUNS CONTINUE` with what happened.

### M11. Follow the terminal, then the desktop theme (visual, owner: renderer + chrome)

Default canvas = terminal default background (no `#141414` fill; roles stay foreground), surfaces
(`card`, `surface`) kept as subtle fills only where the design needs a card. Read the desktop's
`theme`/`mode` settings and map at least Carbon dark/light; a light terminal must not get a black
slab. Files: `ui/theme.ex` (`:canvas`), `paint/canvas.ex`, `ui/capabilities.ex`.

### M12. Errors that help (ux, owner: transcript)

```
✕ assistant could not reach "CLI openai_compatible" (test-model): connection refused, 2 attempts
  r retry   /model switch model   o details
```

No empty `Assistant · 08:53` block before it; a `Retry` action on failed runs (only `Inspect` is
offered today; the plain demo already has Retry); provider display names from the daemon.

### M13. Narrow terminals as a first-class layout (ux, owner: chrome)

- < 120 cols: hive strip (M8), tab row shows up to 3 tabs with 16-cell titles, timestamps hidden.
- < 90 cols: tool groups collapse to one summary line (`✓ 3 tools · read mix.exs +2 · 23ms`),
  composer 2 rows, status line = mode · model · waiting.
- 80x24 target: at least 17 transcript rows (today 13).
Files: `ui/layout.ex`, `projector/density.ex`, `projector/shell.ex`.

### M14. Session basics a daily tool needs (missing-feature, owner: keyboard + daemon)

Prompt history (Up), `@path` completion with the project file index, `/new`, `/resume` picker,
`/clear`, `/approval`, `/diff` (this run's changes), `/cost`, `/help`, `/quit`, image paste later.
Conversation switching in place (backend `member?/2` today refuses it). Queueing a draft while a run
streams is Alt-only today (`Alt-Enter`), against the AGENTS.md rule; add a non-Alt path (Tab while a
run streams, or `/queue`) and show `2 queued` on the composer.

## 5. What is already good (keep it)

- The Elm-style pipeline (Reducer/Projector/Paint) is the right shape for all of the above; every
  move is projector/painter/keymap work, not a rewrite.
- Carbon tokens are exact; `Theme.status/1` and lane colours are coherent.
- The hive pane at `:rich` (gallery `approval-170x42-truecolor-rich`, `swarm-170x42-truecolor-rich`):
  agent card, current-task gauge, sub-agent cards, operations list with status chips. It is the one
  surface that looks like the desktop.
- Streaming is progressive, synchronized output (DEC 2026) removes tearing, the first-run empty
  state teaches the three keys, run tabs carry agents/`!`/elapsed, `/model` with a real picker.
- Width discipline (`Width.cells`, glyph tiers, ASCII twins) is excellent; keep it for every new glyph.

## 6. Order and owners for ~5 implementers

Fix order: blockers first (M1 daemon half, crash hardening in M9), then the three moves that change
how every minute feels (M2 keyboard, M3 transcript, M5 chrome), then looks (M4, M6, M7), then reach
(M8, M10-M14). Suggested split so owners rarely touch the same file:

| owner | moves | main files |
|---|---|---|
| A daemon/wire | M1 (admission + projection), 2.5 (Full detail load, run-scoped changes with diffs, `x` stop), conversation switching, provider names in errors, approval-mode switch | `daemon/service/persisted_backend.ex`, `persisted_projection.ex`, `domain/engine/operation.ex` (read), client `data_source/daemon/codec.ex` |
| B transcript | M3, M4, M12, selection highlight, sub-agent collapse | `projector/workspace/turns.ex`, `projector/workspace.ex`, `paint/markdown.ex`, `paint/blocks.ex`, `theme.ex` (`:code` role only) |
| C keyboard/composer | M2, M1 (approval card in composer slot + y/Y/A/d/e/n), M14 (history, @path, new commands), slash popup | `keymap/bindings.ex`, `keymap.ex`, `keymap/special.ex`, `reducer.ex`, `editor.ex`, `projector/composer.ex`, `slash_palette.ex`, `swarm_code_core/commands.ex`, `docs/keybindings.md` |
| D chrome | M5, M6, M7, M13, help sheet, settings form, toasts | `projector/shell.ex`, `projector/status.ex`, `projector/dialog.ex`, `switcher.ex`, `model_picker.ex`, `feature_form.ex`, `library.ex`, `safe_text.ex`, `theme.ex` (cue prefixes), `layout.ex`, `projector/density.ex` |
| E renderer/terminal | M9, M10, M11, M8 strip painter support, perf budget tests | `native/terminal_port/src/output.rs`, `tty.rs`, `renderer/ratatui_port/owner.ex`, `release/persisted_session.ex`, `session_runtime.ex`, `paint/canvas.ex`, `capabilities.ex` |

Shared-file hazards: `theme.ex` (B adds `:code`, D changes cues, E changes canvas: land D first),
`reducer.ex` (C owns; A's interaction retention is a small reducer change, coordinate),
`projector/dialog.ex` (C's approval card vs D's palette: split by function). Every owner regenerates
the cell gallery and adds a golden cell test at 160x45, 120x36, 90x30, 80x24 for the screens touched.

Acceptance I would run after the pass (real TUI, sandbox HOME, GNU screen + the raw-log emulator):
1. `/private/tmp/p70cli/ux/ailogic`: "create notes/x.md then run ls -la notes" → approve with `y`
   from the composer; the run finishes. 2. Ctrl-R and Ctrl-G on `7d01acff…` do not crash.
3. The first prompt of section 3.1 reads in order: text, tools, text; code block on a card; one
   header row; status line shows mode, model, ctx, cost. 4. Esc then typing `please` types it.
5. 160x45 streamed reply < 1 MB of terminal output; keystroke < 2 KB. 6. Quit prints a summary.

## 7. Findings index (details above)

| id | kind | sev | title | where |
|---|---|---|---|---|
| F1 | bug | critical | approvals rejected (op id vs agent ids); `n` dialog says "resize to act" | 2.1 |
| F2 | bug | critical | Ctrl-R/Ctrl-G crash the session on a real conversation | 2.2 |
| F3 | ux | high | Esc makes letters commands; `q` quits and stops runs without asking | 2.3 |
| F4 | visual | high | internals leak: focus ids, `FOCUS >`, UUIDs, `[INFO]`, JSON settings, hex providers | 2.4 |
| F5 | ux | high | transcript hoists all tools above all text; `thinking` rows; duplicate text | 3.1 |
| F6 | visual | high | markdown/code render as prose; no tables, numbered lists, `_em_`, code surface | 3.2 |
| F7 | missing-feature | high | no diffs anywhere; Changes lists the git tree; Diff never opens | 3.3, 2.5 |
| F8 | perf | high | ~690 KB per repaint, 15-30 KB per key, 50 MB per session; 22 chars/s | 3.9 |
| F9 | ux | medium | chrome eats 10 of 24 rows; prompt shown 3x; `Waiting for you` 3x | 3.5 |
| F10 | missing-feature | medium | no copy, no mouse, nothing left in scrollback; misleading exit text | 3.4 |
| F11 | missing-feature | medium | no prompt history, no @path, no /new /resume /approval; no conversation switch | 3.6, 3.7 |
| F12 | ux | medium | status line shows focus not mode/model/ctx/cost; approval mode invisible | 3.7 |
| F13 | visual | medium | palette/pickers: dup labels, `item N of M` rows, flat 145-model list | 2.4, 3.7 |
| F14 | bug | medium | Full detail stuck LOADING; `x` no-op; timeline mislabels prompt; clock ticks on failed runs | 2.5 |
| F15 | visual | medium | canvas forced to `#141414`; desktop theme/mode ignored; transcript lacks desktop grammar | 3.8 |
| F16 | ux | low | narrow layouts drop the pane with no strip; 2-row slash popup | 3.10, 3.6 |
| F17 | ux | low | Ctrl-C ends the session; no Esc-interrupt; Shift-Enter never works; queue is Alt-only | 3.6, M14 |
