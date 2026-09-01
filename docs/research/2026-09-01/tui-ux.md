# SwarmCode CLI — terminal-native product and UX audit

**Scope.** Read-only audit of the current SwarmCode web/desktop UI to guide a faithful CLI/TUI clone. I inspected the LiveView routes and templates, shared components, CSS tokens and responsive rules, JS hooks, selected focused tests/specs, and the checked design references under `~/Pictures`. I did **not** run a browser and did not modify the source repository.

## Executive recommendation

The TUI should preserve SwarmCode's **information hierarchy, state vocabulary, modes, run relationships, and visual rhythm**, not copy its pixel layout. The defining experience is:

1. a local project/conversation context that is always visible;
2. a transcript made of durable, collapsible **run cards**, not a flat chat log;
3. asynchronous work that keeps running and remains inspectable while the user navigates elsewhere;
4. a high-priority **Needs you** channel for questions and approvals;
5. one mutually exclusive work mode — Build, Plan, Goal, Ultra, Workflow, or Consensus — plus one-shot actions such as Swarm, Compact, Review, and Deep Research;
6. a second reading surface for a run (thread/agents/timeline/changes), available on demand rather than permanently squeezing the transcript.

The web app can show a rail, 280–440 px sidebar, chat, 320–640 px side chat, and 300+ px agent pane. A normal terminal cannot. The CLI should therefore use a **stable one- or two-column shell with a unified inspector**, promoting a third/fourth column only at truly wide terminal sizes. This is the single most important choice that keeps it beautiful instead of making it look like a webpage forced into character cells.

---

## 1. What the current product actually contains

### 1.1 Route and screen inventory

The product currently has these primary destinations:

| Destination | Current route(s) | Core content |
|---|---|---|
| Workspace / chat | `/`, `/c/:id` | conversation transcript, composer, side chat, Agents/Timeline/Changes pane |
| Scheduled | `/scheduled` | month calendar, selected-day tasks, task editor |
| Workflows | `/workflows`, `/workflows/runs/:id`, `/workflows/library`, `/workflows/library/:scope/:name` | run list/detail, pipeline/script/journal/result, workflow library/editor/launcher |
| Deep research | `/research`, `/research/:id` | research launcher/list, live research timeline, report, round notes, sources |
| Usage | `/history` | budget headline/bar and usage table |
| Settings | `/settings` | General, Deep research, Appearance, Providers & models, Pricing, MCP servers, Memory, Storage, Commands, Limits, Budget |

Source: route definitions in `lib/swarm_code_web/router.ex:27-44`; settings section order in `lib/swarm_code_web/live/settings_live.ex:32-47`.

### 1.2 Global shell

The desktop UI is a three-part shell:

- a narrow icon rail for new chat, panel toggle, Chats, Scheduled, Workflows, Research, Usage, theme, and Settings, with running-count badges;
- a resizable context panel, whose contents change by destination;
- a rounded main surface with a 48 px breadcrumb/action header.

The rail hierarchy is explicit in `lib/swarm_code_web/components/frame.ex:320-417`; the main shell composes rail, destination panel, resizer, content, confirmation modal, and scheduled toast in `frame.ex:184-308`. The visual shell uses one 8 px gutter token and floating elevated surfaces (`assets/css/app.css:67-87`, `assets/css/app.css:2327-2501`). The breadcrumb header is project → conversation/page plus contextual actions (`frame.ex:1681-1736`).

The chat panel is more than “recent chats.” It includes:

- a dedicated New conversation action and search;
- Pinned conversations;
- collapsible project nodes and their recent conversations;
- loose/no-project conversations;
- scheduled tasks;
- per-row running/waiting/queued/failed/unread state;
- version, live RAM, and keyboard help.

Source: `lib/swarm_code_web/components/frame.ex:458-863`, row semantics at `frame.ex:876-953`, status mapping at `frame.ex:1175-1237`.

### 1.3 Workspace anatomy

The workspace main area is a split grid:

1. transcript + composer;
2. optional side chat focused on one run;
3. optional swarm pane with Agents, Timeline, or Changes.

The composition and state passed to each surface are visible in `lib/swarm_code_web/live/workspace_live/workspace.html.heex:165-378`. Side and pane widths are independently persisted; the chat is clamped to a 420 px minimum, side to 320 px, pane to 300 px, and the pane auto-hides when side chat opens under 1180 px (`assets/js/hooks.js:73-96`, `assets/js/hooks.js:151-181`). This is strong evidence that terminal widths must trigger **structural substitution**, not simply tighter truncation.

Header actions include expand/collapse all runs, side chat, rename, a Plan badge, pane visibility, and conversation Fork/Rename/Rewind/Delete (`workspace.html.heex:31-159`). Rewind, operation inspector, file editor, and add/edit project are modal workflows (`workspace.html.heex:396-548`).

### 1.4 Transcript and run cards

The transcript is deliberately not a plain message list. It derives one chronological sequence of messages, chat/swarm/goal/compact turns, workflow cards, and nested follow-ups. Each run card can contain:

- the launching user prompt and command chips;
- run kind, status, elapsed time, operations, token/cost metadata, and progress;
- Reply, Steer, Retry, Pause, Continue, Stop, Resume, Side chat, and Open in pane controls where applicable;
- assistant streaming output;
- activity/tool log and provider reasoning;
- approvals and multi-question interviews;
- file changes and inline diffs;
- nested follow-up/implementation turns;
- workflow pipeline state;
- consensus rounds/stages;
- a plan approval gate.

Source: transcript construction and empty state in `lib/swarm_code_web/components/chat.ex:221-429`; run dock in `chat.ex:1614-1684`; run card contract and header in `chat.ex:1745-2181`; expanded body/activity feed and controls in `chat.ex:2194-2418`.

The visual grammar matters:

- assistant output is lightweight prose with a small author/time line;
- the user's prompt and the run it launched are one panel, not two disconnected entries;
- collapsed cards retain a status line and progress bar;
- new/unread and “needs your answer” remain visible while folded;
- compacted context is a neutral `⊟ Context compacted` card with the token delta, not a hidden maintenance event (`chat.ex:1821-1823`, `chat.ex:2082-2087`; behavior verified in `test/swarm_code_web/live/polish44a_compact_test.exs:200-303`).

The transcript also has a Codex-like left minimap, one marker per user turn, with prompt/reply preview and jump behavior (`chat.ex:431-525`; hook behavior at `assets/js/hooks.js:1734-1872`). A terminal cannot reproduce hover previews, but it must preserve rapid turn navigation.

### 1.5 Activity, tools, streaming, and reasoning

During a run, activity is a live ticker showing elapsed time, operation count, and current operation. Once complete, it becomes a “Worked for…” disclosure. Expanded content groups LLM turns, intermediate text, tool operations, errors, and a nested Thinking disclosure (`lib/swarm_code_web/components/chat.ex:3389-3552`). Assistant text arrives as a stable rendered prefix plus growing tail, with an explicit caret while empty (`chat.ex:875-883`).

The web behavior is careful not to steal the user's scroll: transcript/tool panels only auto-follow while already near the bottom, freeze after user scroll, and expose a “latest” affordance (`assets/js/hooks.js:1248-1377`). The Agents list uses the same rule and exposes `↓ newest` when detached (`assets/js/hooks.js:3259-3337`). This must be a TUI invariant.

