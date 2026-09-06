defmodule SwarmCodeCLI.UI.Editor.VisibleSlice do
  @moduledoc """
  Grapheme-aligned source context around the caret, at most 8,192 UTF-8 bytes.

  All indices and logical row/cell positions are zero-based and absolute in
  the editor. `cursor_offset` is relative to `start`. Columns × rows requests
  a context size in graphemes; the projector must cell-clip after SafeText
  expansion. Logical cells use the supplied width policy, including contextual
  ligatures. An individual grapheme over the source limit is omitted whole;
  `omitted_before?`/`omitted_after?` let the projector indicate hidden content.
  """
  alias SwarmCodeCLI.UI.Editor
  alias SwarmCodeCLI.UI.Editor.Buffer
  alias SwarmCodeCLI.UI.Width
  @limit 8192
  @derive {Inspect, only: [:start, :end, :cursor_row, :cursor_cell]}
  defstruct text: "",
            start: 0,
            end: 0,
            cursor_offset: 0,
            cursor_row: 0,
            cursor_cell: 0,
            start_row: 0,
            start_cell: 0,
            end_row: 0,
            end_cell: 0,
            selection_edges: nil,
            columns: 1,
            rows: 1,
            ambiguous_width: :narrow,
            omitted_before?: false,
            omitted_after?: false

  @type t :: %__MODULE__{}

  def new(editor, columns, rows, ambiguous)
      when is_integer(columns) and columns > 0 and is_integer(rows) and rows > 0 and
             ambiguous in [:narrow, :wide] do
    budget = min(columns * rows, @limit)
    {left, left_bytes} = take(editor.buffer.left, div(@limit, 2), div(budget, 2))
    {right, right_bytes} = take(editor.buffer.right, @limit - left_bytes, budget - length(left))
    # At buffer edges, use the unused allowance on the other side.
    {left, _} = take(editor.buffer.left, @limit - right_bytes, budget - length(right))
    start = Editor.cursor(editor) - length(left)
    ending = Editor.cursor(editor) + length(right)
    selection = Editor.selection(editor)

    indices =
      [start, ending, Editor.cursor(editor)] ++
        if(selection, do: Tuple.to_list(selection), else: [])

    positions = positions(Buffer.graphemes(editor.buffer), MapSet.new(indices), ambiguous)
    {cursor_row, cursor_cell} = Map.fetch!(positions, Editor.cursor(editor))
    {start_row, start_cell} = Map.fetch!(positions, start)
    {end_row, end_cell} = Map.fetch!(positions, ending)

    %__MODULE__{
      text: IO.iodata_to_binary([Enum.reverse(left), right]),
      start: start,
      end: ending,
      cursor_offset: Editor.cursor(editor) - start,
      cursor_row: cursor_row,
      cursor_cell: cursor_cell,
      start_row: start_row,
      start_cell: start_cell,
      end_row: end_row,
      end_cell: end_cell,
      selection_edges:
        if(selection,
          do:
            {Map.fetch!(positions, elem(selection, 0)), Map.fetch!(positions, elem(selection, 1))}
        ),
      columns: columns,
      rows: rows,
      ambiguous_width: ambiguous,
      omitted_before?: start > 0,
      omitted_after?: ending < editor.buffer.count
    }
  end

  defp take(gs, bytes, count), do: take(gs, bytes, count, [], 0)
  defp take([], _bytes, _count, acc, used), do: {Enum.reverse(acc), used}
  defp take(_gs, _bytes, 0, acc, used), do: {Enum.reverse(acc), used}

  defp take([g | rest], bytes, count, acc, used) do
    if byte_size(g) <= bytes,
      do: take(rest, bytes - byte_size(g), count - 1, [g | acc], used + byte_size(g)),
      else: {Enum.reverse(acc), used}
  end

  defp positions(gs, indices, ambiguous), do: positions(gs, indices, ambiguous, 0, 0, [], %{})

  defp positions(gs, indices, ambiguous, index, row, line, acc) do
    acc =
      if MapSet.member?(indices, index) do
        cell = line |> Enum.reverse() |> IO.iodata_to_binary() |> Width.cells(ambiguous)
        Map.put(acc, index, {row, cell})
      else
        acc
      end

    case gs do
      [] ->
        acc

      [g | rest] ->
        if Editor.newline?(g),
          do: positions(rest, indices, ambiguous, index + 1, row + 1, [], acc),
          else: positions(rest, indices, ambiguous, index + 1, row, [g | line], acc)
    end
  end
end
