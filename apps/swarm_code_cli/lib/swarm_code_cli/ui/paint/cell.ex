defmodule SwarmCodeCLI.UI.Paint.Cell do
  @moduledoc "Bounded terminal-neutral glyph and continuation values."
  alias SwarmCodeCLI.UI.SafeText

  @type t :: {:glyph, binary(), 1..500, 0..4095} | {:continuation, 0..499}

  @spec glyph?(term(), term(), term()) :: boolean()
  def glyph?(text, width, style),
    do:
      is_integer(width) and width in 1..500 and style?(style) and text?(text, 262_144) and
        inert_glyph?(text)

  @spec style?(term()) :: boolean()
  def style?(style), do: is_integer(style) and style in 0..4095

  @spec id?(term()) :: boolean()
  def id?(id), do: text?(id, 256)

  defp text?(text, limit)
       when is_binary(text) and byte_size(text) > 0 and byte_size(text) <= limit,
       do: printable?(text)

  defp text?(_, _), do: false

  # Check identity without changing the selected binary or its cell boundaries.
  # Opaque IDs are metadata, so only displayed glyphs use this text policy.
  defp inert_glyph?(text) do
    SafeText.value(%SafeText{token: {:external, text}}) == text
  rescue
    ArgumentError -> false
  end

  defp printable?(<<>>), do: true

  defp printable?(<<cp::utf8, rest::binary>>) when cp >= 32 and cp not in 127..159,
    do: printable?(rest)

  defp printable?(_), do: false
end
