defmodule SwarmCodeCLI.UI.Editor.Operation do
  @moduledoc "The closed renderer-independent grapheme editor operation vocabulary."

  alias SwarmCodeCLI.UI.Intent

  @max_fragment_bytes 4_096
  @max_paste_bytes 262_144
  @max_times 999

  @type movement ::
          :left
          | :right
          | :up
          | :down
          | :word_left
          | :word_right
          | :word_end
          | :line_start
          | :first_nonblank
          | :line_end
          | :buffer_start
          | :buffer_end

  @type span :: movement() | :line | :selection

  @type t ::
          {:insert, binary()}
          | {:paste, binary()}
          | :delete_backward
          | :delete_forward
          | :delete_word_backward
          | :delete_word_forward
          | {:move, movement()}
          | {:extend_selection, movement()}
          | {:delete, span()}
          | {:yank, span()}
          | :put_after
          | :put_before
          | {:times, pos_integer(), t()}
          | :select_all
          | :undo
          | :redo
          | :newline
          | {:undo_boundary, binary()}

  @movements [
    :left,
    :right,
    :up,
    :down,
    :word_left,
    :word_right,
    :word_end,
    :line_start,
    :first_nonblank,
    :line_end,
    :buffer_start,
    :buffer_end
  ]

  @spans @movements ++ [:line, :selection]

  @simple_operations [
    :delete_backward,
    :delete_forward,
    :delete_word_backward,
    :delete_word_forward,
    :put_after,
    :put_before,
    :select_all,
    :undo,
    :redo,
    :newline
  ]

  @doc false
  def movements, do: @movements

  @doc false
  def max_fragment_bytes, do: @max_fragment_bytes

  @doc "Actionable size errors for Editor.apply; validate/1 keeps its closed-contract result."
  def admit({:paste, text}) when is_binary(text) and byte_size(text) > @max_paste_bytes,
    do: {:error, :paste_too_large}

  def admit({:insert, text}) when is_binary(text) and byte_size(text) > @max_fragment_bytes,
    do: {:error, :fragment_too_large}

  # A repeat is admitted exactly like the operation it folds; the buffer bound is
  # enforced per fold step by the editor.
  def admit({:times, count, operation}) when is_integer(count), do: admit(operation)

  def admit(_operation), do: :ok

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_editor_operation}
  def validate(operation) when operation in @simple_operations, do: {:ok, operation}

  def validate({kind, movement} = operation)
      when kind in [:move, :extend_selection] and movement in @movements,
      do: {:ok, operation}

  def validate({kind, span} = operation)
      when kind in [:delete, :yank] and span in @spans,
      do: {:ok, operation}

  # No nesting: a count is a single flat repeat of one primitive operation.
  def validate({:times, _count, {:times, _inner_count, _inner}}),
    do: {:error, :invalid_editor_operation}

  def validate({:times, count, operation})
      when is_integer(count) and count >= 1 and count <= @max_times do
    with {:ok, inner} <- validate(operation), do: {:ok, {:times, count, inner}}
  end

  def validate({:insert, fragment} = operation)
      when is_binary(fragment) and byte_size(fragment) <= @max_fragment_bytes do
    if String.valid?(fragment), do: {:ok, operation}, else: {:error, :invalid_editor_operation}
  end

  def validate({:paste, text} = operation)
      when is_binary(text) and byte_size(text) <= @max_paste_bytes do
    if String.valid?(text), do: {:ok, operation}, else: {:error, :invalid_editor_operation}
  end

  def validate({:undo_boundary, boundary_id} = operation) do
    if Intent.valid_id?(boundary_id),
      do: {:ok, operation},
      else: {:error, :invalid_editor_operation}
  end

  def validate(_operation), do: {:error, :invalid_editor_operation}

  @spec validate!(term()) :: t()
  def validate!(operation) do
    case validate(operation) do
      {:ok, valid} -> valid
      {:error, :invalid_editor_operation} -> raise ArgumentError, "invalid editor operation"
    end
  end
end
