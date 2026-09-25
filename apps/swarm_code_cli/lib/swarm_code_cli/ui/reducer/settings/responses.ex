defmodule SwarmCodeCLI.UI.Reducer.Settings.Responses do
  @moduledoc """
  The service's answers to the settings layer (spec §3.4.2, §3.4.4, §3.7.4):

    * a `settings.query` answer fills the layer's data (values, record pages,
      records, files, views, task results) and settles the cursor and the
      deep link;
    * a `settings.command` answer finishes its write (a value write goes to
      `Commit`), runs the section's `after:` ops, keeps the task it started,
      puts `field_errors` into the draft, and says what happened;
    * `settings_update` (another write, here or elsewhere) re-reads what the
      page shows; `settings_task` moves a task row and fetches its result
      when it ends;
    * a watch that resynced (reconnect) re-sends what the page needs.

  Answers are matched by the layer's generation and the request's reference
  (`Settings.Wire`); anything else is dropped as stale.
  """

  alias SwarmCodeCLI.UI.DataSource.DTO

  alias SwarmCodeCLI.UI.DataSource.DTO.{
    SettingsFile,
    SettingsOpen,
    SettingsRecord,
    SettingsRecordPage,
    SettingsResult,
    SettingsSnapshot,
    SettingsTaskView,
    SettingsValues
  }

  alias SwarmCodeCLI.UI.Reducer.Settings.{Commit, Ops}
  alias SwarmCodeCLI.UI.Reducer.Settings.Paste, as: PasteTarget
  alias SwarmCodeCLI.UI.Settings.{Data, DeepLink, Layer, Nav, Page, Sections, Wire}

  @refresh_words "Couldn't tell whether that was saved; reloading."

  # ---------------------------------------------------------- responses

  @doc "A settings answer for `request` (its entry already matched scope and generation)."
  @spec response(map(), map(), term()) :: {map(), list()}
  def response(state, request, body) do
    state = %{state | requests: Map.delete(state.requests, request.request_id)}

    with {:settings, generation, {_kind, ref}} <- request.origin,
         %Layer{generation: ^generation} = layer <- state.settings,
         %{request_id: id} = meta when id == request.request_id <- Map.get(layer.requests, ref) do
      state = %{state | settings: %{layer | requests: Map.delete(layer.requests, ref)}}
      {state, effects} = handle(state, meta, body)
      {state, more} = settle(state)
      {state, effects ++ more}
    else
      _ -> {state, []}
    end
  end

  # -- loads
  defp handle(state, %{kind: :load, load: load}, {:settings_failed, _id, words}),
    do: {load_failed(state, load, words), []}

  defp handle(state, %{kind: :load, load: load}, %SettingsSnapshot{available: false} = snapshot) do
    words = snapshot.message || Wire.unavailable_words()
    {load_failed(state, load, words), []}
  end

  defp handle(
         %{settings: layer} = state,
         %{kind: :load, load: load},
         %SettingsSnapshot{} = snapshot
       ) do
    data = %{layer.data | revision: max(layer.data.revision, snapshot.revision)}
    data = put(data, load, snapshot.view, snapshot.body, state.now)
    state = %{state | settings: %{layer | data: data, available: true, message: nil}}
    follow_desktop(state)
  end

  # -- value writes
  defp handle(state, %{kind: :write, write_ref: ref}, {:settings_failed, _id, words}),
    do: Commit.daemon_result(state, ref, {:failed, words})

  defp handle(state, %{kind: :write, write_ref: ref}, %SettingsResult{} = result) do
    {state, effects} = Commit.daemon_result(state, ref, result)
    {state, more} = refresh_on_unknown(state, result)
    {state, effects ++ more}
  end

  # -- section commands and tasks
  defp handle(state, %{kind: kind}, {:settings_failed, _id, words})
       when kind in [:command, :task],
       do: {Commit.status(state, "Couldn't save: " <> words, :error), []}

  defp handle(state, %{kind: :command} = meta, %SettingsResult{} = result),
    do: command_result(state, meta, result)

  defp handle(state, %{kind: :task} = meta, %SettingsResult{} = result) do
    case result do
      %{task: %{task_id: task_id} = task} when is_binary(task_id) ->
        {track(state, task_id, meta, task), []}

      %{status: status} when status in [:accepted, :unchanged] ->
        {state, []}

      _ ->
        {Commit.status(state, "Couldn't start that: " <> (result.message || "refused"), :error),
         []}
    end
  end

  defp handle(state, _meta, _body), do: {state, []}

  defp load_failed(%{settings: layer} = state, load, words) when load in [:open] do
    %{state | settings: %{layer | available: false, message: words}}
  end

  defp load_failed(%{settings: layer} = state, {:values, _}, words),
    do: %{state | settings: %{layer | available: false, message: words}}

  defp load_failed(%{settings: layer} = state, load, words),
    do: Commit.status(%{state | settings: Wire.failed(layer, load)}, words, :error)

  # What a snapshot's body puts into the layer's data.
  defp put(data, :open, :open, %SettingsOpen{} = open, now) do
    data =
      data
      |> put_values(open.values, Sections.ids())
      |> Map.merge(%{overview: open.overview, facts: open.facts, loaded_at: now})

    case open.projects do
      %SettingsRecordPage{} = page ->
        data = %{data | projects: page_map(page)}
        Data.put_records(data, {"projects", %{}}, page_map(page), now)

      _ ->
        data
    end
  end

  defp put(data, {:values, sections}, :values, %SettingsValues{} = values, _now),
    do: put_values(data, values, sections)

  defp put(data, {:records, kind, options}, :records, %SettingsRecordPage{} = page, now),
    do: Data.put_records(data, {kind, options}, page_map(page), now)

  defp put(data, {:record, kind, id}, :record, %SettingsRecord{} = record, now),
    do: Data.put_record(data, {kind, id}, record.fields, now)

  defp put(data, {:file, ref}, :file, %SettingsFile{} = file, now),
    do: Data.put_file(data, ref, %{fields: file.fields, content: file.content}, now)

  defp put(data, :overview, :overview, overview, _now), do: %{data | overview: overview}
  defp put(data, :facts, :facts, facts, _now), do: %{data | facts: facts}
  defp put(data, :usage, :usage, usage, _now), do: %{data | usage: usage}

  defp put(data, {:task, task_id}, :task, %SettingsTaskView{} = view, now) do
    summary = %{
      state: view.state,
      message: view.message,
      summary: view.summary,
      total: view.total,
      next_cursor: view.next_cursor
    }

    Data.put_task_page(data, task_id, summary, nil, view.rows, now)
  end

  defp put(data, _load, _view, _body, _now), do: data

  defp put_values(data, %SettingsValues{} = values, sections) do
    by_key = Map.new(values.values, &{&1.key, Map.from_struct(&1)})

    %{
      data
      | values: Map.merge(data.values, by_key),
        values_loaded: Enum.reduce(sections, data.values_loaded, &MapSet.put(&2, &1)),
        project_id: values.project_id || data.project_id,
        conversation_id: values.conversation_id || data.conversation_id
    }
  end

  defp put_values(data, _values, _sections), do: data

  defp page_map(%SettingsRecordPage{} = page),
    do: %{kind: page.kind, items: page.items, next_cursor: page.next_cursor, total: page.total}

  # ---------------------------------------------------------- commands

  # The page that handed the file out asks (its `confirm_external/3`), else
  # the status line says what the service wants.
  defp needs_confirmation(state, %{confirm_with: {section, spec}}, %SettingsResult{} = result)
       when is_atom(section) do
    items = (result.confirm && Map.get(result.confirm, :items)) || []

    case Sections.confirm_external(section, Nav.ctx(state), spec, items) do
      nil -> needs_confirmation(state, %{}, result)
      ops -> Ops.run(state, List.wrap(ops))
    end
  end

  defp needs_confirmation(state, _opts, result),
    do: {Commit.status(state, result.message || "That needs a confirmation", :warning), []}

  defp command_result(state, meta, %SettingsResult{} = result) do
    opts = Map.get(meta, :opts, %{})

    case result.status do
      status when status in [:accepted, :unchanged] ->
        state = put_record(state, result.record)

        state =
          if result.task, do: track(state, result.task.task_id, meta, result.task), else: state

        state =
          if Map.get(opts, :paste) == :keep,
            do: PasteTarget.replacement_started(state, result.task && result.task.task_id),
            else: state

        text = Map.get(opts, :toast) || result.message

        state =
          if is_binary(text) and status == :accepted, do: toast(state, text, opts), else: state

        Ops.run(state, after_ops(Map.get(opts, :after), result))

      :rejected ->
        state = field_errors(state, opts, result)

        {Commit.status(
           state,
           "Couldn't save: " <> (result.message || first_error(result)),
           :error
         ), []}

      :needs_confirmation ->
        needs_confirmation(state, opts, result)

      :conflict ->
        {state, effects} = reload(state)

        {Commit.status(state, "That changed elsewhere; showing the new version", :warning),
         effects}

      _other ->
        {state, effects} = refresh_on_unknown(state, result)

        words =
          if result.corrective_action == :refresh,
            do: @refresh_words,
            else: result.message || "Couldn't save that"

        {Commit.status(state, words, :error), effects}
    end
  end

  defp toast(state, text, opts) do
    undo? = Map.get(opts, :undo, true) != false

    history =
      SwarmCodeCLI.UI.Settings.Undo.log(
        state.settings_history,
        state.now,
        text <> if(undo?, do: "", else: " · no undo"),
        undo?: undo?
      )

    Commit.status(%{state | settings_history: history}, text, :success)
  end

  defp put_record(%{settings: layer} = state, %SettingsRecord{kind: kind, id: id, fields: fields})
       when is_binary(id) do
    data = Data.put_record(layer.data, {kind, id}, fields, state.now)
    %{state | settings: %{layer | data: data}}
  end

  defp put_record(state, _record), do: state

  # `after:` of a section command (U2's options), as ops.
  defp after_ops(nil, _result), do: []
  defp after_ops(:back, _result), do: [:back]
  defp after_ops({:discard_draft, kind}, _result), do: [{:draft_discard, kind}]

  defp after_ops({:discard_draft, kind, then: then}, result),
    do: [{:draft_discard, kind} | after_ops(then, result)]

  defp after_ops({:unstage, target, fields}, _result), do: [{:unstage, target, fields}]

  defp after_ops({:task, action, target, attributes}, _result),
    do: [{:task, action, target, attributes}]

  defp after_ops({:open_record, section, kind, then: ops}, result) do
    id = result.record && result.record.id
    page = %Page{section: section, record: {kind, id}}
    ops = Enum.map(List.wrap(ops), &replace_record_id(&1, id))
    if is_binary(id), do: [{:open, page} | ops], else: ops
  end

  defp after_ops(ops, _result) when is_list(ops), do: ops
  defp after_ops(_other, _result), do: []

  defp replace_record_id(:record_id, id), do: id

  defp replace_record_id(term, id) when is_tuple(term),
    do: term |> Tuple.to_list() |> Enum.map(&replace_record_id(&1, id)) |> List.to_tuple()

  defp replace_record_id(term, id) when is_list(term),
    do: Enum.map(term, &replace_record_id(&1, id))

  defp replace_record_id(term, _id), do: term

  defp field_errors(%{settings: layer} = state, opts, %SettingsResult{
         field_errors: [_ | _] = errors
       }) do
    case Map.get(opts, :errors_to) do
      {:draft, kind} ->
        messages = Map.new(errors, &{Map.get(&1, :target), Map.get(&1, :message)})

        drafts =
          Map.update(layer.drafts, kind, %{errors: messages}, &Map.put(&1, :errors, messages))

        %{state | settings: %{layer | drafts: drafts}}

      _ ->
        state
    end
  end

  defp field_errors(state, _opts, _result), do: state

  defp first_error(%SettingsResult{field_errors: [first | _]}),
    do: Map.get(first, :message) || "is invalid"

  defp first_error(%SettingsResult{results: results}) do
    Enum.find_value(results || [], "is invalid", &Map.get(&1, :message))
  end

  defp refresh_on_unknown(state, %SettingsResult{corrective_action: :refresh}) do
    {state, effects} = reload(state)
    {Commit.status(state, @refresh_words, :warning), effects}
  end

  defp refresh_on_unknown(state, _result), do: {state, []}

  # --------------------------------------------------------------- tasks

  defp track(%{settings: layer} = state, task_id, meta, task) do
    entry = %{
      "task_id" => task_id,
      "action" => Map.get(meta, :action) || Map.get(task, :action),
      "target" => Map.get(meta, :target),
      "attributes" => Map.get(meta, :attributes) || %{},
      "state" => "running",
      "received_at_ms" => state.now,
      "mine" => true
    }

    %{state | settings: %{layer | tasks: Map.put(layer.tasks, task_id, entry)}}
  end

  # ---------------------------------------------------------------- deltas

  @doc "A global settings delta on the shell watch."
  @spec delta(map(), term()) :: {map(), list()}
  def delta(%{settings: %Layer{} = layer} = state, %DTO.SettingsUpdate{} = update) do
    if update.revision > layer.data.revision do
      data = layer.data

      data = %{
        data
        | revision: update.revision,
          values_loaded: Enum.reduce(update.sections, data.values_loaded, &MapSet.delete(&2, &1)),
          records: %{},
          record: %{},
          overview: nil
      }

      elsewhere =
        if update.origin == :elsewhere,
          do: Enum.reduce(update.sections, layer.changed_elsewhere, &Map.put(&2, &1, state.now)),
          else: layer.changed_elsewhere

      layer = Wire.forget_failures(layer)
      state = %{state | settings: %{layer | data: data, changed_elsewhere: elsewhere}}
      Wire.sync(state)
    else
      {state, []}
    end
  end

  def delta(%{settings: %Layer{} = layer} = state, %DTO.SettingsTask{task_id: id} = task) do
    current =
      Map.get(layer.tasks, id, %{
        "task_id" => id,
        "action" => task.action,
        "target" => task.target
      })

    entry =
      Map.merge(current, %{
        "state" => wire_state(task.state),
        "elapsed_ms" => task.elapsed_ms,
        "progress" => task.progress,
        "summary" => task.summary,
        "message" => task.message,
        "received_at_ms" => state.now
      })

    state = %{state | settings: %{layer | tasks: Map.put(layer.tasks, id, entry)}}
    ended? = task.state in [:done, :failed, :timeout, :cancelled]

    state =
      if ended?,
        do: PasteTarget.task_ended(state, id, task.state, task.summary || task.message),
        else: state

    if ended?,
      do: Wire.load(state, {:task, id}),
      else: {state, []}
  end

  def delta(state, _body), do: {state, []}

  @doc "Any data delivery while the layer is open: its deltas, then a resynced watch."
  @spec data(map(), term()) :: {map(), list()}
  def data(state, %{kind: :delta, body: %{kind: kind, body: body}})
      when kind in [:settings_update, :settings_task] do
    {state, effects} = delta(state, body)
    {state, more} = after_data(state)
    {state, effects ++ more}
  end

  def data(state, _delivery), do: after_data(state)

  @doc """
  After any data delivery: a shell watch that resynced (a reconnect) drops
  the loads in flight and asks again for what the page needs.
  """
  @spec after_data(map()) :: {map(), list()}
  def after_data(%{settings: %Layer{} = layer} = state) do
    case Map.get(state.watches, :shell) do
      %{status: :ready, generation: generation} when generation != layer.watch_generation ->
        requests =
          Map.reject(layer.requests, fn {_ref, meta} ->
            is_map(meta) and Map.get(meta, :kind) == :load
          end)

        state = %{state | settings: %{layer | requests: requests, watch_generation: generation}}
        Wire.sync(state)

      _ ->
        {state, []}
    end
  end

  def after_data(state), do: {state, []}

  # Re-reads the page's data (Ctrl-R, an unknown outcome, a conflict).
  @doc "Drops what the page shows and asks for it again."
  @spec reload(map()) :: {map(), list()}
  def reload(%{settings: %Layer{} = layer} = state) do
    data = %{
      layer.data
      | values_loaded: MapSet.new(),
        records: %{},
        record: %{},
        files: %{},
        overview: nil
    }

    Wire.sync(%{state | settings: %{Wire.forget_failures(layer) | data: data}})
  end

  def reload(state), do: {state, []}

  # ----------------------------------------------------------- settling

  # The cursor stays on a row that exists; a deep link to a record opens it
  # once its list has arrived; a name the search could not place opens the
  # provider or server of exactly that name.
  defp settle(%{settings: %Layer{}} = state) do
    state = state |> deep_record() |> Nav.settle()
    Wire.sync(state)
  end

  defp settle(state), do: {state, []}

  defp deep_record(%{settings: %Layer{deep_link: {:record, kind, id}} = layer} = state) do
    if Enum.any?(layer.data.records, fn {{_kind, _}, page} ->
         Enum.any?(page.items, &match?(%{id: ^id}, &1))
       end) or
         Map.has_key?(layer.data.record, {kind, id}) do
      section = DeepLink.record_section(kind) || Layer.section(layer)
      page = %Page{section: section, record: {kind, id}}
      %{state | settings: %{Layer.push(layer, page) | deep_link: nil}}
    else
      state
    end
  end

  defp deep_record(%{settings: %Layer{deep_link: {:name, name}} = layer} = state) do
    found =
      Enum.find_value(layer.data.records, fn {{kind, _}, page} ->
        Enum.find_value(page.items, fn item ->
          fields = Map.get(item, :fields) || %{}
          item_name = Map.get(fields, "name")
          if is_binary(item_name) and String.downcase(item_name) == name, do: {kind, item}
        end)
      end)

    case found do
      {_kind, %{kind: record_kind, id: id}} when is_binary(id) ->
        section = DeepLink.record_section(record_kind) || Layer.section(layer)

        layer = %{
          layer
          | stack: [%Page{section: section, record: {record_kind, id}}, Page.section(section)],
            deep_link: nil,
            mode: :browse,
            search: nil,
            region: :page
        }

        %{state | settings: layer}

      _ ->
        state
    end
  end

  defp deep_record(state), do: state

  # D18: the terminal follows the desktop's mode when cli.json names none.
  defp follow_desktop(%{settings: %Layer{data: data}, theme_env: nil} = state) do
    case {Map.get(state.prefs, "theme"), Map.get(data.values, "desktop.mode")} do
      {theme, %{value: mode}} when theme in [nil, "follow"] and mode in ["dark", "light"] ->
        mode = if mode == "light", do: :light, else: :dark

        if mode == state.theme_mode,
          do: {state, []},
          else: {%{state | theme_mode: mode}, [{:terminal_preferences, %{theme: mode}}]}

      _ ->
        {state, []}
    end
  end

  defp follow_desktop(state), do: {state, []}

  # A task entry is wire-shaped like the rest of its fields: the state is the
  # wire's word (`"running"`, `"done"`, …), which the sections compare against.
  defp wire_state(state) when is_atom(state) and not is_nil(state), do: Atom.to_string(state)
  defp wire_state(state), do: state
end
