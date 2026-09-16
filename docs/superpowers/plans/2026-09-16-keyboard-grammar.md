# Keyboard grammar: one binding table, standard navigation, vim

Date: 2026-09-16. Scope: `apps/swarm_code_cli` only. Nothing under `~/dev/swarm-code`
is touched and nothing under `_build/prod` is deleted.

## Why

The shell's keys are hard to learn because they are defined three times and
agree with each other nowhere:

- `UI.Keymap` (703 lines of nested `cond`) decides what a key does.
- `UI.Projector.Status` hand-writes a different hint list for every width.
- `UI.Projector.Dialog.contents(:help, ...)` is eight static strings. It omits
  `Ctrl-G`, `Ctrl-R`, `g`, `j/k`, `h/l`, `o`, `t`, `x`, `p`, `m`, `a`, `/`,
  `Alt-1..4` and the resize keys.

The grammar itself is inconsistent:

- `Esc` closes a layer, leaves the composer, clears the dashboard filter, and in
  main it pops navigation history (`:back`). A key that sometimes navigates
  cannot be the vim "get out" key.
- `q` quits from main but closes the dashboard; `b` closes every other dialog.
- `Ctrl-G` toggles its own layer; `Ctrl-K` and `Ctrl-R` do not (well, `Ctrl-R`
  does, `Ctrl-K` does not).
- `G` selects the last row but `End` follows the stream; `Home` selects first
  but `gg` needs the jump popup; none of `j/k/G` work inside a dialog.
- `{:line, n}` is a valid `ScrollOperation` no key emits.
- The tab row that replaced the navigator has no keys at all; `Alt-1..4` switch
  the *inspector's* tabs.

Facts that constrain the design (verified in the tree):

- Letters arrive as `{:text_fragment, phase, "j", mods}`; only `@special_keys`
  in `UI.Input` arrive as `{:key, ...}`. Uppercase letters arrive as the
  uppercase fragment with `mods` of `[]` or `[:shift]`, so `:shift` must be
  stripped from text fragments before lookup.
- `native/terminal_port/src/input.rs` resolves a standalone Escape after 40 ms.
  Vim's `Esc` will be prompt and unambiguous.
- `Capabilities.enhanced_keys` is always `:unavailable`
  (`renderer/ratatui_port/owner.ex:245`). `Shift-Enter`, `Ctrl-Shift-*` and
  `Ctrl-1..9` cannot be relied on.
- On macOS the user's terminal is ghostty, where Option is not Alt unless
  configured. **Nothing essential may live only on an Alt chord.** Alt chords
  are accelerators for a thing that also has a Ctrl or bare-key route.
- Module attributes cannot hold anonymous functions. Table entries whose action
  needs state (`State.next_id/2`, the selected run) must be symbolic atoms the
  resolver dispatches on.
- `Preferences` (`layout/preferences.ex`) is validated by `map_size == 6` and
  is layout-only. The keymap preference goes on `State`, not there.
- Nothing in the CLI persists preferences to disk. The vim preference is
  session-scoped plus `SWARM_KEYMAP=vim` read at start.
- `/` in main opens `{:region_filter, _}`; `docs/implementation/task13-keyboard-surfaces.md`
  records that the query is applied to nothing. Phase 1 must check whether that
  is still true and, if so, unbind `/` in main rather than ship a key that
  visibly does nothing.

## Design

### One table

`UI.Keymap.Bindings` is the single source of truth. Every entry:

```elixir
%Binding{
  id: :move_next,                     # unique atom
  keys: [{"j", []}, {:down, []}],     # {code, sorted mods}; :shift stripped from fragments
  action: {:move, :next},             # a literal Action, or {:special, atom}
  contexts: [:main, :inspector, :dialog],
  group: :navigate,                   # :navigate | :focus | :runs | :act | :layers | :edit | :vim | :session
  label: "Down",                      # <= 14 cells, shown in status hints
  help: "Move selection down",        # one line, shown in the ? sheet
  hint: 3                             # 0 = never in the status bar; higher = shown first
}
```

Contexts are computed once per key by `Keymap.Context.of(state)`:

