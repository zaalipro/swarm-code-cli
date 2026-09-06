# Renderer-neutral cell paint plan

This implementation slice advances a visible desktop-style TUI. It
turns the existing Scene into an inspectable terminal-cell grid, shared by a
future guarded Port and pure-Elixir renderer. It does not adopt a renderer or
claim terminal lifecycle, native-platform, or provider execution evidence.

## Why this boundary

The reducer and Projector produce responsive Carbon Scenes. Previously no code
proved which cells their nested blocks occupied. A renderer-specific
widget mapping could change wrapping, widths or action placement. A project-owned
cell plan makes those choices deterministic before crossing any renderer boundary.

Three approaches were considered: map Scene directly into Ratatui widgets;
write a pure-Elixir terminal framework now; or first define and exercise a shared
cell plan. The shared plan is selected because both viable candidates require
exact cell placement, while terminal input and restoration remain separate work.
The Port candidate retains first evaluation priority from the renderer ADR.

## Interfaces and limits

`UI.Paint.build(scene, options)` returns `{:ok, %UI.Paint.Plan{}}` or
`{:error, :invalid_scene | :capacity_exceeded | :invalid_options}`. Options are
closed: `color_mode` is truecolor/ansi256/ansi16/monochrome and `ascii?` is boolean.
The Scene supplies revision, dimensions and ambiguous-width policy.

Plan fields are version, revision, size, ambiguous_width, color_mode, cells,
palette, cursor, focus, actions and diagnostics. Focus is nil or a closed map of
region_id, control_id (binary or nil), and optional positive in-bounds rect for
the focused surface. Diagnostics contain only closed reason atoms
and opaque clipped-action IDs. Cells are a row-major tuple of
`{:glyph, binary, positive_width, style_index}` or `{:continuation, lead_column}`.
Blank cells are ordinary one-cell spaces. Width is computed by the existing
Unicode implementation and may exceed two for a complete grapheme cluster.
A glyph unit may contain adjacent complete graphemes when the existing width
algorithm reports a contextual ligature; summing isolated grapheme widths is
not valid. Every continuation refers to a lead in the same row, and every lead's
span fits that row. Palette entries carry only foreground/background color values and a
closed modifier list. Explicit Scene colors must be representable in the requested
mode; reject mismatches instead of silently quantizing them. Actions map opaque existing action IDs to visible cell
rectangles; they carry no Intent, command or source DTO.

Reject dimensions above 500 columns, 200 rows, or 100,000 cells before allocating
any grid. Reject an input Scene above 4 MiB aggregate text, 4,096 structural nodes,
32 nested display levels, 64 regions, or 4,096 action IDs before the ordinary
Scene validator walks it. Do not silently truncate a rejected Scene. Bounded
input checks walk no farther than the first violated count/depth/byte budget.
The byte budget includes opaque IDs and expanded trusted chrome. IDs remain
opaque UTF-8 binaries of 1–256 bytes without C0/C1 controls. A separate structural
recursion guard of 128 accommodates the metadata around 32 nested display blocks.
Palette cardinality is at most 4,096; the Plan's external term size is at most
32 MiB. Glyph payloads are limited to 262,144 bytes and must be unchanged by
SafeText admission. Action ownership is uniform across every complete glyph span.
These are candidate-development limits, not changed canonical data limits.

## Painting rules

Paint regions in Scene order, then the opaque dialog overlay. Clip to each
rectangle and skip zero-area regions. Use a persistent array during construction,
then finalize a tuple once; avoid copying an entire dense tuple for every cell.

A grapheme that cannot fit at the right edge is omitted as a whole. Painting over
any continuation clears the complete old glyph span before placing replacement
cells. Filling an overlay may clear a background glyph crossing its edge, so no
half glyph or orphan continuation survives. Never re-segment an already selected
grapheme prefix or substitute a different ambiguous-width policy.

Default canvas, surface, text and focus colors come from `Theme`. Span styles
inherit defaults and then apply their explicit colors/modifiers. Emit their
trusted prefix once before span content. ASCII changes only trusted borders and
chrome, not external Unicode. No ANSI, OSC, links, raw terminal calls or IO occurs
inside Paint modules.

The block mapping is exhaustive:

| Scene block | Cell presentation |
|---|---|
| Text / RichText | Wrapped text / consecutive styled spans with shared line wrapping |
| Markdown | Readable paragraph, heading, list and fenced-code styling; preserve literal text when syntax is unsupported |
| Code | Monospaced literal lines with optional language caption |
| VirtualList | Only supplied items, in supplied order; no inferred source rows |
| RunCard | One title/status boundary, then body; no nested decorative boxes |
| AgentList | Supplied agent rows in order |
| ConsensusLedger | Supplied entries with one ledger label and shared line layout |
| ResearchDocument | Title followed by supplied sources |
| Progress | Label and bounded proportional bar; zero maximum is indeterminate text |
| Tabs | Inline tab labels with selected styling and wrapping |
| KeyValues | Label/value rows with bounded label column |
| Composer | Supplied viewport text, or placeholder when empty; Scene cursor remains authoritative |
| Notice | Severity prefix and styled text |
| ActionDeck | Inline action labels, wrapping between actions; wholly clipped action IDs are recorded |

The first cell implementation must reconcile actual projector chrome budgets
with these rules. Region labels cannot consume the one-row title/activity/status
strips or shift the composer caret. Navigator reserves its existing label row.
Main/Inspector label/boundary accounting is shared with projection instead of
adding unmeasured rows. If an action is completely clipped, return it in an
explicit Plan diagnostic list rather than silently claiming it is visible;
viewport tests must fix projection so required actions are reachable.

Transcript scrolling counts rendered rows, including Markdown styling and section
headers. Parse before windowing so a viewport beginning inside a code fence keeps
its code style. Shared lazy row production supplies both ScrollMetrics and the
Projector; emit only the selected rows into Scene. History can exceed 200 rows,
while each Paint frame keeps its existing cap. Word breaks preserve complete
graphemes and source whitespace; code and Composer keep literal cell wrapping.
Canonical Scene sizes remain unchanged by Paint admission limits. If optional
Markdown parsing exceeds its syntax budget or produces an unpaintable styled
line, the transcript preserves the admitted source line literally; it must not
crash projection or silently lose text.

## Inspection and verification

A passive SVG exporter consumes only a validated Plan and renders cells at fixed
monospace coordinates with explicit colors and cursor/focus markers. Escape XML
text/attributes. Include the existing fake banner. A fixed contributor command
exports chat, swarm, consensus and research fixtures at selected dimensions into
a task-owned directory. It accepts no arbitrary source path, user data or scripts.
These are cell previews, not the future 87-frame native acceptance evidence.

Use exact small-grid tests for wide and combining glyphs, clipping, overlay
replacement, style inheritance, cursor and action rectangles. Exercise all fifteen
block variants. Check every existing layout breakpoint and both width policies;
assert terminal-neutral content contains no escape sequences. Verify invalid
size/depth/count/text fails before grid allocation, and retained work is bounded
by the cell/input budgets.

Open preview artifacts in a dedicated ego-lite space for visual review, compare
the Navigator/Main/Inspector hierarchy and Carbon theme with the existing desktop
audit, then close only that space. Never clear cookies or daily browser sessions.
Do not claim exact native terminal appearance from SVG. Real terminal drawing,
bounded input, signals, suspend/resume, restoration and four-target execution
remain the subsequent renderer-candidate plan.
