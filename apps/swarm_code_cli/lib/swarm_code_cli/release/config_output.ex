defmodule SwarmCodeCLI.Release.ConfigOutput do
  @moduledoc "Bounded, terminal-inert human config cells, separate from semantic JSON."

  alias SwarmCodeCLI.UI.SafeText
  alias SwarmCodeCLI.UI.SafeText.Limits

  @spec cell(binary()) :: binary()
  def cell(binary) when is_binary(binary) do
    case SafeText.external(binary, Limits.content()) do
      {:ok, text} ->
        text
        |> SafeText.value()
        |> String.replace("\n", "\\n")
        |> String.replace("\r", "\\r")

      {:error, _reason} ->
        "[value exceeds display limit]"
    end
  end
end
