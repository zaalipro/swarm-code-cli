defmodule SwarmCode.Domain.Tools.AgentTitle do
  @moduledoc "Cleans the Lead-given display name of a spawned agent (pass 75)."

  @quotes ["\"", "'", "“", "”"]
  @max_words 3
  @max_chars 24
  @max_bytes 32

  @doc """
  The display name the Lead gave a spawned agent, cleaned: its first line
  without control or format characters or one pair of quotes, at most three
  words, 24 characters and 32 bytes, in the Lead's own case. A missing or
  blank title (or one that cleans to nothing) is the agent's `slug`.
  """
  @spec clean(term(), String.t()) :: String.t()
  def clean(title, slug) when is_binary(title) do
    if String.trim(title) == "" do
      slug
    else
      title
      |> String.split(~r/\r?\n/, parts: 2)
      |> hd()
      |> String.replace(~r/[\p{Cc}\p{Cf}]/u, "")
      |> String.trim()
      |> unquote_once()
      |> String.trim()
      |> String.split(~r/\s+/u, trim: true)
      |> Enum.take(@max_words)
      |> Enum.join(" ")
      |> String.slice(0, @max_chars)
      |> within_bytes()
      |> String.trim_trailing()
      |> case do
        "" -> slug
        clean -> clean
      end
    end
  end

  def clean(_title, slug), do: slug

  defp unquote_once(text) do
    text =
      case String.next_grapheme(text) do
        {first, rest} when first in @quotes -> rest
        _ -> text
      end

    case String.last(text) do
      last when last in @quotes -> String.slice(text, 0..-2//1)
      _ -> text
    end
  end

  defp within_bytes(text) do
    text
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.reduce_while(text, fn _grapheme, acc ->
      if byte_size(acc) > @max_bytes,
        do: {:cont, String.slice(acc, 0..-2//1)},
        else: {:halt, acc}
    end)
  end
end