The canonical status vocabulary is:

| State family | Tone | Required textual cue |
|---|---|---|
| running / thinking / streaming | accent | `running`, live dot/spinner |
| queued / waiting / approval / retrying | amber/warn | `queued`, `waiting`, `approval`, etc. |
| paused | amber/warn | specifically `paused`, never generic waiting |
| done / completed | green/ok | `done` |
| failed / error | red/error | `failed` + error text |
| stopped / cancelled / interrupted | muted | exact terminal state |

Source: `lib/swarm_code_web/status.ex:1-80`.

### 1.6 Side chat and swarm pane

The side chat is a second reading/conversation surface for exactly one run. Its body changes by kind:

- ordinary turn: pinned user prompt and a linear reply/follow-up thread;
- goal: current-state summary and expandable turns/steers;
- swarm: filterable chronological feed by Lead/sub-agent;
- workflow: phase-oriented feed;
- consensus: compact ticker instead of the full docket.

It has its own minimal composer, draft per run, goal Ask/Steer selector, interview ownership, and run controls; it intentionally has **no slash palette, prompt history, attachment picker, model chooser, or run dock** (`lib/swarm_code_web/components/side_chat.ex:1-11`, `side_chat.ex:69-255`, `side_chat.ex:829-958`).

The right pane has three views: Agents, Timeline, Changes. Agents additionally supports Tree/Grid and Full/Compact density; content is a single chronological list of chat assistant rows, workflow pipelines, swarm/goal agent trees, and consensus benches (`lib/swarm_code_web/components/swarm_pane.ex:89-415`). Timeline selects one run or all runs, filters operations, supports density, error navigation, and an operation inspector. Changes is a file tree with diff/editor views (`swarm_pane.ex:2272-2858`, `swarm_pane.ex:2859-3259`).

### 1.7 Composer and modes

The main composer owns a substantial amount of product state:

- project/no-project switcher;
- live runs or Needs you strip;
- prompt history;
- deep-research attachment picker;
- slash palette;
- reply/steer/revise target;
- interviews and active goal bars;
- notices/edit state;
- command, goal, and research chips;
- pasted/dropped image attachments (up to four);
- queued messages;
- model + effort chooser;
- approval chooser;
- one mutually exclusive mode selector;
- stop/send button.

Source: composer contract and project/history/picker/palette in `lib/swarm_code_web/components/chat.ex:3743-4040`; composer field, chips, attachments, queue, and bottom bar in `chat.ex:4054-4417`.

Built-in slash commands currently include `swarm`, `goal`, `plan`, `review`, `effort`, `swarm_effort`, `rewind`, `stop`, `resume`, `workflow`, `workflows`, `create-workflow`, `ultra`, `deep_research`, and `compact`; saved workflows and custom commands join the same ranked palette (`chat.ex:46-92`, `chat.ex:106-146`).

The mode selector is exactly one of:

| Mode | Meaning |
|---|---|
| Build | assistant reads, writes, and runs |
| Plan | read-only tools; produces a step-by-step plan |
| Goal | next message sets a persistent goal |
| Ultra | big tasks become workflows |
| Workflow | next message authors and launches a workflow |
| Consensus | a second model judges the plan first |

The precedence and one-of-six rule are implemented in `chat.ex:4784-4816`; selector/menu markup is at `chat.ex:4818-4889`. **Swarm and Compact are actions, not modes. Deep Research is a separate asynchronous job and attachable artifact.** This distinction should remain explicit in the CLI.

The approval selector is independent of mode: Read-only, Auto, or Full access (`chat.ex:4710-4781`). Model selection independently configures chat and swarm models and each model's effort (`chat.ex:5079-5352`). Consensus adds Planner, Judge, and optional Implementer models, effort per role, 1–3 rounds, and judge checks (`chat.ex:4898-5077`).

### 1.8 Questions, approvals, and “Needs you”

Waiting work is intentionally elevated above normal progress. A composer strip lists waiting runs, urgency, elapsed, and deadline remaining (`chat.ex:528-575`). A multi-question interview shows question number, optional header, numbered choices, multi-select, Other, Back, Skip, and Next/Submit (`chat.ex:4419-4512`). Keyboard behavior presently uses 1–9, arrows, Enter, and Escape (`assets/js/hooks.js:3198-3256`). Tool approvals expose Approve, Deny, and Always allow on every relevant surface (`chat.ex:577-606`).

The TUI must treat these as an inbox, not bury them in whichever pane happened to be open.

### 1.9 Plan, consensus, workflows, research, and compact

#### Plan

A finished Plan run is not merely “done.” It exposes **Approve · Revise · Decline**. Approve then chooses Assistant or Swarm implementation; Revise targets the composer and reruns in Plan mode; the resulting implementation is nested under and visually linked to its plan (`lib/swarm_code_web/components/chat.ex:2545-2674`; focused behavior tests in `test/swarm_code_web/live/polish44b_plan_gate_test.exs:95-170`, `test/swarm_code_web/live/polish44b_plan_gate_test.exs:279-426`).

#### Consensus

Consensus has three intentionally different representations:

- transcript: full Docket with Planner/Judge(/Implementer), one accordion per round, plan and verdict panes, checks strip, and spec/implement stages;
- side chat: compact Ticker;
- Agents pane: balance/Bench plus round ledger and details on demand.

Source: component overview and Docket in `lib/swarm_code_web/components/consensus_components.ex:1-218`; round/stage entries in `consensus_components.ex:229-434`; cross-surface expectations verified in `test/swarm_code_web/live/polish35_docket_rail_test.exs:247-375` and `test/swarm_code_web/live/polish35_docket_rail_test.exs:427-462`.

The CLI should preserve the **same data at three densities**, but it does not need to preserve three simultaneous widgets.

#### Workflows and Ultra

Workflow runs have phase rails, per-panel agent cards or dense tiles, agent budget, logs, gates, pause/interrupted/result/failed cards, and lifecycle controls (`lib/swarm_code_web/components/workflow_pipeline.ex:1-16`, `workflow_pipeline.ex:38-246`). The Workflows page exposes Runs plus a Library, run tabs (Pipeline/Script/Journal/Result), workflow source editor + Check diagnostics, shape preview, launch form, and Save as (`lib/swarm_code_web/live/workflows_live.html.heex:66-229`, `workflows_live.html.heex:230-439`). Ultra delegates large tasks through this workflow machinery; Workflow mode specifically authors and launches a workflow.

#### Deep research

The index combines a question hero, four depth levels, optional project tag, model/effort, independent background execution, filters/search, and research rows with live progress (`lib/swarm_code_web/live/research_live.html.heex:39-168`, `research_live.html.heex:170-307`). Levels are Fastest (1×4), Medium (2×3), High (3×4), Ultra (4×10); a level promises depth while max-live controls load (`lib/swarm_code/research/levels.ex:1-46`).

Detail combines heading/actions, live timeline grouped by rounds/agents/sources, stats, state line, report with table of contents, round notes/agents, rated sources, and reporting agents (`research_live.html.heex:310-360`, `research_live.html.heex:497-743`). A completed research can be copied, downloaded/opened as HTML, revealed, or continued in chat as an attachment (`research_live.html.heex:445-494`).

#### Compact

