# cli021 lane U notes (vitals side panel, status line, settings)

Branch `cli021/U` from CLI `main` `b6f8c79a`, worktree `~/dev/swarm-code-cli-wt/cli021-U`
(contract §4.1 recipe: APFS clones of `deps`, `_build`, `priv/native`; no `_build/prod`).

## U1 design (written before the build)

Meaning, from the desktop: the speed monitor (`speed_monitor.ex`, spec 75) shows, per model slot
the shown conversation uses (Main, Worker, Validator), the latest output tokens/second; a live
estimate while the call streams, the exact value at its end, `—` before the first measure. The RAM
chip (`desktop/memory.ex`, spec 35) shows what the whole app costs (`578 MB`), the breakdown in its
tooltip. Today's side panel (pass 75 V2) is lowercase headings in `text_muted` with faint figures
on the right (`agents ... 3 live`, `found`, `spent`), one blank row between blocks (air, not
rules), every row exactly the pane's width (`Panel.Draw.row/5`).

Decisions:

- The vitals are the panel's first block, above the run in chat, pinned (they never scroll and
  are never cut by the panel's candidates). One blank row parts them from the run.
- One table: a `speed` heading whose unit `tok/s` sits over the numbers, one row per model, then
  the `RAM` row whose number ends on the same right edge. No rules, no boxes.
- A model row: a dot, the role words (wide only), the model name (middle-elided with `…`, so
  `deepseek-v4.1-flash` and `deepseek-v4.1-pro` stay apart), a sparkline of the recent samples
  (newest at the right, every row on one shared 0..max scale so heights compare across models),
  the latest number right-aligned in 4 cells (`142`, `1.2k`, `−` before the first measure).
- Live (streaming now): the dot and the newest bar in the slot's colour (main `run_assistant`,
  worker `run_swarm`, validator `run_ultra`, any other model `text_muted`), the history bars
  `text_faint`, the name `text_primary`, the number `text_primary` bold. Idle: everything
  `text_ghost`/`text_faint`, so only what streams catches the eye.
- Order is stable (calm): main, worker, validator, then other models by name; one model in two
  slots is one row (`main+worker`). At most 4 rows, then `+N more` faint.
- RAM: `▰`/`▱` (the status line's ctx gauge glyphs) against the Mac's memory when the daemon
  sends it (`of 16 GB` in the breakdown), else against a soft scale (2 GB, doubling when
  exceeded); filled `text_muted`, `warning` from 50 % and `error` from 80 % of the Mac's memory;
  the number `text_primary`. The breakdown row (wide only) names the engine's and the terminal's
  shares. Words never say "the daemon".
- Glyph tiers (`Panel.Glyph`): sparkline `▁▂▃▄▅▆▇█` at the rich tier, braille `⡀⣀⣄⣤⣦⣶⣷⣿` at the
  measured tier (block elements are ambiguous-width, braille is one cell under both policies,
  measured), ASCII `_.-~=+*#`; dots `●`/`○` (`⦁`/`⚬`, `*`/`o`); the gauge `▰▱` (`#-`).
- Widths (panel width W, inner N = W − 2): wide N ≥ 44 (roles, spark 12, breakdown row);
  medium 30..43 (no roles, spark 10, else 8 under 36); small < 30 (spark 5).
- A pane shorter than 18 rows gets one vitals row (`● 142 tok/s · deepseek-v4.1-flash  RAM 312
  MB`); under 10 rows none.
- No vitals data (an older daemon, nothing watched yet) draws nothing: every existing scene and
  golden stays as it is.

### Mockups (panel widths 56, 40, 28; `|` marks the pane's edges)

W = 56 (the dock's widest):

```
| speed                                            tok/s |
| ● main       deepseek-v4.1-flash    ▁▂▄▆▇▆▅▆▇█▇▆   142 |
| ○ worker     ms/glm-5.2             ▁▁▂▂▃▂▂▁▁▂▁▁    38 |
| ○ validator  nv/glm-5.3                              − |
|   RAM        ▰▰▰▰▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱  312 MB |
|              engine 271 MB · terminal 41 MB · of 16 GB |
|                                                        |
| ▌⋔ architecture review                                 |
|   swarm · in chat · 65k · $0.15+                 02:14 |
```

W = 40:

```
| speed                          tok/s |
| ● deepseek-v4.1-flash ▁▄▆▇▆▅▆▇█▇  142 |
| ○ ms/glm-5.2          ▁▂▂▃▂▂▁▁▂▁   38 |
| ○ nv/glm-5.3                        − |
|   RAM ▰▰▰▰▰▰▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱▱  312 MB |
|                                      |
| ▌⋔ architecture review               |
```

W = 28 (narrower than the dock allows today, 38; drawn for robustness):

```
| speed              tok/s |
| ● deeps…1-flash ▆▅▆▇█  142 |
| ○ ms/glm-5.2    ▂▂▁▁▂   38 |
|   RAM ▰▰▰▰▱▱▱▱▱▱▱▱  312 MB |
|                          |
| ▌⋔ architecture revi…    |
```

A short pane (under 18 rows), W = 46:

```
| ● 142 tok/s · deepseek-v4.1-flash  RAM 312 MB |
|                                              |
```

### Compact forms (panel hidden, or the one-row strip)

- Placement: the vitals block when the dock is drawn on its agents tab; else the strip's right
  side when the strip is drawn (under 120 columns, auto showing it); else the status line.
- Busiest model: the live one with the most tok/s; when none streams, the newest measure, faint.
- Strip, 80 columns (gives way first: before the stopped agent's name and the title cut):

```
 ▌⋔ architecture review  ! 1 needs you ^N   ⋔ 1 of 4 in   142 tok/s · RAM 312 MB · $0.15
```

- Status line, 120 columns, panel auto-hidden (`vitals`, a new `terminal.status_items` item in
  the default list, the lowest rank, so it is the first fact to give way):

```
 Build · auto · deepseek-v4.1-flash · high · ctx ▰▱▱▱▱▱ 8k/1M · $0.04 · 142 tok/s · RAM 312 MB    Esc interrupt  ? keys
```

- Status line, 80 columns: `Build · auto · deepseek-v4.1-flash · high · RAM 312 MB` while
  nothing streams, as room allows.
