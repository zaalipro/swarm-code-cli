defmodule SwarmCodeCLI.UI.Editor do
  @moduledoc """
  Pure bounded logical-grapheme editor. No timers or composition lifecycle.

  `ambiguous_width` (default `:narrow`) controls vertical movement. The runtime
  replaces its 1,000 ms boundary timer after an edit using `undo_group_id/1`.
  IDs are local to this editor and must be routed to the originating editor.
  Words are Unicode letters/numbers/marks/underscore, punctuation runs, or
  whitespace; forward word motion consumes a run and trailing whitespace.
  History byte accounting counts the exact inserted and removed UTF-8 payloads
  in inverse splices across BOTH undo and redo; cursor metadata is bounded by
  the record count. Oversized groups are evicted whole without changing text.

  The vim primitives are closed operations so one key stays one action. The
  single unnamed `register` holds `{text, :charwise | :linewise}` and is filled
  only by `{:delete, span}` and `{:yank, span}`; linewise text always ends in
  exactly one newline. `{:delete, span}` extends the selection by the span and
  removes it as one record; `{:times, n, op}` folds `op` and records once,
  atomically, appending register writes in document order. The register is
  never inspected and is dropped by `reset/1`.
  """
  import Kernel, except: [apply: 2]
  alias __MODULE__.{Buffer, Operation, Selection, VisibleSlice}
  alias SwarmCodeCLI.UI.Width
  @derive {Inspect, only: [:max_bytes, :undo_bytes, :undo_count, :ambiguous_width]}
  defstruct buffer: %Buffer{},
            anchor: nil,
            preferred_cell: nil,
            max_bytes: 262_144,
            undo_bytes: 1_048_576,
            undo_count: 100,
            ambiguous_width: :narrow,
            undo: [],
            redo: [],
            group: nil,
            boundary_seq: 0,
            register: nil

  @type t :: %__MODULE__{}
  @type register :: nil | {binary(), :charwise | :linewise}
  @type error ::
          :paste_too_large | :fragment_too_large | :text_too_large | :invalid_editor_operation

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    allowed = [:max_bytes, :undo_bytes, :undo_count, :ambiguous_width]

    unless Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in allowed)),
      do: raise(ArgumentError, "invalid editor options")

    editor = struct!(__MODULE__, opts)

    unless Enum.all?(
             [editor.max_bytes, editor.undo_bytes, editor.undo_count],
             &(is_integer(&1) and &1 > 0)
           ) and editor.ambiguous_width in [:narrow, :wide],
           do: raise(ArgumentError, "invalid editor bounds or width policy")

    editor
  end

  @doc "Clear text and derived history while retaining bounds, width policy and timer identity."
  @spec reset(t()) :: t()
  def reset(editor) do
    %__MODULE__{
      max_bytes: editor.max_bytes,
      undo_bytes: editor.undo_bytes,
      undo_count: editor.undo_count,
      ambiguous_width: editor.ambiguous_width,
      boundary_seq: editor.boundary_seq
    }
  end

  @spec text_bytes(t()) :: non_neg_integer()
  def text_bytes(editor), do: editor.buffer.bytes

  @spec text(t()) :: binary()
  def text(editor), do: Buffer.text(editor.buffer)
  @spec cursor(t()) :: non_neg_integer()
  def cursor(editor), do: editor.buffer.cursor
  @spec selection(t()) :: Selection.t()
  def selection(editor), do: Selection.range(editor.anchor, cursor(editor))

  @spec selected_text(t()) :: binary()
  def selected_text(editor) do
    case selection(editor) do
      nil -> ""
      {from, to} -> text_range(editor, from, to)
    end
  end

  @doc "The unnamed register: `{text, :charwise | :linewise}` or nil. Never inspected."
  @spec register(t()) :: register()
  def register(editor), do: editor.register

  defp text_range(_editor, from, to) when from >= to, do: ""

  defp text_range(editor, from, to) do
    editor.buffer
    |> Buffer.seek(from)
    |> Map.fetch!(:right)
    |> Enum.take(to - from)
    |> IO.iodata_to_binary()
  end

  @spec undo_group_id(t()) :: nil | binary()
  def undo_group_id(%{group: nil}), do: nil
  def undo_group_id(%{group: group}), do: group.id

  @spec visible_slice(t(), pos_integer(), pos_integer(), :narrow | :wide) :: VisibleSlice.t()
  def visible_slice(editor, columns, rows, ambiguous),
    do: VisibleSlice.new(editor, columns, rows, ambiguous)

  @spec apply(t(), Operation.t()) :: {:ok, t()} | {:error, error()}
  def apply(editor, operation) do
    with :ok <- Operation.admit(operation), {:ok, _} <- Operation.validate(operation) do
      operate(editor, operation)
    end
  end

  defp operate(editor, {:undo_boundary, id}) do
    {:ok, if(undo_group_id(editor) == id, do: close(editor), else: editor)}
  end

  defp operate(editor, {kind, value}) when kind in [:insert, :paste],
    do: replace(editor, value, kind, replacement_range(editor))

  defp operate(editor, :newline), do: replace(editor, "\n", :newline, replacement_range(editor))

  defp operate(editor, deletion)
       when deletion in [
              :delete_backward,
              :delete_forward,
              :delete_word_backward,
              :delete_word_forward
            ] do
    range = selection(editor) || deletion_range(editor, deletion)
    replace(editor, "", deletion, range)
  end

  defp operate(editor, {kind, movement}) when kind in [:move, :extend_selection] do
    {target, preferred} = movement_target(editor, movement, kind)
    anchor = if kind == :extend_selection, do: editor.anchor || cursor(editor), else: nil

    {:ok,
     %{
       close(editor)
       | buffer: Buffer.seek(editor.buffer, target),
         anchor: anchor,
         preferred_cell: preferred
     }}
  end

  # One record: the span is resolved against the pre-edit buffer, the register
  # takes the exact removed payload and the whole removal is a single splice.
  defp operate(editor, {:delete, span}) do
    case span(editor, span) do
      nil ->
        {:ok, editor}

      {{from, to}, _text, _wise} when from == to ->
        {:ok, editor}

      {range, text, wise} ->
        with {:ok, deleted} <- replace(editor, "", :delete_span, range) do
          deleted = %{deleted | register: {text, wise}}

          if wise == :linewise,
            do: recursor({:ok, deleted}, logical_target(deleted.buffer, :line_start)),
            else: {:ok, deleted}
        end
    end
  end

  defp operate(editor, {:yank, span}) do
    case span(editor, span) do
      nil -> {:ok, editor}
      {_range, "", _wise} -> {:ok, editor}
      {{from, _to}, text, wise} -> {:ok, yanked(editor, span, from, {text, wise})}
    end
  end

  defp operate(editor, put) when put in [:put_after, :put_before] do
    case editor.register do
      nil -> {:ok, editor}
      {"", _wise} -> {:ok, editor}
      {text, :linewise} -> put_lines(editor, text, put)
      {text, :charwise} -> put_chars(editor, text, put)
    end
  end

  # History operations move records between the two stacks, so a count is just
  # repetition; everything else folds into a single record below.
  defp operate(editor, {:times, count, operation}) when operation in [:undo, :redo],
    do: repeat({:ok, editor}, count, operation)

  defp operate(editor, {:times, count, {:undo_boundary, _} = operation}),
    do: repeat({:ok, editor}, count, operation)

  defp operate(editor, {:times, count, operation}), do: fold(editor, count, operation)

  defp operate(editor, :select_all),
    do:
      {:ok,
       %{
         close(editor)
         | buffer: Buffer.seek(editor.buffer, editor.buffer.count),
           anchor: 0,
           preferred_cell: nil
       }}

  defp operate(editor, :undo), do: history(close(editor), :undo)
  defp operate(editor, :redo), do: history(close(editor), :redo)

  defp close(editor), do: %{editor | group: nil}
  defp replacement_range(editor), do: selection(editor) || {cursor(editor), cursor(editor)}

  # {range to remove, exact register payload, wiseness}, or nil for a span that
  # covers nothing. A motion span is the selection extended by that motion, so
  # an open selection is part of the operand exactly as `{:extend_selection, m}`
  # would leave it.
  defp span(editor, :selection) do
    case selection(editor) do
      nil -> nil
      {from, to} = range -> {range, text_range(editor, from, to), :charwise}
    end
  end

  defp span(editor, :line) do
    buffer = editor.buffer
    from = logical_target(buffer, :line_start)
    to = logical_target(buffer, :line_end)

    range =
      cond do
        # The line's own newline, or on the last line the preceding one, as vim.
        to < buffer.count -> {from, to + 1}
        from > 0 -> {from - 1, to}
        true -> {from, to}
      end

    {range, text_range(editor, from, to) <> "\n", :linewise}
  end

  defp span(editor, movement) do
    anchor = editor.anchor || cursor(editor)
    {target, _preferred} = movement_target(editor, movement, :extend_selection)

    case Selection.range(anchor, target) do
      nil -> nil
      {from, to} = range -> {range, text_range(editor, from, to), :charwise}
    end
  end

  # `yy` holds the caret; a motion or selection yank collapses to the start of
  # the operand, as vim does when the operator ends.
  defp yanked(editor, :line, _from, register), do: %{close(editor) | register: register}

  defp yanked(editor, _span, from, register) do
    %{
      close(editor)
      | buffer: Buffer.seek(editor.buffer, from),
        anchor: nil,
        preferred_cell: nil,
        register: register
    }
  end

  defp put_lines(editor, text, put) do
    buffer = editor.buffer
    from = logical_target(buffer, :line_start)
    to = logical_target(buffer, :line_end)

    {at, inserted} =
      case put do
        :put_before -> {from, text}
        # A last line with no newline of its own borrows one for the new block.
        :put_after when to < buffer.count -> {to + 1, text}
        :put_after -> {to, "\n" <> String.replace_suffix(text, "\n", "")}
      end

    put(editor, inserted, at, if(put == :put_before, do: from, else: to + 1))
  end

  # `p` lands after the caret's grapheme but never past the line, like vim,
  # where the caret cannot sit on the newline; `P` lands on the caret. Both
  # leave the caret on the last put grapheme, so a repeat stays contiguous.
  defp put_chars(editor, text, :put_before),
    do: put(editor, text, cursor(editor), :last_grapheme)

  defp put_chars(editor, text, :put_after) do
    at = min(cursor(editor) + 1, logical_target(editor.buffer, :line_end))
    put(editor, text, at, :last_grapheme)
  end

  defp put(editor, text, at, cursor_after) do
    if editor.buffer.bytes + byte_size(text) > editor.max_bytes do
      {:error, :fragment_too_large}
    else
      editor |> replace(text, :put, {at, at}) |> recursor(cursor_after)
    end
  end

  # Placing the caret away from the end of the splice has to travel with the
  # record, or redo would restore the caret the splice alone implies.
  defp recursor({:error, _reason} = error, _position), do: error
  defp recursor({:ok, editor}, nil), do: {:ok, editor}

  # Resegmentation can move the splice end, so step back from where the buffer
  # actually left the caret rather than from a counted grapheme length.
  defp recursor({:ok, editor}, :last_grapheme),
    do: recursor({:ok, editor}, max(cursor(editor) - 1, 0))

  defp recursor({:ok, editor}, position) do
    updated = %{editor | buffer: Buffer.seek(editor.buffer, position)}

    case updated.undo do
      [record | rest] -> {:ok, %{updated | undo: [%{record | after: mark(updated)} | rest]}}
      [] -> {:ok, updated}
    end
  end

  defp repeat({:error, _reason} = error, _count, _operation), do: error
  defp repeat({:ok, _editor} = result, 0, _operation), do: result

  defp repeat({:ok, editor}, count, operation),
    do: repeat(operate(editor, operation), count - 1, operation)

  # The fold runs on history bounds it cannot hit so no step is evicted before
  # the whole repeat becomes the one record the real bounds then judge.
  defp fold(editor, count, operation) do
    scratch = %{
      editor
      | undo: [],
        redo: [],
        group: nil,
        undo_count: count + 1,
        undo_bytes: count * 2 * editor.max_bytes + 1
    }

    with {:ok, folded} <- fold_steps({:ok, scratch}, count, operation, false),
         do: {:ok, commit(editor, folded)}
  end

  defp fold_steps({:ok, editor}, 0, _operation, _written), do: {:ok, editor}

  defp fold_steps({:ok, editor}, count, operation, written) do
    case operate(editor, operation) do
      {:ok, next} ->
        fold_steps(
          {:ok, accumulate(editor, next, written)},
          count - 1,
          operation,
          written or next.register != editor.register
        )

      {:error, _reason} = error ->
        error
    end
  end

  # A repeated delete or yank grows one register in document order, so `2dw`
  # and `2db` both put back exactly what they took.
  defp accumulate(_editor, next, false), do: next

  defp accumulate(editor, next, true) do
    case {editor.register, next.register} do
      {same, same} ->
        next

      {{previous, wise}, {added, wise}} ->
        text =
          if next.buffer.cursor < editor.buffer.cursor,
            do: added <> previous,
            else: previous <> added

        %{next | register: {text, wise}}

      {_previous, _added} ->
        next
    end
  end

  defp commit(editor, folded) do
    restored = %{
      folded
      | undo_count: editor.undo_count,
        undo_bytes: editor.undo_bytes,
        group: nil
    }

    case folded.undo do
      [] ->
        %{restored | undo: editor.undo, redo: editor.redo}

      records ->
        record = %{
          patches: Enum.flat_map(records, & &1.patches),
          bytes: Enum.reduce(records, 0, &(&1.bytes + &2)),
          before: mark(editor),
          after: mark(folded)
        }

        %{
          restored
          | undo: trim([record | editor.undo], editor.undo_count, editor.undo_bytes),
            redo: []
        }
    end
  end

  defp deletion_range(editor, kind) do
    movement =
      case kind do
        :delete_backward -> :left
        :delete_forward -> :right
        :delete_word_backward -> :word_left
        :delete_word_forward -> :word_right
      end

    {target, _} = movement_target(%{editor | anchor: nil}, movement, :move)
    {min(target, cursor(editor)), max(target, cursor(editor))}
  end

  defp replace(editor, inserted, kind, {from, to}) do
    removed_bytes =
      editor.buffer
      |> Buffer.seek(from)
      |> Map.fetch!(:right)
      |> Enum.take(to - from)
      |> Enum.reduce(0, &(byte_size(&1) + &2))

    cond do
      editor.buffer.bytes - removed_bytes + byte_size(inserted) > editor.max_bytes ->
        {:error, :text_too_large}

      from == to and inserted == "" ->
        {:ok, if(kind in [:paste, :newline], do: close(editor), else: editor)}

      true ->
        {buffer, patch} = Buffer.replace(editor.buffer, from, to, inserted)
        after_editor = %{editor | buffer: buffer, anchor: nil, preferred_cell: nil, redo: []}

        record = %{
          patches: [patch],
          bytes: byte_size(patch.removed) + byte_size(patch.inserted),
          before: mark(editor),
          after: mark(after_editor)
        }

        contiguous =
          kind in [
            :insert,
            :delete_backward,
            :delete_forward,
            :delete_word_backward,
            :delete_word_forward
          ] and selection(editor) == nil

        join =
          contiguous and editor.group != nil and editor.group.kind == kind and editor.undo != []

        undo =
          if join do
            [previous | rest] = editor.undo

            [
              %{
                previous
                | patches: [patch | previous.patches],
                  bytes: previous.bytes + record.bytes,
                  after: record.after
              }
              | rest
            ]
          else
            [record | editor.undo]
          end

        seq = editor.boundary_seq + 1

        after_editor = %{
          after_editor
          | undo: trim(undo, editor.undo_count, editor.undo_bytes),
            boundary_seq: seq
        }

        group =
          if contiguous and after_editor.undo != [],
            do: %{kind: kind, id: "editor-#{seq}"},
            else: nil

        {:ok, %{after_editor | group: group}}
    end
  end

  defp trim(records, count, bytes), do: trim(records, count, bytes, [])
  defp trim([], _count, _bytes, acc), do: Enum.reverse(acc)
  defp trim(_records, 0, _bytes, acc), do: Enum.reverse(acc)

  defp trim([record | rest], count, bytes, acc) do
    if record.bytes <= bytes,
      do: trim(rest, count - 1, bytes - record.bytes, [record | acc]),
      else: Enum.reverse(acc)
  end

  defp mark(editor),
    do: %{cursor: cursor(editor), anchor: editor.anchor, preferred_cell: editor.preferred_cell}

  defp history(editor, direction) do
    source = Map.fetch!(editor, direction)
    destination = if direction == :undo, do: :redo, else: :undo

    case source do
      [] ->
        {:ok, editor}

      [record | rest] ->
        patches = if direction == :undo, do: record.patches, else: Enum.reverse(record.patches)

        buffer =
          Enum.reduce(patches, editor.buffer, fn patch, buffer ->
            if direction == :undo,
              do: Buffer.splice(buffer, patch.offset, byte_size(patch.inserted), patch.removed),
              else: Buffer.splice(buffer, patch.offset, byte_size(patch.removed), patch.inserted)
          end)

        mark = if direction == :undo, do: record.before, else: record.after

        updated = %{
          editor
          | buffer: Buffer.seek(buffer, mark.cursor),
            anchor: mark.anchor,
            preferred_cell: mark.preferred_cell
        }

        {:ok,
         updated
         |> Map.put(direction, rest)
         |> Map.put(destination, [record | Map.fetch!(editor, destination)])}
    end
  end

  defp movement_target(editor, movement, kind) do
    selected = selection(editor)

    cond do
      kind == :move and selected != nil and movement in [:left, :right] ->
        {elem(selected, if(movement == :left, do: 0, else: 1)), nil}

      movement in [:up, :down] ->
        vertical(editor, movement)

      true ->
        {logical_target(editor.buffer, movement), nil}
    end
  end

  defp logical_target(buffer, :left), do: max(buffer.cursor - 1, 0)
  defp logical_target(buffer, :right), do: min(buffer.cursor + 1, buffer.count)
  defp logical_target(_buffer, :buffer_start), do: 0
  defp logical_target(buffer, :buffer_end), do: buffer.count

  defp logical_target(buffer, :line_start),
    do: buffer.cursor - length(Enum.take_while(buffer.left, &(not newline?(&1))))

  defp logical_target(buffer, :line_end),
    do: buffer.cursor + length(Enum.take_while(buffer.right, &(not newline?(&1))))

  defp logical_target(buffer, :word_left),
    do: buffer.cursor - blanks_then_run(buffer.left)

  defp logical_target(buffer, :word_right),
    do: buffer.cursor + run_then_blanks(buffer.right)

  # Caret-relative vim `e`: the first word end strictly after the caret, so it
  # ends the word the caret sits inside and otherwise ends the next one. With
  # only blanks ahead it clamps to the buffer end, like forward word motion.
  defp logical_target(buffer, :word_end),
    do: buffer.cursor + blanks_then_run(buffer.right)

  # Vim `^`: the first non-blank of the logical line, which is the line end on
  # a blank line. Absolute for the line, not relative to the caret.
  defp logical_target(buffer, :first_nonblank) do
    start = logical_target(buffer, :line_start)
    line = buffer |> Buffer.seek(start) |> Map.fetch!(:right)

    blanks =
      line |> Enum.take_while(&(not newline?(&1))) |> Enum.take_while(&(class(&1) == :space))

    start + length(blanks)
  end

  defp blanks_then_run(gs) do
    {blanks, rest} = Enum.split_while(gs, &(class(&1) == :space))
    length(blanks) + run_length(rest)
  end

  defp run_then_blanks(gs) do
    n = run_length(gs)
    n + length(gs |> Enum.drop(n) |> Enum.take_while(&(class(&1) == :space)))
  end

  defp run_length([]), do: 0
  defp run_length([g | _] = gs), do: length(Enum.take_while(gs, &(class(&1) == class(g))))

  defp class(g) do
    cond do
      String.trim(g) == "" -> :space
      Regex.match?(~r/^[\p{L}\p{N}\p{M}_]/u, g) -> :word
      true -> :punctuation
    end
  end

  @doc false
  def newline?(g), do: g in ["\n", "\r\n", "\r"]

  defp vertical(editor, direction) do
    buffer = editor.buffer
    start = logical_target(buffer, :line_start)

    line_prefix =
      buffer.left |> Enum.take(buffer.cursor - start) |> Enum.reverse() |> IO.iodata_to_binary()

    preferred = editor.preferred_cell || Width.cells(line_prefix, editor.ambiguous_width)

    target_start =
      case direction do
        :up when start == 0 ->
          nil

        :up ->
          buffer |> Buffer.seek(start - 1) |> logical_target(:line_start)

        :down ->
          ending = logical_target(buffer, :line_end)
          if ending == buffer.count, do: nil, else: ending + 1
      end

    if target_start == nil do
      {buffer.cursor, preferred}
    else
      line =
        buffer
        |> Buffer.seek(target_start)
        |> Map.fetch!(:right)
        |> Enum.take_while(&(not newline?(&1)))

      {target_start + cell_index(line, preferred, editor.ambiguous_width), preferred}
    end
  end

  defp cell_index(line, preferred, ambiguous) do
    # Measure original prefixes, not sums of isolated grapheme widths: the
    # latter lose contextual ligatures. Search grapheme boundaries to avoid
    # measuring every growing prefix of a maximum-size logical line.
    text = IO.iodata_to_binary(line)
    offsets = line |> Enum.scan(0, &(byte_size(&1) + &2))
    offsets = List.to_tuple([0 | offsets])
    count = tuple_size(offsets) - 1

    if Width.cells(text, ambiguous) <= preferred,
      do: count,
      else: cell_boundary(text, offsets, preferred, ambiguous, 0, count)
  end

  defp cell_boundary(_text, _offsets, _preferred, _ambiguous, low, high) when low + 1 >= high,
    do: low

  defp cell_boundary(text, offsets, preferred, ambiguous, low, high) do
    middle = div(low + high, 2)
    prefix = binary_part(text, 0, elem(offsets, middle))
    following = binary_part(text, 0, elem(offsets, middle + 1))

    # Cross-grapheme contractions (notably a Tifinagh joiner followed by a
    # consonant) can make the following boundary narrower. That completed
    # ligature must remain searchable even if its partial prefix is too wide.
    if min(Width.cells(prefix, ambiguous), Width.cells(following, ambiguous)) <= preferred,
      do: cell_boundary(text, offsets, preferred, ambiguous, middle, high),
      else: cell_boundary(text, offsets, preferred, ambiguous, low, middle)
  end
end
