defmodule SwarmCodeCLI.UI.Settings.Nav do
  @moduledoc """
  The settings layer's pure navigation: the section context a page is built
  from (`ctx/1`), the rows of the page on screen, and the moves of the rail
  and the page cursor. The reducer and the projector read the same rows, so
  what the cursor rests on is always what is drawn.
  """

  alias SwarmCodeCLI.UI.Settings.{Ctx, Layer, Normalize, Page, Row, Search, Sections}

  # Rows of chrome around the page column (header, search, rules, status,
  # footer): what is left is the page's height, which PgUp/PgDn move by.
  @chrome_rows 8

  @doc "The context sections build their rows from."
  @spec ctx(map()) :: Ctx.t()
  def ctx(%{settings: %Layer{} = layer} = state) do
    %Ctx{
      state_view: state_view(state),
      data: layer.data,
      caps: state.capabilities,
      size: state.size,
      now: state.now,
      project: project(state),
      conversation: conversation(state),
      prefs: state.prefs,
      launch_facts: state.launch_facts,
      overrides: state.key_overrides,
      layer: layer,
      page: Layer.page(layer)
    }
  end

  defp state_view(state) do
    %{
      destination: state.destination,
      theme_mode: state.theme_mode,
      theme_env: state.theme_env,
      panel_mode: state.panel_mode,
      show_diffs: state.show_diffs,
      mouse?: state.mouse?,
      keymap: state.keymap,
      composer_height: state.composer_height,
      layout: state.preferences,
      history: state.settings_history,
      workspace: Map.get(state.read_model.snapshots, :workspace),
      shell: Map.get(state.read_model.snapshots, :shell)
    }
  end

  # The page's project as the sections read it: `%{"id", "name"}` (the id
  # from the service's values, the name from the workspace), nil when neither.
  defp project(%{settings: %Layer{data: data}} = state) do
    name =
      case Map.get(state.read_model.snapshots, :workspace) do
        %{project: project} when is_binary(project) -> project
        _ -> nil
      end

    id = data && data.project_id
    if is_nil(id) and is_nil(name), do: nil, else: %{"id" => id, "name" => name}
  end

  defp conversation(%{settings: %Layer{data: %{conversation_id: id}}}) when is_binary(id),
    do: %{"id" => id}

  defp conversation(%{destination: {:conversation, id}}), do: %{"id" => id}
  defp conversation(_state), do: nil

  @doc "The rows of the page on screen."
  @spec rows(map()) :: [Row.t()]
  def rows(%{settings: %Layer{search: %{query: query, found: %{} = found}}} = state)
      when query != "",
      do: Search.rows(ctx(state), found, query)

  def rows(%{settings: %Layer{} = layer} = state) do
    ctx = ctx(state)
    page = Layer.page(layer)

    rows =
      case Page.level(page) do
        :section ->
          Sections.rows(page.section, ctx)

        :record ->
          Sections.record_rows(page.section, ctx, elem(page.record, 0), elem(page.record, 1))

        :sub ->
          Sections.sub_rows(page.section, ctx, page.sub)
      end

    rows |> Normalize.rows() |> filtered(layer, ctx) |> conflicted(layer)
  end

  # QA #2 P1-3 (§3.7.9): a record field that changed elsewhere while it was
  # written shows both values on its row.
  defp conflicted(rows, %Layer{conflicts: conflicts}) when map_size(conflicts) > 0 do
    Enum.map(rows, fn row ->
      case Map.get(conflicts, {:row, row.id}) do
        %{mine: mine, theirs: theirs} = conflict ->
          theirs = words(theirs)
          mine = words(mine)

          lines = [
            [{"! changed while you edited (#{conflict.origin}): now #{theirs}", :warning}],
            [{"Enter keep yours (#{mine}) · Esc take theirs (#{theirs})", :text_muted}]
          ]

          %{row | marks: Enum.uniq(row.marks ++ [:conflict]), lines: row.lines ++ lines}

        _ ->
          row
      end
    end)
  end

  defp conflicted(rows, _layer), do: rows

  defp words(values) when is_map(values) do
    values
    |> Enum.sort()
    |> Enum.map_join(", ", fn {_field, value} -> SwarmCodeCLI.UI.Settings.Display.words(value) end)
  end

  # D37: a long list narrowed in place by its filter; a section that knows
  # better (Key bindings matches key names) answers through `filter/3`.
  defp filtered(rows, %Layer{filter: %{query: query, page: key}} = layer, ctx) when query != "" do
    page = Layer.page(layer)

    if key == {page.section, page.record, page.sub} do
      case Sections.filter(page.section, ctx, rows, query) do
        kept when is_list(kept) ->
          Normalize.rows(kept)

        nil ->
          words = query |> String.downcase() |> String.split(~r/\s+/u, trim: true)
          Enum.filter(rows, &(Row.focusable?(&1) and matches?(&1, words)))
      end
    else
      rows
    end
  end

  defp filtered(rows, _layer, _ctx), do: rows

  defp matches?(%Row{} = row, words) do
    haystack =
      [
        row.label
        | Enum.map(
            row.value ++ Enum.flat_map(row.columns || [], &[{elem(&1, 0), nil}]),
            &elem(&1, 0)
          )
      ]
      |> Enum.join(" ")
      |> String.downcase()
      |> String.split(~r/[^\p{L}\p{N}._\/-]+/u, trim: true)

    Enum.all?(words, fn word -> Enum.any?(haystack, &String.starts_with?(&1, word)) end)
  end

  @doc "The row the page cursor is on (nil on an empty page)."
  @spec current(map()) :: Row.t() | nil
  def current(state), do: current(state, rows(state))

  @doc "The row the page cursor is on among `rows`."
  @spec current([Row.t()] | map(), [Row.t()]) :: Row.t() | nil
  def current(%{settings: %Layer{} = layer}, rows) do
    focusable = Enum.filter(rows, &Row.focusable?/1)
    cursor = Layer.page(layer).cursor
    Enum.find(focusable, &(&1.id == cursor)) || List.first(focusable)
  end

  @doc "The page's height in rows (what PgUp and PgDn move by)."
  @spec page_height(map()) :: pos_integer()
  def page_height(%{size: %{rows: rows}}), do: max(rows - @chrome_rows, 3)
  def page_height(_state), do: 10

  @doc """
  Moves the page cursor: `1`/`-1` one focusable row, `:page_up`/`:page_down`
  a page, `:first`/`:last` to the ends. Headings and blank rows are skipped.
  """
  @spec move(map(), integer() | atom()) :: map()
  def move(%{settings: %Layer{} = layer} = state, how) do
    focusable = state |> rows() |> Enum.filter(&Row.focusable?/1)

    case focusable do
      [] ->
        state

      rows ->
        count = length(rows)
        cursor = Layer.page(layer).cursor
        index = Enum.find_index(rows, &(&1.id == cursor)) || 0

        target =
          case how do
            :first -> 0
            :last -> count - 1
            :page_up -> max(index - page_height(state), 0)
            :page_down -> min(index + page_height(state), count - 1)
            delta when is_integer(delta) -> min(max(index + delta, 0), count - 1)
          end

        put_cursor(state, Enum.at(rows, target).id)
    end
  end

  @doc "Puts the page cursor on `row_id`."
  @spec put_cursor(map(), String.t()) :: map()
  def put_cursor(%{settings: %Layer{} = layer} = state, row_id),
    do: %{state | settings: Layer.update_page(layer, &%{&1 | cursor: row_id})}

  @doc """
  Keeps the cursor on a row that exists: a pending deep link to a row takes
  it there once the row appears; a cursor whose row went away falls to the
  first focusable row.
  """
  @spec settle(map()) :: map()
  def settle(%{settings: %Layer{} = layer} = state) do
    rows = rows(state)
    focusable = Enum.filter(rows, &Row.focusable?/1)
    cursor = Layer.page(layer).cursor

    case layer.deep_link do
      # A key's row, or the action row a section draws for that key under an
      # id of its own (`act:…` rows that carry the registry key).
      # A key drawn as a heading (a group of rows: the environment) lands on
      # the first row under it.
      {:row, row_id} ->
        case Enum.drop_while(rows, &(not linked?(&1, row_id))) |> Enum.find(&Row.focusable?/1) do
          nil -> state
          row -> state |> put_cursor(row.id) |> spend_link()
        end

      # A blank open lands on the Overview's first attention item; the link
      # is spent once the service's overview is in (an item it lists first
      # may arrive after the client's own).
      :first_attention ->
        first = Enum.find(focusable, &String.starts_with?(&1.id, "att:"))
        state = if first, do: put_cursor(state, first.id), else: state

        cond do
          Layer.section(layer) != :overview or layer.data.overview != nil ->
            %{state | settings: %{state.settings | deep_link: nil}} |> settle()

          first == nil ->
            settle_cursor(state, focusable, cursor)

          true ->
            state
        end

      _ ->
        settle_cursor(state, focusable, cursor)
    end
  end

  def settle(state), do: state

  defp spend_link(%{settings: layer} = state), do: %{state | settings: %{layer | deep_link: nil}}

  defp linked?(%Row{id: id}, id), do: true
  defp linked?(%Row{key: key}, "key:" <> key) when is_binary(key), do: true
  defp linked?(%Row{id: "act:" <> key}, "key:" <> key), do: true
  defp linked?(_row, _row_id), do: false

  # QA #2 P1-4: a write's delta drops the page's records and asks for them
  # again; while they are on their way the row under the cursor is missing,
  # and the cursor fell to the page's first row (every MCP tool switch threw
  # the focus to the server's header). It keeps its row until the loads end.
  defp settle_cursor(state, focusable, cursor) do
    cond do
      focusable == [] -> state
      Enum.any?(focusable, &(&1.id == cursor)) -> state
      # QA #2 P2-12: a page that opens while its records load places the
      # cursor once they are in (it stayed on `▸ Add a provider…`).
      (is_nil(cursor) or is_binary(cursor)) and loading?(state) -> state
      true -> put_cursor(state, hd(focusable).id)
    end
  end

  # A load on its way, or one the page needs and does not hold yet (the
  # layer settles before it sends them).
  defp loading?(%{settings: %Layer{requests: requests} = layer} = state) do
    Enum.any?(requests, fn {_ref, meta} -> is_map(meta) and Map.get(meta, :kind) == :load end) or
      not Enum.all?(
        Sections.loads(Layer.section(layer), ctx(state)),
        &(SwarmCodeCLI.UI.Settings.Wire.loaded?(layer, &1) or failed?(layer, &1))
      )
  end

  defp failed?(%Layer{requests: requests}, load), do: Map.has_key?(requests, {:failed, load})

  @doc "The rail's section ids in order."
  @spec rail() :: [atom()]
  def rail, do: Sections.ids()

  @doc "Moves the rail cursor: `1`/`-1`, `:first`, `:last`, a page."
  @spec rail_move(map(), integer() | atom()) :: atom()
  def rail_move(%{settings: %Layer{rail_cursor: current}} = state, how) do
    ids = rail()
    count = length(ids)
    index = Enum.find_index(ids, &(&1 == current)) || 0

    target =
      case how do
        :first -> 0
        :last -> count - 1
        :page_up -> max(index - page_height(state), 0)
        :page_down -> min(index + page_height(state), count - 1)
        delta when is_integer(delta) -> min(max(index + delta, 0), count - 1)
      end

    Enum.at(ids, target)
  end

  @doc """
  The Ctrl-F badges of the rail: one letter per section, the hint letters
  first, then the rest of the alphabet.
  """
  @spec jump_labels([String.t()]) :: %{String.t() => atom()}
  def jump_labels(letters) do
    alphabet = for c <- ?a..?z, do: <<c>>
    letters = Enum.uniq(letters ++ alphabet)
    rail() |> Enum.zip(letters) |> Map.new(fn {id, letter} -> {letter, id} end)
  end
end
