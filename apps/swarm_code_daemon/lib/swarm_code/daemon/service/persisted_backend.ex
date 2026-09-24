defmodule SwarmCode.Daemon.Service.PersistedBackend do
  @moduledoc """
  Typed service over an already admitted, running Domain Repo. This module never
  starts storage or opens a database pathname. Engine runs outlive this view;
  reconnect rebuilds projections from persisted messages, runs and nodes.

  Commands reserve a durable CLI metadata identity before execution. Completed
  outcomes replay after restart; unfinished reservations return outcome_unknown.
  The in-memory response cache is capped at 4096 identities.

  Slow reads (pass71 S2): feature queries (the `@path` file index, the Git tree
  of Changes, the libraries) and diffs not yet cached run as supervised,
  monitored jobs (`Task.Supervisor.async_nolink` under
  `SwarmCode.Domain.TaskSupervisor`), correlated by task reference. The caller's
  reply is deferred until its job ends, so a slow walk or Git call never stalls
  other requests. A newer `@path` query replaces an older one (answered
  `stale_revision`); a conversation switch cancels every job (`not_allowed`);
  a job past its request's `timeout_ms` is killed (`source_unavailable`); and
  so is every job when the service stops. At most 8 jobs run at once.
  """
  use GenServer
  alias SwarmCode.Domain.{Attachments, Conversations, Engine, Projects, Repo}
  alias SwarmCode.Protocol.ServiceRequest
  alias SwarmCode.Domain.Engine.{Events, Questions, RunServer}
  @max_models 400
  # pass70 C8: finished-run checkpoints whose change facts a reload computes.
  @facts_per_reload 50
  # Operations that read: never ledgered, answered with a typed error.
  @reads [:query, :detail, :feature_query, :conversation_list, :agent_detail]
  # pass71 S2: slow reads run as jobs; this many at once, the rest are refused.
  @max_jobs 8
  @terminal [:completed, :failed, :cancelled, :interrupted]
  alias SwarmCode.Daemon.Service.PanelFacts

  alias SwarmCode.Daemon.Service.{
    CommandDispatcher,
    CommandLedger,
    PersistedProjection,
    SessionConfiguration
  }

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
      # pass71 S2: `terminate/2` must run on a supervisor shutdown so it can
      # kill the running jobs and settle their callers.
      Process.flag(:trap_exit, true)

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
        # pass71 S6: what the armed refresh has to do — a full reload, or only
        # the runs and nodes a streaming tick touched — the inputs of the last
        # projection (the rows the targeted refetch replaces), and how many
        # projections of each kind ran.
        full_pending: false,
        partial: nil,
        inputs: nil,
        projections: %{full: 0, partial: 0},
        repo_monitor: Process.monitor(Process.whereis(Repo)),
        streams: %{},
        changes: %{},
        verdicts: %{},
        # pass70 C5: the waits already told about (so a toast fires once per
        # new wait elsewhere), the providers' last rate-limit windows, and the
        # MCP servers that failed (so their recovery is told too).
        waiting_seen: MapSet.new(Questions.list(), & &1.conversation_id),
        # pass70 D3: the first-run onboarding sentence the launcher passes in,
        # told once as a toast when the shell watch is ready.
        first_run_notice: first_run_notice(opts[:first_run_notice]),
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
        # pass71 S2: finished-run checkpoints still without facts, the job
        # computing some of them, and the ones whose diff failed (not retried).
        facts_missing: [],
        facts_job: nil,
        facts_failed: MapSet.new(),
        file_index: nil,
        # pass70 Q3: monitors on this conversation's running chat runs while
        # prompts are queued behind them (monitor ref => true).
        queue_monitors: %{},
        queue_retries: 0,
        # pass71 S2: running read jobs (task ref => job), where they run, and
        # the functions that do the slow work (tests inject blocking fakes).
        jobs: %{},
        task_supervisor: Keyword.get(opts, :task_supervisor, SwarmCode.Domain.TaskSupervisor),
        work: work(opts[:work])
      }

      {:ok, reload(state)}
    else
      _ -> :ignore
    end
  rescue
    _ -> :ignore
  end

  @impl true
  def handle_call({:service_request, id, scope, request}, from, state) do
    with {:ok, _} <- ServiceRequest.encode(request, scope), true <- member?(state, scope) do
      admit_request(id, scope, request, from, state)
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
      nil ->
        {:noreply, state}

      entry ->
        state = flush(put_in(state.watches[key], %{entry | ready: true}), key)
        {:noreply, first_run_toast(state, entry.slot)}
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

  # pass70 Q3: the chat turn a queued prompt waits behind has ended.
  def handle_info({:DOWN, monitor, :process, _, _}, %{queue_monitors: monitors} = state)
      when is_map_key(monitors, monitor),
      do: {:noreply, drain_queue(%{state | queue_monitors: Map.delete(monitors, monitor)})}

  # pass71 F8: a retry of a queued prompt whose start was refused.
  def handle_info({:drain_queue, conversation_id}, state) do
    if conversation_id == state.opts[:conversation_id],
      do: {:noreply, drain_queue(state)},
      else: {:noreply, state}
  end

  # pass71 S2: a job crashed or was killed without answering.
  def handle_info({:DOWN, ref, :process, _, _}, %{jobs: jobs} = state)
      when is_map_key(jobs, ref),
      do: {:noreply, settle_job(state, ref, wire_error(:source_unavailable))}

  def handle_info({:DOWN, ref, :process, _, _}, %{facts_job: %{ref: ref, ids: ids}} = state),
    do: {:noreply, facts_done(state, Map.new(ids, &{&1, nil}))}

  def handle_info({:DOWN, monitor, :process, _, _}, state) do
    {:noreply,
     Enum.reduce(state.watches, state, fn {key, entry}, acc ->
       if entry.monitor == monitor, do: unwatch(acc, key), else: acc
     end)}
  end

  # pass71 S2: the facts job of this conversation finished (a stale one was
  # cancelled and its reference forgotten, so its result falls through).
  def handle_info({ref, {conversation, results}}, %{facts_job: %{ref: ref}} = state)
      when is_map(results) do
    Process.demonitor(ref, [:flush])

    if conversation == state.opts[:conversation_id],
      do: {:noreply, facts_done(state, results)},
      else: {:noreply, %{state | facts_job: nil}}
  end

  # pass71 S2: a job's result, correlated by its task reference.
  def handle_info({ref, result}, %{jobs: jobs} = state)
      when is_reference(ref) and is_map_key(jobs, ref) do
    Process.demonitor(ref, [:flush])
    job = jobs[ref]
    {response, next} = job.finish.(result, %{state | jobs: Map.delete(jobs, ref)})
    cancel_job_timer(job)
    GenServer.reply(job.from, response)
    {:noreply, next}
  end

  def handle_info({:job_timeout, ref}, %{jobs: jobs} = state) when is_map_key(jobs, ref),
    do: {:noreply, cancel_job(state, ref, wire_error(:source_unavailable))}

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

  # pass71 S6: a streaming tick refetches only what it touched; anything
  # else (or a refresh nobody armed) reloads the whole projection.
  def handle_info(:refresh_projection, state) do
    cleared = %{state | refresh_pending: false, full_pending: false, partial: nil}

    next =
      if state.full_pending or state.partial == nil,
        do: reload(cleared),
        else: partial_reload(cleared, state.partial)

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

  # pass71 S6 (C9): a streaming tick (`Node.patch_cols/0`: status while
  # running, progress, detail, tokens, cost, turn) and the run totals written
  # in the same flush refresh only the rows they name.
  def handle_info({:nodes_patch, run_id, patches}, state)
      when is_binary(run_id) and is_list(patches) do
    ids = for {id, cols} <- patches, is_binary(id) and is_map(cols), do: id
    {:noreply, schedule_partial(state, [run_id], ids)}
  end

  # Only a totals tick (the counters moved, nothing a card keys off did) is
  # partial; any other run update, or one that changed nothing we hold, is a
  # signal to reload everything.
  def handle_info({:run_updated, %{id: run_id} = run}, state) when is_binary(run_id) do
    if totals_tick?(run, state),
      do: {:noreply, schedule_partial(state, [run_id], [])},
      else: {:noreply, schedule_refresh(state)}
  end

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
  def terminate(_, state) do
    cancel_jobs(state, wire_error(:source_unavailable))
    cancel_facts_job(state.facts_job, state.task_supervisor)
    Events.unsubscribe(state.opts[:conversation_id])
  end

  @impl true
  def format_status(status),
    do: %{status | state: %{mode: :persisted, runs: map_size(status.state.runs)}}

  defp admit_request(id, scope, request, from, state) do
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

            case response do
              # pass71 S2: a read whose work runs as a job answers later.
              {:job, job} when not command? ->
                start_job(next, from, job, request.timeout_ms)

              response ->
                if durable, do: CommandLedger.complete(state.opts[:project_id], id, response)

                next =
                  if command?, do: put_in(next.requests[id], {fingerprint, response}), else: next

                {:reply, response, next}
            end
        end
    end
  end

  # pass70 Q3: Tab (or Alt-Enter, or /queue) while a turn runs puts the prompt
  # on the conversation's queue, the desktop's own `conversations.queued`; it
  # starts when the running chat turn ends. With no chat turn running it is an
  # ordinary send. A slash command or an attachment is never queued.
  defp execute(
         %{operation: :dispatch_send, params: %{"action" => "queue"} = params},
         scope,
         id,
         state
       ) do
    conversation_id = state.opts[:conversation_id]
    text = params["text"]

    cond do
      String.starts_with?(String.trim_leading(text), "/") or params["attachment_refs"] != [] or
          state.attachment_ids != [] ->
        {reject(id, :not_allowed), state}

      not Engine.chat_running?(conversation_id) ->
        execute(
          %{operation: :dispatch_send, params: %{params | "action" => "send"}},
          scope,
          id,
          state
        )

      true ->
        conversation = Conversations.get!(conversation_id)

        case Conversations.set_queued(conversation, (conversation.queued || []) ++ [text]) do
          {:ok, updated} ->
            count = length(updated.queued)

            text =
              if count == 1,
                do: "Queued; it starts when this turn ends.",
                else: "Queued; #{count} prompts wait for this turn to end."

            {accepted(id, [conversation_id], %{
               "kind" => "notice",
               "feature" => nil,
               "title" => "Queue",
               "text" => text,
               "conversation_id" => nil
             }), watch_queue(state)}

          _ ->
            {reject(id, :not_allowed), state}
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
            SessionConfiguration.overlay(Conversations.get!(state.opts[:conversation_id])),
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
    # pass71 S2: the walk and the ranking run as a job; a newer query
    # replaces an older one still running.
    index = fresh_file_index(state)
    root = state.opts[:project_root]
    walk = state.work.file_index

    work = fn ->
      paths = index || walk.(root)
      walked = if index, do: nil, else: paths
      {walked, SwarmCode.Domain.FeatureCatalog.file_matches(paths, p["id"], p["page_size"])}
    end

    finish = fn {walked, items}, state ->
      state = if walked, do: put_file_index(state, walked), else: state
      files_page(items, p, id, state)
    end

    {{:job, %{key: :files, replace: true, work: work, finish: finish}}, state}
  end

  # pass71 S2: a feature query reads the Repo, files and Git (Changes in the
  # project scope lists the working tree): a job. Mutations stay in order here.
  defp execute(%{operation: :feature_query} = request, scope, id, state) do
    scoped = feature_scope(scope, state)
    revision = state.revision
    run = state.work.feature_query
    work = fn -> run.(request, scoped, id, revision) end
    {{:job, %{key: nil, replace: false, work: work, finish: &{&1, &2}}}, state}
  end

  defp execute(%{operation: :feature_command} = request, scope, id, state) do
    scoped = feature_scope(scope, state)
    {SwarmCode.Daemon.Service.FeatureRequest.execute(request, scoped, id, state.revision), state}
  end

  # pass72 S: one agent's detail for the overlay. The rows are read by a job
  # (never in this callback); the pending interactions are this projection's.
  defp execute(%{operation: :agent_detail, params: params}, scope, id, state) do
    # A run this service has not projected yet (no watch so far): project once.
    state = if Map.has_key?(state.runs, params["run_id"]), do: state, else: refresh(state)
    run = state.runs[params["run_id"]]

    if run && run_member?(run, scope, state) do
      conversation = state.opts[:conversation_id]
      node_id = params["node_id"]
      interactions = run.interactions
      model = state.agent_models[node_id] || run.model
      roots = Map.get(state, :roots, [])

      work = fn ->
        case PersistedProjection.agent_detail(conversation, run.id, node_id) do
          {:ok, rows} ->
            ops = MapSet.new(rows.ops, & &1.id)

            mine =
              Enum.filter(interactions, fn i ->
                get_in(i, ["approval", "agent_id"]) == node_id or i["node_id"] == node_id or
                  MapSet.member?(ops, i["node_id"])
              end)

            window =
              if is_binary(model),
                do:
                  SwarmCode.Domain.Engine.Context.budget(
                    model,
                    SwarmCode.Domain.Settings.get_cached()
                  )

            body =
              SwarmCode.Daemon.Service.AgentDetail.build(rows,
                request_id: id,
                roots: roots,
                interactions: mine,
                model: model,
                context_window: if(is_integer(window) and window > 0, do: window)
              )

            result("agent_detail", body)

          :error ->
            wire_error(:not_allowed)
        end
      end

      {{:job, %{key: nil, replace: false, work: work, finish: &{&1, &2}}}, state}
    else
      {wire_error(:not_allowed), state}
    end
  end

  defp execute(%{operation: :detail, params: params}, scope, id, state) do
    next = refresh(state)

    case uncached_diff(next, params["detail_ref"], scope) do
      # pass71 S2: a diff not in the cache is computed by a job, then paged
      # from the cache like any other.
      {:ok, diff_id} ->
        conversation = next.opts[:conversation_id]
        diff = next.work.diff

        work = fn -> bounded_diff(diff_text(diff_id, scope, conversation, diff)) end

        finish = fn
          {:ok, text}, state ->
            state = cache_diff(state, {diff_id, scope.kind, scope.id}, text)
            {result("detail_window", detail(params, scope, id, state)), state}

          {:error, :too_large}, state ->
            window =
              params
              |> detail(scope, id, state)
              |> Map.put("error", error(:capacity_exceeded))

            {result("detail_window", window), state}

          _, state ->
            {result("detail_window", detail(params, scope, id, state)), state}
        end

        {{:job, %{key: nil, replace: false, work: work, finish: finish}}, next}

      :cached ->
        {result("detail_window", detail(params, scope, id, next)), next}
    end
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

  # The pids of this conversation's running chat runs, each monitored once.
  defp watch_queue(state) do
    conversation_id = state.opts[:conversation_id]

    pids =
      Registry.select(SwarmCode.Domain.Registry, [
        {{{:run, :_}, :"$1", {:"$2", :"$3"}},
         [{:==, :"$2", conversation_id}, {:==, :"$3", "chat"}], [:"$1"]}
      ])

    monitors =
      Enum.reduce(pids, state.queue_monitors, fn pid, acc ->
        if Enum.any?(acc, fn {_ref, watched} -> watched == pid end),
          do: acc,
          else: Map.put(acc, Process.monitor(pid), pid)
      end)

    %{state | queue_monitors: monitors}
  end

  # Takes the queue's head (the desktop's IMMEDIATE pop, so a desktop window
  # on the same conversation cannot start it twice) and starts it as a chat
  # turn; still running, it waits for the next turn to end.
  defp drain_queue(state) do
    conversation_id = state.opts[:conversation_id]

    cond do
      Engine.chat_running?(conversation_id) ->
        watch_queue(state)

      true ->
        case Conversations.pop_queued(conversation_id) do
          {:ok, text, conversation} ->
            case Engine.start_chat_turn(SessionConfiguration.overlay(conversation), text, []) do
              {:ok, _} ->
                refresh(%{state | queue_retries: 0})

              {:error, _} ->
                Conversations.set_queued(conversation, [text | conversation.queued || []])
                retry_queue(state)
            end

          {:error, _busy} ->
            retry_queue(state)

          _empty ->
            state
        end
    end
  end

  # pass71 F8: a start refused by a passing condition (a busy database under
  # load, the engine still tearing down the turn before) put the prompt back
  # and armed nothing, so it waited for ever; it is retried a few times first.
  @queue_retry_ms 250
  @queue_retries 8

  defp retry_queue(%{queue_retries: n} = state) when n < @queue_retries do
    Process.send_after(self(), {:drain_queue, state.opts[:conversation_id]}, @queue_retry_ms)
    %{state | queue_retries: n + 1}
  end

  defp retry_queue(state) do
    toast(
      %{state | queue_retries: 0},
      "error",
      "Queue",
      "The queued prompt could not start.",
      nil
    )
  end

  defp switch_conversation(state, id) do
    if id == state.opts[:conversation_id] do
      state
    else
      Enum.each(state.queue_monitors, fn {ref, _pid} -> Process.demonitor(ref, [:flush]) end)
      # pass71 S2: reads of the old conversation are answered as queries
      # against it are now: not allowed.
      state = %{cancel_jobs(state, wire_error(:not_allowed)) | queue_monitors: %{}}
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
          full_pending: false,
          partial: nil,
          inputs: nil,
          diff_cache: %{},
          diff_order: [],
          change_facts: %{},
          facts_missing: [],
          facts_job: cancel_facts_job(state.facts_job, state.task_supervisor),
          facts_failed: MapSet.new()
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

  defp first_run_notice(text) when is_binary(text) and text != "", do: preview(text, 1024)
  defp first_run_notice(_), do: nil

  defp first_run_toast(%{first_run_notice: text} = state, "shell") when is_binary(text),
    do: toast(%{state | first_run_notice: nil}, "info", "First run", text, nil)

  defp first_run_toast(state, _slot), do: state

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

  defp schedule_refresh(state), do: arm_refresh(%{state | full_pending: true, partial: nil})

  # pass71 S6: a partial refresh accumulates the runs and nodes of the ticks
  # coalesced into it; a pending full reload already covers them.
  defp schedule_partial(%{full_pending: true} = state, _runs, _nodes), do: arm_refresh(state)

  defp schedule_partial(state, runs, nodes) do
    partial = state.partial || %{runs: MapSet.new(), nodes: MapSet.new()}

    arm_refresh(%{
      state
      | partial: %{
          runs: MapSet.union(partial.runs, MapSet.new(runs)),
          nodes: MapSet.union(partial.nodes, MapSet.new(nodes))
        }
    })
  end

  defp arm_refresh(%{refresh_pending: true} = state), do: state

  defp arm_refresh(state) do
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
      "hunk" => diff && Map.get(diff, :hunk),
      "diff_lines" => (diff && Map.get(diff, :diff_lines)) || 0,
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
  # says it changed (counts, file state, the diff's size), kept for the
  # checkpoints shown. pass71 S2: the diffs are computed by a facts job, never
  # here; this returns what is known and the checkpoints still missing.
  defp change_facts(cache, checkpoints, terminal, failed) do
    finished = MapSet.new(terminal)
    shown = Enum.filter(checkpoints, &MapSet.member?(finished, &1.run_id))

    Enum.reduce(shown, {%{}, []}, fn c, {acc, missing} ->
      case Map.fetch(cache, c.id) do
        {:ok, facts} -> {Map.put(acc, c.id, facts), missing}
        :error -> {acc, if(MapSet.member?(failed, c.id), do: missing, else: [c.id | missing])}
      end
    end)
    |> then(fn {facts, missing} -> {facts, Enum.reverse(missing)} end)
  end

  # pass71 S2: at most `@facts_per_reload` missing facts per job, one job at a
  # time; its result lands through `handle_info/2` and refreshes the projection.
  defp start_facts_job(%{facts_job: nil, facts_missing: [_ | _]} = state) do
    ids = Enum.take(state.facts_missing, @facts_per_reload)
    conversation = state.opts[:conversation_id]
    diff = state.work.change_diff

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        {conversation,
         Map.new(ids, fn id ->
           case diff.(conversation, id) do
             {:ok, diff} ->
               {id,
                Map.merge(
                  %{
                    added: diff.added,
                    removed: diff.removed,
                    file_state: diff.file_state,
                    total: byte_size(diff.text)
                  },
                  diff_summary(diff.text)
                )}

             _ ->
               {id, nil}
           end
         end)}
      end)

    %{state | facts_job: %{ref: task.ref, pid: task.pid, ids: ids}}
  end

  defp start_facts_job(state), do: state

  defp facts_done(state, results) do
    {known, failed} = Enum.split_with(results, fn {_, facts} -> facts != nil end)

    %{
      state
      | facts_job: nil,
        change_facts: Map.merge(state.change_facts, Map.new(known)),
        facts_failed: Enum.reduce(failed, state.facts_failed, &MapSet.put(&2, elem(&1, 0)))
    }
    |> schedule_refresh()
  end

  defp cancel_facts_job(nil, _supervisor), do: nil

  defp cancel_facts_job(%{ref: ref, pid: pid}, supervisor) do
    Process.demonitor(ref, [:flush])
    Task.Supervisor.terminate_child(supervisor, pid)
    Process.exit(pid, :kill)
    nil
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
             total: Enum.sum(Enum.map(known, & &1.total)) + length(known) - 1,
             # pass71 F5: the edit's first hunk, and the body lines of all of it.
             hunk: Enum.find_value(known, &Map.get(&1, :hunk)),
             diff_lines: Enum.sum(Enum.map(known, &Map.get(&1, :diff_lines, 0)))
           }}
        ]
      else
        []
      end
    end)
    |> Map.new()
  end

  # pass71 F5 (V's request S-1): what an edit row shows in place, its first
  # hunk (the `@@` line and at most 12 lines, 4 KB), and the body lines of the
  # whole diff (from the first `@@`, file headers excluded) for its count.
  @hunk_lines 13
  @hunk_bytes 4096

  @doc false
  def diff_summary(text) when is_binary(text) do
    lines =
      text
      |> String.trim_trailing("\n")
      |> String.split(["\r\n", "\n"])
      |> Enum.reject(
        &(String.starts_with?(&1, "--- ") or String.starts_with?(&1, "+++ ") or
            String.starts_with?(&1, "diff --git ") or String.starts_with?(&1, "index "))
      )
      |> Enum.drop_while(&(not String.starts_with?(&1, "@@")))

    hunk =
      case lines do
        [head | body] ->
          [head | Enum.take_while(body, &(not String.starts_with?(&1, "@@")))]
          |> Enum.take(@hunk_lines)
          |> Enum.join("\n")
          |> preview(@hunk_bytes)

        [] ->
          nil
      end

    %{hunk: hunk, diff_lines: length(lines)}
  end

  def diff_summary(_), do: %{hunk: nil, diff_lines: 0}

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

    state
    |> build_projection(rows, records, agents, :reload)
    |> count_projection(:full)
    |> start_facts_job()
  end

  # pass71 S6 (C9): the runs and nodes a streaming tick named are refetched
  # and replace their rows in the last projection's inputs; the rest (running
  # ops, checkpoints, their counts) is reused, then projected as a reload
  # would. It falls back to a full reload when a row is gone, is not in the
  # projection, or changed anything a tick cannot carry: then the change was
  # structural and its own event is on its way. Golden-tested against a reload.
  @run_tick_keys [:tokens_in, :tokens_out, :cost_usd, :model, :updated_at]
  @agent_tick_keys [:status, :progress, :tokens_in, :tokens_out, :cost_usd, :updated_at]
  @record_tick_keys [:status, :text, :text_bytes, :detail, :tokens_in, :tokens_out, :updated_at]

  defp partial_reload(%{inputs: nil} = state, _partial), do: reload(state)

  defp partial_reload(%{inputs: inputs} = state, %{runs: runs, nodes: nodes}) do
    conv = state.opts[:conversation_id]
    run_ids = MapSet.to_list(runs)
    agent_ids = for a <- inputs.agents, MapSet.member?(nodes, a.id), do: a.id
    record_ids = for r <- inputs.records, MapSet.member?(nodes, r.id), do: r.id

    with true <- Enum.all?(run_ids, fn id -> Enum.any?(inputs.rows, &(&1.id == id)) end),
         {:ok, rows, _, _} <-
           PersistedProjection.runs(conv, %{kind: :runs, ids: run_ids}, nil, "before", 201),
         {:ok, rows} <- tick_rows(inputs.rows, rows, @run_tick_keys, length(run_ids)),
         {:ok, agents} <-
           tick_rows(
             inputs.agents,
             PersistedProjection.agents_by_ids(conv, agent_ids),
             @agent_tick_keys,
             length(agent_ids)
           ),
         {:ok, records} <-
           tick_rows(
             inputs.records,
             PersistedProjection.records_by_ids(conv, record_ids),
             @record_tick_keys,
             length(record_ids)
           ) do
      state
      |> build_projection(rows, records, agents, {:partial, inputs})
      |> count_projection(:partial)
      |> start_facts_job()
    else
      _ -> reload(state)
    end
  end

  # `fresh` (the `expected` rows asked for, all still there) replaces the rows
  # of `cached` with its ids, in place, when each differs only in `keys`.
  defp tick_rows(_cached, fresh, _keys, expected) when length(fresh) != expected, do: :error

  defp tick_rows(cached, fresh, keys, _expected) do
    by_id = Map.new(fresh, &{&1.id, &1})

    matched =
      Enum.count(cached, fn row ->
        case by_id[row.id] do
          nil -> false
          new -> Map.drop(new, keys) == Map.drop(row, keys)
        end
      end)

    if matched == map_size(by_id),
      do: {:ok, Enum.map(cached, &Map.get(by_id, &1.id, &1))},
      else: :error
  end

  defp totals_tick?(run, %{inputs: %{rows: rows}}) do
    case Enum.find(rows, &(&1.id == run.id)) do
      nil ->
        false

      row ->
        Enum.all?(
          [:status, :finished_at, :error_kind, :root_node_id, :kind],
          &(Map.get(run, &1) == Map.get(row, &1))
        ) and Enum.any?([:tokens_in, :tokens_out, :cost_usd], &(Map.get(run, &1) != row[&1]))
    end
  end

  defp totals_tick?(_run, _state), do: false

  defp count_projection(state, kind),
    do: %{state | projections: Map.update!(state.projections, kind, &(&1 + 1))}

  # `mode`: `:reload` and `{:partial, inputs}` are the service's own
  # projection (they record which facts are missing, for the facts job, and
  # keep their inputs); `:page` is a query's page, which reuses what it has.
  defp build_projection(state, rows, records, agents, mode \\ :page) do
    conv = state.opts[:conversation_id]
    ids = Enum.map(rows, & &1.id)
    pending = Questions.list(conv) |> Enum.take(200)
    grouped_records = Enum.group_by(records, & &1.run_id)
    grouped_agents = Enum.group_by(agents, & &1.run_id)

    {ops, checkpoints, checkpoint_counts} =
      case mode do
        {:partial, inputs} ->
          {inputs.ops, inputs.checkpoints, inputs.checkpoint_counts}

        _ ->
          {PersistedProjection.running_ops(conv, ids), PersistedProjection.checkpoints(conv, ids),
           PersistedProjection.checkpoint_counts(conv, ids)}
      end

    reload? = mode != :page

    terminal =
      for row <- rows, row.status in ["done", "stopped", "failed", "interrupted"], do: row.id

    {facts, missing} = change_facts(state.change_facts, checkpoints, terminal, state.facts_failed)

    state =
      if reload?,
        do: %{state | change_facts: facts, facts_missing: missing},
        else: %{state | change_facts: facts}

    op_facts = op_diff_facts(checkpoints, facts)
    panel = panel_inputs(state, rows)

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
          stop: stop_facts(row.status, Map.get(row, :error_kind)),
          panel: %{}
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

        run = panel_run(run, row, ns, interactions, panel, state)
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
        background: background,
        inputs:
          if(reload?,
            do: %{
              rows: rows,
              records: records,
              agents: agents,
              ops: ops,
              checkpoints: checkpoints,
              checkpoint_counts: checkpoint_counts
            },
            else: state.inputs
          )
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

  # pass71 F1 (review R1): a reply or prompt travels whole up to
  # `@reply_bytes` (the projection reads that much); a tool's output keeps the
  # 2 KB preview and opens through its detail. A snapshot that would not fit
  # its byte limit falls back to 2 KB for every item (`snapshot/5`).
  @reply_bytes 8192

  defp transcript(run, state, bound \\ @reply_bytes),
    do:
      Enum.map(run.records, fn row ->
        text_bound = if row.role in ["user", "assistant"], do: bound, else: 2048

        node(run, state, row.id, row.role, row.text, row.reasoning, row.status, row.revision)
        |> Map.put("text", preview(row.text, text_bound))
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
          if(row.text_bytes > byte_size(preview(row.text, text_bound)),
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

  # pass72 S: what the side panel reads beside the rows: the clock, the live
  # runs' recent and open operations (lanes, sentences, whose op waits), the
  # files each agent wrote, workflow phases and goal iterations.
  defp panel_inputs(state, rows) do
    conv = state.opts[:conversation_id]
    ids = Enum.map(rows, & &1.id)

    live =
      for row <- rows, row.status not in ["done", "stopped", "failed", "interrupted"], do: row.id

    ops = PersistedProjection.panel_ops(conv, live)
    workflows = for row <- rows, row.kind == "workflow", do: row.id

    %{
      ops: Enum.group_by(ops, & &1.parent_id),
      parents: Map.new(ops, &{&1.id, &1.parent_id}),
      files: PersistedProjection.files_changed(conv, ids),
      workflows: PersistedProjection.workflow_phases(workflows),
      goals: PersistedProjection.goal_facts(rows)
    }
  end

  # The agents' panel facts (merged into their wire bodies) and the run's.
  defp panel_run(run, row, ns, interactions, panel, state) do
    owner = fn i ->
      get_in(i, ["approval", "agent_id"]) || panel.parents[i["node_id"]] || i["node_id"]
    end

    waiting = Enum.group_by(interactions, owner)
    # Any agent's result may cite a sibling's worktree: strip them all.
    roots = Enum.map(ns, & &1.workspace_path) ++ Map.get(state, :roots, [])

    agents =
      Enum.zip_with(ns, run.agents, fn n, body ->
        Map.merge(
          body,
          PanelFacts.agent(n, Map.get(panel.ops, n.id, []),
            interactions: Map.get(waiting, n.id, []),
            files_changed: Map.get(panel.files, n.id, 0),
            roots: roots
          )
        )
      end)

    subs = Enum.filter(ns, &(is_binary(&1.parent_id) and &1.id != row.root_node_id))
    judges = Enum.filter(ns, &match?("Judge" <> _, &1.name || ""))
    goal = panel.goals[row.id]

    verdict =
      judges
      |> Enum.flat_map(&List.wrap(verdict_body(&1)))
      |> Enum.max_by(& &1["round"], fn -> nil end)

    facts = %{
      "needs_you" =>
        PanelFacts.needs_you(interactions, Map.new(agents, &{&1["id"], &1}), panel.parents, roots),
      "reported" => Enum.count(subs, &(&1.status in ["done", "failed", "stopped"])),
      "total" => length(subs),
      "phases" => PanelFacts.phases(panel.workflows[row.id] || %{}, ns, row.status),
      "phase" => panel.workflows[row.id] && clip(panel.workflows[row.id].phase, 120),
      "goal_iteration" => goal && goal.iteration,
      "goal_iterations" => goal && goal.iterations,
      "goal_status" => goal && clip(goal.status, 32),
      "round" => if(row.consensus == true, do: length(judges)),
      "rounds" => if(row.consensus == true, do: positive(Map.get(row, :consensus_rounds))),
      "verdict" => verdict && blank_nil(verdict["summary"])
    }

    %{run | agents: agents, panel: facts}
  end

  defp positive(n) when is_integer(n) and n > 0, do: n
  defp positive(_), do: nil

  defp blank_nil(""), do: nil
  defp blank_nil(text), do: text

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
      |> Map.merge(Map.get(run, :panel, %{}))

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
    case snapshot(params, scope, request_id, state, @reply_bytes) do
      {:error, :capacity_exceeded} -> snapshot(params, scope, request_id, state, 2048)
      other -> other
    end
  end

  defp snapshot(params, scope, request_id, state, bound) do
    with {:ok, state, before, after_cursor} <- query_projection(params, scope, state) do
      runs =
        state.order |> Enum.map(&state.runs[&1]) |> Enum.filter(&run_member?(&1, scope, state))

      limit = params["page_size"]

      items =
        Enum.flat_map(runs, &transcript(&1, state, bound))
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
                "allowed_actions" => ["send", "queue"],
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
    # The status line names the model this session runs (a `--model` override).
    conversation = SessionConfiguration.overlay(conversation)
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
      "title" => if(is_binary(conversation.title), do: preview(conversation.title, 256)),
      # pass71 S5: the prompts waiting behind the live turn (`conversations.queued`).
      "queued" => length(conversation.queued || [])
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

  defp files_page(items, p, id, state) do
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

  @file_index_ms 30_000

  defp fresh_file_index(%{file_index: {at, paths}}) when is_list(paths) do
    if System.monotonic_time(:millisecond) - at < @file_index_ms, do: paths
  end

  defp fresh_file_index(_state), do: nil

  defp put_file_index(state, paths),
    do: %{state | file_index: {System.monotonic_time(:millisecond), paths}}

  # A diff is computed once and paged from memory: at most 8 of them and
  # 4 MB, the oldest dropped first (and computed again when asked again).
  @diff_cache_entries 8
  @diff_cache_bytes 4_000_000

  defp uncached_diff(state, ref, scope) when is_binary(ref) do
    case String.split(ref, ":", parts: 2) do
      [id, "diff"] ->
        if Map.has_key?(state.diff_cache, {id, scope.kind, scope.id}),
          do: :cached,
          else: {:ok, id}

      _ ->
        :cached
    end
  end

  defp uncached_diff(_state, _ref, _scope), do: :cached

  # One diff never takes more than the whole cache: bigger is refused whole.
  defp bounded_diff({:ok, text}) when byte_size(text) > @diff_cache_bytes,
    do: {:error, :too_large}

  defp bounded_diff(other), do: other

  defp cache_diff(state, key, text) do
    order = List.delete(state.diff_order, key) ++ [key]
    cache = Map.put(state.diff_cache, key, text)
    {cache, order} = trim_diffs(cache, order)
    %{state | diff_cache: cache, diff_order: order}
  end

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
  defp diff_text(id, scope, conversation, change_or_op_diff) do
    with true <- uuid?(id),
         {:ok, run_id, diff} <- change_or_op_diff.(conversation, id),
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

  # pass71 S2: the slow work, overridable for tests (a blocking fake).
  defp work(overrides) do
    defaults = %{
      file_index: fn root -> elem(SwarmCode.Domain.FeatureCatalog.file_index(root), 0) end,
      diff: &change_or_op_diff/2,
      change_diff: &SwarmCode.Domain.FeatureCatalog.change_diff/2,
      feature_query: &SwarmCode.Daemon.Service.FeatureRequest.execute/4
    }

    if is_map(overrides),
      do: Map.merge(defaults, Map.take(overrides, Map.keys(defaults))),
      else: defaults
  end

  defp start_job(state, from, job, timeout) do
    state = if job.replace, do: replace_jobs(state, job.key), else: state

    if map_size(state.jobs) >= @max_jobs do
      {:reply, wire_error(:capacity_exceeded), state}
    else
      task = Task.Supervisor.async_nolink(state.task_supervisor, job.work)
      timer = Process.send_after(self(), {:job_timeout, task.ref}, timeout)

      entry = %{
        pid: task.pid,
        from: from,
        key: job.key,
        finish: job.finish,
        timer: timer
      }

      {:noreply, %{state | jobs: Map.put(state.jobs, task.ref, entry)}}
    end
  end

  defp replace_jobs(state, key) do
    state.jobs
    |> Enum.filter(fn {_, job} -> job.key == key end)
    |> Enum.reduce(state, fn {ref, _}, acc ->
      cancel_job(acc, ref, wire_error(:stale_revision))
    end)
  end

  defp cancel_jobs(state, response),
    do: Enum.reduce(Map.keys(state.jobs), state, &cancel_job(&2, &1, response))

  defp cancel_job(state, ref, response) do
    case Map.pop(state.jobs, ref) do
      {nil, _} ->
        state

      {job, jobs} ->
        Process.demonitor(ref, [:flush])
        Task.Supervisor.terminate_child(state.task_supervisor, job.pid)
        Process.exit(job.pid, :kill)
        cancel_job_timer(job)
        GenServer.reply(job.from, response)
        %{state | jobs: jobs}
    end
  end

  defp settle_job(state, ref, response) do
    case Map.pop(state.jobs, ref) do
      {nil, _} ->
        state

      {job, jobs} ->
        cancel_job_timer(job)
        GenServer.reply(job.from, response)
        %{state | jobs: jobs}
    end
  end

  defp cancel_job_timer(%{timer: timer}), do: Process.cancel_timer(timer)
end
