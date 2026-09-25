defmodule SwarmCodeCLI.UI.Settings.Editors.List do
  @moduledoc """
  A list of values (spec §3.7.8, D37): ↑↓ move, `a` adds, Enter edits the
  focused item, `x` removes it, `J`/`K` move it (ordered lists), `X` asks
  to remove all, Ctrl-S writes the list, Esc puts it back. Each item is
  checked as the entry's items are (domains, env names, command
  families). Only the visible items are drawn; a list of more than 20
  items takes `/` for a filter. Opts: `value`, `entry`, `ordered`.
  """

  @behaviour SwarmCodeCLI.UI.Settings.Editor

  alias SwarmCode.Settings.{Entry, Validate}
  alias SwarmCodeCLI.UI.Settings.Buffer

  @shown 10
  @filter_over 20

  @impl true
  def init(_row, opts, _ctx) do
    items = Enum.map(List.wrap(Map.get(opts, :value)), &to_string/1)

    {:ok,
     %{
       opts: opts,
       items: items,
       cursor: 0,
       typing: nil,
       error: nil,
       filter: nil,
       confirm_all: false
     }}
  end

  @impl true
  # Typing a new or edited item.
  def handle(%{typing: {index, buffer}} = state, {:key, :enter}, _ctx) do
    text = String.trim(buffer.text)

    case check_item(state.opts, text) do
      :ok ->
        items =
          case index do
            :new -> state.items ++ [text]
            n -> List.replace_at(state.items, n, text)
          end

        cursor = if index == :new, do: length(items) - 1, else: index
        {:cont, %{state | items: items, typing: nil, error: nil, cursor: cursor}}

      {:error, message} ->
        {:cont, %{state | error: message}}
    end
  end

  def handle(%{typing: {_index, _buffer}} = state, {:key, :escape}, _ctx),
    do: {:cont, %{state | typing: nil, error: nil}}

  def handle(%{typing: {index, buffer}} = state, {event, text}, _ctx)
      when event in [:text, :paste] do
    case Buffer.insert(buffer, String.trim_trailing(text, "\n")) do
      {:ok, buffer} -> {:cont, %{state | typing: {index, buffer}, error: nil}}
      {:error, :multiline} -> {:cont, %{state | error: "one item per line"}}
      {:error, :too_long} -> {:cont, %{state | error: "that item is too long"}}
    end
  end

  def handle(%{typing: {index, buffer}} = state, {:key, key}, _ctx),
    do: {:cont, %{state | typing: {index, Buffer.key(buffer, key)}}}

  # The filter.
  def handle(%{filter: query} = state, {:text, text}, _ctx) when is_binary(query) and text != "/",
    do: {:cont, %{state | filter: query <> text, cursor: 0}}

  def handle(%{filter: query} = state, {:key, :escape}, _ctx) when is_binary(query),
    do: {:cont, %{state | filter: nil}}

  # Browsing the items.
  def handle(state, {:key, :up}, _ctx), do: {:cont, move(state, -1)}
  def handle(state, {:key, :down}, _ctx), do: {:cont, move(state, 1)}
  def handle(state, {:key, {:ctrl, "s"}}, _ctx), do: commit(state)

  def handle(%{confirm_all: true} = state, {:text, "y"}, _ctx),
    do: {:cont, %{state | items: [], confirm_all: false, cursor: 0}}

  def handle(%{confirm_all: true} = state, _event, _ctx),
    do: {:cont, %{state | confirm_all: false}}

  def handle(state, {:key, :escape}, _ctx), do: {:cancel, state}

  def handle(state, {:text, "a"}, _ctx),
    do: {:cont, %{state | typing: {:new, Buffer.new("", max: 1_024)}}}

  def handle(state, {:key, :enter}, _ctx) do
    case Enum.at(state.items, state.cursor) do
      nil -> {:cont, %{state | typing: {:new, Buffer.new("", max: 1_024)}}}
      item -> {:cont, %{state | typing: {state.cursor, Buffer.new(item, max: 1_024)}}}
    end
  end

  def handle(state, {:text, "x"}, _ctx), do: {:cont, remove(state)}
  def handle(state, {:key, :delete}, _ctx), do: {:cont, remove(state)}
  def handle(state, {:text, "X"}, _ctx), do: {:cont, %{state | confirm_all: state.items != []}}
  def handle(state, {:text, "J"}, _ctx), do: {:cont, swap(state, 1)}
  def handle(state, {:text, "K"}, _ctx), do: {:cont, swap(state, -1)}

  def handle(state, {:text, "/"}, _ctx),
    do: {:cont, if(length(state.items) > @filter_over, do: %{state | filter: ""}, else: state)}

  def handle(state, _event, _ctx), do: {:cont, state}

  defp commit(state) do
    case state.opts do
      %{entry: %Entry{} = entry} ->
        case Validate.check(entry, state.items) do
          :ok -> {:commit, state.items, state}
          {:error, message} -> {:cont, %{state | error: message}}
        end

      _ ->
        {:commit, state.items, state}
    end
  end

  defp check_item(_opts, ""), do: {:error, "can't be blank"}

  defp check_item(%{entry: %Entry{} = entry}, text) do
    case Validate.check(entry, [text]) do
      :ok -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp check_item(_opts, _text), do: :ok

  defp move(state, delta) do
    count = length(state.items)
    %{state | cursor: if(count == 0, do: 0, else: min(max(state.cursor + delta, 0), count - 1))}
  end

  defp remove(%{items: []} = state), do: state

  defp remove(state) do
    items = List.delete_at(state.items, state.cursor)
    %{state | items: items, cursor: min(state.cursor, max(length(items) - 1, 0))}
  end

  defp swap(state, delta) do
    target = state.cursor + delta

    if Map.get(state.opts, :ordered, true) and target >= 0 and target < length(state.items) do
      a = Enum.at(state.items, state.cursor)
      b = Enum.at(state.items, target)
      items = state.items |> List.replace_at(state.cursor, b) |> List.replace_at(target, a)
      %{state | items: items, cursor: target}
    else
      state
    end
  end

  @impl true
  def display(state, _ctx) do
    visible =
      state.items
      |> Enum.with_index()
      |> Enum.filter(fn {item, _} ->
        state.filter in [nil, ""] or String.contains?(item, state.filter)
      end)

    start = max(min(state.cursor - div(@shown, 2), length(visible) - @shown), 0)

    lines =
      visible
      |> Enum.slice(start, @shown)
      |> Enum.map(fn {item, index} ->
        case state.typing do
          {^index, buffer} ->
            [{"› ", :focus}, {buffer.text, :text_primary}, {"▏", :focus}]

          _ ->
            [
              {if(index == state.cursor, do: "› ", else: "  "), :focus},
              {item, if(index == state.cursor, do: :selection, else: :text_primary)}
            ]
        end
      end)

    adding =
      case state.typing do
        {:new, buffer} -> [[{"+ ", :focus}, {buffer.text, :text_primary}, {"▏", :focus}]]
        _ -> []
      end

    more =
      if length(visible) > @shown,
        do: [[{"#{length(visible) - @shown} more · ↑↓", :text_faint}]],
        else: []

    error = if state.error, do: [[{"✗ " <> state.error, :error}]], else: []

    confirm =
      if state.confirm_all,
        do: [[{"Remove all #{length(state.items)}? y removes · any key keeps", :warning}]],
        else: []

    filter = if is_binary(state.filter), do: [[{"/ " <> state.filter, :info}]], else: []

    %{
      value: [{"#{length(state.items)} items", :text_primary}],
      lines: filter ++ lines ++ adding ++ more ++ error ++ confirm,
      popover: nil,
      context: :settings_edit,
      footer: [
        {"a", "add"},
        {"Enter", "edit"},
        {"x", "remove"},
        {"J K", "move"},
        {"Ctrl-S", "save"},
        {"Esc", "cancel"}
      ]
    }
  end
end
