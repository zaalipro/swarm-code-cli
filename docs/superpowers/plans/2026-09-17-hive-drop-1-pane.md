# Hive drop 1: the pane, card for card — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The inspector's Agents tab draws the web app's agent cards (lead card, sub-agent grid, operations drawer, verdict, waiting card) at two fidelity tiers, every frame is painted atomically, and the gallery renders the new states.

**Architecture:** A `glyph_tier` capability (`:measured | :rich`) flows into `Paint.Options`; `Projector.Support.glyph/2` resolves every token for the tier so projectors never branch. The painter (`Paint.Blocks`) gains half-row surface edges, a smooth gradient gauge, a sparkline chart and a `Columns` block. A new `Projector.Inspector.Agents` module composes those blocks into the cards from read-model facts the client already holds (agents, transcript tool items, interactions, verdicts). The Rust port brackets each paint in DEC 2026.

**Tech Stack:** Elixir 1.18 / OTP 28 umbrella under `mise exec --`; Rust terminal port under `native/terminal_port` (cargo via `scripts/dev/check_terminal_port.sh`); ExUnit.

**Spec:** `docs/superpowers/specs/2026-09-17-hive-card-for-card-design.md`

## Global Constraints

- All work in `/Users/zaali/dev/swarm-code-cli`. `~/dev/swarm-code` is read-only reference; never modify it.
- Run tests from the umbrella root: `cd /Users/zaali/dev/swarm-code-cli && unset MIX_QUIET && mise exec -- mix test apps/swarm_code_cli/test/<path>`. Never `mix cmd --app`. `mise exec -- mix format` before every commit. `locked_branch_test` fails while `_build/prod` exists; that is expected and must not be "fixed" by deleting `_build/prod`.
- Never weaken or delete an existing assertion to make a test pass; rewrite the test only where this plan says the behaviour changes, and say so in the commit message.
- New glyphs: rich tokens measure 1 under `:narrow`; measured and ASCII twins measure 1 under both `:narrow` and `:wide` (`SwarmCodeCLI.UI.Width.cells/2`). Never use `● ◎ ▤ × ◆ ◑ ⛨ ▥` (ambiguous width).
- Colour tokens only from `UI.Theme` roles; no invented hex except the one new role in Task 1.
- Plain words on screen: never `NEEDS n`, `OK ACCEPTED`, `Focus:`; a zero count is never shown.
- Commit after each task with `git add <files>` (never `git add -A`; the root `test/` folder stays untracked). Commit messages end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Do not push.
- Keybindings live only in `UI.Keymap.Bindings`; after changing them run `cd apps/swarm_code_cli && mise exec -- mix swarm_code.keymap --write`. Never bind Ctrl-K.

---

### Task 1: The fidelity tier and the glyph vocabulary

**Files:**
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/capabilities.ex` (struct, `@defaults`, `from_probe/1`, `validate_options!/1`)
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/paint/options.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ratatui_port/owner.ex:90` (Options built from capabilities), `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/workspace.ex:60`, `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/workspace/turns.ex:500`, `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/dialog.ex:81`, `apps/swarm_code_cli/lib/swarm_code_cli/ui/transcript.ex:19`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/theme.ex` (new role `:text_ghost`), `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/style.ex` (roles list)
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/safe_text.ex` (new tokens), `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/support.ex` (`@ascii_glyphs`, new `@measured_glyphs`, `glyph/2`)
- Test: `apps/swarm_code_cli/test/swarm_code_cli/ui/capabilities_test.exs`, `apps/swarm_code_cli/test/swarm_code_cli/ui/theme_test.exs`, create `apps/swarm_code_cli/test/swarm_code_cli/ui/glyph_tier_test.exs`

