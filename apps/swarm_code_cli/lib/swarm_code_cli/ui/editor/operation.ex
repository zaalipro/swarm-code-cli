defmodule SwarmCodeCLI.UI.Editor.Operation do
  @moduledoc "The closed renderer-independent grapheme editor operation vocabulary."

  alias SwarmCodeCLI.UI.Intent

  @max_fragment_bytes 4_096
  @max_paste_bytes 262_144

  @type movement ::
          :left
          | :right
          | :up
          | :down
          | :word_left
          | :word_right
          | :line_start
          | :line_end
          | :buffer_start
          | :buffer_end

  @type t ::
          {:insert, binary()}
          | {:paste, binary()}
          | :delete_backward
          | :delete_forward
          | :delete_word_backward
          | :delete_word_forward
          | {:move, movement()}
          | {:extend_selection, movement()}
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
    :line_start,
    :line_end,
    :buffer_start,
    :buffer_end
  ]

  @simple_operations [
    :delete_backward,
    :delete_forward,
    :delete_word_backward,
    :delete_word_forward,
    :select_all,
    :undo,
    :redo,
    :newline
  ]

  @doc "Actionable size errors for Editor.apply; validate/1 keeps its closed-contract result."
  def admit({:paste, text}) when is_binary(text) and byte_size(text) > @max_paste_bytes,
    do: {:error, :paste_too_large}

  def admit({:insert, text}) when is_binary(text) and byte_size(text) > @max_fragment_bytes,
    do: {:error, :fragment_too_large}

  def admit(_operation), do: :ok

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_editor_operation}
  def validate(operation) when operation in @simple_operations, do: {:ok, operation}

  def validate({kind, movement} = operation)
      when kind in [:move, :extend_selection] and movement in @movements,
      do: {:ok, operation}

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
