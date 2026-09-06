defmodule SwarmCodeCLI.UI.Renderer.RatatuiPort.Frame do
  @moduledoc "Bounded version-1 draw frames containing only validated paint cells, palette and cursor."
  import Bitwise
  alias SwarmCodeCLI.UI.Paint.Plan
  alias SwarmCodeCLI.UI.Scene.Cursor
  @max_bytes 33_554_432
  @max_u64 18_446_744_073_709_551_615
  @modes %{monochrome: 0, ansi16: 1, ansi256: 2, truecolor: 3}
  @policies %{narrow: 0, wide: 1}
  @shapes %{block: 0, bar: 1, underline: 2}
  @modifiers %{bold: 1, dim: 2, italic: 4, underlined: 8, reversed: 16}
  @ansi ~w(black red green yellow blue magenta cyan white bright_black bright_red bright_green bright_yellow bright_blue bright_magenta bright_cyan bright_white)a
  @ansi_indices @ansi |> Enum.with_index() |> Map.new()

  @spec encode(Plan.t(), non_neg_integer()) ::
          {:ok, iodata()} | {:error, :invalid_frame | :capacity_exceeded}
  def encode(plan, sequence)
      when is_integer(sequence) and sequence >= 0 and sequence <= @max_u64 do
    with :ok <- Plan.validate(plan) do
      {count, glyphs} = encode_cells(plan.cells, 0, 0, [])
      palette = plan.palette |> Tuple.to_list() |> Enum.map(&style/1)
      policy = Map.fetch!(@policies, plan.ambiguous_width)
      mode = Map.fetch!(@modes, plan.color_mode)

      body = [
        <<1, 3, sequence::64, plan.revision::64, plan.size.columns::16, plan.size.rows::16,
          policy, mode, tuple_size(plan.palette)::16>>,
        cursor(plan.cursor),
        <<count::32>>,
        palette,
        glyphs
      ]

      length = IO.iodata_length(body)

      if length <= @max_bytes,
        do: {:ok, [<<length::32>>, body]},
        else: {:error, :capacity_exceeded}
    else
      _ -> {:error, :invalid_frame}
    end
  rescue
    _ -> {:error, :invalid_frame}
  end

  def encode(_, _), do: {:error, :invalid_frame}

  defp encode_cells(cells, index, count, out) when index == tuple_size(cells),
    do: {count, Enum.reverse(out)}

  defp encode_cells(cells, index, count, out) do
    # Plan validation proved that each following span contains its continuations.
    {:glyph, glyph, width, style} = elem(cells, index)
    entry = [<<width::16, style::16, byte_size(glyph)::32>>, glyph]
    encode_cells(cells, index + width, count + 1, [entry | out])
  end

  defp style(entry) do
    bits =
      Enum.reduce(entry.modifiers, 0, fn modifier, bits ->
        bits ||| Map.fetch!(@modifiers, modifier)
      end)

    [color(entry.foreground), color(entry.background), <<bits>>]
  end

  defp color(nil), do: <<0>>
  defp color({:ansi, name}), do: <<1, Map.fetch!(@ansi_indices, name)>>
  defp color({:indexed, index}), do: <<2, index>>
  defp color({:rgb, red, green, blue}), do: <<3, red, green, blue>>
  defp cursor(nil), do: <<0>>

  defp cursor(%Cursor{} = cursor),
    do:
      <<1, cursor.x::16, cursor.y::16, Map.fetch!(@shapes, cursor.shape),
        if(cursor.visible?, do: 1, else: 0)>>
end
