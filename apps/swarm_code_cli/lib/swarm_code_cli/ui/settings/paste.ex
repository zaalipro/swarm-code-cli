defmodule SwarmCodeCLI.UI.Settings.Paste do
  @moduledoc """
  The paste target of a secret row (spec §3.7.7). The pasted bytes live here
  and nowhere else in the client until the one command that carries them in
  its `secrets` parameter: never in a field editor, a row, the scene, undo,
  the changelog, a toast, the search index, a log or `inspect/1` (which shows
  only the target and the line count).

  `target` is `%{row_id, action, target, attributes, slot, label, set?, kind}`
  (what the commit sends); `typing?` is Ctrl-T's *type instead*;
  `pending_task` the test-first task that decides a replacement.
  """

  @derive {Inspect, only: [:target, :lines]}
  defstruct target: nil, bytes: "", lines: 0, typing?: false, pending_task: nil, refused: nil

  @type t :: %__MODULE__{
          target: map() | nil,
          bytes: binary(),
          lines: non_neg_integer(),
          typing?: boolean(),
          pending_task: String.t() | nil,
          refused: String.t() | nil
        }

  @min_bytes 8
  @max_bytes 8_192

  @doc "A paste target for `target`, nothing pasted yet."
  @spec new(map()) :: t()
  def new(target) when is_map(target), do: %__MODULE__{target: target}

  @doc "A bracketed paste replaces what was pasted before."
  @spec put(t(), binary()) :: t()
  def put(%__MODULE__{} = paste, bytes) when is_binary(bytes),
    do: %{paste | bytes: bytes, lines: count_lines(bytes), refused: nil}

  @doc "Typed characters (only after Ctrl-T, or where the terminal cannot mark pastes)."
  @spec type(t(), binary()) :: t()
  def type(%__MODULE__{} = paste, text) when is_binary(text) do
    bytes = paste.bytes <> text

    if byte_size(bytes) > @max_bytes,
      do: paste,
      else: %{paste | bytes: bytes, lines: count_lines(bytes)}
  end

  @doc "Ctrl-U: nothing pasted."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = paste), do: %{paste | bytes: "", lines: 0, refused: nil}

  @doc "Whether anything was pasted or typed."
  @spec filled?(t() | nil) :: boolean()
  def filled?(%__MODULE__{bytes: bytes}), do: bytes != ""
  def filled?(_), do: false

  @doc """
  The checks before a paste is sent (the service repeats them): one line, no
  inner whitespace, 8..8 192 bytes after trimming. `{:ok, trimmed}` or
  `{:error, words}`.
  """
  @spec check(t()) :: {:ok, binary()} | {:error, String.t()}
  def check(%__MODULE__{bytes: bytes}) do
    trimmed = String.trim(bytes)
    lines = count_lines(trimmed)

    cond do
      trimmed == "" -> {:error, "paste the key first"}
      lines > 1 -> {:error, "the paste had #{lines} lines; paste only the key"}
      String.match?(trimmed, ~r/\s/u) -> {:error, "a key has no spaces inside"}
      byte_size(trimmed) < @min_bytes -> {:error, "that is too short to be a key"}
      byte_size(trimmed) > @max_bytes -> {:error, "that is too long to be a key"}
      String.contains?(trimmed, <<0>>) -> {:error, "that is not a key"}
      true -> {:ok, trimmed}
    end
  end

  defp count_lines(""), do: 0

  defp count_lines(bytes),
    do: bytes |> String.trim_trailing() |> String.split(["\r\n", "\n", "\r"]) |> length()
end
