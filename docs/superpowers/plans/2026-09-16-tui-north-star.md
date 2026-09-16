# SwarmCode TUI north star: the hive you can see

Date: 2026-09-16. Status: proposal, nothing built.

Claude Code and Codex CLI are single-agent chat logs with good manners: one
column, one agent, tool calls folded into one-liners, a spinner, a prompt.
SwarmCode is not that product. It runs many agents at once, keeps every run
for ever, and can judge answers against each other. The screen should make
those three facts obvious in the first second. Today it hides them.

## 1. What the screenshot shows

Taken from the saved session on 2026-09-16 at 15:00, 170 columns.

1. **The transcript has no shape.** A run card at the top, a floating list
   of ten file paths in the middle of the screen, the word `tool` below it,
   thirty blank rows, then the composer. No turn markers, no speaker, no
   time, no indication that the list is the output of one tool call among
   several.
2. **The right pane is empty for the one run kind that needs it.** A swarm
   run shows `AGENTS / RUNNING / Kind · swarm` and nothing else. Which
   agents, doing what, on which files, for how long: none of it.
3. **Progress means nothing.** The tick bar under the run title is a grey
   rule with no fill; it looks like a loading bar that never loads.
4. **System vocabulary leaks.** `OK ACCEPTED`, `NEEDS 0 · Activity`,
   `S SWARM · parallel agent lanes`, `Focus: composer`. These are the
   reducer talking to itself.
5. **Space is wasted twice.** A twelve-cell empty gutter on the left, and a
   transcript column that stops at 60% of the width while the inspector
   holds four words.
6. **Tabs are opaque.** Coloured dots for run state and a title cut at
   fourteen cells. Nothing says how many agents, whether something needs
   you, or how long it has run.
7. **Nothing streams visibly.** No caret, no elapsed time, no token count,
   no "lead is planning" line. A running swarm looks identical to a stuck
   one.

The root cause is not the painter. The presentation facts the daemon
sends are too thin to draw anything better:

| DTO | What it carries | What a good screen needs |
| --- | --- | --- |
| TranscriptItem | role, state, text, reasoning | tool name, arguments, result, duration, exit status, files touched, tokens |
| AgentSummary | id, state, allowed actions | name, role (lead/scout/builder/judge), current step, current tool, files, tokens, cost, started/finished |
| RunSummary | title, state, kind | progress (steps done/total), budget used, needs count, checkpoint count |
| Workspace | runs, transcript, interactions | changes ledger (file, hunks, author agent), checkpoints, cost totals |

Everything below assumes those fields are added to the daemon contract.
Section 12 lists them exactly.

## 2. Principles

1. **The hive is the hero.** Agents are first-class on screen at all times,
   not a detail behind a key.
2. **Every pixel says state.** Colour, fill and motion encode running,
   waiting-on-you, done, failed. Nothing is decorative.
3. **Three zoom levels, one grammar.** Overview (all runs), run (one hive),
   lane (one agent). `Ctrl-+`/`Ctrl--` or `z` cycle; the same keys mean the
   same thing at every level.
4. **The human's queue is sacred.** Anything waiting on you is one key away
   and visibly counted, always.
5. **Time is a dimension.** Runs persist, so you can scrub, rewind, branch
   and compare. Claude Code cannot; make it the thing people talk about.
6. **Plain words.** "Waiting for you", "3 agents reading", "2 files changed",
   never `NEEDS 0` or `OK ACCEPTED`.

## 3. The main screen

170 columns. Transcript takes the width it needs; the hive panel is fixed
at 44 cells and collapses to a one-line strip under 120 columns.

```
 ⬢ SWARMCODE  ailogic · main ✓ · deepseek-v4.1-flash          $0.42 · 12k ctx · 15:00
 ● read only app analysis ⬢3 02:14   ○ hi   ○ hi again                    + new  Ctrl-R
 ─────────────────────────────────────────────────────────┬────────────────────────────
  you · 14:58                                             │ HIVE  read only app analysis
  read only app analysis                                  │ 3 agents · 02:14 · 4.1k tokens
                                                          │
  lead · planning ✱                                       │ ⬢ lead     planning           ▇▇▇▇
  I'll fan out three read-only scouts: web layer, domain, │ ⬢ scout-1  reading ailogic_web ▇▇▅
  and the test suite. Each reports back with a summary.   │ ⬢ scout-2  reading lib/ailogic ▇▃
                                                          │ ⬡ scout-3  queued
  ▸ scout-1  read 12 files  ailogic_web/…          1.2s ✓ │
  ▸ scout-2  grep "Repo\."  41 hits                0.4s ✓ │ WAITING FOR YOU · 0
  ▾ scout-3  ls lib/ailogic_web                    ● 0.3s │
      ailogic_web/views/                                  │ CHANGES · 0 files
      ailogic_web/endpoint.ex                             │
      ailogic_web/router.ex                               │ TIMELINE
      … 7 more  (Enter opens, d diff, y yank)             │ ▏▏▏▏▏▏▏▏▏▏▏▏▏▏▏▏▏▏▏▏▏▏▏▏▏▏▏▏▏▏
                                                          │ 14:58 you · lead · s1 s2 s3
  lead · writing ▍                                        │
  The web layer has 8 controllers and no auth on…         │ Ctrl-G runs  Ctrl-I inspect
 ─────────────────────────────────────────────────────────┴────────────────────────────
 ▍ Type a message, / for commands…                              read-only · vim NORMAL
  Enter send · Esc back · Ctrl-K palette · ? keys                                      
```