`/compact [focus]` asynchronously summarizes the conversation, establishes the new history floor, and renders as its own neutral run card. It must remain visible, inspectable, and measured (`test/swarm_code_web/live/polish44a_compact_test.exs:45-62`, `test/swarm_code_web/live/polish44a_compact_test.exs:200-303`). Do not turn it into a silent local optimization.

### 1.10 Secondary pages

- Scheduled uses a month calendar + selected-day task list, with task filters and an editor supporting Chat/Swarm/Workflow, Build/Plan, model/effort, once/daily/weekly/monthly/cron schedules, color, timezone, and catch-up (`lib/swarm_code_web/live/scheduled_live.html.heex:21-297`, `scheduled_live.html.heex:300-595`).
- Usage shows period, spend/budget progress, run/conversation counts, and a Date/Project/Conversation/Model/Kind/Tokens/Cost table (`lib/swarm_code_web/live/history_live.html.heex:23-126`).
- Settings' eleven sections and persistent section navigation are listed at `lib/swarm_code_web/live/settings_live.ex:32-47`; Appearance includes four themes, light/dark, reduced motion, window-focus behavior, sidebar preference, and reasoning-open preference (`settings_live.html.heex:588-704`).

---

## 2. Visual DNA to retain in character cells

### 2.1 Current design language

The default Carbon theme is near-black with warm orange accent, subtle elevated layers, faint borders/hatch, rounded cards, restrained shadows, Inter for UI, and JetBrains Mono for metadata. Its exact dark tokens are:

- canvas `#141414`, elevated `#191919`, card `#1e1e1e`, hover `#262626`;
- text `#f3f2f0`, muted `#8c8b88`, faint `#5e5d5a`;
- accent `#ff6a1a`, success `#3ddc5a`, warning `#f5b400`, error `#ff4d4f`, info `#4da3ff`;
- agent lanes teal, violet, amber, pink, cyan.

Source: `assets/css/themes.css:16-59`. Carbon light equivalents are at `themes.css:61-100`. Obsidian, Graphite, and Aurora provide alternative palettes/modes (`themes.css:102-292`). Kind colors add Goal violet, Swarm teal, Workflow blue, Research orange, Ultra pink→violet, and Consensus lime (`assets/css/app.css:6148-6169`, `assets/css/app.css:7724-7745`).

The inspected reference images reinforce these traits:

- `~/Pictures/UI components/aichat.jpeg`: one large black composer, generous interior spacing, hairline rainbow focus edge, few pill controls;
- `~/Pictures/UI components/texts.png`: quiet assistant prose with tiny identity/meta, compact inline file diff chip;
- `~/Pictures/Designs/awesomecard.jpeg`: card hierarchy driven by labels, one accent progress strip, and disciplined metadata;
- `~/Pictures/Designs/beaitufl sidebar.jpeg`: isolated floating rail/panels rather than a continuous dashboard grid;
- `~/Pictures/Designs/calendar.jpeg` and `history.jpeg`: orange used as a focal instrument, not a page wash;
- `~/Pictures/Designs/beautiful dark 2 modal.jpeg`: strong foreground dialog, subdued background.

### 2.2 Terminal equivalents

Use a semantic terminal palette rather than spraying ANSI color:

| Semantic role | Truecolor | 256-color fallback | No-color fallback |
|---|---:|---:|---|
| canvas | `#141414` | 233/234 | default background |
| surface | `#191919` / `#1e1e1e` | 234/235 | border + spacing only |
| primary text | `#f3f2f0` | 255 | normal |
| muted/faint | `#8c8b88` / `#5e5d5a` | 245/240 | dim where supported, otherwise labels |
| accent/running | `#ff6a1a` | 208 | `* RUNNING` |
| success | `#3ddc5a` | 41 | `✓ DONE` |
| warning/waiting | `#f5b400` | 220 | `? WAITING` / `! APPROVAL` |
| error | `#ff4d4f` | 203 | `✗ FAILED` |
| info/workflow | `#4da3ff` | 75 | `WF` prefix |

Rules:

- Accent only the active focus, live work, key progress, and primary action.
- Color can never be the only state cue; retain glyph + word.
- Use one-cell glyphs only after `wcwidth` validation. Emoji such as `🛠` are not safe because terminals disagree about width. Prefer `◆`, `◎`, `⋔`, `▤`, `⧉`, `⚖` when Unicode width is known; offer ASCII aliases (`B`, `G`, `S`, `P`, `W`, `C`).
- Do not fake gradients with rainbow text except perhaps a two-color Ultra badge. The web itself reserves gradients for Ultra and the composer focus edge.
- Terminal typography is user-owned and monospace. Recreate hierarchy with weight, case, spacing, and color: bold sentence-case titles; small uppercase labels; dim monospaced metadata; normal-weight prose.
- Respect `NO_COLOR`, a `--color=auto|always|never` option, 16/256/truecolor detection, and an ASCII mode.

---

## 3. Proposed terminal information architecture

### 3.1 Core regions

Use five stable regions:

1. **Title bar (1 row):** SwarmCode mark, project/repository, conversation/page, mode, aggregate activity.
2. **Navigator (optional column/drawer):** projects, conversations, primary destinations.
3. **Main viewport:** transcript or current primary page.
4. **Inspector (optional column/full-screen overlay):** Thread, Agents, Timeline, Changes; context follows focused run.
5. **Action deck:** Needs you / live runs strip, composer or page actions, and a 1-row contextual key/status bar.

Do not create separate permanent “side chat” and “swarm pane” columns at ordinary widths. Put both into one Inspector with tabs:

`[Thread] [Agents] [Timeline] [Changes]`

At exceptionally wide sizes, permit **pinning** Thread beside one of Agents/Timeline/Changes. This retains every function while making the default comprehensible.

### 3.2 Focus model

The UI must always name the focused region in the bottom status line. Recommended cycle:

`Navigator → Main → Inspector → Composer`

- `Tab` / `Shift+Tab`: cycle regions, never cycle through every tiny button.
- Within a region: `j/k` or arrows move; `Enter` opens/activates; `Space` toggles; `h/l` collapse/expand where appropriate.
- `Esc`: close the topmost overlay; otherwise leave editor/composer focus for navigation without discarding its draft; otherwise collapse the current detail. Repeated Escape walks **layers**, never triggers two actions at once.
- Mouse is optional. Every mouse action must have a visible keyboard equivalent.

The web composer currently uses Shift+Tab to toggle Build/Plan (`assets/js/hooks.js:1017-1021`). In a TUI this conflicts with accessible reverse-focus navigation. Prefer `Alt+M`, `/mode`, or the mode control; optionally support Shift+Tab only behind a compatibility setting.

### 3.3 Global navigation

Recommended primary commands:

| Key | Action | Notes/fallback |
|---|---|---|
| `Ctrl+K` | universal switcher | chats, projects, pages, commands, runs; prefixes `/`, `@`, `#`, `>` |
| `Ctrl+N` | new conversation | preserve current draft in old conversation |
| `Ctrl+B` | toggle Navigator | mirrors current panel behavior |
| `Alt+I` | toggle Inspector | `/inspect` fallback |
| `Alt+1..4` | Thread / Agents / Timeline / Changes | ignored if Inspector hidden, but switches on open |
| `Ctrl+R` in composer | prompt history | matches current behavior |
| `?` outside text entry | contextual help/keymap | bottom sheet/full overlay |
| `g c/w/r/s/u/,` | Chats / Workflows / Research / Scheduled / Usage / Settings | two-key navigation-mode chord |
| `q` outside text entry | request quit | confirmation when work runs |
| `Ctrl+C` | conventional CLI interrupt/quit request | never silently stop all runs; confirm if anything active |

