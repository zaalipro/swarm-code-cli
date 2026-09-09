# Approved TUI redesign implementation plan

**Goal:** Implement the user's approved visual companion direction in the native terminal client.

**Spec:** `.superpowers/brainstorm/89632-1788946213/content/selected-direction-v3.html`; approval recorded in the companion's `state/events`.

**Architecture:** Keep the typed service, reducer, terminal transport and cell scene. Improve the pure projectors and shared painting geometry. Mode summaries use facts already supplied by the service; unavailable progress must be stated rather than invented.

## Constraints

- Work only in `/Users/zaali/dev/swarm-code-cli`; preserve existing uncommitted work.
- Keep every slash command and its typed dispatch behavior.
- Retain keyboard operation, small terminal layouts, monochrome/ASCII modes, safe text, clipping and exact cursor positioning.
- Browser checks use Ego Lite, close the owned space afterward, and never clear sessions or cookies.
- Continue under existing approval; no further design approval required.

## Tasks

- [x] Recover approved design, run the saved-session PTY test, resolve stale empty-state assertion and generated release audit artifact.
- [x] Shell: visibly separate composer and docks, provide product title and feature navigation, use coherent blue/cyan palette, show context-sensitive keys. Keep geometry and cursor calculation shared; verify exact painted actions and all sizes.
- [x] Modes: Build live stream; Plan checklist; Goal sidecard; Ultra pipeline; Workflow library entry; Consensus comparison. Also preserve useful research/swarm presentations. Extract a focused mode projector and use actual transcript/run/agent facts. Verify no fabricated completion or cross-conversation leakage.
- [x] Verification: CLI suite, formatting, compile with warnings as errors, real saved/live/demo PTYs, visual capture review. Resolve regressions.
- [x] Document startup and keys, record implementation evidence, close owned visual companion server/browser space.

## Execution notes

The shell and mode projectors can be implemented independently. Shell owns `projector/shell.ex`, `projector/composer.ex`, `projector/status.ex`, theme and cell geometry. Mode work owns `projector/workspace.ex`, `projector/inspector.ex`, and a new mode module. Shared interface remains `project(state, rect, class)` returning semantic blocks. Mode work must measure all additional chrome using the existing Metrics path.

Ruling: continue in the existing checkout to preserve the authorized in-progress implementation. Do not reset, stash, or commit unrelated work.
