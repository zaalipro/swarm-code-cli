defmodule SwarmCodeCLI.UI.Settings.Wire do
  @moduledoc """
  The settings layer's requests to the service (spec §3.4, §3.7.4): the
  `settings.query` of every view a page reads and the `settings.command` of
  every write. Pure: it answers the effects that send them.

  Each request rides the shell watch's global scope and generation, and its
  origin is `{:settings, layer_generation, {:q | :c, ref}}`; the layer keeps
  `requests[ref]` (what the answer is for), so an answer for a closed or
  reopened layer is dropped by generation and one for a replaced load by its
  reference. A request `Request` refuses by its wire bound never leaves:
  `{:error, "That is too long to save here (<param>)"}`.
  """

  alias SwarmCodeCLI.UI.DataSource.Request
  alias SwarmCodeCLI.UI.Reducer.Settings.Commit
  alias SwarmCodeCLI.UI.Settings.{Data, Layer, Nav, Page, Sections}
  alias SwarmCodeCLI.UI.State

  @deadline_ms 15_000
  @page_size 100

  @unavailable "This SwarmCode service does not offer settings. Update the CLI and the daemon together."

  @doc "The words when the service cannot answer settings requests at all."
  def unavailable_words, do: @unavailable

  # ------------------------------------------------------------ queries

  @doc """
  Sends what the page on screen needs and does not have (and is not already
  asking for): the open view on a fresh layer, then the section's `loads/1`.
  """
  @spec sync(map()) :: {map(), list()}
  def sync(%{settings: %Layer{available: true} = layer} = state) do
    loads = if layer.data.loaded_at == nil, do: [:open], else: []
    loads = loads ++ Sections.loads(Layer.section(layer), Nav.ctx(state))

    Enum.reduce(loads, {state, []}, fn load, {acc, effects} ->
      if needed?(acc.settings, load) do
        {acc, more} = load(acc, load)
        {acc, effects ++ more}
      else
        {acc, effects}
      end
    end)
  end

  def sync(state), do: {state, []}

  @doc "Asks for one load (again, even when it is loaded: a delta, Ctrl-R)."
  @spec load(map(), term()) :: {map(), list()}
  def load(state, {:auto_task, action, target} = load) do
    params = %{"action" => action, "target" => target, "attributes" => %{}}

    case command(state, params, %{kind: :task, action: action, target: target, attributes: %{}}) do
      {:error, _words, state} -> {mark(state, load, :done), []}
      {state, effects} -> {mark(state, load, :done), effects}
    end
  end

  def load(state, load) do
    case params(state, load) do
      nil -> {state, []}
      params -> query(state, params, %{kind: :load, load: load})
    end
  end

  defp params(state, :open), do: %{"view" => "open", "project_id" => project_id(state)}
  defp params(_state, :overview), do: %{"view" => "overview"}
  defp params(_state, :facts), do: %{"view" => "facts"}
  defp params(_state, :usage), do: %{"view" => "usage"}

  defp params(state, {:values, sections}) when is_list(sections),
    do: %{
      "view" => "values",
      "sections" => Enum.map(sections, &to_string/1),
      "project_id" => project_id(state)
    }

  defp params(state, {:records, kind, options}),
    do: %{
      "view" => "records",
      "kind" => kind,
      "options" => if(options == %{}, do: nil, else: options),
      "project_id" => project_id(state),
      "page_size" => @page_size
    }

  defp params(state, {:record, kind, id}),
    do: %{"view" => "record", "kind" => kind, "id" => id, "project_id" => project_id(state)}

  defp params(state, {:file, ref}),
    do: %{"view" => "file", "id" => ref, "project_id" => project_id(state)}

  defp params(_state, {:task, task_id}), do: %{"view" => "task", "id" => task_id}
  defp params(_state, _load), do: nil

  @doc "The project the page's rows belong to (the picker's choice, else the session's)."
  @spec project_id(map()) :: String.t() | nil
  def project_id(%{settings: %Layer{page_project_id: id}}) when is_binary(id), do: id
  def project_id(%{settings: %Layer{data: %Data{project_id: id}}}), do: id
  def project_id(_state), do: nil

  @doc "Sends a `settings.query` for `params`; `meta` says what the answer is for."
  @spec query(map(), map(), map()) :: {map(), list()}
  def query(%{settings: %Layer{} = layer} = state, params, meta) do
    {ref, layer} = next_ref(layer)
    state = %{state | settings: layer}

    case request(state, :settings_query, params, {:q, ref}) do
      {:ok, request, state} ->
        state = remember(state, ref, Map.put(meta, :request_id, request.request_id))
        {state, [{:query, request}]}

      {:error, _words} ->
        {state, []}
    end
  end

  # ----------------------------------------------------------- commands

  @doc """
  Sends a `settings.command` with `params` (`action`, `target`,
  `attributes`, `expected`, `secrets`, `dry_run`); `meta` is what the
  answer is for (`%{kind: :write, ref: write_ref}` for a value write).
  """
  @spec command(map(), map(), map()) :: {map(), list()} | {:error, String.t(), map()}
  def command(%{settings: %Layer{} = layer} = state, params, meta) do
    {ref, layer} = next_ref(layer)
    state = %{state | settings: layer}

    case request(state, :settings_command, params, {:c, ref}) do
      {:ok, request, state} ->
        state = remember(state, ref, Map.put(meta, :request_id, request.request_id))
        {state, [{:command, request}]}

      {:error, words} ->
        {:error, words, state}
    end
  end

  defp request(%{settings: %Layer{available: false} = layer}, _op, _params, _purpose),
    do: {:error, layer.message || @unavailable}

  defp request(state, op, params, purpose) do
    case Map.get(state.watches, :shell) do
      %{status: :ready, generation: generation} ->
        {id, state} = State.next_id(state, :request)
        origin = {:settings, state.settings.generation, purpose}
        deadline = state.now + @deadline_ms
        opts = [request_id: id, generation: generation]

        built =
          case op do
            :settings_query -> Request.settings_query(params, origin, deadline, opts)
            :settings_command -> Request.settings_command(params, origin, deadline, opts)
          end

        case built do
          {:ok, request} ->
            {:ok, request,
             %{state | requests: Map.put(state.requests, id, without_secrets(request))}}

          {:error, {:too_long, param}} ->
            {:error, Request.too_long_words(param)}

          {:error, _reason} ->
            {:error, "that request is not valid"}
        end

      _watch ->
        {:error, "the service is not connected"}
    end
  end

  # The copy the reducer keeps to match the answer never holds a secret.
  defp without_secrets(%Request{kind: {:settings_command, params}} = request),
    do: %{request | kind: {:settings_command, Map.put(params, "secrets", [])}}

  defp without_secrets(request), do: request

  # ------------------------------------------------------- section ops

  @doc "A service op of a section (`:command`, `:task`, `:cancel_task`, `:load`)."
  @spec op(map(), term()) :: {map(), list()}
  def op(state, {:command, action, target, attributes, opts}) do
    opts = Map.new(opts)

    params = %{
      "action" => action,
      "target" => json(target),
      "attributes" => json(attributes || %{}),
      "expected" => json(Map.get(opts, :expected)),
      "secrets" => secrets(state, Map.get(opts, :secrets_from)),
      "dry_run" => Map.get(opts, :dry_run, false)
    }

    meta = %{kind: :command, action: action, target: target, attributes: attributes, opts: opts}

    case command(state, params, meta) do
      {:error, words, state} -> {Commit.status(state, "Couldn't save: " <> words, :error), []}
      {state, effects} -> {state, effects}
    end
  end

  def op(state, {:task, action, target, attributes}) do
    params = %{"action" => action, "target" => target, "attributes" => attributes || %{}}
    meta = %{kind: :task, action: action, target: target, attributes: attributes || %{}}

    case command(state, params, meta) do
      {:error, words, state} ->
        {Commit.status(state, "Couldn't start that: " <> words, :error), []}

      {state, effects} ->
        {state, effects}
    end
  end

  def op(state, {:cancel_task, task_id}) do
    params = %{
      "action" => "task.cancel",
      "target" => %{"task_id" => task_id},
      "attributes" => %{}
    }

    case command(state, params, %{kind: :cancel_task, task_id: task_id}) do
      {:error, words, state} -> {Commit.status(state, words, :error), []}
      {state, effects} -> {state, effects}
    end
  end

  def op(state, {:load, load}), do: load(state, load)
  def op(state, _op), do: {state, []}

  # cli74 F12: a section's target, attributes and expected as the wire's JSON.
  # A decoded secret field is `%{set: …, hint: …}`; sent back as a key's
  # expected value it failed the bounds check ("That is too long to save
  # here (expected)") and every key replacement stopped there.
  defp json(map) when is_map(map) and not is_struct(map),
    do: Map.new(map, fn {key, value} -> {json_key(key), json(value)} end)

  defp json(list) when is_list(list), do: Enum.map(list, &json/1)
  defp json(value), do: value

  defp json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp json_key(key), do: key

  # A command's secrets come from the paste target or a draft, never from
  # its attributes (§3.7.7).
  defp secrets(%{settings: %Layer{paste: %{bytes: bytes, target: target}}}, :paste)
       when bytes != "" do
    slot = Map.get(target, :slot) || Map.get(target, "slot") || "api_key"
    [%{"slot" => slot, "value" => String.trim(bytes)}]
  end

  defp secrets(%{settings: %Layer{drafts: drafts}}, {:draft, kind}) do
    case Map.get(drafts, kind) do
      %{secrets: secrets} when is_map(secrets) ->
        for {slot, value} <- secrets,
            is_binary(value) and value != "",
            do: %{"slot" => slot, "value" => value}

      _ ->
        []
    end
  end

  defp secrets(_state, _from), do: []

  # ------------------------------------------------------------ helpers

  # The open view carries every section's values: while it is on its way no
  # values load goes out.
  # What the open view brings is not asked for beside it.
  defp needed?(%Layer{} = layer, load)
       when load in [:overview, :facts] or
              (is_tuple(load) and elem(load, 0) == :values) or
              load == {:records, "projects", %{}},
       do:
         not in_flight?(layer, :open) and not in_flight?(layer, load) and
           not loaded?(layer, load) and not failed_here?(layer, load)

  defp needed?(%Layer{} = layer, load),
    do: not in_flight?(layer, load) and not loaded?(layer, load) and not failed_here?(layer, load)

  # A load the service could not answer is asked once per arrival on a page,
  # not again after every other answer (Ctrl-R and a delta still ask).
  defp failed_here?(%Layer{requests: requests} = layer, load),
    do: Map.get(requests, {:failed, load}) == Page.ref(Layer.page(layer))

  @doc "Forgets the failed loads (Ctrl-R and a `settings_update` ask everything again)."
  @spec forget_failures(Layer.t()) :: Layer.t()
  def forget_failures(%Layer{requests: requests} = layer),
    do: %{layer | requests: Map.reject(requests, fn {key, _} -> match?({:failed, _}, key) end)}

  @doc "Remembers that `load` failed on the page on screen (see `sync/1`)."
  @spec failed(Layer.t(), term()) :: Layer.t()
  def failed(%Layer{} = layer, load),
    do: %{layer | requests: Map.put(layer.requests, {:failed, load}, Page.ref(Layer.page(layer)))}

  defp in_flight?(%Layer{requests: requests}, load),
    do: Enum.any?(requests, fn {_ref, meta} -> is_map(meta) and Map.get(meta, :load) == load end)

  @doc "Whether the layer holds what `load` asks for."
  @spec loaded?(Layer.t(), term()) :: boolean()
  def loaded?(%Layer{data: data}, :open), do: data.loaded_at != nil
  def loaded?(%Layer{data: data}, :overview), do: data.overview != nil
  def loaded?(%Layer{data: data}, :facts), do: data.facts != nil
  def loaded?(%Layer{data: data}, :usage), do: data.usage != nil

  def loaded?(%Layer{data: data}, {:values, sections}),
    do: Enum.all?(List.wrap(sections), &MapSet.member?(data.values_loaded, &1))

  def loaded?(%Layer{data: data}, {:records, kind, options}),
    do: Map.has_key?(data.records, {kind, options})

  def loaded?(%Layer{data: data}, {:record, kind, id}), do: Map.has_key?(data.record, {kind, id})
  def loaded?(%Layer{data: data}, {:file, ref}), do: Map.has_key?(data.files, ref)

  def loaded?(%Layer{requests: requests}, {:auto_task, _, _} = load),
    do: Map.get(requests, load) == :done

  def loaded?(_layer, _load), do: true

  defp mark(%{settings: layer} = state, key, value),
    do: %{state | settings: %{layer | requests: Map.put(layer.requests, key, value)}}

  defp remember(%{settings: layer} = state, ref, meta),
    do: %{state | settings: %{layer | requests: Map.put(layer.requests, ref, meta)}}

  defp next_ref(%Layer{next_ref: ref} = layer), do: {ref, %{layer | next_ref: ref + 1}}
end
