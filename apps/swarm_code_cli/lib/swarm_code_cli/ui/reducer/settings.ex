defmodule SwarmCodeCLI.UI.Reducer.Settings do
  @moduledoc """
  The settings layer's reducer (cli74, spec §3.7): every `{:settings, event}`
  action and `{:settings_open, arg}` land here. Pure: IO happens through the
  effects the session runtime and the data source run, and their answers come
  back as `{:settings, event}` actions matched by generation and reference.

    * **Open** (`open/2`): a new generation, the restore point (focus, draft,
      chat scroll), the page stack from the deep link or the resume point,
      and the reads the page needs.
    * **Close** (`close/1`): the resume point kept (page stack, region,
      tasks), focus and scroll put back; undo history stays in
      `State.settings_history` (D38).
    * **Levels**: layer › section page › record page › sub-page. Esc pops one
      level and restores the parent's cursor; at a section page it closes.

  It also keeps `state.prefs` (every cli.json value by json name) in step
  with the file: the runtime's reads and writes answer here, and the legacy
  `/panel`, `/diff`, `/theme`, `/mouse` saves update it as they are made, so
  an open layer shows their change.
  """

  alias SwarmCodeCLI.UI.{Hint, SafeText, State}
  alias SwarmCodeCLI.UI.Init.Preferences
  alias SwarmCodeCLI.UI.Settings.{DeepLink, Layer, Nav, Page, Sections}

  @conflict_words "cli.json changed elsewhere; /settings shows it"

  # ------------------------------------------------------------ open, close

  @doc """
  Opens the layer at `arg` (see `Settings.DeepLink`). With the layer already
  open, a blank argument closes it (`/settings` again) and any other one
  moves it there.
  """
  @spec open(State.t(), term()) :: {State.t(), list()}
  def open(%{settings: %Layer{}} = state, nil), do: close(state)

  def open(%{settings: %Layer{} = layer} = state, arg) do
    link = DeepLink.resolve(arg, nil)
    layer = arrive(%{layer | stack: link.stack, deep_link: link.deep_link, popover: nil}, link)
    {state |> put_layer(layer) |> Nav.settle(), []}
  end

  def open(state, arg) do
    generation = state.settings_generation + 1
    resume = state.settings_resume
    link = DeepLink.resolve(arg, resume)

    layer =
      generation
      |> Layer.new(link.stack)
      |> Map.merge(%{
        restore: %{
          focus: state.focus,
          draft_key: State.current_draft_key(state),
          chat_scroll: state.scrolls.main
        },
        deep_link: link.deep_link,
        tasks: resume_tasks(resume),
        region: resume_region(resume, arg)
      })
      |> arrive(link)

    state =
      %{state | settings: layer, settings_generation: generation, hint: nil}
      |> Nav.settle()

    {state, [{:settings_cli_read, generation}]}
  end

  defp resume_tasks(%{tasks: tasks}) when is_map(tasks), do: tasks
  defp resume_tasks(_resume), do: %{}

  defp resume_region(%{region: region}, nil) when region in [:rail, :page, :detail], do: region
  defp resume_region(_resume, _arg), do: :page

  # A search argument opens the layer in the search row.
  defp arrive(layer, %{search: query}) when is_binary(query),
    do: %{
      layer
      | mode: :search,
        region: :search,
        search: %{query: query, cursor: nil, entered_from: :open},
        rail_cursor: Layer.section(layer)
    }

  defp arrive(layer, _link),
    do: %{layer | mode: :browse, search: nil, rail_cursor: Layer.section(layer)}

  @doc """
  Closes the layer: the resume point is kept, focus and the chat's scroll
  come back as they were.
  """
  @spec close(State.t()) :: {State.t(), list()}
  def close(%{settings: %Layer{} = layer} = state) do
    resume = %{
      stack: Enum.map(layer.stack, &%{&1 | scroll: &1.scroll}),
      region: if(layer.region == :search, do: :page, else: layer.region),
      rail_cursor: layer.rail_cursor,
      tasks: layer.tasks
    }

    state =
      case layer.restore do
        %{focus: focus, chat_scroll: scroll} ->
          %{state | focus: focus, scrolls: %{state.scrolls | main: scroll}}

        _ ->
          state
      end

    {%{state | settings: nil, settings_resume: resume}, []}
  end

  def close(state), do: {state, []}

  # ------------------------------------------------------------------ keys

  @doc "Applies one `{:settings, event}` action."
  @spec event(State.t(), term()) :: {State.t(), list()}
  def event(%{settings: %Layer{}} = state, {:verb, verb}), do: verb(state, verb)

  # Ctrl-F's badges: the letter opens its section; any other key ends them.
  def event(%{settings: %Layer{jump: %{labels: labels}} = layer} = state, {:raw, {code, []}})
      when is_binary(code) do
    layer = %{layer | jump: nil}

    case Map.get(labels, code) do
      nil -> {put_layer(state, layer), []}
      section -> go_section(put_layer(state, layer), section, :page)
    end
  end

  def event(%{settings: %Layer{jump: %{}} = layer} = state, {:raw, _key}),
    do: {put_layer(state, %{layer | jump: nil}), []}

  def event(%{settings: %Layer{} = layer} = state, {:wheel, delta, _column, _row}) do
    case layer.region do
      :rail -> {rail_to(state, Nav.rail_move(state, sign(delta))), []}
      _ -> {Nav.move(state, delta), []}
    end
  end

  def event(state, {:cli_snapshot, generation, %{values: values} = snapshot}) do
    state = %{state | prefs: values}
    {put_cli(state, generation, snapshot), []}
  end

  def event(state, {:cli_snapshot, generation, {:error, reason}}),
    do: {put_cli(state, generation, {:error, reason}), []}

  # A legacy save found the key changed in the file since the session read
  # it: the file's value stays, the shell shows it, and the user is told.
  def event(state, {:prefs_conflict, current}) when is_map(current) do
    prefs =
      Enum.reduce(current, state.prefs, fn
        {name, :absent}, acc -> Map.delete(acc, name)
        {name, value}, acc -> Map.put(acc, name, value)
      end)

    {state, effects} = apply_legacy(%{state | prefs: prefs}, Map.keys(current))
    {notice(state, @conflict_words), effects}
  end

  # A cli.json write answered: `state.prefs` follows the file it left; the
  # layer that asked (same generation) takes the outcome.
  def event(state, {:cli_result, generation, ref, result}) do
    state =
      case result do
        {:ok, %{values: values}} -> %{state | prefs: values}
        {:ok, %{values: values}, _warnings} -> %{state | prefs: values}
        _ -> state
      end

    {cli_outcome(state, generation, ref, result), []}
  end

  def event(state, {:folder_result, _generation, result}),
    do: {notice(state, folder_words(result)), []}

  def event(state, _event), do: {state, []}

  # ------------------------------------------------------------------ verbs

  # Esc: the popover, then the detail, then one level; at a section page it
  # closes the layer.
  defp verb(%{settings: %Layer{popover: {_, _}} = layer} = state, verb)
       when verb in [:back, :escape],
       do: {put_layer(state, %{layer | popover: nil}), []}

  defp verb(%{settings: %Layer{mode: :search} = layer} = state, verb)
       when verb in [:back, :escape] do
    case layer.search do
      %{query: query} = search when query != "" ->
        {put_layer(state, %{layer | search: %{search | query: ""}}), []}

      _ ->
        {put_layer(state, %{layer | mode: :browse, search: nil, region: :page}), []}
    end
  end

  defp verb(%{settings: %Layer{region: :detail} = layer} = state, :back),
    do: {put_layer(state, %{layer | region: :page}), []}

  defp verb(%{settings: %Layer{} = layer} = state, :back) do
    case Layer.pop(layer) do
      {:ok, layer} -> {state |> put_layer(layer) |> Nav.settle(), []}
      :top -> close(state)
    end
  end

  defp verb(state, :close), do: close(state)

  # Ctrl-C on a page closes the layer; in a text it clears first (editors).
  defp verb(%{settings: %Layer{mode: :browse}} = state, :interrupt), do: close(state)

  defp verb(%{settings: %Layer{mode: :search} = layer} = state, :interrupt),
    do: verb(%{state | settings: layer}, :escape)

  defp verb(%{settings: %Layer{region: :rail}} = state, verb)
       when verb in [:up, :down, :page_up, :page_down, :first, :last],
       do: {rail_to(state, Nav.rail_move(state, step(verb))), []}

  defp verb(%{settings: %Layer{mode: :browse}} = state, verb)
       when verb in [:up, :down, :page_up, :page_down, :first, :last],
       do: {Nav.move(state, step(verb)), []}

  defp verb(%{settings: %Layer{region: :rail} = layer} = state, verb)
       when verb in [:right, :enter],
       do: {put_layer(state, %{layer | region: :page}) |> Nav.settle(), []}

  defp verb(%{settings: %Layer{region: :page, mode: :browse} = layer} = state, :left),
    do: {put_layer(state, %{layer | region: :rail}), []}

  defp verb(state, :next_region), do: {cycle_region(state, 1), []}
  defp verb(state, :previous_region), do: {cycle_region(state, -1), []}

  defp verb(%{settings: %Layer{} = layer} = state, :prev_section),
    do: go_section(state, Sections.step(Layer.section(layer), -1), layer.region)

  defp verb(%{settings: %Layer{} = layer} = state, :next_section),
    do: go_section(state, Sections.step(Layer.section(layer), 1), layer.region)

  defp verb(%{settings: %Layer{} = layer} = state, :jump),
    do: {put_layer(state, %{layer | jump: %{labels: Nav.jump_labels(Hint.letters())}}), []}

  defp verb(%{settings: %Layer{} = layer} = state, :help),
    do: {put_layer(state, %{layer | popover: {:help, %{scroll: 0}}}), []}

  defp verb(%{settings: %Layer{} = layer} = state, :info),
    do: {put_layer(state, %{layer | detail_open: not layer.detail_open}), []}

  defp verb(%{settings: %Layer{} = layer} = state, :search),
    do:
      {put_layer(state, %{
         layer
         | mode: :search,
           region: :search,
           search: %{query: "", cursor: nil, entered_from: layer.region}
       }), []}

  defp verb(state, _verb), do: {state, []}

  defp step(:up), do: -1
  defp step(:down), do: 1
  defp step(other), do: other

  defp sign(delta) when delta < 0, do: -1
  defp sign(_delta), do: 1

  # The rail cursor shows its section in the page as it moves.
  defp rail_to(%{settings: %Layer{} = layer} = state, section) do
    layer = %{layer | rail_cursor: section, stack: [Page.section(section)]}
    state |> put_layer(layer) |> Nav.settle()
  end

  defp go_section(%{settings: %Layer{} = layer} = state, section, region) do
    layer = %{
      layer
      | rail_cursor: section,
        stack: [Page.section(section)],
        region: if(region == :search, do: :page, else: region),
        mode: :browse,
        search: nil
    }

    {state |> put_layer(layer) |> Nav.settle(), []}
  end

  @regions [:rail, :page, :detail]

  defp cycle_region(%{settings: %Layer{} = layer} = state, delta) do
    regions = if detail_column?(state), do: @regions, else: [:rail, :page]
    index = Enum.find_index(regions, &(&1 == layer.region)) || 1
    region = Enum.at(regions, Integer.mod(index + delta, length(regions)))
    put_layer(state, %{layer | region: region, mode: :browse, search: nil})
  end

  # The detail is a column of its own from 160 columns.
  defp detail_column?(%{size: %{columns: columns}}), do: columns >= 160
  defp detail_column?(_state), do: false

  defp put_layer(state, layer), do: %{state | settings: layer}

  @doc """
  Keeps `state.prefs` in step with the legacy saves the reducer emits (the
  `/panel`, `/diff`, `/theme`, `/mouse` paths and the palette's toggles).
  """
  @spec track_legacy(State.t(), list()) :: State.t()
  def track_legacy(state, effects) do
    Enum.reduce(effects, state, fn
      {:save_preferences, wanted}, acc ->
        %{acc | prefs: Map.merge(acc.prefs, Preferences.changes(wanted))}

      _effect, acc ->
        acc
    end)
  end

  @doc "The words the status row shows for an open-folder answer."
  @spec folder_words(term()) :: String.t()
  def folder_words(:ok), do: "Opened the folder"

  def folder_words({:error, :no_desktop}),
    do: "No desktop to open folders here · y copies the path"

  def folder_words({:error, :missing}),
    do: "That folder does not exist yet · n creates the first file in it"

  def folder_words({:error, :busy}), do: "Still opening the last folder"
  def folder_words(_result), do: "Couldn't open the folder · y copies the path"

  defp cli_outcome(
         %{settings: %Layer{generation: generation} = layer} = state,
         generation,
         ref,
         result
       ),
       do: %{
         state
         | settings: %{layer | requests: Map.put(layer.requests, {:cli, ref}, {:done, result})}
       }

  defp cli_outcome(state, _generation, _ref, _result), do: state

  defp put_cli(%{settings: %Layer{generation: layer_generation} = layer} = state, generation, cli)
       when generation in [nil, layer_generation],
       do: %{state | settings: %{layer | data: %{layer.data | cli: cli}}}

  defp put_cli(state, _generation, _cli), do: state

  # The shell's live copies of the four legacy preferences follow the file;
  # the terminal repaints or turns wheel reports over when those moved.
  defp apply_legacy(state, names) do
    legacy = Preferences.legacy(state.prefs)

    Enum.reduce(names, {state, []}, fn
      "panel", {acc, effects} ->
        {%{acc | panel_mode: legacy.panel_mode}, effects}

      "show_diffs", {acc, effects} ->
        {%{acc | show_diffs: legacy.show_diffs}, effects}

      "mouse", {acc, effects} when acc.mouse? != legacy.mouse? ->
        {%{acc | mouse?: legacy.mouse?},
         effects ++ [{:terminal_preferences, %{mouse?: legacy.mouse?}}]}

      "theme", {%{theme_env: nil} = acc, effects}
      when legacy.theme != nil and legacy.theme != acc.theme_mode ->
        {%{acc | theme_mode: legacy.theme},
         effects ++ [{:terminal_preferences, %{theme: legacy.theme}}]}

      _name, acc ->
        acc
    end)
  end

  defp notice(%{settings: %Layer{} = layer} = state, words),
    do: %{state | settings: %{layer | status: %{text: words, role: :text_muted, at: state.now}}}

  defp notice(state, words) do
    {:ok, safe} = SafeText.external(words, SafeText.Limits.content())
    %{state | notice: {:command_feedback, SafeText.value(safe)}}
  end
end
