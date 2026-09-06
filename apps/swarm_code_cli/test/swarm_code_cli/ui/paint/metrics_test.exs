defmodule SwarmCodeCLI.UI.Paint.MetricsTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{SafeText, Scene}
  alias SwarmCodeCLI.UI.SafeText.Limits
  alias SwarmCodeCLI.UI.Paint.{Blocks, Metrics, Options}

  test "height is the exact bounded layout height under either width policy" do
    {:ok, value} = SafeText.external("·界abc\nsecond", Limits.content())
    block = %Scene.Block.Text{text: value}

    for policy <- [:narrow, :wide], width <- [1, 4, 20], rows <- [0, 1, 10] do
      assert {:ok, lines} =
               Blocks.lines(
                 [block],
                 width,
                 %Options{},
                 %{foreground: nil, background: nil, modifiers: []},
                 rows,
                 policy
               )

      assert Metrics.height(block, width, %Options{}, rows, policy) == {:ok, length(lines)}
    end
  end
end