What changed against today:

- **Turns have a speaker line**: `you · time`, `lead · planning ✱`, and the
  agent's own name on tool calls. Role colour: you neutral, lead accent,
  workers by lane colour, judge violet, errors red.
- **Tool calls are one-liners** with name, argument summary, result summary,
  duration and status glyph. `▸` collapsed, `▾` expanded, `Enter` toggles,
  `o` opens the full result in the inspector. Long results show the first
  five lines and `… N more`.
- **Streaming has a caret `▍`** on the item being written and an elapsed
  timer on the run tab. A stuck run shows "no output for 40s" in amber
  after a threshold.
- **The tab row shows `⬢3`** (agents), `02:14` (elapsed), and a `!` badge
  when a run waits on you. Titles get 24 cells before elision.
- **The gutter is gone.** Text starts at column 2.

## 4. The hive panel and semantic zoom

Three levels, same keys.

**Overview** (`Ctrl-G` today, or zoom out from a run): every run as a row of
cells. One cell per agent, filled by progress, coloured by state. This is the
"beehive" made literal and it is scannable at 200 runs.

```
 RUNS · ailogic                                   12 running · 2 waiting · 41 done
 ● read only app analysis    ⬢⬢⬢⬡        02:14   lead planning
 ! consensus: terminal change ⬢⬢⬢⬢⬢ ⚖    05:40   judge needs your vote
 ● migrate auth to tokens    ⬢⬢⬢⬢⬢⬢⬢⬢    18:02   builder-4 editing lib/auth.ex
 ○ hi                        ⬢           done    "hi mate"
 ✕ lets do consensus         ⬢⬢          failed  401 from provider
```

**Run** (the main screen above): lanes with current step and a mini gauge.

**Lane** (`Enter` on a lane, or zoom in): one agent's own transcript, its
tool calls, its files, its tokens, with `p` pause, `s` stop, `t` steer.

Glyphs: `⬢` running/done, `⬡` queued, `⚖` judge, `!` waiting on you, `✕`
failed. All need the width-safe check; ASCII fallbacks `(o) ( ) [j] ! x`.

## 5. Waiting for you

One inbox for approvals and questions across all runs. `n` jumps to the
next item, `N` to the previous, from anywhere. The count is always visible
in the header and on each tab.

An approval shows the exact command, the working directory, the risk
class, and the agent's one-line reason, with `y` once, `Y` for this run,
`a` always, `d` deny, `e` edit the command before approving.

```
 ┌ builder-4 wants to run ────────────────────────────────────────────────┐
 │ $ mix ecto.migrate                            in ~/dev/ailogic          │
 │ writes the database · reversible with mix ecto.rollback                │
 │ "the token table migration must exist before I can compile the tests"  │
 │ y allow once   Y allow for this run   a always   d deny   e edit        │
 └────────────────────────────────────────────────────────────────────────┘
```

## 6. Changes, the comb

A ledger of every file an agent touched in this run, with the author lane,
hunk count, and a per-hunk accept/revert. `Ctrl-D` opens it; inside, `j/k`
move, `Enter` expands a hunk with two-colour diff, `a` accept, `r` revert,
`A` accept file, `o` open in `$EDITOR`. A "blast radius" line says how many
files and lines changed and which agents overlap on the same file, which is
the swarm's own failure mode and nobody else shows it.

## 7. Timeline, rewind, branch

Every run is persisted, so the timeline strip under the hive is a real
scrubber. `[` and `]` step back and forward through checkpoints; the
transcript and the changes ledger re-render as of that moment. `b`
branches a new conversation from the checkpoint. `c` compares two
checkpoints side by side. This is the feature Claude Code structurally
cannot have and it should be in the demo video.

## 8. Consensus

A judged run gets a verdict card: candidates in columns, the judge's
criteria as rows, a filled cell per point awarded, the winning column
highlighted, and the judge's reasoning collapsed below. `v` votes with the
judge, `V` overrides. At overview zoom the run shows `⚖` and the score.

## 9. The composer

- Slash commands autocomplete in a popup above the composer as you type,
  with a one-line description and the keys that command takes.
