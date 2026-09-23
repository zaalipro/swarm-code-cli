defmodule SwarmCodeCLI.UI.Projector.SceneBudgetTest do
  @moduledoc """
  rel F3 / ux F2: a long conversation in a big terminal overflowed the paint
  budget and the draw error closed the session. Every demo conversation, with
  and without the run palette and the dashboard over it, must project into a
  scene that Paint admits at every size a terminal can be.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Demo.Conversation
  alias SwarmCodeCLI.UI.{Capabilities, Paint, Projector, Size}
  alias SwarmCodeCLI.UI.Paint.{Budget, Options}

  @sizes [{250, 70}, {160, 45}, {120, 36}, {90, 30}, {80, 24}, {500, 200}]
  @layers [[], [{:run_palette, "p"}], [{:runs_dashboard, "d"}], [:help]]

  for scene <- [:long, :failed_workflow, :swarm, :approval] do
    test "#{scene} paints at every size, under every overlay" do
      for {columns, rows} <- @sizes, layers <- @layers, tier <- [:measured, :rich] do
        size = %Size{columns: columns, rows: rows}
        caps = %Capabilities{size: size, color_mode: :truecolor, glyph_tier: tier}
        state = Conversation.state(unquote(scene), size, caps)
        state = %{state | layers: layers, focus: if(layers == [], do: "composer", else: "query")}
        {scene, _table} = Projector.project(state)

        assert {:ok, _plan} =
                 Paint.build(scene, %Options{color_mode: :truecolor, glyph_tier: tier}),
               "#{columns}x#{rows} #{inspect(layers)} #{tier}"
      end
    end
  end

  test "the node ceiling grows with the terminal and keeps its floor" do
    assert Budget.node_limit(0, 0) == Budget.limits().nodes
    assert Budget.node_limit(250, 70) > Budget.node_limit(160, 45)
    assert Budget.node_limit(160, 45) > Budget.node_limit(80, 24)
  end
end
