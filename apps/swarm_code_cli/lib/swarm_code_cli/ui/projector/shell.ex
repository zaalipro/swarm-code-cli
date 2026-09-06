defmodule SwarmCodeCLI.UI.Projector.Shell do
  @moduledoc false
  alias SwarmCodeCLI.UI.SafeText
  alias SwarmCodeCLI.UI.Scene.{Block, Region}
  alias SwarmCodeCLI.UI.Projector.{Composer, Density, Inspector, Status, Support, Workspace}
  @order [:title, :navigator, :main, :inspector, :activity, :composer, :status]
  def project(state, layout) do
    Enum.reduce(@order, {[], nil}, fn role, {regions, cursor} ->
      case Map.get(layout.rects, role) do
        nil ->
          {regions, cursor}

        rect ->
          {blocks, new_cursor} = blocks(role, state, rect, layout.class)
          id = Atom.to_string(role)
          focus = if state.focus == id and state.layers == [], do: :active, else: :inactive
          label = Density.safe(SafeText.chrome(role), state, rect.width)

          region = %Region{
            id: id,
            role: role,
            rect: rect,
            label: label,
            blocks: blocks,
            focus: focus
          }

          region =
            case {role, blocks} do
              {:navigator, [%Block.VirtualList{} = window]} ->
                scroll = Map.get(state.scrolls, :navigator)

                %{
                  region
                  | scroll_offset: window.first_index,
                    visible_range:
                      {window.first_index, window.first_index + length(window.items)},
                    follow: if(scroll && scroll.follow?, do: :end, else: :none)
                }

              _ ->
                region
            end

          {regions ++ [region], new_cursor || cursor}
      end
    end)
  end

  defp blocks(:title, state, rect, class) do
    banner = Density.budget(class).banner |> SafeText.chrome() |> SafeText.value()
    {[Support.text(banner <> " · Build", state, rect.width)], nil}
  end

  defp blocks(:main, state, rect, class), do: {Workspace.project(state, rect, class), nil}
  defp blocks(:inspector, state, rect, class), do: {Inspector.project(state, rect, class), nil}
  defp blocks(:composer, state, rect, _), do: Composer.project(state, rect)
  defp blocks(:status, state, rect, class), do: {Status.project(state, class, rect.width), nil}

  defp blocks(:activity, state, rect, _class) do
    needs = state.read_model.interactions |> Map.values() |> Enum.count(&(&1.state == :pending))
    {[Support.text("NEEDS #{needs} · Activity", state, rect.width)], nil}
  end

  defp blocks(:navigator, state, rect, _class) do
    fallback = state.read_model.runs |> Map.keys() |> Enum.sort()
    ids = Map.get(state.read_model.order, :shell, fallback)

    items =
      Enum.flat_map(ids, fn id ->
        case Map.fetch(state.read_model.runs, id) do
          {:ok, run} -> [{id, run}]
          :error -> []
        end
      end)

    capacity = max(0, rect.height - 1)
    scroll = Map.get(state.scrolls, :navigator)

    anchor =
      case scroll do
        %{anchor: {id, _, _}} -> Enum.find_index(items, fn {key, _} -> key == id end) || 0
        _ -> 0
      end

    selected = Map.get(state.selection, "navigator")
    selected_index = Enum.find_index(items, fn {id, _} -> id == selected end)
    first = if scroll && scroll.follow?, do: max(0, length(items) - capacity), else: anchor

    first =
      cond do
        is_integer(selected_index) and selected_index < first ->
          selected_index

        is_integer(selected_index) and selected_index >= first + capacity ->
          selected_index - capacity + 1

        true ->
          first
      end
      |> min(max(0, length(items) - capacity))
      |> max(0)

    rows =
      items
      |> Enum.drop(first)
      |> Enum.take(capacity)
      |> Enum.map(fn {id, run} ->
        title = Density.safe(run.title, state, rect.width)

        title =
          if id == selected,
            do:
              Density.safe(
                SafeText.concat([SafeText.chrome(:selection_marker), title]),
                state,
                rect.width
              ),
            else: title

        Support.action(title, {:local, {:navigate, {:run, id}}})
      end)

    page = Map.get(state.pages, :shell)

    {[
       %Block.VirtualList{
         total_count: length(items),
         first_index: first,
         items: rows,
         before_cursor: page && page.before_cursor,
         after_cursor: page && page.after_cursor,
         overscan: 0
       }
     ], nil}
  end
end
