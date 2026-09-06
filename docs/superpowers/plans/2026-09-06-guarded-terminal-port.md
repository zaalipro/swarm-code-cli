# Guarded terminal Port implementation plan

> Use superpowers:subagent-driven-development for the independent component work
> and scoped review; continue within the authorized CLI checkout.

**Goal:** run the existing interactive workspace through a bounded native terminal
Port, then evaluate it against the candidate gates.
**Architecture:** pure Rust byte parser and wire decoder, exact cell writer,
external restoration guard, Elixir terminal owner and fixed synthetic demo.
**Tech stack:** Rust1.97.1, pinned Elixir1.18.4/OTP28.4.2, ratatui-core0.1.2 and
crossterm0.29.0 commands only after source review, ExUnit and task-owned PTYs.
**Spec:** `docs/superpowers/specs/2026-09-06-guarded-terminal-port-design.md`.

## Global constraints

- Modify only swarm-code-cli. No desktop/canonical-data/global-toolchain writes.
- No ExRatatui, NIF, stock Crossterm event reader, DSR input reader, renderer type
  in neutral UI state, or executable/native download at runtime.
- Paint limits remain500columns,200rows,100000cells; preserve declared widths.
- Input fragments<=4096bytes; paste<=262144bytes, enforced while consuming input.
- One terminal resource owner and serialized restoration guard, one frame/event
  in flight, fixed read buffers, no unbounded channel or output queue.
- Native builds/evidence do not authorize candidate adoption or full parity.
- Existing plain demo and all production application boundaries stay verified.

## Task1: Pure bounded input parser

Files: `native/terminal_port/{Cargo.toml,Cargo.lock,src/lib.rs,src/input.rs}`,
`native/terminal_port/tests/input.rs`, and `scripts/dev/check_terminal_port.sh`.
Interfaces: `InputParser::new`, `advance(&[u8])->Step`, `expire_escape`, `finish`,
`retained_bytes`/`retained_capacity` expose only size diagnostics. Closed Event,
Key, Phase, Modifiers and Rejection values map to the existing UI.Input contract.

- [x] Create a std-only library manifest, Rust1.97.1, edition2024, no native IO.
  Build artifacts go under repository `_build/terminal-port`, never tracked.
- [x] Write parser tests before code. For each split of `a界ESC[A`, append chunks
  through advance and require text a, text界, Up in order with exact consumption.
  A lone Escape has no event until expire_escape, then exactly Escape.
- [x] Test paste at262144bytes accepted once;262145 rejected once and no payload
  remains; every split of the terminator and false ESC[201 prefixes is exact.
  Feed a long overflow remainder plus terminator+`x`; receive only rejection thenx.
- [x] Test malformed UTF-8 without losing following ASCII/Unicode, control/Alt
  keys, CSI/SS3 keys, supported CSI-u phase/modifiers, unknown control strings,
  64-byte CSI overflow recovery, EOF,10000orderedkeys and100pastes.
- [x] Run RED, implement bounded state transitions, run GREEN, format and review.
  Allocation assertions use retained capacity and overflow state; tests must not
  merely assert that the emitted event is small after unbounded capture.

## Task2: Credit-controlled wire and exact cell output

Progress: Draw-v1 codec, control/event records, credit state machine and exact-cell
writer are implemented. Ratatui core and commands-only Crossterm are pinned with
events disabled; 58 locked crate records and 108 license texts are verified offline.
Exact body layouts are in `docs/implementation/terminal-port-wire-v1.md`.

Files: Rust wire/frame/output modules and Elixir
`ui/renderer/ratatui_port/{wire,frame}.ex`, cross-language fixture corpus.
Consumes: validated Paint.Plan and parser Event. Produces: versioned transport
bytes, bounded decode steps, exact positioned terminal output and paint acks.

- [x] Specify exact closed record byte layouts, packet limits, cursor/style enums,
  invalid-record closure and one-credit state machine before implementing them.
- [x] Add independently decoded cross-language fixtures, truncated/oversized
  headers, bad UTF-8/control glyphs, row-crossing widths and palette overflow.
- [x] Pin core/commands dependencies with events disabled; verify actual feature
  tree and record licenses/provenance. Use explicit cursor moves per glyph and
  clear old complete spans; do not rely on ForcedWidth's omitted trailing clears.
- [x] Compare output to exact grids across both width policies, wide overwrite,
  palette modes, cursor visibility/shapes, and frame revision/ack correlation.

## Task3: Restoration guard and real PTY execution

Files: native guard/tty/main modules, task-owned Python PTY harness/tests.
Consumes: versioned protocol; produces ready/input/paint-ack/restored records.

- [x] Write PTY tests that snapshot termios; test normal shutdown and injected
  initialization failure before implementing lifecycle. No-alt avoids entering
  alternate screen; painting there does not preserve old main-screen content.
- [x] Open the explicit terminal fd, snapshot modes, create guarded writer
  ownership and bounded poll loop. BEAM launch uses verified inherited tty
  descriptors and separate protocol fd3/fd4; there is no unverified tty fallback.
- [x] Test parent EOF, renderer failure, INT/TERM/HUP, resize, suspend/resume,
  no-alt and alternate-screen; verify exact restoration and child termination.
- [x] Capture actual cell output/input bytes and resource bounds. Record local
  platform evidence without marking absent native targets as passed.

## Task4: Interactive CLI integration and candidate evaluation

Files: Elixir RatatuiPort adapter/terminal owner, fixed demo Mix task and tests;
renderer decision/locked audit updates scoped to the new candidate.

- [x] Test two-phase binding, stale revision, credit ack, terminal failure and
  shutdown against the existing SessionRuntime before adding the owner.
- [x] Compose the existing Fake.Source/SessionRuntime into an interactive terminal
  demo; keyboard navigation, composer, questions, controls and detach must work.
- [x] Run the real command in task-owned PTYs; verify unchanged plain demo,
  process/application boundaries, no canonical IO, exact restoration and no leaks.
- [ ] Continue the candidate's native input/frame/lifecycle/performance and
  supported-target campaign. Emit incomplete evidence for unavailable targets;
  never change the decision to adopt from local checks alone.
- [x] Update README/audit, run full precommit and production compile. Final seed
  832090 passed 789 tests + 5 properties; native 44 Rust + 14 PTY, live demo 8 PTY,
  then 3 focused live checks after the final lifecycle/message changes. All scoped
  reviews approved; ego-lite task space and local server closed.
- [x] Commit the reviewed local implementation checkpoint with explicit files.
- [ ] Continue original daemon/provider/persistence/parity work. Candidate adoption,
  complete native campaign and supported-target release artifacts remain open
  independently of this local implementation checkpoint.
