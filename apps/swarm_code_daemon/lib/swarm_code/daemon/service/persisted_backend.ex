defmodule SwarmCode.Daemon.Service.PersistedBackend do
  @moduledoc """
  Typed service over an already admitted, running Domain Repo. This module never
  starts storage or opens a database pathname. Engine runs outlive this view;
  reconnect rebuilds projections from persisted messages, runs and nodes.

  Commands reserve a durable CLI metadata identity before execution. Completed
  outcomes replay after restart; unfinished reservations return outcome_unknown.
  The in-memory response cache is capped at 4096 identities.
  """
  use GenServer
  alias SwarmCode.Domain.{Attachments, Conversations, Engine, Projects, Repo}
  alias SwarmCode.Protocol.ServiceRequest
  alias SwarmCode.Domain.Engine.{Events, Questions, RunServer}
  @max_models 400
  # Operations that read: never ledgered, answered with a typed error.
  @reads [:query, :detail, :feature_query, :conversation_list]
  @terminal [:completed, :failed, :cancelled, :interrupted]
  alias SwarmCode.Daemon.Service.{CommandDispatcher, PersistedProjection, CommandLedger}

  @errors %{
    invalid_request: "invalid data source request",
    not_allowed: "request is not allowed",
    request_conflict: "request reference is already admitted",
    capacity_exceeded: "data source admission capacity exceeded",
    stale_revision: "request revision is stale",
    source_unavailable: "data source is unavailable",
    unknown_outcome: "previous command outcome is unknown; refresh before retrying"
  }

  def start_link(opts) do
    if Keyword.keyword?(opts) and opts[:mode] == :persisted and opts[:repo] == Repo and
         is_pid(Process.whereis(Repo)),
       do: normalize_start(GenServer.start_link(__MODULE__, opts)),
       else: {:error, :admitted_repo_required}
  end

  defp normalize_start(:ignore), do: {:error, :invalid_backend_configuration}
  defp normalize_start(result), do: result

  @impl true
  def init(opts) do
    with true <- Enum.all?([:project_id, :conversation_id, :source_epoch], &uuid?(opts[&1])),
         %{project_id: project_id} <- Conversations.get(opts[:conversation_id]),
         true <- project_id == opts[:project_id],
         %{root_path: project_root} <- Projects.get!(project_id),
         {:ok, root} <- SwarmCode.Domain.Tools.Path.real_path(opts[:project_root]),
         {:ok, ^root} <- SwarmCode.Domain.Tools.Path.real_path(project_root),
         true <- File.dir?(root) do
      :ok = CommandLedger.ensure!()

      staged_attachments =
        CommandLedger.staged_attachments(opts[:project_id], opts[:conversation_id])

      Events.subscribe(opts[:conversation_id])
      Events.ui_subscribe()
      # pass70 C5 (arch F10): what happens outside this conversation.
      SwarmCode.Domain.PubSub.subscribe(SwarmCode.Domain.PubSub, "notifications")
      SwarmCode.Domain.MCP.subscribe()

      state = %{
        opts: Keyword.put(opts, :project_root, root),
        # The realized root and the roots as configured: checkpoint paths are
        # recorded under whichever form the engine resolved against.
        roots: Enum.uniq([root, opts[:project_root], project_root]),
        runs: %{},
        order: [],
        watches: %{},
        requests: %{},
        revision: 0,
        metadata: nil,
        research_ids: [],
        attachment_ids: staged_attachments,
        refresh_pending: false,
        repo_monitor: Process.monitor(Process.whereis(Repo)),
        streams: %{},
        changes: %{},
        verdicts: %{},
        # pass70 C5: the waits already told about (so a toast fires once per
        # new wait elsewhere), the providers' last rate-limit windows, and the
        # MCP servers that failed (so their recovery is told too).
        waiting_seen: MapSet.new(Questions.list(), & &1.conversation_id),
        rate_limits: %{},
        mcp_failed: MapSet.new(),
        # pass70 C6: an agent's model is a virtual node field the RunServer
        # broadcasts and never stores; kept for the agents projected. And what
        # the projected runs left running in the background.
        agent_models: %{},
        background: %{},
        background_tick: nil,
        # pass70 C8: unified diffs being paged, and what each finished run
        # changed per file (line counts, created/modified/deleted).
        diff_cache: %{},
        diff_order: [],
        change_facts: %{},
        file_index: nil
      }

      {:ok, reload(state)}
    else
      _ -> :ignore
    end
  rescue
    _ -> :ignore
  end

  @impl true
  def handle_call({:service_request, id, scope, request}, _, state) do
    with {:ok, _} <- ServiceRequest.encode(request, scope), true <- member?(state, scope) do
      admit_request(id, scope, request, state)
    else
      _ ->
        response =
          if Map.get(request, :operation) in @reads,
            do: wire_error(:not_allowed),
            else: reject(id, :not_allowed)

        {:reply, response, state}
    end
  end

  def handle_call({:service_watch, connection, _id, scope, request}, _, state) do
    key = {connection, request.params["watch_ref"]}

    with {:ok, _} <- ServiceRequest.encode(request, scope),
         true <- is_pid(connection) and member?(state, scope),
         false <- Map.has_key?(state.watches, key),
         true <- map_size(state.watches) < 128,
         state <- refresh(state),
         {:ok, kind, body} <- snapshot(request.params, scope, nil, state) do
      entry = %{
        scope: scope,
        slot: request.params["slot"],
        ready: false,
        sequence: 0,
        acked: 0,
        queue: :queue.new(),
        bytes: 0,
        monitor: Process.monitor(connection)
      }

      {:reply, {:watch, 0, state.revision, kind, body}, put_in(state.watches[key], entry)}
    else
      _ -> {:reply, wire_error(:invalid_request), state}
    end
  end

  @impl true
  def handle_info({:service_ready, connection, ref}, state) do
    key = {connection, ref}

    case state.watches[key] do
      nil -> {:noreply, state}
      entry -> {:noreply, flush(put_in(state.watches[key], %{entry | ready: true}), key)}
    end
  end

  def handle_info({:service_credit, connection, ref, sequence}, state) do
    key = {connection, ref}

    case state.watches[key] do
      %{sequence: sent, acked: acked} = entry
      when is_integer(sequence) and sequence > acked and sequence <= sent ->
        {:noreply, flush(put_in(state.watches[key], %{entry | acked: sequence}), key)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:service_unwatch, connection, ref}, state),
    do: {:noreply, unwatch(state, {connection, ref})}

  def handle_info({:DOWN, monitor, :process, _, _}, %{repo_monitor: monitor} = state),
    do: {:stop, :admitted_repo_lost, state}

  def handle_info({:DOWN, monitor, :process, _, _}, state) do
    {:noreply,
     Enum.reduce(state.watches, state, fn {key, entry}, acc ->
       if entry.monitor == monitor, do: unwatch(acc, key), else: acc
     end)}
  end

  def handle_info({:assistant_delta, message_id, text}, state)
      when is_binary(message_id) and is_binary(text) do
    {next, run_id} = stream_append(state, message_id, text, false)

    if run_id,
      do: {:noreply, publish_stream(state, next, run_id, message_id, text, :text, false)},
      else: {:noreply, state}
  end

  def handle_info({:assistant_reset, message_id, text}, state)
      when is_binary(message_id) and is_binary(text) do
    {next, run_id} = stream_append(state, message_id, text, true)

    if run_id,
      do: {:noreply, publish_stream(state, next, run_id, message_id, text, :text, true)},
      else: {:noreply, state}
  end

  def handle_info({kind, message_id, text}, state)
      when kind in [:reasoning_delta, :reasoning_reset] and is_binary(message_id) and
             is_binary(text) do
    {next, run_id} = stream_append(state, message_id, text, kind == :reasoning_reset, :reasoning)

    if run_id,
      do:
        {:noreply,
         publish_stream(
           state,
           next,
           run_id,
           message_id,
           text,
           :reasoning,
           kind == :reasoning_reset
         )},
      else: {:noreply, state}
  end

  def handle_info(:refresh_projection, state) do
    next = reload(%{state | refresh_pending: false})
    {:noreply, publish_changes(state, next)}
  end

  # pass70 C5 (arch F10): the domain's own notices become toasts on the shell
  # watch. "Waiting" comes from `:waiting_changed` instead, which knows the
  # conversation.
  def handle_info({:notification, kind, message}, state) when is_binary(message) do
    case kind do
      :finished -> {:noreply, toast(state, "success", "Finished", message, nil)}
      :info -> {:noreply, toast(state, "info", "SwarmCode", message, nil)}
      _waiting -> {:noreply, state}
    end
  end

  def handle_info({:toast, text}, state) when is_binary(text),
    do: {:noreply, toast(state, "info", "SwarmCode", text, nil)}

  def handle_info({:waiting_changed}, state),
    do: {:noreply, schedule_refresh(waiting_elsewhere(state))}

  # Runs of this conversation may be research or workflow runs; the library
  # itself is read on demand, so a changed workflow file needs no delta.
  def handle_info({event}, state)
      when event in [:research_runs_changed, :workflow_runs_changed, :workflows_changed],
      do: {:noreply, schedule_refresh(state)}

  def handle_info({:rate_limit, provider_id, snapshot}, state)
      when is_binary(provider_id) and is_map(snapshot),
      do: {:noreply, rate_limit(state, provider_id, snapshot)}

  def handle_info({:mcp_status, server_id, status}, state),
    do: {:noreply, mcp_status(state, server_id, status)}

  # pass70 C6: the models of the agents a run just registered or switched.
  def handle_info({:nodes_upsert, _run_id, nodes} = event, state) when is_list(nodes) do
    models =
      for %{kind: "agent", id: id, model: model} <- nodes,
          is_binary(id) and is_binary(model) and model != "",
          into: state.agent_models,
          do: {id, model}

    handle_info({:projection_event, event}, %{state | agent_models: models})
  end

  # A background command ends without an event: while any is listed, look
  # again every few seconds.
  def handle_info(:background_tick, state) do
    next = reload(%{state | background_tick: nil})
    {:noreply, publish_changes(state, next)}
  end

  def handle_info({:projection_event, _event}, state), do: {:noreply, schedule_refresh(state)}

  def handle_info(event, state) when is_tuple(event) do
    if elem(event, 0) in [
         :run_created,
         :run_updated,
         :nodes_upsert,
         :nodes_patch,
         :assistant_delta,
         :reasoning_delta,
         :assistant_reset,
         :reasoning_reset,
         :message_created,
         :message_updated,
         :messages_changed,
         :question,
         :question_cleared,
         :waiting_changed,
         :workflow_updated,
         :conversation_updated
       ] do
      {:noreply, schedule_refresh(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state), do: Events.unsubscribe(state.opts[:conversation_id])
  @impl true
  def format_status(status),
    do: %{status | state: %{mode: :persisted, runs: map_size(status.state.runs)}}

  defp admit_request(id, scope, request, state) do
    command? = Map.get(request, :operation) not in @reads

    fingerprint =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary(
          {stable_scope(scope), Map.get(request, :operation), Map.get(request, :params)}
        )
      )
      |> Base.encode16(case: :lower)

    cond do
      command? and map_size(state.requests) >= 4096 and not Map.has_key?(state.requests, id) ->
        {:reply, reject(id, :capacity_exceeded), state}

      command? and match?({^fingerprint, _}, state.requests[id]) ->
        {:reply, elem(state.requests[id], 1), state}

      command? and is_tuple(state.requests[id]) ->
        {:reply, reject(id, :request_conflict), state}

      true ->
        # Opening a conversation and marking something seen are idempotent
        # and ledger nothing; creating one or changing the project does.
        durable = command? and request.operation not in [:conversation_open, :mark_seen]

        admission =
          if durable,
            do: CommandLedger.admit(state.opts[:project_id], id, scope, fingerprint),
            else: :new

        case admission do
          {:replay, saved} ->
            {:reply, saved, restore_staged_attachment(saved, state)}

          {:unresolved, _} ->
            {:reply, unknown_outcome(id), state}

          {:conflict, reason} ->
            {:reply, reject(id, reason), state}

          :new ->
            {response, next} =
              with {:ok, _} <- ServiceRequest.encode(request, scope),
                   true <- member?(state, scope) do
                execute(request, scope, id, state)
              else
                _ ->
                  {if(command?, do: reject(id, :not_allowed), else: wire_error(:not_allowed)),
                   state}
              end

            if durable, do: CommandLedger.complete(state.opts[:project_id], id, response)
            next = if command?, do: put_in(next.requests[id], {fingerprint, response}), else: next
            {:reply, response, next}
        end
    end
  end

  defp execute(%{operation: :dispatch_send, params: params}, _scope, id, state) do
    text = params["text"]

    answer =
      with {:ok, attachments} <-
             attachment_payloads(Enum.uniq(state.attachment_ids ++ params["attachment_refs"])) do
        if String.starts_with?(String.trim_leading(text), "/") do
          CommandDispatcher.dispatch(state.opts[:conversation_id], text,
            research_ids: state.research_ids,
            attachments: attachments
          )
        else
          Engine.start_chat_turn(
            Conversations.get!(state.opts[:conversation_id]),
            text,
            attachments,
            research_ids: state.research_ids
          )
        end
      end

    case answer do
      {:ok, run_id} when is_binary(run_id) ->
        consume_staged(state, state.attachment_ids)
        {accepted(id, [run_id]), refresh(%{state | research_ids: [], attachment_ids: []})}

      {:ok, %{type: :started, run_id: run_id}} ->
        consume_staged(state, state.attachment_ids)
        {accepted(id, [run_id]), refresh(%{state | research_ids: [], attachment_ids: []})}

      {:ok, %{type: :attached, research_id: research_id}} ->
        {accepted(id, []), %{state | research_ids: Enum.uniq([research_id | state.research_ids])}}

      {:ok, %{type: :attachment_staged, attachment: %{"id" => attachment_id}}} ->
        :ok =
          CommandLedger.stage_attachment(
            state.opts[:project_id],
            state.opts[:conversation_id],
            attachment_id
          )

        {accepted(id, [attachment_id]),
         %{state | attachment_ids: Enum.uniq([attachment_id | state.attachment_ids])}}

      {:ok, %{type: :updated, mode: mode}} ->
        {accepted(id, [state.opts[:conversation_id]], notice_feedback(mode)), refresh(state)}

      {:ok, %{type: type}} when type in [:updated, :stopped, :controlled, :saved] ->
        {accepted(id, [state.opts[:conversation_id]]), refresh(state)}

      {:ok, %{type: :select, subject: :goal, goal: goal}} ->
        feedback = goal_feedback(state.opts[:conversation_id], goal)
        {accepted(id, [], feedback), state}

      {:ok, %{type: :select, subject: subject}} when subject in [:rewind, :research] ->
        {accepted(id, [], navigation_feedback(subject)), state}

      {:ok, %{type: :navigate, destination: :workflows}} ->
        {accepted(id, [], navigation_feedback(:workflows)), state}

      # pass70 C7: `/new`, `/clear`, `/resume <which>` switch this service to
      # the conversation (identifiers: [its id]); the client re-scopes.
      {:ok, %{type: :conversation, conversation_id: target}} ->
        {accepted(id, [target], navigation_feedback(:conversations)),
         switch_conversation(state, target)}

      {:ok, %{type: :navigate, destination: destination}}
      when destination in [:conversations, :changes] ->
        {accepted(id, [], navigation_feedback(destination)), state}

      {:ok, %{type: :report, title: title, text: text}} ->
        {accepted(id, [], report_feedback(title, text)), state}

      {:ok, %{type: :project, project_id: project_id, text: text}} ->
        state = state |> refresh() |> toast("success", "Project", text, nil)

        {accepted(id, [project_id], %{
           "kind" => "notice",
           "feature" => nil,
           "title" => "Project",
           "text" => text,
           "conversation_id" => nil
         }), state}

      {:ok, _selection} ->
        {reject(id, :not_allowed), state}

      {:error, reason} ->
        {reject(id, error_code(reason)), state}
    end
  end

  defp execute(%{operation: :query, params: params}, scope, id, state) do
    next = refresh(state)

    case snapshot(params, scope, id, next) do
      {:ok, kind, body} -> {result(kind, body), next}
      {:error, code} -> {wire_error(code), next}
    end
  end

  # pass70 C8: `@path` completion over the project's files (the index is
  # walked at most every 30 s and kept while it is fresh).
  defp execute(%{operation: :feature_query, params: %{"feature" => "files"} = p}, _, id, state) do
    {paths, state} = file_index(state)
    items = SwarmCode.Domain.FeatureCatalog.file_matches(paths, p["id"], p["page_size"])

    body = %{
      "feature" => "files",
      "title" => "Files",
      "description" => "Files of the project",
      "items" =>
        Enum.map(items, fn item ->
          %{
            "id" => item.id,
            "title" => item.title,
            "subtitle" => item.subtitle,
            "status" => item.status,
            "detail" => item.detail,
            "actions" => [],
            "form" => nil,
            "matches" => item.matches
          }
        end),
      "state" => "idle",
      "before_cursor" => nil,
      "after_cursor" => nil,
      "request_id" => id,
      "error" => nil,
      "presence" => "covered",
      "covered_ids" => Enum.map(items, & &1.id),
      "through_sequence" => state.revision
    }

    case fit("library_snapshot", body, p["byte_limit"]) do
      {:ok, kind, body} -> {result(kind, body), state}
      {:error, code} -> {wire_error(code), state}
    end
  end

  defp execute(%{operation: operation} = request, scope, id, state)
       when operation in [:feature_query, :feature_command] do
    scoped = feature_scope(scope, state)
    {SwarmCode.Daemon.Service.FeatureRequest.execute(request, scoped, id, state.revision), state}
  end

  defp execute(%{operation: :detail, params: params}, scope, id, state) do
    next = state |> refresh() |> warm_diff(params["detail_ref"], scope)
    {result("detail_window", detail(params, scope, id, next)), next}
  end

  # pass70 C3 (arch F7): any conversation of the admitted project opens in
  # place; the service re-subscribes and re-projects, and its global watches
  # re-snapshot. `nil` is the one already open.
  defp execute(%{operation: :conversation_open, params: params}, _scope, id, state) do
    target = params["conversation_id"] || state.opts[:conversation_id]
    project = state.opts[:project_id]

    case Conversations.get(target) do
      %{project_id: ^project} ->
        {accepted(id, [target]), switch_conversation(state, target)}

      _ ->
        {reject(id, :not_allowed), state}
    end
  end

  # Create and open: the new conversation is where the next prompt goes.
  defp execute(%{operation: :conversation_new}, _scope, id, state) do
    case Conversations.create(state.opts[:project_id]) do
      {:ok, conversation} ->
        {accepted(id, [conversation.id]), switch_conversation(state, conversation.id)}

      {:error, _} ->
        {reject(id, :not_allowed), state}
    end
  end

  defp execute(%{operation: :conversation_list, params: params}, _scope, id, state) do
    case PersistedProjection.conversations(
           state.opts[:project_id],
           params["cursor"],
           params["page_size"]
         ) do
      {:ok, rows, more?} ->
        body = conversation_list(rows, more?, params["cursor"], id, state)

        case fit("conversation_list", body, params["byte_limit"]) do
          {:ok, kind, body} -> {result(kind, body), state}
          {:error, code} -> {wire_error(code), state}
        end

      {:error, code} ->
        {wire_error(code), state}
    end
  end

  # pass70 C2 (arch F12): the project's approval mode and trust, the
  # desktop's own (`Projects.trust/1` stamps `trusted_at` and lifts a
  # read-only project to `auto`).
  defp execute(%{operation: :project_update, params: params}, _scope, id, state) do
    project = Projects.get!(state.opts[:project_id])

    with {:ok, project} <- trust_project(project, params["trusted"]),
         {:ok, project} <- set_mode(project, params["approval_mode"]) do
      text = project_notice(project, params)
      state = refresh(state)
      state = toast(state, "success", "Project", text, nil)

      {accepted(id, [project.id], %{
         "kind" => "notice",
         "feature" => nil,
         "title" => "Project",
         "text" => text,
         "conversation_id" => nil
       }), state}
    else
      _ -> {reject(id, :invalid_request), state}
    end
  end

  defp execute(%{operation: :mark_seen, params: params}, scope, id, state) do
    target = params["id"]

    result =
      case params["kind"] do
        "conversation" ->
          if target == state.opts[:conversation_id],
            do: Conversations.mark_seen(target),
            else: {:error, :not_allowed}

        _run_or_activity ->
          case state.runs[target] do
            nil -> {:error, :not_allowed}
            run -> if run_member?(run, scope, state), do: Conversations.mark_run_seen(run.id)
          end
      end

    case result do
      {:ok, _} -> {accepted(id, [target]), refresh(state)}
      _ -> {reject(id, :not_allowed), state}
    end
  end

  defp execute(%{operation: :question_answer, params: p}, scope, id, state) do
    alias SwarmCode.Daemon.Service.QuestionProjection
    state = refresh(state)
    run = state.runs[p["run_id"]]

    item =
      run &&
        Enum.find(
          run.interactions,
          &(&1["id"] == p["interaction_id"] and &1["kind"] == "question")
        )

    with true <- not is_nil(run) and run_member?(run, scope, state),
         true <-
           not is_nil(item) and item["node_id"] == p["node_id"] and
             item["expected_revision"] == p["expected_revision"],
         {:ok, indices} <-
           QuestionProjection.selection(item, p["answers"], p["custom_text"] || ""),
         index when is_integer(index) <-
           QuestionProjection.index(p["node_id"], p["expected_revision"], p["interaction_id"]),
         :ok <-
           RunServer.answer_question(run.id, p["node_id"], index, indices, p["custom_text"] || "") do
      {accepted(id, [run.id]), refresh(state)}
    else
      {:error, :invalid_request} -> {reject(id, :invalid_request), state}
      {:error, :invalid_answer} -> {reject(id, :invalid_request), state}
      _ -> {reject(id, :stale_revision), state}
    end
  end

  defp execute(%{operation: operation, params: params}, scope, id, state)
       when operation in [:run_control, :run_steer, :approval_resolve] do
    state = refresh(state)
    run = state.runs[params["run_id"]]

    run =
      if run && operation == :approval_resolve,
        do: %{
          run
          | approval:
              Enum.find(
                run.interactions,
                &(&1["id"] == params["interaction_id"] and &1["kind"] == "approval")
              )
        },
        else: run

    cond do
      is_nil(run) or not run_member?(run, scope, state) ->
        {reject(id, :not_allowed), state}

      # pass70 C2 (rel F2): an approval waits on the **op** node, never on an
      # agent; the nodes a run is waiting on are admitted beside its agents.
      params["node_id"] != nil and params["node_id"] not in admitted_nodes(run) ->
        {reject(id, :not_allowed), state}

      operation == :approval_resolve and
          (is_nil(run.approval) or run.approval["id"] != params["interaction_id"] or
             run.approval["node_id"] != params["node_id"] or
             run.approval["expected_revision"] != params["expected_revision"]) ->
        {reject(id, :stale_revision), state}

      operation == :approval_resolve and
          params["decision"] not in offered_decisions(run.approval) ->
        {reject(id, :not_allowed), state}

      run.status in @terminal ->
        {reject(id, :not_allowed), state}

      true ->
        answer = control(operation, params, run, state)

        case answer do
          :ok -> {accepted(id, [run.id]), state}
          {:ok, _} -> {accepted(id, [run.id]), state}
          _ -> {reject(id, :not_allowed), state}
        end
    end
  end

  defp execute(_, _, id, state), do: {reject(id, :not_allowed), state}

  defp switch_conversation(state, id) do
    if id == state.opts[:conversation_id] do
      state
    else
      Events.unsubscribe(state.opts[:conversation_id])
      Events.subscribe(id)

      # Watches of the whole project (the shell, the activity list) now show
      # another conversation: they re-snapshot. Watches of the old
      # conversation hear nothing more; their client re-scopes them.
      watches =
        Enum.reduce(state.watches, state.watches, fn {{connection, ref} = key, entry}, acc ->
          if entry.scope.kind in [:global, :project] do
            send(connection, {:service_resync, self(), ref})
            Process.demonitor(entry.monitor, [:flush])
            Map.delete(acc, key)
          else
            acc
          end
        end)

      reload(%{
        state
        | opts: Keyword.put(state.opts, :conversation_id, id),
          watches: watches,
          runs: %{},
          order: [],
          streams: %{},
          changes: %{},
          verdicts: %{},
          metadata: nil,
          research_ids: [],
          attachment_ids: CommandLedger.staged_attachments(state.opts[:project_id], id),
          refresh_pending: false,
          diff_cache: %{},
          diff_order: [],
          change_facts: %{}
      })
    end
  end

  defp conversation_list(rows, more?, cursor, id, state) do
    # The conversations with a running run: one registry select.
    live =
      MapSet.new(
        Registry.select(SwarmCode.Domain.Registry, [{{{:run, :_}, :_, {:"$1", :_}}, [], [:"$1"]}])
      )

    waiting =
      Questions.list()
      |> Enum.frequencies_by(& &1.conversation_id)

    current = state.opts[:conversation_id]

    items =
      Enum.map(rows, fn row ->
        {runs, finished} = row.stats

        %{
          "id" => row.id,
          "title" => preview(row.title || "", 256),
          "created_at" => ms(row.inserted_at) || 0,
          "updated_at" => ms(row.updated_at) || 0,
          "run_count" => runs,
          "live" => MapSet.member?(live, row.id),
          "waiting" => Map.get(waiting, row.id, 0),
          "unread" => unread?(row.last_seen_at, finished),
          "current" => row.id == current
        }
      end)

    %{
      "project" => project_label(state.opts[:project_id]),
      "current_id" => current,
      "items" => items,
      "state" => "idle",
      "before_cursor" => if(cursor && items != [], do: hd(items)["id"]),
      "after_cursor" => if(more? and items != [], do: List.last(items)["id"]),
      "request_id" => id,
      "error" => nil,
      "presence" => if(cursor || more?, do: "off_window", else: "covered"),
      "covered_ids" => Enum.map(items, & &1["id"]),
      "through_sequence" => 0
    }
  end

  defp unread?(_seen, nil), do: false
  defp unread?(nil, _finished), do: true

  defp unread?(seen, finished) do
    case {ms(seen), ms(finished)} do
      {seen, finished} when is_integer(seen) and is_integer(finished) -> finished > seen
      _ -> false
    end
  end

  defp project_label(project_id) do
    case Projects.get(project_id) do
      %{} = project -> project_name(%{project: project})
      _ -> nil
    end
  end

  defp trust_project(project, true), do: Projects.trust(project)

  defp trust_project(project, _), do: {:ok, project}

  defp set_mode(project, mode) when mode in ["read_only", "auto", "full_access"],
    do: Projects.update(project, %{approval_mode: mode})

  defp set_mode(project, _), do: {:ok, project}

  defp project_notice(project, %{"approval_mode" => mode}) when is_binary(mode),
    do: "Approval mode: " <> mode_words(project.approval_mode)

  defp project_notice(project, _),
    do: "Project trusted; approval mode " <> mode_words(project.approval_mode)

  defp mode_words("read_only"), do: "read-only"
  defp mode_words("full_access"), do: "full access"
  defp mode_words(mode), do: to_string(mode)

  # pass70 C1: a transient notice for the shell watch.
  defp toast(state, level, title, text, run_id, conversation_id \\ nil) do
    toast_id = Ecto.UUID.generate()
    revision = state.revision + 1

    broadcast(%{state | revision: revision}, %{
      "kind" => "toast",
      "entity_id" => toast_id,
      "run_id" => nil,
      "conversation_id" => nil,
      "channel" => nil,
      "attempt_id" => nil,
      "text" => nil,
      "body" => %{
        "id" => toast_id,
        "level" => level,
        "title" => preview(title, 200),
        "text" => preview(text, 1024),
        "run_id" => run_id,
        "conversation_id" => conversation_id,
        "at" => System.system_time(:millisecond),
        "revision" => revision
      },
      "sequence" => 0,
      "revision" => revision
    })
  end

  defp schedule_refresh(%{refresh_pending: true} = state), do: state

  defp schedule_refresh(state) do
    Process.send_after(self(), :refresh_projection, 20)
    %{state | refresh_pending: true}
  end

  # One toast when another conversation starts waiting (not per request: a
  # conversation already waiting is already told).
  defp waiting_elsewhere(state) do
    waits = Questions.list() |> Enum.take(200)
    current = state.opts[:conversation_id]

    fresh =
      waits
      |> Enum.reject(fn wait ->
        wait.conversation_id == current or
          MapSet.member?(state.waiting_seen, wait.conversation_id)
      end)
      |> Enum.uniq_by(& &1.conversation_id)

    state = %{state | waiting_seen: MapSet.new(waits, & &1.conversation_id)}

    Enum.reduce(fresh, state, fn wait, acc ->
      what = if wait.kind == :approval, do: "an approval", else: "an answer"

      toast(
        acc,
        "waiting",
        "Waiting for you",
        conversation_title(wait.conversation_id) <> " needs " <> what,
        wait.run_id,
        wait.conversation_id
      )
    end)
  end

  defp conversation_title(id) do
    case Conversations.get(id) do
      %{title: title} when is_binary(title) and title != "" -> preview(title, 120)
      _ -> "Another conversation"
    end
  end

  # pass70 C5/C6: a provider's rate-limit window (the synced engine reports
  # one per response). One per provider, on the shell watch and its snapshot.
  defp rate_limit(state, provider_id, snapshot) do
    used = Map.get(snapshot, :used_percent)

    if is_number(used) and
         (Map.has_key?(state.rate_limits, provider_id) or
            map_size(state.rate_limits) < 100) do
      revision = state.revision + 1

      body = %{
        "provider_id" => provider_id,
        "provider" => rate_provider(provider_id),
        "scope" => preview(to_string(Map.get(snapshot, :scope) || ""), 64),
        "used_percent" => min(max(used * 1.0, 0.0), 100.0),
        "resets_at" => ms(Map.get(snapshot, :resets_at)),
        "retry_at" => ms(Map.get(snapshot, :retry_at)),
        "revision" => revision
      }

      same? =
        Map.delete(state.rate_limits[provider_id] || %{}, "revision") ==
          Map.delete(body, "revision")

      if same? do
        state
      else
        state = %{
          state
          | revision: revision,
            rate_limits: Map.put(state.rate_limits, provider_id, body)
        }

        broadcast(state, %{
          "kind" => "rate_limit",
          "entity_id" => provider_id,
          "run_id" => nil,
          "conversation_id" => nil,
          "channel" => nil,
          "attempt_id" => nil,
          "text" => nil,
          "body" => body,
          "sequence" => 0,
          "revision" => revision
        })
      end
    else
      state
    end
  end

  defp rate_provider(id) do
    case SwarmCode.Domain.Providers.get_cached(id) do
      %{name: name} when is_binary(name) -> preview(name, 200)
      _ -> ""
    end
  rescue
    _ -> ""
  end

  # MCP: a failure is told once, and so is the recovery after it.
  defp mcp_status(state, server_id, {:error, reason}) do
    if MapSet.member?(state.mcp_failed, server_id) do
      state
    else
      text = mcp_name(server_id) <> ": " <> preview(to_string_safe(reason), 400)
      state = %{state | mcp_failed: MapSet.put(state.mcp_failed, server_id)}
      toast(state, "warning", "MCP server failed", text, nil)
    end
  end

  defp mcp_status(state, server_id, :ready) do
    if MapSet.member?(state.mcp_failed, server_id) do
      state = %{state | mcp_failed: MapSet.delete(state.mcp_failed, server_id)}
      toast(state, "success", "MCP server ready", mcp_name(server_id), nil)
    else
      state
    end
  end

  defp mcp_status(state, _server_id, _status), do: state

  defp mcp_name(id) do
    case SwarmCode.Domain.MCP.get(id) do
      %{name: name} when is_binary(name) and name != "" -> preview(name, 120)
      _ -> "MCP server"
    end
  rescue
    _ -> "MCP server"
  end

  defp to_string_safe(value) when is_binary(value), do: value
  defp to_string_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp to_string_safe(value), do: inspect(value, limit: 20, printable_limit: 400)

  defp unknown_outcome(id),
    do:
      result("outcome", %{
        "status" => "outcome_unknown",
        "request_id" => id,
        "identifiers" => [],
        "interaction" => nil,
        "error" => error(:source_unavailable),
        "corrective_action" => "refresh"
      })

  defp stable_scope(scope), do: %{kind: scope.kind, id: scope.id}

  defp restore_staged_attachment(
         {:ok, %{"value" => %{"status" => "accepted", "identifiers" => [attachment_id]}}},
         state
       )
       when is_binary(attachment_id),
       do: %{state | attachment_ids: Enum.uniq([attachment_id | state.attachment_ids])}

  defp restore_staged_attachment(_response, state), do: state

  defp consume_staged(state, attachment_ids) when is_list(attachment_ids) do
    CommandLedger.consume_attachments(
      state.opts[:project_id],
      state.opts[:conversation_id],
      attachment_ids
    )
  end

  defp feature_scope(%{kind: :global, generation: generation}, state),
    do: %SwarmCode.Protocol.Scope{
      kind: :project,
      id: state.opts[:project_id],
      generation: generation
    }

  defp feature_scope(scope, _state), do: scope

  defp control(:run_control, %{"action" => "pause"}, run, _), do: Engine.pause_run(run.id)
  defp control(:run_control, %{"action" => "continue"}, run, _), do: Engine.continue_run(run.id)

  defp control(:run_control, %{"action" => "stop"}, %{kind: "workflow"} = run, _),
    do: SwarmCode.Domain.Workflows.control(run.id, :stop, [])

  defp control(:run_control, %{"action" => "stop"}, run, _), do: Engine.stop_run(run.id)

  defp control(:run_steer, params, run, state) do
    with {:ok, attachments} <- attachment_payloads(params["attachment_refs"]) do
      Engine.steer(state.opts[:conversation_id], params["text"], attachments,
        run_id: run.id,
        node_id: params["node_id"]
      )
    end
  end

  # pass70 C2: the five decisions (engine 6dd8d82). `approve_run` is the
  # engine's `:always` (this tool, this run); `deny_stop` denies and stops the
  # run. `always_prefix` remembers the family the service computed for this
  # request (the card's), never one a client names; the RunServer uses the
  # node's own prefix anyway.
  defp control(:approval_resolve, %{"decision" => decision}, run, _) do
    node = run.approval["node_id"]

    case decision do
      "approve" ->
        Engine.resolve_approval(run.id, node, :approve)

      "approve_run" ->
        Engine.resolve_approval(run.id, node, :always)

      "deny" ->
        Engine.resolve_approval(run.id, node, :deny)

      "deny_stop" ->
        Engine.resolve_approval(run.id, node, :deny_stop)

      "always_prefix" ->
        family = get_in(run.approval, ["approval", "command_family"])
        Engine.resolve_approval(run.id, node, :always_prefix, family)
    end
  end

  defp admitted_nodes(run), do: run.node_ids ++ Enum.map(run.interactions, & &1["node_id"])

  # A legacy client may send `approve`/`deny` to a card that predates the
  # decision list; every other decision must be one the card offered.
  defp offered_decisions(%{"approval" => %{"allowed_decisions" => [_ | _] = offered}}),
    do: offered

  defp offered_decisions(_), do: ["approve", "deny"]

  defp error_code(reason)
       when reason in [
              :invalid_request,
              :not_allowed,
              :request_conflict,
              :capacity_exceeded,
              :stale_revision,
              :source_unavailable
            ],
       do: reason

  defp error_code(:unknown_outcome), do: :unknown_outcome
  defp error_code(:not_configured), do: :source_unavailable
  # The client's closed error enum has no "not found": a model no provider
  # lists is an argument the request cannot carry, which is what it says.
  defp error_code(:unknown_model), do: :invalid_request
  defp error_code(reason) when is_atom(reason), do: :not_allowed
  defp error_code(_), do: :source_unavailable

  defp attachment_payloads(refs) when is_list(refs) and length(refs) <= 4 do
    Enum.reduce_while(refs, {:ok, []}, fn id, {:ok, acc} ->
      case Attachments.path(id) do
        {:ok, path, mime} ->
          {:cont,
           {:ok,
            [%{"id" => id, "name" => Path.basename(path), "mime" => mime, "path" => path} | acc]}}

        :error ->
          {:halt, {:error, :not_allowed}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp attachment_payloads(_), do: {:error, :invalid_request}

  defp stream_text(_old, text, true), do: preview(text, 65_536)
  defp stream_text(old, text, false), do: preview(old <> preview(text, 65_536), 65_536)

  defp stream_append(state, message_id, text, reset?, channel \\ :text) do
    Enum.reduce(state.runs, {state, nil}, fn {run_id, run}, {acc, found} ->
      if found do
        {acc, found}
      else
        case Enum.find_index(run.records, &(&1.id == message_id)) do
          nil ->
            {acc, nil}

          index ->
            records =
              List.update_at(run.records, index, fn row ->
                value = stream_text(Map.fetch!(row, channel), text, reset?)

                row
                |> Map.put(channel, value)
                |> Map.put(
                  if(channel == :text, do: :text_bytes, else: :reasoning_bytes),
                  byte_size(value)
                )
                |> Map.put(:revision, max(run.revision, acc.revision) + 1)
              end)

            next_run = %{
              run
              | records: records,
                revision: max(run.revision, acc.revision) + 1,
                status: :running
            }

            {%{
               acc
               | runs: Map.put(acc.runs, run_id, next_run),
                 revision: acc.revision + 1,
                 streams:
                   Map.put(
                     acc.streams,
                     message_id,
                     Map.take(Enum.at(records, index), [
                       :text,
                       :text_bytes,
                       :reasoning,
                       :reasoning_bytes,
                       :revision
                     ])
                   )
             }, run_id}
        end
      end
    end)
  end

  defp publish_stream(_old, state, run_id, message_id, text, channel, reset?) do
    run = state.runs[run_id]
    record = Enum.find(run.records, &(&1.id == message_id))

    if record do
      kind = if reset?, do: "stream_reset", else: "stream_append"

      stream =
        delta(kind, run, message_id, nil)
        |> Map.merge(%{
          "channel" => Atom.to_string(channel),
          "attempt_id" => run.attempt_id,
          "text" => text,
          "revision" => record.revision
        })

      broadcast(state, stream)
    else
      state
    end
  end

  defp refresh(state), do: publish_changes(state, reload(state))

  # `ops` is `%{agent_id => newest open op}`; an agent's step is that op's
  # title (a tool call reads "grep Bootstrap|…", a think reads "thinking"),
  # else its status word.
  defp agent_summary(n, ops, models) do
    status = normalize_node_status(n.status)
    stop = stop_facts(n.status, Map.get(n, :error_kind))

    step =
      case ops[n.id] do
        %{title: title} when is_binary(title) and title != "" -> title
        %{op_type: type} when is_binary(type) and type != "" -> type
        _ -> status
      end

    %{
      "id" => n.id,
      "run_id" => n.run_id,
      "revision" => stamp(n.updated_at),
      "state" => status,
      "allowed_actions" => [],
      "launched_by_superseded" => false,
      "name" => clip(n.name, 200) || "",
      "role" => agent_role(n),
      "title" => clip(n.title, 200) || "",
      "step" => clip(step, 200),
      "progress" => progress(n.progress),
      "tokens_in" => n.tokens_in || 0,
      "tokens_out" => n.tokens_out || 0,
      "cost_usd" => n.cost_usd,
      "started_at" => ms(n.started_at),
      "finished_at" => ms(n.finished_at),
      "parent_id" => n.parent_id,
      "depth" => n.depth || 0,
      "changes_stat" => clip(n.changes_stat, 200),
      "error" => if(present?(n.error), do: clip(n.error, 200)),
      "model" => clip(models[n.id], 200)
    }
    |> Map.merge(stop)
  end

  # pass70 C6 (arch F16): why a run or an agent stopped, as the synced domain
  # records it (`error_kind` holds a provider error kind or an orchestration
  # stop reason, `LLM.Error`), with the desktop's chip label. A run the user
  # stopped carries no kind: its reason is `user_stopped`.
  defp stop_facts(status, kind) do
    error = SwarmCode.Domain.LLM.Error

    {reason, error_kind} =
      cond do
        is_binary(kind) and error.stop_reason?(known_atom(kind)) -> {kind, nil}
        is_binary(kind) and error.kind?(known_atom(kind)) -> {nil, kind}
        status == "stopped" -> {"user_stopped", nil}
        true -> {nil, nil}
      end

    %{
      "stop_reason" => reason,
      "error_kind" => error_kind,
      "stop_label" => error.stop_reason_label(reason || error_kind)
    }
  end

  # Only atoms that already exist: a kind written by a newer desktop is text.
  defp known_atom(text) do
    String.to_existing_atom(text)
  rescue
    ArgumentError -> nil
  end

  defp agent_role(%{role: "worker", name: "Judge" <> _}), do: "judge"
  defp agent_role(%{role: role}) when role in ["lead", "sub", "worker", "assistant"], do: role
  defp agent_role(_), do: "unknown"

  # Progress is always a gauge on the wire: an agent that never reported one is at 0.
  defp progress(value) when is_integer(value), do: value |> max(0) |> min(100)
  defp progress(_), do: 0

  # A live agent: not queued, not finished.
  defp live_agent?(%{status: status}),
    do: status in ["running", "retrying", "awaiting_approval", "awaiting_answer", "paused"]

  # The run's error is its root agent's; a run that failed without one borrows
  # the first failed agent's. A worker's failure inside a running run is the
  # agent's error, not the run's.
  defp run_error(row, agents) do
    root = Enum.find(agents, &(&1.id == row.root_node_id))
    failed = Enum.find(agents, &(&1.status == "failed" and present?(&1.error)))

    cond do
      root && present?(root.error) -> clip(root.error, 200)
      failed && row.status in ["failed", "interrupted"] -> clip(failed.error, 200)
      true -> nil
    end
  end

  defp present?(text), do: is_binary(text) and text != ""

  # pass70 C2 (rel F11): an op stopped while it waited for approval keeps the
  # progress text "awaiting approval" on its row; a finished op no longer
  # waits, so the words go and the status speaks.
  @waiting_words ["awaiting approval", "awaiting answer"]

  defp settle_wait(%{source_kind: "op", status: status} = r)
       when status in ["done", "stopped", "failed", "interrupted", "cancelled"] do
    stale? = fn text -> is_binary(text) and String.trim(text) in @waiting_words end

    r
    |> then(&if stale?.(&1.detail), do: %{&1 | detail: ""}, else: &1)
    |> then(fn row ->
      if stale?.(row.text), do: %{row | text: "", text_bytes: 0}, else: row
    end)
  end

  defp settle_wait(r), do: r

  defp item_kind(%{source_kind: "op", op_type: "llm"}), do: "thinking"
  defp item_kind(%{source_kind: "op"}), do: "tool"
  defp item_kind(%{source_kind: kind}) when kind in ["user", "assistant", "agent"], do: "text"
  defp item_kind(%{source_kind: "error"}), do: "error"
  defp item_kind(_), do: "system"

  defp tool_call(%{source_kind: "op", op_type: type} = r, op_facts)
       when is_binary(type) and type != "llm" do
    started = ms(r.started_at)
    finished = ms(r.finished_at)
    diff = op_facts[r.id]

    %{
      # pass70 C8: an edit of a finished run says what it changed and where
      # its diff is; line counts and the diff wait until the run is over.
      "added" => diff && diff.added,
      "removed" => diff && diff.removed,
      "diff_ref" => diff && %{"id" => r.id <> ":diff", "total_bytes" => diff.total},
      "name" => clip(type, 200),
      "title" => clip(r.title, 200) || "",
      "detail" => clip(r.detail, 200) || "",
      "status" => normalize_node_status(r.status),
      "started_at" => started,
      "finished_at" => finished,
      "duration_ms" => if(started && finished && finished >= started, do: finished - started),
      "result_bytes" => r.result_bytes || 0,
      "files" => op_files(type, r.input)
    }
  end

  defp tool_call(_, _), do: nil

  # pass70 C8: per checkpoint of a finished run, what `FeatureCatalog.change_diff/2`
  # says it changed (counts, file state, the diff's size). Computed once per
  # checkpoint, at most 50 per projection, kept for the checkpoints shown.
  @facts_per_reload 50

  defp change_facts(cache, checkpoints, terminal, conversation) do
    finished = MapSet.new(terminal)
    shown = Enum.filter(checkpoints, &MapSet.member?(finished, &1.run_id))

    {facts, _budget} =
      Enum.reduce(shown, {%{}, @facts_per_reload}, fn c, {acc, budget} ->
        case Map.fetch(cache, c.id) do
          {:ok, facts} ->
            {Map.put(acc, c.id, facts), budget}

          :error when budget > 0 ->
            case SwarmCode.Domain.FeatureCatalog.change_diff(conversation, c.id) do
              {:ok, diff} ->
                {Map.put(acc, c.id, %{
                   added: diff.added,
                   removed: diff.removed,
                   file_state: diff.file_state,
                   total: byte_size(diff.text)
                 }), budget - 1}

              _ ->
                {acc, budget - 1}
            end

          :error ->
            {acc, budget}
        end
      end)

    facts
  end

  # An op's diff is its checkpoints' diffs joined by a newline, oldest first
  # (`FeatureCatalog.op_diff/2`); known when every one of them is.
  defp op_diff_facts(checkpoints, facts) do
    checkpoints
    |> Enum.filter(& &1.node_id)
    |> Enum.group_by(& &1.node_id)
    |> Enum.flat_map(fn {node_id, cs} ->
      cs =
        Enum.sort_by(cs, &{&1.inserted_at, &1.id}, fn {a, x}, {b, y} ->
          case DateTime.compare(a, b) do
            :lt -> true
            :gt -> false
            :eq -> x <= y
          end
        end)

      known = Enum.map(cs, &facts[&1.id])

      if length(cs) <= 20 and Enum.all?(known) do
        [
          {node_id,
           %{
             added: sum_known(known, :added),
             removed: sum_known(known, :removed),
             total: Enum.sum(Enum.map(known, & &1.total)) + length(known) - 1
           }}
        ]
      else
        []
      end
    end)
    |> Map.new()
  end

  defp sum_known(known, key) do
    if Enum.all?(known, &is_integer(Map.get(&1, key))),
      do: Enum.sum(Enum.map(known, &Map.get(&1, key)))
  end

  @file_ops ~w(read_file edit_file write_file list_dir)

  defp op_files(type, input) when type in @file_ops and is_binary(input) do
    case Jason.decode(input) do
      {:ok, %{"path" => path}} when is_binary(path) and path != "" ->
        [String.slice(path, 0, 512)]

      _ ->
        []
    end
  end

  defp op_files(_, _), do: []

  defp change_body(c, state) do
    facts = state.change_facts[c.id]

    %{
      "id" => c.id,
      "run_id" => c.run_id,
      "agent_id" => c.agent_id,
      "path" => change_path(c.path, c.workspace_path, state.roots),
      "restorable" => c.restorable == true,
      "at" => ms(c.inserted_at) || 0,
      "revision" => stamp(c.inserted_at) + if(facts, do: 1, else: 0),
      # pass70 C8: the op that made it and, once its run is over, what it
      # changed and where its diff is.
      "op_id" => c.node_id,
      "file_state" => (facts && facts.file_state) || "unknown",
      "added" => facts && facts.added,
      "removed" => facts && facts.removed,
      "diff_ref" => facts && %{"id" => c.id <> ":diff", "total_bytes" => facts.total}
    }
  end

  # Inside the agent's worktree → relative to the worktree; inside the project
  # → relative to the project root; anywhere else stays as recorded.
  defp change_path(path, worktree, roots) when is_binary(path) do
    case Enum.find([worktree | roots], &inside?(path, &1)) do
      nil -> path
      base -> Path.relative_to(path, base)
    end
    |> preview(1024)
  end

  defp change_path(_, _, _), do: ""

  defp inside?(path, base) when is_binary(base) and base != "",
    do: String.starts_with?(path, String.trim_trailing(base, "/") <> "/")

  defp inside?(_, _), do: false

  # A judge node whose result decodes as a JSON object is a verdict; `status` is
  # the judge node's state word (the checks say how it rated each criterion).
  defp verdict_body(%{name: "Judge" <> _ = name, result: result} = n) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, %{} = verdict} ->
        %{
          "id" => n.id,
          "run_id" => n.run_id,
          "round" => judge_round(name),
          "status" => normalize_node_status(n.status),
          "checks" => verdict_checks(verdict["checks"]),
          "summary" => clip(to_text(verdict["summary"]), 400) || "",
          "revision" => stamp(n.updated_at)
        }

      _ ->
        nil
    end
  end

  defp verdict_body(_), do: nil

  defp judge_round(name) do
    case Regex.run(~r/round\s+(\d+)/, name) do
      [_, digits] -> String.to_integer(digits)
      _ -> 0
    end
  end

  defp verdict_checks(checks) when is_list(checks) do
    checks
    |> Enum.filter(&is_map/1)
    |> Enum.take(32)
    |> Enum.map(fn check ->
      %{
        "key" => clip(to_text(check["key"]), 200) || "",
        "ok" => check_ok(check),
        "note" => clip(to_text(check["note"]), 400) || ""
      }
    end)
  end

  defp verdict_checks(_), do: []

  defp check_ok(%{"ok" => ok}) when is_boolean(ok), do: ok
  defp check_ok(%{"status" => "pass"}), do: true
  defp check_ok(%{"status" => "fail"}), do: false
  defp check_ok(_), do: nil

  defp to_text(value) when is_binary(value), do: value
  defp to_text(nil), do: nil
  defp to_text(value), do: inspect(value)

  # A wire text bound is in bytes (the client's `{:text, n}`), cut on a
  # character boundary.
  defp clip(nil, _), do: nil
  defp clip(text, max) when is_binary(text), do: preview(text, max)
  defp clip(_, _), do: nil

  # Wall-clock milliseconds; a raw SQLite datetime string (an untyped union
  # column) is parsed, anything else is unknown.
  defp ms(nil), do: nil
  defp ms(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)

  defp ms(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix(:millisecond)

  defp ms(value) when is_binary(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} -> ms(naive)
      _ -> nil
    end
  end

  defp ms(_), do: nil

  defp presentation_kind(%{goal_id: id}) when is_binary(id), do: "goal"
  defp presentation_kind(%{consensus: true}), do: "consensus"
  defp presentation_kind(%{kind: "compact"}), do: "chat"
  defp presentation_kind(row), do: row.kind

  defp reload(state) do
    conv = state.opts[:conversation_id]
    {:ok, rows, _, _} = PersistedProjection.runs(conv, nil, nil, "before", 200)
    {:ok, records, _, _} = PersistedProjection.records(conv, nil, nil, "before", 200)
    ids = Enum.map(rows, & &1.id)
    agents = PersistedProjection.agents(conv, ids)
    build_projection(state, rows, records, agents)
  end

  defp build_projection(state, rows, records, agents) do
    conv = state.opts[:conversation_id]
    ids = Enum.map(rows, & &1.id)
    pending = Questions.list(conv) |> Enum.take(200)
    grouped_records = Enum.group_by(records, & &1.run_id)
    grouped_agents = Enum.group_by(agents, & &1.run_id)
    ops = PersistedProjection.running_ops(conv, ids)
    checkpoints = PersistedProjection.checkpoints(conv, ids)

    terminal =
      for row <- rows, row.status in ["done", "stopped", "failed", "interrupted"], do: row.id

    facts = change_facts(state.change_facts, checkpoints, terminal, conv)
    state = %{state | change_facts: facts}
    op_facts = op_diff_facts(checkpoints, facts)
    checkpoint_counts = PersistedProjection.checkpoint_counts(conv, ids)

    runs =
      Map.new(rows, fn row ->
        rs = Map.get(grouped_records, row.id, [])
        ns = Map.get(grouped_agents, row.id, [])
        revision = Enum.max([stamp(row.updated_at) | Enum.map(rs ++ ns, &stamp(&1.updated_at))])

        run = %{
          id: row.id,
          node_id: row.root_node_id || row.id,
          attempt_id: row.id,
          user_id: row.id,
          kind: presentation_kind(row),
          parent_run_id: row.launched_by_run_id,
          prompt: row.label || row.prompt || "",
          status: runtime_status(row.status),
          created: stamp(row.inserted_at),
          revision: revision,
          records: [],
          agents: Enum.map(ns, &agent_summary(&1, ops, state.agent_models)),
          node_ids: Enum.map(ns, & &1.id),
          approval: nil,
          interactions: [],
          tokens_in: row.tokens_in || 0,
          tokens_out: row.tokens_out || 0,
          cost_usd: row.cost_usd,
          model: clip(row.model, 200),
          agents_total: length(ns),
          agents_running: Enum.count(ns, &live_agent?/1),
          changes_count: Map.get(checkpoint_counts, row.id, 0),
          started_at: ms(row.started_at),
          finished_at: ms(row.finished_at),
          consensus: row.consensus == true,
          error: run_error(row, ns),
          stop: stop_facts(row.status, Map.get(row, :error_kind))
        }

        rs =
          Enum.map(rs, fn r ->
            r = settle_wait(r)

            base = %{
              id: r.id,
              node_id: r.node_id,
              role: message_role(r.role),
              text: r.text,
              reasoning: r.reasoning,
              status: if(r.role == "user", do: "done", else: normalize_node_status(r.status)),
              revision: stamp(r.updated_at),
              created: stamp(r.inserted_at),
              text_bytes: r.text_bytes,
              reasoning_bytes: r.reasoning_bytes,
              attachments: Map.get(r, :attachments, []),
              kind: item_kind(r),
              tool: tool_call(r, op_facts),
              agent_id: r.agent_id,
              tokens_in: r.tokens_in || 0,
              tokens_out: r.tokens_out || 0,
              at: ms(r.started_at) || ms(r.inserted_at) || 0
            }

            case state.streams[r.id] do
              stream when is_map(stream) and run.status not in @terminal ->
                Map.merge(base, stream)

              _ ->
                base
            end
          end)

        run = %{run | records: rs}

        interactions =
          pending
          |> Enum.filter(&(&1.run_id == row.id))
          |> Enum.flat_map(&pending_interaction(&1, run, state))

        approval = Enum.find(interactions, &(&1["kind"] == "approval"))

        status =
          cond do
            approval != nil -> :waiting_approval
            interactions != [] -> :waiting_question
            true -> run.status
          end

        {row.id, %{run | interactions: interactions, approval: approval, status: status}}
      end)

    live_messages =
      Enum.flat_map(runs, fn {_, run} ->
        if run.status in @terminal, do: [], else: Enum.map(run.records, & &1.id)
      end)

    metadata = workspace_metadata(Conversations.get!(state.opts[:conversation_id]))
    revision = Enum.max([state.revision | Enum.map(Map.values(runs), & &1.revision)])
    revision = if metadata != state.metadata, do: revision + 1, else: revision

    verdicts =
      Enum.flat_map(agents, fn n ->
        case verdict_body(n) do
          nil -> []
          body -> [{n.id, body}]
        end
      end)

    background = background_bodies(ids)

    %{
      state
      | runs: runs,
        order: Enum.map(rows, & &1.id),
        streams: Map.take(state.streams, live_messages),
        revision: revision,
        metadata: metadata,
        changes: Map.new(checkpoints, &{&1.id, change_body(&1, state)}),
        verdicts: Map.new(verdicts),
        agent_models: Map.take(state.agent_models, Enum.map(agents, & &1.id)),
        background: background
    }
    |> background_tick()
  end

  # pass70 C6: what the projected runs left running (`Tools.BackgroundProcs`,
  # an ETS table; empty when the runtime has none).
  defp background_bodies([]), do: %{}

  defp background_bodies(run_ids) do
    runs = MapSet.new(run_ids)

    SwarmCode.Domain.Tools.BackgroundProcs.list_all()
    |> Enum.filter(&MapSet.member?(runs, &1.run_id))
    |> Enum.take(200)
    |> Map.new(fn entry ->
      id = "#{entry.run_id}:#{entry.os_pid}"

      {id,
       %{
         "id" => id,
         "run_id" => entry.run_id,
         "agent_id" => nil,
         "pid" => entry.os_pid,
         "command" => preview(to_string(entry.command), 512),
         "cwd" => nil,
         "state" => "running",
         "exit_code" => nil,
         "started_at" => ms(entry.started_at),
         "output_bytes" => 0,
         "revision" => stamp(entry.started_at)
       }}
    end)
  rescue
    _ -> %{}
  end

  defp background_for(runs, state) do
    shown = MapSet.new(runs, & &1.id)

    state.background
    |> Map.values()
    |> Enum.filter(&MapSet.member?(shown, &1["run_id"]))
    |> Enum.sort_by(&{&1["started_at"], &1["id"]})
  end

  defp background_tick(%{background: background, background_tick: nil} = state)
       when map_size(background) > 0,
       do: %{state | background_tick: Process.send_after(self(), :background_tick, 5_000)}

  defp background_tick(state), do: state

  # The changes and verdicts of the runs a snapshot shows, newest first.
  defp changes_for(runs, state) do
    ids = MapSet.new(runs, & &1.id)

    state.changes
    |> Map.values()
    |> Enum.filter(&MapSet.member?(ids, &1["run_id"]))
    |> Enum.sort_by(&{&1["at"], &1["id"]}, :desc)
    |> Enum.take(200)
  end

  defp verdicts_for(runs, state) do
    ids = MapSet.new(runs, & &1.id)

    state.verdicts
    |> Map.values()
    |> Enum.filter(&MapSet.member?(ids, &1["run_id"]))
    |> Enum.sort_by(&{&1["revision"], &1["id"]}, :desc)
    |> Enum.take(200)
  end

  defp query_projection(params, scope, state) do
    conv = state.opts[:conversation_id]
    slot = params["slot"]
    limit = params["page_size"]
    direction = if params["cursor"], do: params["direction"], else: "before"
    transcript_slot? = slot == "transcript" or (slot == "inspector" and scope.kind == :run)

    with {:ok, rows, rb, ra} <-
           PersistedProjection.runs(
             conv,
             scope,
             if(transcript_slot?, do: nil, else: params["cursor"]),
             direction,
             limit
           ),
         {:ok, records, tb, ta} <-
           PersistedProjection.records(
             conv,
             scope,
             if(transcript_slot?, do: params["cursor"]),
             if(transcript_slot?, do: direction, else: "before"),
             limit
           ) do
      metadata =
        if transcript_slot?,
          do: PersistedProjection.run_metadata(conv, Enum.uniq(Enum.map(records, & &1.run_id))),
          else: rows

      agents = PersistedProjection.agents(conv, Enum.map(metadata, & &1.id))
      temp = build_projection(state, metadata, records, agents)

      {:ok, temp, if(transcript_slot?, do: tb, else: rb), if(transcript_slot?, do: ta, else: ra)}
    end
  end

  defp pending_interaction(p, run, state) do
    details = RunServer.pending_interactions(run.id)

    entries =
      cond do
        is_list(details) -> details
        is_map(details) -> List.wrap(details[:approvals]) ++ List.wrap(details[:questions])
        true -> []
      end

    detail = Enum.find(entries, &(&1[:node_id] == p.node_id))
    since = stamp(p.since)

    base = %{
      "id" => p.node_id,
      "run_id" => run.id,
      "node_id" => p.node_id,
      "conversation_id" => state.opts[:conversation_id],
      "kind" => Atom.to_string(p.kind),
      "expected_revision" => since,
      "state" => "pending",
      "question" => nil,
      "approval" => nil,
      "allowed_actions" => [],
      "urgency" => "normal",
      "deadline" => 0,
      "created_at" => since
    }

    cond do
      is_nil(detail) ->
        []

      p.kind == :approval ->
        [
          %{
            base
            | "approval" => approval_card(detail, p, run, state),
              "allowed_actions" => ["approve", "deny"]
          }
        ]

      p.kind == :question ->
        SwarmCode.Daemon.Service.QuestionProjection.rows(base, detail[:questions] || [])

      true ->
        []
    end
  end

  # pass70 C2: the card's facts. The RunServer row (A2's frozen contract)
  # carries `command`, `cwd`, `reason`, `command_family`, `classification`,
  # `allowed_decisions` and `requested_at`; the op's arguments fill in for a
  # row without them.
  defp approval_card(detail, p, run, state) do
    tool = bound(detail[:tool], 200) || "agent operation"
    args = decode_args(detail[:args])
    command = detail_text(detail, :command) || (tool == "run_command" && args["command"]) || nil
    classification = classification(detail[:classification])
    family = detail_text(detail, :command_family)
    agent = approval_agent(p.node_id, run)

    %{
      "tool" => tool,
      "permission" => permission(detail[:permission]),
      "arguments_preview" => bound(to_string(detail[:args] || "{}"), 65_536) || "{}",
      "arguments_detail_ref" => nil,
      "command" => bound(command, 4096),
      "cwd" => approval_cwd(detail, args, tool, state),
      "reason" => bound(detail_text(detail, :reason) || args["justification"], 1024),
      "command_family" => if(classification != "dangerous", do: bound(family, 200)),
      "classification" => classification,
      "agent_id" => agent && agent["id"],
      "agent_name" => agent && bound(agent["name"], 200),
      "requested_at" => unix_ms(detail[:requested_at]) || unix_ms(p.since),
      "allowed_decisions" => decisions(detail[:allowed_decisions], classification, family)
    }
  end

  @decisions ~w(approve approve_run always_prefix deny deny_stop)

  # The row's own list when it has one (the RunServer knows what it can do);
  # `always_prefix` only with a family the card shows.
  defp decisions([_ | _] = offered, classification, family) do
    offered = offered |> Enum.map(&to_string/1) |> Enum.filter(&(&1 in @decisions)) |> Enum.uniq()
    remembered? = classification != "dangerous" and family?(family)
    if remembered?, do: offered, else: offered -- ["always_prefix"]
  end

  defp decisions(_none, "dangerous", _family), do: ["approve", "deny", "deny_stop"]

  defp decisions(_none, _classification, family) do
    prefix = if family?(family), do: ["always_prefix"], else: []
    ["approve", "approve_run"] ++ prefix ++ ["deny", "deny_stop"]
  end

  defp family?(text), do: is_binary(text) and String.trim(text) != ""

  defp permission(value) when value in [:read, :write, :execute], do: Atom.to_string(value)
  defp permission(value) when value in ["read", "write", "execute"], do: value
  defp permission(_), do: "write"

  defp classification(value) when value in [:safe, :normal, :dangerous], do: Atom.to_string(value)
  defp classification(value) when value in ["safe", "normal", "dangerous"], do: value
  defp classification(_), do: "unknown"

  defp detail_text(detail, key) do
    case detail[key] do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp decode_args(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp decode_args(%{} = args), do: args
  defp decode_args(_), do: %{}

  # The working directory as the user reads it: relative to the project root,
  # "." for the root itself.
  defp approval_cwd(detail, args, tool, state) do
    raw =
      detail_text(detail, :cwd) ||
        case args["workdir"] do
          dir when is_binary(dir) and dir != "" -> dir
          _ -> if tool == "run_command", do: "."
        end

    case raw do
      nil ->
        nil

      dir ->
        base = Enum.find(state.roots, &(is_binary(&1) and (dir == &1 or inside?(dir, &1))))

        cond do
          base == dir -> "."
          base -> bound(Path.relative_to(dir, base), 1024)
          true -> bound(dir, 1024)
        end
    end
  end

  defp approval_agent(node_id, run) do
    agent_id =
      Enum.find_value(run.records, fn r -> if r.node_id == node_id, do: r.agent_id end)

    Enum.find(run.agents, &(&1["id"] == agent_id))
  end

  defp unix_ms(value) when is_integer(value) and value > 0, do: value
  defp unix_ms(%DateTime{} = value), do: DateTime.to_unix(value, :millisecond)
  defp unix_ms(%NaiveDateTime{} = value), do: ms(value)
  defp unix_ms(_), do: nil

  defp bound(nil, _), do: nil
  defp bound(false, _), do: nil
  defp bound(text, max) when is_binary(text), do: preview(text, max)
  defp bound(value, max) when is_atom(value), do: bound(Atom.to_string(value), max)
  defp bound(_, _), do: nil

  defp publish_changes(old, state) do
    state = if old.metadata != state.metadata, do: broadcast_metadata(state), else: state
    state = publish_entities(old, state)

    Enum.reduce(state.order, state, fn id, acc ->
      run = acc.runs[id]
      previous = old.runs[id]

      if previous == run do
        acc
      else
        acc = broadcast(acc, delta("run_update", run, run.id, summary(run, acc)))

        # Agents move while a run is live: a new lane, a step, a gauge. Each
        # one that differs from the last published body goes out as its own
        # upsert, so the hive and the speaker lines follow without a resync.
        previous_agents = Map.new((previous && previous.agents) || [], &{&1["id"], &1})

        acc =
          Enum.reduce(run.agents, acc, fn agent, a ->
            if previous_agents[agent["id"]] == agent,
              do: a,
              else: broadcast(a, delta("agent_update", run, agent["id"], agent))
          end)

        removed_records =
          ((previous && Enum.map(previous.records, & &1.id)) || []) --
            Enum.map(run.records, & &1.id)

        removed_records =
          PersistedProjection.represented_node_ids(acc.opts[:conversation_id], removed_records)

        acc =
          Enum.reduce(removed_records, acc, fn record_id, a ->
            broadcast(a, delta("transcript_remove", run, record_id, nil))
          end)

        acc =
          Enum.reduce(transcript(run, acc), acc, fn body, a ->
            broadcast(a, delta("node_upsert", run, body["id"], body))
          end)

        acc = broadcast(acc, delta("activity_upsert", run, run.id, activity(run, acc)))

        old_interactions = if previous, do: previous.interactions, else: []

        acc =
          Enum.reduce(old_interactions, acc, fn item, a ->
            if Enum.any?(run.interactions, &(&1["id"] == item["id"])),
              do: a,
              else: broadcast(a, delta("interaction_remove", run, item["id"], nil))
          end)

        Enum.reduce(run.interactions, acc, fn item, a ->
          broadcast(a, delta("interaction_upsert", run, item["id"], item))
        end)
      end
    end)
  end

  # Changes and verdicts travel like the other entities: an upsert for every
  # body that differs from the last published one, a removal for a checkpoint
  # that left the newest-200 window or was deleted. The body's revision is the
  # delta's, so the client dedupes on it.
  defp publish_entities(old, state) do
    state =
      Enum.reduce(state.changes, state, fn {id, body}, acc ->
        if old.changes[id] == body,
          do: acc,
          else: broadcast(acc, entity_delta("change_upsert", body["run_id"], id, body, acc))
      end)

    state =
      Enum.reduce(Map.keys(old.changes) -- Map.keys(state.changes), state, fn id, acc ->
        gone = old.changes[id]
        broadcast(acc, entity_delta("change_remove", gone["run_id"], id, nil, acc))
      end)

    state =
      Enum.reduce(state.verdicts, state, fn {id, body}, acc ->
        if old.verdicts[id] == body,
          do: acc,
          else: broadcast(acc, entity_delta("verdict_upsert", body["run_id"], id, body, acc))
      end)

    state =
      Enum.reduce(state.background, state, fn {id, body}, acc ->
        if old.background[id] == body,
          do: acc,
          else: broadcast(acc, entity_delta("background_upsert", body["run_id"], id, body, acc))
      end)

    Enum.reduce(Map.keys(old.background) -- Map.keys(state.background), state, fn id, acc ->
      gone = old.background[id]
      broadcast(acc, entity_delta("background_remove", gone["run_id"], id, nil, acc))
    end)
  end

  defp entity_delta(kind, run_id, entity, body, state) do
    run = state.runs[run_id] || %{id: run_id, revision: state.revision}
    delta(kind, run, entity, body)
  end

  defp broadcast_metadata(state) do
    broadcast(state, %{
      "kind" => "workspace_metadata",
      "entity_id" => nil,
      "run_id" => nil,
      "conversation_id" => state.opts[:conversation_id],
      "channel" => nil,
      "attempt_id" => nil,
      "text" => nil,
      "body" => state.metadata,
      "sequence" => 0,
      "revision" => state.revision
    })
  end

  defp delta(kind, run, entity, body),
    do: %{
      "kind" => kind,
      "entity_id" => entity,
      "run_id" => run.id,
      "conversation_id" => nil,
      "channel" => nil,
      "attempt_id" => nil,
      "text" => nil,
      "body" => body,
      "sequence" => 0,
      "revision" =>
        if(is_map(body), do: Map.get(body, "revision", run.revision), else: run.revision)
    }

  defp transcript(run, state),
    do:
      Enum.map(run.records, fn row ->
        node(run, state, row.id, row.role, row.text, row.reasoning, row.status, row.revision)
        |> Map.put("node_id", row.node_id)
        |> Map.put("attachment_refs", attachment_ids(Map.get(row, :attachments, [])))
        |> Map.put("created_sequence", row.created)
        |> Map.merge(%{
          "kind" => row.kind,
          "tool" => row.tool,
          "agent_id" => row.agent_id,
          "tokens_in" => row.tokens_in,
          "tokens_out" => row.tokens_out,
          "at" => row.at
        })
        |> Map.put(
          "detail_ref",
          if(row.text_bytes > byte_size(preview(row.text)),
            do: %{"id" => row.id <> ":text", "total_bytes" => row.text_bytes}
          )
        )
        |> Map.put(
          "reasoning_detail_ref",
          if(row.reasoning_bytes > byte_size(preview(row.reasoning)),
            do: %{"id" => row.id <> ":reasoning", "total_bytes" => row.reasoning_bytes}
          )
        )
      end)

  defp summary(run, state),
    do:
      %{
        "created_sequence" => run.created,
        "parent_run_id" => run.parent_run_id,
        "seen_revision" => 0,
        "id" => run.id,
        "conversation_id" => state.opts[:conversation_id],
        "kind" => run.kind,
        "title" => preview(run.prompt, 256),
        "revision" => run.revision,
        "state" => status(run.status),
        "allowed_actions" => actions(run),
        "progress" => nil,
        "tokens_in" => run.tokens_in,
        "tokens_out" => run.tokens_out,
        "cost_usd" => run.cost_usd,
        "model" => run.model,
        "agents_total" => run.agents_total,
        "agents_running" => run.agents_running,
        "needs" => length(run.interactions),
        "changes" => run.changes_count,
        "started_at" => run.started_at,
        "finished_at" => run.finished_at,
        "consensus" => run.consensus,
        "error" => run.error
      }
      |> Map.merge(run.stop)

  defp member?(_, %{kind: :global, id: nil}), do: true
  defp member?(state, %{kind: :project, id: id}), do: id == state.opts[:project_id]
  defp member?(state, %{kind: :conversation, id: id}), do: id == state.opts[:conversation_id]

  defp member?(state, %{kind: :run, id: id}) do
    conv = state.opts[:conversation_id]
    match?(%{conversation_id: ^conv}, Conversations.get_run(id))
  end

  defp member?(_, _), do: false
  defp run_member?(run, %{kind: :run, id: id}, _), do: run.id == id
  defp run_member?(_, scope, state), do: member?(state, scope)
  defp stamp(nil), do: 0
  defp stamp(%DateTime{} = value), do: DateTime.to_unix(value, :microsecond)
  defp runtime_status("done"), do: :completed
  defp runtime_status("stopped"), do: :cancelled
  defp runtime_status("failed"), do: :failed
  defp runtime_status("interrupted"), do: :interrupted
  defp runtime_status("paused"), do: :paused
  defp runtime_status("waiting_user"), do: :waiting_question
  defp runtime_status(_), do: :running
  defp normalize_node_status("awaiting_approval"), do: "waiting_approval"
  defp normalize_node_status("awaiting_answer"), do: "waiting_question"
  defp normalize_node_status("waiting_user"), do: "waiting_question"
  defp normalize_node_status("retrying"), do: "running"
  defp normalize_node_status(status), do: status
  defp message_role("error"), do: "system"
  defp message_role(role) when role in ["user", "assistant", "tool"], do: role
  defp message_role(_), do: "assistant"
  defp uuid?(id), do: is_binary(id) and match?({:ok, ^id}, Ecto.UUID.cast(id))

  defp attachment_ids(values) when is_list(values),
    do:
      Enum.flat_map(values, fn value ->
        if is_map(value) and is_binary(value["id"]), do: [value["id"]], else: []
      end)

  defp attachment_ids(_), do: []

  defp broadcast(state, delta) do
    delta = Map.put(delta, "conversation_id", state.opts[:conversation_id])

    Enum.reduce(state.watches, state, fn {key, entry}, acc ->
      relevant =
        member?(state, entry.scope) and
          (entry.scope.kind != :run or entry.scope.id == delta["run_id"]) and
          case entry.slot do
            # pass70 C1: toasts and rate limits reach the shell watch alone.
            "shell" ->
              delta["kind"] in ["run_update", "toast", "rate_limit"]

            "activity" ->
              delta["kind"] == "activity_upsert"

            "workspace" ->
              delta["kind"] not in ["activity_upsert", "toast", "rate_limit"]

            # pass70 C6: background commands belong to the workspace and the
            # run inspector, not to the transcript or pending windows.
            "inspector" ->
              delta["kind"] not in [
                "activity_upsert",
                "workspace_metadata",
                "toast",
                "rate_limit"
              ]

            _ ->
              delta["kind"] not in [
                "activity_upsert",
                "workspace_metadata",
                "toast",
                "rate_limit",
                "background_upsert",
                "background_remove"
              ]
          end

      if relevant do
        size = byte_size(Jason.encode!(delta))
        # Coalesce complete entity replacements only. Stream events must retain
        # their channel and order: dropping an append loses tokens, and moving
        # a reset across an append changes the resulting text.
        pending = :queue.to_list(entry.queue)

        pending =
          Enum.reject(pending, fn {old, _} ->
            delta["kind"] not in ["stream_append", "stream_reset"] and
              old["kind"] == delta["kind"] and old["entity_id"] == delta["entity_id"] and
              not (delta["kind"] == "node_upsert" and
                     Enum.any?(pending, fn {queued, _} ->
                       queued["kind"] in ["stream_append", "stream_reset"] and
                         queued["entity_id"] == delta["entity_id"]
                     end))
          end)

        entry = %{
          entry
          | queue: :queue.from_list(pending),
            bytes: Enum.reduce(pending, 0, fn {_, bytes}, n -> n + bytes end)
        }

        if :queue.len(entry.queue) >= 128 or entry.bytes + size > 1_048_576 or size > 131_072 or
             (is_binary(delta["text"]) and byte_size(delta["text"]) > 65_536) do
          {connection, ref} = key
          send(connection, {:service_overflow, self(), ref})
          unwatch(acc, key)
        else
          entry = %{
            entry
            | queue: :queue.in({delta, size}, entry.queue),
              bytes: entry.bytes + size
          }

          flush(put_in(acc.watches[key], entry), key)
        end
      else
        acc
      end
    end)
  end

  defp flush(state, {connection, ref} = key) do
    case state.watches[key] do
      %{ready: true, sequence: sequence, acked: sequence} = entry ->
        case :queue.out(entry.queue) do
          {{:value, {delta, size}}, queue} ->
            send(
              connection,
              {:service_delta, self(), ref, Map.put(delta, "sequence", sequence + 1)}
            )

            put_in(state.watches[key], %{
              entry
              | sequence: sequence + 1,
                queue: queue,
                bytes: entry.bytes - size
            })

          _ ->
            state
        end

      _ ->
        state
    end
  end

  defp unwatch(state, key) do
    case Map.pop(state.watches, key) do
      {nil, _} ->
        state

      {entry, watches} ->
        Process.demonitor(entry.monitor, [:flush])
        %{state | watches: watches}
    end
  end

  defp snapshot(params, scope, request_id, state) do
    with {:ok, state, before, after_cursor} <- query_projection(params, scope, state) do
      runs =
        state.order |> Enum.map(&state.runs[&1]) |> Enum.filter(&run_member?(&1, scope, state))

      limit = params["page_size"]

      items =
        Enum.flat_map(runs, &transcript(&1, state))
        |> Enum.sort_by(&{&1["created_sequence"], &1["id"]})

      pending = Enum.flat_map(runs, & &1.interactions)
      run_bodies = Enum.map(runs, &summary(&1, state))
      slot = params["slot"]

      source =
        case slot do
          "transcript" -> items
          "pending" -> pending
          "activity" -> Enum.map(runs, &activity(&1, state))
          _ -> run_bodies
        end

      selected = Enum.take(source, limit)

      with true <- true do
        base = page_info(request_id, selected, before, after_cursor)

        transcript =
          window(
            Enum.take(items, -limit),
            request_id,
            if(slot == "inspector" and scope.kind == :run, do: before, else: nil),
            if(slot == "inspector" and scope.kind == :run, do: after_cursor, else: nil)
          )

        kind =
          %{
            "shell" => "shell_snapshot",
            "workspace" => "workspace_snapshot",
            "transcript" => "transcript_window",
            "pending" => "pending_interactions",
            "activity" => "activity_snapshot",
            "inspector" => "run_detail_snapshot"
          }[slot]

        body =
          case slot do
            "shell" ->
              Map.merge(base, %{
                "rate_limits" =>
                  state.rate_limits |> Map.values() |> Enum.sort_by(& &1["provider"]),
                "runs" => selected,
                "connection" => %{
                  "state" => "connected",
                  "source_epoch" => state.opts[:source_epoch]
                },
                "counts" => counts(runs)
              })

            "workspace" ->
              Map.merge(base, %{
                "allowed_actions" => ["send"],
                "revision" => state.revision,
                "seen_revision" => 0,
                "runs_page" => base,
                "interactions_page" => page_info(request_id, Enum.take(pending, limit)),
                "conversation_id" => state.opts[:conversation_id],
                "runs" => selected,
                "transcript" => transcript,
                "interactions" => Enum.take(pending, limit),
                "changes" => changes_for(runs, state),
                "verdicts" => verdicts_for(runs, state),
                "agents" => Enum.flat_map(runs, & &1.agents) |> Enum.take(limit),
                "background" => background_for(runs, state)
              })
              |> Map.merge(state.metadata)

            "inspector" ->
              Map.merge(base, %{
                "run" => List.first(selected),
                "agents" => Enum.flat_map(runs, & &1.agents) |> Enum.take(limit),
                "transcript" => transcript,
                "tab" => "thread"
              })

            "activity" ->
              Map.merge(base, %{"items" => selected, "counts" => counts(runs)})

            _ ->
              Map.put(base, "items", selected)
          end

        fit(kind, body, params["byte_limit"])
      end
    end
  end

  defp fit(kind, body, bytes) do
    if byte_size(Jason.encode!(body)) <= bytes,
      do: {:ok, kind, body},
      else: {:error, :capacity_exceeded}
  end

  defp workspace_mode(%{consensus: true}), do: "consensus"
  defp workspace_mode(%{ultra: true}), do: "ultra"
  defp workspace_mode(%{authoring_workflow: true}), do: "workflow"
  defp workspace_mode(%{mode: "plan"}), do: "plan"
  defp workspace_mode(_), do: "build"

  defp workspace_metadata(conversation) do
    chat = SwarmCode.Domain.Providers.effective_model(conversation, :chat)
    totals = PersistedProjection.conversation_totals(conversation.id)

    %{
      "conversation_id" => conversation.id,
      "mode" => workspace_mode(conversation),
      "project" => project_name(conversation),
      "chat_model" => effective_model_name(conversation, :chat),
      "swarm_model" => effective_model_name(conversation, :swarm),
      "effort" => conversation.effort,
      "swarm_effort" => conversation.swarm_effort,
      "models" => model_options(),
      # pass70 C1/C2: the status line's facts.
      "approval_mode" => approval_mode(conversation),
      "trusted" => trusted(conversation),
      "chat_provider" => provider_name(chat),
      "context_used" => totals.context_used,
      "context_window" => context_window(chat),
      "cost_usd" => totals.cost_usd,
      "title" => if(is_binary(conversation.title), do: preview(conversation.title, 256))
    }
  end

  defp approval_mode(%{project: %{approval_mode: mode}})
       when mode in ["read_only", "auto", "full_access"],
       do: mode

  defp approval_mode(_), do: nil

  defp trusted(%{project: %{} = project}), do: Projects.trusted?(project)
  defp trusted(_), do: nil

  defp provider_name({:ok, %{provider: %{name: name}}}) when is_binary(name) and name != "",
    do: preview(name, 200)

  defp provider_name(_), do: nil

  # The window the harness works in: the point where `Context.trim/2` starts
  # dropping history (75 % of the model's configured window, or the default
  # budget for its family).
  defp context_window({:ok, %{model: model}}) when is_binary(model),
    do: SwarmCode.Domain.Engine.Context.budget(model, SwarmCode.Domain.Settings.get_cached())

  defp context_window(_), do: nil

  defp project_name(%{project: %{name: name}}) when is_binary(name) and name != "",
    do: preview(name, 200)

  defp project_name(%{project: %{root_path: root}}) when is_binary(root) and root != "",
    do: preview(Path.basename(root), 200)

  defp project_name(_), do: nil

  # Every model a `/model` or `/swarm_model` switch may name, provider by
  # provider, bounded so a gateway that lists hundreds of ids cannot flood the
  # wire. The ids are what the dispatcher resolves; the names are for people.
  defp model_options do
    SwarmCode.Domain.Providers.list()
    |> Enum.flat_map(fn provider ->
      Enum.map(provider.models || [], fn model ->
        %{
          "provider_id" => provider.id,
          "provider" => preview(provider.name || "", 200),
          "model" => preview(model, 200)
        }
      end)
    end)
    |> Enum.filter(&(&1["model"] != ""))
    |> Enum.take(@max_models)
  end

  defp effective_model_name(conversation, role) do
    case SwarmCode.Domain.Providers.effective_model(conversation, role) do
      {:ok, %{model: model}} -> preview(model, 256)
      _ -> nil
    end
  end

  defp page_info(request_id, items, before_cursor \\ nil, after_cursor \\ nil),
    do: %{
      "state" => "idle",
      "before_cursor" => before_cursor,
      "after_cursor" => after_cursor,
      "request_id" => request_id,
      "error" => nil,
      "presence" => "covered",
      "covered_ids" => Enum.map(items, & &1["id"]),
      "through_sequence" => 0
    }

  defp window(items, id, before_cursor, after_cursor),
    do: Map.put(page_info(id, items, before_cursor, after_cursor), "items", items)

  defp node(run, state, id, role, text, reasoning, status, revision),
    do: %{
      "created_sequence" => run.created,
      "attachment_refs" => [],
      "detail_ref" => detail_ref(id <> ":text", text),
      "reasoning_detail_ref" => detail_ref(id <> ":reasoning", reasoning),
      "target_kind" => "main",
      "target_id" => nil,
      "id" => id,
      "run_id" => run.id,
      "conversation_id" => state.opts[:conversation_id],
      "node_id" => run.node_id,
      "revision" => revision,
      "role" => role,
      "state" => status,
      "text" => preview(text),
      "reasoning" => preview(reasoning),
      "attempt_id" => run.attempt_id,
      "allowed_actions" => []
    }

  defp activity(run, state),
    do: %{
      "seen_revision" => 0,
      "id" => run.id,
      "run_id" => run.id,
      "conversation_id" => state.opts[:conversation_id],
      "kind" => activity_kind(run.status),
      "state" => status(run.status),
      "title" => preview(run.prompt, 256),
      "revision" => run.revision,
      "allowed_actions" => actions(run),
      "interaction" => run.approval || List.first(run.interactions),
      "deadline" => nil,
      "created_at" => run.created
    }

  defp activity_kind(:waiting_approval), do: "approval"
  defp activity_kind(:waiting_question), do: "question"
  defp activity_kind(:paused), do: "paused"
  defp activity_kind(:failed), do: "failure"
  defp activity_kind(s) when s in @terminal, do: "completion"
  defp activity_kind(_), do: "running"

  defp counts(runs),
    do: %{
      "running" => Enum.count(runs, &(&1.status == :running)),
      "waiting" => Enum.count(runs, &(&1.status in [:waiting_approval, :waiting_question])),
      "paused" => Enum.count(runs, &(&1.status == :paused)),
      "failed" => Enum.count(runs, &(&1.status in [:failed, :interrupted])),
      "done" => Enum.count(runs, &(&1.status in [:completed, :cancelled])),
      "unseen" => 0
    }

  defp status(:completed), do: "done"
  defp status(:cancelled), do: "stopped"
  defp status(s), do: Atom.to_string(s)
  defp actions(%{status: s}) when s in @terminal, do: []
  defp actions(%{status: :paused}), do: ["continue", "stop", "steer"]
  defp actions(_), do: ["pause", "stop", "steer"]

  defp detail(params, scope, id, state) do
    ref = params["detail_ref"]
    offset = params["offset"]

    base = %{
      "detail_ref" => nil,
      "state" => "error",
      "error" => error(:invalid_request),
      "offset" => offset,
      "text" => "",
      "next_offset" => nil,
      "through_sequence" => 0,
      "request_id" => id
    }

    found =
      case String.split(ref, ":", parts: 2) do
        [entity_id, channel] when channel in ["text", "reasoning"] ->
          if uuid?(entity_id),
            do:
              PersistedProjection.detail(
                state.opts[:conversation_id],
                scope,
                entity_id,
                channel,
                offset,
                params["bytes"]
              )

        # pass70 C8: an edit's or a change's unified diff, cut into windows.
        [entity_id, "diff"] ->
          case cached_diff(state, entity_id, scope) do
            {:ok, text} ->
              %{
                text:
                  binary_part(
                    text,
                    min(offset, byte_size(text)),
                    max(min(params["bytes"], byte_size(text) - offset), 0)
                  ),
                total: byte_size(text)
              }

            _ ->
              nil
          end

        _ ->
          nil
      end

    case found do
      %{text: raw, total: total} when total > offset ->
        text = preview(raw, params["bytes"])

        if text != "",
          do:
            Map.merge(base, %{
              "state" => "idle",
              "error" => nil,
              "detail_ref" => %{"id" => ref, "total_bytes" => total},
              "text" => text,
              "next_offset" => if(offset + byte_size(text) < total, do: offset + byte_size(text))
            }),
          else: base

      _ ->
        base
    end
  end

  @file_index_ms 30_000

  defp file_index(%{file_index: {at, paths}} = state) when is_list(paths) do
    if System.monotonic_time(:millisecond) - at < @file_index_ms,
      do: {paths, state},
      else: file_index(%{state | file_index: nil})
  end

  defp file_index(state) do
    {paths, _truncated?} = SwarmCode.Domain.FeatureCatalog.file_index(state.opts[:project_root])
    {paths, %{state | file_index: {System.monotonic_time(:millisecond), paths}}}
  end

  # A diff is computed once and paged from memory: at most 8 of them and
  # 4 MB, the oldest dropped first (and computed again when asked again).
  @diff_cache_entries 8
  @diff_cache_bytes 4_000_000

  defp warm_diff(state, ref, scope) when is_binary(ref) do
    with [id, "diff"] <- String.split(ref, ":", parts: 2),
         false <- Map.has_key?(state.diff_cache, {id, scope.kind, scope.id}),
         {:ok, text} <- diff_text(id, scope, state) do
      key = {id, scope.kind, scope.id}
      order = state.diff_order ++ [key]
      cache = Map.put(state.diff_cache, key, text)
      {cache, order} = trim_diffs(cache, order)
      %{state | diff_cache: cache, diff_order: order}
    else
      _ -> state
    end
  end

  defp warm_diff(state, _ref, _scope), do: state

  defp trim_diffs(cache, [oldest | rest] = order) do
    bytes = cache |> Map.values() |> Enum.map(&byte_size/1) |> Enum.sum()

    if length(order) > @diff_cache_entries or (bytes > @diff_cache_bytes and rest != []),
      do: trim_diffs(Map.delete(cache, oldest), rest),
      else: {cache, order}
  end

  defp trim_diffs(cache, []), do: {cache, []}

  defp cached_diff(state, id, scope) do
    case Map.fetch(state.diff_cache, {id, scope.kind, scope.id}) do
      {:ok, text} -> {:ok, text}
      :error -> :error
    end
  end

  # A checkpoint id (a change) or an op id (an edit): its diff, when it belongs
  # to this conversation (and to the run a run-scoped inspector shows).
  defp diff_text(id, scope, state) do
    conversation = state.opts[:conversation_id]

    with true <- uuid?(id),
         {:ok, run_id, diff} <- change_or_op_diff(conversation, id),
         true <- scope.kind != :run or scope.id == run_id do
      {:ok, diff.text}
    else
      _ -> :error
    end
  end

  defp change_or_op_diff(conversation, id) do
    alias SwarmCode.Domain.FeatureCatalog

    case SwarmCode.Domain.Checkpoints.get(id) do
      %{conversation_id: ^conversation, run_id: run_id} ->
        with {:ok, diff} <- FeatureCatalog.change_diff(conversation, id), do: {:ok, run_id, diff}

      nil ->
        with %{run_id: run_id} <- Conversations.get_node(id),
             {:ok, diff} <- FeatureCatalog.op_diff(conversation, id),
             do: {:ok, run_id, diff}

      _ ->
        :error
    end
  end

  defp detail_ref(id, text),
    do: if(byte_size(text) > 2048, do: %{"id" => id, "total_bytes" => byte_size(text)})

  defp preview(text, max \\ 2048) do
    part = binary_part(text, 0, min(byte_size(text), max))
    utf8_prefix(part)
  end

  defp utf8_prefix(text),
    do:
      if(String.valid?(text),
        do: text,
        else: utf8_prefix(binary_part(text, 0, byte_size(text) - 1))
      )

  defp result(kind, body),
    do: {:ok, %{"op" => "result", "response_kind" => kind, "value" => body}}

  defp accepted(id, ids, feedback \\ nil), do: outcome(id, "accepted", ids, nil, feedback)
  defp reject(id, code), do: outcome(id, "rejected", [], error(code))

  defp outcome(id, status, ids, error, feedback \\ nil),
    do:
      result("outcome", %{
        "status" => status,
        "request_id" => id,
        "identifiers" => ids,
        "interaction" => nil,
        "feedback" => feedback,
        "error" => error,
        "corrective_action" => "none"
      })

  defp navigation_feedback(:rewind), do: navigation_feedback(:checkpoints)

  defp navigation_feedback(feature),
    do: %{
      "kind" => "navigate",
      "feature" => Atom.to_string(feature),
      "title" => "",
      "text" => "",
      "conversation_id" => nil
    }

  defp report_feedback(title, text),
    do: %{
      "kind" => "report",
      "feature" => nil,
      "title" => preview(title, 200),
      "text" => if(text == "", do: " ", else: preview(text, 60_000)),
      "conversation_id" => nil
    }

  defp notice_feedback(mode),
    do: %{
      "kind" => "notice",
      "feature" => nil,
      "title" => "Mode",
      "text" => mode_text(mode),
      "conversation_id" => nil
    }

  defp mode_text(:plan), do: "Plan mode enabled"
  defp mode_text(:build), do: "Build mode enabled"
  defp mode_text(:ultra), do: "Ultra mode enabled"
  defp mode_text(:consensus), do: "Consensus mode enabled"
  defp mode_text(:workflow), do: "Workflow mode enabled"
  defp mode_text(_), do: "Mode updated"

  defp goal_feedback(conversation_id, nil),
    do: %{
      "kind" => "report",
      "feature" => nil,
      "title" => "Conversation goal",
      "text" => "No goal is set for this conversation.",
      "conversation_id" => conversation_id
    }

  defp goal_feedback(conversation_id, goal),
    do: %{
      "kind" => "report",
      "feature" => nil,
      "title" => "Conversation goal",
      "text" => goal_text(goal),
      "conversation_id" => conversation_id
    }

  defp goal_text(goal),
    do:
      "Status: " <>
        to_string(goal.status) <>
        "\nMode: " <> to_string(goal.mode) <> "\n\n" <> preview(to_string(goal.text), 60_000)

  defp error(code),
    do: %{
      "code" => Atom.to_string(code),
      "message" => Map.get(@errors, code, "domain command could not be completed")
    }

  defp wire_error(code), do: {:error, Map.put(error(code), "op", "error")}
end