| context | when |
|---|---|
| `:composer` | `focus == "composer"`, no layer, keymap `:default`, or keymap `:vim` in INSERT |
| `:composer_normal` | keymap `:vim`, composer focused, mode NORMAL |
| `:composer_visual` | keymap `:vim`, composer focused, mode VISUAL |
| `:main` | `focus == "main"`, no layer |
| `:inspector` | `focus == "inspector"`, no layer |
| `:picker` | top layer is `:switcher`, `:run_palette`, `:runs_dashboard`, `:jump`, `:action_menu`, `:region_filter` |
| `:field` | any layer where `Keymap.editor_context/1` returns a field editor |
| `:dialog` | any other layer |

`:global` entries apply in every context except where a text field would take
the key as typing (`:composer`, `:field`, and the filter of a `:picker`), and
`Ctrl`/`F-key` entries apply everywhere.

Resolution order in `Keymap.resolve/3`:

1. Lifecycle inputs (`focus_gained`, `resize`, `paste`, `rejected`) as today.
2. `Keymap.Vim.resolve/4` when keymap is `:vim` and the composer is focused.
3. Table lookup for `{Context.of(state), {code, mods}}`; `{:special, atom}`
   dispatches to `Keymap.Special.run/3`.
4. Text fragments fall through to typing (composer, field, picker filter).
5. `:ignore`.

Collisions are a compile-time-free but test-enforced invariant: no two entries
share a `{context, key}` pair.

### The grammar

Everything below is what the table says. Anything not listed is unbound.

**Session / layers (global)**

| key | does |
|---|---|
| `?`, `F1` | help sheet (`?` not in text fields; `F1` everywhere) |
| `Ctrl-K` | command palette, toggles closed when open |
| `Ctrl-G` | runs dashboard, toggles |
| `Ctrl-R` | run palette, toggles (in vim NORMAL it is redo, see below) |
| `Ctrl-B` | toggle the inspector dock (kept: it is on screen and has no Ctrl-free twin) |
| `Ctrl-C` | unchanged |
| `q` | close the top layer; with no layer, quit (unsent-changes confirm as today). Typing in text fields. |
| `Esc` | one step out, in order: pending vim keys, picker filter text, top layer, composer to main, VISUAL/NORMAL to the outer mode. Never navigates history. |
| `Alt-Left`, `Backspace` (main/inspector only) | `:back` |
| `Tab` / `Shift-Tab` | cycle focus (main, inspector, composer). From main with a composer, `Tab` goes straight to the composer, as today. |
| `i` (main/inspector) | focus the composer; in vim that is INSERT |
| `Alt-I` | toggle the inspector dock (accelerator for `Ctrl-B`) |

**Runs (main/inspector/global)**

| key | does |
|---|---|
| `g` then `t` / `g` then `T` | next / previous run tab, in the *stable* order `RunRow.visible(runs, "", RunRow.shell_order(state))`, never in the drawn active-first order (that would ping-pong) |
| `Alt-1..4` | the run tab as drawn at that position |
| `[` / `]` | previous / next inspector tab, whenever the inspector is visible (docked or overlay). `Alt-1..4` no longer do this. |
| `x` | stop the selected/current run (confirm) |
| `p` | pause / continue |
| `m` | mark seen |
| `a` | action menu |
| `t` | inspector overlay for the run |
| `o` | open detail |

**Selection and scrolling (main, inspector, dialog, run inspector)**

| key | does |
|---|---|
| `j` / `↓`, `k` / `↑` | `{:move, :next}` / `{:move, :previous}` |
| `g` then `g`, `Home` | `{:move, :first}` |
| `G`, `End` | `{:move, :last}` (and follow; `End` no longer differs from `G`) |
| `Ctrl-D` / `Ctrl-U` | `{:scroll, region, {:half_page, 1 / -1}}` — new `ScrollOperation` |
| `PgDn` / `PgUp` | `{:scroll, region, {:page, ±1}}` |
| `Ctrl-E` / `Ctrl-Y` | `{:scroll, region, {:line, ±1}}` without moving the selection |
| `h` / `←`, `l` / `→` | collapse / expand the selected item |
| `Space` | toggle expand |
| `Enter` | activate |

