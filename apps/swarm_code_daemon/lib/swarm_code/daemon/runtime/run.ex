defmodule SwarmCode.Daemon.Runtime.Run do
  @moduledoc """
  A supervised live model/tool loop. This is a runtime component, not a canonical
  database launcher. Its owner supplies the repository, credentials and policy;
  the service layer is responsible for durable admission and event persistence.
  """
  use GenServer, restart: :temporary
  alias SwarmCode.{LLM, Tools}
  alias SwarmCode.LLM.{Chunks, Request, Result}
  alias SwarmCode.Providers.Provider

  @terminal [:completed, :failed, :cancelled]
  @maximum_context 8 * 1_024 * 1_024
  @tool_result_bytes 65_000
  @maximum_calls 32
  @options ~w(provider model prompt project_root approval max_steps request_timeout_ms subscriber settings system effort)a

  def start_link(opts) do
    with {:ok, config} <- config(opts), do: GenServer.start_link(__MODULE__, config)
  end

  def snapshot(run), do: GenServer.call(run, :snapshot)
  def acknowledge(run, sequence), do: GenServer.call(run, {:acknowledge, sequence})
  def await(run, timeout \\ 5_000), do: GenServer.call(run, :await, timeout)
  def stop(run), do: GenServer.call(run, :stop)
  def pause(run), do: GenServer.call(run, :pause)
  def continue(run), do: GenServer.call(run, :continue)
  def steer(run, text), do: GenServer.call(run, {:steer, text})
  def resolve_approval(run, id, decision), do: GenServer.call(run, {:approval, id, decision})

  @impl true
  def init(config) do
    with {:ok, operations} <- Task.Supervisor.start_link() do
      Process.flag(:trap_exit, true)

      state =
        Map.merge(config, %{
          id: uuid(),
          operations: operations,
          op: nil,
          phase: :model,
          calls: [],
          messages: [%{role: "user", content: config.prompt}],
          steer: [],
          pending_approval: nil,
          status: :running,
          paused?: false,
          stopping?: false,
          steps: 0,
          sequence: 0,
          text: "",
          stream: Chunks.new(),
          reasoning: Chunks.new(),
          in_flight: [],
          delivery_stale?: false,
          error: nil,
          waiters: [],
          usage: %{input: 0, output: 0, cache_read: 0, cache_write: 0}
        })

      {:ok, emit(state, %{type: :started, model: config.model}), {:continue, :advance}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:advance, state), do: {:noreply, advance(state)}

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
             sequence <= state.sequence do
    {:reply, :ok, %{state | in_flight: Enum.reject(state.in_flight, &(&1 <= sequence))}}
  end

  def handle_call({:acknowledge, _}, _, state),
    do: {:reply, {:error, :invalid_acknowledgment}, state}

  def handle_call(:await, _, %{status: status} = state) when status in @terminal,
    do: {:reply, {:ok, outcome(state)}, state}

  def handle_call(:await, from, %{waiters: waiters} = state) when length(waiters) < 128,
    do: {:noreply, %{state | waiters: [from | waiters]}}

  def handle_call(:await, _, state), do: {:reply, {:error, :too_many_waiters}, state}

  def handle_call(:stop, _, %{status: status} = state) when status in @terminal,
    do: {:reply, :ok, state}

  def handle_call(:stop, _, state) do
    state = %{state | stopping?: true, pending_approval: nil}
    state = if state.op, do: cancel_operation(state), else: finish(state, :cancelled)
    {:reply, :ok, state}
  end

  def handle_call(:pause, _, %{status: status} = state) when status in @terminal,
    do: {:reply, {:error, :terminal}, state}

  def handle_call(:pause, _, state) do
    state = %{state | paused?: true}
    {:reply, :ok, if(state.op, do: state, else: hold(state))}
  end

  def handle_call(:continue, _, %{status: status} = state) when status in @terminal,
    do: {:reply, {:error, :terminal}, state}

  def handle_call(:continue, _, state) do
    status = if state.pending_approval, do: :waiting_approval, else: :running
    state = emit(%{state | paused?: false, status: status}, %{type: :continued, status: status})
    {:reply, :ok, advance(state)}
  end

  def handle_call({:steer, text}, _, %{status: status} = state)
      when status not in @terminal and is_binary(text) and byte_size(text) in 1..65_000 do
    if String.valid?(text) and length(state.steer) < 32 do
      {:reply, :ok, %{state | steer: state.steer ++ [%{role: "user", content: text}]}}
    else
      {:reply, {:error, :invalid_steer}, state}
    end
  end

  def handle_call({:steer, _}, _, state), do: {:reply, {:error, :invalid_steer}, state}

  def handle_call(
        {:approval, id, decision},
        _,
        %{pending_approval: %{id: id, call: call}} = state
      )
      when decision in [:allow, :deny] and not state.stopping? do
    state = %{state | pending_approval: nil, status: :running}
    state = emit(state, %{type: :approval_resolved, id: id, decision: decision})

    state =
      case decision do
        :allow ->
          advance(%{state | calls: [Map.put(call, :approved?, true) | state.calls]})

        :deny ->
          state |> tool_result(call, {:error, "tool execution denied by user"}) |> advance()
      end

    {:reply, :ok, state}
  end

  def handle_call({:approval, _, _}, _, state), do: {:reply, {:error, :stale_approval}, state}

  def handle_call(
        {:operation_event, token, event},
        {worker, _},
        %{op: %{token: token, task: %{pid: worker}}} = state
      ) do
    state =
      case event do
        %{type: :text_delta, text: text} ->
          %{state | stream: Chunks.append(state.stream, text)}

        %{type: :text_reset} ->
          %{state | stream: Chunks.new(), text: ""}

        %{type: :reasoning_delta, text: text} ->
          %{state | reasoning: Chunks.append(state.reasoning, text)}

        %{type: :reasoning_reset} ->
          %{state | reasoning: Chunks.new()}

        _ ->
          state
      end

    {:reply, :ok, emit(state, event)}
  end

  def handle_call({:operation_event, _, _}, _, state), do: {:reply, :ok, state}

  @impl true
  def handle_info({ref, result}, %{op: %{task: %{ref: ref}} = op} = state),
    do: {:noreply, %{state | op: %{op | result: {:result, result}}}}

  def handle_info({:DOWN, ref, :process, _, reason}, %{op: %{task: %{ref: ref}} = op} = state) do
    Process.cancel_timer(op.timer)
    state = %{state | op: nil}

    state =
      cond do
        state.stopping? ->
          finish(state, :cancelled)

        reason != :normal ->
          operation_result(state, op, {:error, "operation terminated"})

        op.result == nil ->
          operation_result(state, op, {:error, "operation ended without a result"})

        true ->
          operation_result(state, op, elem(op.result, 1))
      end

    {:noreply, advance(state)}
  end

  def handle_info({:operation_timeout, token}, %{op: %{token: token}} = state) do
    state = %{state | error: :operation_timeout, stopping?: true} |> cancel_operation()
    {:noreply, state}
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
    do: Map.put(status, :state, Map.take(status.state, [:id, :status, :steps, :sequence]))

  defp advance(%{status: status} = state) when status in @terminal, do: state
  defp advance(%{op: op} = state) when not is_nil(op), do: state
  defp advance(%{stopping?: true} = state), do: finish(state, :cancelled)
  defp advance(%{paused?: true} = state), do: hold(state)
  defp advance(%{pending_approval: pending} = state) when not is_nil(pending), do: state
  defp advance(%{calls: [call | rest]} = state), do: admit_tool(%{state | calls: rest}, call)

  defp advance(state) do
    messages = state.messages ++ state.steer
    state = %{state | messages: messages, steer: [], phase: :model, status: :running}

    cond do
      state.steps >= state.max_steps ->
        finish(state, :failed, :step_limit)

      length(messages) > 1_024 or :erlang.external_size(messages) > @maximum_context ->
        finish(state, :failed, :context_limit)

      true ->
        launch_model(state)
    end
  end

  defp launch_model(state) do
    state = %{state | stream: Chunks.new(), reasoning: Chunks.new(), text: ""}

    request = %Request{
      provider: state.provider,
      model: state.model,
      system: state.system,
      messages: state.messages,
      tools: Tools.specs(),
      effort: state.effort,
      deadline_ms: state.request_timeout_ms
    }

    state =
      emit(%{state | steps: state.steps + 1}, %{type: :model_started, step: state.steps + 1})

    launch(state, :model, nil, state.request_timeout_ms + 1_000, fn notify ->
      LLM.stream(request, fn event -> notify.(model_event(event)) end)
    end)
  end

  defp admit_tool(state, call) do
    cond do
      Map.has_key?(call, :args_error) ->
        state |> tool_result(call, {:error, call.args_error}) |> advance()

      true ->
        case Tools.permission(call.name, call.args) do
          {:error, reason} ->
            state |> tool_result(call, {:error, reason}) |> advance()

          {:ok, permission} ->
            cond do
              permission == :read or state.approval == :auto or Map.get(call, :approved?) == true ->
                launch_tool(state, call)

              state.approval == :read_only ->
                state
                |> tool_result(call, {:error, "tool denied by read-only policy"})
                |> advance()

              true ->
                approval = %{id: uuid(), call: call}

                emit(%{state | pending_approval: approval, status: :waiting_approval}, %{
                  type: :approval_required,
                  id: approval.id,
                  tool: call.name,
                  permission: permission,
                  arguments: preview_arguments(call.args)
                })
            end
        end
    end
  end

  defp launch_tool(state, call) do
    context = %{project_root: state.project_root, settings: state.settings}
    {timeout, _} = Tools.RunCommand.timeout_for(call.args, context)
    state = emit(state, %{type: :tool_started, id: call.id, tool: call.name})

    launch(state, :tool, call, timeout + 3_000, fn notify ->
      Tools.run(call.name, call.args, context, fn progress, text ->
        notify.(%{type: :tool_progress, id: call.id, progress: progress, text: bounded(text)})
      end)
    end)
  end

  defp launch(state, kind, call, timeout, function) do
    owner = self()
    token = make_ref()

    task =
      Task.Supervisor.async_nolink(state.operations, fn ->
        function.(fn event ->
          GenServer.call(owner, {:operation_event, token, event}, :infinity)
        end)
      end)

    timer = Process.send_after(self(), {:operation_timeout, token}, timeout)
    %{state | op: %{kind: kind, call: call, task: task, token: token, timer: timer, result: nil}}
  end

  defp operation_result(state, %{kind: :model}, {:ok, %Result{} = result}) do
    state = %{
      state
      | usage: add_usage(state.usage, result.usage),
        text: result.text,
        stream: Chunks.new(result.text),
        reasoning: Chunks.new(result.reasoning)
    }

    cond do
      result.stop_reason == "refusal" ->
        finish(state, :failed, :provider_refusal)

      result.stop_reason == "max_tokens" ->
        finish(state, :failed, :response_limit)

      not valid_calls?(result.tool_calls) ->
        finish(state, :failed, :invalid_tool_calls)

      true ->
        assistant = %{role: "assistant", content: result.text, tool_calls: result.tool_calls}

        assistant =
          if result.provider_blocks == [],
            do: assistant,
            else: Map.put(assistant, :provider_blocks, result.provider_blocks)

        state = %{
          state
          | messages: state.messages ++ [assistant],
            text: result.text,
            calls: result.tool_calls
        }

        if result.tool_calls == [] and state.steer == [],
          do: finish(state, :completed),
          else: state
    end
  end

  defp operation_result(state, %{kind: :model}, {:error, reason}),
    do: finish(state, :failed, {:provider_failed, bounded(reason)})

  defp operation_result(state, %{kind: :tool, call: call}, result),
    do: tool_result(state, call, result)

  defp operation_result(state, _, _), do: finish(state, :failed, :invalid_operation_result)

  defp tool_result(state, call, result) do
    {text, error?} =
      case result do
        {:ok, text} when is_binary(text) -> {bounded(text), false}
        {:error, reason} -> {"Error: " <> bounded(reason), true}
        _ -> {"Error: invalid tool result", true}
      end

    message = %{
      role: "tool",
      tool_call_id: call.id,
      name: call.name,
      content: text,
      is_error: error?
    }

    emit(%{state | messages: state.messages ++ [message]}, %{
      type: :tool_completed,
      id: call.id,
      tool: call.name,
      text: text,
      error?: error?
    })
  end

  defp cancel_operation(%{op: %{kind: :tool, call: %{name: "run_command"}, task: task}} = state) do
    send(task.pid, :swarm_code_tool_cancel)
    state
  end

  defp cancel_operation(%{op: %{task: task}} = state) do
    Process.exit(task.pid, :kill)
    state
  end

  defp hold(%{status: :paused} = state), do: state
  defp hold(state), do: emit(%{state | status: :paused}, %{type: :paused})

  defp finish(state, status, error \\ nil)
  defp finish(%{status: status} = state, _, _) when status in @terminal, do: state

  defp finish(state, status, error) do
    status = if state.error == :operation_timeout, do: :failed, else: status

    state = %{
      state
      | status: status,
        error: error || state.error,
        pending_approval: nil,
        calls: [],
        steer: []
    }

    state = emit(state, %{type: :finished, result: outcome(state)})
    Enum.each(state.waiters, &GenServer.reply(&1, {:ok, outcome(state)}))
    %{state | waiters: []}
  end

  defp emit(state, event) do
    sequence = state.sequence + 1
    state = %{state | sequence: sequence}

    cond do
      not is_pid(state.subscriber) or state.delivery_stale? ->
        state

      length(state.in_flight) < 32 and :erlang.external_size(event) <= @tool_result_bytes ->
        send(state.subscriber, {:run_event, state.id, sequence, event})
        %{state | in_flight: [sequence | state.in_flight]}

      true ->
        send(state.subscriber, {:run_snapshot_required, state.id, sequence})
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
      status: state.status,
      steps: state.steps,
      sequence: state.sequence,
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
             (is_binary(effort) and Regex.match?(SwarmCode.LLM.Efforts.key_format(), effort)) do
      {:ok,
       %{
         provider: provider,
         model: model,
         prompt: prompt,
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

  defp uuid do
    <<a::32, b::16, c::12, d::14, e::48, _::6>> = :crypto.strong_rand_bytes(16)

    [hex(a, 8), hex(b, 4), "4" <> hex(c, 3), hex(Bitwise.bor(d, 0x8000), 4), hex(e, 12)]
    |> Enum.join("-")
  end

  defp hex(value, length),
    do: value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(length, "0")
end
