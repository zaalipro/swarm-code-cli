defmodule SwarmCodeCLI.UI.Home.OrbitMarkTest do
  @moduledoc """
  orbit U3: the mark's braille is the designer's (`d_mark.py`, goldens in
  `test/fixtures/home/mark_WxH.txt`) and its roles follow the data.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.Home.Mark
  alias SwarmCodeCLI.UI.Width

  @fixtures Path.expand("../../../fixtures/home", __DIR__)

  defp golden({w, h}) do
    lines =
      Path.join(@fixtures, "mark_#{w}x#{h}.txt") |> File.read!() |> String.split("\n", trim: true)

    for {line, row} <- Enum.with_index(lines),
        {char, col} <- line |> String.graphemes() |> Enum.with_index(),
        char != " ",
        into: %{},
        do: {{row, col}, char}
  end

  defp glyphs(size),
    do: Map.new(Mark.elements(size), fn {row, col, char, _} -> {{row, col}, char} end)

  defp ratio(size) do
    expected = golden(size)
    actual = glyphs(size)
    keys = MapSet.union(MapSet.new(Map.keys(expected)), MapSet.new(Map.keys(actual)))
    same = Enum.count(keys, &(Map.get(expected, &1) == Map.get(actual, &1)))
    {same / MapSet.size(keys), MapSet.size(keys) - same}
  end

  describe "the braille" do
    for size <- [{32, 16}, {40, 20}, {24, 12}] do
      test "#{inspect(size)} matches the designer's golden in at least 98 % of cells" do
        {ratio, different} = ratio(unquote(size))
        assert ratio >= 0.98, "#{different} cells differ (#{Float.round(ratio * 100, 2)} % match)"
      end
    end

    test "the three sizes are the ones rasterised, each inside its box" do
      assert Mark.sizes() == [{40, 20}, {32, 16}, {24, 12}]

      for {w, h} = size <- Mark.sizes() do
        cells = Mark.elements(size)
        assert cells != []

        assert Enum.all?(cells, fn {row, col, _, _} -> row in 0..(h - 1) and col in 0..(w - 1) end)

        assert Mark.cell_set(size) == MapSet.new(cells, fn {row, col, _, _} -> {row, col} end)
      end
    end

    test "every glyph is one braille cell, one column under both width policies" do
      for size <- Mark.sizes(), {_, _, char, _} <- Mark.elements(size) do
        assert [codepoint] = String.to_charlist(char)
        assert codepoint in 0x2801..0x28FF
        assert Width.cells(char, :narrow) == 1
        assert Width.cells(char, :wide) == 1
      end
    end

    test "the five bars run left to right and rise" do
      for size <- Mark.sizes() do
        bars =
          for {row, col, _, {:bar, k, _t}} <- Mark.elements(size), reduce: %{} do
            acc ->
              Map.update(acc, k, {row, row, col, col}, fn {top, bottom, left, right} ->
                {min(top, row), max(bottom, row), min(left, col), max(right, col)}
              end)
          end

        assert Map.keys(bars) |> Enum.sort() == [0, 1, 2, 3, 4]
        tops = for k <- 0..4, do: elem(bars[k], 0)
        lefts = for k <- 0..4, do: elem(bars[k], 2)

        assert tops == Enum.sort(tops, :desc),
               "bar tops #{inspect(tops)} do not rise at #{inspect(size)}"

        assert Enum.uniq(tops) == tops
        assert lefts == Enum.sort(lefts)
      end
    end

    test "the ring's gap is on the right and the dot sits inside bar 3's columns" do
      for {w, _h} = size <- Mark.sizes() do
        elements = Mark.elements(size)

        ring =
          for {row, col, _, {kind, _}} <- elements, kind in [:ring, :ring_cap], do: {row, col}

        {cx, cy, _radius} = Mark.centre(size)
        centre_row = trunc(cy / 4)
        centre_col = trunc(cx / 2)

        # no ring cell on the centre row to the right of the ring, left of it there are some
        assert Enum.any?(ring, fn {row, col} -> row == centre_row and col < centre_col end)
        refute Enum.any?(ring, fn {row, col} -> row == centre_row and col > centre_col end)
        assert w > 0

        dots = for {row, col, _, :dot} <- elements, do: {row, col}
        assert dots != []

        bar3 = for {_, col, _, {:bar, 2, _}} <- elements, do: col
        {low, high} = Enum.min_max(bar3)
        assert Enum.all?(dots, fn {_row, col} -> col in (low - 1)..(high + 1) end)
      end
    end

    test "the ring centre is where the ring is" do
      for size <- Mark.sizes() do
        {cx, cy, radius} = Mark.centre(size)

        ring =
          for {row, col, _, {kind, _}} <- Mark.elements(size),
              kind == :ring,
              do: {col * 2 + 1, row * 4 + 2}

        assert Enum.all?(ring, fn {x, y} ->
                 abs(:math.sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy)) - radius) <
                   radius * 0.2
               end)
      end
    end
  end

  describe "roles" do
    defp roles(size, opts), do: Mark.cells(size, opts) |> Enum.map(&elem(&1, 3))

    defp by_element(size, opts) do
      Enum.zip(Mark.elements(size), Mark.cells(size, opts))
      |> Enum.map(fn {{_, _, _, element}, {_, _, _, role}} -> {element, role} end)
    end

    test "by default everything is a ghost ring, empty bar slots and a ghost dot" do
      for {element, role} <- by_element({32, 16}, %{}) do
        case element do
          :dot -> assert role == :text_ghost
          {:bar, _, _} -> assert role == :disabled
          _ring -> assert role == :text_ghost
        end
      end
    end

    test "frac 0.64 lights the ring cells with f_mid <= 0.64 and only those" do
      pairs = by_element({40, 20}, %{frac: 0.64})
      lit = for {{:ring, f}, role} <- pairs, do: {f, role}
      assert Enum.any?(lit, fn {_f, role} -> role == :accent end)
      assert Enum.any?(lit, fn {_f, role} -> role == :text_ghost end)

      for {f, role} <- lit do
        assert role == if(f <= 0.64, do: :accent, else: :text_ghost), "f_mid #{f} drew #{role}"
      end

      assert [{{:ring_cap, :start}, :accent}] ==
               pairs |> Enum.filter(&match?({{:ring_cap, :start}, _}, &1)) |> Enum.uniq()

      refute :warning in roles({40, 20}, %{frac: 0.64})
    end

    test "frac nil is all ghost, 0.95 is warning, 1.2 is error" do
      assert Enum.uniq(for {{:ring, _}, role} <- by_element({32, 16}, %{frac: nil}), do: role) ==
               [:text_ghost]

      warning = for {{:ring, f}, role} <- by_element({32, 16}, %{frac: 0.95}), f <= 0.95, do: role
      assert Enum.uniq(warning) == [:warning]

      error = by_element({32, 16}, %{frac: 1.2})
      assert Enum.uniq(for {{:ring, _}, role} <- error, do: role) == [:error]
      assert Enum.uniq(for {{:ring_cap, _}, role} <- error, do: role) == [:error]

      # a ring at 99 % does not light the closing cap yet
      full = by_element({32, 16}, %{frac: 0.99})
      assert Enum.all?(for({{:ring_cap, :end}, role} <- full, do: role), &(&1 == :text_ghost))
    end

    test "a bar with progress is partly its role and partly faint, empty slots are disabled" do
      pairs = by_element({40, 20}, %{bars: [{:run_swarm, 60}, nil, nil, nil, nil]})
      bar0 = for {{:bar, 0, t}, role} <- pairs, do: {t, role}
      assert Enum.uniq(Enum.map(bar0, &elem(&1, 1))) |> Enum.sort() == [:run_swarm, :text_faint]

      assert Enum.all?(bar0, fn {t, role} ->
               role == if(t <= 0.6, do: :run_swarm, else: :text_faint)
             end)

      for k <- 1..4 do
        assert Enum.uniq(for {{:bar, ^k, _}, role} <- pairs, do: role) == [:disabled]
      end
    end

    test "a bar without a progress number is all its role" do
      pairs = by_element({32, 16}, %{bars: [{:run_goal, nil}, {:text_primary, nil}]})
      assert Enum.uniq(for {{:bar, 0, _}, role} <- pairs, do: role) == [:run_goal]
      assert Enum.uniq(for {{:bar, 1, _}, role} <- pairs, do: role) == [:text_primary]
      assert Enum.uniq(for {{:bar, 2, _}, role} <- pairs, do: role) == [:disabled]
    end

    test "the dot is warning when on, ghost when off or ghost" do
      assert Enum.uniq(for {:dot, role} <- by_element({32, 16}, %{dot: :on}), do: role) == [
               :warning
             ]

      assert Enum.uniq(for {:dot, role} <- by_element({32, 16}, %{dot: :off}), do: role) == [
               :text_ghost
             ]

      assert Enum.uniq(for {:dot, role} <- by_element({32, 16}, %{dot: :ghost}), do: role) == [
               :text_ghost
             ]
    end

    test "kind roles are the theme's" do
      assert Mark.kind_role(:chat) == :text_primary
      assert Mark.kind_role(:goal) == :run_goal
      assert Mark.kind_role(:swarm) == :run_swarm
      assert Mark.kind_role(:workflow) == :run_workflow
      assert Mark.kind_role(:research) == :run_research
      assert Mark.kind_role(:consensus) == :run_consensus_judge
      assert Mark.kind_role(:ultra) == :run_ultra
      assert Mark.kind_role(:something_new) == :text_primary

      known = SwarmCodeCLI.UI.Theme.roles()

      for role <- [
            :run_goal,
            :run_swarm,
            :run_workflow,
            :run_research,
            :run_consensus_judge,
            :run_ultra,
            :text_primary,
            :text_faint,
            :text_ghost,
            :disabled,
            :accent,
            :warning,
            :error
          ] do
        assert role in known, "#{role} is not a theme role"
      end
    end
  end

  describe "the compact inline glyph" do
    test "is the fixed string at the rich tier, one cell per piece under both policies" do
      assert Enum.map_join(Mark.inline(:rich, %{}), &elem(&1, 0)) == "⢎⡁▂▃▅▆█ ●"

      for tier <- [:rich, :measured, :ascii], {text, _role} <- Mark.inline(tier, %{}) do
        assert Width.cells(text, :narrow) == String.length(text)
      end

      for tier <- [:measured, :ascii], {text, _role} <- Mark.inline(tier, %{}) do
        assert Width.cells(text, :wide) == String.length(text)
      end
    end

    test "the ascii tier has no braille and the measured tier keeps the one-cell dot" do
      ascii = Enum.map_join(Mark.inline(:ascii, %{}), &elem(&1, 0))
      assert ascii == "().-=+# *"
      refute ascii |> String.to_charlist() |> Enum.any?(&(&1 in 0x2800..0x28FF))
      assert Enum.map_join(Mark.inline(:measured, %{}), &elem(&1, 0)) =~ "⦁"
    end

    test "roles follow the data, a bar slot keeps its run's role" do
      parts =
        Mark.inline(:rich, %{frac: 0.5, bars: [{:run_swarm, 40}, nil, {:run_goal, nil}], dot: :on})

      assert Enum.map(parts, &elem(&1, 1)) ==
               [
                 :accent,
                 :run_swarm,
                 :disabled,
                 :run_goal,
                 :disabled,
                 :disabled,
                 :text_ghost,
                 :warning
               ]

      assert Mark.inline(:rich, %{}) |> Enum.map(&elem(&1, 1)) |> hd() == :text_ghost
      assert Mark.inline(:rich, %{frac: 0.95}) |> Enum.map(&elem(&1, 1)) |> hd() == :warning
    end
  end
end
