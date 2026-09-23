defmodule SwarmCode.Daemon.Service.LiveBackend do
  @moduledoc """
  Internal live service projection over supervised Runtime.Run children.

  State and request deduplication last only for this process lifetime. Starting
  requires explicit `mode: :transient`, including with an internal canonical sink.
  This component does not open a Repo, admit production storage, or persist a
  conversation. Presentation queues are bounded independently of run execution.
  """
  use GenServer
  alias SwarmCode.Daemon.Runtime.Run
  alias SwarmCode.Domain.Attachments
  alias SwarmCode.Protocol.ServiceRequest
  @commands [:dispatch_send, :run_control, :run_steer, :approval_resolve, :conversation_open]
  @terminal [:completed, :failed, :cancelled, :interrupted]
  @errors %{
    invalid_request: "invalid data source request",
    not_allowed: "request is not allowed",
    request_conflict: "request reference is already admitted",
    capacity_exceeded: "data source admission capacity exceeded",
    stale_revision: "request revision is stale",
    source_unavailable: "data source is unavailable",
    duplicate_watch: "watch reference is already admitted"
  }

  def start_link(opts) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, :invalid_backend_configuration}

      opts[:mode] != :transient ->
        {:error, :canonical_persistence_required}

      true ->
        GenServer.start_link(__MODULE__, opts)
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with true <- Enum.all?([:conversation_id, :project_id, :source_epoch], &uuid?(opts[&1])),
         %SwarmCode.Providers.Provider{} <- opts[:provider],
         {:ok, root} <- SwarmCode.Tools.Path.real_path(opts[:project_root]),
         true <- File.dir?(root),
         {:ok, supervisor} <-
           DynamicSupervisor.start_link(strategy: :one_for_one, max_children: 64) do
      {:ok,
       %{
         opts: Keyword.put(opts, :project_root, root),
         supervisor: supervisor,
         runs: %{},
         order: [],
         watches: %{},
         requests: %{},
         revision: 0
       }}
    else
      _ -> {:stop, :invalid_backend_configuration}
    end
  end

  @impl true
  def handle_call({:service_request, id, scope, request}, _, state) do
    # pass70 F: `conversation_list` is a read (the palette sends it on open);
    # answering it as a command made the client drop the connection. The
    # unsaved session has no saved conversations, so it answers not_allowed.
    command? =
      Map.get(request, :operation) in @commands or
        Map.get(request, :operation) not in [
          :query,
          :detail,
          :resync,
          :feature_query,
          :conversation_list
        ]

    fingerprint = {scope, Map.get(request, :operation), Map.get(request, :params)}

    if command? and map_size(state.requests) >= 4096 and not Map.has_key?(state.requests, id) do
      {:reply, reject(id, :capacity_exceeded), state}
    else
      case if(command?, do: Map.get(state.requests, id)) do
        {^fingerprint, response} ->
          {:reply, response, state}

        {_other, _} ->
          {:reply, reject(id, :request_conflict), state}

        nil ->
          {response, next} =
            with {:ok, _} <- ServiceRequest.encode(request, scope),
                 true <- member?(state, scope) do
              execute(request, scope, id, state)
            else
              _ ->
                {if(command?, do: reject(id, :not_allowed), else: wire_error(:not_allowed)),
                 state}
            end

          next = if command?, do: put_in(next.requests[id], {fingerprint, response}), else: next
          {:reply, response, next}
      end
    end
  end

  def handle_call({:service_watch, connection, _id, scope, request}, _, state) do
    key = {connection, request.params["watch_ref"]}

    with {:ok, _} <- ServiceRequest.encode(request, scope),
         true <- is_pid(connection) and member?(state, scope),
         false <- Map.has_key?(state.watches, key),
         true <- map_size(state.watches) < 128,
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

  def handle_info({:run_event, id, sequence, event}, state) when is_map_key(state.runs, id) do
    run = state.runs[id]
    # Runtime.Run does not synchronously call its subscriber, including when a
    # canonical sink is configured. Acknowledging here bounds its presentation.
    safe_call(fn -> Run.acknowledge(run.pid, sequence) end)
    next = project(state, id, event)
    if next.runs[id].status in @terminal, do: send(self(), {:retire_run, id})
    {:noreply, next}
  end

  def handle_info({:retire_run, id}, state) do
    case state.runs[id] do
      %{pid: pid, status: status} = run when is_pid(pid) and status in @terminal ->
        Process.demonitor(run.monitor, [:flush])
        DynamicSupervisor.terminate_child(state.supervisor, pid)
        {:noreply, put_in(state.runs[id], %{run | pid: nil, monitor: nil})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:run_snapshot_required, id, _sequence}, state)
      when is_map_key(state.runs, id) do
    case safe_call(fn -> Run.snapshot(state.runs[id].pid) end) do
      %{status: status, text: text, reasoning: reasoning} = snapshot ->
        state = %{state | revision: state.revision + 1}

        state =
          update_in(
            state.runs[id],
            &%{&1 | status: status, text: text, reasoning: reasoning, revision: state.revision}
          )

        # Reconcile the current pending operation if presentation overflowed.
        state = reconcile_approval(state, id, snapshot.pending_approval)
        if status in @terminal, do: send(self(), {:retire_run, id})
        {:noreply, publish_run(state, id)}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    state =
      Enum.reduce(state.watches, state, fn {key, entry}, acc ->
        if entry.monitor == monitor, do: unwatch(acc, key), else: acc
      end)

    case Enum.find(state.runs, fn {_, run} -> run.monitor == monitor end) do
      {id, %{status: status}} when status not in @terminal ->
        {:noreply, project(state, id, %{type: :finished, status: :interrupted})}

      {id, _run} ->
        {:noreply,
         %{state | runs: Map.delete(state.runs, id), order: List.delete(state.order, id)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, supervisor, reason}, %{supervisor: supervisor} = state),
    do: {:stop, reason, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    if Process.alive?(state.supervisor), do: Supervisor.stop(state.supervisor, :shutdown, 10_000)
  end

  @impl true
  def format_status(status),
    do: %{status | state: %{mode: status.state.opts[:mode], runs: map_size(status.state.runs)}}

  defp execute(%{operation: :dispatch_send, params: params}, _scope, id, state) do
    if map_size(state.runs) >= 200 or map_size(state.requests) >= 4096 do
      {reject(id, :capacity_exceeded), state}
    else
      with {:ok, prompt} <- transient_prompt(params["text"]),
           {:ok, attachments} <- attachment_payloads(params["attachment_refs"]) do
        run_id = Ecto.UUID.generate()
        node_id = Ecto.UUID.generate()

        opts =
          Keyword.take(state.opts, [
            :provider,
            :model,
            :project_root,
            :approval,
            :effort,
            :canonical_sink,
            :canonical_timeout_ms,
            :request_timeout_ms,
            :max_steps,
            :settings,
            :system
          ])

        opts =
          Keyword.merge(opts,
            prompt: prompt,
            attachments: attachments,
            id: run_id,
            agent_id: node_id,
            subscriber: self()
          )

        case DynamicSupervisor.start_child(state.supervisor, {Run, opts}) do
          {:ok, pid} ->
            run = %{
              id: run_id,
              pid: pid,
              monitor: Process.monitor(pid),
              node_id: node_id,
              user_id: Ecto.UUID.generate(),
              attempt_id: Ecto.UUID.generate(),
              prompt: prompt,
              text: "",
              attachments: attachments,
              reasoning: "",
              status: :running,
              revision: state.revision + 1,
              created: state.revision + 1,
              approval: nil,
              steers: [],
              tools: [],
              at: now_ms(),
              finished_at: nil
            }

            next = %{
              state
              | runs: Map.put(state.runs, run_id, run),
                order: state.order ++ [run_id],
                revision: state.revision + 1
            }

            {accepted(id, [run_id]), publish_run(next, run_id, true)}

          _ ->
            {reject(id, :source_unavailable), state}
        end
      else
        {:error, reason} -> {reject(id, reason), state}
      end
    end
  end

  defp execute(%{operation: :query, params: params}, scope, id, state) do
    case snapshot(params, scope, id, state) do
      {:ok, kind, body} -> {result(kind, body), state}
      {:error, code} -> {wire_error(code), state}
    end
  end

  defp execute(%{operation: :feature_query, params: params}, scope, id, state) do
    feature = params["feature"]

    opts = [
      id: params["id"],
      cursor: params["cursor"],
      limit: params["page_size"],
      byte_limit: params["byte_limit"]
    ]

    result =
      try do
        SwarmCode.Domain.FeatureCatalog.query(feature, %{kind: scope.kind, id: scope.id}, opts)
      catch
        _, _ -> {:error, :feature_unavailable}
      end

    case result do
      {:ok, page} ->
        body = library_snapshot(feature, id, page, state)

        if byte_size(Jason.encode!(body)) <= params["byte_limit"],
          do: {result("library_snapshot", body), state},
          else: {wire_error(:capacity_exceeded), state}

      {:error, _} ->
        {wire_error(:source_unavailable), state}
    end
  end

  defp execute(%{operation: :detail, params: params}, scope, id, state),
    do: {result("detail_window", detail(params, scope, id, state)), state}

  defp execute(%{operation: :conversation_open, params: params}, _scope, id, state) do
    if params["conversation_id"] in [nil, state.opts[:conversation_id]],
      do: {accepted(id, [state.opts[:conversation_id]]), state},
      else: {reject(id, :not_allowed), state}
  end

  defp execute(%{operation: operation, params: params}, scope, id, state)
       when operation in [:run_control, :run_steer, :approval_resolve] do
    run = state.runs[params["run_id"]]

    cond do
      is_nil(run) or not run_member?(run, scope, state) ->
        {reject(id, :not_allowed), state}

      params["node_id"] not in [nil, run.node_id] ->
        {reject(id, :not_allowed), state}

      operation == :approval_resolve and
          (is_nil(run.approval) or run.approval["id"] != params["interaction_id"] or
             run.approval["expected_revision"] != params["expected_revision"]) ->
        {reject(id, :stale_revision), state}

      true ->
        answer = safe_call(fn -> control(operation, params, run.pid) end)

        case answer do
          :ok -> {accepted(id, [run.id]), state}
          {:error, :stale_approval} -> {reject(id, :stale_revision), state}
          _ -> {reject(id, :not_allowed), state}
        end
    end
  end

  defp execute(%{operation: :conversation_list}, _scope, _id, state),
    do: {wire_error(:not_allowed), state}

  defp execute(_, _, id, state), do: {reject(id, :not_allowed), state}

  # The unsaved runtime does not implement web modes. Never turn a slash
  # command into an ordinary provider prompt and falsely imply mode execution.
  defp transient_prompt(text) when is_binary(text) do
    if String.starts_with?(String.trim_leading(text), "/"),
      do: {:error, :not_allowed},
      else: {:ok, text}
  end

  defp control(:run_control, %{"action" => "pause"}, pid), do: Run.pause(pid)
  defp control(:run_control, %{"action" => "continue"}, pid), do: Run.continue(pid)
  defp control(:run_control, %{"action" => "stop"}, pid), do: Run.stop(pid)

  defp control(:run_steer, params, pid) do
    with {:ok, attachments} <- attachment_payloads(params["attachment_refs"]) do
      Run.steer(pid, params["text"], attachments)
    end
  end

  defp control(:approval_resolve, params, pid),
    do:
      Run.resolve_approval(
        pid,
        params["interaction_id"],
        if(params["decision"] == "approve", do: :allow, else: :deny)
      )

  defp attachment_payloads(refs) when is_list(refs) do
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

  defp project(state, id, event) do
    revision = state.revision + 1
    run = %{state.runs[id] | revision: revision}
    old_approval = run.approval

    run =
      case event do
        %{type: :text_delta, text: text} ->
          %{run | text: run.text <> text}

        %{type: :tool_started, id: call_id, tool: tool} ->
          %{run | tools: run.tools ++ [new_tool(call_id, tool, revision)]}

        %{type: :tool_progress, id: call_id, text: text} ->
          update_tool(run, call_id, text, "running", revision)

        %{type: :tool_completed, id: call_id, text: text, error?: failed} ->
          run =
            if Enum.any?(run.tools, &(&1.call_id == call_id)),
              do: run,
              else: %{run | tools: run.tools ++ [new_tool(call_id, event.tool, revision)]}

          update_tool(run, call_id, text, if(failed, do: "failed", else: "done"), revision)

        %{type: :reasoning_delta, text: text} ->
          %{run | reasoning: run.reasoning <> text}

        %{type: :text_reset} ->
          %{run | text: ""}

        %{type: :reasoning_reset} ->
          %{run | reasoning: ""}

        %{type: :paused} ->
          %{run | status: :paused}

        %{type: :continued, status: status} ->
          %{run | status: status}

        %{type: :finished, result: result, reasoning: reasoning} ->
          %{
            run
            | status: result.status,
              text: result.text,
              reasoning: reasoning,
              approval: nil,
              finished_at: now_ms()
          }

        %{type: :finished, status: status} ->
          %{run | status: status, approval: nil, finished_at: now_ms()}

        %{type: :approval_required} ->
          %{run | status: :waiting_approval, approval: approval(event, run, state)}

        %{type: :approval_resolved} ->
          %{run | status: :running, approval: nil}

        %{type: :steer_admitted, text: text, id: steer_id} = event ->
          %{
            run
            | steers:
                run.steers ++
                  [
                    %{
                      id: steer_id,
                      text: text,
                      revision: revision,
                      attachments: Map.get(event, :attachment_refs, []),
                      at: now_ms()
                    }
                  ]
          }

        _ ->
          run
      end

    next = %{state | runs: Map.put(state.runs, id, run), revision: revision}

    next =
      if old_approval && is_nil(run.approval),
        do: broadcast(next, delta("interaction_remove", run, old_approval["id"], nil)),
        else: next

    publish_run(next, id)
  end

  defp publish_run(state, id, include_user \\ false) do
    run = state.runs[id]

    nodes =
      if include_user, do: transcript(run, state), else: Enum.drop(transcript(run, state), 1)

    state =
      Enum.reduce(nodes, state, fn body, acc ->
        broadcast(acc, delta("node_upsert", run, body["id"], body))
      end)

    state =
      if run.approval,
        do: broadcast(state, delta("interaction_upsert", run, run.approval["id"], run.approval)),
        else: state

    state = broadcast(state, delta("activity_upsert", run, run.id, activity(run, state)))
    broadcast(state, delta("run_update", run, run.id, summary(run, state)))
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
      "revision" => if(body, do: Map.get(body, "revision", run.revision), else: run.revision)
    }

  defp broadcast(state, delta) do
    delta = Map.put(delta, "conversation_id", state.opts[:conversation_id])

    Enum.reduce(state.watches, state, fn {key, entry}, acc ->
      relevant =
        member?(state, entry.scope) and
          (entry.scope.kind != :run or entry.scope.id == delta["run_id"]) and
          case entry.slot do
            "shell" -> delta["kind"] == "run_update"
            "activity" -> delta["kind"] == "activity_upsert"
            _ -> delta["kind"] != "activity_upsert"
          end

      if relevant do
        size = byte_size(Jason.encode!(delta))
        # Queued values are complete entity replacements. Replacing an unsent
        # value does not consume a sequence or lose stream text. Keep removals
        # ordered after the final upsert and never modify an in-flight value.
        pending = :queue.to_list(entry.queue)

        pending =
          Enum.reject(pending, fn {old, _} ->
            old["kind"] == delta["kind"] and old["entity_id"] == delta["entity_id"]
          end)

        entry = %{
          entry
          | queue: :queue.from_list(pending),
            bytes: Enum.reduce(pending, 0, fn {_, bytes}, n -> n + bytes end)
        }

        if :queue.len(entry.queue) >= 128 or entry.bytes + size > 1_048_576 or size > 131_072 do
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
    runs = state.order |> Enum.map(&state.runs[&1]) |> Enum.filter(&run_member?(&1, scope, state))
    cursor = params["cursor"]
    limit = params["page_size"]
    items = Enum.flat_map(runs, &transcript(&1, state))
    pending = Enum.flat_map(runs, &if(&1.approval, do: [&1.approval], else: []))
    run_bodies = Enum.map(runs, &summary(&1, state))
    slot = params["slot"]

    source =
      case slot do
        "transcript" -> items
        "pending" -> pending
        "activity" -> Enum.map(runs, &activity(&1, state))
        _ -> run_bodies
      end

    with {:ok, selected, before, after_cursor} <-
           page(source, cursor, params["direction"] || "after", limit) do
      base = page_info(request_id, selected, before, after_cursor)
      transcript = window(Enum.take(items, -limit), request_id)

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
              "mode" => "build",
              "chat_model" => state.opts[:model],
              "swarm_model" => state.opts[:model],
              "effort" => nil,
              "swarm_effort" => nil,
              "runs" => selected,
              "transcript" => transcript,
              "interactions" => Enum.take(pending, limit),
              "changes" => [],
              "verdicts" => [],
              "agents" => runs |> Enum.map(&agent(&1, state)) |> Enum.take(limit)
            })

          "inspector" ->
            Map.merge(base, %{
              "run" => List.first(selected),
              "agents" => runs |> Enum.map(&agent(&1, state)) |> Enum.take(limit),
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

  # The unsaved runtime has one assistant per run and no checkpoints or judges:
  # the agent is synthesized from the run, changes and verdicts stay empty.
  defp agent(run, _state) do
    open = run.tools |> Enum.reverse() |> Enum.find(&(&1.status == "running"))

    %{
      "id" => run.node_id,
      "run_id" => run.id,
      "revision" => run.revision,
      "state" => status(run.status),
      "allowed_actions" => [],
      "launched_by_superseded" => false,
      "name" => "Assistant",
      "role" => "assistant",
      "title" => "",
      "step" => preview(if(open, do: open.tool, else: status(run.status)), 200),
      "progress" => 0,
      "tokens_in" => 0,
      "tokens_out" => 0,
      "cost_usd" => nil,
      "started_at" => run.at,
      "finished_at" => run.finished_at,
      "parent_id" => nil,
      "depth" => 0,
      "changes_stat" => nil,
      "error" => nil
    }
  end

  defp page(items, nil, _direction, limit) do
    chosen = Enum.take(items, limit)
    {:ok, chosen, nil, if(length(items) > limit, do: List.last(chosen)["id"])}
  end

  defp page(items, cursor, direction, limit) do
    case Enum.find_index(items, &(&1["id"] == cursor)) do
      nil ->
        {:error, :invalid_request}

      index ->
        chosen =
          if direction == "after",
            do: Enum.slice(items, index + 1, limit),
            else: Enum.take(Enum.take(items, index), -limit)

        first = if chosen != [], do: Enum.find_index(items, &(&1["id"] == hd(chosen)["id"]))
        last = if chosen != [], do: Enum.find_index(items, &(&1["id"] == List.last(chosen)["id"]))

        {:ok, chosen, if(first && first > 0, do: hd(chosen)["id"]),
         if(last && last < length(items) - 1, do: List.last(chosen)["id"])}
    end
  end

  defp fit(kind, body, bytes) do
    if byte_size(Jason.encode!(body)) <= bytes,
      do: {:ok, kind, body},
      else: {:error, :capacity_exceeded}
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

  defp window(items, id), do: Map.put(page_info(id, items), "items", items)

  defp summary(run, state),
    do: %{
      "created_sequence" => run.created,
      "parent_run_id" => nil,
      "seen_revision" => 0,
      "id" => run.id,
      "conversation_id" => state.opts[:conversation_id],
      "kind" => "chat",
      "title" => preview(run.prompt, 256),
      "revision" => run.revision,
      "state" => status(run.status),
      "allowed_actions" => actions(run),
      "progress" => nil,
      "tokens_in" => 0,
      "tokens_out" => 0,
      "cost_usd" => nil,
      "model" => state.opts[:model],
      "agents_total" => 1,
      "agents_running" => if(run.status in @terminal, do: 0, else: 1),
      "needs" => if(run.approval, do: 1, else: 0),
      "changes" => 0,
      "started_at" => run.at,
      "finished_at" => run.finished_at,
      "consensus" => false,
      "error" => nil
    }

  defp transcript(run, state) do
    user =
      node(run, state, run.user_id, "user", run.prompt, "", "done", run.created)
      |> Map.merge(facts("text", run.node_id, run.at))

    assistant =
      node(
        run,
        state,
        run.node_id,
        "assistant",
        run.text,
        run.reasoning,
        status(run.status),
        run.revision
      )
      |> Map.merge(facts("text", run.node_id, run.at))

    user = Map.put(user, "attachment_refs", attachment_ids(run.attachments))

    [user, assistant] ++
      Enum.map(run.tools, fn tool ->
        node(
          run,
          state,
          tool.id,
          "tool",
          tool.tool <> "\n" <> tool.text,
          "",
          tool.status,
          tool.revision
        )
        |> Map.merge(facts("tool", run.node_id, tool.started_at, tool_call(tool)))
      end) ++
      Enum.map(run.steers, fn steer ->
        node(run, state, steer.id, "user", steer.text, "", "done", steer.revision)
        |> Map.put("attachment_refs", steer.attachments)
        |> Map.merge(%{"target_kind" => "steer", "target_id" => run.node_id})
        |> Map.merge(facts("text", run.node_id, steer.at))
      end)
  end

  defp facts(kind, agent_id, at, tool \\ nil),
    do: %{
      "kind" => kind,
      "tool" => tool,
      "agent_id" => agent_id,
      "tokens_in" => 0,
      "tokens_out" => 0,
      "at" => at || 0
    }

  defp tool_call(tool) do
    finished = tool.finished_at

    %{
      "name" => preview(tool.tool, 200),
      "title" => preview(tool.tool, 200),
      "detail" => tool.text |> String.split("\n", parts: 2) |> hd() |> preview(200),
      "status" => tool.status,
      "started_at" => tool.started_at,
      "finished_at" => finished,
      "duration_ms" => if(finished, do: max(finished - tool.started_at, 0)),
      "result_bytes" => byte_size(tool.text),
      "files" => []
    }
  end

  defp new_tool(call_id, tool, revision),
    do: %{
      id: Ecto.UUID.generate(),
      call_id: call_id,
      tool: tool,
      text: "",
      status: "running",
      revision: revision,
      started_at: now_ms(),
      finished_at: nil
    }

  defp update_tool(run, call_id, text, status, revision) do
    finished = if status in ["done", "failed"], do: now_ms()

    %{
      run
      | tools:
          Enum.map(run.tools, fn tool ->
            if tool.call_id == call_id,
              do: %{
                tool
                | text: text,
                  status: status,
                  revision: revision,
                  finished_at: finished || tool.finished_at
              },
              else: tool
          end)
    }
  end

  defp now_ms, do: System.system_time(:millisecond)

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

  defp attachment_ids(values) when is_list(values),
    do:
      Enum.flat_map(values, fn
        %{"id" => id} when is_binary(id) -> [id]
        _ -> []
      end)

  defp attachment_ids(_), do: []

  defp approval(event, run, state),
    do: %{
      "id" => event.id,
      "run_id" => run.id,
      "node_id" => run.node_id,
      "conversation_id" => state.opts[:conversation_id],
      "kind" => "approval",
      "expected_revision" => run.revision,
      "state" => "pending",
      "question" => nil,
      "approval" => %{
        "tool" => event.tool,
        "permission" => Atom.to_string(event.permission),
        "arguments_preview" => preview(Jason.encode!(event.arguments)),
        "arguments_detail_ref" => nil
      },
      "allowed_actions" => ["approve", "deny"],
      "urgency" => "normal",
      "deadline" => 0,
      "created_at" => run.revision
    }

  defp reconcile_approval(state, id, nil), do: update_in(state.runs[id], &%{&1 | approval: nil})

  defp reconcile_approval(state, id, pending) do
    run = state.runs[id]

    if run.approval && run.approval["id"] == pending.id do
      state
    else
      case SwarmCode.Tools.permission(pending.tool, pending.arguments) do
        {:ok, permission} when permission in [:write, :execute] ->
          event = Map.put(pending, :permission, permission)
          update_in(state.runs[id], &%{&1 | approval: approval(event, run, state)})

        _ ->
          update_in(state.runs[id], &%{&1 | approval: nil})
      end
    end
  end

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
      "interaction" => run.approval,
      "deadline" => nil,
      "created_at" => run.created
    }

  defp activity_kind(:waiting_approval), do: "approval"
  defp activity_kind(:paused), do: "paused"
  defp activity_kind(:failed), do: "failure"
  defp activity_kind(s) when s in @terminal, do: "completion"
  defp activity_kind(_), do: "running"

  defp counts(runs),
    do: %{
      "running" => Enum.count(runs, &(&1.status == :running)),
      "waiting" => Enum.count(runs, &(&1.status == :waiting_approval)),
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

    found =
      state.order
      |> Enum.map(&state.runs[&1])
      |> Enum.filter(&run_member?(&1, scope, state))
      |> Enum.find_value(fn run ->
        values =
          [
            {run.user_id <> ":text", run.prompt},
            {run.node_id <> ":text", run.text},
            {run.node_id <> ":reasoning", run.reasoning}
          ] ++ Enum.map(run.steers, &{&1.id <> ":text", &1.text})

        Enum.find_value(values, fn {key, text} -> if key == ref, do: text end)
      end)

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

    if is_binary(found) and offset < byte_size(found) and
         String.valid?(binary_part(found, 0, offset)) do
      text =
        preview(
          binary_part(found, offset, byte_size(found) - offset),
          min(params["bytes"], 65_536)
        )

      Map.merge(base, %{
        "state" => "idle",
        "error" => nil,
        "detail_ref" => %{"id" => ref, "total_bytes" => byte_size(found)},
        "text" => text,
        "next_offset" =>
          if(offset + byte_size(text) < byte_size(found), do: offset + byte_size(text))
      })
    else
      base
    end
  end

  defp library_snapshot(feature, request_id, page, state) do
    items =
      Enum.map(page.items || [], fn item ->
        %{
          "id" => id_string(item[:id] || item["id"]),
          "title" => preview(item[:title] || item["title"] || "", 256),
          "subtitle" => preview(item[:subtitle] || item["subtitle"] || "", 256),
          "status" => preview(item[:status] || item["status"] || "", 128),
          "detail" => preview(item[:detail] || item["detail"] || "", 65_536),
          "actions" => Enum.map(item[:actions] || item["actions"] || [], &Atom.to_string/1)
        }
      end)

    %{
      "feature" => feature,
      "title" => preview(page.title || "", 256),
      "description" => preview(page.description || "", 2_048),
      "items" => items,
      "state" => "idle",
      "before_cursor" => nil,
      "after_cursor" => page.next_cursor,
      "request_id" => request_id,
      "error" => nil,
      "presence" => "covered",
      "covered_ids" => Enum.map(items, & &1["id"]),
      "through_sequence" => state.revision
    }
  end

  defp id_string(value) when is_binary(value), do: value
  defp id_string(value) when is_integer(value), do: Integer.to_string(value)
  defp id_string(value), do: inspect(value)

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

  # Scope generations are client navigation generations. They are compared by
  # the client when correlating a response; a daemon may receive a valid
  # conversation request at any generation after reconnect. Membership is
  # therefore structural, while ServiceRequest still bounds the generation.
  defp member?(state, scope) when is_map(scope) do
    case scope do
      %{kind: :global, id: nil} -> true
      %{kind: :project, id: id} -> id == state.opts[:project_id]
      %{kind: :conversation, id: id} -> id == state.opts[:conversation_id]
      %{kind: :run, id: id} -> Map.has_key?(state.runs, id)
      _ -> false
    end
  end

  defp member?(_, _), do: false
  defp run_member?(run, %{kind: :run, id: id}, _state), do: run.id == id
  defp run_member?(_run, scope, state), do: member?(state, scope)

  defp result(kind, body),
    do: {:ok, %{"op" => "result", "response_kind" => kind, "value" => body}}

  defp accepted(id, ids), do: outcome(id, "accepted", ids, nil)
  defp reject(id, code), do: outcome(id, "rejected", [], error(code))

  defp outcome(id, status, ids, error),
    do:
      result("outcome", %{
        "status" => status,
        "request_id" => id,
        "identifiers" => ids,
        "interaction" => nil,
        "error" => error,
        "corrective_action" => "none"
      })

  defp error(code), do: %{"code" => Atom.to_string(code), "message" => Map.fetch!(@errors, code)}
  defp wire_error(code), do: {:error, Map.put(error(code), "op", "error")}

  defp safe_call(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :source_unavailable}
  end

  defp uuid?(id), do: is_binary(id) and match?({:ok, ^id}, Ecto.UUID.cast(id))
end
