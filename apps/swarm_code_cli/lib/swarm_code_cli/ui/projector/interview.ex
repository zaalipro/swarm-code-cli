defmodule SwarmCodeCLI.UI.Projector.Interview do
  @moduledoc "pass75 interview: the ask_user note (frames QA1-QA3)."

  alias SwarmCodeCLI.UI.{SafeText, Size}
  alias SwarmCodeCLI.UI.Keymap.Bindings
  alias SwarmCodeCLI.UI.Projector.{Density, KeyLabel}
  alias SwarmCodeCLI.UI.Scene.Rect

  @narrow_classes [:narrow, :small, :compressed_small]

  @doc "The label of the first key bound to `id` under the user's overrides; nil when unbound."
  @spec key(map(), atom()) :: String.t() | nil
  def key(state, id) do
    case id |> Bindings.keys_for(SwarmCodeCLI.UI.Keymap.overrides(state)) |> List.first() do
      nil -> nil
      key -> KeyLabel.label(key, state.capabilities.ascii?)
    end
  end

  @doc """
  The note's rectangle: `min(86, columns - 16)` wide and as tall as its content
  (at most `rows - 4`), centred on the chat (`main`); the whole screen below 100
  columns.
  """
  @spec rect(Size.t(), Rect.t(), atom(), pos_integer()) :: Rect.t()
  def rect(%Size{} = size, _main, class, _content_rows) when class in @narrow_classes,
    do: %Rect{x: 0, y: 0, width: size.columns, height: size.rows}

  def rect(%Size{} = size, %Rect{} = main, _class, content_rows) do
    width = size.columns |> Kernel.-(16) |> min(86) |> max(1) |> min(size.columns)
    height = (content_rows + 2) |> min(size.rows - 4) |> max(3) |> min(size.rows)
    x = main.x + div(main.width - width, 2)
    y = main.y + div(main.height - height, 2)

    %Rect{
      x: x |> max(0) |> min(size.columns - width),
      y: y |> max(0) |> min(size.rows - height),
      width: width,
      height: height
    }
  end

  @doc """
  The rows that fit `max_rows`, and the scroll of the body. Nothing is dropped
  when the rows fit. Else the blank rows go first (bottom-most first), then the
  why row; a body still too tall scrolls the slice between the stepper and the
  keys row so the focused row stays in view.
  """
  @spec fit([{term(), term()}], non_neg_integer(), term()) ::
          {[{term(), term()}], non_neg_integer()}
  def fit(tagged_rows, max_rows, focused_tag) do
    if length(tagged_rows) <= max_rows do
      {tagged_rows, 0}
    else
      rows = drop_blanks(tagged_rows, length(tagged_rows) - max_rows)

      rows =
        if length(rows) > max_rows,
          do: Enum.reject(rows, &(elem(&1, 0) == :why)),
          else: rows

      if length(rows) <= max_rows, do: {rows, 0}, else: scroll(rows, max_rows, focused_tag)
    end
  end

  # Blank rows go bottom-most first, `count` of them at most.
  defp drop_blanks(rows, count) do
    {kept, _} =
      rows
      |> Enum.reverse()
      |> Enum.reduce({[], count}, fn
        {:blank, _}, {kept, left} when left > 0 -> {kept, left - 1}
        row, {kept, left} -> {[row | kept], left}
      end)

    kept
  end

  # The stepper (and what stands above it) and the keys row stay; the rows in
  # between scroll so the focused one is inside the window.
  defp scroll(rows, max_rows, focused_tag) do
    head_count =
      case Enum.find_index(rows, &(elem(&1, 0) == :stepper)) do
        nil -> 0
        index -> index + 1
      end

    {head, rest} = Enum.split(rows, head_count)
    {slice, tail} = Enum.split_with(rest, &(elem(&1, 0) != :keys))
    window = max(max_rows - length(head) - length(tail), 0)
    focused = Enum.find_index(slice, &(elem(&1, 0) == focused_tag)) || 0
    last = max(length(slice) - window, 0)
    offset = (focused - window + 1) |> max(0) |> min(last)
    visible = slice |> Enum.drop(offset) |> Enum.take(window)
    {Enum.take(head ++ visible ++ tail, max_rows), offset}
  end

  @doc """
  Why the agent asks: the last sentence of the asker's newest assistant text
  of the same run written before the ask's own op item, quoted by the caller,
  cut to `width - 2` cells; nil when the op item is not loaded or nothing
  precedes it.
  """
  @spec why(map(), map(), non_neg_integer()) :: SafeText.t() | nil
  def why(state, ask, width) do
    items = Map.values(state.read_model.transcript)

    with %{created_sequence: bound} <- Enum.find(items, &(&1.node_id == ask.node_id)),
         %{} = said <-
           items
           |> Enum.filter(
             &(&1.run_id == ask.run_id and &1.role == :assistant and &1.kind == :text and
                 &1.created_sequence < bound)
           )
           |> Enum.max_by(& &1.created_sequence, fn -> nil end),
         sentence when sentence != "" <- last_sentence(plain(said.text)) do
      Density.safe(sentence, state, max(width - 2, 0))
    else
      _ -> nil
    end
  end

  defp plain(%SafeText{} = text), do: SafeText.value(text)
  defp plain(text) when is_binary(text), do: text
  defp plain(_), do: ""

  defp last_sentence(text) do
    text
    |> String.trim()
    |> String.split(~r/(?<=[.!?])\s+/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> Kernel.||("")
  end
end
