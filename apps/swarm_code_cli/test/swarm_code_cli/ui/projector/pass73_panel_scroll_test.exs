defmodule SwarmCodeCLI.UI.Projector.Pass73PanelScrollTest do
  @moduledoc """
  pass73 T9 (K's request F1, `panel.ex` is V1's): the wheel over the side
  panel scrolls it (K's `state.panel_scroll`) when it holds more than the
  pane; the needs-you band stays pinned, and the cut row says what is out
  of sight above and below.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Demo.Panel, as: Scenes
  alias SwarmCodeCLI.UI.{Capabilities, Layout, SafeText, Size}
  alias SwarmCodeCLI.UI.Projector.Panel

  defp crowded(columns, rows) do
    size = %Size{columns: columns, rows: rows}
    caps = %Capabilities{size: size, color_mode: :truecolor, glyph_tier: :rich}
    state = Scenes.state(:panel_swarm_2, size, caps)
    template = state.read_model.agents["agent-80-3"]

    extra =
      for i <- 6..29, into: %{} do
        id = "agent-80-#{i}"
        {id, %{template | id: id, name: "worker-#{i}", started_at: template.started_at + i}}
      end

    put_in(state.read_model.agents, Map.merge(state.read_model.agents, extra))
  end

  defp texts(state) do
    rect = Layout.for_state(state).rects.inspector

    state
    |> Panel.plan(rect.width, rect.height)
    |> Enum.map(&elem(&1, 0))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn block -> Enum.map_join(block.spans, &SafeText.value(&1.text)) end)
  end

  test "the wheel scrolls an overflowing panel; the band stays; the cut says more above" do
    state = crowded(160, 30)
    top = texts(state)
    assert Enum.any?(top, &(&1 =~ "more")), Enum.join(top, "\n")
    refute Enum.any?(top, &(&1 =~ "more above"))

    scrolled = state |> Map.put(:panel_scroll, 6) |> texts()
    assert Enum.any?(scrolled, &(&1 =~ "more above")), Enum.join(scrolled, "\n")
    assert Enum.any?(scrolled, &(&1 =~ "NEEDS YOU"))
    assert Enum.any?(scrolled, &(&1 =~ "mix test test/swarm_code_web/live"))
    assert scrolled != top
    assert length(scrolled) == length(top)

    # Past the end it stops at the last row.
    far = state |> Map.put(:panel_scroll, 10_000) |> texts()
    assert length(far) == length(top)
    assert Enum.any?(far, &(&1 =~ "worker-29"))
  end
end
