defmodule SwarmCode.Domain.Engine.AgentServer do
  @moduledoc """
  One agent's loop as a non-blocking state machine:
  think (llm op) → run every tool call as its own op (concurrently) → think again,
  until the model answers without tool calls or `max_turns` is reached.
  """
  use GenServer, restart: :temporary
  require Logger

  alias SwarmCode.Domain.Engine.{AgentSup, Context, Operation, Prompts, RunServer, Telemetry}
  alias SwarmCode.Domain.Projects.Project
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
        # spec 66 T20: `slots` is op_id → the index the model emitted that call
        # at; `serial_queue` holds the calls of tools that must not run beside
        # anything else, and `serial_running` the one of them that is in flight.
        slots: %{},
        serial_queue: [],
        serial_running: nil,
        # spec 66 T14: the last turn an auto-compaction was launched at, and the
        # one-shot flag of the context-overflow retry.
        last_compact_turn: nil,
        overflow_retried?: false,
        # spec 67 T24 (G26): the turn this agent last compacted its *own*
        # history at, so a tail that is still over the threshold cannot buy a
        # summary call every single turn.
        last_inline_compact_turn: nil,
        # spec 67 T26 (G29): the `<environment>` block this agent last sent. The
        # system prompt carries the one that was true at run start; a branch
        # switch or a mode change re-emits it as a user message, never by
        # rewriting the system block (which is the Anthropic cache prefix).
        last_env: Map.get(args, :env),
        # spec 67 T11 (G27): the prompt size the provider *reported* for the
        # last call (input + both cache counters), against which the compaction
        # threshold is judged — `Context.estimate_tokens/1` sees neither the
        # system prompt nor the tool schemas and reads ~60 % of the truth.
        last_input: 0,
        usage: %{input: 0, output: 0, cache_read: 0, cache_write: 0},
        cost: nil,
        llm_node: nil,
        steer: [],
        status: :thinking,
        nudges: 0,
        # spec 55 T18 (55a A13): the last-turn notice is sent once per agent.
        notice_sent?: false,
        # spec 72 B1: two-turn wrap-up notice sent once per agent.
        wrap_up_sent?: false,
        # spec 55 T23: the steer's extra turn (spec 43 §1.5) was written with
        # `%{state | steer_turn?: true}` but the key was never in the state —
        # a KeyError killed the agent at exactly the turn A13 is about.
        steer_turn?: false,
        # spec 73 T9 (F6): set by the RunServer's `{:mailbox_pending, _}` when
        # a peer message is queued for this agent; the think step only asks
        # the state owner for its mailbox when there is something to drain.
        mailbox_pending?: false,
        # spec 70 A2: doom loop detection — bounded list of recent
        # {tool_name, args_hash} tuples, newest first.
        recent_calls: [],
        doom_notice_sent?: false,
        # Spec 45 §5.2: `paused?` is the request, `held` says a step was
        # actually withheld (`:llm`) and has to be started on continue.
        paused?: Map.get(args, :paused?, false),
        held: nil,
        require_tool: Map.get(args, :require_tool),
        # spec 72 A5: prewalk model hand-off state
        prewalk?: Map.get(args, :prewalk, false),
        prewalk_model: Map.get(args, :prewalk_model),
        prewalked?: false,
        ops_sup: AgentSup.ops_sup(args.node_id),
        tool_specs: Tools.specs(args.tools)
      })

    # spec 70 A1: the system prompt and tool schemas the provider will see
    # but Context.estimate_tokens/1 does not — bytes/4 like the rest, so
    # the first-turn estimate is in the same ballpark as the provider's
    # reported usage that replaces it from turn 2 on.
    prompt_overhead =
      div(
        byte_size(args.system || "") +
          byte_size(Jason.encode!(state.tool_specs)),
        4
      )

    state = Map.put(state, :prompt_overhead, prompt_overhead)

    # spec 70 E2: structured telemetry — Logger metadata + agent span start.
    Telemetry.put_agent_metadata(args.run_id, args.node_id)

    telemetry_start =
      Telemetry.span_start(Telemetry.agent_span(), %{
        run_id: args.run_id,
        agent_id: args.node_id,
        role: args.role,
        name: args.name
      })

    state = Map.put(state, :telemetry_start, telemetry_start)

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

    # spec 73 T48: each call is priced at the model that made it and the costs
    # add up — the cumulative `usage` used to be re-priced at `state.model`,
    # so after a prewalk hand-off (spec 72 A5) an implementer's strong-model
    # planning tokens showed at the cheap model's rate, or as no cost at all
    # when that model has no pricing row. `Pricing.cost/5` is linear per call,
    # so the running sum is exact.
    cost =
      Pricing.add(
        state.cost,
        Pricing.cost(
          state.settings.pricing,
          state.model.model,
          result.usage.input,
          result.usage.output,
          %{
            read: Map.get(result.usage, :cache_read, 0),
            write: Map.get(result.usage, :cache_write, 0)
          }
        )
      )

    RunServer.update_node(state.run_id, state.node_id, %{
      tokens_in: usage.input,
      tokens_out: usage.output,
      cache_read: usage.cache_read,
      cache_write: usage.cache_write,
      cost_usd: cost
    })

    messages = state.messages ++ [assistant_message(result)]

    # spec 66 T14: the overflow retry is one per overflow, not one per agent.
    state = %{
      state
      | usage: usage,
        cost: cost,
        messages: messages,
        llm_node: nil,
        overflow_retried?: false,
        # spec 67 T11 (G27): the exact prompt size of the call that just
        # returned — `input` is history + system prompt + tool schemas + both
        # cache counters — for `auto_compact?/2` to judge against.
        last_input: result.usage.input
    }

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
      # spec 73 T49: the same typed reason the tool-call cap passes (spec 72 B2)
      # — without it the worker was persisted as `done` and the parent's text
      # lost its '(turn limit)' suffix.
      state.require_tool && state.turn >= state.max_turns ->
        finish(state, {:ok, wrap_up_text(state)}, :turn_budget)

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

  # The llm op failed. spec 67 T30 (G42): with a kind beside the message when
  # the provider produced one.
  def handle_info({:op_done, id, {:error, kind, msg}}, %{llm_node: id} = state)
      when is_atom(kind),
      do: llm_failed(id, kind, msg, state)

  def handle_info({:op_done, id, {:error, msg}}, %{llm_node: id} = state),
    do: llm_failed(id, LLM.Error.classify(nil, nil, msg), msg, state)

  # A tool op finished.
  def handle_info({:op_done, id, result}, state) do
    if Map.has_key?(state.pending, id) do
      # spec 67 T34 (G35): a third element is the MCP images of this result.
      {text, error?, images} =
        case result do
          {:ok, text, images} when is_list(images) -> {to_string(text), false, images}
          {:ok, text} -> {to_string(text), false, []}
          {:error, msg} -> {"Error: " <> to_string(msg), true, []}
          {:error, _kind, msg} -> {"Error: " <> to_string(msg), true, []}
        end

      state = %{
        state
        | pending: Map.delete(state.pending, id),
          results: Map.put(state.results, id, {text, error?, images})
      }

      # spec 66 T20: the serial calls are a queue — the next one starts here,
      # when the previous one is done, and never earlier.
      state =
        if Map.get(state, :serial_running) == id, do: start_next_serial(state), else: state

      if tools_done?(state),
        do: after_tools(%{state | order: ordered_ops(state)}),
        else: {:noreply, state}
    else
      {:noreply, state}
    end
  end

  # spec 70 C6: a background sub-agent finished and its result is injected into
  # this agent's steer queue. The next LLM turn picks it up.
  # spec 73 T9 (F6): a peer message is waiting in the RunServer's mailbox;
  # the next think step drains it (`drain_mailbox/1`).
  def handle_info({:mailbox_pending, _node_id}, state),
    do: {:noreply, %{state | mailbox_pending?: true}}

  def handle_info({:background_result, text}, state) do
    message = Context.count(%{role: "user", content: text})
    {:noreply, %{state | steer: state.steer ++ [message]}}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp llm_failed(id, kind, msg, state) do
    state = %{state | llm_node: nil}

    # spec 66 T14: "prompt is too long" is not a failed run — it is an estimate
    # that was wrong. Force the compression and cut passes to bite (0.6 of the
    # budget, not 1.0) and think once more. A second overflow fails as before.
    # spec 67 T30 (G42): the trigger is the kind now; `LLM.context_overflow?/1`
    # is what the classifier reads to arrive at it.
    if kind == :context_overflow and not Map.get(state, :overflow_retried?, false) do
      # spec 67 T12 (B39): the op this writes to has already finished
      # (`Operation.run/5` settled it), and the retry opens a *new* llm node, so
      # the `retrying → running` reset in `put_stream/4` never fired: the node
      # stayed `retrying` for the life of the run and counted as live in the
      # pane, the timeline and the transcript. It failed — say so — and the
      # signal that something is being retried goes on the agent's own node,
      # which is the row that is still running.
      RunServer.update_node(state.run_id, id, %{
        status: "failed",
        detail: "context overflow — trimmed and retried"
      })

      RunServer.update_node(state.run_id, state.node_id, %{
        detail: "context overflow — trimmed and retried"
      })

      budget = trunc(Context.budget(state.model.model, state.settings) * 0.6)

      messages =
        state.messages
        |> Context.compress(budget)
        |> Context.trim(budget)

      start_llm(%{
        state
        | messages: messages,
          overflow_retried?: true,
          # The failed attempt does not cost the agent one of its turns, the
          # way a transport retry does not (spec 11 §7.3).
          turn: max(state.turn - 1, 0)
      })
    else
      finish(state, {:error, kind, msg})
    end
  end

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

  # spec 72 B1: two-turn wrap-up notice at max_turns - 1.
  defp wrap_up_notice(%{require_tool: tool}) when is_binary(tool),
    do:
      "You have two turns left. Start wrapping up — prepare your " <>
        "#{tool} call for the next turn."

  defp wrap_up_notice(_state),
    do:
      "You have two turns left. Start wrapping up your work and " <>
        "prepare your final answer for the next turn."

  # Spec 45 §5.2: a paused agent holds here — before the next think step, with
  # its messages complete — and `handle_cast(:continue, …)` calls back in.
  defp start_llm(%{paused?: true} = state) do
    RunServer.update_node(state.run_id, state.node_id, %{status: "paused"})
    {:noreply, %{state | held: :llm, status: :paused}}
  end

  defp start_llm(state) do
    turn = state.turn + 1

    # spec 66 T13: the model's own context window when Settings → Pricing has
    # one for it, today's three cases otherwise.
    budget = Context.budget(state.model.model, state.settings)

    # spec 66 T14: over 80 % of the budget, a root chat agent summarises the
    # conversation into a `kind: "compact"` run of its own. This turn carries on
    # against the trimmed history exactly as before; the *next* user turn starts
    # from the summary, which is the turn that would otherwise have lost the
    # beginning of the conversation silently.
    state = maybe_auto_compact(state, budget)

    # spec 67 T24 (G26): and this turn's own history is summarised in place when
    # it crosses the same threshold — the conversation-level path above only
    # helps the *next* user turn, and a single turn with sixty tool calls never
    # gets one.
    state = maybe_inline_compact(state, budget)

    # spec 67 T26 (G29): the world the block in the system prompt described can
    # have moved (a `git checkout -b`, a mode switch from the composer). The
    # refresh is a user message on the next request; the system block is the
    # cache prefix and is never touched.
    {env_notice, state} = environment_notice(state)

    # spec 73 T9: what peers sent since the last think step (spec 72 C1) joins
    # the steer here — the one place a message reaches the model — instead of
    # being cast into the steer *and* left in the mailbox to be read again.
    state = drain_mailbox(state)

    # spec 72 B1: two-turn wrap-up notice at max_turns - 1, last-turn notice at
    # max_turns. Both go to the *request* only, once; never into durable history.
    {notice, is_last_turn_notice, is_wrap_up_notice} =
      cond do
        turn == state.max_turns and state.max_turns > 1 and not state.notice_sent? ->
          {[%{role: "user", content: last_turn_notice(state)}], true, false}

        turn == state.max_turns - 1 and state.max_turns > 2 and not state.wrap_up_sent? ->
          {[%{role: "user", content: wrap_up_notice(state)}], false, true}

        true ->
          {[], false, false}
      end

    # Spec 43 §1.4: the compressed history is what the agent keeps, not only
    # what it sends — an over-budget agent used to hold every old tool body on
    # its heap for life. Idempotent: a placeholder is never compressed again,
    # so the model sees exactly what it saw before.
    #
    # spec 73 T5: and so is the *trimmed* history. `Context.trim/2` ran on the
    # request alone, so an over-budget agent re-trimmed its full (larger) list
    # on every call, dropped one more exchange from the front each time and the
    # first message sent changed per call — the prefix-cache miss spec 72 B4's
    # hysteresis was written to stop. Trimmed once and stored, the following
    # calls grow from the low-water mark with a byte-identical prefix.
    messages =
      (state.messages ++ state.steer)
      |> Context.compress(budget)
      |> Context.trim(budget)

    state = %{
      state
      | messages: messages,
        steer: [],
        notice_sent?: state.notice_sent? or is_last_turn_notice,
        wrap_up_sent?: state.wrap_up_sent? or is_wrap_up_notice,
        model: refresh_provider(state.model)
    }

    request = %LLM.Request{
      provider: state.model.provider,
      model: state.model.model,
      system: state.system,
      messages: state.messages ++ env_notice ++ notice,
      tools: state.tool_specs,
      # Spec 45 §3.3: the one effort → request site every agent goes through
      # (chat, swarm, judge, workflow, research tier, scheduled) — a key the
      # model's list lacks becomes that list's default.
      effort:
        LLM.Efforts.normalise_key(
          Map.get(state, :effort),
          state.model.provider,
          state.model.model
        ),
      # spec 66 T18: one prefix-cache key per agent — the run's for the agent at
      # the root, the run's plus the node's for a sub-agent, so siblings with
      # different prefixes do not evict each other's cache.
      cache_key: cache_key(state)
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

  # spec 73 T9: a message that arrived while a tool batch ran is oldest-first
  # ahead of anything the user steered meanwhile; a run that is already gone
  # answers `{:error, :not_running}` and there is nothing to add.
  #
  # F6: only when the RunServer said something is queued (`{:mailbox_pending,
  # _}`, sent on enqueue and at start for a mailbox filled while the agent
  # waited) — a synchronous call to the state owner before *every* think step
  # of every agent put a hop on the hot path that an idle mailbox never needs,
  # and reordered agents that used to reach the provider in start order.
  defp drain_mailbox(%{mailbox_pending?: false} = state), do: state

  defp drain_mailbox(state) do
    state = %{state | mailbox_pending?: false}

    case RunServer.drain_inbox(state.run_id, state.node_id) do
      [_ | _] = messages ->
        drained =
          Enum.map(messages, fn message ->
            prefix = if message[:broadcast?], do: "Broadcast from ", else: "Message from "

            Context.count(%{
              role: "user",
              content: prefix <> message.from <> ": " <> message.text
            })
          end)

        %{state | steer: drained ++ state.steer}

      _none_or_gone ->
        state
    end
  end

  defp cache_key(%{run_id: run_id, node_id: node_id, depth: depth, role: role})
       when is_binary(run_id) and (depth > 0 or role != "assistant"),
       do: run_id <> ":" <> to_string(node_id)

  defp cache_key(%{run_id: run_id}) when is_binary(run_id), do: run_id
  defp cache_key(_state), do: nil

  # spec 66 T14: the fraction of the budget a root chat agent compacts at, and
  # the smallest number of turns between two compactions of one agent.
  #
  # spec 67 T11 (G27): 0.8 of an estimate that ignored the system prompt and the
  # tool schemas tripped at ~0.6 of the real window — and on a normal 60-tool-call
  # turn it never tripped at all. The threshold is judged against the larger of
  # the estimate and the size the provider itself reported, so it can be the 0.9
  # it always meant to be.
  @auto_compact_at 0.9
  @auto_compact_gap 10

  # spec 70 A2: doom loop detection — N consecutive identical single-call
  # batches trigger a warning; the next identical call after the warning
  # stops the agent.
  @doom_threshold 3

  # spec 67 T9 (B34): the running turn no longer compacts. `start_chat_turn/4`
  # reserves the user row *and* the empty assistant row before the agent starts,
  # so a summary written from inside the turn landed above the answer that was
  # still to come and buried it under the compaction floor for ever. The agent
  # raises a flag instead; the next chat turn compacts before it reserves its own
  # rows, which is the only order in which the summary can cover the whole
  # conversation and the answer can stay above it. The in-turn (inline) half is
  # G26, and is not this task.
  defp maybe_auto_compact(state, budget) do
    if auto_compact?(state, budget) do
      SwarmCode.Domain.Conversations.mark_compact_due(Map.get(state, :conversation_id))
      %{state | last_compact_turn: state.turn}
    else
      state
    end
  end

  defp auto_compact?(state, budget) do
    Map.get(state, :role) == "assistant" and Map.get(state, :depth, 0) == 0 and
      Map.get(state, :run_kind) == "chat" and is_binary(Map.get(state, :conversation_id)) and
      gap_elapsed?(state) and
      context_tokens(state) > budget * @auto_compact_at
  end

  # spec 67 T11 (G27): `result.usage.input` is what the provider charged for the
  # whole prompt — history, system prompt, tool schemas and cache reads — where
  # the estimate is `payload_bytes / 4` of the history alone. The larger of the
  # two decides; the estimate still leads on the first turn of an agent, and
  # after a trim (the reported size is one call behind).
  # spec 70 A1: the overhead closes the ~40 % gap on the first turn;
  # after that, last_input carries the provider's real number.
  defp context_tokens(state) do
    max(
      Map.get(state, :last_input, 0),
      Context.estimate_tokens(state.messages ++ state.steer) +
        Map.get(state, :prompt_overhead, 0)
    )
  end

  defp gap_elapsed?(%{last_compact_turn: n, turn: turn}) when is_integer(n),
    do: turn - n >= @auto_compact_gap

  defp gap_elapsed?(_state), do: true

  ## ------------------------------------------- inline compaction (spec 67 T24)

  # spec 67 T24 (G26): `maybe_auto_compact/2` above raises a flag the *next*
  # user turn reads. That does nothing for the turn that is actually too big:
  # one request with sixty tool calls silently loses its earliest exchanges to
  # `Context.trim/2` and the agent forgets what it was asked. Over the same
  # threshold the agent now summarises its own history, synchronously, inside
  # its think step, and carries on against the summary plus the last exchanges.
  #
  # The summary call blocks this GenServer on purpose: the agent has nothing
  # else to do (its next step is the request this is preparing), every message
  # it can receive is a cast that simply waits, and a stop still kills it
  # through its supervisor. The deadline is 120 s, not the LLM default.
  #
  # Messages kept whole after the summary, and the smallest number of turns
  # between two inline compactions of one agent (a tail that is still over the
  # threshold — one 100 000-character tool result — must not buy a summary call
  # every single turn).
  @inline_keep 6
  @inline_gap 3
  @inline_deadline_ms 120_000
  @inline_max_tokens 4_000
  @inline_marker "[Summary of this turn so far]\n"

  defp maybe_inline_compact(state, budget) do
    if inline_compact?(state, budget) do
      before = context_tokens(state)
      op = inline_node(state)

      case inline_summary(state, budget) do
        {:ok, summary} ->
          messages =
            [Context.count(%{role: "user", content: @inline_marker <> summary})] ++
              inline_tail(state.messages)

          after_tokens = Context.estimate_tokens(messages)
          note = "compacted in place (#{before} → #{after_tokens} tokens)"

          # The op row is what survives the turn: `complete_agent/3` overwrites
          # the agent node's `detail` with the final answer.
          finish_inline_node(state, op, %{
            status: "done",
            progress: 100,
            detail: note,
            result: summary
          })

          RunServer.update_node(state.run_id, state.node_id, %{detail: note})

          %{
            state
            | messages: messages,
              # The reported size belongs to the prompt that has just been
              # thrown away; leaving it would keep the threshold tripped.
              last_input: 0,
              last_inline_compact_turn: state.turn
          }

        {:error, reason} ->
          Logger.warning("swarm_code inline compaction failed: " <> String.slice(reason, 0, 200))

          finish_inline_node(state, op, %{
            status: "failed",
            progress: 100,
            error: String.slice(reason, 0, 500),
            detail: "compaction failed"
          })

          # Carry on with the history as it is — `Context.trim/2` still fits the
          # request — and do not ask again before the gap.
          %{state | last_inline_compact_turn: state.turn}
      end
    else
      state
    end
  end

  defp inline_node(state) do
    case RunServer.register_node(state.run_id, %{
           kind: "op",
           op_type: "compact",
           title: "compacting the history",
           parent_id: state.node_id,
           progress: nil,
           status: "running"
         }) do
      {:ok, node} -> node.id
      _other -> nil
    end
  rescue
    _error -> nil
  end

  defp finish_inline_node(_state, nil, _attrs), do: :ok

  defp finish_inline_node(state, id, attrs) do
    RunServer.update_node(state.run_id, id, Map.put(attrs, :finished_at, DateTime.utc_now()))
  end

  defp inline_compact?(state, budget) do
    # A compact run *is* the summariser: compacting its input would summarise a
    # summary request. Everything else — chat, lead, worker, workflow — compacts.
    #
    # Never on the agent's *first* think step: that history is the window the
    # RunServer handed it, and a conversation that arrives over the threshold is
    # `maybe_auto_compact/2`'s case (the summary is persisted, so the next turn
    # starts from it). This path is for the history the turn itself grew.
    Map.get(state, :run_kind) != "compact" and
      state.turn >= 1 and
      inline_gap_elapsed?(state) and
      length(state.messages) > @inline_keep + 2 and
      length(Context.group(state.messages)) >= 3 and
      context_tokens(state) > budget * @auto_compact_at
  end

  defp inline_gap_elapsed?(%{last_inline_compact_turn: n, turn: turn}) when is_integer(n),
    do: turn - n >= @inline_gap

  defp inline_gap_elapsed?(_state), do: true

  # The history is flattened into one user message rather than replayed as
  # itself: an assistant turn carries `tool_use` blocks (which Anthropic refuses
  # without a `tools` array) and signed thinking blocks (which may not be
  # re-sent out of their run), and neither survives a request whose whole point
  # is to have no tools. A transcript has the same information and no shape
  # rules.
  defp inline_summary(state, budget) do
    body =
      state.messages
      |> Context.trim(budget)
      |> Enum.map_join("\n\n", &transcript_line/1)

    request = %LLM.Request{
      provider: state.model.provider,
      model: state.model.model,
      system: "",
      messages: [
        %{
          role: "user",
          content:
            "Here is the transcript of the work so far.\n\n" <>
              body <> "\n\n" <> Prompts.compact()
        }
      ],
      tools: [],
      max_tokens: @inline_max_tokens,
      effort: nil,
      deadline_ms: @inline_deadline_ms
    }

    case LLM.stream(request, fn _ -> :ok end) do
      {:ok, %LLM.Result{text: text}} ->
        if String.trim(text) == "", do: {:error, "the summary was empty"}, else: {:ok, text}

      {:error, message} ->
        {:error, to_string(message)}

      # spec 67 T30: the structured error shape.
      {:error, _kind, message} ->
        {:error, to_string(message)}

      other ->
        {:error, inspect(other)}
    end
  end

  defp transcript_line(%{role: "tool"} = m) do
    "[tool result · #{m[:name] || "tool"}#{if m[:is_error], do: " · error", else: ""}]\n" <>
      to_string(m[:content] || "")
  end

  defp transcript_line(%{role: role} = m) do
    calls =
      case m[:tool_calls] || [] do
        [] -> ""
        list -> "\n[calls: " <> Enum.map_join(list, ", ", &to_string(&1.name)) <> "]"
      end

    String.upcase(to_string(role)) <> ": " <> to_string(m[:content] || "") <> calls
  end

  defp transcript_line(m), do: inspect(m)

  # The tail is taken by whole `Context.group/1` exchanges, not by a flat count,
  # so the summary is never followed by a `tool_result` whose `tool_use` was cut
  # away (both providers reject that request outright).
  defp inline_tail(messages) do
    messages
    |> Context.group()
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn group, {acc, kept} ->
      if kept >= @inline_keep,
        do: {:halt, {acc, kept}},
        else: {:cont, {[group | acc], kept + length(group)}}
    end)
    |> elem(0)
    |> Enum.concat()
    |> drop_leading_results()
  end

  defp drop_leading_results([%{role: "tool"} | rest]), do: drop_leading_results(rest)
  defp drop_leading_results(messages), do: messages

  ## ------------------------------------- environment refresh (spec 67 T26)

  # spec 67 T26 (G29): `<environment>` is stamped into the system prompt once,
  # at run start. After `git checkout -b feature` the agent still writes its
  # changelog entry for `main`, and a mode switched to full access leaves a
  # prompt that says `read_only`. The block is rebuilt per think step and, when
  # it differs from the one this agent last saw, goes out as a user message —
  # the system block is the Anthropic cache prefix and rewriting it would
  # invalidate the whole run's cache on every branch change.
  #
  # The first computed block is stored without being sent: it is the one the
  # system prompt already carries.
  # The first think step sends the system prompt, which carries the block the
  # RunServer stamped and handed over as `args.env`; there is nothing to
  # compare against yet and nothing to gain from reading the row again.
  defp environment_notice(%{turn: 0} = state), do: {[], state}

  defp environment_notice(state) do
    env = environment_block(state)

    cond do
      is_nil(env) or env == state.last_env ->
        {[], state}

      is_nil(state.last_env) ->
        {[], %{state | last_env: env}}

      true ->
        {[%{role: "user", content: "[environment changed]\n" <> env}], %{state | last_env: env}}
    end
  end

  # Spec 39 §1.1: a research run borrows the scratch project and sets its mode
  # in memory, so its row is the wrong answer — it keeps the block it started
  # with.
  defp environment_block(%{run_kind: "research"}), do: nil

  defp environment_block(state) do
    with id when is_binary(id) <- Map.get(state, :project_id),
         %Project{} = project <- SwarmCode.Domain.Projects.get_cached(id) do
      root = Map.get(state, :project_root) || project.root_path
      Prompts.environment_cached(%{project | root_path: root})
    else
      _other -> nil
    end
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

  # spec 66 T20: the batch is started in two groups. Every parallel-safe call
  # starts at once, as before; the calls a tool declares `parallel?: false` for
  # (`write_file`, `edit_file`, `run_command`, `move_file`, `delete_file`,
  # `git_commit`, `integrate_agent`, `remember`, and every writing MCP tool) are
  # started one at a time, in the order the model emitted them, each waiting for
  # the previous one's `{:op_done, …}`. `state.order` is rebuilt in the model's
  # order once the batch is complete, so the `role: "tool"` messages still line
  # up with the calls — `continue_after_tools/1` is unchanged.
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

    plans =
      tool_calls
      |> Enum.with_index()
      |> Enum.map(fn {call, index} -> plan_call(state, call, index, ctx) end)

    {parallel, serial} = Enum.split_with(plans, & &1.parallel?)

    state = %{
      state
      | pending: %{},
        calls: %{},
        order: [],
        results: %{},
        slots: %{},
        serial_queue: serial,
        serial_running: nil,
        status: :awaiting_tools
    }

    state = Enum.reduce(parallel, state, &start_plan(&2, &1))
    {:noreply, start_next_serial(state)}
  end

  # Everything `Operation.start/3` needs for one call, decided before anything
  # is started so the model's order survives a deferred start.
  defp plan_call(state, call, index, ctx) do
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

    %{
      call: call,
      index: index,
      op_type: op_type,
      title: title,
      work: work,
      # An unknown name, an undecodable argument list or a structured answer is
      # not a write: it never blocks the batch.
      parallel?: is_nil(ref) or not is_nil(call[:args_error]) or Ref.parallel?(ref)
    }
  end

  defp start_plan(state, plan), do: state |> start_op(plan) |> elem(0)

  defp start_op(state, plan) do
    {:ok, op_id} =
      Operation.start(state.ops_sup, self(), %{
        run_id: state.run_id,
        parent_id: state.node_id,
        op_type: plan.op_type,
        title: plan.title,
        work: plan.work
      })

    state = %{
      state
      | pending: Map.put(state.pending, op_id, plan.call),
        calls: Map.put(state.calls, op_id, plan.call),
        slots: Map.put(state.slots, op_id, plan.index)
    }

    {state, op_id}
  end

  # Starts the next `parallel?: false` call, if any; `serial_running` is the op
  # whose `{:op_done, …}` releases the one after it.
  defp start_next_serial(%{serial_queue: []} = state), do: %{state | serial_running: nil}

  defp start_next_serial(%{serial_queue: [plan | rest]} = state) do
    {state, op_id} = start_op(%{state | serial_queue: rest}, plan)
    %{state | serial_running: op_id}
  end

  # The batch is over when nothing is running and nothing is queued.
  defp tools_done?(state),
    do: map_size(state.pending) == 0 and Map.get(state, :serial_queue, []) == []

  # The model's order, from the slot each op was planned into.
  defp ordered_ops(state) do
    state.slots
    |> Enum.sort_by(fn {_op_id, index} -> index end)
    |> Enum.map(fn {op_id, _index} -> op_id end)
  end

  defp after_tools(state) do
    structured =
      state.require_tool &&
        Enum.find_value(state.order, fn op_id ->
          call = Map.fetch!(state.calls, op_id)
          {text, error?, _images} = Map.fetch!(state.results, op_id)
          if call.name == state.require_tool and not error?, do: text
        end)

    if structured do
      finish(state, {:ok, structured})
    else
      continue_after_tools(state)
    end
  end

  # spec 73 T50: the two polling tools are designed to be called again with
  # the same arguments — `wait_for_message`'s only argument is its timeout —
  # and their results differ without the guard ever reading them. A lead with
  # three slow background agents used to be stopped as a doom loop on its
  # fourth wait, workers still producing.
  @doom_exempt ~w(wait_for_message inbox)

  # spec 70 A2
  defp record_doom_calls(state) do
    sigs =
      state.order
      |> Enum.map(&Map.fetch!(state.calls, &1))
      |> Enum.reject(&(&1.name in @doom_exempt))
      |> Enum.map(fn call -> {call.name, :erlang.phash2(call.args)} end)

    recent = Enum.take(sigs ++ state.recent_calls, @doom_threshold + 1)
    %{state | recent_calls: recent}
  end

  # spec 70 A2: returns `{:stop, reason}` or updated state.
  defp check_doom_loop(%{recent_calls: recent} = state)
       when length(recent) >= @doom_threshold do
    window = Enum.take(recent, @doom_threshold)
    [{name, hash} | _] = window

    if Enum.all?(window, &match?({^name, ^hash}, &1)) do
      if state.doom_notice_sent? do
        {:stop,
         "doom loop: `#{name}` called with identical arguments " <>
           "#{@doom_threshold} consecutive times after a warning — " <>
           "stopping to avoid wasting tokens"}
      else
        notice =
          "NOTICE: You have called `#{name}` with the same arguments " <>
            "#{@doom_threshold} times in a row, producing the same " <>
            "result each time. This appears to be a loop — try a " <>
            "completely different approach, use different arguments, " <>
            "or call ask_user to request guidance."

        %{
          state
          | doom_notice_sent?: true,
            steer:
              state.steer ++
                [Context.count(%{role: "user", content: notice})]
        }
      end
    else
      # Pattern broke — reset the flag.
      %{state | doom_notice_sent?: false}
    end
  end

  defp check_doom_loop(state), do: state

  # spec 72 A5: prewalk trigger — any completed tool call that writes or edits.
  # run_command triggers unless the command is read-only.
  #
  # spec 73 T51: "read-only" is `SwarmCode.Domain.Tools.CommandSafety.classify/1`'s
  # `:safe` — the one classifier the approval path already uses, which knows
  # `rg`, `sort`, `git rev-parse`, `git blame`, and reads through pipes and
  # redirections. The hand-rolled prefix list it replaces (spec 72 R8) counted
  # `echo x > lib/a.ex` as read-only and `rg` as a write.
  @prewalk_write_tools ~w(write_file edit_file edit_files)

  defp prewalk_trigger?(state) do
    Enum.any?(state.order, fn op_id ->
      call = Map.fetch!(state.calls, op_id)

      cond do
        call.name in @prewalk_write_tools ->
          true

        call.name == "run_command" ->
          cmd = to_string(call.args["command"] || call.args[:command] || "")
          SwarmCode.Domain.Tools.CommandSafety.classify(cmd) != :safe

        true ->
          false
      end
    end)
  end

  defp continue_after_tools(state) do
    tool_messages =
      Enum.map(state.order, fn op_id ->
        call = Map.fetch!(state.calls, op_id)
        {text, error?, images} = Map.fetch!(state.results, op_id)

        message = %{
          role: "tool",
          tool_call_id: call.id,
          name: call.name,
          content: text,
          is_error: error?
        }

        # spec 67 T34 (G35): the provider turns these into `tool_result` image
        # blocks (Anthropic) or an `[image omitted]` line (OpenAI).
        message = if images == [], do: message, else: Map.put(message, :images, images)

        Context.count(message)
      end)

    # spec 70 A2: doom loop detection — record before clearing calls/order.
    # spec 72 A5: check prewalk trigger before clearing calls/order.
    prewalk_triggered? =
      state.prewalk? and not state.prewalked? and prewalk_trigger?(state)

    state = record_doom_calls(state)

    state = %{
      state
      | messages: state.messages ++ tool_messages,
        calls: %{},
        order: [],
        results: %{},
        # spec 66 T20: both are empty by now; cleared with the rest of the batch.
        slots: %{},
        serial_running: nil
    }

    # spec 72 A5: prewalk model switch — happens after tools complete, before
    # the next start_llm call.
    state =
      if prewalk_triggered? do
        require Logger

        Logger.info("prewalk: switching #{state.name} to #{state.prewalk_model.model}")

        # spec 72 F5: notify RunServer so the node's model field updates and
        # the inspector's model_chip reflects the switch.
        RunServer.update_node(state.run_id, state.node_id, %{
          model: state.prewalk_model.model
        })

        %{state | model: state.prewalk_model, prewalked?: true}
      else
        state
      end

    # spec 70 A2: doom loop detection
    case check_doom_loop(state) do
      {:stop, reason} ->
        # spec 72 B6: doom loop gets its own stop reason.
        finish(state, {:error, reason}, :doom_loop)

      state ->
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
            # spec 72 B1: :turn_budget stop reason.
            finish(state, {:ok, wrap_up_text(state)}, :turn_budget)
        end
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

  # spec 72 B2: finish/3 carries an optional orchestration stop reason alongside
  # the result. The stop reason becomes {:ok, reason, text} so RunServer can
  # persist it in error_kind without conflating it with LLM errors.
  defp finish(state, result, stop_reason \\ nil) do
    # spec 70 E2: close the agent telemetry span.
    if start = state[:telemetry_start] do
      Telemetry.span_stop(Telemetry.agent_span(), start, %{
        run_id: state.run_id,
        agent_id: state.node_id,
        status: :done
      })
    end

    result_with_reason =
      case {result, stop_reason} do
        {_, nil} -> result
        {{:ok, text}, reason} -> {:ok, reason, text}
        {{:error, msg}, reason} -> {:error, reason, msg}
      end

    RunServer.agent_finished(state.run_id, state.node_id, result_with_reason)
    {:stop, :normal, %{state | status: :done}}
  end
end