The `g` prefix keeps using the existing `{:jump, _}` layer, which becomes a
which-key popup: it lists `g top · G bottom · t next run · T previous run`
and closes on the second key or `Esc`.

**Pickers** (`Ctrl-K`, `Ctrl-R`, `Ctrl-G`, `g`, `a`)

Typing filters. `↑/↓`, `Ctrl-N/Ctrl-P`, `Tab/Shift-Tab` move; `Ctrl-D/U`,
`PgUp/PgDn`, `Home/End` page; `Enter` picks; `Esc` clears the filter, then
closes; the opening chord toggles closed. `b` no longer closes anything. The
dashboard keeps `q`-closes-when-filter-empty because it is a screen, not a
prompt; the palette does not.

**Dialogs** (question, approval, confirm, unsent changes, detail, help,
library, forms, command report, run inspector)

`j/k/↑/↓/←/→/Tab/Shift-Tab` cycle focus; `Enter` activates; `Esc` and `q`
close (`q` only when the focus is not a text field); `1..9` pick a question
option; `a/d/A` approve/deny/always on approvals; `y`/`n` confirm/cancel on
`confirm_intent` and `unsent_changes`; `PgUp/PgDn/Ctrl-D/Ctrl-U` scroll long
dialogs; `[`/`]` switch run-inspector tabs.

**Composer, default keymap**

Everything today plus readline: `Ctrl-A` line start (was select-all),
`Ctrl-E` line end, `Ctrl-W` delete word backward, `Ctrl-U` delete to line
start. `Enter` send, `Ctrl-O` newline, `Alt-Enter` queue, `Ctrl-Z` undo,
`Ctrl-Shift-Z` redo (unreliable, documented as such), `Esc` to main. Select-all
is unbound; `Ctrl-U` on a one-line draft is the clear-draft idiom.

**Composer, vim keymap** (`state.keymap == :vim`)

Off by default. On via the `Ctrl-K` entry "Vim mode: on/off" or
`SWARM_KEYMAP=vim` in the environment at start. Mode lives in
`state.vim = %UI.Vim{mode: :insert | :normal | :visual, pending: nil | binary, count: nil | pos_integer}`.

- INSERT: the default composer keys. `Esc` → NORMAL (cursor one left when not
  at line start, as vim).
- NORMAL: `h j k l 0 ^ $ w b e gg G` motions; `x X`; operators `d c y` with
  motions `w b e 0 ^ $ h l j k` and doubled (`dd cc yy`); `D C Y`; `s S`;
  `p P`; `u`, `Ctrl-R` redo; `i a I A o O` enter INSERT with the vim placement;
  `v` VISUAL, `V` line-VISUAL; counts `[1-9][0-9]*` before a motion or
  operator, capped at 999; `Enter` sends (chat convention, both modes);
  `Esc` → focus main. `Ctrl-R` is redo here and the run palette everywhere
  else, which is what a vim user expects.
- VISUAL: motions extend the selection; `d x` delete, `y` yank, `c` change,
  `Esc` → NORMAL.
- Not in v1, documented as such: `.` repeat, `f t ; ,`, `J`, `~`, `r`, `>` `<`,
  registers other than the unnamed one, marks, macros.

Editor gets the vim primitives as closed operations so one key stays one
action: movements `:word_end`, `:first_nonblank`; operations
`{:delete, motion | :line | :selection}`, `{:yank, motion | :line | :selection}`,
`:put_after`, `:put_before`, `{:times, 1..999, op}`; an unnamed `register` on
the `Editor` struct, filled by delete and yank.

**Status bar**: left segment is the mode when vim is on (`NORMAL`, `INSERT`,
`VISUAL`) or the focus otherwise; then the pending keys/count (vim showcmd);
then hints picked from the table by `hint` priority for the current context,
as many as `Density.budget(class).bindings` allows.

**Help sheet** (`?`/`F1`): generated from the table for the current context
plus `:global`, grouped by `group`, two columns at ≥ 100 cells, one column
below, scrollable with the dialog scroll keys, closes on `Esc`/`q`/`?`.

**Palette**: `Ctrl-K` entries show their key on the right when the table has
one for their target.

