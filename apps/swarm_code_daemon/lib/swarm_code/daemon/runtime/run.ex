defmodule SwarmCode.Daemon.Runtime.Run do
  @moduledoc """
  Live model/tool loop with an optional acknowledged internal canonical sink.
  The sink claims the writer and commits exact (run_id, sequence) records before
  acknowledgement. It must not synchronously call Run. This component does not
  provide production storage; presentation delivery is separately bounded.
  """
  use GenServer, restart: :temporary, shutdown: 10_000
  alias SwarmCode.{LLM, Tools}
  alias SwarmCode.Domain.Attachments
  alias SwarmCode.LLM.{Chunks, Request, Result}
  alias SwarmCode.Providers.Provider
  @terminal [:completed, :failed, :cancelled]
  @maximum_context 8 * 1_024 * 1_024
  @tool_result_bytes 65_000
  @maximum_calls 32
  @options ~w(provider model prompt attachments project_root approval max_steps request_timeout_ms subscriber settings system effort id agent_id canonical_sink canonical_timeout_ms)a

  def start_link(opts) do
    with {:ok, config} <- config(opts), do: GenServer.start_link(__MODULE__, config)
  end

  def snapshot(run), do: GenServer.call(run, :snapshot)
  def acknowledge(run, sequence), do: GenServer.call(run, {:acknowledge, sequence})
  def await(run, timeout \\ 5_000), do: GenServer.call(run, :await, timeout)
  def stop(run), do: GenServer.call(run, :stop)
  def pause(run), do: GenServer.call(run, :pause)
  def continue(run), do: GenServer.call(run, :continue)
  def steer(run, text, attachments \\ []), do: GenServer.call(run, {:steer, text, attachments})
  def resolve_approval(run, id, decision), do: GenServer.call(run, {:approval, id, decision})

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)

    with {:ok, operations} <- Task.Supervisor.start_link() do
      state =
        Map.merge(config, %{
          operations: operations,
          op: nil,
          model_operation_id: nil,
          calls: [],
          messages: [user_message(config.prompt, config.attachments)],
          steer: [],
          pending_approval: nil,
          status: :running,
          paused?: false,
          stopping?: false,
          finishing?: false,
          steps: 0,
          sequence: 0,
          canonical_sequence: 0,
          stream: Chunks.new(),
          reasoning: Chunks.new(),
          in_flight: [],
          delivery_stale?: false,
          error: nil,
          waiters: [],
          pending: nil,
          controls: [],
          resume: nil,
          usage: %{input: 0, output: 0, cache_read: 0, cache_write: 0},
          sink_monitor: if(config.canonical_sink, do: Process.monitor(config.canonical_sink))
        })

      {:ok, state, {:continue, :start}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:start, state),
    do:
      {:noreply,
       publish(
         state,
         %{type: :started, model: state.model, prompt: state.prompt},
         nil,
         &advance/1,
         %{type: :started, model: state.model}
       )}

  @impl true
  def handle_call(:snapshot, {reader, _}, state) do
    snapshot = public_snapshot(state)

    state =
      if reader == state.subscriber,
        do: %{state | in_flight: [], delivery_stale?: false},
        else: state

    {:reply, snapshot, state}
  end

  def handle_call({:acknowledge, sequence}, {reader, _}, state)
      when reader == state.subscriber and is_integer(sequence) and sequence >= 0 and
             sequence <= state.sequence,
      do: {:reply, :ok, %{state | in_flight: Enum.reject(state.in_flight, &(&1 <= sequence))}}

  def handle_call({:acknowledge, _}, _, state),
    do: {:reply, {:error, :invalid_acknowledgment}, state}

  def handle_call(:await, _, %{status: status} = state) when status in @terminal,
    do: {:reply, {:ok, outcome(state)}, state}

  def handle_call(:await, from, %{waiters: waiters} = state) when length(waiters) < 128,
    do: {:noreply, %{state | waiters: [from | waiters]}}

  def handle_call(:await, _, state), do: {:reply, {:error, :too_many_waiters}, state}

  def handle_call(:stop, _, %{status: status} = state) when status in @terminal,
    do: {:reply, :ok, state}

  def handle_call(:stop, _, %{stopping?: true} = state), do: {:reply, :ok, state}
  def handle_call(:stop, _, %{finishing?: true} = state), do: {:reply, :ok, state}

  def handle_call(:stop, _, state) do
    # Cancellation takes effect immediately, even with a canonical append held.
    # Its durable request/settlement remains serialized after that append.
    state = cancel_operation(%{state | stopping?: true})
    control = fn s -> publish(s, %{type: :stop_requested}, operation_id(s), &advance/1) end
    {:reply, :ok, drive(%{state | controls: [control | state.controls]})}
  end

  def handle_call(command, _, %{status: status} = state)
      when command in [:pause, :continue] and status in @terminal,
      do: {:reply, {:error, :terminal}, state}

  def handle_call(command, _, %{finishing?: true} = state) when command in [:pause, :continue],
    do: {:reply, {:error, :terminal}, state}

  def handle_call(:pause, from, state) do
    enqueue_control(
      state,
      fn s ->
        publish(s, %{type: :pause_requested}, operation_id(s), fn next ->
          GenServer.reply(from, :ok)
          advance(%{next | paused?: true})
        end)
      end,
      from,
      :terminal
    )
  end

  def handle_call(:continue, from, state) do
    enqueue_control(
      state,
      fn s ->
        status = if s.pending_approval, do: :waiting_approval, else: :running

        publish(s, %{type: :continued, status: status}, operation_id(s), fn next ->
          GenServer.reply(from, :ok)
          advance(%{next | paused?: false, status: status})
        end)
      end,
      from,
      :terminal
    )
  end

  def handle_call({:steer, text, attachments}, from, state)
      when is_binary(text) and byte_size(text) in 1..65_000 and state.status not in @terminal and
             not state.finishing? and not state.stopping? do
    if String.valid?(text) and valid_attachments?(attachments) and
         length(state.steer) + length(state.controls) < 32 do
      id = uuid()

      enqueue_control(
        state,
        fn s ->
          publish(
            s,
            %{
              type: :steer_admitted,
              id: id,
              text: text,
              attachment_refs: Enum.map(attachments, & &1["id"])
            },
            nil,
            fn next ->
              GenServer.reply(from, :ok)

              advance(%{
                next
                | steer: next.steer ++ [%{id: id, text: text, attachments: attachments}]
              })
            end
          )
        end,
        from,
        :invalid_steer
      )
    else
      {:reply, {:error, :invalid_steer}, state}
    end
  end

  def handle_call({:steer, text}, from, state), do: handle_call({:steer, text, []}, from, state)

  def handle_call({:steer, _text, _attachments}, _, state),
    do: {:reply, {:error, :invalid_steer}, state}

  def handle_call(
        {:approval, id, decision},
        from,
        %{pending_approval: %{id: id, resolving?: false} = approval} = state
      )
      when decision in [:allow, :deny] and not state.stopping? do
    if length(state.controls) >= 32 do
      {:reply, {:error, :capacity_exceeded}, state}
    else
      state = %{state | pending_approval: %{approval | resolving?: true}}

      enqueue_control(
        state,
        fn s ->
          event = %{
            type: :approval_resolved,
            id: id,
            decision: decision,
            parent_model_operation_id: approval.call.parent_model_operation_id,
            call_id: approval.call.id
          }

          publish(s, event, nil, fn next ->
            GenServer.reply(from, :ok)
            next = %{next | pending_approval: nil, status: :running}

            if decision == :allow,
              do:
                advance(%{next | calls: [Map.put(approval.call, :approved?, true) | next.calls]}),
              else:
                tool_result(next, nil, approval.call, {:error, "tool execution denied by user"})
          end)
        end,
        from,
        :stale_approval
      )
    end
  end

  def handle_call({:approval, _, _}, _, state), do: {:reply, {:error, :stale_approval}, state}

  @impl true
  def handle_info(
        {:operation_event, token, event, worker, ref},
        %{op: %{token: token, task: %{pid: worker}}} = state
      ) do
    # The actual worker waits for one credit and cannot grow this queue.
    action = fn s ->
      publish(s, event, operation_id(s), fn next ->
        send(worker, {ref, :ok})

        next =
          case event do
            %{type: :text_delta, text: text} ->
              %{next | stream: Chunks.append(next.stream, text)}

            %{type: :text_reset} ->
              %{next | stream: Chunks.new()}

            %{type: :reasoning_delta, text: text} ->
              %{next | reasoning: Chunks.append(next.reasoning, text)}

            %{type: :reasoning_reset} ->
              %{next | reasoning: Chunks.new()}

            _ ->
              next
          end

        advance(next)
      end)
    end

    {:noreply, drive(%{state | controls: state.controls ++ [action]})}
  end

  def handle_info({:operation_event, _, _, worker, ref}, state) do
    send(worker, {ref, :ok})
    {:noreply, state}
  end

  def handle_info({ref, result}, %{pending: %{task: %{ref: ref}} = pending} = state),
    do: {:noreply, %{state | pending: %{pending | result: result}}}

  def handle_info(
        {:DOWN, ref, :process, _, reason},
        %{pending: %{task: %{ref: ref}} = pending} = state
      ) do
    Process.cancel_timer(pending.timer)

    if reason == :normal and pending.result == {:ok, pending.record.sequence} do
      state =
        present(
          %{state | pending: nil, canonical_sequence: pending.record.sequence},
          pending.presentation
        )

      {:noreply, drive(%{state | resume: pending.next})}
    else
      {:stop, :canonical_sink_failed, state}
    end
  end

  def handle_info({:canonical_timeout, token}, %{pending: %{token: token}} = state),
    do: {:stop, :canonical_sink_failed, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{sink_monitor: ref} = state)
      when not is_nil(ref),
      do: {:stop, :canonical_sink_failed, state}

  def handle_info({ref, result}, %{op: %{task: %{ref: ref}} = op} = state),
    do: {:noreply, %{state | op: %{op | result: {:result, result}}}}

  def handle_info({:DOWN, ref, :process, _, reason}, %{op: %{task: %{ref: ref}} = op} = state) do
    if op.timer, do: Process.cancel_timer(op.timer)
    {:noreply, drive(%{state | op: %{op | down: {:down, reason}}})}
  end

  def handle_info({:operation_timeout, token}, %{op: %{token: token, down: nil}} = state) do
    state = cancel_operation(%{state | error: :operation_timeout, stopping?: true})
    control = fn s -> publish(s, %{type: :operation_timeout}, operation_id(s), &advance/1) end
    {:noreply, drive(%{state | controls: [control | state.controls]})}
  end

  def handle_info({:EXIT, supervisor, _}, %{operations: supervisor} = state),
    do: {:stop, :operation_supervisor_failed, state}

  def handle_info(_, state), do: {:noreply, state}
  @impl true
  def terminate(_, state) do
    if Process.alive?(state.operations), do: Supervisor.stop(state.operations, :shutdown, 7_000)
    :ok
  end

  @impl true
  def format_status(status),
    do:
      status
      |> Map.put(:state, Map.take(status.state, [:id, :agent_id, :status, :steps, :sequence]))
      |> Map.put(:message, :redacted)
      |> Map.put(:reason, :redacted)
      |> Map.put(:log, [])

  defp enqueue_control(%{controls: controls} = state, _, _, _) when length(controls) >= 32,
    do: {:reply, {:error, :capacity_exceeded}, state}

  defp enqueue_control(state, control, from, rejection) do
    guarded = fn current ->
      # Arrival-time validation can expire while a model-result commit is held.
      # A terminal continuation may already have submitted/committed its final
      # record before this saved control gets its turn. Never reopen that state.
      if current.finishing? or current.stopping? or current.status in @terminal do
        GenServer.reply(from, {:error, rejection})
        current
      else
        control.(current)
      end
    end

    {:noreply, drive(%{state | controls: state.controls ++ [guarded]})}
  end

  defp drive(%{pending: pending} = state) when not is_nil(pending), do: state

  defp drive(%{resume: resume} = state) when not is_nil(resume),
    do: drive(resume.(%{state | resume: nil}))

  defp drive(%{controls: [control | rest]} = state),
    do: drive(control.(%{state | controls: rest}))

  defp drive(state), do: advance(state)
  defp advance(%{pending: pending} = state) when not is_nil(pending), do: state
  defp advance(%{controls: [_ | _]} = state), do: drive(state)
  defp advance(%{status: status} = state) when status in @terminal, do: state
  defp advance(%{finishing?: true} = state), do: state
  defp advance(%{op: %{down: down}} = state) when not is_nil(down), do: settle_operation(state)

  defp advance(%{op: %{effect: effect, task: nil} = op, stopping?: true} = state)
       when not is_nil(effect),
       do: advance(%{state | op: %{op | effect: nil, down: {:down, :not_started}}})

  defp advance(%{op: %{effect: effect}, stopping?: true} = state) when not is_nil(effect),
    do: cancel_operation(state)

  defp advance(%{op: %{effect: effect}, paused?: true} = state) when not is_nil(effect),
    do: hold(state)

  defp advance(%{op: %{effect: effect} = op} = state) when not is_nil(effect),
    do: effect.(%{state | op: %{op | effect: nil}})

  defp advance(%{op: op} = state) when not is_nil(op), do: state
  defp advance(%{stopping?: true} = state), do: finish(state, :cancelled)
  defp advance(%{paused?: true} = state), do: hold(state)
  defp advance(%{pending_approval: pending} = state) when not is_nil(pending), do: state
  defp advance(%{calls: [call | rest]} = state), do: admit_tool(%{state | calls: rest}, call)

  defp advance(state) do
    messages = state.messages ++ Enum.map(state.steer, &user_message(&1.text, &1.attachments))

    cond do
      state.steps >= state.max_steps ->
        finish(state, :failed, :step_limit)

      length(messages) > 1_024 or :erlang.external_size(messages) > @maximum_context ->
        finish(state, :failed, :context_limit)

      true ->
        launch_model(state, messages)
    end
  end

  defp launch_model(state, messages) do
    op = new_operation(:model, nil)

    event = %{
      type: :model_admitted,
      step: state.steps + 1,
      steer_ids: Enum.map(state.steer, & &1.id)
    }

    publish(
      %{state | op: op},
      event,
      op.id,
      fn committed ->
        effect = fn next ->
          if next.stopping? do
            advance(%{next | op: %{op | down: {:down, :not_started}}})
          else
            request = %Request{
              provider: next.provider,
              model: next.model,
              system: next.system,
              messages: messages,
              tools: Tools.specs(),
              effort: next.effort,
              deadline_ms: next.request_timeout_ms
            }

            next = %{
              next
              | messages: messages,
                steer: Enum.reject(next.steer, &(&1.id in event.steer_ids)),
                steps: next.steps + 1,
                model_operation_id: op.id,
                stream: Chunks.new(),
                reasoning: Chunks.new(),
                status: :running
            }

            launch_task(
              next,
              next.request_timeout_ms + 1_000,
              fn notify -> LLM.stream(request, fn event -> notify.(model_event(event)) end) end,
              %{type: :model_started, step: next.steps}
            )
          end
        end

        advance(%{committed | op: %{committed.op | effect: effect}})
      end,
      nil
    )
  end

  defp admit_tool(state, call) do
    case if(Map.has_key?(call, :args_error),
           do: {:error, call.args_error},
           else: Tools.permission(call.name, call.args)
         ) do
      {:error, reason} ->
        tool_result(state, nil, call, {:error, reason})

      {:ok, permission} ->
        cond do
          permission == :read or state.approval == :auto or Map.get(call, :approved?) == true ->
            launch_tool(state, call)

          state.approval == :read_only ->
            tool_result(state, nil, call, {:error, "tool denied by read-only policy"})

          true ->
            approval = %{id: uuid(), call: call, resolving?: false}

            event = %{
              type: :approval_required,
              id: approval.id,
              tool: call.name,
              permission: permission,
              arguments: call.args,
              call_id: call.id,
              parent_model_operation_id: call.parent_model_operation_id
            }

            publish(
              state,
              event,
              nil,
              fn next ->
                advance(%{next | pending_approval: approval, status: :waiting_approval})
              end,
              Map.put(event, :arguments, preview_arguments(call.args))
            )
        end
    end
  end

  defp launch_tool(state, call) do
    op = new_operation(:tool, call)

    event = %{
      type: :tool_admitted,
      id: call.id,
      tool: call.name,
      arguments: call.args,
      parent_model_operation_id: call.parent_model_operation_id
    }

    publish(
      %{state | op: op},
      event,
      op.id,
      fn committed ->
        effect = fn next ->
          if next.stopping? do
            advance(%{next | op: %{op | down: {:down, :not_started}}})
          else
            context = %{project_root: next.project_root, settings: next.settings}
            {timeout, _} = Tools.RunCommand.timeout_for(call.args, context)

            launch_task(
              next,
              timeout + 3_000,
              fn notify ->
                Tools.run(call.name, call.args, context, fn progress, text ->
                  notify.(%{
                    type: :tool_progress,
                    id: call.id,
                    progress: progress,
                    text: bounded(text),
                    parent_model_operation_id: call.parent_model_operation_id
                  })
                end)
              end,
              %{
                type: :tool_started,
                id: call.id,
                tool: call.name,
                parent_model_operation_id: call.parent_model_operation_id
              }
            )
          end
        end

        advance(%{committed | op: %{committed.op | effect: effect}})
      end,
      nil
    )
  end

  defp new_operation(kind, call),
    do: %{
      id: uuid(),
      kind: kind,
      call: call,
      task: nil,
      token: make_ref(),
      timer: nil,
      result: nil,
      down: nil,
      effect: nil
    }

  defp launch_task(state, timeout, function, started) do
    owner = self()
    op = state.op

    launched =
      try do
        {:ok,
         Task.Supervisor.async_nolink(state.operations, fn ->
           receive do
             {:run_operation, token} when token == op.token ->
               function.(fn event -> notify(owner, op.token, event) end)

             :swarm_code_tool_cancel ->
               {:error, "operation cancelled before execution"}
           end
         end)}
      catch
        _, _ -> :launch_failed
      end

    case launched do
      :launch_failed ->
        advance(%{state | op: %{op | down: {:down, :launch_failed}}})

      {:ok, task} ->
        state = %{state | op: %{op | task: task}}

        publish(state, started, op.id, fn committed ->
          # A queued pause is applied before releasing this task's effect gate.
          effect = fn next ->
            timer = Process.send_after(self(), {:operation_timeout, op.token}, timeout)
            send(task.pid, {:run_operation, op.token})
            advance(%{next | op: %{next.op | timer: timer}})
          end

          advance(%{committed | op: %{committed.op | effect: effect}})
        end)
    end
  end

  defp notify(owner, token, event) do
    ref = make_ref()
    send(owner, {:operation_event, token, event, self(), ref})

    receive do
      {^ref, :ok} ->
        :ok

      :swarm_code_tool_cancel ->
        # Leave cancellation for RunCommand's native cleanup handshake while
        # breaking its progress wait independently of the canonical sink.
        send(self(), :swarm_code_tool_cancel)
        :ok
    end
  end

  defp settle_operation(%{op: op} = state) do
    {_, reason} = op.down

    result =
      case op.result do
        {:result, result} ->
          result

        nil ->
          {:error,
           if(reason == :not_started, do: "operation not started", else: "operation terminated")}
      end

    event = %{
      type: :operation_settled,
      kind: op.kind,
      disposition:
        if(op.result, do: :result, else: if(state.stopping?, do: :cancelled, else: :failed)),
      result: canonical_result(result),
      parent_model_operation_id: parent_model_id(op),
      call_id: if(op.call, do: op.call.id),
      launch_state:
        if(reason == :not_started,
          do: :not_started,
          else: if(reason == :launch_failed, do: :launch_failed, else: :started)
        )
    }

    publish(
      state,
      event,
      op.id,
      fn next ->
        next = %{next | op: nil}

        case op.kind do
          :model -> model_result(next, op, result)
          :tool -> tool_result(next, op.id, op.call, result)
        end
      end,
      nil
    )
  end

  defp canonical_result({:ok, %Result{} = result}), do: {:ok, Map.from_struct(result)}
  defp canonical_result({:ok, text}) when is_binary(text), do: {:ok, text}
  defp canonical_result({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp canonical_result(_), do: {:error, "invalid operation result"}
  defp parent_model_id(%{kind: :model, id: id}), do: id
  defp parent_model_id(%{call: call}), do: call.parent_model_operation_id

  defp model_result(state, op, {:ok, %Result{} = result}) do
    publish(
      state,
      %{type: :model_completed, result: Map.from_struct(result)},
      op.id,
      fn next ->
        next = %{
          next
          | usage: add_usage(next.usage, result.usage),
            stream: Chunks.new(result.text),
            reasoning: Chunks.new(result.reasoning),
            model_operation_id: op.id
        }

        cond do
          next.stopping? ->
            advance(next)

          result.stop_reason == "refusal" ->
            finish(next, :failed, :provider_refusal)

          result.stop_reason == "max_tokens" ->
            finish(next, :failed, :response_limit)

          not valid_calls?(result.tool_calls) ->
            finish(next, :failed, :invalid_tool_calls)

          true ->
            assistant = %{role: "assistant", content: result.text, tool_calls: result.tool_calls}

            assistant =
              if result.provider_blocks == [],
                do: assistant,
                else: Map.put(assistant, :provider_blocks, result.provider_blocks)

            next = %{
              next
              | messages: next.messages ++ [assistant],
                calls:
                  Enum.map(result.tool_calls, &Map.put(&1, :parent_model_operation_id, op.id))
            }

            if result.tool_calls == [] and next.steer == [] and next.controls == [],
              do: finish(next, :completed),
              else: advance(next)
        end
      end,
      nil
    )
  end

  defp model_result(state, op, result) do
    reason =
      case result do
        {:error, reason} -> bounded(reason)
        _ -> "invalid operation result"
      end

    publish(
      state,
      %{type: :model_failed, error: reason},
      op.id,
      fn next ->
        if next.stopping?,
          do: advance(next),
          else: finish(next, :failed, {:provider_failed, reason})
      end,
      nil
    )
  end

  defp tool_result(state, id, call, result) do
    {full, error?} =
      case result do
        {:ok, text} when is_binary(text) -> {text, false}
        {:error, reason} when is_binary(reason) -> {"Error: " <> reason, true}
        _ -> {"Error: invalid tool result", true}
      end

    event = %{
      type: :tool_completed,
      id: call.id,
      tool: call.name,
      text: full,
      error?: error?,
      result: canonical_result(result),
      parent_model_operation_id: call.parent_model_operation_id
    }

    presentation = %{
      type: :tool_completed,
      id: call.id,
      tool: call.name,
      text: bounded(full),
      error?: error?
    }

    publish(
      state,
      event,
      id,
      fn next ->
        message = %{
          role: "tool",
          tool_call_id: call.id,
          name: call.name,
          content: bounded(full),
          is_error: error?
        }

        advance(%{next | messages: next.messages ++ [message]})
      end,
      presentation
    )
  end

  defp cancel_operation(%{op: nil} = state), do: state
  defp cancel_operation(%{op: %{task: nil}} = state), do: state

  defp cancel_operation(%{op: %{kind: :tool, call: %{name: "run_command"}, task: task}} = state) do
    send(task.pid, :swarm_code_tool_cancel)
    state
  end

  defp cancel_operation(%{op: %{task: task}} = state) do
    Process.exit(task.pid, :kill)
    state
  end

  defp operation_id(%{op: nil}), do: nil
  defp operation_id(%{op: op}), do: op.id
  defp hold(%{status: :paused} = state), do: state

  defp hold(state),
    do: publish(state, %{type: :paused}, nil, fn next -> %{next | status: :paused} end)

  defp finish(state, status, error \\ nil)
  defp finish(%{finishing?: true} = state, _, _), do: state
  defp finish(%{status: status} = state, _, _) when status in @terminal, do: state

  defp finish(state, status, error) do
    status = if state.error == :operation_timeout, do: :failed, else: status
    terminal = %{state | status: status, error: error || state.error}

    event = %{
      type: :finished,
      result: outcome(terminal),
      reasoning: Chunks.to_string(state.reasoning),
      model_operation_id: state.model_operation_id
    }

    publish(%{state | finishing?: true}, event, nil, fn next ->
      next = %{
        next
        | status: status,
          error: terminal.error,
          pending_approval: nil,
          calls: [],
          steer: []
      }

      Enum.each(next.waiters, &GenServer.reply(&1, {:ok, outcome(next)}))
      %{next | waiters: []}
    end)
  end

  defp publish(state, event, operation_id, next),
    do: publish(state, event, operation_id, next, event)

  defp publish(state, event, operation_id, next, presentation) do
    record = %{
      writer: self(),
      run_id: state.id,
      agent_id: state.agent_id,
      operation_id: operation_id,
      sequence: state.canonical_sequence + 1,
      event: event
    }

    if state.canonical_sink do
      sink = state.canonical_sink

      task =
        Task.Supervisor.async_nolink(state.operations, fn ->
          try do
            GenServer.call(sink, {:append_run_event, record}, :infinity)
          catch
            # Task logs otherwise print the raw sink exit and canonical call
            # arguments before the owning Run can apply its redacted status.
            _, _ -> :canonical_append_failed
          end
        end)

      token = make_ref()
      timer = Process.send_after(self(), {:canonical_timeout, token}, state.canonical_timeout_ms)

      %{
        state
        | pending: %{
            record: record,
            presentation: presentation,
            task: task,
            token: token,
            timer: timer,
            result: nil,
            next: next
          }
      }
    else
      next.(present(%{state | canonical_sequence: record.sequence}, presentation))
    end
  end

  defp present(state, nil), do: state

  defp present(state, event) do
    state = %{state | sequence: state.sequence + 1}

    cond do
      not is_pid(state.subscriber) or state.delivery_stale? ->
        state

      length(state.in_flight) < 32 and :erlang.external_size(event) <= @tool_result_bytes ->
        send(state.subscriber, {:run_event, state.id, state.sequence, event})
        %{state | in_flight: [state.sequence | state.in_flight]}

      true ->
        send(state.subscriber, {:run_snapshot_required, state.id, state.sequence})
        %{state | delivery_stale?: true}
    end
  end

  defp model_event({:text_delta, text}), do: %{type: :text_delta, text: text}
  defp model_event({:reasoning_delta, text}), do: %{type: :reasoning_delta, text: text}
  defp model_event({:text_reset}), do: %{type: :text_reset}
  defp model_event({:reasoning_reset}), do: %{type: :reasoning_reset}

  defp model_event({:retry, attempt, count, reason}),
    do: %{type: :retry, attempt: attempt, count: count, reason: reason}

  defp public_snapshot(state),
    do: %{
      id: state.id,
      agent_id: state.agent_id,
      durability: if(state.canonical_sink, do: :acknowledged_sink, else: :transient),
      status: state.status,
      steps: state.steps,
      sequence: state.sequence,
      canonical_sequence: state.canonical_sequence,
      text: Chunks.to_string(state.stream),
      reasoning: Chunks.to_string(state.reasoning),
      error: state.error,
      usage: state.usage,
      pending_approval:
        case state.pending_approval do
          nil ->
            nil

          %{id: id, call: call} ->
            %{id: id, tool: call.name, arguments: preview_arguments(call.args)}
        end
    }

  defp outcome(state),
    do: %{
      id: state.id,
      status: state.status,
      steps: state.steps,
      text: Chunks.to_string(state.stream),
      error: state.error,
      usage: state.usage
    }

  defp bounded(value) when is_binary(value) and byte_size(value) <= @tool_result_bytes,
    do: String.replace_invalid(value)

  defp bounded(value) when is_binary(value),
    do: String.replace_invalid(binary_part(value, 0, @tool_result_bytes)) <> "\n[truncated]"

  defp bounded(_), do: "operation failed"

  defp preview_arguments(args),
    do:
      Map.new(args, fn {key, value} ->
        {key, if(is_binary(value), do: bounded(value), else: value)}
      end)

  defp add_usage(left, right),
    do: Map.new(left, fn {key, value} -> {key, value + Map.get(right, key, 0)} end)

  defp valid_calls?(calls) when is_list(calls) and length(calls) <= @maximum_calls do
    Enum.all?(calls, fn
      %{id: id, name: name, args: args} ->
        is_binary(id) and id != "" and is_binary(name) and is_map(args)

      _ ->
        false
    end) and length(Enum.uniq_by(calls, & &1.id)) == length(calls)
  end

  defp valid_calls?(_), do: false

  defp config(opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- keys == Enum.uniq(keys) and Enum.all?(keys, &(&1 in @options)),
         id <- Keyword.get_lazy(opts, :id, &uuid/0),
         agent_id <- Keyword.get_lazy(opts, :agent_id, &uuid/0),
         true <- valid_uuid?(id) and valid_uuid?(agent_id),
         sink <- Keyword.get(opts, :canonical_sink),
         true <- is_nil(sink) or (is_pid(sink) and Process.alive?(sink)),
         sink_timeout <- Keyword.get(opts, :canonical_timeout_ms, 5_000),
         true <- is_integer(sink_timeout) and sink_timeout in 1..60_000,
         %Provider{} = supplied <- opts[:provider],
         {:ok, provider} <- Provider.new(Map.from_struct(supplied)),
         model when is_binary(model) and byte_size(model) in 1..1_024 <-
           opts[:model] || provider.default_model,
         prompt when is_binary(prompt) and byte_size(prompt) in 1..2_097_152 <- opts[:prompt],
         true <- String.valid?(model) and String.valid?(prompt),
         {:ok, root} <- SwarmCode.Tools.Path.real_path(opts[:project_root]),
         true <- File.dir?(root),
         approval when approval in [:auto, :ask, :read_only] <-
           Keyword.get(opts, :approval, :ask),
         steps when is_integer(steps) and steps in 1..1_000 <- Keyword.get(opts, :max_steps, 40),
         timeout when is_integer(timeout) and timeout in 1..600_000 <-
           Keyword.get(opts, :request_timeout_ms, 600_000),
         subscriber <- Keyword.get(opts, :subscriber),
         true <- is_nil(subscriber) or is_pid(subscriber),
         settings <- Keyword.get(opts, :settings, %{command_timeout_ms: 120_000}),
         true <- is_map(settings) and not is_struct(settings),
         command_timeout <- Map.get(settings, :command_timeout_ms, 120_000),
         true <- is_integer(command_timeout) and command_timeout in 1..600_000,
         system <-
           Keyword.get(
             opts,
             :system,
             "You are a coding agent. Inspect the project, make precise changes, and verify them with tools. Ask for clarification when needed."
           ),
         true <- is_binary(system) and String.valid?(system) and byte_size(system) <= 65_000,
         effort <- Keyword.get(opts, :effort, "medium"),
         true <-
           is_nil(effort) or
             (is_binary(effort) and Regex.match?(SwarmCode.LLM.Efforts.key_format(), effort)),
         attachments <- Keyword.get(opts, :attachments, []),
         true <- valid_attachments?(attachments) do
      {:ok,
       %{
         id: id,
         agent_id: agent_id,
         canonical_sink: sink,
         canonical_timeout_ms: sink_timeout,
         provider: provider,
         model: model,
         prompt: prompt,
         attachments: attachments,
         project_root: root,
         approval: approval,
         max_steps: steps,
         request_timeout_ms: timeout,
         subscriber: subscriber,
         settings: Map.put(settings, :command_timeout_ms, command_timeout),
         system: system,
         effort: effort
       }}
    else
      _ -> {:error, :invalid_run_configuration}
    end
  rescue
    _ -> {:error, :invalid_run_configuration}
  end

  defp user_message(text, attachments) do
    images = Attachments.images(attachments)
    base = %{role: "user", content: text}
    if images == [], do: base, else: Map.put(base, :images, images)
  end

  defp valid_attachments?(attachments) when is_list(attachments) and length(attachments) <= 4 do
    Enum.all?(attachments, fn
      %{"id" => id} when is_binary(id) -> match?({:ok, _, _}, Attachments.path(id))
      _ -> false
    end)
  end

  defp valid_attachments?(_), do: false

  defp valid_uuid?(value) when is_binary(value) and byte_size(value) == 36,
    do: Regex.match?(~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, value)

  defp valid_uuid?(_), do: false

  defp uuid do
    <<a::32, b::16, c::12, d::14, e::48, _::6>> = :crypto.strong_rand_bytes(16)

    [hex(a, 8), hex(b, 4), "4" <> hex(c, 3), hex(Bitwise.bor(d, 0x8000), 4), hex(e, 12)]
    |> Enum.join("-")
  end

  defp hex(value, length),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(length, "0")
end