**Interfaces:**
- Produces: `Capabilities.glyph_tier :: :measured | :rich` (default `:measured`); `Paint.Options.glyph_tier` (same, default `:measured`); `Theme.style(:text_ghost, caps)`; SafeText tokens `:eighth_1 .. :eighth_7` (`▏▎▍▌▋▊▉`), `:block_full` (`█`), `:half_lower` (`▄`), `:half_upper` (`▀`), `:vert_1 .. :vert_7` (`▁▂▃▄▅▆▇`), `:dash_rule` (`┄`) with no ASCII twins of their own, plus measured tokens `:copy_mark` (`⧉`), `:ops_mark` (`≣`), `:command_mark` (`⌘`) each with a `_ascii` twin; `Support.glyph(token, state)` resolving by `state.capabilities.ascii?` (a rich token goes through its measured twin's ASCII form) then `state.capabilities.glyph_tier`; `Support.measured_glyphs/0` returning the rich → measured twin map.

- [ ] **Step 1: Write the failing capability tests** ✅

Append to `capabilities_test.exs` (use the existing probe helper in that file; if it builds probes with `%Probe{}` literals, copy that shape):

```elixir
  describe "glyph_tier" do
    test "defaults to :measured" do
      caps = Capabilities.explicit(%Size{columns: 80, rows: 24}, [])
      assert caps.glyph_tier == :measured
    end

    test "ghostty with truecolor and the narrow policy is :rich" do
      probe = probe(term: "xterm-ghostty", colorterm: "truecolor", stdout_tty?: true, stdin_tty?: true, controlling_tty?: true)
      assert Capabilities.from_probe(probe).glyph_tier == :rich
    end

    test "the wide policy, ASCII, or a 256-colour terminal stay :measured" do
      base = [term: "xterm-ghostty", colorterm: "truecolor", stdout_tty?: true, stdin_tty?: true, controlling_tty?: true]
      assert Capabilities.from_probe(probe(base ++ [ambiguous_width: :wide])).glyph_tier == :measured
      assert Capabilities.from_probe(probe(base ++ [ascii?: true])).glyph_tier == :measured
      assert Capabilities.from_probe(probe(term: "xterm-256color", colorterm: nil, stdout_tty?: true, stdin_tty?: true, controlling_tty?: true)).glyph_tier == :measured
    end

    test "explicit rejects an unknown tier" do
      assert_raise ArgumentError, fn -> Capabilities.explicit(%Size{columns: 80, rows: 24}, glyph_tier: :pixels) end
    end
  end
```

`probe/1` is whatever helper the file already uses to build a `%Capabilities.Probe{}` with defaults; if none exists, add one that starts from `%Probe{size: %Size{columns: 80, rows: 24}, ...all booleans false, term: "xterm", colorterm: nil, ambiguous_width: nil, enhanced_keys: :unavailable, focus: :unavailable, paste: :unavailable, alternate_screen: :unavailable, paste_preallocation_bound?: false}` and `struct!/2`s the overrides.

- [ ] **Step 2: Run them to see them fail**

Run: `unset MIX_QUIET && mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/capabilities_test.exs`
Expected: failures on `glyph_tier` (KeyError / unknown option).

- [ ] **Step 3: Add the capability**

In `capabilities.ex`: add `glyph_tier: :measured` to `defstruct`, `@type t`, and `@defaults`; add `@type glyph_tier :: :measured | :rich`; in `validate_options!/1` add `validate_member!(options, :glyph_tier, [:measured, :rich])`; in `from_probe/1` compute

```elixir
    tier =
      if mode == :truecolor and width == :narrow and not probe.ascii? and
           rich_terminal?(probe.term),
         do: :rich,
         else: :measured
```

and pass `glyph_tier: tier` to `explicit/2`, with

```elixir
  defp rich_terminal?(term) when is_binary(term) do
    components = String.split(term, "-")
    Enum.any?(components, &(&1 in ~w[ghostty kitty wezterm iterm iterm2]))
  end

  defp rich_terminal?(_), do: false
```

- [ ] **Step 4: Add the paint option and thread it through**

`paint/options.ex`: `defstruct color_mode: :truecolor, ascii?: false, glyph_tier: :measured`; validate `map_size(options) == 4` and `tier in [:measured, :rich]`. At every `%Options{...}` site that builds from capabilities add `glyph_tier: capabilities.glyph_tier` (whatever the local variable is called): `ui/renderer/ratatui_port/owner.ex:90`, `ui/projector/workspace.ex:60`, `ui/projector/workspace/turns.ex:500`, `ui/projector/dialog.ex:81`, `ui/transcript.ex:19`. `demo/cells.ex:118` keeps the default for now (Task 6 extends its examples). Grep `%Options{` under `lib` afterwards to be sure none is missed. `Paint.Metrics.height/5` and `demo/plain.ex` keep the default.

- [ ] **Step 5: Add `:text_ghost` to the theme**

In `theme.ex` beside `:text_faint`:

```elixir
  defp base_style(:text_ghost, mode),
    do: %Style{foreground: color(mode, 0x4B4A48, 239, :bright_black)} |> cue(:text_ghost, mode)
```

Add `:text_ghost` wherever `:text_faint` is listed as a role (`scene/style.ex` roles, `Theme.roles`, any `cue/2` table). In `theme_test.exs` add a test that `Theme.style(:text_ghost, %Capabilities{size: nil, color_mode: :truecolor}).foreground == {:rgb, 75, 74, 72}` (match the file's existing assertion style for colours).

- [ ] **Step 6: Write the failing glyph test**

Create `glyph_tier_test.exs`:

```elixir
defmodule SwarmCodeCLI.UI.GlyphTierTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Capabilities, SafeText, Size, Width}
  alias SwarmCodeCLI.UI.Projector.Support

  @rich [:eighth_1, :eighth_2, :eighth_3, :eighth_4, :eighth_5, :eighth_6, :eighth_7, :block_full,
         :half_lower, :half_upper, :vert_1, :vert_2, :vert_3, :vert_4, :vert_5, :vert_6, :vert_7,
         :dash_rule]
  @measured [:copy_mark, :ops_mark, :command_mark]

  defp state(opts), do: %{capabilities: struct!(Capabilities, [size: %Size{columns: 80, rows: 24}] ++ opts)}

  test "every rich token measures one cell under the narrow policy and has both twins" do
    for token <- @rich do
      value = SafeText.value(SafeText.chrome(token))
      assert Width.cells(value, :narrow) == 1, "#{token} is not one cell"
      measured = Map.fetch!(Support.measured_glyphs(), token)
      mv = SafeText.value(SafeText.chrome(measured))
      assert Width.cells(mv, :narrow) == 1 and Width.cells(mv, :wide) == 1, "#{measured} twin"
      av = SafeText.value(Support.glyph(token, state(ascii?: true, glyph_tier: :rich)))
      assert av =~ ~r/^[ -~]$/, "#{token} must have a one-character ASCII form"
    end
  end

  test "every measured token is one cell under both policies with an ASCII twin" do
    for token <- @measured do
      value = SafeText.value(SafeText.chrome(token))
      assert Width.cells(value, :narrow) == 1 and Width.cells(value, :wide) == 1
      assert SafeText.value(SafeText.chrome(Map.fetch!(Support.glyphs(), token))) =~ ~r/^[ -~]$/
    end
  end

  test "glyph/2 resolves a rich token by tier" do
    assert SafeText.value(Support.glyph(:block_full, state(glyph_tier: :rich))) == "█"
    assert SafeText.value(Support.glyph(:block_full, state(glyph_tier: :measured))) == "▐"
    assert SafeText.value(Support.glyph(:block_full, state(ascii?: true, glyph_tier: :rich))) == "#"
    assert SafeText.value(Support.glyph(:dash_rule, state(glyph_tier: :measured))) == "▬"
  end
end
```

- [ ] **Step 7: Run it to see it fail**

Run: `unset MIX_QUIET && mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/glyph_tier_test.exs`
Expected: FunctionClauseError on `SafeText.chrome/1`.

- [ ] **Step 8: Add the tokens**

In `safe_text.ex`, following the exact pattern of `:stripe` (its `@type token` entry near line 183, its `chrome/1` clause near line 427, and its `value/1` clause guarded by `map_size(text) == 2`; grep `:stripe` to find all three), add: `eighth_1`..`eighth_7` → `"▏" "▎" "▍" "▌" "▋" "▊" "▉"`; `block_full` → `"█"`; `half_lower` → `"▄"`; `half_upper` → `"▀"`; `vert_1`..`vert_7` → `"▁" "▂" "▃" "▄" "▅" "▆" "▇"`; `dash_rule` → `"┄"`; `copy_mark` → `"⧉"`; `ops_mark` → `"≣"`; `command_mark` → `"⌘"`; and ASCII twins only for the three measured tokens: `copy_mark_ascii` → `"c"`, `ops_mark_ascii` → `"="`, `command_mark_ascii` → `"$"`. Rich tokens get no ASCII twin: the existing test "every catalogue glyph has a one-cell ASCII twin" iterates `Support.glyphs()` and requires one cell under both policies, which a rich token cannot satisfy, so a rich token under ASCII resolves through its measured twin (whose ASCII twin already exists). If `safe_text_test.exs` pins the token count or enumerates tokens, extend it.

In `support.ex`:

```elixir
  # Rich tokens (eighth blocks, half blocks, the dashed rule) are East Asian
  # Ambiguous: one cell under the narrow policy, two under the wide one. A
  # measured twin stands in for each below tier :rich.
  @measured_glyphs %{
    eighth_1: :stripe, eighth_2: :stripe, eighth_3: :stripe, eighth_4: :stripe,
    eighth_5: :stripe, eighth_6: :stripe, eighth_7: :stripe, block_full: :stripe,
    half_lower: :corner_tl, half_upper: :corner_bl,
    vert_1: :dot_small, vert_2: :dot_small, vert_3: :dot_small, vert_4: :seg_on,
    vert_5: :seg_on, vert_6: :seg_on, vert_7: :seg_on, dash_rule: :rule
  }
```

extend `@ascii_glyphs` with the three measured tokens only (`copy_mark: :copy_mark_ascii`, `ops_mark: :ops_mark_ascii`, `command_mark: :command_mark_ascii`), and replace `glyph/2` with:

```elixir
  def glyph(token, %{capabilities: %{ascii?: true}} = state)
      when is_map_key(@measured_glyphs, token),
      do: glyph(Map.fetch!(@measured_glyphs, token), state)

  def glyph(token, %{capabilities: %{ascii?: true}}) when is_map_key(@ascii_glyphs, token),
    do: SafeText.chrome(Map.fetch!(@ascii_glyphs, token))

  def glyph(token, %{capabilities: %{glyph_tier: :rich}}), do: SafeText.chrome(token)

  def glyph(token, _state) when is_map_key(@measured_glyphs, token),
    do: SafeText.chrome(Map.fetch!(@measured_glyphs, token))

  def glyph(token, _state), do: SafeText.chrome(token)

  def measured_glyphs, do: @measured_glyphs
```

(`half_lower` at measured tier becomes `▗`, which the painter uses only as a corner; the mapping only has to be one measured cell.)

- [ ] **Step 9: Run the three test files, then the whole CLI suite**

Run: `unset MIX_QUIET && mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/glyph_tier_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/capabilities_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/theme_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/safe_text_test.exs`, then `unset MIX_QUIET && mise exec -- mix test apps/swarm_code_cli`
Expected: green except the known `locked_branch_test`.

- [ ] **Step 10: Format and commit**

```bash
mise exec -- mix format
git add apps/swarm_code_cli/lib/swarm_code_cli/ui/capabilities.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/paint/options.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/theme.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/style.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/safe_text.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/support.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/renderer/ratatui_port/owner.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/workspace.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/transcript.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/workspace/turns.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/dialog.ex apps/swarm_code_cli/test/swarm_code_cli/ui/capabilities_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/theme_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/glyph_tier_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/safe_text_test.exs
git commit -m "feat(ui): a glyph tier for rich terminals, with measured and ASCII twins

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Synchronized output in the Rust port

**Files:**
- Modify: `native/terminal_port/src/output.rs:147-212` (`paint`)
- Test: same file, new `#[cfg(test)] mod sync_tests`

**Interfaces:**
- Produces: every painted frame is wrapped in `ESC [ ? 2026 h` … `ESC [ ? 2026 l`; an unchanged frame writes nothing.

- [ ] **Step 1: Write the failing test**

At the bottom of `output.rs`:

```rust
#[cfg(test)]
mod sync_tests {
    use super::*;
    use std::num::NonZeroU16;

    fn painted(symbol: &str) -> Painted {
        let mut buffer = Buffer::empty(Rect::new(0, 0, 2, 1));
        let cell = &mut buffer[(0, 0)];
        cell.set_symbol(symbol);
        cell.diff_option = CellDiffOption::ForcedWidth(NonZeroU16::new(1).unwrap());
        Painted { buffer, cursor: None }
    }

    #[test]
    fn a_painted_frame_is_bracketed_in_synchronized_update_mode() {
        let mut out = Vec::new();
        paint(None, &painted("x"), &mut out).unwrap();
        let text = String::from_utf8_lossy(&out);
        assert!(text.starts_with("\x1b[?2026h"), "opens the bracket first: {text:?}");
        assert!(text.ends_with("\x1b[?2026l"), "closes it last: {text:?}");
    }

    #[test]
    fn an_unchanged_frame_writes_nothing() {
        let first = painted("x");
        let mut out = Vec::new();
        paint(Some(&first), &painted("x"), &mut out).unwrap();
        assert!(out.is_empty(), "{:?}", String::from_utf8_lossy(&out));
    }
}
```

If `Painted`, `Buffer`, `Rect` or `CellDiffOption` are not in scope under those names, use the names the file already imports (they are all used by `paint`/`project`).

- [ ] **Step 2: Run it to see it fail**

Run: `cd /Users/zaali/dev/swarm-code-cli && scripts/dev/check_terminal_port.sh`
Expected: the first test fails on the missing bracket (the second may already pass).

- [ ] **Step 3: Bracket the paint**

In `paint`, where the first dirty row hides the cursor:

```rust
        if !painted {
            writer.write_all(b"\x1b[?2026h")?;
            command(writer, Hide)?;
            painted = true;
        }
```

and at the very end of `paint`, after the cursor block and before `Ok(())`:

```rust
    if painted {
        writer.write_all(b"\x1b[?2026l")?;
    }
```

Note the cursor block runs when `painted || cursor changed`; a cursor-only change stays unbracketed, which is fine (one cursor move cannot tear).

- [ ] **Step 4: Run the port checks**

Run: `scripts/dev/check_terminal_port.sh`
Expected: fmt clean, all tests pass, licence check passes.

- [ ] **Step 5: Commit**

```bash
git add native/terminal_port/src/output.rs
git commit -m "feat(port): bracket every painted frame in synchronized update mode

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Three tabs, Agents first

**Files:**
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/keymap/bindings.ex:75` (`@inspector_tabs`)
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/inspector.ex` (`project/3`, `tab/1`, `strip/3`; remove `thread/5`)
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/reducer.ex:99-127` (`:set_tab`, `:inspector_tab`)
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/layer_spec.ex:6` (`inspector_tab` type keeps `:overview`)
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/dialog.ex:529` only if it branches on `:thread`
- Test: `apps/swarm_code_cli/test/swarm_code_cli/ui/inspector_cards_test.exs` (tab tests), `apps/swarm_code_cli/test/swarm_code_cli/ui/keymap_test.exs:678-691`
- Regenerate: `docs/keybindings.md` via `mix swarm_code.keymap --write`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `Bindings.inspector_tabs() == [:agents, :timeline, :changes]`; `Inspector.tab/1` returns one of those, mapping `:thread`, `:overview`, `nil` and unknown values to `:agents`; the strip paints the current tab bold on the `:hover` surface and a solid amber count (`Theme.style(:on_warn, ..)`) after `agents` when interactions of the run are pending; `Inspector.project/3` calls `Hive.panel/5` for `:agents` (Task 5 swaps it for the cards) and keeps `Verdict.card/3` after it on a judged run.

- [ ] **Step 1: Update the tests first**

In `inspector_cards_test.exs`, the tab test that iterates `[:thread, :agents, :timeline, :changes]` becomes `[:agents, :timeline, :changes]`, and every `tab: :thread` option in that file becomes `tab: :agents`. In `keymap_test.exs:678-691` replace `:thread` with `:agents` (the test asserts `[`/`]` rotation lands on the first tab). Grep for `:thread` under `apps/swarm_code_cli/test` and change only the inspector-tab uses (draft targets `{:thread, id}` are unrelated; leave them).

- [ ] **Step 2: Run them to see them fail**

Run: `unset MIX_QUIET && mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/inspector_cards_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/keymap_test.exs`
Expected: the tab tests fail (a `thread` action still exists; rotation lands on `:thread`).

- [ ] **Step 3: Change the table and the projector**

`bindings.ex`: `@inspector_tabs [:agents, :timeline, :changes]`.

`inspector.ex`:

```elixir
  def project(state, rect, class) do
    run = Support.run(state)
    tab = tab(state)
    width = rect.width
    height = max(0, rect.height - 1)
    opts = [stop?: class not in [:compressed_small, :too_small]]

    body =
      case tab do
        :agents -> agents(state, run, width, height, opts)
        :timeline -> Timeline.tab(state, run, width, height)
        :changes -> Changes.tab(state, run, width, height)
      end

    [strip(tab, state, run, width) | Enum.take(body, height)]
  end

  def tab(state) do
    case Map.get(state.tabs, :inspector, :agents) do
      tab when tab in [:agents, :timeline, :changes] -> tab
      _other -> :agents
    end
  end

  # The verdict of a judged run reads below the agents.
  defp agents(state, run, width, height, opts) do
    card = Verdict.card(state, run, width)
    Hive.panel(state, run, width, max(0, height - length(card)), opts) ++ card
  end
```

`strip/4`: keep one `Support.action(label, {:local, {:set_tab, tab}}, style)` per tab; the current tab's style is `%{RunRow.tinted(:accent, state) | modifiers: [:bold], background: Theme.style(:hover, state.capabilities).background}` and its label is padded with one space on each side (`" agents "`); the others use `Theme.style(:text_faint, state.capabilities)`. After the `agents` action, when `run` is not nil and `Enum.count(state.read_model.interactions, fn {_, i} -> i.state == :pending and i.run_id == run.id end) > 0`, insert a `%Span{text: Density.safe(" #{n} ", state, 4), style: Theme.style(:on_warn, state.capabilities)}` into the deck. (An `ActionDeck` accepts spans between actions; if it does not, wrap the count as an action with the `set_tab :agents` target.)

`reducer.ex`: `:set_tab` writes the tab into the layer unchanged (drop the `:thread`→`:overview` translation); `:inspector_tab` reads `current` through `Inspector.tab(state)` semantics: `Map.get(state.tabs, :inspector, :agents)` with `:overview` and `:thread` mapped to `:agents`.

`layer_spec.ex`: leave `:overview` in the type (saved layers may carry it); `Inspector.tab/1` already folds it. In `dialog.ex:529` the run-inspector overlay ignores the tab; verify with `grep -n ':thread\|:overview' apps/swarm_code_cli/lib -r` that nothing else depends on `:thread`.

- [ ] **Step 4: Run the tests, regenerate the keymap doc, run the suite**

Run: `unset MIX_QUIET && mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/inspector_cards_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/keymap_test.exs`, then `cd apps/swarm_code_cli && mise exec -- mix swarm_code.keymap --write && cd ../..`, then `unset MIX_QUIET && mise exec -- mix test apps/swarm_code_cli`
Expected: green except `locked_branch_test`; `docs/keybindings.md` may change only if its text mentions the tab list.

- [ ] **Step 5: Commit**

```bash
mise exec -- mix format
git add apps/swarm_code_cli/lib/swarm_code_cli/ui/keymap/bindings.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/inspector.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/reducer.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/layer_spec.ex apps/swarm_code_cli/test/swarm_code_cli/ui/inspector_cards_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/keymap_test.exs docs/keybindings.md
git commit -m "feat(ui): the inspector has three tabs, agents first, with the waiting count on the strip

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: The painter — half edges, smooth gauge, sparkline, columns

**Files:**
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/surface.ex`, `scene/block/gauge.ex`, `scene/block/chart.ex`, `scene/block.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/columns.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/paint/blocks.ex` (`@blocks`, Surface/Gauge/Chart clauses, new Columns clause, `gauge_glyph/2`, `surface_with_corners/4`)
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/paint/budget.ex` only if it validates block fields
- Test: create `apps/swarm_code_cli/test/swarm_code_cli/ui/paint/rich_blocks_test.exs`

**Interfaces:**
- Consumes: `Paint.Options.glyph_tier` and the tokens from Task 1 (`SafeText.chrome(:eighth_3)` etc.).
- Produces:
  - `%Block.Surface{blocks, tone, accent, rounded, edges: :corners | :half}` (default `:corners`).
  - `%Block.Gauge{tone, value, maximum, style: :ticks | :bar | :segments | :smooth, gradient_to: atom | nil, label}`.
  - `%Block.Chart{series, tone, height, label, style: :braille | :sparkline}`.
  - `%Block.Columns{columns: [%{width: pos_integer, blocks: [Block.t()]}], gap: non_neg_integer}` painting the columns side by side.

- [ ] **Step 1: Write the failing painter tests**

Create `rich_blocks_test.exs`. Paint through a one-region scene the way `inspector_cards_test.exs` does, or call `Blocks.lines/6` directly; the direct call is simplest:

```elixir
defmodule SwarmCodeCLI.UI.Paint.RichBlocksTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.Paint.{Blocks, Options}
  alias SwarmCodeCLI.UI.Scene.Block
  alias SwarmCodeCLI.UI.SafeText
  alias SwarmCodeCLI.UI.SafeText.Limits

  defp safe(text), do: elem(SafeText.external(text, Limits.content()), 1)

  @base %{foreground: {:rgb, 243, 242, 240}, background: {:rgb, 20, 20, 20}, modifiers: []}

  defp lines(blocks, width, tier, rows \\ 10) do
    {:ok, lines} =
      Blocks.lines(blocks, width, %Options{color_mode: :truecolor, glyph_tier: tier}, @base, rows, :narrow)
    Enum.map(lines, fn line -> Enum.map(line.units, &{&1.text, &1.style.foreground, &1.style.background}) end)
  end

  defp text(line), do: line |> Enum.map(&elem(&1, 0)) |> Enum.join()
  defp t(token), do: SafeText.value(SafeText.chrome(token))

  describe "Surface edges: :half" do
    test "rich paints half-block top and bottom rows in the surface colour over the outside" do
      [top, body, bottom] = lines([%Block.Surface{blocks: [%Block.Text{text: safe("hi")}], tone: :card, edges: :half}], 6, :rich)
      assert text(top) == t(:corner_tl) <> String.duplicate(t(:half_lower), 4) <> t(:corner_tr)
      assert text(bottom) == t(:corner_bl) <> String.duplicate(t(:half_upper), 4) <> t(:corner_br)
      {_, fg, bg} = Enum.at(top, 1)
      assert fg == {:rgb, 30, 30, 30} and bg == {:rgb, 20, 20, 20}
      assert String.starts_with?(text(body), " hi")
    end

    test "measured falls back to the quadrant corners" do
      [top | _] = lines([%Block.Surface{blocks: [], tone: :card, edges: :half}], 6, :measured)
      assert text(top) == t(:corner_tl) <> "    " <> t(:corner_tr)
    end
  end

  describe "Gauge :smooth" do
    test "rich fills whole cells with the full block and the boundary cell with an eighth" do
      [line] = lines([%Block.Gauge{tone: :accent, value: 30, maximum: 100, style: :smooth}], 10, :rich)
      # 30% of 10 cells = 3.0 cells: three full blocks, then track.
      assert text(line) == String.duplicate(t(:block_full), 3) <> String.duplicate(" ", 7)
      [line] = lines([%Block.Gauge{tone: :accent, value: 35, maximum: 100, style: :smooth}], 10, :rich)
      # 3.5 cells: three full, then the left-half block (eighth_4).
      assert text(line) == String.duplicate(t(:block_full), 3) <> t(:eighth_4) <> String.duplicate(" ", 6)
    end

    test "a gradient mixes the first and last lit cell between the two roles" do
      [line] = lines([%Block.Gauge{tone: :agent_lane_1, value: 100, maximum: 100, style: :smooth, gradient_to: :accent}], 10, :rich)
      {_, first, _} = List.first(line)
      {_, last, _} = List.last(line)
      assert first == {:rgb, 45, 212, 191}
      assert last == {:rgb, 255, 106, 26}
    end

    test "measured paints :smooth as ticks" do
      [line] = lines([%Block.Gauge{tone: :accent, value: 30, maximum: 100, style: :smooth}], 10, :measured)
      assert text(line) == String.duplicate(t(:stripe), 3) <> String.duplicate(t(:stripe_off), 7)
    end
  end

  describe "Chart :sparkline" do
    test "rich draws one vertical eighth per value, normalised to the peak" do
      [line] = lines([%Block.Chart{series: [0, 4, 8], tone: :accent, style: :sparkline}], 3, :rich)
      assert text(line) == " " <> t(:vert_4) <> t(:block_full)
    end

    test "measured falls back to braille" do
      [line] = lines([%Block.Chart{series: [0, 4, 8], tone: :accent, style: :sparkline}], 3, :measured)
      assert String.match?(text(line), ~r/^[\x{2800}-\x{28FF}]+$/u)
    end
  end

  describe "Columns" do
    test "zips two columns side by side, padding the shorter one" do
      left = [%Block.Text{text: safe("a")}, %Block.Text{text: safe("b")}]
      right = [%Block.Text{text: safe("c")}]
      rows = lines([%Block.Columns{columns: [%{width: 3, blocks: left}, %{width: 3, blocks: right}], gap: 1}], 7, :rich)
      assert Enum.map(rows, &text/1) == ["a   c  ", "b      "]
    end
  end
end
```

`safe/1` mirrors the helper in `test/swarm_code_cli/ui/paint/blocks_test.exs`.

- [ ] **Step 2: Run it to see it fail**

Run: `unset MIX_QUIET && mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/paint/rich_blocks_test.exs`
Expected: struct key errors (`edges`, `gradient_to`, `style`, `Columns`).

- [ ] **Step 3: Extend the block structs**

```elixir
# surface.ex
defstruct [:blocks, :accent, tone: :card, rounded: false, edges: :corners]
# gauge.ex
defstruct [:tone, :label, :gradient_to, value: 0, maximum: 0, style: :ticks]
@type style :: :ticks | :bar | :segments | :smooth
# chart.ex
defstruct [:series, :tone, :label, height: 1, style: :braille]
# columns.ex (new)
defmodule SwarmCodeCLI.UI.Scene.Block.Columns do
  alias SwarmCodeCLI.UI.Scene.Block
  @enforce_keys [:columns]
  defstruct [:columns, gap: 1]
  @type column :: %{width: pos_integer(), blocks: [Block.t()]}
  @type t :: %__MODULE__{columns: [column()], gap: non_neg_integer()}
end
```

Add `Columns` to `Block.modules/0`, the `@type t` union in `block.ex`, and `Blocks.@blocks`. Check `Paint.Budget.validate_scene/1` walks nested maps (columns are maps holding block lists); if it only descends into structs and lists, extend it to descend into plain maps' values.

- [ ] **Step 4: Paint them**

In `blocks.ex`:

`gauge_glyph/2` learns the tier: for `:stripe`/`:stripe_off`/`:seg_on`/`:seg_off` unchanged; add `rich?(ctx)`:

```elixir
  defp rich?(ctx), do: not ctx.options.ascii? and ctx.options.glyph_tier == :rich
```

Gauge clause: accept `style in [:ticks, :bar, :segments, :smooth]` and `gradient_to` nil or atom. When `style == :smooth and not rich?(ctx)` treat as `:ticks`. Smooth fill:

```elixir
  defp gauge_filled(:smooth, value, maximum, slots, tone, gradient_to, ctx) do
    eighths = div(min(value, maximum) * slots * 8, maximum)
    whole = div(eighths, 8)
    part = rem(eighths, 8)
    track = role(:ticks_track, ctx)
    track_bg = %{track | background: track.foreground}

    for i <- 0..(slots - 1) do
      lit = role(tone, ctx)
      lit = if gradient_to, do: mix_fg(lit, role(gradient_to, ctx), i / max(1, slots - 1)), else: lit

      cond do
        i < whole -> raw(t(:block_full), lit)
        i == whole and part > 0 -> raw(t(String.to_atom("eighth_#{part}")), %{lit | background: track.foreground})
        true -> raw(" ", track_bg)
      end
    end
  end

  defp mix_fg(%{foreground: {:rgb, r1, g1, b1}} = a, %{foreground: {:rgb, r2, g2, b2}}, t) do
    mix = fn x, y -> round(x + (y - x) * t) end
    %{a | foreground: {:rgb, mix.(r1, r2), mix.(g1, g2), mix.(b1, b2)}}
  end

  defp mix_fg(a, _b, _t), do: a
```

with `t/1` = `SafeText.value(SafeText.chrome(token))` (the painter deliberately uses the rich glyphs directly here because `rich?/1` gated the branch; under `:measured` the `:ticks` branch runs). Note `eighths` with `maximum == 0` never reaches here (the track branch handles it).

Surface: when `edges == :half and rich?(ctx)`, replace the corner rows: top row runs `[raw(t(:corner_tl), edge), raw(String.duplicate(t(:half_lower), fill), edge), raw(t(:corner_tr), edge)]` with `edge = %{foreground: bg_style.background, background: ctx.style.background, modifiers: []}`; bottom row the same with `:corner_bl`, `:half_upper`, `:corner_br`. The body rows reserve `rows - 2` exactly as `rounded: true` does. When `edges == :half and not rich?(ctx)` paint as `rounded: true`. When `edges == :corners` keep today's behaviour for both values of `rounded`.

Chart: when `style == :sparkline and rich?(ctx)`: one row, `peak = max(series) || 1`, for each value `level = round(value / peak * 8)`; glyph `" "` for 0, `t(:"vert_#{level}")` for 1..7, `t(:block_full)` for 8, styled `role(tone, ctx)`; take `ctx.width` values. Otherwise fall through to today's braille path with `height`.

Columns clause:

```elixir
  defp block(%Block.Columns{columns: columns, gap: gap}, ctx, rows)
       when is_list(columns) and columns != [] and is_integer(gap) and gap >= 0 do
    rendered =
      Enum.map(columns, fn %{width: width, blocks: blocks} when is_integer(width) and width > 0 ->
        blocks
        |> sequence(%{ctx | width: width}, rows)
        |> Enum.map(&pad_line(&1, ctx, ctx.style, width))
        |> then(&{width, &1})
      end)

    height = rendered |> Enum.map(fn {_, lines} -> length(lines) end) |> Enum.max()
    spacer = render([raw(String.duplicate(" ", gap), ctx.style)], %{ctx | width: max(gap, 1)}, 1)

    for row <- 0..(height - 1) do
      rendered
      |> Enum.map(fn {width, lines} ->
        Enum.at(lines, row) || pad_line(%{units: [], cells: 0}, ctx, ctx.style, width)
      end)
      |> Enum.intersperse(if gap > 0, do: hd(spacer), else: %{units: [], cells: 0})
      |> Enum.reduce(%{units: [], cells: 0}, fn part, acc ->
        %{units: acc.units ++ part.units, cells: acc.cells + part.cells}
      end)
    end
    |> Enum.take(rows)
  end
```

Guard `height == 0` (all columns empty) → `[]`.

- [ ] **Step 5: Run the painter tests, then the suite**

Run: `unset MIX_QUIET && mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/paint apps/swarm_code_cli/test/swarm_code_cli/ui/scene_contracts_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/primitives_test.exs`, then the whole `apps/swarm_code_cli`
Expected: green except `locked_branch_test`. If `scene_contracts_test` enumerates block modules or struct keys, extend its expectations for the new fields and `Columns`.

- [ ] **Step 6: Commit**

```bash
mise exec -- mix format
git add apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/surface.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/gauge.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/chart.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/scene/block/columns.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/paint/blocks.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/paint/budget.ex apps/swarm_code_cli/test/swarm_code_cli/ui/paint/rich_blocks_test.exs
git commit -m "feat(paint): half-row surface edges, a smooth gradient gauge, sparklines and columns

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: The Agents tab, card for card

**Files:**
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/inspector/agents.ex` (the tab), `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/inspector/ops.ex` (operation rows and tool families)
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/inspector.ex` (`agents/5` calls `Agents.tab/5`)
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/inspector/hive.ex` (keep `agents/2`, `lanes_for/2`, `total/2`, `glyph_token/1`, `lane_role/2`, `name/1`, `step/1`, `newest_running/1`, `run_words/2`, `cells/4`, `blank/1`, `fit/3`, `measure/2`, `lanes/6`, `lane/6`; `panel/5` may be deleted once nothing calls it)
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/action_target.ex` (allow `{:local, {:select_agent, id}}`), `apps/swarm_code_cli/lib/swarm_code_cli/ui/reducer.ex` (`{:select_agent, id}` transition), `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/support.ex` (`chip/4`)
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/fixtures.ex` (a pending approval on the swarm fixture for the `judge`-less waiting case is not needed; add `tool` items for `agent-1` so the lead card has chips, and give `hive_agents` a `:done` sub-agent so the grid shows a `✓`)
- Test: `apps/swarm_code_cli/test/swarm_code_cli/ui/inspector_cards_test.exs` ("hive lanes" describe rewritten as "agent cards"), `apps/swarm_code_cli/test/swarm_code_cli/ui/reducer_navigation_test.exs` (select_agent)

**Interfaces:**
- Consumes: Task 1 tokens via `Support.glyph/2` (`:agent_lead`, `:agent_sub`, `:assistant_mark`, `:judge`, `:dot`, `:check_mark`, `:close_mark`, `:chevron`, `:clock_mark`, `:branch_mark`, `:copy_mark`, `:ops_mark`, `:command_mark`, `:search_mark`, `:write_mark`, `:rule`, `:dash_rule`); Task 4 blocks (`Surface edges: :half`, `Gauge :smooth`, `Columns`); Task 3 `Inspector.tab/1`.
- Produces: `Agents.tab(state, run, width, height, opts) :: [Block.t()]`; `Ops.family(name) :: {token, role}`; `Ops.rows(state, agent, width, height) :: [Block.t()]`; reducer state `state.tabs[:agent]` (selected agent id) set by `{:local, {:select_agent, id}}`; `Support.chip(text, role, state, width)` returning a `%Span{}` padded with one space each side.

- [ ] **Step 1: Read the fixture and pin the expected rows**

Read `Fixtures.representative(:swarm, ...)`: five agents (`lead` planning 35 %, `scout-1` 70 %, `scout-2` 55 %, `builder-4` 40 %, `judge` waiting), `hive_items/1` tool items for agents 2, 3 (and any more), run model in `run_facts(:swarm)`. Extend the fixture so the design is exercised: give `agent-1` (the lead) two tool items (`grep`, `read_file`) with `tool.name` set; mark `scout-2` (`agent-3`) as `state: :done, progress: 100, finished_at: @clock_ms - 100_000`; keep everything else. Update any existing tests that pin scout-2 running (grep `scout-2` under `test/`).

- [ ] **Step 2: Write the failing card tests**

Replace the "hive lanes" describe in `inspector_cards_test.exs` with:

```elixir
  describe "agent cards" do
    test "the agents tab paints the lead card, the sub-agent grid and the operations drawer" do
      rows = rows(:swarm, 170, 34, tab: :agents)

      assert Enum.at(rows, 0) =~ ~r/^ agents 1 +timeline +changes/
      # The lead card: head, avatar rows, subtitle, run meta, chips, divider, task.
      assert Enum.any?(rows, &(&1 =~ ~r/^\S AGENT +stop$/))
      assert Enum.any?(rows, &(&1 =~ ~r/⬡ +lead +⬤ ACTIVE$/))
      assert Enum.any?(rows, &(&1 =~ ~r/LEAD AGENT · deepseek/))
      assert Enum.any?(rows, &(&1 =~ ~r/1\/4 sub-agents done · \d\d:\d\d · 22k tok/))
      assert Enum.any?(rows, &(&1 =~ ~r/ grep +read_file /))
      assert Enum.any?(rows, &(&1 =~ ~r/CURRENT TASK +35%/))
      assert Enum.any?(rows, &(&1 =~ ~r/planning +LEAD 7\.6k · SUBS 15k/))
      # The grid: two columns of mini cards.
      assert Enum.any?(rows, &(&1 =~ ~r/SUB-AGENTS +1 of 4 done · 1 waiting/))
      assert Enum.any?(rows, &(&1 =~ ~r/✦ scout-1 .*✦ scout-2 .*✓/))
      assert Enum.any?(rows, &(&1 =~ ~r/SUB · D1 .*SUB · D1/))
      assert Enum.any?(rows, &(&1 =~ ~r/3\.8k TOK +1 ops/))
      assert Enum.any?(rows, &(&1 =~ ~r/⚖ judge .*\?/))
      # The drawer follows the newest running sub-agent.
      assert Enum.any?(rows, &(&1 =~ ~r/OPERATIONS · builder-4/))
    end

    test "every sub-agent card is one action that selects it, and the lead card offers stop" do
      state = state(:swarm, 170, 34, tab: :agents)
      {_rows, table, _plan, _rect} = painted(state)

      for id <- ~w(agent-2 agent-3 agent-4 agent-5) do
        assert length(targets(table, {:local, {:select_agent, id}})) == 1
      end

      assert length(targets(table, {:intent, {:stop_agent, @run, "agent-1", 1}})) == 1
      assert length(targets(table, {:local, {:set_tab, :timeline}})) == 2
    end

    test "selecting an agent moves the drawer to it" do
      state = state(:swarm, 170, 34, tab: :agents)
      {state, []} = SwarmCodeCLI.UI.Reducer.update(state, {:select_agent, "agent-2"})
      {rows, _, _, _} = painted(state)
      assert Enum.any?(rows, &(&1 =~ ~r/OPERATIONS · scout-1/))
      assert Enum.any?(rows, &(&1 =~ ~r/⌕ +grep +lib\/ test\/ · 41 hits .*done +0\.4s/))
    end

    test "a waiting agent is painted in the warning colour and the strip counts it" do
      state = state(:swarm, 170, 34, caps: [color_mode: :truecolor], tab: :agents)
      {rows, _table, plan, rect} = painted(state, :truecolor)
      assert foreground(plan, rect, rows, "APPROVAL") == @warning or foreground(plan, rect, rows, "WAITING") == @warning
    end

    test "a chat run draws the assistant as the lead card with no sub-agents" do
      rows = rows(:chat, 170, 34, tab: :agents)
      assert Enum.any?(rows, &(&1 =~ ~r/✳ +assistant/))
      refute Enum.any?(rows, &(&1 =~ ~r/SUB-AGENTS/))
    end

    test "the narrow dock keeps the lead card and lists sub-agents as rows" do
      rows = rows(:swarm, 150, 30, tab: :agents)
      assert Enum.any?(rows, &(&1 =~ ~r/⬡ +lead/))
      assert Enum.any?(rows, &(&1 =~ ~r/^\S › ✦ scout-1 /))
    end

    test "ASCII keeps every row within the dock and uses the twins" do
      rows = rows(:swarm, 170, 34, caps: [ascii?: true], tab: :agents)
      refute Enum.any?(rows, &(&1 =~ ~r/[^\x00-\x7F]/))
      assert Enum.any?(rows, &(&1 =~ ~r/o +lead/))
    end
  end
```

Fix the exact numbers after reading the fixture: `22k tok` is the run total (`tokens_in + tokens_out`); `LEAD 7.6k` is the lead's own tokens (6120 + 1480), `SUBS 15k` the rest; `3.8k TOK` is scout-1 (3210 + 640); the `1 ops` count is its tool items. If the fixture differs, change the expected strings, not the design.

- [ ] **Step 3: Run them to see them fail**

Run: `unset MIX_QUIET && mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/inspector_cards_test.exs`
Expected: the new tests fail (rows still read `HIVE  …`).

- [ ] **Step 4: The action target and the reducer**

`action_target.ex`: add `{:select_agent, id}` when `is_binary(id)` to the accepted `{:local, _}` actions. `reducer.ex`:

```elixir
  defp transition(state, {:select_agent, id}) when is_binary(id),
    do: {%{state | tabs: Map.put(state.tabs, :agent, id)}, []}
```

Add to `reducer_navigation_test.exs`: `{state, []} = Reducer.update(state, {:select_agent, "agent-2"}); assert state.tabs.agent == "agent-2"`.

- [ ] **Step 5: `Support.chip/4`**

```elixir
  @doc "A chip: the text with one space each side in a tinted role, clipped to `width`."
  def chip(text, role, state, width) do
    inner = Density.safe(text, state, max(0, width - 2)) |> SafeText.value()
    %Span{text: Density.safe(" " <> inner <> " ", state, width), style: RunRow.tinted(role, state)}
  end
```

(`RunRow.tinted/2` resolves a theme role to a `%Style{}`; the chip roles are `:chip_accent`, `:chip_ok`, `:chip_warn`, `:chip_err`, `:chip_info`, and `:hover` for the neutral chip.)

- [ ] **Step 6: `Inspector.Ops`**

```elixir
defmodule SwarmCodeCLI.UI.Projector.Inspector.Ops do
  @moduledoc "Operation rows: the tool and thinking items of one agent, and the family a tool belongs to."
  alias SwarmCodeCLI.UI.{SafeText, Theme}
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  alias SwarmCodeCLI.UI.Projector.{Density, RunRow, Support}
  alias SwarmCodeCLI.UI.Projector.Inspector.{Hive, Words}

  @gauge 14

  @doc "The tool items of `agent`, oldest first."
  def items(state, agent) do
    state.read_model.transcript
    |> Map.values()
    |> Enum.filter(&(&1.agent_id == agent.id and &1.kind in [:tool, :thinking]))
    |> Enum.sort_by(&{&1.at, &1.created_sequence, &1.id})
  end

  @doc "The distinct tool names an agent has used, in first-use order."
  def tools(state, agent),
    do: state |> items(agent) |> Enum.map(&tool_name/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

  defp tool_name(%{kind: :tool, tool: %{name: name}}) when is_binary(name) and name != "", do: name
  defp tool_name(_), do: nil

  @doc "The glyph token and theme role of a tool family."
  def family(:thinking), do: {:assistant_mark, :text_faint}
  def family("run_command"), do: {:command_mark, :accent}
  def family("bash"), do: {:command_mark, :accent}
  def family("read_file"), do: {:ops_mark, :info}
  def family("list_dir"), do: {:ops_mark, :info}
  def family("grep"), do: {:search_mark, :run_goal}
  def family("web_search"), do: {:search_mark, :run_swarm}
  def family("write_file"), do: {:write_mark, :success}
  def family("edit_file"), do: {:write_mark, :success}
  def family("spawn_agent"), do: {:agent_sub, :run_swarm}
  def family(_), do: {:dot_small, :text_muted}

  @doc "One row per item, newest last, at most `height`."
  def rows(state, agent, width, height) do
    state |> items(agent) |> Enum.take(-max(0, height)) |> Enum.map(&row(&1, state, width))
  end

  defp row(item, state, width) do
    {token, role} = if item.kind == :thinking, do: family(:thinking), else: family(item.tool && item.tool.name)
    name = if item.kind == :thinking, do: "thinking", else: item.tool.name
    arg = if item.kind == :thinking, do: item.text, else: present(item.tool.detail) || item.tool.title
    duration = if item.kind == :tool, do: Words.duration(item.tool.duration_ms), else: nil
    status = if item.kind == :tool, do: item.tool.status, else: item.state
    running? = Words.running?(status)
    tail = tail(status, running?, duration, state)
    tail_cells = Enum.reduce(tail, 0, &(Hive.measure(SafeText.value(&1.text), state) + &2))
    chip = Support.chip(name, chip_role(role), state, Hive.measure(name, state) + 2)
    arg_width = max(0, width - 2 - Hive.measure(SafeText.value(chip.text), state) - 1 - tail_cells - 2)

    %Block.RichText{
      spans:
        [
          %Span{text: Support.glyph(token, state), style: %{RunRow.tinted(role, state) | modifiers: [:bold]}},
          RunRow.gap(1, state),
          chip,
          RunRow.gap(1, state),
          %Span{text: Hive.fit(arg || "", arg_width, state), style: Theme.style(:text_muted, state.capabilities)}
        ] ++ tail ++ [RunRow.gap(1, state), %Span{text: Support.glyph(:chevron, state), style: Theme.style(:text_faint, state.capabilities)}]
    }
  end

  # A running operation shows a short ticks gauge; a settled one its state chip; then the duration.
  defp tail(status, true, _duration, state) do
    on = SafeText.value(Support.glyph(:stripe, state))
    off = SafeText.value(Support.glyph(:stripe_off, state))
    lit = 5
    [
      RunRow.gap(1, state),
      %Span{text: Density.safe(String.duplicate(on, lit), state, lit), style: RunRow.tinted(:accent, state)},
      %Span{text: Density.safe(String.duplicate(off, @gauge - lit), state, @gauge - lit), style: RunRow.tinted(:ticks_track, state)},
      RunRow.gap(1, state),
      Support.chip("active", :chip_accent, state, 8)
    ]
  end

  defp tail(status, false, duration, state) do
    word = Words.state(status)
    role = case status, do: (:done -> :chip_ok; :failed -> :chip_err; _ -> :hover)
    [RunRow.gap(1, state), Support.chip(word, role, state, Hive.measure(word, state) + 2)] ++
      if duration, do: [RunRow.gap(1, state), %Span{text: Density.safe(duration, state, 6), style: Theme.style(:text_faint, state.capabilities)}], else: []
  end

  defp chip_role(:accent), do: :chip_accent
  defp chip_role(:info), do: :chip_info
  defp chip_role(:success), do: :chip_ok
  defp chip_role(_), do: :hover
  defp present(v) when is_binary(v) and v != "", do: v
  defp present(_), do: nil
end
```

A running op's gauge has no progress fact, so it paints a fixed five-of-fourteen band; the caret-sweep animation is drop 2. (The `Words.state/1` word for `:done` is `done`; keep it, the chip tint says the rest.)

- [ ] **Step 7: `Inspector.Agents`**

Compose with the blocks. Skeleton (fill every helper; nothing left as a stub):

```elixir
defmodule SwarmCodeCLI.UI.Projector.Inspector.Agents do
  @moduledoc "The Agents tab: the lead card, the sub-agent grid, the operations drawer, the verdict and the waiting card."
  alias SwarmCodeCLI.UI.{SafeText, Theme}
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  alias SwarmCodeCLI.UI.Projector.{Density, RunRow, Support}
  alias SwarmCodeCLI.UI.Projector.Inspector.{Hive, Ops, Verdict, Words}

  @grid_min 46      # two mini-card columns need this many cells
  @rows_over 10     # above this many sub-agents the grid becomes rows

  def tab(state, nil, width, _height, _opts), do: [Support.text("No run selected", state, width), Hive.blank(state), Support.text("Ctrl-G  all runs", state, width), Support.text("Ctrl-R  switch run", state, width)]

  def tab(state, run, width, height, opts) do
    agents = Hive.lanes_for(state, run)
    [lead | subs] = agents
    selected = selected(state, run, agents)

    lead_card = lead_card(state, run, lead, subs, width, opts)
    verdict = if Verdict.judged?(run), do: Verdict.card(state, run, width), else: []
    waiting = waiting_card(state, run, width)
    sub_section = if subs == [], do: [], else: [Hive.blank(state), sub_heading(state, subs, width)] ++ sub_cards(state, subs, width)
    drawer = [Hive.blank(state), ops_heading(state, selected, width)] ++ Ops.rows(state, selected, width, max(0, height - 20))

    (lead_card ++ waiting ++ verdict ++ sub_section ++ drawer) |> Enum.take(max(0, height))
  end
  ...
end
```

Rules the helpers must follow (the spec §5.1 is the source; these are the parts that need a decision):

- The lead card is `%Block.Surface{tone: :card, accent: lane_role, edges: :half, blocks: [...]}` whose inner rows are `RichText`s built with `Hive.fit/3`, `RunRow.gap/2`, `Support.chip/4`, and one `%Block.Gauge{tone: lane_role, value: progress, maximum: 100, style: :smooth, gradient_to: :accent}` (`gradient_to: nil` and `tone: status role` once `Words.finished?(state)`). The surface indents by two cells (rail + space), so inner width is `width - 2`. The head row's `stop` is `Support.action("stop", {:intent, {:stop_agent, run_id, id, revision}}, style)` only when `Support.allowed?(state, lead, :stop_agent)` and `opts[:stop?]`; the foot row holds `Support.action("◷ lanes", {:local, {:set_tab, :timeline}}, ..)` and `Support.action("⎇ diff", {:local, {:set_tab, :changes}}, ..)` (glyphs through `Support.glyph/2`, so ASCII gets `t`/`Y`).
- The avatar block is three rows of four cells on `:hover` with the glyph in the middle row; the name and status share the first of those rows, the subtitle the second, the run meta the third.
- Subtitle: `"LEAD AGENT · " <> (run.model || "")` for `:lead`; `"ROUND #{v.round} · JUDGING…"` for a judged run with `Verdict.newest/2` running; `"ASSISTANT · " <> model` for `:assistant`; `"JUDGE"` for `:judge`.
- Run meta: `"#{done}/#{total} sub-agents done · #{Words.clock(run.started_at)} · #{Words.tokens(run tokens)} tok"` dropping empty parts; `total = Hive.total(run, state) - 1` when it exceeds zero, else the section is omitted.
- Chips: `Ops.tools(state, lead)` first three as `Support.chip(name, :hover, ..)`, then `"+N"`; `"no tools yet"` in `:text_ghost` when empty.
- Divider: a `RichText` of `Support.glyph(:dash_rule, state)` repeated (measured tier yields `▬`, ASCII `-`), in `:ticks_track`.
- Task row: text = `Hive.step(lead)`; metric right-aligned: `"LEAD #{Words.tokens(lead)} · SUBS #{Words.tokens(sum subs)}"` when `subs != []`, else `"#{Words.tokens(lead)} TOKENS"`; never a `0k` (`Words.tokens/1` returns `"0k"` for zero, so test the count first and omit the metric when it is zero).
- Sub cards: `%Block.Columns{gap: 1, columns: [%{width: cw, blocks: [card]}, %{width: cw, blocks: [card]}]}` per pair with `cw = div(width - 1, 2)` when `width >= @grid_min and length(subs) <= @rows_over`; each card a `Surface{edges: :corners, accent: lane}` of three inner rows (`✦ name … mark`, `SUB · D<depth>[ · APPROVAL | · FAILED]`, gauge) plus a fourth row `"#{tokens} TOK"` / `"#{ops} ops"` (ops = `length(Ops.items(state, agent))`), wrapped as an action with `Support.action_spans/2` on the first row → `{:local, {:select_agent, agent.id}}`. Otherwise (narrow or many) a `Hive.lane/6`-style row on a one-row surface with `› ✦ name`, the state mark, a gauge and the elapsed/`approval` word, each row the same select action.
- Marks: done `check_mark` in `:success`; running `dot` in the lane role; waiting `"?"` in `:on_warn`; failed `close_mark` in `:error`; queued `hex_empty` in `:ticks_track`.
- `selected/3`: `state.tabs[:agent]` when it names an agent of this run, else `Hive.newest_running(subs)`, else the lead.
- `ops_heading/3`: `"OPERATIONS · " <> name` with the name in the agent's lane role and, right-aligned, `"#{n} ops"` when n > 0.
- `waiting_card/3`: for the first pending interaction of the run, `Surface{accent: :warning, edges: :corners}` with rows `? <agent> wants to run a command` (`asks a question` for `:question`), `$ <arguments_preview>` (or the question's prompt), the permission in words (`writes files` / `runs a command`), and a key row `y once · d deny · ↵ open`; the whole first row is `Support.action_spans(spans, {:local, {:open_interaction, id}})` (the existing navigation target used by `n`/`N`; check its exact spelling in `action_target.ex`/`reducer.ex` and use that).
- Every row is measured with `Hive.measure/2` and clipped with `Density.safe/3` so nothing exceeds `width`; a card that cannot fit its minimum (fewer than 6 rows left) is dropped whole, operations first, then the grid, then the verdict, then the waiting card, then the lead card's chips row.

- [ ] **Step 8: Wire the tab and delete the old panel**

`inspector.ex`: `agents/5` becomes `Agents.tab(state, run, width, height, opts)` (the verdict is inside). Remove `Hive.panel/5` and `Hive.summary/4`, `Hive.footer/3`, `Hive.heading/4` if nothing else calls them (grep `Hive.panel` under `lib` and `test`: the run-inspector overlay in `dialog.ex` does not; the companion does not). Update tests that called `Hive.panel` directly, if any.

- [ ] **Step 9: Run the inspector tests, then everything**

Run: `unset MIX_QUIET && mise exec -- mix test apps/swarm_code_cli/test/swarm_code_cli/ui/inspector_cards_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/reducer_navigation_test.exs`, then `unset MIX_QUIET && mise exec -- mix test apps/swarm_code_cli`
Expected: green except `locked_branch_test`. Tests elsewhere that pinned `HIVE  ` rows (grep `"HIVE` under `test/`) are rewritten to the card rows in the same spirit, never deleted.

- [ ] **Step 10: Commit**

```bash
mise exec -- mix format
git add apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/inspector/agents.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/inspector/ops.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/inspector.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/inspector/hive.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/action_target.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/reducer.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/support.ex apps/swarm_code_cli/lib/swarm_code_cli/ui/fixtures.ex apps/swarm_code_cli/test/swarm_code_cli/ui/inspector_cards_test.exs apps/swarm_code_cli/test/swarm_code_cli/ui/reducer_navigation_test.exs
git commit -m "feat(ui): the agents tab draws the lead card, the sub-agent grid and the operations drawer

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: The gallery renders the pane at both tiers

**Files:**
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/demo/cells.ex` (`@examples`, `render/1`, `filename/1`, an `:approval` fixture beside `:question`)
- Test: `apps/swarm_code_cli/test/swarm_code_cli/demo/cells_test.exs` (or wherever `Demo.Cells` is tested; `grep -rl "Demo.Cells" apps/swarm_code_cli/test`)

**Interfaces:**
- Consumes: `Capabilities.glyph_tier`, `Paint.Options.glyph_tier` (Task 1); the Agents tab (Task 5).
- Produces: `mix swarm_code.demo.cells` writes, in addition to today's files, `swarm-170x42-truecolor-rich.svg`, `swarm-170x42-truecolor-measured.svg`, `consensus-170x42-truecolor-rich.svg`, `approval-170x42-truecolor-rich.svg`, `swarm-150x30-truecolor-rich.svg`, all with the inspector on `:agents`.

- [ ] **Step 1: Extend the example tuple**

Examples become `{kind, {columns, rows}, mode, ascii?, tier}`; every existing example gets `:measured`; add the five above with `:rich`/`:measured` as listed. `render/1` builds `%Capabilities{size: size, color_mode: mode, ascii?: ascii?, glyph_tier: tier}` and `%Options{color_mode: mode, ascii?: ascii?, glyph_tier: tier}`, and sets `tabs: Map.put(state.tabs, :inspector, :agents)` on the state. `filename/1` appends `-rich` for the rich tier. `fixture(:approval, ..)` mirrors `fixture(:question, ..)` with a `%PendingInteraction{kind: :approval, approval: %DTO.Approval{tool: "run_command", permission: :execute, arguments_preview: "mix ecto.migrate"}, ...}` attached to the swarm fixture's `agent-4` run.

- [ ] **Step 2: Test and run**

Extend the cells test so the returned file list contains the five new names. Run it, then `cd apps/swarm_code_cli && mise exec -- mix swarm_code.demo.cells && cd ../..` and confirm the directory it prints holds the SVGs and `index.html`.

- [ ] **Step 3: Commit**

```bash
mise exec -- mix format
git add apps/swarm_code_cli/lib/swarm_code_cli/demo/cells.ex apps/swarm_code_cli/test
git commit -m "feat(demo): the cell gallery paints the agents tab at both glyph tiers

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Verification in the real terminal (orchestrator)

- Full umbrella suites (`core`, `daemon`, `cli`) and `mix format --check-formatted`.
- `scripts/dev/check_terminal_port.sh` green; rebuild the installed `swarmcode` with the port (`scripts/install.sh`) so synchronized output reaches the user's terminal.
- Capture the Agents tab from the real TUI under GNU screen (`/tmp/screen_live.sh` style) on the repo's saved conversation; read the hardcopy rows.
- Put the rich-tier SVG from the gallery and the capture on the companion (`.superpowers/brainstorm/23923-1789620273/content/drop-1-review.html`) beside the mock, and report.