Do **not** require macOS Command-key sequences; terminal emulators generally intercept them. Do not rely on `Ctrl+,` or `Ctrl+Q`, which are inconsistently representable or may interact with flow control. Every shortcut must also be reachable through the switcher or slash command.

### 3.4 Universal switcher

The existing web product has separate sidebar search, slash palette, project chooser, research picker, and model flyouts. Terminal interaction benefits from one consistent overlay while keeping specialized pickers available.

Suggested query grammar:

- no prefix: fuzzy-search recent chats, projects, pages, and commands;
- `/`: slash commands and saved workflows;
- `@`: projects/repositories;
- `#`: conversations/research IDs/run IDs;
- `>`: actions (new, rename, fork, rewind, settings, theme, quit).

Results show icon/glyph, primary text, scope/project, status, and shortcut. Ranking should preserve the current rule: name prefix first, then word-boundary match; built-in command before saved workflow before custom command (`lib/swarm_code_web/components/chat.ex:106-173`).

### 3.5 Project/session picker

The Navigator should preserve the current ordering:

```text
CHATS                                      2 running
[ New conversation ]
[ Search…                           Ctrl+K ]

PINNED 2
  ● Parser rewrite                     aicore
  ? Release plan                       swarm-code

PROJECTS 3
▾ swarm-code                         main  ●
    > CLI clone                           2m
      Consensus polish                   1h
▸ aicore
▾ No project
      Scratch explanation                 3d

SCHEDULED 1
  ◷ Nightly tests                      in 4h
```

Requirements:

- “No project” is a first-class scope, not an error state; the web composer explicitly offers it as a sandbox (`chat.ex:3831-3909`).
- Show running/waiting/queued/failed/unread using glyph + word/accessible detail.
- Project rows expand/collapse and show branch/path in a secondary line when focused.
- Pin, rename, fork, delete, project edit, instructions/memory files, and Add project live in an action menu, never hover-only.
- Switching conversations preserves the old conversation's draft and scroll/fold state.

---

## 4. Textual wireframes

### 4.1 Wide workspace (recommended at ≥150 columns)

```text
┌ SC ─ swarm-code/main › CLI clone ─────────── [BUILD] ── ●3  ?1  $0.18 ┐
│ CHATS                 │ TRANSCRIPT                         │ INSPECTOR  │
│ [New] [Search]        │                                   │ Thread  A T C
│                       │ YOU · /swarm                      │ ● Lead     14s
│ PINNED                │ Build a CLI clone…                │ ├─✓ UX audit
│ ● CLI clone           │ ┌ ⋔ Swarm · RUNNING ─ 3/6 ─────┐ │ ├─● Packaging
│                       │ │ ▰▰▰▰▰▰▱▱  18 ops · 00:24     │ │ └─? TUI choice
│ PROJECTS              │ │ Working… inspect workspace…   │            │
│ ▾ swarm-code          │ └───────────────────────────────┘ │ [Open op]  │
│   > CLI clone         │                                   │            │
│     Older session     │ ASSISTANT                         │            │
│ ▸ aicore              │ I’ve mapped the application…▌    │            │
│                       │                                   │            │
│ SCHEDULED             │ ↓ 2 new messages — End to follow  │            │
├───────────────────────┼───────────────────────────────────┴────────────┤
│                       │ NEEDS YOU  ? TUI choice · 02:11 left            │
│                       │ [project: swarm-code] [live: ⋔3]                 │
│                       │ ┌ Message…                                     ┐ │
│                       │ │                                              │ │
│                       │ └ +  model:gpt-5.6·high  auto  BUILD       ↑ ┘ │
└ Ctrl+K switch · Tab regions · Alt+I inspector · ? help ────────────────┘
```

The title bar should not try to carry every current web header action. It carries identity and aggregate state; contextual actions appear in the bottom key line or `>` action menu.

### 4.2 Medium workspace (100–149 columns)

```text
┌ swarm-code/main › CLI clone ───────── [CONSENSUS R2/3] ●2 ?1 ┐
│ TRANSCRIPT                                                    │
│ ... full-width run cards and prose ...                       │
│                                                               │
│ [Inspector: Timeline]   ← overlay/drawer when Alt+I is pressed │
├───────────────────────────────────────────────────────────────┤
│ ? NEEDS YOU · Judge requests clarification                    │
│ [swarm-code] [gpt-5.6 high] [auto] [CONSENSUS ⚙]              │
│ Message…                                                 Send │
└ Ctrl+B chats · Ctrl+K switch · Alt+I inspect · ? help ───────┘
```

Navigator and Inspector are mutually exclusive drawers by default. Opening one must not destroy the other's selection or scroll position.

### 4.3 Narrow workspace (72–99 columns)

```text
┌ CLI clone ─ PLAN ─ ●1 ───────────────────────────────────────┐
│ YOU  Add dates to the task list                             │
│ ▤ Planner · DONE · 12 ops · 01:18                          │
│   Worked for 1m 18s  [open]                                │
│   The implementation plan is…                              │
│                                                             │
│ ▤ PLAN  [Approve] [Revise] [Decline]                        │
│                                                             │
│ ↓ latest                                                    │
├─────────────────────────────────────────────────────────────┤
│ project: swarm-code · model: gpt-5.6 high · mode: PLAN      │
│ Message…                                                    │
└ Ctrl+K switch · Alt+I details · ? help ─────────────────────┘
```

All secondary metadata moves behind `i`/Inspector. Never horizontally scroll the entire workspace.

### 4.4 Run card, collapsed and expanded

Collapsed:

```text
┌ /swarm  Build a release checker                              ┐
│ ⋔ SWARM  ● RUNNING   3/8 agents · 26 ops · 01:42       ?1  ▸│
│ ▰▰▰▰▰▱▱▱                                                     │
└───────────────────────────────────────────────────────────────┘
```

Expanded:

```text
┌ /swarm  Build a release checker                              ┐
│ ⋔ SWARM  ● RUNNING   3/8 agents · 26 ops · 01:42       ?1  ▾│
│ ▰▰▰▰▰▱▱▱                                                     │
│ ? Question · Which release channel?                          │
│   1 Stable (recommended)   2 Beta   3 Other…                 │
│                                                               │
│ 12:41 Lead       planning phases…                            │
│ 12:42 researcher ✓ inspected mix releases                    │
│ 12:42 builder    ● run_command mix test                      │
│ 12:43 reviewer   ✗ failing test · [error]                    │
│                                                               │
│ [Reply] [Steer] [Pause] [Stop] [Inspect]                     │
└───────────────────────────────────────────────────────────────┘
```

Run-card rules:

- Prompt wraps; it is not silently truncated. At rest it may clamp to two rows, with Expand.
- Status line never wraps. Lower-priority metadata progressively moves behind Details.
- Error, Needs you, consensus state, and unread survive every density.
- Expanded logs have their own vertical bound and `↓ latest`; they do not make one card consume the full conversation indefinitely. This mirrors the web's bounded live log (`chat.ex:2229-2241`).
- Follow-up and implementation turns render one level deep under a left rule; never duplicate them as top-level cards.

