defmodule SwarmCodeCLI.UI.Editor.Buffer do
  @moduledoc "Two-sided extended-grapheme zipper. Left is nearest-cursor first."
  @derive {Inspect, only: [:cursor, :count, :bytes]}
  defstruct left: [], right: [], cursor: 0, count: 0, bytes: 0, left_bytes: 0
  @type t :: %__MODULE__{}

  def new(text \\ "") do
    graphemes = String.graphemes(text)
    %__MODULE__{right: graphemes, count: length(graphemes), bytes: byte_size(text)}
  end

  def text(buffer), do: IO.iodata_to_binary([Enum.reverse(buffer.left), buffer.right])
  def graphemes(buffer), do: Enum.reverse(buffer.left, buffer.right)

  def seek(buffer, index), do: do_seek(buffer, min(max(index, 0), buffer.count))
  defp do_seek(%{cursor: index} = buffer, index), do: buffer

  defp do_seek(%{cursor: cursor, left: [g | left]} = buffer, index) when cursor > index,
    do:
      do_seek(
        %{
          buffer
          | left: left,
            right: [g | buffer.right],
            cursor: cursor - 1,
            left_bytes: buffer.left_bytes - byte_size(g)
        },
        index
      )

  defp do_seek(%{cursor: cursor, right: [g | right]} = buffer, index),
    do:
      do_seek(
        %{
          buffer
          | left: [g | buffer.left],
            right: right,
            cursor: cursor + 1,
            left_bytes: buffer.left_bytes + byte_size(g)
        },
        index
      )

  @doc "Replace a grapheme range; return a byte splice for exact inverse history."
  def replace(buffer, from, to, inserted) do
    at = seek(buffer, from)
    {deleted, right} = Enum.split(at.right, to - from)
    removed = IO.iodata_to_binary(deleted)

    {context, left} =
      case at.left do
        [] -> {"", []}
        [g | rest] -> {g, rest}
      end

    local = String.graphemes(context <> inserted) |> Enum.reverse()
    {local, right, consumed} = resegment(local, right, 0)
    local = Enum.reverse(local)
    target_bytes = byte_size(context) + byte_size(inserted)
    {before, after_cursor} = split_at_byte(local, target_bytes, [])
    context_count = if context == "", do: 0, else: 1

    updated = %{
      at
      | left: Enum.reverse(before, left),
        right: after_cursor ++ right,
        cursor: from - context_count + length(before),
        count: buffer.count - (to - from) - context_count - consumed + length(local),
        bytes: buffer.bytes - byte_size(removed) + byte_size(inserted),
        left_bytes: at.left_bytes - byte_size(context) + iodata_bytes(before)
    }

    {updated, %{offset: at.left_bytes, removed: removed, inserted: inserted}}
  end

  # Stop as soon as the next original boundary survives. A changed RI pairing
  # may propagate across the whole RI run; combining/ZWJ joins stay local.
  defp resegment([], right, count), do: {[], right, count}
  defp resegment(local, [], count), do: {local, [], count}

  defp resegment([last | rest] = local, [next | tail] = right, count) do
    case String.graphemes(last <> next) do
      [^last, ^next] -> {local, right, count}
      joined -> resegment(Enum.reverse(joined, rest), tail, count + 1)
    end
  end

  defp split_at_byte(rest, remaining, acc) when remaining <= 0, do: {Enum.reverse(acc), rest}
  defp split_at_byte([], _remaining, acc), do: {Enum.reverse(acc), []}

  defp split_at_byte([g | rest], remaining, acc),
    do: split_at_byte(rest, remaining - byte_size(g), [g | acc])

  defp iodata_bytes(gs), do: Enum.reduce(gs, 0, &(byte_size(&1) + &2))

  @doc "Replay an exact byte splice; history can split a former combining cluster."
  def splice(buffer, offset, length, replacement) do
    first = seek_byte(buffer, offset)
    last = seek_byte(first, offset + length)
    prefix_size = offset - first.left_bytes

    prefix =
      case first.right do
        [g | _] -> binary_part(g, 0, prefix_size)
        [] -> ""
      end

    {ending, suffix} =
      if offset + length == last.left_bytes do
        {last.cursor, ""}
      else
        [g | _] = last.right
        inner = offset + length - last.left_bytes
        {last.cursor + 1, binary_part(g, inner, byte_size(g) - inner)}
      end

    {updated, _patch} =
      replace(first, first.cursor, ending, IO.iodata_to_binary([prefix, replacement, suffix]))

    updated
  end

  defp seek_byte(buffer, offset) when buffer.left_bytes > offset,
    do: seek_byte(seek(buffer, buffer.cursor - 1), offset)

  defp seek_byte(%{right: [g | _]} = buffer, offset)
       when buffer.left_bytes + byte_size(g) <= offset,
       do: seek_byte(seek(buffer, buffer.cursor + 1), offset)

  defp seek_byte(buffer, _offset), do: buffer
end
