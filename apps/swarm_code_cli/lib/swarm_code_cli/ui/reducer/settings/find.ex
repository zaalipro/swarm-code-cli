defmodule SwarmCodeCLI.UI.Reducer.Settings.Find do
  @moduledoc """
  The search row and the `:` command line of the settings layer (spec
  §3.7.11), and the in-page filter of long lists (D37).

    * **Search** (`/`): typing narrows the results page (the index is
      rebuilt only when the data changes); ↓ moves into the results, ↑ from
      the first result back to the typing; Enter opens or edits the result;
      `g` on a result goes to it in its section; Tab completes an
      `@filter`; Esc clears, then leaves.
    * **Filter** (`/` on a list of more than 20 rows): the same typing
      narrows that list in place; `/` on an empty filter opens the search.
    * **Command line** (`:`): `set <key> <value>`, `get <key>`, `reset
      <key>`, `goto <section | key | words>`, `undo`, `redo`, `help`.
      Values are parsed as `swarmcode config set` parses them; a result is
      a toast, an error stays on the line.
  """

  alias SwarmCode.Settings.{Entry, Registry, TextValue, Validate}
  alias SwarmCodeCLI.UI.Reducer.Settings.{Commit, Ops}
  alias SwarmCodeCLI.UI.Settings.{DeepLink, Display, Layer, Nav, Page, Row, Rows, Search}

  @filter_rows 20

  # ------------------------------------------------------------- search

  @doc "Opens the search row (or the in-page filter of a long list)."
  @spec open(map()) :: {map(), list()}
  def open(%{settings: %Layer{} = layer} = state) do
    rows = Nav.rows(state)
    focusable = Enum.count(rows, &Row.focusable?/1)

    cond do
      Layer.depth(layer) > 1 and focusable > @filter_rows and layer.filter == nil ->
        page = Layer.page(layer)
        filter = %{page: {page.section, page.record, page.sub}, query: "", total: focusable}
        {%{state | settings: %{layer | filter: filter, mode: :search, region: :search}}, []}

      true ->
        search = %{
          query: "",
          cursor: nil,
          entered_from: layer.region,
          index: nil,
          index_key: nil,
          found: nil
        }

        {%{
           state
           | settings: %{layer | mode: :search, region: :search, search: search, filter: nil}
         }, []}
    end
  end

  @doc "Opens the search row with `words` in it, the results found."
  @spec query(map(), String.t()) :: map()
  def query(%{settings: %Layer{}} = state, words) when is_binary(words) do
    {state, _} = open(%{state | settings: %{state.settings | filter: nil}})
    state = put_in(state.settings.search.query, words)
    refresh(state)
  end

  @doc "One key or text while the search row, the filter or the command line has focus."
  @spec event(map(), term()) :: {map(), list()}
  def event(%{settings: %Layer{mode: :command_line}} = state, event),
    do: command_event(state, event)

  def event(%{settings: %Layer{filter: %{}, search: nil}} = state, event),
    do: filter_event(state, event)

  def event(state, event), do: search_event(state, event)

  defp search_event(%{settings: %Layer{search: search}} = state, {:text, "g"})
       when is_map(search) and search.cursor != nil,
       do: goto_result(state)

  # On a result the row's own keys work (results are real rows).
  defp search_event(%{settings: %Layer{search: %{cursor: cursor}}} = state, {:verb, verb})
       when cursor != nil and verb in [:left, :right, :big_left, :big_right, :reset, :undo, :redo],
       do: Ops.row_verb(state, verb)

  defp search_event(%{settings: %Layer{search: %{cursor: cursor}}} = state, {:text, " "})
       when cursor != nil,
       do: Ops.row_verb(state, :toggle)

  defp search_event(state, {:text, text}), do: {type(state, &(&1 <> text)), []}

  defp search_event(state, {:paste, text}),
    do: {type(state, &(&1 <> String.replace(text, ~r/\s+/u, " "))), []}

  defp search_event(state, {:verb, :backspace}),
    do: {type(state, &String.slice(&1, 0, max(String.length(&1) - 1, 0))), []}

  defp search_event(state, {:verb, :clear_line}), do: {type(state, fn _ -> "" end), []}

  defp search_event(state, {:verb, :delete_word}),
    do: {type(state, &Regex.replace(~r/\S*\s*\z/u, &1, "")), []}

  defp search_event(%{settings: %Layer{search: %{cursor: nil}}} = state, {:verb, :down}) do
    case first_result(state) do
      nil -> {state, []}
      id -> {state |> Nav.put_cursor(id) |> put_search(&%{&1 | cursor: id}), []}
    end
  end

  defp search_event(%{settings: %Layer{search: %{cursor: cursor}}} = state, {:verb, :up})
       when cursor != nil do
    if Nav.current(state) && Nav.current(state).id == first_result(state),
      do: {put_search(state, &%{&1 | cursor: nil}), []},
      else: {sync_cursor(Nav.move(state, -1)), []}
  end

  defp search_event(%{settings: %Layer{search: %{cursor: cursor}}} = state, {:verb, verb})
       when cursor != nil and verb in [:down, :page_up, :page_down, :first, :last] do
    how = %{down: 1, page_up: :page_up, page_down: :page_down, first: :first, last: :last}[verb]
    {sync_cursor(Nav.move(state, how)), []}
  end

  defp search_event(state, {:verb, :enter}) do
    state =
      case state.settings.search do
        %{cursor: nil} ->
          with id when is_binary(id) <- first_result(state),
               do: Nav.put_cursor(state, id),
               else: (_ -> state)

        _ ->
          state
      end

    open_result(state)
  end

  defp search_event(state, {:verb, :complete}), do: {type(state, &complete_filter/1), []}

  defp search_event(state, _event), do: {state, []}

  defp type(%{settings: %Layer{search: %{} = search} = layer} = state, fun) do
    query = search.query |> fun.() |> String.slice(0, 200)
    state = %{state | settings: %{layer | search: %{search | query: query, cursor: nil}}}
    refresh(state)
  end

  defp type(state, _fun), do: state

  @doc "Runs the query over the index (rebuilding the index when the data moved)."
  @spec refresh(map()) :: map()
  def refresh(%{settings: %Layer{search: %{query: query} = search} = layer} = state) do
    ctx = Nav.ctx(state)
    key = Search.index_key(ctx)
    index = if search.index_key == key and search.index, do: search.index, else: Search.index(ctx)
    found = if query == "", do: nil, else: Search.run(index, query, ctx)

    state = %{
      state
      | settings: %{layer | search: %{search | index: index, index_key: key, found: found}}
    }

    Nav.settle(state)
  end

  def refresh(state), do: state

  defp first_result(state) do
    case Enum.find(Nav.rows(state), &Row.focusable?/1) do
      %Row{kind: :info} -> nil
      %Row{id: id} -> id
      nil -> nil
    end
  end

  defp sync_cursor(state) do
    case Nav.current(state) do
      %Row{id: id} -> put_search(state, &%{&1 | cursor: id})
      nil -> state
    end
  end

  defp put_search(%{settings: %Layer{search: %{} = search} = layer} = state, fun),
    do: %{state | settings: %{layer | search: fun.(search)}}

  # Enter on a result: a key row is edited in place; the others open.
  defp open_result(state) do
    case Nav.current(state) do
      %Row{target: {:search_result, target}} -> go(state, target)
      %Row{kind: :setting} -> Ops.row_verb(state, :enter)
      _ -> {state, []}
    end
  end

  defp goto_result(state) do
    case Nav.current(state) do
      %Row{target: {:search_result, target}} -> go(state, target)
      %Row{key: key} when is_binary(key) -> go(state, {:key, key})
      _ -> {state, []}
    end
  end

  @doc """
  Leaves the search (when open) for a target: a section, a key's row (the
  cursor on it) or a record page above its section.
  """
  @spec go(map(), term()) :: {map(), list()}
  def go(state, {:section, id}), do: leave_to(state, [Page.section(id)], nil)

  def go(state, {:key, key}) do
    case Registry.fetch(key) do
      {:ok, entry} ->
        leave_to(
          state,
          [%Page{section: entry.section, cursor: "key:" <> key}],
          {:row, "key:" <> key}
        )

      :error ->
        {state, []}
    end
  end

  def go(state, {:record, kind, id}) do
    section = DeepLink.record_section(to_string(kind)) || Layer.section(state.settings)
    leave_to(state, [%Page{section: section, record: {kind, id}}, Page.section(section)], nil)
  end

  def go(state, {:record, kind, id, _item}), do: go(state, {:record, kind, id})
  def go(state, _target), do: {state, []}

  defp leave_to(%{settings: layer} = state, stack, deep_link) do
    layer = %{
      layer
      | stack: stack,
        mode: :browse,
        region: :page,
        search: nil,
        filter: nil,
        rail_cursor: hd(Enum.reverse(stack)).section,
        deep_link: deep_link
    }

    {Nav.settle(%{state | settings: layer}), []}
  end

  defp complete_filter(query) do
    case Regex.run(~r/(@\S*)\z/u, query) do
      [_, partial] ->
        case Enum.find(Search.filters(), &String.starts_with?(&1, partial)) do
          nil ->
            query

          filter ->
            String.replace_suffix(query, partial, filter) <>
              if(String.ends_with?(filter, ":"), do: "", else: " ")
        end

      _ ->
        query
    end
  end

  # ------------------------------------------------------------- filter

  defp filter_event(%{settings: %Layer{filter: filter} = layer} = state, event) do
    case event do
      {:text, "/"} when filter.query == "" ->
        open(%{state | settings: %{layer | filter: nil}})

      {:text, text} ->
        {put_filter(state, filter.query <> text), []}

      {:verb, :backspace} ->
        {put_filter(
           state,
           String.slice(filter.query, 0, max(String.length(filter.query) - 1, 0))
         ), []}

      {:verb, :clear_line} ->
        {put_filter(state, ""), []}

      {:verb, verb} when verb in [:down, :up, :page_up, :page_down, :first, :last] ->
        how =
          %{down: 1, up: -1, page_up: :page_up, page_down: :page_down, first: :first, last: :last}[
            verb
          ]

        {Nav.move(state, how), []}

      {:verb, :enter} ->
        {%{state | settings: %{state.settings | mode: :browse, region: :page}}, []}

      _ ->
        {state, []}
    end
  end

  defp put_filter(%{settings: layer} = state, query),
    do: Nav.settle(%{state | settings: %{layer | filter: %{layer.filter | query: query}}})

  # ------------------------------------------------------- command line

  @doc "Opens the `:` command line."
  @spec command_line(map()) :: {map(), list()}
  def command_line(%{settings: %Layer{} = layer} = state),
    do:
      {%{
         state
         | settings: %{
             layer
             | mode: :command_line,
               region: :search,
               command_line: %{text: "", error: nil}
           }
       }, []}

  defp command_event(%{settings: %Layer{command_line: line} = layer} = state, event) do
    case event do
      {:text, text} ->
        {put_line(state, %{line | text: String.slice(line.text <> text, 0, 1_000), error: nil}),
         []}

      {:paste, text} ->
        {put_line(state, %{
           line
           | text: String.slice(line.text <> String.trim(text), 0, 1_000),
             error: nil
         }), []}

      {:verb, :backspace} ->
        {put_line(state, %{
           line
           | text: String.slice(line.text, 0, max(String.length(line.text) - 1, 0))
         }), []}

      {:verb, :clear_line} ->
        {put_line(state, %{line | text: "", error: nil}), []}

      {:verb, :complete} ->
        {put_line(state, %{line | text: complete_command(line.text)}), []}

      {:verb, verb} when verb in [:escape, :back, :interrupt] ->
        {%{state | settings: %{layer | mode: :browse, region: :page, command_line: nil}}, []}

      {:verb, :enter} ->
        run(state, String.trim(line.text))

      _ ->
        {state, []}
    end
  end

  defp put_line(%{settings: layer} = state, line),
    do: %{state | settings: %{layer | command_line: line}}

  defp run(state, text) do
    case String.split(text, ~r/\s+/u, parts: 3) do
      ["set", key, value] ->
        set(state, key, value)

      ["get", key] ->
        get(state, key)

      ["reset", key] ->
        with_key(state, key, fn entry -> done(Commit.reset(state, [entry.key])) end)

      ["goto" | words] ->
        goto(state, Enum.join(words, " "))

      ["undo"] ->
        done(Ops.row_verb(close_line(state), :undo))

      ["redo"] ->
        done(Ops.row_verb(close_line(state), :redo))

      ["help"] ->
        {state
         |> close_line()
         |> then(&%{&1 | settings: %{&1.settings | popover: {:help, %{scroll: 0}}}}), []}

      [""] ->
        {close_line(state), []}

      _ ->
        {line_error(state, "not a command here · set, get, reset, goto, undo, redo, help"), []}
    end
  end

  defp set(state, key, text) do
    with_key(state, key, fn entry ->
      with {:ok, value} <- TextValue.parse(entry, text),
           :ok <- Validate.check(entry, value) do
        done(Commit.patch(close_line(state), entry.key, value, reason: :edit))
      else
        {:error, message} -> {line_error(state, message), []}
      end
    end)
  end

  defp get(state, key) do
    with_key(state, key, fn entry ->
      ctx = Nav.ctx(state)
      setting = Rows.setting(ctx, entry)

      value =
        if entry.secret,
          do: "not shown",
          else: Display.toast_words(entry, Rows.shown(ctx, entry, setting), setting)

      {Commit.status(close_line(state), "#{entry.key} = #{value}", :text_muted), []}
    end)
  end

  defp goto(state, words) do
    link = DeepLink.resolve(words, nil)
    state = close_line(state)

    layer = %{
      state.settings
      | stack: link.stack,
        deep_link: link.deep_link,
        rail_cursor: hd(Enum.reverse(link.stack)).section
    }

    state = %{state | settings: layer}

    if is_binary(link.search) do
      {state, _} = open(state)
      {refresh(put_search(state, &%{&1 | query: link.search})), []}
    else
      {Nav.settle(state), []}
    end
  end

  defp with_key(state, key, fun) do
    case Registry.resolve(key) do
      {:key, key} ->
        entry = Registry.fetch!(key)

        if Entry.scalar?(entry),
          do: fun.(entry),
          else: {line_error(state, "#{key} is not a value"), []}

      _ ->
        {line_error(state, "not a setting: #{key}"), []}
    end
  end

  defp done({state, effects}), do: {state, effects}

  defp close_line(%{settings: layer} = state),
    do: %{state | settings: %{layer | mode: :browse, region: :page, command_line: nil}}

  defp line_error(%{settings: %Layer{command_line: line} = layer} = state, message),
    do: %{state | settings: %{layer | command_line: %{line | error: message}}}

  @commands ~w(set get reset goto undo redo help)

  defp complete_command(text) do
    case String.split(text, ~r/\s+/u) do
      [partial] ->
        Enum.find(@commands, text, &String.starts_with?(&1, partial)) <> " "

      [command, partial] when command in ["set", "get", "reset", "goto"] ->
        case Enum.find(Registry.all(), &String.starts_with?(&1.key, partial)) do
          nil -> text
          entry -> command <> " " <> entry.key <> " "
        end

      _ ->
        text
    end
  end
end
