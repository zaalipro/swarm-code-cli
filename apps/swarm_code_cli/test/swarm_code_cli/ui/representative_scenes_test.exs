defmodule SwarmCodeCLI.UI.RepresentativeScenesTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Paint, Projector, SafeText, Scene, Size}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.Scene.Block

  defp blocks(%{__struct__: _} = x),
    do: [x | x |> Map.from_struct() |> Map.values() |> Enum.flat_map(&blocks/1)]

  defp blocks(x) when is_list(x), do: Enum.flat_map(x, &blocks/1)
  defp blocks(_), do: []

  test "four fixed surfaces use distinct semantic evidence and bounded windows" do
    for {kind, evidence} <- [
          chat: ["The workspace is ready", "synthetic changes"],
          swarm: ["Five numbered lanes", "judge", "waiting for your answer"],
          consensus: ["Consensus", "Docket 01", "Ledger:"],
          research: ["Static research report", "Synthetic source", "Fixture notes"]
        ] do
      state = Fixtures.representative(kind, %Size{columns: 170, rows: 34}, struct(Capabilities))
      {scene, _} = Projector.project(state)
      assert Scene.validate(scene) == :ok
      assert {:ok, plan} = Paint.build(scene, %Options{color_mode: :monochrome})
      assert :ok = Plan.validate(plan)

      pixels =
        for y <- 0..(scene.size.rows - 1), into: "" do
          for x <- 0..(scene.size.columns - 1), into: "" do
            case Plan.cell(plan, x, y) do
              {:glyph, glyph, _, _} -> glyph
              _ -> ""
            end
          end
        end

      for text <- evidence, do: assert(pixels =~ text)

      # The prompt is a card and the turn has one header row (ux M3); the turn
      # is spoken by the run's agent when the hive names one (the swarm lead),
      # and by "assistant" otherwise.
      assert pixels =~ "Review this synthetic project"
      refute pixels =~ "you · "

      speaker =
        case kind do
          :swarm -> "lead  "
          :chat -> "assistant  "
          other -> Atom.to_string(other) <> "  "
        end

      assert pixels =~ speaker

      main = Enum.find(scene.regions, &(&1.role == :main))
      assert Enum.count(main.blocks, &is_struct(&1, Block.RunCard)) == 0

      if kind in [:consensus, :research] do
        heading = Atom.to_string(kind)

        assert Enum.any?(blocks(main), fn
                 %Scene.Span{text: text, style: style} ->
                   SafeText.value(text) == heading and :bold in style.modifiers

                 _ ->
                   false
               end)
      end

      for list <- Enum.filter(blocks(scene), &is_struct(&1, Block.VirtualList)) do
        assert list.overscan <= 2
        assert length(list.items) <= 38
      end
    end
  end
end
