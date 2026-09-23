# What the reference reports do well

Six reports this skill is derived from, and the one thing each gets right that
you should copy.

---

## `nvfp4-dgx-spark-dashboard.html` — density without noise

An instrument panel: `7px`–`9px` mono labels, `1px`–`2px` radii, a `54px` hero
figure. Almost every value is a `spec-row`; there is barely a paragraph in the
file. The lesson: **when the content is facts, rows beat prose**, and a tiny
uniform label size makes forty rows read as one calm block instead of forty
things shouting.

It also proves colour discipline. Seven accent tokens are declared and each one
means exactly one thing (cyan = the subject, green = good, amber = caution, red
= failure, purple = a third party). Nothing is coloured to look nice.

## `xmrig-vps-mining-report.html` — a palette that matches the subject

Gold on near-black, with a green and a red that are muted rather than bright.
It reads like a ledger because it is about money. The lesson: **shift the
background and the accents toward the subject's own register.** A neutral grey
report about mining would be forgettable.

Note the three-weight text scale (`#E8E4DC` / `#888070` / `#3A3632`). Three
weights is enough; a fourth starts to look like an accident.

## `algae_biofuel_report.html` — serif display against mono data

`Cormorant Garamond` for headings, `DM Sans` for body, `JetBrains Mono` for
numbers, on a deep green-black. The serif makes a science report feel
authoritative rather than technical. The lesson: **the display face sets the
register of the whole document** — pick it from the subject, not from habit.

It is also the longest of the six and stays readable because every section
opens with a `section-header` that says how many sources it rests on.

## `china_ai_gpus_report.html` — one accent per entity, held all the way down

Cambricon is orange, Huawei is teal, for 1,059 lines. Every bar, every chip,
every table cell obeys it, so you can read a chart without a legend. The lesson:
**assign colour to entities once and never break it.**

Its `perf-bar-track`/`perf-bar-fill` pair is the bar component in this skill,
and its `hero-stats` row is the `stat-strip`.

## `qwen35_122b_memory.html` — a small report that knows it is small

487 lines, one table, three stat cards, one bar chart with a limit line marking
the hardware ceiling. No filler, no invented sections. The lesson: **a report
should be as long as its content and no longer.** Four sections is a perfectly
good report; seven is the maximum.

The limit line is worth stealing: a single absolute-positioned `1px` rule across
a bar chart, labelled, turning "these are the numbers" into "here is which of
them fit".

## `mlx_quantization.html` — editorial rhythm

`Fraunces` optical serif, `clamp()` type throughout, `--maxw: 1120px`, and
generous `74px 0 56px` hero padding. It reads like a magazine feature rather
than a dashboard, and the `pill` / `callout` / `verdict-row` components carry
the judgements. The lesson: **when the content is an argument rather than a
dataset, widen the leading, narrow the measure and let the display face work.**

---

## The pattern across all six

1. A `:root` block first, then no raw hex anywhere.
2. Three fonts, and numbers always mono.
3. Tiny wide uppercase labels against large tight display type.
4. Colour that carries meaning, never decoration.
5. A judgement at the end, not just a summary.
6. Self-contained: no CDN script in any of the six.
