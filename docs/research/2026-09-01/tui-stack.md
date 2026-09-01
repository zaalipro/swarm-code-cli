# TUI stack research for SwarmCode CLI

**Research date:** 2026-09-01 (Asia/Tbilisi)  
**Scope:** read-only technology assessment; no repository was initialized or edited.  
**Target:** a full-screen, visually polished SwarmCode terminal client on Ubuntu and macOS, with the Elixir/OTP core and ERTS bundled into a one-command install.

## Decision in one paragraph

Use **ExRatatui 0.13.x, pinned exactly, behind a SwarmCode-owned semantic presentation boundary**, and use its **reducer runtime** only for terminal/UI state and UI-only subscriptions. Keep all durable state and long-running work in SwarmCode's Elixir supervisors; deliver typed, scoped engine events to the TUI process and render only the visible window. ExRatatui is the best current balance: it exposes Ratatui 0.30/Crossterm 0.29 through an OTP-supervised API, has the exact primitives this product needs (row-scrolled heterogeneous chat lists, Markdown/code, textarea, slash commands, popup, tables, gauges, focus, mouse, paste, resize and true color), a headless backend, precompiled macOS/Linux NIFs, and a tested Burrito path. It avoids inventing and maintaining a custom Elixir↔Rust sidecar protocol. This recommendation is **conditional on a native-safety, input, terminal-restoration and four-target packaging spike** because ExRatatui is young, pre-1.0 and in-process native code. If it fails the gate, retain the semantic boundary and switch the adapter to **TermUI 1.0** (native-free terminal core) or, specifically when crash isolation is the blocker, a supervised **Ratatui Port sidecar**. Always ship a line-oriented `--plain` presentation; no full-screen TUI is screen-reader accessible merely because it has keyboard focus.

## What “TUI clone” can honestly mean

The current SwarmCode surface is a dense Carbon-themed application, not a simple prompt. Local specs and implementation show:

- a project/sidebar column, central transcript/composer, swarm/agent pane and side chat;
- Markdown, code and diffs, run cards, streamed operations and tool state;
- goal, swarm, workflow, plan, deep-research, ultra and consensus modes;
- consensus proposal/judge/stage/round ledgers and a timeline inspector;
- research sources/report/rounds and a following rail;
- menus, popovers, filters, command palette behavior, modals, resize, pause/resume and keyboard state;
- the dark Carbon tokens `#141414` background, `#1e1e1e` cards, `#ff6a1a` accent, semantic green/yellow/red/blue, plus mode colors. See local `.specs/04_redesign_spec.md`, `.specs/37_consensus_spec.md` through `.specs/50_pass44_compact_commands_planner_spec.md`, `assets/css/themes.css`, and `assets/css/app.css`.

A terminal can preserve the **information architecture, interaction model, hierarchy, modes, live status, color language and card vocabulary**. It cannot pixel-clone Inter/SF typography, arbitrary radii, shadows, gradients, SVG illustrations, CSS hover geometry or sub-cell responsive spacing. Define acceptance as a **behavioral TUI clone with a faithful Carbon terminal theme**, not a screenshot-identical port. At 80 columns, responsive behavior must collapse panes into tabs/drawers; at 120–160 columns the three-pane cockpit is achievable.

## Current evidence snapshot

All status below was verified from package metadata, source, release notes and default-branch history on 2026-09-01.

