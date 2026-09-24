defmodule SwarmCodeCLI.UI.Scroll do
  @moduledoc "Logical item anchors survive reflow and replacement pages."
  alias SwarmCodeCLI.UI.OrderedIdSet

  defstruct anchor: nil,
            follow?: true,
            unseen: %OrderedIdSet{},
            before_cursor: nil,
            after_cursor: nil

  @type t :: %__MODULE__{}
  def new, do: %__MODULE__{}

  def change(scroll, id) do
    if scroll.follow? do
      {:ok, scroll}
    else
      case OrderedIdSet.put(scroll.unseen, id) do
        {:ok, unseen} -> {:ok, %{scroll | unseen: unseen}}
        {:error, reason, _} -> {:error, reason, scroll}
      end
    end
  end

  def apply(scroll, operation, ids, page_height \\ 10)

  def apply(scroll, operation, ids, _) when operation in [:last, :follow],
    do: %{
      scroll
      | anchor: anchor(List.last(ids), 0),
        follow?: true,
        unseen: OrderedIdSet.clear(scroll.unseen)
    }

  def apply(scroll, :detach, _, _), do: %{scroll | follow?: false}

  def apply(scroll, :first, ids, _),
    do: %{scroll | anchor: anchor(List.first(ids), 0), follow?: false}

  def apply(scroll, {kind, delta}, ids, height) when kind in [:line, :half_page, :page],
    do: __MODULE__.apply(scroll, {kind, delta}, ids, height, fn _ -> 1 end)

  def apply(scroll, operation, ids, page_height, height_for)

  def apply(scroll, {kind, delta}, ids, page_height, height_for)
      when kind in [:line, :half_page, :page] do
    follow_anchor = follow_top(ids, page_height, height_for)
    {id, line, bias} = if scroll.follow?, do: follow_anchor, else: scroll.anchor || follow_anchor
    index = Enum.find_index(ids, &(&1 == id)) || 0
    movement = delta * lines_per(kind, page_height)
    anchor = if ids == [], do: nil, else: locate(ids, index, line + movement, bias, height_for)
    %{scroll | anchor: anchor, follow?: false}
  end

  def apply(scroll, operation, ids, height, _),
    do: __MODULE__.apply(scroll, operation, ids, height)

  # pass73 T9: following, the view is the last `page_height` rows, so a move
  # starts from that view's top row. It started from the last row, and the
  # projector draws an anchor whose rows do not fill the view from the end
  # (pass70 Q1): the first wheel notches, and PgUp, moved almost nothing.
  defp follow_top([], _page_height, _height_for), do: {nil, 0, :top}

  #
  # pass73 F9: the bottom row is the last row of the last item that draws one;
  # an item that draws nothing (a silent thought, a worker's call under a
  # folded lane) takes no row here either. Each counted as one row, so the
  # first notch over a turn that ended in three of them moved nothing, and
  # every later notch lost a row per such item it crossed.
  defp follow_top(ids, page_height, height_for) do
    last = last_drawn(ids, height_for)
    bottom = max(0, item_height(height_for, Enum.at(ids, last)) - 1)
    locate(ids, last, bottom - max(0, page_height - 1), :top, height_for)
  end

  defp last_drawn(ids, height_for) do
    last = length(ids) - 1

    ids
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.find_value(last, fn {id, back} ->
      if item_height(height_for, id) > 0, do: last - back
    end)
  end

  # Ctrl-D and Ctrl-U move half a viewport, never less than a line, so the keys
  # still do something in a one-row pane.
  defp lines_per(:page, page_height), do: page_height
  defp lines_per(:half_page, page_height), do: max(1, div(page_height, 2))
  defp lines_per(:line, _page_height), do: 1

  defp locate(ids, index, line, bias, height_for) do
    id = Enum.at(ids, index)
    height = item_height(height_for, id)

    cond do
      line < 0 and index > 0 ->
        locate(
          ids,
          index - 1,
          line + item_height(height_for, Enum.at(ids, index - 1)),
          bias,
          height_for
        )

      line >= height and index < length(ids) - 1 ->
        locate(ids, index + 1, line - height, bias, height_for)

      true ->
        {id, max(0, min(height - 1, line)), bias}
    end
  end

  defp item_height(_, nil), do: 1
  defp item_height(fun, id), do: max(0, fun.(id))

  def repair(scroll, id, old_ids, new_ids) do
    unseen = OrderedIdSet.delete(scroll.unseen, id)

    case scroll.anchor do
      {^id, line, bias} ->
        position = Enum.find_index(old_ids, &(&1 == id)) || 0
        successor = Enum.at(new_ids, position) || List.last(new_ids)
        %{scroll | anchor: if(successor, do: {successor, line, bias}, else: nil), unseen: unseen}

      _ ->
        %{scroll | unseen: unseen}
    end
  end

  defp anchor(nil, _), do: nil
  defp anchor(id, line), do: {id, line, :top}
end