### 4.5 Activity/reasoning/tool display

Default compact row:

```text
  ● run_command  mix test test/swarm_code/...        8.4s
```

Expanded:

```text
  ▼ run_command · done · 8.4s
    $ mix test test/swarm_code/engine/consensus_test.exs
    14 tests, 0 failures
    [copy] [open inspector]
```

Reasoning:

```text
  ▸ Thinking · 2.1k chars
```

- Reasoning starts folded unless the user setting says otherwise, matching Settings (`settings_live.html.heex:689-703`).
- Streaming reasoning and final answer must be distinct buffers; finishing an answer must not reorder either.
- Tool arguments/results/errors must be lossless and scrollable, with structured fields before raw JSON.
- File operations show path, `+N -N`, and an inline or Inspector diff.
- Long command output is viewport-lazy but never discarded; the user can page/search/copy the exact full text.

### 4.6 Consensus at terminal densities

Full Docket (wide/normal main viewport):

```text
┌ ⚖ CONSENSUS · Planner gpt-5.6 ⇄ Judge deepseek-v4 · round 2/3 ┐
│ │ R1  PLAN  ✎ REVISE       4/5 checks · 00:42                 │
│ │     “Handle rollback before migration”                      │
│ ├ R2  PLAN  ● JUDGING      3/5 checked · 00:18                │
│ │     Judge: checking correctness…                            │
│ ├ S   SPEC  pending                                            │
│ └ I   IMPLEMENT  pending                                       │
└ Enter opens round · l expands · [ toggles plan/verdict ───────┘
```

Compact Ticker (Inspector/narrow):

```text
⚖ R1 revise › R2 judging…  [AO ✓] [KCM ·] [SEC ✓]   2/3
```

Pane/ledger representation:

```text
R1  ▣ planner “first plan”      │ ⚖ revise  4/5
R2  ▣ planner “rollback added”  │ ⚖ reading…
S   ▣ spec pending              │
I   ⚒ implementer pending       │
```

Do not attempt to reproduce the SVG balance scale in cells. Preserve its purpose — planner/judge sides, round outcomes, checks, current side, and inspectable ledger — with a two-column textual instrument. At narrow widths stack Judge below Planner. The web already changes Docket/Ticker/Bench by available surface, so this remains conceptually faithful.

### 4.7 Plan gate

```text
┌ ▤ PLAN COMPLETE ─────────────────────────────────────────────┐
│ [Approve…]  [Revise]  [Decline]                             │
└──────────────────────────────────────────────────────────────┘

Approve implementation with
> ✱ Assistant   one agent, full access, in this chat
  ⋔ Swarm       a Lead that fans work out to workers
```

After selection, keep the settled line (`↳ implemented by …`, `plan declined`, or `↻ plan revised`) permanently visible on the plan, as the current component does (`chat.ex:2653-2669`).

### 4.8 Deep research index

```text
┌ DEEP RESEARCH ─────────────────────────────────────────────────────┐
│ What do you want to know?                                         │
│ [                                                                  ]│
│                                                                    │
│ ( ) Fastest   1 round · 4 agents     median $0.08 · 2m             │
│ (●) Medium    2 rounds · 3 each      median $0.22 · 7m             │
│ ( ) High      3 rounds · 4 each      median $0.71 · 18m            │
│ ( ) Ultra     4 rounds · 10 each     median $3.10 · 39m            │
│                                                                    │
│ project: swarm-code · model: default+tiers · effort: high [Start] │
└────────────────────────────────────────────────────────────────────┘

FILTER [All] [Running 2] [Done 8] [Failed 1]      / search
● #18  TUI framework survey       medium  2×3  37%  $0.12  4m
✓ #17  macOS packaging options    high    3×4  23 src     1h
```

The Start screen must explicitly say the job continues in the background, mirroring `research_live.html.heex:159-165`.

### 4.9 Deep research detail

Wide:

```text
┌ Research #18 · TUI framework survey ───────────── ● RUNNING 43% ┐
│ TIMELINE                  │ REPORT / NOTES                       │
│ [Rounds Agents Sources]   │ 8 agents · 23 sources · $0.18 · 6m │
│ ● Round 1 done            │                                     │
│ ├ ✓ ecosystem             │ Current state: synthesizing round 2 │
│ ├ ✓ packaging             │                                     │
│ └ ✓ accessibility        │ ## Findings                         │
│ ● Round 2 running         │ ...markdown report stream...        │
│ ├ ● renderer survey      │                                     │
│ └ ◷ waiting              │ SOURCES                             │
└───────────────────────────┴─────────────────────────────────────┘
```

Narrow: timeline becomes an Inspector tab; main shows state/report/round notes/sources in document order. Provide actions Stop, Retry, Retry with model, Copy Markdown, Open/Download HTML, Continue in chat, Reveal directory.

### 4.10 Workflows

```text
┌ WORKFLOWS ─ [Runs] [Library] ───── filter: running/interrupted/all ┐
│ RUNS                         │ release-review                     │
│ ● review-changes  Hunt 4/12 │ [Pipeline Script Journal Result]  │
│ ! deploy-check    interrupted│                                    │
│ ✓ research        done      │ ● Phase 1 · Map · 3 agents         │
│                              │ ├✓ reader-1  12 ops · 8.1k        │
│                              │ ├● reader-2  run_command           │
│                              │ └✓ reader-3                        │
│                              │ ○ Phase 2 · Review · pending       │
│                              │ Log (8) ▸                          │
└──────────────────────────────┴────────────────────────────────────┘
```

Library detail needs scope, description, args, smoke/shape preview, source, Run, Edit, Duplicate, Delete, Copy name. Editing is a full-screen text editor region with Check/Save and diagnostics, not a tiny modal.

### 4.11 Scheduled, Usage, and Settings

Scheduled should use two layouts:

- wide: compact month grid left, selected-day task list right;
- narrow: agenda list by default, month grid as a tab. A 7-column calendar below ~84 cells is less useful than an agenda.

Usage should progressively collapse the table:

```text
USAGE · LAST 30 DAYS                 $18.42 · 42 runs · 11 chats
████████████████░░░░  61% of $30 monthly budget

Sep 01  swarm-code  CLI clone       gpt-5.6  swarm   84.2k  $0.82
Aug 31  aicore     parser review     deepseek chat    9.1k  $0.07
```

Settings should be a searchable master-detail list, not an 11-card scrolling page:

```text
SETTINGS
> General                 Chat model        gpt-5.6
  Deep research           Swarm model       deepseek-v4
  Appearance              Chat effort       high
  Providers & models      Swarm effort      max
  Pricing
  MCP servers             [Save defaults]
  Memory
  Storage
  Commands
  Limits
  Budget
```

Dirty values must survive asynchronous status/settings updates; this is an existing tested requirement (`lib/swarm_code_web/live/settings_live.ex:96-109`, settings focused tests around dirty forms in `test/swarm_code_web/live/settings_live_test.exs:201-270`).

---

## 5. Composer, attachments, queue, and command behavior

### 5.1 Composer layout

Use three layers, only when needed:

1. **context strip:** project, active goal, live runs/Needs you;
2. **editor:** target/command/research chips and multiline text;
3. **control strip:** attach, model/effort, approval, mode/settings, send/stop.

At narrow widths, control labels shorten but critical state never disappears:

