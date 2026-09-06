defmodule SwarmCodeCLI.UI.Paint.PlanTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.Paint.Plan
  alias SwarmCodeCLI.UI.Size
  alias SwarmCodeCLI.UI.Scene.{Cursor, Rect}

  defp plan(overrides \\ []) do
    struct(
      Plan,
      Keyword.merge(
        [
          size: %Size{columns: 3, rows: 1},
          cells: {{:glyph, "界", 2, 0}, {:continuation, 0}, {:glyph, "x", 1, 0}},
          palette: {%{foreground: {:rgb, 1, 2, 3}, background: nil, modifiers: [:bold]}}
        ],
        overrides
      )
    )
  end

  test "a plan validates and exposes only in-bounds row-major cells" do
    assert :ok = Plan.validate(plan())
    assert Plan.cell(plan(), 1, 0) == {:continuation, 0}

    for {x, y} <- [{-1, 0}, {3, 0}, {0, 1}, {0, -1}, {nil, 0}],
        do: assert(Plan.cell(plan(), x, y) == nil)
  end

  test "cell lookup tolerates malformed dimensions and cell tuples" do
    assert Plan.cell(plan(size: %Size{columns: :invalid, rows: 1}), 0, 0) == nil
    assert Plan.cell(plan(cells: {}), 0, 0) == nil
    assert Plan.cell(plan(), 0.0, 0) == nil
  end

  test "revision and action identifier budgets hold at their boundaries" do
    assert :ok = Plan.validate(plan(revision: 18_446_744_073_709_551_615))
    assert {:error, :invalid_plan} = Plan.validate(plan(revision: 18_446_744_073_709_551_616))
    diagnostics = for n <- 1..4096, do: {:clipped_action, Integer.to_string(n)}
    assert :ok = Plan.validate(plan(diagnostics: diagnostics))

    assert {:error, :invalid_plan} =
             Plan.validate(plan(diagnostics: [{:clipped_action, "overflow"} | diagnostics]))

    assert {:error, :invalid_plan} = Plan.validate(plan(focus: %{region_id: "a\nb"}))
  end

  test "forged cells cannot introduce malformed or inaccurate spans" do
    invalid = [
      {{:continuation, 0}, {:glyph, "x", 1, 0}, {:glyph, "x", 1, 0}},
      {{:glyph, "界", 2, 0}, {:continuation, 1}, {:glyph, "x", 1, 0}},
      {{:glyph, "界", 2, 0}, {:glyph, "x", 1, 0}, {:glyph, "x", 1, 0}},
      {{:glyph, "界", 1, 0}, {:glyph, "x", 1, 0}, {:glyph, "x", 1, 0}},
      {{:glyph, "x", 1, 0}, {:glyph, "x", 1, 0}, {:glyph, "界", 2, 0}},
      {{:glyph, "x", 1, 1}, {:glyph, "x", 1, 0}, {:glyph, "x", 1, 0}},
      {{:glyph, "\e", 1, 0}, {:glyph, "x", 1, 0}, {:glyph, "x", 1, 0}},
      {{:glyph, "x", 1, 0}}
    ]

    for cells <- invalid, do: assert(Plan.validate(plan(cells: cells)) == {:error, :invalid_plan})
    assert Plan.validate(plan(size: %Size{columns: 1, rows: 3})) == {:error, :invalid_plan}

    assert :ok =
             Plan.validate(plan(size: %Size{columns: 1, rows: 1}, cells: {{:glyph, "لا", 1, 0}}))

    assert Plan.validate(
             plan(
               size: %Size{columns: 1, rows: 1},
               cells: {{:glyph, "·", 1, 0}},
               ambiguous_width: :wide
             )
           ) == {:error, :invalid_plan}
  end

  test "closed plan and nested shapes reject extra fields and wrong values" do
    assert Plan.validate(Map.put(plan(), :command, :stop)) == {:error, :invalid_plan}

    for attrs <- [
          [version: 2],
          [revision: -1],
          [size: %Size{columns: 501, rows: 1}],
          [size: Map.put(%Size{columns: 3, rows: 1}, :extra, true)],
          [color_mode: :unknown],
          [ambiguous_width: :unknown],
          [focus: %{region_id: "main", extra: true}],
          [focus: %{region_id: ""}],
          [cursor: %Cursor{x: 3, y: 0}],
          [cursor: Map.put(%Cursor{x: 0, y: 0}, :extra, true)],
          [diagnostics: [:unknown]],
          [actions: %{"a" => []}],
          [actions: %{"a" => [%Rect{x: 2, y: 0, width: 2, height: 1}]}],
          [actions: %{"a" => [%Rect{x: 0, y: 0, width: 0, height: 1}]}]
        ] do
      assert Plan.validate(plan(attrs)) == {:error, :invalid_plan}, inspect(attrs)
    end

    assert :ok =
             Plan.validate(
               plan(
                 focus: %{region_id: "main"},
                 cursor: %Cursor{x: 2, y: 0},
                 actions: %{"a" => [%Rect{x: 0, y: 0, width: 2, height: 1}]},
                 diagnostics: [{:clipped_action, "b"}]
               )
             )
  end

  test "palette is bounded, closed and representable in the selected mode" do
    for palette <- [
          {},
          List.to_tuple(List.duplicate(%{foreground: nil, background: nil, modifiers: []}, 4097)),
          {%{foreground: {:rgb, 256, 0, 0}, background: nil, modifiers: []}},
          {%{foreground: nil, background: nil, modifiers: [:bold, :bold]}},
          {%{foreground: nil, background: nil, modifiers: [:blink]}},
          {%{foreground: nil, background: nil, modifiers: [], command: :stop}}
        ],
        do: assert(Plan.validate(plan(palette: palette)) == {:error, :invalid_plan})

    for mode <- [:ansi256, :ansi16, :monochrome],
        do: assert(Plan.validate(plan(color_mode: mode)) == {:error, :invalid_plan})

    for {mode, color} <- [
          {:truecolor, {:rgb, 255, 0, 0}},
          {:ansi256, {:indexed, 255}},
          {:ansi16, {:ansi, :bright_red}},
          {:monochrome, nil}
        ] do
      assert :ok =
               Plan.validate(
                 plan(
                   color_mode: mode,
                   palette: {%{foreground: color, background: nil, modifiers: []}}
                 )
               )
    end
  end

  test "IDs and diagnostics carry only bounded opaque identifiers" do
    for id <- ["", <<255>>, String.duplicate("a", 257), :stop, self()] do
      assert Plan.validate(plan(diagnostics: [{:clipped_action, id}])) == {:error, :invalid_plan}
      assert Plan.validate(plan(focus: %{region_id: id})) == {:error, :invalid_plan}

      assert Plan.validate(plan(actions: %{id => [%Rect{x: 0, y: 0, width: 1, height: 1}]})) ==
               {:error, :invalid_plan}
    end

    assert Plan.validate(plan(diagnostics: [{:clipped_action, "a"}, {:clipped_action, "a"}])) ==
             {:error, :invalid_plan}

    assert Plan.validate(
             plan(
               actions: %{"a" => [%Rect{x: 0, y: 0, width: 1, height: 1}]},
               diagnostics: [{:clipped_action, "a"}]
             )
           ) == {:error, :invalid_plan}
  end

  test "action rectangles cannot assign one visible cell to multiple owners or duplicate a claim" do
    rect = %Rect{x: 0, y: 0, width: 2, height: 1}

    for actions <- [
          %{"a" => [rect, rect]},
          %{"a" => [rect], "b" => [%Rect{x: 1, y: 0, width: 1, height: 1}]}
        ] do
      assert {:error, :invalid_plan} = Plan.validate(plan(actions: actions))
    end

    assert :ok =
             Plan.validate(
               plan(actions: %{"a" => [rect], "b" => [%Rect{x: 2, y: 0, width: 1, height: 1}]})
             )

    cells = List.to_tuple(List.duplicate({:glyph, " ", 1, 0}, 6))

    assert :ok =
             Plan.validate(
               plan(
                 size: %Size{columns: 3, rows: 2},
                 cells: cells,
                 actions: %{"a" => [%Rect{x: 0, y: 0, width: 2, height: 2}]}
               )
             )
  end

  test "external term budget rejects repeated huge glyph payloads" do
    glyph = "e" <> String.duplicate("́", 180_000)
    cells = List.to_tuple(List.duplicate({:glyph, glyph, 1, 0}, 100))
    assert :erlang.external_size(cells) > 32 * 1024 * 1024

    assert Plan.validate(plan(size: %Size{columns: 100, rows: 1}, cells: cells)) ==
             {:error, :invalid_plan}
  end

  test "each complete glyph has one action owner including its unowned cells" do
    lead = %Rect{x: 0, y: 0, width: 1, height: 1}
    continuation = %Rect{x: 1, y: 0, width: 1, height: 1}

    for actions <- [
          %{"a" => [lead]},
          %{"a" => [continuation]},
          %{"a" => [lead], "b" => [continuation]}
        ] do
      assert {:error, :invalid_plan} = Plan.validate(plan(actions: actions))
    end

    assert :ok = Plan.validate(plan(actions: %{"a" => [lead, continuation]}))
    assert :ok = Plan.validate(plan(actions: %{}))
  end

  test "forged glyphs must preserve the existing inert SafeText representation" do
    for glyph <- ["a\u202E", "́a", "a\u200B"] do
      assert {:error, :invalid_plan} =
               Plan.validate(
                 plan(size: %Size{columns: 1, rows: 1}, cells: {{:glyph, glyph, 1, 0}})
               )
    end
  end

  test "legitimate complete Unicode units retain their exact binary and contextual width" do
    for {glyph, width} <- [{"👩‍💻", 2}, {"一\u{E0100}", 2}, {"لا", 1}, {"क्ष्म", 3}, {"é", 1}] do
      cells =
        List.to_tuple([{:glyph, glyph, width, 0} | List.duplicate({:continuation, 0}, width - 1)])

      valid = plan(size: %Size{columns: width, rows: 1}, cells: cells)
      assert :ok = Plan.validate(valid)
      assert Plan.cell(valid, 0, 0) == {:glyph, glyph, width, 0}
    end
  end

  test "optional focus geometry is a positive bounded closed rectangle" do
    rect = %Rect{x: 0, y: 0, width: 3, height: 1}
    focus = %{region_id: "main", control_id: "control", rect: rect}
    assert :ok = Plan.validate(plan(focus: focus))
    assert :ok = Plan.validate(plan(focus: %{region_id: "main"}))
    assert :ok = Plan.validate(plan(focus: nil))

    for invalid <- [
          nil,
          %{x: 0, y: 0, width: 3, height: 1},
          %Rect{x: 0, y: 0, width: 0, height: 1},
          %Rect{x: 0, y: 0, width: 1, height: 0},
          %Rect{x: -1, y: 0, width: 1, height: 1},
          %Rect{x: 0, y: 0, width: 4, height: 1},
          %Rect{x: 0, y: 1, width: 1, height: 1},
          Map.put(rect, :extra, true)
        ] do
      assert {:error, :invalid_plan} = Plan.validate(plan(focus: %{focus | rect: invalid}))
    end

    assert {:error, :invalid_plan} = Plan.validate(plan(focus: Map.put(focus, :extra, true)))
  end

  test "repeated glyph safety and width work is reused within one validation" do
    repeated = grid(List.duplicate(<<0xE000::utf8>>, 4800))
    distinct = grid(for cp <- 0xE000..(0xE000 + 4799), do: <<cp::utf8>>)
    assert :ok = Plan.validate(repeated)
    assert :ok = Plan.validate(distinct)
    {repeated_result, repeated_work} = validation_work(repeated)
    {distinct_result, distinct_work} = validation_work(distinct)
    assert repeated_result == :ok
    assert distinct_result == :ok
    assert repeated_work * 2 < distinct_work
  end

  test "memo admission stops at 1024 glyph pairs without skipping later safety checks" do
    costly = "e" <> String.duplicate("́", 100)
    prefix = for cp <- 0xE000..(0xE000 + 1023), do: <<cp::utf8>>
    cached = grid([costly | tl(prefix)] ++ List.duplicate(costly, 1000))
    beyond_capacity = grid(prefix ++ List.duplicate(costly, 1000))
    {cached_result, cached_work} = validation_work(cached)
    {bounded_result, bounded_work} = validation_work(beyond_capacity)
    assert cached_result == :ok
    assert bounded_result == :ok
    assert cached_work * 2 < bounded_work

    unsafe = grid(prefix ++ ["a\u202E"] ++ List.duplicate("x", 999))
    assert {:error, :invalid_plan} = Plan.validate(unsafe)
  end

  test "memo hits still validate style bounds and the exact glyph width" do
    assert {:error, :invalid_plan} =
             Plan.validate(
               plan(cells: {{:glyph, "x", 1, 0}, {:glyph, "x", 1, 1}, {:glyph, "x", 1, 0}})
             )

    assert {:error, :invalid_plan} =
             Plan.validate(
               plan(cells: {{:glyph, "x", 1, 0}, {:glyph, "x", 2, 0}, {:continuation, 1}})
             )
  end

  defp grid(glyphs) do
    count = length(glyphs)
    columns = if rem(count, 120) == 0, do: 120, else: 46

    plan(
      size: %Size{columns: columns, rows: div(count, columns)},
      cells: List.to_tuple(Enum.map(glyphs, &{:glyph, &1, 1, 0}))
    )
  end

  defp validation_work(value) do
    {:reductions, before} = Process.info(self(), :reductions)
    result = Plan.validate(value)
    {:reductions, after_count} = Process.info(self(), :reductions)
    {result, after_count - before}
  end
end
