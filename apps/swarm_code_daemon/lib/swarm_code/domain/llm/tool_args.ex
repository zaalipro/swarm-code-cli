defmodule SwarmCode.Domain.LLM.ToolArgs do
  @moduledoc """
  Decoding of the `arguments` JSON a provider streams for a tool call.

  Both providers used to swallow a decode failure and hand `%{}` to the tool,
  which then reported `missing required argument "path"` — a message that blames
  the model for the wrong thing and gives it nothing to correct, so it resends
  the same broken call (observed five times in one swarm run, 2026-08-23).
  A failure is a value here, and the agent turns it into a tool error the model
  can act on.
  """

  @max_reason 200

  @doc """
  `{:ok, args}` for a JSON object, `{:error, reason}` for anything else.

  An empty string is the provider's way of saying "no arguments" and stays
  `{:ok, %{}}`; a non-object (`[1,2]`, `"text"`, `null`) is an error, because a
  tool always takes named arguments.
  """
  @spec decode(binary() | term()) :: {:ok, map()} | {:error, String.t()}
  def decode(""), do: {:ok, %{}}

  def decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = args} ->
        {:ok, args}

      {:ok, other} ->
        {:error, "expected a JSON object, got #{type_of(other)}"}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, truncate(Exception.message(error))}

      {:error, other} ->
        {:error, truncate(inspect(other))}
    end
  end

  def decode(other), do: {:error, "expected a JSON object, got #{type_of(other)}"}

  defp type_of(value) when is_list(value), do: "an array"
  defp type_of(value) when is_binary(value), do: "a string"
  defp type_of(value) when is_number(value), do: "a number"
  defp type_of(value) when is_boolean(value), do: "a boolean"
  defp type_of(nil), do: "null"
  defp type_of(_value), do: "something else"

  defp truncate(reason) when byte_size(reason) <= @max_reason, do: reason
  defp truncate(reason), do: binary_part(reason, 0, @max_reason) <> "…"
end