```text
[swarm-code] [gpt-5.6:H] [A] [P]                         [↑]
```

Focused control or bottom help expands `A = Auto approval`, `P = Plan mode`. This mirrors the web's progressive label hiding at 640/480/380/300 px (`assets/css/app.css:2975-3004`) without making icon-only states mysterious.

### 5.2 Input keys and terminal compatibility

Recommended behavior:

- `Enter`: send/submit when the command palette/interview is not active.
- `Shift+Enter`: newline when the terminal's enhanced keyboard protocol distinguishes it.
- `Ctrl+O`: guaranteed newline fallback for legacy terminals.
- `Alt+Enter`: queue behind the currently running turn, matching current behavior (`assets/js/hooks.js:1052-1059`). Also expose `/queue` because some terminals remap Alt+Enter.
- `Ctrl+R`: prompt history; arrows select; Enter restores; Escape closes (`assets/js/hooks.js:1023-1050`).
- IME composition must never accidentally send.
- Backspace at draft start restores/removes command/goal chip; Escape does not silently remove a slash command. Reply/steer/revise target can be cleared explicitly and with Backspace on an empty draft, matching the current semantics (`assets/js/hooks.js:981-1015`).
- Draft, selection, editor scroll, chip state, and pinned height survive every async redraw and screen switch.

### 5.3 Slash palette

Palette rows should show:

```text
> /swarm <task>                 Start a swarm of agents
  /compact [focus]              Summarise context                built-in
  /review-changes [base=main]   Review workflow                  project · workflow
  /arch-review <args>           Architecture review             user
```

Arrows move, Tab/Enter pick, Escape closes; selection must not send. Custom/workflow scope remains visible. Selecting `/goal`, `/plan`, `/ultra`, or `/create-workflow` updates the one mode indicator because those commands own a mode; `/swarm`, `/compact`, `/review`, and `/workflow <name>` remain one-shot actions.

### 5.4 Attachments

The web accepts pasted/dropped PNG/JPEG/GIF/WebP, up to four, permits image-only messages, persists thumbnails, and reports unsupported/over-limit errors (`assets/js/hooks.js:1135-1179`; behavior at `test/swarm_code_web/live/attachments_live_test.exs:38-114`). Terminal design:

- `/attach path` and an Attach picker add files; pasted terminal image protocols are optional enhancement, not a baseline.
- Each pending image is a chip: `[shot.png · PNG · 1440×900 · 312 KB ×]`.
- Internal transcript shows name/dimensions/size and `[open]`; use Kitty/Sixel/iTerm inline preview only as an opt-in enhancement.
- Never encode a filename as plain prompt text when it is actually an image attachment.
- Preserve max-four and size/type validation messages.

### 5.5 Queue and targeting

- Queued messages show one chip/row each, in order, with Remove and Edit. Do not summarize several queued messages into only a count.
- Reply, Steer, and Revise are visually distinct target chips at the top of the editor.
- A plain message during another running turn starts a normal new turn; it does not implicitly steer. The explicit run-card action establishes the target.
- Needs-you question ownership follows the focused run/Inspector but remains reachable globally.

---

## 6. Async behavior and status bars

### 6.1 Async invariants

Every long-running activity — chat, swarm, goal, workflow, research, compaction, MCP connection/test, storage scan/cleanup — must:

- continue when the user changes page, conversation, or closes a detail view;
- update aggregate counts in the title bar and exact rows in Navigator/Activity Center;
- have a visible owner, state, elapsed time, and cancel/pause/resume action when supported;
- persist final output and terminal failure;
- never steal focus, reset a draft, move selection, or yank scroll;
- surface completion as a non-blocking event, not forced navigation.

The existing app explicitly says scheduled runs must not navigate the user and uses toasts (`lib/swarm_code_web/components/frame.ex:271-307`); research likewise says it continues off-page (`research_live.html.heex:159-165`).

### 6.2 Activity Center

Add an Activity Center reachable from the title bar or switcher:

```text
ACTIVITY
? CLI clone / swarm        waiting: TUI framework choice      02:11 left
● Research #18             round 2/3 · 5/8 agents             06:42
Ⅱ review-changes           paused · phase Review              12:09
✗ Nightly tests            failed · exit 1                    4h ago
```

Sort Needs you first, then running/paused, then recent failures/completions. This is the terminal-native replacement for rail badges + sidebar dots + run dock + Needs you strip + several toasts.

### 6.3 Top and bottom status

Top title bar, always:

`project/branch › conversation | MODE | ● running_count ? waiting_count | cost`

Bottom contextual bar, always:

- focus/selection identity;
- most relevant 3–5 key hints;
- connection/provider warning if present;
- detached-from-bottom count, if any.

Never animate the whole status line once a second. Update elapsed labels only where visible and only when their displayed value changes, following the web hook's efficiency behavior (`assets/js/hooks.js:185-249`).

### 6.4 Auto-follow

- Follow new transcript/activity only while at bottom.
- Wheel/key/page navigation detaches immediately.
- `End` or `G` rejoins; show `↓ N new` while detached.
- Sending one's own message rejoins the transcript once, unless reduced-motion/plain mode requests an immediate jump.
- Inspector and main viewport have independent follow states.
- Resizing recomputes layout but preserves logical top item and cursor, not just raw scroll offset.

---

## 7. Responsive behavior in terminal cells

Treat terminal columns/rows as capabilities, not CSS pixels. Suggested defaults, tunable after prototype measurements:

| Class | Size | Layout |
|---|---|---|
| XL | `≥170×34` | Navigator + Main + Inspector; optionally pin Thread plus one secondary inspector |
| Wide | `150–169×30` | Navigator + Main + one Inspector |
| Medium | `100–149×24` | Main + Navigator **or** Inspector drawer; composer full controls with shortened labels |
| Narrow | `72–99×20` | single main view; Navigator/Inspector full-height overlays; stacked consensus/research/settings |
| Small | `50–71×16` | survival layout: title, main, one-line live/needs strip, compact composer, status |
| Too small | `<50×14` | keep resize/quit/help usable; show required minimum and optional `--plain` mode |

Width rules:

- Main transcript never drops below 50 columns when another region is open.
- Navigator target width 24–32 columns; Inspector 38–56; sizes persist but clamp on resize.
- Below XL, Thread and Agents/Timeline/Changes are not separate columns.
- Tables collapse into key/value rows; calendar defaults to agenda; consensus plan/verdict stack; research timeline moves to Inspector; settings becomes single list/detail.
- Horizontal scrolling is permitted only inside code, diff, wide tables, and raw JSON — never for the whole screen.

Height rules:

- Composer auto-grows to at most 8 rows, consistent with current behavior (`assets/js/hooks.js:705-736`).
- Needs you gets at most two rows before becoming a count + Activity Center link.
- Expanded run log uses at most 40–50% of viewport height unless explicitly maximized.
- Overlays clamp to terminal height and scroll their bodies while keeping title/actions visible.

---

## 8. Keyboard and accessibility details

### 8.1 Recommended contextual keymap

#### Lists/tree/document

| Key | Action |
|---|---|
| `j/k`, arrows | next/previous row |
| `h/l` | collapse/expand |
| `Enter` | activate/open |
| `Space` | select/toggle without navigating |
| `g g` / `G` | first / last |
| `PageUp/PageDown` | page viewport |
| `/` | filter/search current region |
| `n/N` | next/previous match |
| `[` / `]` | previous/next user turn or round, depending region |
| `i` | inspect focused item |
| `a` | actions menu |

