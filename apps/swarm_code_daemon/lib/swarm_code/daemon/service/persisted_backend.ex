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
         {:ok, root} <- SwarmCode.Tools.Path.real_path(opts[:project_root]),
         {:ok, ^root} <- SwarmCode.Tools.Path.real_path(project_root),
         true <- File.dir?(root) do
      :ok = CommandLedger.ensure!()

      staged_attachments =
        CommandLedger.staged_attachments(opts[:project_id], opts[:conversation_id])

      Events.subscribe(opts[:conversation_id])
      Events.ui_subscribe()

      state = %{
        opts: Keyword.put(opts, :project_root, root),
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
        streams: %{}
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
          if Map.get(request, :operation) in [:query, :detail, :feature_query],
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
       ] and not state.refresh_pending do
      Process.send_after(self(), :refresh_projection, 20)
      {:noreply, %{state | refresh_pending: true}}
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
    command? = Map.get(request, :operation) not in [:query, :detail, :feature_query]

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
        durable = command? and request.operation not in [:conversation_open]

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

  defp execute(%{operation: operation} = request, scope, id, state)
       when operation in [:feature_query, :feature_command] do
    scoped = feature_scope(scope, state)
    {SwarmCode.Daemon.Service.FeatureRequest.execute(request, scoped, id, state.revision), state}
  end

  defp execute(%{operation: :detail, params: params}, scope, id, state) do
    next = refresh(state)
    {result("detail_window", detail(params, scope, id, next)), next}
  end

  defp execute(%{operation: :conversation_open, params: params}, _scope, id, state) do
    if params["conversation_id"] in [nil, state.opts[:conversation_id]],
      do: {accepted(id, [state.opts[:conversation_id]]), state},
      else: {reject(id, :not_allowed), state}
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

      params["node_id"] != nil and params["node_id"] not in run.node_ids ->
        {reject(id, :not_allowed), state}

      operation == :approval_resolve and
          (is_nil(run.approval) or run.approval["id"] != params["interaction_id"] or
             run.approval["node_id"] != params["node_id"] or
             run.approval["expected_revision"] != params["expected_revision"]) ->
        {reject(id, :stale_revision), state}

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

  defp control(:approval_resolve, params, run, _),
    do:
      Engine.resolve_approval(
        run.id,
        run.approval["node_id"],
        if(params["decision"] == "approve", do: :approve, else: :deny)
      )

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

  defp agent_summary(n),
    do: %{
      "id" => n.id,
      "run_id" => n.run_id,
      "revision" => stamp(n.updated_at),
      "state" => normalize_node_status(n.status),
      "allowed_actions" => [],
      "launched_by_superseded" => false
    }

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
    pending = Questions.list(state.opts[:conversation_id]) |> Enum.take(200)
    grouped_records = Enum.group_by(records, & &1.run_id)
    grouped_agents = Enum.group_by(agents, & &1.run_id)

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
          agents: Enum.map(ns, &agent_summary/1),
          node_ids: Enum.map(ns, & &1.id),
          approval: nil,
          interactions: []
        }

        rs =
          Enum.map(rs, fn r ->
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
              attachments: Map.get(r, :attachments, [])
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

    %{
      state
      | runs: runs,
        order: Enum.map(rows, & &1.id),
        streams: Map.take(state.streams, live_messages),
        revision: revision,
        metadata: metadata
    }
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
            | "approval" => %{
                "tool" => detail[:tool] || "agent operation",
                "permission" => Atom.to_string(detail[:permission] || :write),
                "arguments_preview" => to_string(detail[:args] || "{}"),
                "arguments_detail_ref" => nil
              },
              "allowed_actions" => ["approve", "deny"]
          }
        ]

      p.kind == :question ->
        SwarmCode.Daemon.Service.QuestionProjection.rows(base, detail[:questions] || [])

      true ->
        []
    end
  end

  defp publish_changes(old, state) do
    state = if old.metadata != state.metadata, do: broadcast_metadata(state), else: state

    Enum.reduce(state.order, state, fn id, acc ->
      run = acc.runs[id]
      previous = old.runs[id]

      if previous == run do
        acc
      else
        acc = broadcast(acc, delta("run_update", run, run.id, summary(run, acc)))

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
    do: %{
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
      "progress" => nil
    }

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
            "shell" -> delta["kind"] == "run_update"
            "activity" -> delta["kind"] == "activity_upsert"
            "workspace" -> delta["kind"] != "activity_upsert"
            _ -> delta["kind"] not in ["activity_upsert", "workspace_metadata"]
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
                "interactions" => Enum.take(pending, limit)
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
    %{
      "conversation_id" => conversation.id,
      "mode" => workspace_mode(conversation),
      "chat_model" => effective_model_name(conversation, :chat),
      "swarm_model" => effective_model_name(conversation, :swarm),
      "effort" => conversation.effort,
      "swarm_effort" => conversation.swarm_effort
    }
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
