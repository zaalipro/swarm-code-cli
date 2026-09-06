# Renderer-neutral cell paint plan work breakdown

> **For agentic workers:** use superpowers:subagent-driven-development or superpowers:executing-plans. Review each task before proceeding.

**Status:** implementation design and task boundaries. Expand each task into its exact RED tests and code plan before dispatch; this document does not establish implementation completion.

**Goal:** produce an inspectable cell representation of current Scenes and passive SVG previews for visual review, advancing the eventual desktop-style terminal client.

**Architecture:** Paint is a pure Scene-to-Plan conversion. Bounded canvas/text/block modules share measurements with Projector; SVG and the fixed contributor command consume Plan outside that pure boundary. The candidate Port and terminal owner remain later work.

**Tech stack:** current Elixir/OTP, existing Unicode width and Carbon Theme, ExUnit/StreamData, SVG with no browser dependencies.

**Spec:** `docs/superpowers/specs/2026-09-06-cell-paint-plan-design.md`.

## Global constraints

- Work only in `/Users/zaali/dev/swarm-code-cli`; never modify the desktop checkout or user data.
- Preserve Scene, source permissions, opaque Action IDs, logical editor state and the plain demo.
- No renderer/native dependency, raw terminal, terminal input, OS signal handler, database or provider execution in this slice.
- Paint limits: 500 columns, 200 rows, 100,000 cells, 4 MiB input text, 4,096 structural nodes/action IDs, depth 32, 64 regions, 4,096 palette entries, 32 MiB Plan term.
- Use the Scene's existing narrow/wide policy. Never split a grapheme or leave an orphan continuation.
- XML output is passive and escaped. ASCII changes trusted chrome only. Previews are synthetic cell evidence, not native acceptance frames.
- Browser verification uses a task-owned ego-lite space; close only that space, never browser sessions/cookies.

## Task 1: Bounded Plan and canvas

**Files:** `ui/paint.ex`, `ui/paint/{plan,cell,options,budget,canvas}.ex`; `test/swarm_code_cli/ui/paint/canvas_test.exs` and `budget_test.exs`.

**Interfaces:** `Paint.build(Scene.t(), Options.t())`; `Plan.cell(plan, x, y)`; `Plan.validate(plan)`; `Canvas.new(size, blank_style)`; `Canvas.put(canvas, x, y, glyph, width, style_index)`; `Canvas.fill(canvas, rect, style_index)`; `Canvas.finish(canvas)`.

- [ ] Add exact-grid RED tests before implementation. A 4x1 blank canvas receiving `界` at column 1 produces space, a width-2 lead, continuation to column 1, space. Overwrite column 2 with `x`; both old glyph cells clear, then column 2 contains `x`. A width-2 glyph at column 3 must not create a half glyph or write outside the row.
- [ ] Add preallocation RED tests for 501x1, 1x201, invalid dimensions, 33 nested display levels, 4,097 nodes, 4 MiB+1 text and forged SafeText. Test the admitted boundary independently from the rejected boundary.
- [ ] Implement closed structs/options/errors and bounded preflight traversal before `Scene.validate/1`. Use a persistent array while painting; finalize once to a row-major tuple. Validate the complete span/continuation/palette relationship and maximum external term size.
- [ ] Run the focused canvas/budget tests and a property asserting each emitted continuation resolves to a fitting same-row lead after arbitrary bounded put/fill operations. Review and commit.

The central cell invariant test is:

```elixir
assert {:glyph, "界", 2, 0} = Plan.cell(plan, 1, 0)
assert {:continuation, 1} = Plan.cell(plan, 2, 0)
assert :ok = Plan.validate(plan)
```

## Task 2: Shared styled text and measurements

**Files:** `ui/paint/{text,style,metrics}.ex`; `test/swarm_code_cli/ui/paint/text_test.exs` and `style_test.exs`.

**Interfaces:** `Text.lines(spans, width, policy, max_rows)` returns bounded lines of styled grapheme runs; `Metrics.height(block, width, options, max_rows)` returns its clipped cell height; `Style.resolve(style, inherited, mode)` returns a palette entry or typed rejection.

- [ ] Add RED cases for LF/CRLF/blank lines, CJK, Georgian, Arabic logical order, combining marks, ZWJ emoji and ambiguous symbols under both policies. Use existing Width vectors for expected widths, including Arabic contextual ligatures that are not additive across graphemes; verify actual occupied cells, not only joined strings.
- [ ] Test a RichText grapheme crossing a span boundary. Segment the logical text once while retaining style ownership for each resulting cluster; use the first contributing style, so style boundaries cannot split a grapheme or alter width.
- [ ] Implement wrapping shared by measuring and painting. Emit trusted style prefixes once, preserve explicit colors/modifiers over inherited defaults, reject colors unsupported by the requested mode, and never duplicate a prefix during wrapping.
- [ ] Run focused tests. Require a multiline styled example's measured height to equal its painted row count at exact-edge widths. Review and commit.

