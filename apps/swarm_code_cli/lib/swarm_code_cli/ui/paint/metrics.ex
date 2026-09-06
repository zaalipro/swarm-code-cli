defmodule SwarmCodeCLI.UI.Paint.Metrics do
  @moduledoc "Bounded block measurement derived from the actual cell layout."
  alias SwarmCodeCLI.UI.Paint.{Blocks, Options}
  @base %{foreground: nil, background: nil, modifiers: []}
  def height(block, width, options \\ %Options{}, max_rows \\ 200, policy \\ :narrow) do
    items = if is_list(block), do: block, else: [block]

    case Blocks.lines(items, width, options, @base, max_rows, policy) do
      {:ok, lines} -> {:ok, length(lines)}
      error -> error
    end
  end
end