**Docs**: `docs/keybindings.md` is written by `mix swarm_code.keymap` from the
table; a test asserts the checked-in file equals the generated output.

## Phases and ownership

Phase 1 runs two agents in parallel on disjoint files. Phase 2 runs two agents
in parallel after both Phase 1 agents finish. Phase 3 is adversarial review
through the real input-to-pixels pipeline, then repair.

### Phase 1A — table, resolver, grammar (owns keymap, actions, state, reducer)

Files: `ui/keymap.ex`, new `ui/keymap/bindings.ex`, `ui/keymap/context.ex`,
`ui/keymap/special.ex`, new `ui/vim.ex` (struct only: `mode`, `pending`,
`count`; logic comes in 2C), `ui/action.ex`, `ui/state.ex`, `ui/reducer.ex`,
`ui/reducer/pages.ex`, `ui/scroll_operation.ex`, `ui/scroll.ex`,
`ui/layer_spec.ex` if needed, `ui/projector/dialog.ex` only for the `:jump`
popup rows, and tests under `test/swarm_code_cli/ui/` for those.

Adds: `State.keymap` (`:default`), `State.vim` (`%Vim{}`), actions
`{:set_keymap, :default | :vim}`, `{:run_tab, :next | :previous | 1..4}`,
`{:inspector_tab, :next | :previous}`, `{:toggle_expand, id}` (or reuse
`{:expand, id, bool}` from the resolver), `{:half_page, ±1}` scroll operation
and its `Scroll.apply` clause. Removes `:back` from `Esc`. Rewrites
`keymap_test.exs` around the table. Adds `bindings_test.exs`: no collisions per
context; every binding resolves to its declared action from a representative
state of each context (`Fixtures.representative/3` and hand-built states);
every binding has a label and help line; every context has at least one hint
binding. Updates the tests that assumed `Alt-1..4` set inspector tabs and that
`Esc` in main is `:back`, each with a one-line justification in the diff.

Must verify `Pages.scroll` honours `{:line, n}`; wire it if not.

Must check whether `{:region_filter, _}` filters anything; if not, unbind `/`
in main and say so in the report.

### Phase 1B — editor vim primitives (owns editor)

Files: `ui/editor.ex`, `ui/editor/operation.ex`, `ui/editor/*` as needed,
`test/swarm_code_cli/ui/editor_test.exs` (extend, do not weaken).

Adds the movements and operations listed under "Editor gets the vim
primitives". `{:delete, motion}` is extend-selection-then-delete in one
operation and records one undo record; `{:delete, :line}` removes the line and
its newline (or the preceding newline on the last line, as vim); delete and
yank both fill `register`; `put_after` inserts the register after the cursor
(a line register goes on a new line below, as vim); `{:times, n, op}` folds
the op `n` times and is one undo record. `{:delete, :selection}` with no
selection is a no-op. Everything stays within `max_bytes`; a put that would
exceed it is rejected as `{:error, :fragment_too_large}` through `admit/1`.

### Phase 2C — vim resolver, mode transitions, toggle (owns vim logic)

Files: new `ui/keymap/vim.ex`, `ui/vim.ex` (fill in), `ui/keymap.ex` only at
the composer seam, `ui/reducer.ex` (vim transitions, `:set_keymap`),
`ui/action.ex` (vim actions), `ui/switcher.ex` (the "Vim mode" entry and key
labels from `Bindings.key_for/2`), `ui/init.ex` or wherever `SWARM_*` is read
for `SWARM_KEYMAP`, `test/swarm_code_cli/ui/vim_test.exs`.

`Keymap.Vim.resolve(code, mods, phase, state)` is pure: it reads
`state.vim` and returns `{:ok, action}` or `:ignore`. Pending operator and
count are stored through actions (`{:vim, {:pending, "d"}}`,
`{:vim, {:count, 12}}`, `{:vim, {:mode, :normal}}`) so the reducer owns state
and a keystroke is still one action. Where one vim key needs an editor
operation *and* a mode change (`cw`, `o`, `s`), use one compound action
`{:vim, {:edit_then, op, mode}}` the reducer applies in order.