## Task 3: Exhaustive Scene block painting

**Files:** `ui/paint/{blocks,scene,markdown}.ex`; `test/swarm_code_cli/ui/paint/blocks_test.exs`, `scene_test.exs`.

**Interfaces:** `Blocks.paint(block, canvas, rect, context)` and `Scene.paint(scene, options)` return Plan data plus bounded diagnostics. They accept only the closed Scene union.

- [ ] Add one complete fixture test for each of the sixteen blocks in the spec's mapping table, plus composition tests for nested RunCard/AgentList/ActionDeck and an opaque dialog.
- [ ] Implement text/rich text/code and the readable Markdown subset, preserving unsupported syntax literally. Then implement the closed container/table/progress/composer mappings from the spec; keep RunCard to one title/status boundary.
- [ ] Paint in region order, then overlay. Preserve Scene cursor coordinates and derive focused region/control IDs. Build action rectangles from visible painted glyphs; discard occluded portions and disable background actions beneath a modal. Record completely clipped action IDs as diagnostics.
- [ ] Test that a dialog crossing a background wide glyph clears the whole old span, that repeated paint is deterministic, that background modal actions are absent, and that unknown blocks return a typed error.
- [ ] Run canvas/text/block/scene tests, review and commit.

## Task 4: Reconcile actual projector geometry

**Files:** relevant `ui/projector/{shell,workspace,inspector,composer,dialog}.ex`, `ui/scroll_metrics.ex`; `test/swarm_code_cli/ui/paint/projector_test.exs`.

**Interfaces:** Projector keeps `project(State) -> {Scene, table}`. Shared Paint.Metrics supplies content heights without depending on State/Projector, preventing a dependency cycle.

- [ ] Build current four representative fixtures at 80x24, 120x40, 160x50, plus seven layout boundaries, narrow dialogs, and the too-small state. Capture failing assertions for overwritten content, shifted caret or completely clipped required actions.
- [ ] Replace guessed chrome row counts with shared measurements where they differ. Do not add label rows to one-row strips or the composer. Reserve the existing Navigator label row; keep one run boundary and the desktop Navigator/Main/Inspector hierarchy.
- [ ] Assert all current actionable table IDs have visible rectangles or an intentional size/modal exclusion. For tiny scenes assert no mutation rectangles. Assert composer cursor lands at the cell corresponding to the existing editor prefix measurement.
- [ ] Rerun existing projector, reducer-scroll, keymap and three-run tests along with Paint integration tests. Review changes to behavior as well as snapshots; commit.

## Task 5: Passive previews and visual review

**Files:** `ui/paint/svg.ex`, `demo/cells.ex`, `lib/mix/tasks/swarm_code.demo.cells.ex`; `test/swarm_code_cli/ui/paint/svg_test.exs`, `test/swarm_code_cli/demo/cells_test.exs`; README command documentation.

**Interfaces:** `SVG.encode(Plan.t()) -> {:ok, binary} | {:error, :invalid_plan}`. The fixed child-project task `mix swarm_code.demo.cells` exports the four fixtures at 80x24, 120x40 and 160x50 into a fresh task directory below repository `_build/cell-previews/`. No arbitrary input/script/source paths are accepted.

- [ ] Add RED SVG tests for exact dimensions, fixed cell coordinates, wide glyph leads only, palette colors/modifiers, cursor/focus markers, XML escaping and absence of scripts/external resources. Test invalid Plan rejection before output.
- [ ] Implement passive XML serialization with per-row/cell placement and a fixed monospace font declaration. Default terminal colors receive a documented preview-only visual background; Plan values stay unchanged.
- [ ] Implement the fixed contributor command with compile-only startup and no daemon. Create a fresh output directory; refuse symlink output ancestors. Generate only filenames derived from closed fixture/size/mode enums. Return the output directory and exact artifact count.
- [ ] Run artifact tests and the real command from the CLI child. Serve the task output locally and inspect it using ego-lite at laptop and wide-screen sizes; verify all four scenes and narrow question/confirmation views. Fix observed hierarchy, clipping, color and cursor defects, then close the task space and server.
- [ ] Run focused Paint, projector, reducer and demo suites, then full precommit and production compilation. Record actual visual evidence and limitations in the parity audit; commit.

## Completion evidence for this slice

A checked-in Plan/Canvas/Text implementation is not enough. Completion requires
all sixteen Scene blocks painted, wide-cell invariants, current fixtures passing
actual-cell assertions, a working preview command, visually reviewed artifacts,
and preserved plain/reducer/runtime tests. Native terminal ownership/input and
Port integration remain the next candidate plan, with their own Gate0 and
four-target obligations. The full user parity goal remains active.
