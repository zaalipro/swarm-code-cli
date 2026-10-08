# cli021 lane U notes (vitals side panel, status line, settings)

Branch `cli021/U` from CLI `main` `b6f8c79a`, worktree `~/dev/swarm-code-cli-wt/cli021-U`
(contract §4.1 recipe: APFS clones of `deps`, `_build`, `priv/native`; no `_build/prod`).

Done: U1, U2, U3, U4. Parity items taken: none (P4 is outside this lane's files, see the end).
The design below was written before the build; "U1 as built" further down supersedes it where
they differ (rendered from the code, with the reasons).

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

## U1 as built

`ui/projector/vitals.ex` (new, pure) reads the vitals, plans the panel's top rows and the compact
form. `Panel.plan/3` puts its rows first (pinned, never scrolled), `Shell` decides where the
compact form goes (`Vitals.placement/2`), `Strip` and `Status` draw it. Theme roles only.

Rendered by `Panel.plan/3` from the swarm fixture (rich tier; `|` marks the pane's edges; colour
not shown: the live dot and the newest bar in the slot's role, history bars `text_ghost`, idle
sparks `ticks_track`, the live number bold `text_primary`, idle names and numbers faint):

```
W = 56:
| speed                                            tok/s |
| ● main       deepseek-v4.1-flash    ▄▅▆▇▇▇▆▇███▇   142 |
| ○ worker     ms/glm-5.2               ▁▂▂▂▃▂▂▃▃▃    38 |
| ○ validator  nv/glm-5.3                              − |
|   RAM        ▄▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁  312 MB |
|              app 271 MB · tools 41 MB         of 16 GB |
|                                                        |
|▌⋔ Swarm · independent agent lanes                      |

W = 46 (the default dock):
| speed                                  tok/s |
| ● deepseek-v4.1-flash       ▆▇▇▇▆▇███▇   142 |
| ○ ms/glm-5.2                ▁▂▂▂▃▂▂▃▃▃    38 |
| ○ nv/glm-5.3                               − |
|   RAM ▄▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁  312 MB |
|       app 271 MB · tools 41 MB      of 16 GB |
|                                              |

W = 40:
| speed                            tok/s |
| ● deepseek-v4.1-flash ▆▇▇▇▆▇███▇   142 |
| ○ ms/glm-5.2          ▁▂▂▂▃▂▂▃▃▃    38 |
| ○ nv/glm-5.3                         − |
|   RAM ▄▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁▁  312 MB |
|                               of 16 GB |
|                                        |

W = 28 (below the dock's 38 minimum; drawn for robustness):
| speed                tok/s |
| ● deepse…-flash ▇███▇  142 |
| ○ ms/glm-5.2    ▂▂▃▃▃   38 |
| ○ nv/glm-5.3             − |
|   RAM ▄▁▁▁▁▁▁▁▁▁▁▁▁ 312 MB |
|                            |

A short pane (under table + 1 + 12 rows), W = 46:
| ● 142 tok/s · deepseek-v4.1-flash RAM 312 MB |
|                                              |

Strip, 80 columns (below 120 columns the panel is this one-row strip):
 ▌⋔ Swarm · independent a…   ⋔ 0 of 4 in         142 tok/s · RAM 312 MB · $0.18

Status line, 120 and 80 columns, panel hidden (`auto`, no run in chat):
 Build · ctx 2k · $0.02 · 142 tok/s · RAM 312 MB                Esc stop the turn   Ctrl-P palette
 Build · 142 tok/s · RAM 312 MB                               Esc stop the turn
```

PNG renders reviewed (Pillow rasteriser of the paint plan's SVG, scratch, not committed): 120x40
carbon dark, 160x48 paper light, the dock at 56/46/40, the `other` model with no Mac size, and the
strip/status line at 80x24 in both themes (`~/.cache/ncode/cli021/U/shots/`).

### Where the as-built differs from the design, and why

- **Seam.** C2's DTO, not the guessed shape: `ReadModel.vitals` = `%DTO.Vitals{conversation_id,
  models: [%DTO.ModelSpeed{slot (:main|:worker|:validator|:other), model, tps, live, ttft_ms, at,
  history}], beam_bytes, os_rss_bytes, children_rss_bytes, machine_bytes, sampled_at}` (cli021/C
  `285610ff`). Read with `Map.get`, so plain maps (the tests) and a nil field (an older daemon,
  this branch before the merge) both work: nil draws nothing and every old scene is unchanged. No
  stub was needed. Speeds of another conversation are dropped (memory kept). One model in two slots
  is one row (`main+worker`), the live slot's numbers, else the newest measure.
- **Slot words.** Only when the pane's inner width is 44 or more, some row has a slot, and the
  names keep 18 cells. The 56 dock shows them; the default 46 dock does not (`main` would cut
  `deepseek-v4.1-flash`), and there the dot's colour is the slot. A model outside the three slots
  reads `other`.
- **Spark colours.** History in `text_ghost` and only the newest bar lit: the first render (history
  `text_faint`) read as a heavy wall next to the run's title.
- **RAM gauge.** `▄`/`▁` (the panel's found-gauge glyphs, `Glyph :report_on/:report_off`) instead of
  `▰▱`: the `▱` track read busy across 30+ cells. Filled `text_muted`, `warning` from 50 % and
  `error` from 80 % of the Mac's memory; the track `ticks_track`.
- **Breakdown words.** `app 271 MB · tools 41 MB` (C2's split: the app's own RSS, its child
  processes), `of 16 GB` right-aligned under the number; without the Mac's size the gauge says
  its soft scale, `scale 2 GB` (doubling when exceeded). The split gives way before the scale.
- **Busiest.** The live model with the most tok/s; when none streams, the measured one with the
  most tok/s, faint (the design said "the newest measure").
- **Status item.** `vitals` is a new `terminal.status_items` choice, in the default list, at the
  lowest rank (10), so it is the first fact to give way; leaving it out of the list hides it.
- **Strip.** The compact form sits before the money on the strip's right side and is the first
  thing dropped when the strip is short.
- **Placement.** The panel when the dock draws its agents tab and is at least 10 rows tall (else
  the dock has no vitals row); the strip when it is drawn; else the status line. A dock on its
  timeline or changes tab leaves the compact form to the status line.

## U2 as built

- `projector/status.ex`: the worker fact reads `worker <model>` (was `agents <model>`), shown only
  while it differs from the chat model. B's hand-over.
- `ctx` reads used / window: `8k/1M`, `26k/200k`, `1.2M/1.5M`, `8k/2M` (`window_words/1`: whole
  millions as `1M`, else one decimal; thousands as `200k`). The window is `workspace.context_window`,
  which C3 (cli021/C `285610ff`, `Service.ContextWindow`) now fills with the model's window (the
  configured one, else the default) instead of the 75 % trimming budget.
- Dependency: until K's sync brings K1's 1 M default into this CLI, an unconfigured model's window
  is still the synced domain's budget (120k, Claude 160k), so the status line reads `8k/120k` for
  such a model. That is C3's documented behaviour, not a U bug.

## U3 as built

- **Context window rows.** Every unset window reads `1M default` (K1), from one source,
  `IntegrationRows.context(nil)`: the Pricing table's context column, a price row's page and its
  editor's null label, the model picker's rows, the new Models & effort rows. If K's sync does not
  land in 0.2.1, that one function changes the words back (`family default`).
- **Models & effort → `context windows`** (new group after `this conversation`): one row per model
  the conversation uses (its chat, worker and validator values, else the new conversations'
  defaults), the slots named on the right (`chat · worker` when one model fills both). A priced
  model edits in place (Number editor, 8 000 to 2 000 000, step 1 000 / 100 000, nullable; `r`
  back to 1M); the commit writes the whole price row through `pricing.put_row` with CAS on the row
  as read (`Pricing.window_ops/3`), the same op the Pricing page sends. An unpriced model's row is a
  link that opens its price draft (`Pricing.draft_ops/2`): the desktop keeps the window on the price
  row and `pricing.put_row` requires both prices, so the window cannot be saved alone.
  The price rows come 200 a page: a model not on a partial page reads `set on the Pricing page`
  and opens Pricing, never a second draft for a row that exists (`Pricing.window/2` `:unknown`).
- Reading of "a row for each model": each priced model (Pricing, as before, now with the 1M words)
  and each model the conversation uses (Models & effort). Not each model a provider lists
  (OpenRouter lists about 2 000; the window has no home outside the price row).
- **Fetch results where the fetch was started** (C1's words; the service's own `words` win, else
  the same sentence is built from `listed/added/removed`):
  - the provider page's `▸ Fetch models` row: `✓ 12 models · 3 new · 2 removed · 18:42`, a failure
    in its own sentence after the error glyph (`the key was refused (401)`); a fetch with `saved: true` offers no diff
    to apply (the fake keeps `saved: false` and the preview-then-apply flow its tests drive);
  - `▸ Fetch every provider's models` on Providers and on Models & effort: `✓ 3 providers · 2
    updated · 1 failed` and one line per provider (up to 6, then `+N more`; a failure in `error`
    with its message);
  - the model picker's provider heading (`f` there starts a fetch): `· 12 models · 3 new`.
- The idle words follow C1 (a fetch now saves): `saves the list the provider names now`, and the
  registry's `models.fetch_all` description; `docs/settings.md` regenerated.

## U4 as built

- B's words for the worker slot (B's notes, "Hand-overs for B2"): the status fact (U2), the
  registry's `session.sub_agent_model` / `session.sub_agent_effort` parity (`CLI /worker_model`,
  `CLI /worker_effort`) and description (`as /worker_model does`), the efforts synonyms
  (`worker effort`, `swarm effort`), the worker effort picker's title `Effort · worker model`.
- The dropdown: B wrote "U (drawing): nothing needed" (B3), so it is unchanged here. Its rows and
  `slash_popup/3` live on cli021/B. A later touch, after the merge: draw `current?: true` rows with
  a `●` in `text_muted` in place of the "(current)" words (`projector/composer.ex slash_popup/3`).

## For the integrator

- Files: only this lane's row (`ui/projector*`, `ui/settings/**`, `core/settings/**`,
  `docs/settings.md`) plus new tests under `test/swarm_code_cli/cli021/` and updated tests
  (`ui/shell_awareness_test.exs`, `cli020/e28_status_items_test.exs`, `cli020/e4_effort_test.exs`,
  `ui/settings/c74_model_picker_test.exs`, `ui/settings/sections/c74_pricing_test.exs`,
  `ui/settings/sections/c74_providers_test.exs`).
- With C: needs C's `ReadModel.vitals` field and delta (cli021/C `285610ff`); without it nothing is
  drawn. The U tests put the DTO's shape as plain maps, so they pass before and after the merge.
- With B: `projector/dialog.ex` is changed by both (U at line ~1403, the worker picker's title; B
  at ~1441, the picker's cursor); different hunks. `cli020/e4_effort_test.exs` expects
  `Effort · worker model`; if B changed the same assertion, keep U's words.
- With K's sync: the `1M default` words (see U3).

AGENTS.md lines for the finisher (CLI repo, the projector section):

> The side panel's top block is the vitals (`ui/projector/vitals.ex`): tok/s per model with a
> sparkline and RAM as a gauge, from `ReadModel.vitals` (C2's `DTO.Vitals`). Below 120 columns or
> with the panel hidden, the busiest model's tok/s and RAM move to the strip or the status line
> (`vitals` status item). Theme roles only; nil vitals draw nothing.

## Parity (P4, lane U, size S): not taken

P4: a scheduled task made in the CLI saves effort `medium` and timezone `Etc/UTC`
(`ui/library.ex:25-90`, `new_form(:schedules)`); the desktop leaves the effort unset (it follows
`default_scheduled_effort`) and uses the Mac's zone. Not taken: `ui/library.ex` is in no lane's
row (brief, ownership table) and the rule is "S items in your own files". Proposed fix for its
owner: an effort choice `default` (value nil, no initial value submitted, the description naming
the current default) first and selected; the timezone's initial value from the daemon's local
zone (the client has no IANA zone of its own; `Etc/UTC` only as the fallback when none is sent).

## Assumptions (verified = read in code; guessed = inferred, with the fix if wrong)

1. Verified: C's `ReadModel` has `vitals: nil` and a `:vitals` delta that stores `%DTO.Vitals{}`
   (cli021/C `read_model.ex:24-26, 321-328`).
2. Verified: C3's window for an unconfigured model is the synced domain's budget until K1 is synced
   (cli021/C `service/context_window.ex`, `default(750_000) -> 1_000_000`, else the budget). If the
   sync slips: change `IntegrationRows.context(nil)` back to `family default`.
3. Verified: per-model windows live on price rows; `pricing.put_row` requires input and output;
   the window is 8 000..2 000 000 (`sections/pricing.ex check/2`, the daemon's pricing handler).
4. Verified: price rows come 200 a page (`daemon/service/settings/kit.ex @page_size 200`), hence
   the `:unknown` state.
5. Verified: the session's model values are `%{"provider_id", "model"}` maps (read from the fake's
   delivered values while writing the U3 test).
6. Verified: C1's single fetch summary carries `words` and `saved`; fetch-all carries `words`,
   `saved`, `failed` and per-provider `name/state/message` (cli021/C `fca9047f`, `72e9a69d`).
7. Verified: block elements U+2581..2588 are two cells under the wide ambiguous policy and braille
   is one cell under both (`Width.cells/2`, scratch `widths.exs`), hence the measured tier's
   braille sparkline.
8. Verified: the dock is drawn from 120 columns at 38..56 (default 46); below 120 the panel is the
   one-row strip (`ui/layout*`).
9. Verified: B's dropdown needs nothing from U (B.md, B3) and B's `dialog.ex` hunk (~1441) does not
   overlap U's (~1403).
10. Verified: `ui/library.ex` is in no lane's row (brief table).
11. Verified: `os_rss_bytes` is the VM's resident size (daemon and terminal client share it) and
    `children_rss_bytes` the processes it started (the terminal renderer, tool commands) (cli021/C
    `dto/vitals.ex` moduledoc); the desktop's RAM tooltip calls the same share `tools`
    (desktop `lib/swarm_code/desktop/memory.ex:92`), hence `app · tools`.
12. Verified: `machine_bytes` is the machine's memory, "the scale a bar draws against", nil when
    unknown (same moduledoc), hence the gauge's scale and the 50 % / 80 % roles.
13. Verified: `history` holds the exact rates of the most recent finished calls, oldest first, at
    most 12 (cli021/C `dto/model_speed.ex`); the live estimate is appended as the newest bar.

## Tests and gates (run on this branch, 2026-10-08)

New tests (written first, seen failing): `test/swarm_code_cli/cli021/u1_vitals_test.exs` (15:
widths 56/46/40/28 exact, slot words, breakdown by room, middle elision, the dash, nil vitals
unchanged, short pane, short dock, memory only, live vs idle roles in truecolor, ASCII clean, the
seam's merge/other conversation/VM fallback/`other` + soft scale, sparkline tiers),
`u2_status_line_test.exs` (10: `worker`, `ctx` used/window, compact form on the status line, not
while the panel draws it, in the strip, idle, none, the status item), `u3_settings_test.exs` (10:
`1M default`, the context windows group, CAS write and `r`, unpriced draft, partial page, fetch
words on the provider page, fetch-all lines, the model picker heading, Models & effort's row).

- `mix format --check-formatted`: clean. `mix compile --warnings-as-errors --force`: clean (core,
  daemon, cli).
- Full CLI app suite under the slot rule (`~/.cache/ncode/cli020/suite-slots`, claimed 11:33:37Z,
  released 11:38:14Z): 10 properties, 3128 tests, 0 failures.
- Focused after the last change: cli021 + ui/projector + cli020 + shell_awareness + ui/settings +
  c74_settings_docs: 1108 tests, 0 failures. Core `test/swarm_code/settings`: 40, 0 failures.
  Daemon `service/settings`: 101, 0 failures.
- `mix swarm_code.settings --write` then `git diff --exit-code docs/settings.md`: no diff.
- PTY: `scripts/dev/test_terminal_demo_pty.py` under a scratch HOME (`~/.cache/ncode/cli021/U/home`,
  `NCODE_CONFIG_DIR`/`NCODE_PREFIX` there): 8 tests OK.
- Not run: `keymap --check` (no binding changed), the provenance check (no repin), any real
  provider or gateway (none needed; the fetch words are tested on the fake and C's summary shape).
