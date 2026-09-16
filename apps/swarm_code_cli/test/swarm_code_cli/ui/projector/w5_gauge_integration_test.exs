defmodule SwarmCodeCLI.UI.Projector.W5GaugeIntegrationTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Paint, Projector, SafeText, Size}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.Scene.Block

  defp fixture(kind, size, opts \\ []) do
    caps = struct(Capabilities, Keyword.take(opts, [:ascii?, :color_mode, :ambiguous_width]))
    caps = %{caps | size: size}
    Fixtures.representative(kind, size, caps)
  end

  defp find_blocks(value, predicate) do
    do_find_blocks(value, predicate)
  end

  defp do_find_blocks(%{__struct__: _} = block, predicate) do
    matched = if predicate.(block), do: [block], else: []
    nested = do_find_blocks(Map.from_struct(block), predicate)
    matched ++ nested
  end

  defp do_find_blocks(map, predicate) when is_map(map) do
    map
    |> Map.values()
    |> Enum.flat_map(&do_find_blocks(&1, predicate))
  end

  defp do_find_blocks(list, predicate) when is_list(list) do
    Enum.flat_map(list, &do_find_blocks(&1, predicate))
  end

  defp do_find_blocks(_, _predicate), do: []

  defp texts(%SafeText{} = t), do: [SafeText.value(t)]
  defp texts(%{__struct__: _} = t), do: t |> Map.from_struct() |> texts()
  defp texts(m) when is_map(m), do: m |> Map.values() |> texts()
  defp texts(l) when is_list(l), do: Enum.flat_map(l, &texts/1)
  defp texts(t) when is_tuple(t), do: t |> Tuple.to_list() |> texts()
  defp texts(_), do: []

  describe "the run headline" do
    # The main pane no longer carries a run card with a gauge: the run's state
    # is one row of plain words under the tabs, and progress lives on the tab
    # row and in the hive's lanes. Nothing in main invents a percentage.
    test "a running run shows its state in words, not a gauge in main" do
      state = fixture(:chat, %Size{columns: 150, rows: 30})
      run = hd(Map.values(state.read_model.runs))
      state = put_in(state.read_model.runs[run.id].state, :running)
      state = put_in(state.read_model.runs[run.id].progress, 62)

      {scene, _} = Projector.project(state)
      main = Enum.find(scene.regions, &(&1.role == :main))

      assert find_blocks(main, &match?(%Block.Gauge{}, &1)) == []
      assert find_blocks(main, &match?(%Block.Progress{}, &1)) == []
      assert find_blocks(main, &match?(%Block.RunCard{}, &1)) == []
      assert Enum.join(texts(main), " ") =~ "running"
    end

    test "an unknown progress invents no percentage" do
      state = fixture(:chat, %Size{columns: 150, rows: 30})
      run = hd(Map.values(state.read_model.runs))
      state = put_in(state.read_model.runs[run.id].state, :running)
      state = put_in(state.read_model.runs[run.id].progress, nil)

      {scene, _} = Projector.project(state)
      main = Enum.find(scene.regions, &(&1.role == :main))

      refute Enum.join(texts(main), " ") =~ "%"
      assert find_blocks(main, &match?(%Block.Gauge{}, &1)) == []
    end
  end

  describe "title bar logo mark (Change 2)" do
    test "painted title row carries the logo mark before the wordmark in Unicode mode" do
      state = fixture(:chat, %Size{columns: 150, rows: 30}, ascii?: false)
      title = paint_row_0(state)

      assert title =~ "⬢ SWARMCODE  "
    end

    test "painted title row degrades the logo mark to its ASCII twin in ASCII mode" do
      state = fixture(:chat, %Size{columns: 150, rows: 30}, ascii?: true)
      title = paint_row_0(state)

      refute title =~ "⬢", "Unicode logo must not survive into ASCII mode"
      assert title =~ "# SWARMCODE  "
    end

    test "title region spans still carry the logo mark in the accent-bold wordmark style" do
      state = fixture(:chat, %Size{columns: 150, rows: 30}, ascii?: false)
      {scene, _} = Projector.project(state)
      title_region = Enum.find(scene.regions, &(&1.role == :title))
      assert title_region

      rendered = render_blocks(title_region.blocks)
      assert rendered =~ "⬢"

      %Block.RichText{spans: [logo_span | _]} = hd(title_region.blocks)
      assert SafeText.value(logo_span.text) == "⬢"
      assert :bold in logo_span.style.modifiers
    end
  end

  # The navigator's run rows carried the run-state colour. The dock is gone, so
  # the same evidence is now the tab row's status dots: one dot per run, coloured
  # by that run's state.
  describe "run-state colour on the tab row (Change 3)" do
    test "two runs in different states get different status colours on the tab row" do
      # Build a fixture with multiple runs by adding a second run
      state = fixture(:chat, %Size{columns: 150, rows: 30}, color_mode: :truecolor)

      run1 = hd(Map.values(state.read_model.runs))

      run2 = %{
        run1
        | id: "fixture-run-2",
          title: "Second run for color test",
          state: :failed
      }

      state = put_in(state.read_model.runs[run1.id].state, :done)
      state = put_in(state.read_model.runs[run2.id], run2)

      # Add run2 to the shell order
      state = put_in(state.read_model.order[:shell], [run1.id, run2.id])

      {scene, _} = Projector.project(state)

      refute Enum.any?(scene.regions, &(&1.role == :navigator))
      tabline = Enum.find(scene.regions, &(&1.role == :tabline))
      assert tabline

      dot = SafeText.value(SafeText.chrome(:dot))

      colors =
        tabline.blocks
        |> find_blocks(&match?(%Block.RichText{}, &1))
        |> Enum.flat_map(& &1.spans)
        |> Enum.filter(&(SafeText.value(&1.text) == dot))
        |> Enum.map(& &1.style.foreground)

      # One dot per run, and the two states do not share a colour.
      assert length(colors) >= 2
      assert length(Enum.uniq(colors)) > 1
    end
  end

  # Paints the state and returns the text of the title row (row 0), following the
  # helpers in test/swarm_code_cli/ui/paint/shell_format_test.exs.
  defp paint_row_0(state) do
    {scene, _table} = Projector.project(state)

    options = %Options{
      color_mode: state.capabilities.color_mode,
      ascii?: state.capabilities.ascii?
    }

    assert {:ok, plan} = Paint.build(scene, options)
    assert :ok = Plan.validate(plan)

    for column <- 0..(plan.size.columns - 1), reduce: "" do
      text ->
        case Plan.cell(plan, column, 0) do
          {:glyph, glyph, _, _} -> text <> glyph
          _ -> text
        end
    end
  end

  defp render_blocks(blocks) when is_list(blocks) do
    Enum.map_join(blocks, " ", &render_block/1)
  end

  defp render_block(%Block.Text{text: text}), do: SafeText.value(text)

  defp render_block(%Block.RichText{spans: spans}) do
    Enum.map_join(spans, "", fn span ->
      SafeText.value(span.text)
    end)
  end

  defp render_block(_), do: ""
end
