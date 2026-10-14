defmodule SwarmCodeCLI.UI.Home.OrbitTiersTest do
  @moduledoc """
  orbit U11: Home at every glyph tier, in the light theme, and at both
  ambiguous-width policies. Nothing here invents a colour: the roles are the
  theme's, and the tests look at what they resolve to.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.OrbitHelpers, only: [fixture: 2]

  alias SwarmCodeCLI.Cli020EHelpers, as: H
  alias SwarmCodeCLI.UI.{Projector, SafeText, Theme, Width}
  alias SwarmCodeCLI.UI.Home.Mark
  alias SwarmCodeCLI.UI.Paint
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}

  @sizes [{120, 36}, {80, 24}, {160, 44}, {110, 32}, {60, 16}]

  defp screen(size, caps, scene \\ :main) do
    size |> fixture(caps: caps, scene: scene) |> H.screen()
  end

  defp braille?(text), do: String.match?(text, ~r/[\x{2800}-\x{28FF}]/u)

  describe "the ASCII tier (D23)" do
    test "120 x 36 has no braille and none of the round glyphs, at every size" do
      for size <- @sizes, scene <- [:main, :first_run, :interact] do
        text = size |> screen([ascii?: true], scene) |> Enum.join("\n")
        refute braille?(text), "#{inspect(size)} #{scene} draws braille"
        refute String.match?(text, ~r/[●○▰▱]/u), "#{inspect(size)} #{scene} draws round glyphs"
      end
    end

    test "Home's own rows are plain ASCII" do
      rows = screen({120, 36}, ascii?: true)

      for row <- Enum.slice(rows, 0, 35) do
        assert String.match?(row, ~r/\A[\x20-\x7E]*\z/), "not ASCII: #{inspect(row)}"
      end
    end

    test "the orbits are lines with - rules and * o ! beads" do
      rows = screen({120, 36}, ascii?: true)
      assert Enum.at(rows, 5) =~ ~r/^  swarm-code-cli  -+!-+\*/
      assert Enum.at(rows, 5) |> String.ends_with?("  9")
      assert Enum.any?(rows, &(&1 =~ ~r/-o-/))
      assert Enum.at(rows, 9) =~ "now"
    end

    test "the gauge is [######----] and the selection bar is >" do
      rows = screen({120, 36}, ascii?: true)
      assert Enum.at(rows, 2) =~ "[######----] $38.40 of $60"
      assert Enum.at(rows, 2) =~ "()"
      assert Enum.at(rows, 0) =~ "> home"
      assert Enum.at(rows, 11) =~ "> 1 ! rate-limit chip wiring"
      refute Enum.any?(rows, &(&1 =~ "▌"))
    end

    test "the first run and the map focus have ASCII words too" do
      first = screen({120, 36}, [ascii?: true], :first_run)
      assert Enum.any?(first, &(&1 =~ "Ready to build"))
      assert Enum.any?(first, &(&1 =~ "! untrusted"))

      interact = screen({120, 36}, [ascii?: true], :interact)
      assert Enum.any?(interact, &(&1 =~ "opens in its own tab"))
    end
  end

  describe "the measured tier" do
    test "round beads are ⦁ and ⚬" do
      text = {120, 36} |> screen(glyph_tier: :measured) |> Enum.join("\n")
      assert text =~ "⦁"
      assert text =~ "⚬"
      refute String.match?(text, ~r/[●○]/u)
      assert braille?(text)
    end

    test "the rich tier keeps ● and ○" do
      text = {120, 36} |> screen(glyph_tier: :rich) |> Enum.join("\n")
      assert text =~ "●"
      assert text =~ "○"
    end
  end

  describe "the light theme" do
    defp styles(theme) do
      state = fixture({120, 36}, caps: [glyph_tier: :rich, color_mode: :truecolor])
      {scene, _} = Projector.project(state)
      {:ok, plan} = Paint.build(scene, %Options{color_mode: :truecolor, theme: theme})
      at = fn x, y -> elem(plan.palette, elem(Plan.cell(plan, x, y), 3)) end

      cell = fn predicate ->
        {r, c, _, _} = Enum.find(Mark.elements({32, 16}), predicate)
        at.(4 + c, 2 + r)
      end

      %{
        dot: cell.(&match?({_, _, _, :dot}, &1)),
        track: cell.(&match?({_, _, _, {:ring, f}} when f > 0.8, &1)),
        empty_bar: cell.(&match?({_, _, _, {:bar, 3, _}}, &1))
      }
    end

    test "the dot's style differs from the dark one" do
      assert styles(:light).dot != styles(:dark).dot
    end

    test "the ring's track and the empty bar slots stay visible against the page" do
      light = styles(:light)
      assert light.track.foreground != light.track.background
      assert light.empty_bar.foreground != light.empty_bar.background
      assert light.track.background == {:rgb, 244, 243, 241}
      page = Theme.page_color(:light)
      assert page == 244 * 65_536 + 243 * 256 + 241
    end
  end

  describe "widths" do
    # A row measures exactly W cells under the policy the state draws with.
    defp row_cells(block, policy) do
      block.spans |> Enum.map(&Width.cells(SafeText.value(&1.text), policy)) |> Enum.sum()
    end

    test "every row of every class is exactly W cells wide under both policies" do
      for size <- @sizes, policy <- [:narrow, :wide], scene <- [:main, :first_run, :interact] do
        {columns, rows} = size
        state = fixture(size, caps: [ambiguous_width: policy], scene: scene)
        {frame, _} = Projector.project(state)
        region = Enum.find(frame.regions, &(&1.id == "home"))
        assert length(region.blocks) == rows

        for {block, index} <- Enum.with_index(region.blocks) do
          assert row_cells(block, policy) == columns,
                 "#{inspect(size)} #{policy} #{scene} row #{index}: #{row_cells(block, policy)}"
        end
      end
    end
  end
end

defmodule SwarmCodeCLI.UI.Home.OrbitContrastTest do
  @moduledoc "orbit U11: high contrast changes the roles, never the layout. Global state: not async."
  use ExUnit.Case, async: false

  import SwarmCodeCLI.OrbitHelpers, only: [fixture: 2]

  alias SwarmCodeCLI.Cli020EHelpers, as: H
  alias SwarmCodeCLI.UI.Theme

  setup do
    before = Theme.high_contrast?()
    on_exit(fn -> Theme.put_high_contrast(before) end)
    :ok
  end

  test "the screen reads the same and the track still stands out from the page" do
    state = fixture({120, 36}, caps: [glyph_tier: :rich, color_mode: :truecolor])
    normal = H.screen_text(state)

    Theme.put_high_contrast(true)
    assert H.screen_text(state) == normal

    plan = H.plan(state)

    {r, c, _, _} =
      Enum.find(SwarmCodeCLI.UI.Home.Mark.elements({32, 16}), &match?({_, _, _, :dot}, &1))

    style = H.cell_style(plan, 4 + c, 2 + r)
    assert style.foreground != style.background
  end
end