`vim_test.exs` drives the real pipeline: build a state, feed
`Input.text_fragment`s through `Keymap.resolve/3` and `Reducer`, assert the
draft text, cursor and mode after sequences such as `i hello Esc 0 dw p u`,
`3j`, `d3w`, `cc`, `A`, `o`, `v e d`, `Ctrl-R`. A test that only asserts the
action tuple is not enough.

### Phase 2D — help sheet, status bar, tabline hint, docs (owns presentation)

Files: `ui/projector/dialog.ex` (`:help`), `ui/projector/status.ex`,
`ui/projector/shell.ex` (tabline hint from the table), `ui/safe_text.ex` for
any new chrome tokens, new `lib/mix/tasks/swarm_code.keymap.ex`,
`docs/keybindings.md`, tests: help renders every binding of the current
context (assert through `Paint.build` on the painted grid, not on block
structure), fits without overflow at 80×24, 100×30 and 170×40, status shows
`NORMAL`/`INSERT`/`VISUAL` and pending keys when vim is on, doc sync test.

Do not touch `switcher.ex` (2C owns it).

### Phase 3E — review and recheck

Read the diff, then drive scenarios through `Keymap.resolve` + `Reducer` and
through `Projector.project` + `Paint.build` on the painted grid:

1. `Esc` from every context never yields `:back` and never navigates.
2. `q` never yields `{:quit_requested, _}` while any layer is open.
3. The dashboard: `Ctrl-G`, type `sw`, `Ctrl-N`, `Enter` navigates to a swarm.
4. `g` `t` cycles runs in stable order and comes back to the start after N.
5. `[`/`]` in a docked inspector changes `state.tabs.inspector`.
6. Vim: from main, `i`, type `hello world`, `Esc`, `0`, `dw`, `p`, `u`,
   `Enter` sends "hello world".
7. `?` at 80×24 and 170×40: every row inside the dialog, nothing wraps, every
   binding for the context appears exactly once.
8. Status bar at every layout class shows the right number of hints and never
   overflows its row.
9. `bindings_test` collision check is real: temporarily add a duplicate and
   see it fail.
10. Known environmental failures only: `locked_branch_test` (prod release),
    `Backup.GateTest` under full-suite load.

Report defects with file:line and a failing input; fix what is confirmed.

## Outcome (2026-09-16)

Implemented as planned, with these deviations, each for a reason found while
building it:

- `Ctrl-B` stays the inspector toggle. It is on screen and has no Ctrl-free
  twin; vim paging in the transcript is `Ctrl-D`/`Ctrl-U` plus PgUp/PgDn.
- `/` in main is unbound. `{:region_filter, _}` applied its query to nothing
  and opened a second command palette titled "Search"; a key that visibly does
  nothing is worse than no key.
- `Enter` is two rows, `:activate` and `:send`, so the status bar and the
  sheet can say "Send" in the composer without a per-context label field.
- `hint` is an integer or a per-context keyword list. `Esc` must not be hinted
  in main, where it declines, and `?` must not be hinted in the composer, where
  it types, so a single weight was not enough. A hinted key is always one the
  resolver routes in that context (`Bindings.key_in_context/2`).
- The help sheet goes two-column at 130 inner cells, not 100: at 100 a second
  column left under 40 cells per help line and elided most of them. Its box is
  wider and taller than a prompt dialog (150 × rows − 2) so a context's whole
  grammar fits one screen at 170 columns.
- The key column of the sheet is capped at 24 cells; a chord with four
  spellings is elided rather than allowed to cost every other row its text.
- `Ctrl-Shift-Z` prints as `Ctrl-Shift-Z`: the key formatter drops `:shift`
  only when an uppercase letter already carries it, so undo and redo no longer
  print the same key.
- The command palette does not yet print each entry's key on the right; the
  "Vim mode: on/off" entry is there. Left for a follow-up.
- Vim's `cc` and `S` ignore a count. `x` at the end of a line does nothing
  rather than joining lines (the caret sits between graphemes, not on one).

## Not in scope

`/vim` as a slash command (the catalogue is in `swarm_code_core`, shared with
the web); persisting the preference to disk; mouse; `Ctrl-Shift` chords that
need the kitty protocol; vim features listed as v2 above.