| Candidate | Verified current status | Consequence |
|---|---|---|
| **ExRatatui** | Hex **0.13.0**, 2026-08-13; 26 releases since 2026-02-19; default branch active 2026-09-01; 112 GitHub stars; Ratatui 0.30/Crossterm 0.29/Rustler 0.38; CI badge passing. [Hex](https://hex.pm/packages/ex_ratatui), [source](https://github.com/mcass19/ex_ratatui), [0.13 changelog](https://github.com/mcass19/ex_ratatui/blob/main/CHANGELOG.md#0130---2026-08-13) | Best product fit, but young, one primary maintainer, pre-1.0 and a NIF. Pin and wrap it. |
| **TermUI** | Hex **1.0.0** inserted 2026-08-31; release dated 2026-08-28; active repo (~200 stars), passing release CI; 55k Elixir source lines and 65k test lines in the inspected tag. [Hex](https://hex.pm/packages/term_ui), [source](https://github.com/agentjido/term_ui), [1.0 changelog](https://github.com/agentjido/term_ui/blob/main/CHANGELOG.md) | Strongest current full-screen, mostly-Elixir fallback; its 1.0 integration still has material limitations described below. |
| **Ratatui + Crossterm** | Ratatui **0.30.2**, 2026-06-19, about 22.4k stars and 47.6m crate downloads; active commits through 2026-08-30. Crossterm **0.29.0** published 2025-04-05 and active source through 2026-08. [Ratatui](https://github.com/ratatui/ratatui), [crate](https://crates.io/crates/ratatui), [Crossterm](https://github.com/crossterm-rs/crossterm) | By far the most proven renderer/input ecosystem here. A custom bridge, not Ratatui itself, is the risk. |
| **Owl** | Hex **0.13.1**, 2026-06-04; active and widely downloaded. Its own README now explicitly says full-screen apps should use TermUI/Ratatouille/ExNcurses. [Hex](https://hex.pm/packages/owl), [source](https://github.com/fuelen/owl) | Excellent installer/progress/`--plain` toolkit; not the full-screen application framework. |
| **Ratatouille** | Hex **0.5.1**, 2020-03-25; default-branch last commit 2021-10-17. [Hex](https://hex.pm/packages/ratatouille), [source](https://github.com/ndreynolds/ratatouille) | Legacy only; do not start a new flagship client on it. |
| **ExTermbox** | Hex **1.0.2**, 2020-03-25; default-branch last commit 2022-02-14. It binds original termbox, whose maintainer marked it unmaintained on 2020-08-25. [Hex](https://hex.pm/packages/ex_termbox), [source](https://github.com/ndreynolds/ex_termbox), [termbox notice](https://github.com/nsf/termbox#important) | Low-level, stale NIF/global terminal ownership, no widget system; reject. |
| **Drafter** | Hex **0.3.2**, 2026-08-04; active but one-maintainer/low-adoption; 30+ widgets, animations, headless test and remote TUI. [Hex](https://hex.pm/packages/drafter), [source](https://github.com/jaman/drafter) | Impressive watch candidate, but a larger custom stack and less proven packaging/ecosystem than the recommendation. |
| **Raxol** | Hex **2.6.1**, 2026-08-07; active and feature-rich, based on termbox2. [Hex](https://hex.pm/packages/raxol), [source](https://github.com/DROOdotFOO/raxol) | Technically capable but far too broad/invasive for a renderer dependency: the inspected root had ~189k Elixir source lines, 107 locked deps and overlapping agent/LiveView/database subsystems. |
| **Breeze/Termite** | Breeze **0.5.1**, 2026-08-27; LiveView-like `~H`, active, Termite-backed. Termite **0.4.4**, 2026-07-30, NIF-free and dependency-free. [Breeze](https://hex.pm/packages/breeze), [Termite](https://hex.pm/packages/termite) | Attractive pure-Elixir direction, but still explicitly evolving and currently less complete for this cockpit than ExRatatui/TermUI. |

The original `termbox2` successor is active and adds 32-bit color and extended grapheme clusters, but it remains a low-level terminal I/O library without widgets/layout. [termbox2 README](https://github.com/termbox/termbox2)

## Comparative assessment

### 1. ExRatatui 0.13 — recommended, with a hard spike gate

ExRatatui is the important “better maintained option” missing from the legacy Elixir TUI shortlist. It is not a separate Rust process: Elixir widget structs cross a Rustler NIF boundary, Ratatui lays out and paints them, and Crossterm polls events on a DirtyIo scheduler. The app runs as an OTP-supervised `Server` and supports either LiveView-style callbacks or an Elm/reducer runtime. [Architecture](https://github.com/mcass19/ex_ratatui/blob/main/guides/internals/architecture.md), [reducer runtime](https://github.com/mcass19/ex_ratatui/blob/main/guides/runtimes/reducer_runtime.md)

**Why it fits SwarmCode unusually well**

- The current 25-widget set includes `WidgetList` with row-based scrolling for variable-height chat, Markdown with highlighted code, multiline `Textarea`, `SlashCommands`, `Popup`, `Throbber`, `Table`, `List`, `Tabs`, `Scrollbar`, gauges/charts and custom pure-Elixir widgets. Version 0.5.1 explicitly added the chat/list/Markdown/textarea/slash combination; later releases added focus, transports and packaging. [Changelog](https://github.com/mcass19/ex_ratatui/blob/main/CHANGELOG.md)
- Styles support named, indexed-256 and RGB colors, rich spans and semantic theme slots. This is enough to translate the Carbon tokens and mode colors.
- Events cover key press/repeat/release, mouse, resize, focus and local bracketed paste. Mouse is opt-in, which preserves normal text selection by default. [Transport matrix](https://github.com/mcass19/ex_ratatui/blob/main/guides/transports/transports.md)
- It already solved a subtle BEAM/Crossterm race: the BEAM `prim_tty` reader and Crossterm previously competed for keystrokes, especially on macOS; 0.11.1 parks the BEAM reader during local sessions. This is a warning about how nontrivial a home-grown sidecar/input layer is, and positive evidence that the bridge is being exercised in real terminals. [0.11.1 note](https://github.com/mcass19/ex_ratatui/blob/main/CHANGELOG.md#0111---2026-06-24)
- Unicode uses Ratatui plus `unicode-width 0.2`; the repository has integration fixtures for CJK, combining marks, ZWJ emoji, wrapping and input editing. Terminal width is never perfectly portable (see “Unicode reality”), but this is substantially stronger than Ratatouille or TermUI's hand-maintained ranges.
- `test_mode`, injected events, a headless Ratatui backend and `CellSession` allow text and exact per-cell/style assertions. [Testing guide](https://github.com/mcass19/ex_ratatui/blob/main/guides/internals/testing.md)
- The runtime accepts PubSub/mailbox messages and has structured async commands/subscriptions. More importantly, SwarmCode can avoid framework-owned business work entirely: core supervisors send typed deltas to the UI, and the UI only renders them.
- Version 0.13 documents and regression-tests Burrito packaging. Precompiled NIFs cover Linux x86_64/aarch64 and macOS x86_64/aarch64 (plus other targets); no Rust toolchain is needed by the end user. Its size-tuned native artifact is about 4.6 MB uncompressed / 2.14 MB compressed on x86_64 Linux according to the current changelog. [Packaging guide](https://github.com/mcass19/ex_ratatui/blob/main/guides/packaging/packaging_with_burrito.md)

**Risks that prevent an unconditional choice**

- A NIF shares the BEAM address space. Rustler catches ordinary Rust panics, but a native memory error, FFI defect or indefinitely blocked native call can crash or impair the whole VM; a supervisor cannot isolate that the way an OS Port can.
- The project is only six months old, pre-1.0, fast-moving and primarily maintained by one person. Its 26 releases demonstrate responsiveness, but also API churn. Exact pinning plus a narrow internal adapter is mandatory.
- Every rendered widget tree is encoded and decoded across the NIF boundary. A million-row transcript is explicitly called out as an anti-pattern in its performance guide. SwarmCode must send only visible rows and bounded metadata, never full history. [Performance guide](https://github.com/mcass19/ex_ratatui/blob/main/guides/internals/performance.md)
- Local paste/focus support is better than its SSH/session transports; this CLI needs local first, so that is acceptable, but the presentation contract must not assume parity if remote TUI is later added.
- Alternate-screen full-screen mode still has accessibility and native scrollback costs.

### 2. TermUI 1.0 — best mostly-Elixir full-screen fallback

TermUI uses a TEA `init/update/view` root, an ANSI terminal layer, raw/TTY/SSH backends, ETS double buffers, differential rendering, a constraint layout solver, RGB/256/16/monochrome fallback and a large widget set. It advertises 60 FPS and includes text input, viewport, split pane, tree, command palette, dialogs, Markdown, log viewer and tests. It supports local Linux/macOS; raw character-at-a-time mode requires OTP 28, which matches SwarmCode's current `.tool-versions` (`Elixir 1.18.4-otp-28`). [README](https://github.com/agentjido/term_ui), [terminal guide](https://github.com/agentjido/term_ui/blob/main/guides/user/08-terminal.md)

It has three major advantages over a custom sidecar: no IPC contract, direct mailbox/OTP integration and a terminal renderer implemented where the rest of the app lives. Its core terminal layer is NIF-free. Note, however, that its required Markdown dependency MDEx uses a precompiled native library, so the complete dependency graph is not literally native-free.

The inspected 1.0 documentation is refreshingly explicit about its limits:

- the integrated runtime has one root; process-oriented component routing modules exist but are not wired into that runtime;
- bracketed-paste and focus sequences are parsed but not automatically enabled in 1.0;
- automatic resize in local TTY mode depends on newer OTP signal support; raw mode requires OTP 28;
- there is no generic function/HTTP command and interval IDs are not publicly cancellable; app-owned supervised work is required;
- its current test harness contract differs from current stateful widget callbacks, and terminal-free runtime tests skip backend/input integration;
- the display-width implementation uses hand-coded ranges, not a current Unicode width database. ZWJ/emoji/variation behavior therefore needs much more aggressive product testing.

Those limitations are manageable because SwarmCode already has owned async processes, but the composer is mission-critical and Unicode/input defects are a release blocker. TermUI is the right fallback if the ExRatatui NIF or native-artifact policy fails, not the first blind commitment.

### 3. A custom Rust Ratatui sidecar controlled by Elixir

A well-designed sidecar is technically excellent. Ratatui provides constraint layouts, rich spans, RGB/indexed color, a large widget ecosystem and a first-class `TestBackend`; Crossterm provides raw/alternate screen, mouse press/release/drag, key modifiers and enhancements, resize, focus and bracketed paste on Unix/macOS. Ratatui's active ecosystem also includes textarea, tree, overlay, Markdown and animation/effects libraries. [Ratatui backends](https://ratatui.rs/concepts/backends/), [Crossterm events](https://docs.rs/crossterm/0.29.0/crossterm/event/enum.Event.html), [TestBackend](https://docs.rs/ratatui/0.30.2/ratatui/backend/struct.TestBackend.html)

**Advantages**

- Strong OS crash boundary. Elixir monitors a Port, can terminate/restart it and the renderer cannot corrupt BEAM memory.
- Ratatui and Crossterm have orders of magnitude more production exposure than any Elixir-native full-screen framework.
- Rust owns frame timing, cell diffing and terminal input; Elixir owns domain state and asynchronous work. A bounded framed protocol can preserve backpressure.
- Rust golden/snapshot tests and Elixir protocol tests make renderer behavior deterministic.

**Costs and traps**

- Ratatui is a renderer, not an application protocol. SwarmCode would own a versioned scene/event protocol, reconnection, initial snapshot, patch ordering, stale-generation handling, flow control, capability negotiation and crash recovery forever.
- Do not send the whole transcript at 60 FPS. The protocol would need semantic, stable-ID patches and a visible-window model; that is a significant subsystem, not glue.
- An Erlang Port normally pipes the child process's stdin/stdout for IPC. A TUI also wants the controlling tty. The sidecar must either open `/dev/tty` separately and arrange compatible Crossterm event polling, use a dedicated Unix socket/extra FD for IPC, or invert ownership so Rust is the parent and BEAM is the child. This needs a real prototype on both Darwin and Linux; it is easy to create competing readers or broken restoration.
- Four renderer builds (Linux/macOS × x86_64/aarch64), musl/glibc choices, executable extraction permissions, checksums, nested signing/notarization and protocol compatibility add release complexity.
- Two languages and two state machines slow UI iteration. The bridge code initially has zero production history, even though Ratatui itself is mature.

**Conclusion:** use a sidecar when native crash isolation is a non-negotiable requirement or when the ExRatatui NIF fails the native-safety gate. Do not pay this cost merely for access to Ratatui; ExRatatui already supplies that access and the relevant chat widgets.

If the fallback is taken, use an Elixir `RendererPort` GenServer that exclusively owns `Port.open`, monitor, restart/backoff, protocol sequence, terminal generation and shutdown. Use a length-framed binary protocol (`packet: 4` or a local socket), protocol version + feature negotiation, bounded outgoing latest-scene coalescing, stable action IDs, stderr-only renderer logs, and a full-snapshot resync after restart. Never put secrets or raw provider credentials in scene messages.

### 4. Ratatouille

Ratatouille's declarative DSL and TEA callbacks were attractive in 2019. It supports rows/columns, panels, labels, tables, trees, charts, overlays and viewports; ExTermbox supplies key/click/resize events. It is nevertheless unsuitable for this new product:

- release and default-branch maintenance are years stale;
- original termbox is explicitly unmaintained;
- its default output mode is termbox `normal`; 256 color is opt-in and true color is absent;
- its text renderer splits graphemes, then deliberately keeps only the first UTF-8 code point (`# TODO: Figure out how to handle trailing codepoints`) and advances each grapheme by one cell, so combining/ZWJ and wide-character layout are not trustworthy;
- async `Runtime.Command` uses detached `Task.start`, with source TODOs for failures, timeout and zombie tasks—directly contrary to SwarmCode ownership rules;
- terminal state is a singleton around an old C NIF and tests are much narrower than the modern options.

Ratatouille is useful as prior art for a declarative Elixir API, not as a dependency.

### 5. Owl

Owl 0.13.1 is healthy and useful. It has tagged styling, true color, OSC 8 links, optional `ucwidth`, tables/boxes, prompts, concurrent progress/spinners and `LiveScreen`, including a virtual I/O device that makes output testable. Its model remains a normal top-to-bottom CLI with line input and dynamically rewritten blocks. It does not supply a full-screen layout/event/focus system, raw key handling, mouse routing or pane navigation; the maintainers now say so directly in the README.

Use Owl in two narrow places:

1. the install/bootstrap command and diagnostics; and
2. the accessible/non-interactive `--plain` renderer, using ordinary chronological output rather than `LiveScreen` cursor rewrites when a screen reader is active.

Do not attempt to stretch `LiveScreen` into the SwarmCode cockpit.

### 6. ExTermbox / low-level termbox

ExTermbox wraps termbox with NIFs and a C polling thread, and exposes cells, clear/present, input/output modes and keyboard/mouse/resize events. It has no layout, widgets, focus, input editor, Markdown, test backend or application architecture. Its binding and upstream are stale; its global native terminal state has worse fault isolation than Rustler resources or a Port. Even replacing original termbox with active termbox2 would still leave almost the entire UI framework to build.

Reject it for a product UI. It is only appropriate for a deliberately tiny internal tool or as implementation detail inside a maintained higher-level framework.

### 7. Direct ANSI/VT plus terminfo

Direct ANSI offers total control and can be NIF-free on OTP 28, but “no framework” is not “no cost.” SwarmCode would need to own:

- exact raw/cooked/alternate-screen lifecycle and signal restoration;
- a streaming escape parser with partial-sequence timeouts for keys, modifiers, mouse, focus and paste;
- SIGWINCH/size handling;
- capability detection, terminfo lookup and conservative fallback;
- Unicode grapheme segmentation and terminal-specific column width;
- cells, clipping, diffing, cursor placement, layout, focus, widgets, editor, Markdown, modals and tests.

Terminfo is a database of terminal capabilities and control strings, not a widget framework. [terminfo(5), ncurses 6.6, 2025-08-16](https://invisible-island.net/ncurses/man/terminfo.5.html). Xterm's current control-sequence reference alone illustrates the size and statefulness of the protocol surface. [xterm control sequences, patch #411, 2026-08-23](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html)

Direct ANSI is appropriate for the simple `--plain`/bootstrap path and emergency terminal restoration. Reimplementing TermUI/Crossterm for the full client has no product advantage.

## Cross-cutting capability conclusions

### Unicode is a terminal contract, not just UTF-8

Correct UTF-8 decoding does not answer how many cells a grapheme occupies. CJK, combining marks, emoji presentation selectors, regional flags and ZWJ sequences vary between width libraries, fonts and emulators. Unicode's own East Asian Width annex warns that the property is not an off-the-shelf solution for modern terminal emulators. [Unicode UAX #11 v17.0, 2025-07-24](https://www.unicode.org/reports/tr11/)

Practical order:

1. ExRatatui/Ratatui (`unicode-width`, active terminal ecosystem) plus product fixtures;
2. Owl with optional `ucwidth` for line mode;
3. TermUI only after expanding its width/grapheme tests or replacing its hand-coded width module;
4. never Ratatouille for multilingual composer text.

No library eliminates terminal variance. Test composed/decomposed accents, Georgian, Arabic/Hebrew, CJK, skin-tone emoji, flags, family/occupation ZWJ, VS15/VS16 and ambiguous-width symbols across the supported terminal matrix.

### Input, mouse and resize

- ExRatatui local transport: key/mouse/resize/paste, focus opt-in; strong fit.
- Rust sidecar: Crossterm has all required events, but tty ownership is custom work.
- TermUI raw backend: key/mouse/resize and paste parser; paste/focus enablement must be integrated and verified.
- Ratatouille/ExTermbox: basic key/mouse/resize, mouse/output modes need configuration and event semantics are dated.
- Owl: line input, not full-screen event routing.

Mouse must remain optional. Capturing it interferes with native terminal selection; every action needs a keyboard equivalent.

### True color and fidelity

ExRatatui/Ratatui and TermUI can emit 24-bit RGB. Owl can do true color in line mode. Ratatouille/classic termbox cannot. Always provide a 256-color, 16-color and monochrome theme; terminals, tmux, SSH and user preference can invalidate true-color assumptions. Never encode state only in color—retain glyph and text status (`RUNNING`, `WAITING`, `DONE`, etc.). Honor [`NO_COLOR`](https://no-color.org/) and `TERM=dumb`.

Use rounded box-drawing, half blocks, Braille sparingly, semantic colors and whitespace to reproduce Carbon. Avoid terminal image protocols for core UI: they reduce portability, copying and accessibility, even though ExRatatui supports them.

### Animation

The desired activity bars, spinners, live agents and progress are feasible in ExRatatui subscriptions, TermUI one-shot timers or a Ratatui tick loop. Render event-driven, not constantly:

- no animation timer when nothing visible is moving;
- cap normal motion around 15–30 FPS; 60 FPS is unnecessary for text;
- coalesce engine deltas into the next frame without dropping durable content;
- offer `--motion=reduce|off`; in reduced mode use static glyph/status changes;
- pause hidden-pane animation while still applying state.

### Accessibility

A full-screen cell UI has no semantic accessibility tree. A 2025 Ratatui accessibility discussion describes current terminal UIs as essentially unusable for screen readers and explores, but does not provide, an AccessKit solution. [Ratatui discussion #2190](https://github.com/ratatui/ratatui/discussions/2190)

Required product response:

- `swarm-code --plain` (and automatic fallback when stdout is not a TTY or `TERM=dumb`): append-only chronological text, stable headings, no cursor movement, no animations, slash commands through stdin;
- `--no-color`/`NO_COLOR`, high-contrast theme, reduced motion;
- complete keyboard operation, explicit focus labels/help and no color-only meaning;
- user-selectable alternate-screen/full-screen behavior where feasible;
- VoiceOver on macOS and Orca on Ubuntu acceptance for **plain mode**. Do not claim the full TUI itself is screen-reader accessible.

### Testability

Best renderer primitives are ExRatatui/Ratatui `TestBackend`/`CellSession`. TermUI has a useful buffer/event simulator but its own 1.0 guide notes gaps between the harness and current widget contract. Owl's virtual device is excellent for line output. Direct ANSI requires building all of this.

Test at three levels:

1. **Pure UI reducer**: state + normalized event → state/effect; no terminal.
2. **Golden cells**: canonical 80×24, 120×40 and 160×50 frames, including exact styles, focus and cursor; narrow/responsive layouts.
3. **Real PTY/terminal**: input streams, paste, mouse, resize storms, SIGINT/SIGTERM, crash cleanup, tmux and target terminal emulators on native macOS/Ubuntu runners.

A text-only buffer assertion is insufficient: it misses background bleed, wide-cell continuation, focus cursor and semantic-color regressions.

## Recommended architecture

```text
SwarmCodeCli.Application (Elixir release; one durable core)
├── existing domain supervisors
│   ├── Repo / projects / conversations / workflows / research
│   └── RunSupervisor → RunSup → RunServer → agents/operations
├── Cli.UiSupervisor
│   └── Cli.Tui.Host.ExRatatui  (one local terminal owner)
│       ├── reducer state: focus, scroll, tabs, modal, draft, selection,
│       │                  terminal capabilities, visible generations
│       ├── typed subscriptions to scoped domain events
│       └── render(state, frame) → Cli.Ui.Scene → ExRatatui adapter
└── Cli.PlainPresenter (selected by --plain/non-TTY; append-only)
```

### Boundaries

**`Cli.Ui.Scene` is SwarmCode-owned.** Define stable semantic primitives—pane, text, rich text, Markdown, list/window, run card, consensus stage, progress, composer, popup—and stable action IDs. Do not allow ExRatatui widget structs, key names or ResourceArcs into the domain/core. A thin adapter maps the scene to pinned ExRatatui types. This makes TermUI or a sidecar a replaceable presentation adapter rather than a rewrite.

**Normalize input immediately.** Renderer events become typed intents such as `{:composer_insert, text}`, `{:activate, action_id}`, `{:scroll, region_id, delta}`, `{:resize, cols, rows}`. Include conversation/project generation where relevant; ignore stale results exactly as the web UI does.

**The TUI never performs domain work.** A key event asks `SwarmCode.Engine`, `SwarmCode.Workflows`, `SwarmCode.Research` or another explicit owner to act. The UI records a request reference and renders pending state. Results arrive through typed PubSub/monitor messages. Framework `Command.async` is reserved for UI-local, bounded work; the existing app supervisors own network, Git, database, MCP and commands.

**Render a window, not history.** Keep message/run IDs, offsets and derived visible lines in UI state. Page older rows on demand; cache width/theme-specific Markdown layouts by collision-safe key and byte bound. ExRatatui's `WidgetList` row offset is a good final primitive, not permission to encode all messages every frame.

**Coalesce only redraws.** Apply every ordered domain delta, mark the view dirty, and render at most once per frame interval. Never coalesce or discard assistant text/tool payloads themselves. UI-only animation ticks are cancellable and exist only while visible animation is active.

**Own shutdown.** The ExRatatui host is the single terminal owner. It must restore cursor, paste/focus/mouse modes, alternate screen and tty settings on normal exit, callback error, `SIGINT` and `SIGTERM`; compare `stty -g` before/after in tests. Never write logs to TUI stdout—use a file/stderr capture. `SIGKILL` cannot be repaired by any in-process library; document `reset`/`stty sane` recovery.

### Theme/layout mapping

- True-color Carbon: `bg #141414`, elevated/card `#191919/#1e1e1e`, borders `#2a2a2a`, text `#f3f2f0`, muted `#8c8b88`, accent `#ff6a1a` plus existing kind colors.
- 256/16/mono maps are explicit assets tested alongside true color.
- ≥140 columns: sidebar / transcript / agents. 100–139: collapsible sidebar + transcript / agents. <100: one primary pane plus tab/drawer switcher. <60: compact plain-like screen with composer and one list.
- Modals overlay and trap focus; Esc closes once and restores focus. Status includes text/glyph/color. Composer owns the real terminal cursor and preserves grapheme selection/paste.

## Packaging impact

Use **Burrito 1.6.x** to produce one self-extracting executable per OS/architecture with ERTS bundled. Burrito 1.6.0 was published 2026-07-24 and targets macOS/Linux without target runtime dependencies; macOS still needs signing/notarization for a polished download. [Burrito Hex](https://hex.pm/packages/burrito), [source](https://github.com/burrito-elixir/burrito)

For ExRatatui:

- build four artifacts: Darwin arm64/x86_64 and Linux arm64/x86_64;
- use the musl ExRatatui artifact for Burrito Linux; 0.12 fixed the former `libgcc_s` relocation issue, but keep the documented verification step;
- ensure only the target NIF variant lands in each payload;
- sign/notarize the macOS wrapper and verify the embedded native library policy;
- publish SHA-256 manifest/signature and a release manifest recording app, OTP, ExRatatui, NIF ABI and renderer versions;
- the one-line installer detects `uname -s`/`uname -m`, downloads the exact artifact, verifies it, and atomically installs to a user-writable bin directory. “One command” should not mean an unverified `curl | sh` that executes before checksum verification.

A custom Rust sidecar adds a separately executable renderer per target, extraction permissions and another binary to sign. Ratatouille/ExTermbox/Drafter need C compilation per target. TermUI's terminal core is simplest, although Markdown still introduces MDEx native artifacts. Owl/plain is simplest of all.

Burrito bundles ERTS and BEAM bytecode—the runtime required to run the Elixir application. It does not, by itself, promise a full developer `mix`/Elixir compiler toolchain inside the executable; that is a separate product requirement from the TUI choice.

## Prototype plan and kill criteria

Build a throwaway but production-shaped ExRatatui spike before committing application code. It should render four representative scenes: normal streaming chat + composer, swarm/agent pane, expanded consensus card/ledger, and research report/sources. Exercise real domain-event bursts with fake providers.

### Pass criteria

1. **Input integrity**
   - no lost/duplicated bytes during sustained typing and repeated bracketed pastes on native macOS and Ubuntu;
   - correct composed/decomposed Unicode, CJK, RTL text storage, Georgian, emoji/ZWJ, Option/Alt keys, Shift+Tab and terminal key repeat;
   - multiline composer cursor/selection remains correct after resize and paste;
   - mouse disabled by default; when enabled, click/drag/scroll work and keyboard equivalents remain.

2. **Terminal lifecycle**
   - 1,000 automated normal/error/`SIGINT`/`SIGTERM` start-stop cycles restore exact `stty -g`, cursor and main screen;
   - no hang on non-TTY stdin; automatic `--plain` or a clear error;
   - tmux, SSH-launched shell, Ghostty/iTerm2/Terminal.app on macOS and GNOME Terminal/Kitty on Ubuntu do not corrupt input or output.

3. **Native safety**
   - property/fuzz tests over malformed/zero/huge rectangles, constraints, widget data and event streams produce no BEAM crash, native abort or unbounded DirtyIo stall;
   - source-built sanitizer runs for the Rust boundary are clean;
   - every NIF call used by the client has bounded input, explicit error handling and an observed latency distribution.

4. **Performance/resource**
   - representative 120×40 visible scene renders in ≤16 ms p95 on baseline hardware; input-to-painted-frame ≤50 ms p95 while engine events stream;
   - idle CPU ≤2% of one core after warm-up; no unconditional 60 FPS redraw;
   - a resize/event storm remains responsive and bounded; 30-minute soak has no monotonic mailbox, ETS, native-resource or heap growth;
   - a 10k-message conversation consumes UI memory proportional to visible/page cache, not full rendered history.

5. **Visual/behavioral fidelity**
   - no overlap or unreachable action at 80×24, 120×40, 160×50;
   - Carbon true-color, 256, 16 and monochrome goldens pass;
   - transcript scrolling, streaming follow/pin behavior, modal focus, slash commands, pause/stop/resume, consensus and research flows work keyboard-only.

6. **Packaging**
   - all four release artifacts boot on clean target VMs/machines with no Erlang, Elixir, Rust, compiler or system NIF library installed;
   - checksum verification, writable-cache behavior, cold/warm launch, upgrade and uninstall are proven;
   - signed/notarized macOS artifacts do not trigger unexplained Gatekeeper failures.

7. **Accessibility fallback**
   - every workflow required for an unattended or screen-reader user works in `--plain` mode;
   - VoiceOver and Orca can read chronological output and prompts; `NO_COLOR` and motion-off are respected.

### Kill/switch triggers

Switch away from ExRatatui rather than rationalizing any of these:

- one reproducible BEAM crash, native memory-safety failure or non-cancellable NIF hang from valid bounded UI input;
- any supported target needs a compiler or undocumented system shared library at end-user install/runtime;
- lost keystrokes/paste or terminal corruption remains after one focused fix cycle;
- the composer cannot correctly edit the Unicode fixture set;
- p95 frame/input targets fail after visible-windowing and redraw coalescing (do not “fix” by dropping content);
- a required scene needs invasive changes to domain state because renderer types leaked past the adapter;
- the framework cannot render/test exact styles, focus and cursor needed for the representative screens;
- upstream/API churn cannot be contained by the adapter and exact version pin.

### Fallback choice after a kill

- **NIF/native policy, packaging or BEAM-safety failure, but pure-Elixir rendering passes:** implement the `Cli.Ui.Scene` adapter in **TermUI 1.0**, first replacing/validating its Unicode-width and paste/focus integration.
- **NIF isolation is the only failure and Ratatui's rendering/input proof remains strong:** implement the supervised **Ratatui Port sidecar**. Reuse the same scene/actions; do not move domain state into Rust.
- **Full-screen accessibility/non-TTY environment:** select **plain presenter** (optionally Owl-formatted) automatically. This is a permanent supported surface, not an error screen.

## Bottom line

- **Adopt for the spike:** ExRatatui 0.13.x (exact pin) + Ratatui/Crossterm, behind a SwarmCode-owned scene/event adapter.
- **Keep:** Owl or simple ANSI for installer/diagnostics/plain mode.
- **Fallback:** TermUI 1.0 for mostly-Elixir full screen; Ratatui Port sidecar when OS-process isolation is mandatory.
- **Do not adopt:** Ratatouille, original ExTermbox, or a from-scratch ANSI framework for this product.
- **Watch, do not couple the core to yet:** Drafter, Breeze and modular Raxol terminal packages.

The decisive architectural point is not merely the renderer. It is keeping terminal presentation disposable while the Elixir engine remains the single durable, supervised source of truth.

## Sources

Accessed 2026-09-01 unless a publication/release date is stated above.

- ExRatatui: [repository](https://github.com/mcass19/ex_ratatui), [Hex](https://hex.pm/packages/ex_ratatui), [architecture](https://github.com/mcass19/ex_ratatui/blob/main/guides/internals/architecture.md), [testing](https://github.com/mcass19/ex_ratatui/blob/main/guides/internals/testing.md), [performance](https://github.com/mcass19/ex_ratatui/blob/main/guides/internals/performance.md), [packaging](https://github.com/mcass19/ex_ratatui/blob/main/guides/packaging/packaging_with_burrito.md), [changelog](https://github.com/mcass19/ex_ratatui/blob/main/CHANGELOG.md).
- TermUI: [repository](https://github.com/agentjido/term_ui), [Hex](https://hex.pm/packages/term_ui), [1.0 terminal guide](https://github.com/agentjido/term_ui/blob/main/guides/user/08-terminal.md), [commands](https://github.com/agentjido/term_ui/blob/main/guides/user/09-commands.md), [architecture](https://github.com/agentjido/term_ui/blob/main/guides/developer/01-architecture-overview.md), [testing](https://github.com/agentjido/term_ui/blob/main/guides/developer/09-testing-framework.md).
- Ratatui: [repository](https://github.com/ratatui/ratatui), [crate](https://crates.io/crates/ratatui), [0.30.2 docs](https://docs.rs/ratatui/0.30.2/ratatui/), [backends](https://ratatui.rs/concepts/backends/), [snapshot testing](https://ratatui.rs/recipes/testing/snapshots/).
- Crossterm: [repository](https://github.com/crossterm-rs/crossterm), [crate](https://crates.io/crates/crossterm), [0.29 events](https://docs.rs/crossterm/0.29.0/crossterm/event/enum.Event.html).
- Ratatouille / ExTermbox / termbox: [Ratatouille](https://github.com/ndreynolds/ratatouille), [Ratatouille Hex](https://hex.pm/packages/ratatouille), [ExTermbox](https://github.com/ndreynolds/ex_termbox), [ExTermbox Hex](https://hex.pm/packages/ex_termbox), [original termbox maintenance notice](https://github.com/nsf/termbox#important), [active termbox2](https://github.com/termbox/termbox2).
- Owl: [repository](https://github.com/fuelen/owl), [Hex](https://hex.pm/packages/owl).
- Other current Elixir frameworks: [Drafter](https://github.com/jaman/drafter), [Breeze](https://github.com/Gazler/breeze), [Termite](https://github.com/Gazler/termite), [Raxol](https://github.com/DROOdotFOO/raxol).
- Packaging: [Burrito](https://github.com/burrito-elixir/burrito), [Burrito Hex](https://hex.pm/packages/burrito).
- Terminal standards/correctness: [terminfo(5)](https://invisible-island.net/ncurses/man/terminfo.5.html), [xterm control sequences](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html), [Unicode UAX #11](https://www.unicode.org/reports/tr11/), [NO_COLOR](https://no-color.org/), [Ratatui accessibility discussion #2190](https://github.com/ratatui/ratatui/discussions/2190).
