# html-report

Write a single-file HTML report that looks designed, not generated.

You are producing a document someone will open in a browser, scroll once, and
either trust or close. Everything below is drawn from a reference set of reports
that worked. Follow it exactly; the freedom is in the *content* and the
*palette*, not in the structure or the craft.

---

## The six hard constraints

**1. One file.** No build step, no external CSS, no CDN JavaScript. The only
external resource permitted is a single Google Fonts `<link>`. Everything else —
every style, every chart — lives in the file you write.

**2. No JavaScript for content.** Every chart, bar, gauge and comparison is CSS.
If you add a `<script>` at all it may only animate something already legible
without it (a bar widening on load). A reader with scripts off must lose nothing.

**3. A `:root` token block, and no raw hex below it.** Declare a background, two
or three surfaces, a border, three text weights and two or three accents. Then
use only `var(--…)`. A raw `#hex` inside a rule is a bug.

**4. Three fonts, three jobs.** A display face for headings, a sans for body
text, a mono for every number. Numbers are *always* mono, and always
`font-variant-numeric: tabular-nums` so columns line up.

**5. The type contrast is the design.** Micro-labels are `10–11px`, uppercase,
`letter-spacing: .08em–.15em`, in the muted text colour. Display type is
`2.4rem+` with `letter-spacing: -.02em`. That gap between tiny-wide and
huge-tight is most of what makes these reports look like someone made them.

**6. Every number carries its source.** A figure with no `[n]` marker is a bug.
The `sources` block at the end is numbered and every marker resolves to it.

---

## Page shape

```
<header class="hero">        the question, one sentence of answer, 3-5 big numbers
<section>  × 4-7             each with a section-header
<footer class="sources">     numbered, each with one clause on what it gave you
```

- Body `max-width` between `1100px` and `1400px` for a data-dense report,
  `760px–860px` for an essay-shaped one. Centre it, and give the page
  `padding: 0 24px`.
- Vertical rhythm: `80px` above a section header, `36px` below it, `20px`
  between blocks inside a section. Be consistent; drifting spacing is the single
  most obvious tell of generated HTML.
- Dark by default. If the subject is warm (biology, materials, money) shift the
  background toward that hue rather than using neutral grey — `#050d0f` for a
  green report, `#0c0b0e` for a warm one, `#060912` for a cool technical one.

---

## Component vocabulary

Use these and nothing else. Their markup and CSS are in `components.html`.

| Component | When |
|---|---|
| `hero` | Once, at the top. Kicker, title, one-sentence subtitle, `stat-strip`. |
| `stat-strip` | 3–5 numbers that carry the whole report. Never more than 5. |
| `section` + `section-header` | Every section. The header has a dot, a title and a right-aligned meta line. |
| `spec-row` | A key/value fact. The densest honest way to show a table of specs. |
| `bar` | Anything comparative. A `track` and a `fill` with an inline `width:%`. |
| `compare-table` | Two or three things across the same dimensions. |
| `callout` | `--note`, `--warn`, `--good`. At most one per section. |
| `verdict` | Once, near the end. The judgement, in a box, in one sentence. |
| `chip-tag` | A category, a status, a version. Mono, uppercase, tiny. |
| `quote` | A source's own words, when the wording matters. |
| `timeline` | Dated events, roadmaps, release history. |
| `sources` | Once, at the end. Numbered `<ol>`. |

If a thing you want to show is not on this list, use `spec-row` or
`compare-table`. Do not invent a component.

---

## Palettes and fonts

Pick one palette and one font pairing from `themes.css`, whichever fits the
subject. Copy the `:root` block verbatim, then add at most two subject-specific
accent tokens (one per entity being compared, for example). Do not blend two
palettes.

---

## What makes these reports good, concretely

- **The hero number is huge.** `clamp(2.6rem, 6.6vw, 5.2rem)`. One number the
  reader remembers.
- **Density is a feature.** A `spec-row` list of 20 facts at `12.5px` reads
  better than five paragraphs. Prefer rows to prose wherever the content is
  facts.
- **Bars beat tables for comparison, tables beat bars for exactness.** Use both:
  the bar for the shape, the number at the end of it for the value.
- **Colour means something.** Each entity compared gets one accent and keeps it
  for the whole document. Never colour something for decoration.
- **Uncertainty is shown, not hidden.** Where sources disagree, say so in a
  `callout --warn` with both numbers and both markers.
- **The report ends with a judgement.** A `verdict` block. Reports that only
  summarise are forgettable.

## What to avoid

- Emoji. Border-radius above `14px`. Drop shadows on flat surfaces.
- Gradients as backgrounds for large areas (a 1px gradient rule is fine).
- Centre-aligned body text. Justified text.
- More than five `stat-strip` entries, or more than seven sections.
- A table of contents. The document is one scroll; a TOC admits it is too long.
- Inventing a number. If the notes do not have it, the report does not have it.