#### Run card

| Key | Action |
|---|---|
| `Enter`/`l` | expand |
| `r` | Reply; if failed, actions menu disambiguates Retry |
| `s` | Steer |
| `p` | Pause/Continue |
| `x` | Stop with confirmation |
| `t` | open Thread inspector |
| `o` | open operation/selected detail |
| `m` | mark read |

#### Question/approval

| Key | Action |
|---|---|
| `1..9` | choose option |
| arrows | move option |
| `Space` | toggle multi-select |
| `Enter` | Next/Submit |
| `b` | Back |
| `s` | Skip (explicit) |
| `a/d/A` | Approve / Deny / Always allow, when approval is focused |

The web currently maps Escape to Skip for an interview (`assets/js/hooks.js:3215-3219`). In terminal convention Escape should close/cancel the current interaction layer; make Skip explicit to prevent accidental irreversible answers.

### 8.2 Modal/overlay rules

The current modal contract is good and should carry over: one shared component model; title/description/body/footer; focus moves inside; background inert; Tab traps; Escape closes; opener regains focus (`lib/swarm_code_web/components/core_components.ex:668-779`; focus implementation `assets/js/hooks.js:3491-3579`). TUI equivalent:

- dim background if supported, but do not depend on blur;
- visible border/title and `Dialog 1/1` semantics in plain mode;
- first focus should usually be the safest action;
- Tab/Shift+Tab cycles dialog regions/actions;
- Escape closes once and restores focus/scroll;
- destructive confirmation must default to Cancel. Do **not** automatically make bare Enter destructive merely to match the web's optional `enter_primary` behavior;
- nested popovers are replaced by one drill-down overlay with breadcrumb, not overlapping boxes.

### 8.3 Accessibility and degraded modes

- `--plain`: line-oriented, append-only output with explicit prompts; suitable for screen readers, pipes, logs, and terminals without alternate-screen support.
- `--no-alt-screen`: keep output in scrollback while still accepting commands.
- `--ascii`: replace box drawing and specialized symbols.
- `--reduced-motion` and persisted setting: no spinner frames, pulsing, scrolling animation, or color cycling. The web honors both OS preference and explicit setting (`assets/css/app.css:1787-1797`, `assets/css/app.css:2314-2325`).
- `NO_COLOR` plus state words/glyphs.
- Never encode meaning only in bold/dim because some terminals ignore them.
- Ensure focus is visible under every theme and no-color mode.
- Use `wcwidth` and grapheme-safe truncation; never split a combining sequence.
- Announce async state changes in a bounded event log/plain line; optional terminal bell only for Needs you and only when enabled.

---

## 9. Where visual parity conflicts with terminal conventions

| Web/desktop behavior | Conflict | Terminal-native resolution |
|---|---|---|
| rail + sidebar + chat + side chat + pane | too many simultaneous scroll/focus regions | stable Main plus optional Navigator and unified Inspector; extra split only at XL |
| rounded floating cards, shadows, hatch, blur | character cells cannot reproduce depth cleanly | spacing, hairline box borders, surface background, limited accent |
| Inter + JetBrains Mono hierarchy | terminal font is user-controlled and monospace | weight/case/spacing hierarchy; no font assumptions |
| hover-only row actions/tooltips/minimap previews | keyboard and many terminals have no hover | explicit Actions menu, focus help line, jump list |
| pixel drag resizing | mouse may not exist; cell resize differs | keyboard size presets and ±2/±8-cell nudge; optional mouse drag |
| animated progress/glows/gradients | flicker, accessibility, remote latency | static segmented bars; sparse spinner; reduced-motion default over slow links |
| Shift+Tab toggles Build/Plan | conflicts with reverse focus | Tab navigation; `Alt+M` or `/mode`; optional compatibility binding |
| Escape skips interview | Escape conventionally cancels/closes | explicit `s`/Skip button; Escape leaves layer without answering |
| Enter as dangerous confirm | terminal muscle memory can trigger it while navigating | safe default focus; explicit destructive mnemonic/second confirmation |
| Cmd shortcuts | terminal emulator owns Command | Ctrl/Alt/navigation chords + command fallbacks |
| Shift+Enter newline | indistinguishable in legacy terminal protocols | support enhanced protocol plus reliable `Ctrl+O` fallback |
| image thumbnails | most terminals cannot render portable images | metadata chips + external open; optional Kitty/Sixel/iTerm preview |
| consensus SVG balance | ASCII art would be noisy and fragile | textual two-sided ledger preserving data/state |
| HTML-designed research report | terminal cannot reproduce art direction | readable Markdown internally; keep Open/Download HTML action |
| 7-column calendar at every width | illegible on narrow terminals | agenda default below width threshold |
| browser-native links/clipboard | terminal integration varies | OSC 8 links when supported, copy action/OSC 52 opt-in, always show URL/path |

Functional parity is more important than ornamental parity. The CLI should feel unmistakably like the same product because the same nouns, colors, states, hierarchy, and relationships are present.

---

## 10. Acceptance criteria for a faithful TUI clone

### A. Shell and navigation

- [ ] Every primary destination (Chats, Scheduled, Workflows, Research, Usage, Settings) is keyboard-reachable in at most three actions and through the universal switcher.
- [ ] Navigator shows pinned, project-grouped, no-project, and scheduled rows with exact running/waiting/queued/failed/unread states.
- [ ] Project/no-project context and conversation title are visible in the workspace title/composer context.
- [ ] New, rename, fork, pin, delete, rewind, project edit/add, and open instructions/memory are available without a mouse or hover.
- [ ] Switching destination/conversation never loses an unsent draft, selection, expanded state, or scroll anchor.
- [ ] Running jobs continue and their aggregate counts remain visible across navigation.

### B. Transcript and async work

- [ ] Transcript keeps chronological order across messages, chat/swarm/goal/compact/workflow runs, and nested follow-ups.
- [ ] A launching user prompt and its run appear as one card; nested implementation/follow-up runs are not duplicated at top level.
- [ ] Run cards expose kind, exact state, elapsed, progress, operations, tokens/cost, unread, and Needs you at appropriate density.
- [ ] Streaming final text, reasoning, tools, errors, file changes, and workflow/consensus state update independently without full-screen flicker.
- [ ] User scroll detaches auto-follow; new count appears; End/G rejoins; async patches never yank the viewport.
- [ ] Pause, Continue, Stop, Resume, Retry, Reply, Steer, mark read, and inspect are present only when semantically valid.
- [ ] Full logs/results remain lossless and searchable even if rendering is virtualized.

### C. Composer and commands

- [ ] Slash palette contains all built-ins, saved workflows, and custom commands with current ranking and scope.
- [ ] Build, Plan, Goal, Ultra, Workflow, Consensus are mutually exclusive and visibly named at all widths.
- [ ] Swarm, Compact, Review, and Deep Research remain actions/artifacts rather than silently becoming persistent modes.
- [ ] Chat and swarm models/efforts, approval mode, consensus Planner/Judge/Implementer settings, rounds, and checks are editable.
- [ ] Reply/Steer/Revise target is visible and removable; a plain message does not implicitly steer another run.
- [ ] Prompt history, queued messages, active goal bars, notices, and project/research attachments are preserved.
- [ ] Enter/send, newline fallback, queue fallback, IME protection, and legacy-terminal key behavior are tested.
- [ ] Up to four supported images can be attached, removed, sent without text, persisted, and opened; errors are explicit.