- `@` mentions a run, agent or file with the same popup, and turns into a
  steer target or an attachment.
- The mode strip on the right of the composer says the approval mode, the
  keymap mode, and the queue state: `read-only · vim NORMAL · 2 queued`.
- Multi-line by `Ctrl-O` stays; a draft that is not empty survives run
  switches, and the tab shows a pencil glyph.

## 10. The visual companion

The terminal is the control surface. A companion is a second, read-mostly
surface for the things a grid of cells does badly: syntax-coloured diffs,
long tool output, images and screenshots agents produce, the hive as a
graph, and the timeline as a real scrubber.

Two forms, one data path. Both subscribe to the same daemon watch stream
the TUI already uses, so they never disagree with it.

**Browser companion.** The CLI starts a local HTTP listener on a random
port with a one-time token in the URL, and `Ctrl-\` opens it. It renders:

- the hive as a live graph: lead in the centre, lanes around it, edges for
  handoffs, node fill for progress, red halo for waiting-on-you;
- the changes ledger with full syntax colouring and a file tree;
- artefacts: any image, HTML report or screenshot an agent attached;
- the timeline as a draggable scrubber with checkpoint pins.

Clicking anything in the companion focuses the same thing in the TUI, via
the daemon, so the keyboard user never loses their place. The core repo
already has a LiveView web app; the companion should reuse its components
and palette rather than grow a second design system. The CLI currently has
no HTTP dependency, so this adds Plug and Bandit, which the release must
carry.

**Inline companion.** In terminals that speak the kitty graphics protocol
(ghostty, kitty, wezterm, iTerm2; the capability probe already knows their
names) the same artefacts render inline in the inspector: a screenshot from
a browser smoke test, a rendered diagram of the hive, a plot. Everywhere
else the item shows a one-line "image · 1200×800 · o opens in companion".

## 11. Beauty, concretely

- **One accent, six semantic colours, nothing else.** Accent for the lead
  and focus, green done, amber waiting, red failed, violet judge, dim grey
  chrome. Lane colours come from a fixed six-hue ring so agent 7 wraps.
- **Vertical rhythm.** One blank row between turns, none inside a turn,
  tool one-liners indented two cells under their agent's line.
- **Motion with meaning.** The caret blinks only while streaming. The lane
  gauge animates only on new tokens. Nothing spins.
- **Empty states that teach.** A new conversation shows three example
  prompts and the three keys that matter, then gets out of the way.
- **Density switch.** `Ctrl-Shift-D` toggles compact mode: no blank rows,
  tool calls always collapsed, hive as a strip. For 40-row terminals.

## 12. Daemon contract additions

The TUI cannot draw what it is not told. Add to the presentation facts:

- TranscriptItem: `tool: %{name, args_summary, result_summary, duration_ms,
  status, files: [path]}`, `tokens: %{in, out}`, `agent_id`.
- AgentSummary: `name`, `role`, `step`, `tool`, `files`, `tokens`, `cost`,
  `started_at`, `finished_at`, `parent_id`.
- RunSummary: `progress: %{done, total}`, `needs: integer`, `cost`,
  `checkpoints: integer`, `agents: integer`.
- WorkspaceSnapshot: `changes: [%{path, hunks, agent_id, state}]`,
  `checkpoints: [%{id, at, label}]`, `budget: %{used, limit}`.
- New watch kinds: `artifact` (image/html/text with a detail ref),
  `verdict` (consensus scores).

All bounded, all optional with defaults, so the fake data source and the
existing tests keep working.

## 13. Roadmap

Each phase ships on its own and is demoable.

| Phase | Delivers | Needs daemon change |
| --- | --- | --- |
| A. Transcript shape | speaker lines, tool one-liners, streaming caret, plain words, gutter removed, richer tabs | tool summary fields |
| B. Hive panel | lanes with step and gauge, overview cells, lane zoom | agent name/role/step/tokens |
| C. Waiting for you | inbox, `n`/`N`, approval card with edit | none |
| D. Comb | changes ledger, per-hunk accept/revert, blast radius | changes in snapshot |
| E. Time | timeline scrubber, rewind, branch, compare | checkpoints |
| F. Companion | browser graph, diffs, artefacts, inline images | artifact kind, HTTP listener |
| G. Consensus | verdict card, vote/override | verdict kind |

A alone fixes most of what the screenshot shows. A plus B is the point at
which the product stops looking like a chat log.

## 14. Open questions

- Does the daemon already know tool names and durations internally, or do
  the adapters need to record them? (Section 12 depends on this.)
- Companion auth: the one-time token in the URL is enough for localhost;
  is remote use over SSH a target? If so, port forwarding instructions or a
  QR code in the TUI.
- Should the hex glyphs be the default or an opt-in theme? They need the
  width check on every supported terminal before they can be default.
