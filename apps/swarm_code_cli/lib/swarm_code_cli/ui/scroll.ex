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

  def apply(scroll, {kind, delta}, ids, height) when kind in [:line, :page],
    do: __MODULE__.apply(scroll, {kind, delta}, ids, height, fn _ -> 1 end)

  def apply(scroll, operation, ids, page_height, height_for)

  def apply(scroll, {kind, delta}, ids, page_height, height_for) when kind in [:line, :page] do
    follow_anchor = {List.last(ids), max(0, item_height(height_for, List.last(ids)) - 1), :top}
    {id, line, bias} = if scroll.follow?, do: follow_anchor, else: scroll.anchor || follow_anchor
    index = Enum.find_index(ids, &(&1 == id)) || 0
    movement = if kind == :page, do: delta * page_height, else: delta
    anchor = if ids == [], do: nil, else: locate(ids, index, line + movement, bias, height_for)
    %{scroll | anchor: anchor, follow?: false}
  end

  def apply(scroll, operation, ids, height, _),
    do: __MODULE__.apply(scroll, operation, ids, height)

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
  defp item_height(fun, id), do: max(1, fun.(id))

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