### D. Needs you, plan, consensus

- [ ] Every pending question/approval appears in Activity Center and workspace strip regardless of current page.
- [ ] Question flow supports numbered options, recommended default, multi-select, Other, Back, Skip, Next/Submit, and deadline/urgency where applicable.
- [ ] Approvals support Approve, Deny, Always allow and clearly name run/tool/scope.
- [ ] Finished Plan runs offer Approve→Assistant/Swarm, Revise, Decline, then retain settled state and linked implementation.
- [ ] Consensus shows Planner/Judge(/Implementer), exact round `n/N`, check outcomes, plan, verdict/findings, spec/implementation stages, current activity, and controls.
- [ ] Consensus adapts Docket→Ticker/ledger by width without losing any inspectable data.

### E. Workflows, research, scheduled, usage, settings

- [ ] Workflow Runs/Library, Pipeline/Script/Journal/Result, phase/agent budget, logs/gates/results, source editor/check, shape preview, launch, duplicate/save/delete all work keyboard-only.
- [ ] Deep Research launch supports question, four exact levels, project, model/effort; jobs run independently; list filters/search/pin/status work.
- [ ] Research detail exposes timeline by rounds/agents/sources, stats/state, report/TOC, notes, rated sources, reporter agents, Stop/Retry/Copy/Open/Download/Continue/Reveal.
- [ ] Scheduled supports month and agenda, filters, run now/pause/edit/delete, and complete task fields including workflow args and schedule types.
- [ ] Usage preserves budget/spend and every table field, collapsing to readable rows at narrow width.
- [ ] All eleven Settings sections, validation, dirty-form preservation, save feedback, secrets masking, provider/MCP/search status, storage cleanup progress, and memory/commands editors are represented.

### F. Visual, responsive, accessible

- [ ] Carbon dark is recognizable from semantic palette, sparse orange, surface hierarchy, uppercase labels, and segmented progress; other four themes × light/dark map consistently.
- [ ] Status is always glyph + word + optional color; No Color and ASCII modes remain fully legible.
- [ ] Snapshots pass at XL/Wide/Medium/Narrow/Small sizes and 16/256/truecolor/no-color modes.
- [ ] No whole-screen horizontal scroll; code/diff/raw tables are the only horizontal scrollers.
- [ ] Focus is visible and stable; overlays trap focus, Escape closes once, and focus returns to opener.
- [ ] Reduced motion removes spinners/pulses/animated scrolling while retaining state.
- [ ] `--plain`, `--no-alt-screen`, `--ascii`, `NO_COLOR`, resize, tmux/screen, SSH latency, macOS Terminal/iTerm/Kitty, and common Linux terminals are smoke-tested.
- [ ] Unicode width, combining text, CJK, emoji in user/model output, long paths/model names, and terminals as small as `50×16` do not corrupt layout.

### G. Performance/quality bar

- [ ] Keystroke-to-paint latency remains imperceptible while several streams update.
- [ ] Only changed rows/regions redraw; cursor never flashes or jumps due to background events.
- [ ] Long transcripts, tool logs, timelines, sources, and settings lists are viewport-windowed without dropping data.
- [ ] Hidden tabs/regions do not continually animate or recompute.
- [ ] Resize preserves focused logical item and draft, then repaints once.

---

## 11. Priority order for implementation

1. **Shell + state model:** title bar, Navigator, Main, unified Inspector, Action deck, universal switcher, responsive breakpoints.
2. **Chat vertical slice:** transcript, run cards, streaming, tools/reasoning, composer, project/conversation switch, model/approval/mode, slash commands, queue.
3. **Needs you + lifecycle:** questions, approvals, Activity Center, pause/continue/stop/resume/retry, side Thread inspector.
4. **Swarm observability:** Agents tree/list, Timeline, Changes/diff, follow/focus rules.
5. **Plan/Consensus:** plan gate and adaptive consensus Docket/Ticker/ledger.
6. **Workflow/Ultra/Compact:** pipeline, library/editor/launcher, compact card/history transition.
7. **Research:** launch/index/detail/report/actions.
8. **Scheduled/Usage/Settings:** complete parity and degraded layouts.
9. **Accessibility/compatibility hardening:** plain/ascii/no-color, terminal matrix, screen-reader and remote-session passes.

The first milestone should prove that **three concurrent runs can stream while the user navigates, edits an unsent multiline draft, opens Inspector, answers a waiting question, and returns without any state or scroll loss**. That scenario captures the product's core promise better than a static screenshot.

---

## 12. Source index

Most important implementation sources inspected:

- Shell/navigation: `lib/swarm_code_web/components/frame.ex:141-417`, `frame.ex:458-953`, `frame.ex:1681-1736`
- Workspace composition/modals: `lib/swarm_code_web/live/workspace_live/workspace.html.heex:29-378`, `workspace.html.heex:396-548`
- Transcript/run cards/composer: `lib/swarm_code_web/components/chat.ex:221-429`, `chat.ex:1614-2418`, `chat.ex:3389-3552`, `chat.ex:3743-4417`, `chat.ex:4710-5352`
- Side chat: `lib/swarm_code_web/components/side_chat.ex:69-255`, `side_chat.ex:259-755`, `side_chat.ex:829-1032`
- Agents/Timeline/Changes: `lib/swarm_code_web/components/swarm_pane.ex:46-415`, `swarm_pane.ex:2272-3259`
- Consensus: `lib/swarm_code_web/components/consensus_components.ex:1-434`, `consensus_components.ex:510-1159`, `consensus_components.ex:1163-2303`
- Workflows: `lib/swarm_code_web/live/workflows_live.html.heex:66-439`, `lib/swarm_code_web/components/workflow_pipeline.ex:1-450`
- Research: `lib/swarm_code_web/live/research_live.html.heex:39-743`, `lib/swarm_code/research/levels.ex:1-141`
- Scheduled/Usage/Settings: `lib/swarm_code_web/live/scheduled_live.html.heex:21-595`, `lib/swarm_code_web/live/history_live.html.heex:23-126`, `lib/swarm_code_web/live/settings_live.ex:32-109`
- Themes/responsiveness: `assets/css/themes.css:16-292`, `assets/css/app.css:63-450`, `assets/css/app.css:2327-3004`, `assets/css/app.css:6148-6750`, `assets/css/app.css:7724-8221`
- Keyboard/focus/scroll: `assets/js/hooks.js:607-1213`, `assets/js/hooks.js:1248-1377`, `assets/js/hooks.js:1638-1718`, `assets/js/hooks.js:2915-3068`, `assets/js/hooks.js:3198-3337`, `assets/js/hooks.js:3491-3579`, `assets/js/hooks.js:4027-4105`
- Specs: `.specs/04_redesign_spec.md:20-95`, `.specs/38_mode_selector_spec.md:13-173`, `.specs/45_pass39_efforts_implementer_pause_timeline_spec.md:293-683`, `.specs/50_pass44_compact_commands_planner_spec.md:89-157`, `.specs/50_pass44_compact_commands_planner_spec.md:1601-1695`

