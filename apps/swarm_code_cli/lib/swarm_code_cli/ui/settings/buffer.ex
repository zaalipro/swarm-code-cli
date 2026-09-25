defmodule SwarmCodeCLI.UI.Settings.Buffer do
  @moduledoc """
  The text of a settings editor and its caret (a grapheme index), pure. The
  settings editors keep their text here rather than in `UI.FieldEditors`:
  the layer owns and drops them with itself, and a secret never enters one
  (secrets are the paste target's, `Settings.Paste`).

  Editing is bounded by `max` bytes: an insert or a paste that would pass it
  is refused whole (the editor says so), never cut.
  """

  defstruct text: "", caret: 0, max: 4_096, multiline?: false

  @type t :: %__MODULE__{
          text: String.t(),
          caret: non_neg_integer(),
          max: pos_integer(),
          multiline?: boolean()
        }

  @doc "A buffer holding `text` with the caret at its end."
  @spec new(String.t(), keyword()) :: t()
  def new(text, opts \\ []) when is_binary(text) do
    %__MODULE__{
      text: text,
      caret: String.length(text),
      max: Keyword.get(opts, :max, 4_096),
      multiline?: Keyword.get(opts, :multiline?, false)
    }
  end

  @doc "The text before and after the caret."
  @spec split(t()) :: {String.t(), String.t()}
  def split(%__MODULE__{text: text, caret: caret}),
    do: {String.slice(text, 0, caret), String.slice(text, caret..-1//1)}

  @doc "Inserts `text` at the caret; `{:error, :too_long}` when it would pass the bound."
  @spec insert(t(), String.t()) :: {:ok, t()} | {:error, :too_long | :multiline}
  def insert(%__MODULE__{} = buffer, text) do
    text = if buffer.multiline?, do: String.replace(text, "\r\n", "\n"), else: text

    cond do
      not buffer.multiline? and String.contains?(text, ["\n", "\r"]) ->
        {:error, :multiline}

      byte_size(buffer.text) + byte_size(text) > buffer.max ->
        {:error, :too_long}

      true ->
        {before, rest} = split(buffer)
        {:ok, %{buffer | text: before <> text <> rest, caret: buffer.caret + String.length(text)}}
    end
  end

  @doc "Replaces the whole text (the caret goes to its end); bounded like an insert."
  @spec replace(t(), String.t()) :: {:ok, t()} | {:error, :too_long}
  def replace(%__MODULE__{} = buffer, text) do
    if byte_size(text) > buffer.max,
      do: {:error, :too_long},
      else: {:ok, %{buffer | text: text, caret: String.length(text)}}
  end

  @doc "One editing key: moves and deletions."
  @spec key(t(), term()) :: t()
  def key(%__MODULE__{} = buffer, :left), do: %{buffer | caret: max(buffer.caret - 1, 0)}

  def key(%__MODULE__{} = buffer, :right),
    do: %{buffer | caret: min(buffer.caret + 1, String.length(buffer.text))}

  def key(%__MODULE__{} = buffer, :home), do: %{buffer | caret: line_start(buffer)}
  def key(%__MODULE__{} = buffer, :end), do: %{buffer | caret: line_end(buffer)}
  def key(%__MODULE__{} = buffer, {:ctrl, "a"}), do: key(buffer, :home)
  def key(%__MODULE__{} = buffer, {:ctrl, "e"}), do: key(buffer, :end)

  def key(%__MODULE__{caret: 0} = buffer, :backspace), do: buffer

  def key(%__MODULE__{} = buffer, :backspace) do
    {before, rest} = split(buffer)
    %{buffer | text: String.slice(before, 0, buffer.caret - 1) <> rest, caret: buffer.caret - 1}
  end

  def key(%__MODULE__{} = buffer, :delete) do
    {before, rest} = split(buffer)
    %{buffer | text: before <> String.slice(rest, 1..-1//1)}
  end

  # Ctrl-W: the word before the caret (and the spaces after it).
  def key(%__MODULE__{} = buffer, {:ctrl, "w"}) do
    {before, rest} = split(buffer)
    kept = Regex.replace(~r/\S*\s*\z/u, before, "", global: false)
    %{buffer | text: kept <> rest, caret: String.length(kept)}
  end

  # Ctrl-U: everything before the caret.
  def key(%__MODULE__{} = buffer, {:ctrl, "u"}) do
    {_before, rest} = split(buffer)
    %{buffer | text: rest, caret: 0}
  end

  def key(%__MODULE__{multiline?: true} = buffer, :up), do: vertical(buffer, -1)
  def key(%__MODULE__{multiline?: true} = buffer, :down), do: vertical(buffer, 1)
  def key(%__MODULE__{} = buffer, _key), do: buffer

  @doc "The lines of the text (one for a single-line buffer)."
  @spec lines(t()) :: [String.t()]
  def lines(%__MODULE__{text: text}), do: String.split(text, "\n")

  @doc "The caret's line and column."
  @spec position(t()) :: {non_neg_integer(), non_neg_integer()}
  def position(%__MODULE__{} = buffer) do
    {before, _rest} = split(buffer)
    lines = String.split(before, "\n")
    {length(lines) - 1, String.length(List.last(lines))}
  end

  defp line_start(buffer) do
    {line, column} = position(buffer)
    _ = line
    buffer.caret - column
  end

  defp line_end(buffer) do
    {line, _column} = position(buffer)
    lines = lines(buffer)
    start = line_start(buffer)
    start + String.length(Enum.at(lines, line))
  end

  defp vertical(buffer, delta) do
    {line, column} = position(buffer)
    lines = lines(buffer)
    target = line + delta

    if target < 0 or target >= length(lines) do
      buffer
    else
      offset =
        lines
        |> Enum.take(target)
        |> Enum.map(&(String.length(&1) + 1))
        |> Enum.sum()

      %{buffer | caret: offset + min(column, String.length(Enum.at(lines, target)))}
    end
  end
end
