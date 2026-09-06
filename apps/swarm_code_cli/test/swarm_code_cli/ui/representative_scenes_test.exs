defmodule SwarmCodeCLI.UI.RepresentativeScenesTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Projector, Scene, Size}
  alias SwarmCodeCLI.UI.Scene.Block

  defp blocks(%{__struct__: _} = x),
    do: [x | x |> Map.from_struct() |> Map.values() |> Enum.flat_map(&blocks/1)]

  defp blocks(x) when is_list(x), do: Enum.flat_map(x, &blocks/1)
  defp blocks(_), do: []

  test "four fixed surfaces use distinct semantic evidence and bounded windows" do
    for {kind, module} <- [
          chat: Block.Markdown,
          swarm: Block.AgentList,
          consensus: Block.ConsensusLedger,
          research: Block.ResearchDocument
        ] do
      state = Fixtures.representative(kind, %Size{columns: 170, rows: 34}, struct(Capabilities))
      {scene, _} = Projector.project(state)
      assert Scene.validate(scene) == :ok
      assert Enum.any?(blocks(scene), &is_struct(&1, module))

      for list <- Enum.filter(blocks(scene), &is_struct(&1, Block.VirtualList)) do
        assert list.overscan <= 2
        assert length(list.items) <= 38
      end
    end
  end
end
