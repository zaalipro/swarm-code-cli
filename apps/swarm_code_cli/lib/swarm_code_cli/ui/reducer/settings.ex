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
  alias SwarmCodeCLI.UI.Reducer.Settings.{Commit, Edit, Find, Ops, Popover, Responses}
  alias SwarmCodeCLI.UI.Settings.{DeepLink, Layer, Nav, Page, Sections, Wire}

  @conflict_words "cli.json changed elsewhere; /settings shows it"

  # The keys a page row answers (the section's `act/3` first, §4.3).
  @row_verbs [:enter, :toggle, :left, :right, :big_left, :big_right, :reset, :undo, :redo] ++
               [:copy, :add, :add_key, :delete, :delete_record, :remove_all, :move_up] ++
               [:move_down, :test, :fetch, :open_related, :cancel_task, :new, :clear] ++
               [:edit_external, :all_on, :all_off, :alt, :restart, :save, :external]

  # ------------------------------------------------------------ open, close

  @doc """
  Opens the layer at `arg` (see `Settings.DeepLink`). With the layer already
  open, a blank argument closes it (`/settings` again) and any other one
  moves it there.
  """
  @spec open(State.t(), term()) :: {State.t(), list()}
  def open(state, arg) do
    {state, effects} = open_layer(state, arg)
    state = Find.refresh(state)
    {state, more} = Wire.sync(state)
    {state, effects ++ more}
  end

  defp open_layer(%{settings: %Layer{}} = state, nil), do: close(state)

  defp open_layer(%{settings: %Layer{} = layer} = state, arg) do
    link = DeepLink.resolve(arg, nil)
    layer = arrive(%{layer | stack: link.stack, deep_link: link.deep_link, popover: nil}, link)
    {state |> put_layer(layer) |> Nav.settle(), []}
  end

  defp open_layer(state, arg) do
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
        region: resume_region(resume, arg),
        watch_generation: shell_generation(state)
      })
      |> arrive(link)

    state =
      %{state | settings: layer, settings_generation: generation, hint: nil}
      |> Nav.settle()

    {state, [{:settings_cli_read, generation}]}
  end

  defp shell_generation(state) do
    case Map.get(state.watches, :shell) do
      %{generation: generation} -> generation
      _ -> nil
    end
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
        search: %{
          query: query,
          cursor: nil,
          entered_from: :open,
          index: nil,
          index_key: nil,
          found: nil
        },
        rail_cursor: Layer.section(layer)
    }

  defp arrive(layer, _link),
    do: %{layer | mode: :browse, search: nil, rail_cursor: Layer.section(layer)}

  @doc """
  Closes the layer: the resume point is kept, focus and the chat's scroll
  come back as they were.
  """
  @spec close(State.t()) :: {State.t(), list()}
  def close(%{settings: %Layer{}} = state) do
    {state, cancels} = cancel_mine(state)
    layer = state.settings

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

    {%{state | settings: nil, settings_resume: resume}, cancels}
  end

  def close(state), do: {state, []}

  # Closing stops the cancellable tasks this layer started; the others run on.
  defp cancel_mine(%{settings: %Layer{tasks: tasks}} = state) do
    Enum.reduce(SwarmCodeCLI.UI.Settings.Tasks.to_cancel(tasks), {state, []}, fn id,
                                                                                 {acc, effects} ->
      {acc, more} = Wire.op(acc, {:cancel_task, id})
      {acc, effects ++ more}
    end)
  end

  # ------------------------------------------------------------------ keys

  @doc """
  Applies one `{:settings, event}` action, then asks for what the page on
  screen needs and does not have yet.
  """
  @spec event(State.t(), term()) :: {State.t(), list()}
  def event(state, event) do
    {state, effects} = handle_event(state, event)
    {state, more} = Wire.sync(state)
    {state, effects ++ more}
  end

  # A popover owns every key while it is open (Tab stays inside it).
  defp handle_event(%{settings: %Layer{popover: {_, _}}} = state, {kind, _} = event)
       when kind in [:verb, :text, :key, :raw, :paste],
       do: Popover.event(state, event)

  # The paste target of a secret takes its keys, text and pastes.
  defp handle_event(%{settings: %Layer{mode: :paste, paste: %{}}} = state, {kind, _} = event)
       when kind in [:verb, :text, :paste],
       do: SwarmCodeCLI.UI.Reducer.Settings.Paste.event(state, event)

  # The search row, the in-page filter and the command line take typing and
  # their keys; Esc, Ctrl-C and ? keep their layer meaning.
  defp handle_event(%{settings: %Layer{mode: mode, popover: nil}} = state, {kind, value} = event)
       when mode in [:search, :command_line] and kind in [:text, :paste, :verb] and
              value not in [
                :escape,
                :back,
                :interrupt,
                :help,
                :close,
                :next_region,
                :previous_region
              ],
       do: Find.event(state, event)

  # An open editor takes the keys, the text and the pastes first.
  defp handle_event(%{settings: %Layer{mode: :editing, popover: nil}} = state, {:verb, verb}) do
    case Edit.verb_event(verb) do
      nil when verb == :interrupt -> Edit.event(state, :interrupt)
      nil -> verb(state, verb)
      event -> Edit.event(state, event)
    end
  end

  defp handle_event(%{settings: %Layer{mode: :editing, popover: nil}} = state, {kind, _} = event)
       when kind in [:text, :paste, :key, :raw],
       do: Edit.event(state, event)

  defp handle_event(%{settings: %Layer{}} = state, {:verb, verb}), do: verb(state, verb)

  defp handle_event(state, {:saving, generation, ref}),
    do: {Commit.saving(state, generation, ref), []}

  defp handle_event(state, {:settle, generation, timer}), do: Ops.settle(state, generation, timer)

  # Ctrl-F's badges: the letter opens its section; any other key ends them.
  defp handle_event(
         %{settings: %Layer{jump: %{labels: labels}} = layer} = state,
         {:raw, {code, []}}
       )
       when is_binary(code) do
    layer = %{layer | jump: nil}

    case Map.get(labels, code) do
      nil -> {put_layer(state, layer), []}
      section -> go_section(put_layer(state, layer), section, :page)
    end
  end

  defp handle_event(%{settings: %Layer{jump: %{}} = layer} = state, {:raw, _key}),
    do: {put_layer(state, %{layer | jump: nil}), []}

  defp handle_event(%{settings: %Layer{} = layer} = state, {:wheel, delta, _column, _row}) do
    case layer.region do
      :rail -> {rail_to(state, Nav.rail_move(state, sign(delta))), []}
      _ -> {Nav.move(state, delta), []}
    end
  end

  defp handle_event(state, {:cli_snapshot, generation, %{values: values} = snapshot}) do
    state = %{state | prefs: values}
    {put_cli(state, generation, snapshot), []}
  end

  defp handle_event(state, {:cli_snapshot, generation, {:error, reason}}),
    do: {put_cli(state, generation, {:error, reason}), []}

  # A legacy save found the key changed in the file since the session read
  # it: the file's value stays, the shell shows it, and the user is told.
  defp handle_event(state, {:prefs_conflict, current}) when is_map(current) do
    prefs =
      Enum.reduce(current, state.prefs, fn
        {name, :absent}, acc -> Map.delete(acc, name)
        {name, value}, acc -> Map.put(acc, name, value)
      end)

    {state, effects} = Commit.apply_names(%{state | prefs: prefs}, Map.keys(current))
    {notice(state, @conflict_words), effects}
  end

  # A cli.json write answered: `state.prefs` follows the file it left; the
  # layer that asked (same generation) takes the outcome.
  defp handle_event(state, {:cli_result, generation, ref, result}) do
    state =
      case result do
        {:ok, %{values: values}} -> %{state | prefs: values}
        {:ok, %{values: values}, _warnings} -> %{state | prefs: values}
        _ -> state
      end

    state = put_cli_result(state, generation, result)

    case state.settings do
      %Layer{writes: writes} ->
        case Enum.find(writes, fn {_key, write} -> write.ref == ref end) do
          {{:cli_batch, _} = key, write} -> batch_outcome(state, key, write, result)
          _ -> Commit.cli_result(state, generation, ref, result)
        end

      _ ->
        {state, []}
    end
  end

  # The text an external editor returned: cli.json goes back through its
  # fingerprint CAS; an open multi-line editor takes it; a file is saved
  # with the fingerprint it was read with.
  defp handle_event(
         %{settings: %Layer{generation: generation} = layer} = state,
         {:external_result, generation, ref, result}
       ) do
    {spec, requests} = Map.pop(layer.requests, {:external, ref})
    state = put_layer(state, %{layer | requests: requests})
    external(state, spec, result)
  end

  defp handle_event(state, {:folder_result, _generation, result}),
    do: {notice(state, folder_words(result)), []}

  defp handle_event(state, _event), do: {state, []}

  # ------------------------------------------------------------------ verbs

  # Esc: the popover, then the detail, then one level; at a section page it
  # closes the layer.
  defp verb(%{settings: %Layer{popover: {_, _}} = layer} = state, verb)
       when verb in [:back, :escape],
       do: {put_layer(state, %{layer | popover: nil}), []}

  defp verb(
         %{settings: %Layer{mode: :search, search: nil, filter: %{} = filter} = layer} = state,
         verb
       )
       when verb in [:back, :escape, :interrupt] do
    if filter.query != "",
      do: {Nav.settle(put_layer(state, %{layer | filter: %{filter | query: ""}})), []},
      else: {put_layer(state, %{layer | mode: :browse, filter: nil, region: :page}), []}
  end

  defp verb(%{settings: %Layer{mode: :command_line} = layer} = state, verb)
       when verb in [:back, :escape, :interrupt],
       do: {put_layer(state, %{layer | mode: :browse, command_line: nil, region: :page}), []}

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

  # Esc on a conflict row takes theirs.
  defp verb(%{settings: %Layer{region: :page, mode: :browse} = layer} = state, :back)
       when map_size(layer.conflicts) > 0 do
    case Nav.current(state) do
      %{key: key} when is_map_key(layer.conflicts, {:value, key}) ->
        {put_layer(state, %{layer | conflicts: Map.delete(layer.conflicts, {:value, key})}), []}

      _ ->
        back(state)
    end
  end

  defp verb(state, :back), do: back(state)

  defp verb(state, :close), do: leave(state, :close)

  # Ctrl-C on a page closes the layer; in a text it clears first (editors).
  defp verb(%{settings: %Layer{mode: :browse}} = state, :interrupt), do: leave(state, :close)

  defp verb(%{settings: %Layer{mode: :search} = layer} = state, :interrupt),
    do: verb(%{state | settings: layer}, :escape)

  defp verb(%{settings: %Layer{region: :rail}} = state, verb)
       when verb in [:up, :down, :page_up, :page_down, :first, :last],
       do: {rail_to(state, Nav.rail_move(state, step(verb))), []}

  defp verb(%{settings: %Layer{mode: :browse}} = state, verb)
       when verb in [:up, :down, :page_up, :page_down, :first, :last] do
    {state, settled} = Ops.flush_step(state)
    {Nav.move(state, step(verb)), settled}
  end

  defp verb(%{settings: %Layer{region: :rail} = layer} = state, verb)
       when verb in [:right, :enter],
       do: {put_layer(state, %{layer | region: :page}) |> Nav.settle(), []}

  defp verb(%{settings: %Layer{region: :page, mode: :browse, popover: nil}} = state, verb)
       when verb in @row_verbs,
       do: Ops.row_verb(state, verb)

  defp verb(state, :next_region), do: {cycle_region(state, 1), []}
  defp verb(state, :previous_region), do: {cycle_region(state, -1), []}

  defp verb(%{settings: %Layer{} = layer} = state, :prev_section),
    do: leave(state, {:section, Sections.step(Layer.section(layer), -1), layer.region})

  defp verb(%{settings: %Layer{} = layer} = state, :next_section),
    do: leave(state, {:section, Sections.step(Layer.section(layer), 1), layer.region})

  defp verb(%{settings: %Layer{} = layer} = state, :jump),
    do: {put_layer(state, %{layer | jump: %{labels: Nav.jump_labels(Hint.letters())}}), []}

  defp verb(%{settings: %Layer{} = layer} = state, :help),
    do: {put_layer(state, %{layer | popover: {:help, %{scroll: 0}}}), []}

  defp verb(%{settings: %Layer{} = layer} = state, :info),
    do: {put_layer(state, %{layer | detail_open: not layer.detail_open}), []}

  defp verb(state, :search), do: Find.open(state)
  defp verb(state, :command), do: Find.command_line(state)

  defp verb(state, :refresh), do: Responses.reload(state)

  defp verb(state, _verb), do: {state, []}

  defp back_pop(%{settings: %Layer{} = layer} = state) do
    case Layer.pop(layer) do
      {:ok, layer} -> {state |> put_layer(layer) |> Nav.settle(), []}
      :top -> close(state)
    end
  end

  # Below a section page the section answers Esc first (`[]` ignores it).
  defp back(%{settings: %Layer{} = layer} = state) do
    {state, settled} = Ops.flush_step(state)

    answer =
      if Layer.depth(layer) > 1,
        do: Sections.act(Layer.section(layer), Nav.ctx(state), Nav.current(state), :escape),
        else: :default

    {state, effects} =
      case answer do
        [] -> {state, []}
        [_ | _] = ops -> Ops.run(state, ops)
        _default -> leave(state, :pop)
      end

    {state, settled ++ effects}
  end

  # ------------------------------------------------------ leaving a page

  @doc """
  Leaves the page (`:pop`, `:close`, `{:section, id, region}`) unless
  something on it is not saved (a paste, a draft being filled, staged
  fields): then the pending question asks first (§3.7.10). A record page's
  section answers `:leave` first (the MCP page applies its valid staged
  fields in one `mcp.update`).
  """
  @spec leave(State.t(), term()) :: {State.t(), list()}
  def leave(%{settings: %Layer{} = layer} = state, how) do
    case pending(layer) do
      [] ->
        leave_now(state, how)

      items ->
        body = %{items: items, then: [], continue: how, save: [], discard: discard_ops(layer)}
        {put_layer(state, %{layer | popover: {:pending, body}}), []}
    end
  end

  def leave(state, _how), do: {state, []}

  @doc "Leaves without asking (the pending question was answered)."
  @spec leave_now(State.t(), term()) :: {State.t(), list()}
  def leave_now(%{settings: %Layer{} = layer} = state, how) do
    {state, left} =
      if Layer.depth(layer) > 1 do
        case Sections.act(Layer.section(layer), Nav.ctx(state), Nav.current(state), :leave) do
          [_ | _] = ops -> Ops.run(state, ops)
          _ -> {state, []}
        end
      else
        {state, []}
      end

    {state, effects} =
      case how do
        :pop -> back_pop(state)
        :close -> close(state)
        {:section, id, region} -> go_section(state, id, region)
      end

    {state, left ++ effects}
  end

  def leave_now(state, _how), do: {state, []}

  defp pending(%Layer{} = layer) do
    paste =
      case layer.paste do
        %{bytes: bytes, target: target} when bytes != "" ->
          ["the pasted #{Map.get(target, :label) || "key"}"]

        _ ->
          []
      end

    drafts =
      for {kind, draft} <- layer.drafts,
          dirty_draft?(draft),
          do: "the new #{kind} (not created yet)"

    staged =
      for {{kind, id}, fields} <- layer.staged,
          map_size(fields) > 0,
          do: "changes to #{kind} #{id}"

    paste ++ drafts ++ staged
  end

  defp dirty_draft?(draft) when is_map(draft),
    do:
      Enum.any?(draft, fn {key, value} ->
        key not in [:errors, "errors"] and value not in [nil, "", %{}, []]
      end)

  defp dirty_draft?(_draft), do: false

  defp discard_ops(%Layer{} = layer) do
    Enum.map(Map.keys(layer.drafts), &{:draft_discard, &1}) ++
      Enum.map(Map.keys(layer.staged), &{:unstage, &1, :all})
  end

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

  defp external(state, nil, _result), do: {state, []}

  defp external(state, _spec, {:error, reason}),
    do: {Commit.status(state, "Couldn't open the editor (#{external_words(reason)})", :error), []}

  defp external(%{settings: layer} = state, %{ref: "cli.json"} = spec, {:ok, text}) do
    ref = layer.next_ref
    layer = %{layer | next_ref: ref + 1}

    {put_layer(state, layer),
     [{:settings_cli_write_text, layer.generation, ref, text, Map.get(spec, :fingerprint)}]}
  end

  defp external(%{settings: %Layer{editing: %{module: module}}} = state, _spec, {:ok, text})
       when module == SwarmCodeCLI.UI.Settings.Editors.Multiline,
       do: Edit.event(state, {:replace, text})

  defp external(state, %{ref: ref} = spec, {:ok, text}) when is_binary(ref) do
    name = Map.get(spec, :name) || ref

    op =
      {:command, "file.save", %{"ref" => ref}, %{"content" => text},
       %{
         expected: %{"fingerprint" => Map.get(spec, :fingerprint)},
         write_key: {:file, ref},
         undo: false,
         toast: "Saved #{name}",
         # A save the service wants confirmed (a project file's new hooks,
         # D14) is asked by the page that handed the file out.
         confirm_with:
           {Layer.section(state.settings),
            %{content: text, fingerprint: Map.get(spec, :fingerprint)}}
       }}

    Ops.run(state, [op])
  end

  defp external(state, _spec, _result), do: {state, []}

  defp external_words(:unavailable), do: "no editor is set; terminal.editor, VISUAL or EDITOR"
  defp external_words(:terminal), do: "the terminal could not hand over"
  defp external_words(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp external_words(_reason), do: "it did not start"

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

  # The layer's copy of the file follows a write's snapshot.
  defp put_cli_result(state, generation, {:ok, snapshot}),
    do: put_cli(state, generation, snapshot)

  defp put_cli_result(state, generation, {:ok, snapshot, _}),
    do: put_cli(state, generation, snapshot)

  defp put_cli_result(state, _generation, _result), do: state

  # A section's own cli.json change set (`{:cli_write, changes}`).
  defp batch_outcome(%{settings: layer} = state, key, write, result) do
    state = put_layer(state, %{layer | writes: Map.delete(layer.writes, key)})

    case result do
      {:ok, _} ->
        batch_done(state, write)

      {:ok, _, _} ->
        batch_done(state, write)

      {:conflict, _} ->
        {Commit.status(state, @conflict_words, :warning), []}

      {:error, :invalid, messages} ->
        {Commit.status(state, "Couldn't save: " <> first(messages), :error), []}

      {:error, reason} ->
        {Commit.status(state, "Couldn't save: " <> Commit.cli_words(reason), :error), []}
    end
  end

  defp batch_done(state, write) do
    {state, effects} = Commit.apply_names(state, write.names)
    {Commit.status(state, "Saved cli.json", :success), effects}
  end

  defp first(messages), do: messages |> Map.values() |> List.first() || "is invalid"

  defp put_cli(%{settings: %Layer{generation: layer_generation} = layer} = state, generation, cli)
       when generation in [nil, layer_generation],
       do: %{state | settings: %{layer | data: %{layer.data | cli: cli}}}

  defp put_cli(state, _generation, _cli), do: state

  defp notice(%{settings: %Layer{} = layer} = state, words),
    do: %{state | settings: %{layer | status: %{text: words, role: :text_muted, at: state.now}}}

  defp notice(state, words) do
    {:ok, safe} = SafeText.external(words, SafeText.Limits.content())
    %{state | notice: {:command_feedback, SafeText.value(safe)}}
  end
end
