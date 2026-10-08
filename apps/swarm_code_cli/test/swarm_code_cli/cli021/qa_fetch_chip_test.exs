defmodule SwarmCodeCLI.Cli021.QaFetchChipTest do
  @moduledoc """
  cli021 qa (found live at 120x40): a label that fills its column ran into
  the result chip, `Fetch every provider's models✓ 1 provider · 1 updated`
  on Providers and Models & effort. A chip keeps one cell from such a label.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0]
  import SwarmCodeCLI.UI.C74U3Helpers

  alias SwarmCodeCLI.UI.{Projector, SafeText, Size}
  alias SwarmCodeCLI.UI.DataSource.Fake.Settings, as: FakeSettings

  defp lines(state) do
    {scene, _actions} = Projector.project(state)

    scene.regions
    |> Enum.flat_map(& &1.blocks)
    |> Enum.map(fn block -> Enum.map_join(block.spans, "", &SafeText.value(&1.text)) end)
  end

  defp with_done_fetch_all(state) do
    task = %{
      "task_id" => "t-all",
      "action" => "provider.fetch_all",
      "target" => nil,
      "state" => "done",
      "summary" => %{"words" => "1 provider · 1 updated", "providers" => []},
      "received_at_ms" => System.system_time(:millisecond)
    }

    layer = state.settings
    %{state | settings: %{layer | tasks: Map.put(layer.tasks, "t-all", task)}}
  end

  for section <- [:providers, :models_effort], {columns, rows} <- [{120, 40}, {160, 45}] do
    test "#{section} at #{columns}x#{rows}: the label and the chip stay apart" do
      base =
        act!(ready(), {:resize, %Size{columns: unquote(columns), rows: unquote(rows)}})

      base = %{
        base
        | capabilities: %{base.capabilities | color_mode: :truecolor, glyph_tier: :rich}
      }

      {state, _fake} = opened(unquote(section), state: base, fake: FakeSettings.seed())
      line = state |> with_done_fetch_all() |> lines() |> Enum.find(&(&1 =~ "provider's models"))
      assert line =~ ~r/provider's models\s+✓ 1 provider · 1 updated/, line
    end
  end
end
