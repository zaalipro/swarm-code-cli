defmodule SwarmCodeCLI.UI.Settings.Nav do
  @moduledoc """
  The settings layer's pure navigation: the section context a page is built
  from (`ctx/1`), the rows of the page on screen, and the moves of the rail
  and the page cursor. The reducer and the projector read the same rows, so
  what the cursor rests on is always what is drawn.
  """

  alias SwarmCodeCLI.UI.Settings.{Ctx, Layer, Page, Row, Sections}

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

  defp project(state) do
    case Map.get(state.read_model.snapshots, :workspace) do
      %{project: project} when is_binary(project) -> project
      _ -> nil
    end
  end

  defp conversation(%{destination: {:conversation, id}}), do: id
  defp conversation(_state), do: nil

  @doc "The rows of the page on screen."
  @spec rows(map()) :: [Row.t()]
  def rows(%{settings: %Layer{} = layer} = state) do
    ctx = ctx(state)
    page = Layer.page(layer)

    case Page.level(page) do
      :section ->
        Sections.rows(page.section, ctx)

      :record ->
        Sections.record_rows(page.section, ctx, elem(page.record, 0), elem(page.record, 1))

      :sub ->
        Sections.sub_rows(page.section, ctx, page.sub)
    end
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
      {:row, row_id} ->
        if Enum.any?(focusable, &(&1.id == row_id)),
          do: %{put_cursor(state, row_id) | settings: %{state.settings | deep_link: nil}},
          else: state

      _ ->
        cond do
          focusable == [] -> state
          Enum.any?(focusable, &(&1.id == cursor)) -> state
          true -> put_cursor(state, hd(focusable).id)
        end
    end
  end

  def settle(state), do: state

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
