defmodule SwarmCode.Domain.Engine.AgentServer do
  @moduledoc """
  One agent's loop as a non-blocking state machine:
  think (llm op) → run every tool call as its own op (concurrently) → think again,
  until the model answers without tool calls or `max_turns` is reached.
  """
  use GenServer, restart: :temporary

  alias SwarmCode.Domain.Engine.{AgentSup, Context, Operation, RunServer}
  alias SwarmCode.Domain.LLM
  alias SwarmCode.Domain.{Pricing, Tools}
  alias SwarmCode.Domain.Tools.Ref

  @type args :: %{
          run_id: String.t(),
          node_id: String.t(),
          name: String.t(),
          role: String.t(),
          system: String.t(),
          messages: [map()],
          model: %{provider: struct(), model: String.t()},
          tools: [SwarmCode.Domain.Tools.Ref.t()],
          depth: non_neg_integer(),
          max_turns: pos_integer(),
          project_root: String.t(),
          approval_mode: String.t(),
          run_kind: String.t() | nil,
          effort: String.t(),
          settings: struct()
        }

  def start_link(args),
    do: GenServer.start_link(__MODULE__, args, name: via(args.node_id), hibernate_after: 15_000)

  def via(node_id), do: {:via, Registry, {SwarmCode.Domain.Registry, {:agent, node_id}}}

  @doc """
  Steers a running agent: `text` is appended to its message list as a user message
  right before its next LLM call. If the agent is waiting on an LLM response the
  message waits for the turn after; if it is waiting on tool results it goes out
  together with them.
  """
  @spec user_message(pid() | String.t(), String.t(), [map()]) :: :ok
  def user_message(pid, text, images \\ [])

  def user_message(pid, text, images) when is_pid(pid),
    do: GenServer.cast(pid, {:user_message, text, images})

  def user_message(node_id, text, images),
    do: GenServer.cast(via(node_id), {:user_message, text, images})

  @doc """
  Spec 45 §5.2: the agent finishes the step it is on (an LLM stream or a batch
  of tool ops) and then holds before its next think step. Nothing is killed.
  """
  @spec pause(pid() | String.t()) :: :ok
  def pause(pid) when is_pid(pid), do: GenServer.cast(pid, :pause)
  def pause(node_id), do: GenServer.cast(via(node_id), :pause)

  @doc "Spec 45 §5.2: a held agent takes its next step; a paused one that is mid-step just forgets the pause."
  @spec continue(pid() | String.t()) :: :ok
  def continue(pid) when is_pid(pid), do: GenServer.cast(pid, :continue)
  def continue(node_id), do: GenServer.cast(via(node_id), :continue)

  @impl true
  def init(args) do
    state =
      Map.merge(args, %{
        turn: 0,
        pending: %{},
        calls: %{},
        order: [],
        results: %{},
        usage: %{input: 0, output: 0, cache_read: 0, cache_write: 0},
        cost: nil,
        llm_node: nil,
        steer: [],
        status: :thinking,
        nudges: 0,
        # spec 55 T18 (55a A13): the last-turn notice is sent once per agent.
        notice_sent?: false,
        # spec 55 T23: the steer's extra turn (spec 43 §1.5) was written with
        # `%{state | steer_turn?: true}` but the key was never in the state —
        # a KeyError killed the agent at exactly the turn A13 is about.
        steer_turn?: false,
        # Spec 45 §5.2: `paused?` is the request, `held` says a step was
        # actually withheld (`:llm`) and has to be started on continue.
        paused?: Map.get(args, :paused?, false),
        held: nil,
        require_tool: Map.get(args, :require_tool),
        ops_sup: AgentSup.ops_sup(args.node_id),
        tool_specs: Tools.specs(args.tools)
      })

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state), do: start_llm(state)

  @impl true
  def handle_cast({:user_message, text, images}, state) do
    message = %{role: "user", content: to_string(text)}
    message = if images == [], do: message, else: Map.put(message, :images, images)
    {:noreply, %{state | steer: state.steer ++ [Context.count(message)]}}
  end

  # Spec 45 §5.2: the flag is read by `start_llm/1`, the one place a new step
  # begins — an LLM stream or a batch of tool ops in flight runs to its end.
  def handle_cast(:pause, state), do: {:noreply, %{state | paused?: true}}

  def handle_cast(:continue, %{held: :llm} = state) do
    RunServer.update_node(state.run_id, state.node_id, %{status: "running"})
    start_llm(%{state | paused?: false, held: nil})
  end

  def handle_cast(:continue, state), do: {:noreply, %{state | paused?: false}}

  @impl true
  # The llm op finished with a result. Spec 51 §6.3: there is no `:op_event`
  # clause any more — streamed text and reasoning go straight to the RunServer
  # (spec 43 §1.1) and usage is read from `Result.usage` right here.
  def handle_info({:op_done, id, {:ok, %LLM.Result{} = result}}, %{llm_node: id} = state) do
    # Spec 53b §5: the two cache counters are part of `input` (the prompt is the
    # sum of the three, whatever it was billed as) and are carried beside it so
    # the fresh part can be priced at the input rate and the rest at its own.
    usage = %{
      input: state.usage.input + result.usage.input,
      output: state.usage.output + result.usage.output,
      cache_read: Map.get(state.usage, :cache_read, 0) + Map.get(result.usage, :cache_read, 0),
      cache_write: Map.get(state.usage, :cache_write, 0) + Map.get(result.usage, :cache_write, 0)
    }

    cost =
      Pricing.cost(state.settings.pricing, state.model.model, usage.input, usage.output, %{
        read: usage.cache_read,
        write: usage.cache_write
      })

    RunServer.update_node(state.run_id, state.node_id, %{
      tokens_in: usage.input,
      tokens_out: usage.output,
      cache_read: usage.cache_read,
      cache_write: usage.cache_write,
      cost_usd: cost
    })

    messages = state.messages ++ [assistant_message(result)]

    state = %{state | usage: usage, cost: cost, messages: messages, llm_node: nil}

    cond do
      # Spec 53b §3: a classifier decline is an HTTP 200 with `stop_reason:
      # "refusal"` and an empty (pre-output) or partial (mid-stream) body — the
      # partial is discarded, not treated as an answer. Without this the run
      # reported a finished turn that said nothing, and in a swarm the empty
      # report propagated to the Lead. Branch on `stop_reason`, never on
      # `stop_details`, which is informational and can be null on a real
      # refusal.
      result.stop_reason == "refusal" ->
        finish(state, {:error, refusal_message(result)})

      result.tool_calls != [] ->
        dispatch_tools(state, result.tool_calls)

      # Spec 36 §A8: the nudge is a turn like any other. Without this check an
      # agent that never produced its structured output ran up to two turns
      # past its cap — `continue_after_tools/1` applies exactly the same test.
      state.require_tool && state.turn >= state.max_turns ->
        finish(state, {:ok, wrap_up_text(state)})

      # A workflow worker with a schema must answer through the tool (spec 09 §3.2).
      state.require_tool && state.nudges < 2 ->
        nudge = %{role: "user", content: "Call #{state.require_tool} now."}
        start_llm(%{state | nudges: state.nudges + 1, steer: state.steer ++ [nudge]})

      state.require_tool ->
        finish(state, {:error, "no structured output"})

      # Spec 53b §3: `max_tokens` now caps thinking *plus* text, so a turn can
      # end here having produced only reasoning. Delivered as `{:ok, ""}` that
      # reads as a complete, empty answer.
      result.stop_reason == "max_tokens" and String.trim(result.text) == "" ->
        finish(state, {:error, "the answer hit max_tokens before any text was produced"})

      # spec 60 T5: a steer that landed while the final answer streamed (spec 55 7.4 covered tools only).
      state.steer != [] and state.turn < state.max_turns ->
        start_llm(state)

      state.steer != [] and not Map.get(state, :steer_turn?, false) ->
        start_llm(%{state | max_turns: state.max_turns + 1, steer_turn?: true})

      true ->
        finish(state, {:ok, result.text})
    end
  end

  # The llm op failed.
  def handle_info({:op_done, id, {:error, msg}}, %{llm_node: id} = state) do
    finish(%{state | llm_node: nil}, {:error, msg})
  end

  # A tool op finished.
  def handle_info({:op_done, id, result}, state) do
    if Map.has_key?(state.pending, id) do
      {text, error?} =
        case result do
          {:ok, text} -> {to_string(text), false}
          {:error, msg} -> {"Error: " <> to_string(msg), true}
        end

      state = %{
        state
        | pending: Map.delete(state.pending, id),
          results: Map.put(state.results, id, {text, error?})
      }

      if map_size(state.pending) == 0, do: after_tools(state), else: {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Spec 30 §2: provider continuation state (Anthropic's signed thinking blocks)
  # rides along with the assistant turn it belongs to, in memory only.
  #
  # Spec 53b §4: the history is append-only. Earlier turns used to give their
  # blocks up on every request, which is the one edit preserved thinking
  # rejects — a thinking block removed from anywhere but the *front* of the run
  # invalidates every later block (400 `invalid_request_error` on accounts
  # created on or after 2026-08-31), and rewriting the previous assistant turn
  # moved the cache breakpoint back a turn on every single request. The old
  # rationale is wrong on the current API besides: a block the receiving model
  # cannot read is dropped server-side, before pricing, so there are no input
  # tokens to save by stripping it here. `Context.trim/2` still drops whole
  # exchanges, but only from the oldest end, which is the one removal the API
  # allows.
  defp assistant_message(%LLM.Result{provider_blocks: []} = result),
    do: Context.count(%{role: "assistant", content: result.text, tool_calls: result.tool_calls})

  defp assistant_message(%LLM.Result{} = result) do
    Context.count(%{
      role: "assistant",
      content: result.text,
      tool_calls: result.tool_calls,
      provider_blocks: result.provider_blocks
    })
  end

  # Spec 53b §3: the category names what was declined ("cyber", "bio",
  # "reasoning_extraction", …) and is what tells the user whether re-asking
  # differently is worth anything. It is optional and can be null on a real
  # refusal, so the message reads without it too.
  defp refusal_message(%LLM.Result{stop_details: %{"category" => category}})
       when is_binary(category) and category != "",
       do: "the model declined this request (#{category})"

  defp refusal_message(_result), do: "the model declined this request"

  # Spec 51 §6.8: one indexed read per LLM call (0.1 ms) so a key or base URL
  # edited in Settings reaches the next request; the model *name* stays the
  # run's; a deleted row keeps the snapshot. Before this, a rotated key failed
  # every run in flight — the row was resolved once at run start, a 401 is not
  # retried, and the run finished `failed`.
  defp refresh_provider(%{provider: %{id: id}} = model) when is_binary(id) do
    case SwarmCode.Domain.Providers.get_cached(id) do
      %SwarmCode.Domain.Providers.Provider{} = fresh -> %{model | provider: fresh}
      nil -> model
    end
  end

  defp refresh_provider(model), do: model

  # Spec 51 §5.5: an agent that must answer through a tool is told to call it.
  defp last_turn_notice(%{require_tool: tool}) when is_binary(tool),
    do: "You have one turn left. Call #{tool} now with what you know."

  defp last_turn_notice(_state),
    do:
      "You have one turn left. Stop exploring and give your final answer now with what you know."

  # Spec 45 §5.2: a paused agent holds here — before the next think step, with
  # its messages complete — and `handle_cast(:continue, …)` calls back in.
  defp start_llm(%{paused?: true} = state) do
    RunServer.update_node(state.run_id, state.node_id, %{status: "paused"})
    {:noreply, %{state | held: :llm, status: :paused}}
  end

  defp start_llm(state) do
    turn = state.turn + 1

    budget = Context.budget(state.model.model)

    # spec 55 T18 (55a A13): the notice goes to the *request*, once; never into the
    # durable history (it used to be stored and repeated on the steer's extra turn).
    notice =
      if turn == state.max_turns and state.max_turns > 1 and not state.notice_sent?,
        do: [%{role: "user", content: last_turn_notice(state)}],
        else: []

    # Spec 43 §1.4: the compressed history is what the agent keeps, not only
    # what it sends — an over-budget agent used to hold every old tool body on
    # its heap for life. Idempotent: a placeholder is never compressed again,
    # so the model sees exactly what it saw before.
    messages = Context.compress(state.messages ++ state.steer, budget)

    state = %{
      state
      | messages: messages,
        steer: [],
        notice_sent?: state.notice_sent? or notice != [],
        model: refresh_provider(state.model)
    }

    request = %LLM.Request{
      provider: state.model.provider,
      model: state.model.model,
      system: state.system,
      messages: Context.trim(state.messages ++ notice, budget),
      tools: state.tool_specs,
      # Spec 45 §3.3: the one effort → request site every agent goes through
      # (chat, swarm, judge, workflow, research tier, scheduled) — a key the
      # model's list lacks becomes that list's default.
      effort:
        LLM.Efforts.normalise_key(
          Map.get(state, :effort),
          state.model.provider,
          state.model.model
        )
    }

    # Spec 26 §5.3: only an agent that asked for one; the struct default (8 192)
    # is right for every agent whose answer is prose plus small tool calls.
    request =
      case Map.get(state, :max_tokens) do
        n when is_integer(n) and n > 0 -> %{request | max_tokens: n}
        _other -> request
      end

    RunServer.update_node(state.run_id, state.node_id, %{turn: turn, max_turns: state.max_turns})

    {:ok, id} =
      Operation.start(state.ops_sup, self(), %{
        run_id: state.run_id,
        parent_id: state.node_id,
        op_type: "llm",
        title: "thinking",
        work: {:llm, request}
      })

    {:noreply, %{state | llm_node: id, turn: turn, status: :thinking}}
  end

  # Spec 13 §11 A-1: the per-agent tool list is the allow-list, not a hint. A
  # name the model invented (or remembered from another agent) used to be
  # resolved from the global registry and executed — a Lead with no edit tools,
  # a plan-mode agent or a read-only workflow worker could call `write_file`,
  # `run_command` or `workflow_save`. Only the interaction tools that are never
  # part of a per-agent list may still be resolved this way; everything else
  # takes `operation.ex`'s "unknown tool …" path.
  @fallback_tools ~w(structured_output ask_user)

  defp fallback_ref(name) do
    if name in @fallback_tools do
      case Tools.get(name) do
        {:ok, ref} -> ref
        :error -> nil
      end
    end
  end

  defp dispatch_tools(state, tool_calls) do
    ctx = %{
      project_root: state.project_root,
      run_id: state.run_id,
      agent_node_id: state.node_id,
      depth: state.depth,
      # Spec 51 §6.11: the per-tool limits are read live, once per tool batch
      # (0.21–0.26 ms) — the approval mode has been live per op since spec 39,
      # and a `command_timeout_ms` raised in Settings while a long run is going
      # used to apply only to the next run.
      settings: SwarmCode.Domain.Settings.get_cached(),
      approval_mode: state.approval_mode,
      project_id: Map.get(state, :project_id),
      # Spec 39 §1.1: the run kind, so a research op keeps its in-memory mode.
      run_kind: Map.get(state, :run_kind),
      conversation_id: Map.get(state, :conversation_id)
    }

    {pending, calls, order} =
      Enum.reduce(tool_calls, {%{}, %{}, []}, fn call, {pending, calls, order} ->
        ref =
          case Enum.find(state.tools, &(&1.name == call.name)) do
            nil -> fallback_ref(call.name)
            found -> found
          end

        # Normalise the argument names before anything reads them, so the op's
        # title, its permission and the tool itself all see the same map — a
        # `write_file` called with `file_path` used to render as `write ` with no
        # path even when it succeeded.
        args = if ref, do: Tools.alias_args(ref, call.args), else: call.args
        title = if ref, do: Ref.title(ref, args), else: "tool " <> call.name
        op_type = if ref, do: Ref.op_type(ref), else: call.name

        # The provider could not decode this call's `arguments` JSON. Running the
        # tool with `%{}` reports a missing argument, which the model reads as
        # "add the argument" and resends the same broken call; the decode reason
        # is what it can actually act on.
        work =
          case call[:args_error] do
            nil -> {:tool, ref, args, ctx}
            reason -> {:invalid_args, call.name, reason, call[:args_raw]}
          end

        title = if call[:args_error], do: "tool " <> call.name, else: title

        {:ok, op_id} =
          Operation.start(state.ops_sup, self(), %{
            run_id: state.run_id,
            parent_id: state.node_id,
            op_type: op_type,
            title: title,
            work: work
          })

        {Map.put(pending, op_id, call), Map.put(calls, op_id, call), order ++ [op_id]}
      end)

    {:noreply,
     %{
       state
       | pending: pending,
         calls: calls,
         order: order,
         results: %{},
         status: :awaiting_tools
     }}
  end

  defp after_tools(state) do
    structured =
      state.require_tool &&
        Enum.find_value(state.order, fn op_id ->
          call = Map.fetch!(state.calls, op_id)
          {text, error?} = Map.fetch!(state.results, op_id)
          if call.name == state.require_tool and not error?, do: text
        end)

    if structured do
      finish(state, {:ok, structured})
    else
      continue_after_tools(state)
    end
  end

  defp continue_after_tools(state) do
    tool_messages =
      Enum.map(state.order, fn op_id ->
        call = Map.fetch!(state.calls, op_id)
        {text, error?} = Map.fetch!(state.results, op_id)

        Context.count(%{
          role: "tool",
          tool_call_id: call.id,
          name: call.name,
          content: text,
          is_error: error?
        })
      end)

    state = %{
      state
      | messages: state.messages ++ tool_messages,
        calls: %{},
        order: [],
        results: %{}
    }

    cond do
      state.turn < state.max_turns ->
        start_llm(state)

      # Spec 43 §1.5 (B5): the user steered during the last turn — their
      # message is already in the transcript, so it is read: one extra turn,
      # once (`max_turns + 1` makes the next check fail for good).
      state.steer != [] and not Map.get(state, :steer_turn?, false) ->
        start_llm(%{state | max_turns: state.max_turns + 1, steer_turn?: true})

      true ->
        # Out of turns but the model still wanted tools: hand back what it has
        # instead of failing the whole run.
        finish(state, {:ok, wrap_up_text(state)})
    end
  end

  defp wrap_up_text(state) do
    state.messages
    |> Enum.reverse()
    |> Enum.find_value(fn m ->
      if m[:role] == "assistant" and is_binary(m[:content]) and String.trim(m[:content]) != "",
        do: m[:content]
    end)
    |> case do
      nil -> "Stopped after #{state.max_turns} turns; no answer was produced."
      text -> text <> "\n\n_(Stopped after #{state.max_turns} turns; partial result above.)_"
    end
  end

  defp finish(state, result) do
    RunServer.agent_finished(state.run_id, state.node_id, result)
    {:stop, :normal, %{state | status: :done}}
  end
end
