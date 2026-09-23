defmodule SwarmCode.Domain.Engine.RunServer do
  @moduledoc """
  The single owner of one run's node tree.

  Every node change goes through this process; changes are persisted (SQLite) when
  meaningful and broadcast on the conversation topic at most every 100 ms
  (`{:nodes_upsert, run_id, nodes}`, `{:assistant_delta, message_id, text}`, `{:run_updated, run}`).
  It also starts/queues agents within `max_concurrent_agents`, gates operations on user
  approval, stops subtrees, detects agent crashes and finishes the run by writing the
  assistant / swarm / error message.
  """
  use GenServer, restart: :temporary
  require Logger

  alias SwarmCode.Domain.Conversations
  alias SwarmCode.Domain.Conversations.Node
  alias SwarmCode.Domain.Engine.{AgentsSup, Events, Isolation, Prompts, Telemetry}
  alias SwarmCode.Domain.LLM.Chunks
  alias SwarmCode.Domain.{Pricing, Providers, Tools}
  alias SwarmCode.Domain.Tools.IntegrateAgent
  alias SwarmCode.Domain.Projects.Workspace

  @flush_ms 100
  # spec 72 C1: per-agent mailbox cap — sender gets a tool error, never a silent drop.
  @mailbox_cap 100
  # The one-line preview a node carries. It is pushed to every open LiveView on
  # every flush, so 8 streaming agents at 500 chars were ~40 KB/s of text the UI
  # truncates anyway (spec 12 §11.2).
  @detail_chars 160
  @detail_scan_bytes 1_280
  # spec 66 T3: a node parked on an approval is the one place the preview is not
  # a preview — the user has to read the whole command before pressing Approve.
  @approval_detail_chars 2_000
  # Spec 51 §2.4: the per-node stream buffer is a byte-bounded tail; the one-line
  # preview is derived from it once per flush, not once per delta.
  @stream_tail_bytes 3_200
  # Spec 51 §2.5: the columns a node can change after it was registered. Everything
  # else (kind, op_type, name, role, depth, position, parent_id, prompt, input) is
  # written once, at register. `title` is here for `write_spec`, which names its op
  # after the file it wrote; `started_at` for a queued agent that starts; `max_turns`
  # because an agent's first turn is what writes it.
  # Spec 53b §5: `cache_read`/`cache_write` ride with the token counters — they
  # are the two parts of `tokens_in` that were not billed at the input rate.
  # spec 67 T30 (G42): `error_kind` rides with `error` — the same write, one
  # more column, so a failed node says what kind of failure it was.
  @persisted ~w(status progress detail result error error_kind tokens_in tokens_out cache_read
                cache_write cost_usd turn max_turns title started_at finished_at workspace_path
                branch base_sha changes_stat integrated phase group)a
  # Clock model (spec 51 §4.12, verified on OTP 28 defaults `multi_time_warp` +
  # `CLOCK_UPTIME_RAW`): every deadline here and in `run_command`/`program` is
  # monotonic and pauses while the machine sleeps; every timestamp is wall-clock
  # and jumps at wake. Keep it that way; do not add `+C no_time_warp`.
  @approval_timeout_ms SwarmCode.Domain.Engine.Questions.deadline_ms(:approval)
  @question_timeout_ms SwarmCode.Domain.Engine.Questions.deadline_ms(:question)
  @finished ~w(done failed stopped)

  # ------------------------------------------------------------------ client API

  def start_link(args) do
    GenServer.start_link(__MODULE__, args,
      name: via(args.run.id, {args.conversation.id, args.run.kind}),
      # Spec 43 §1.4: a run parked in an approval or a question compacts its
      # heap; one that streams is woken ten times a second and never gets here.
      hibernate_after: 15_000
    )
  end

  def via(run_id), do: {:via, Registry, {SwarmCode.Domain.Registry, {:run, run_id}}}
  def via(run_id, value), do: {:via, Registry, {SwarmCode.Domain.Registry, {:run, run_id}, value}}

  @doc "Registers a node; `attrs` must contain `:kind`. id/position/started_at are assigned here."
  @spec register_node(String.t(), map()) :: {:ok, Node.t()}
  # Spec 13 §11 A-5: the default 5 s call timed out on a slow repo (the server
  # runs `git worktree add` inside it) and took the whole workflow down with it.
  def register_node(run_id, attrs),
    do: GenServer.call(via(run_id), {:register_node, attrs}, 30_000)

  @spec update_node(String.t(), String.t(), map()) :: :ok
  def update_node(run_id, node_id, attrs),
    do: GenServer.cast(via(run_id), {:update_node, node_id, attrs})

  @spec text_delta(String.t(), String.t(), String.t()) :: :ok
  def text_delta(run_id, node_id, text),
    do: GenServer.cast(via(run_id), {:text_delta, node_id, text})

  @spec reasoning_delta(String.t(), String.t(), String.t()) :: :ok
  def reasoning_delta(run_id, node_id, text),
    do: GenServer.cast(via(run_id), {:reasoning_delta, node_id, text})

  @doc """
  Drops the text an op streamed before a transport retry (spec 11 §7.3), so the
  retried answer replaces the half-streamed one instead of appending to it.
  """
  @spec text_reset(String.t(), String.t()) :: :ok
  def text_reset(run_id, node_id), do: GenServer.cast(via(run_id), {:text_reset, node_id})

  @spec reasoning_reset(String.t(), String.t()) :: :ok
  def reasoning_reset(run_id, node_id),
    do: GenServer.cast(via(run_id), {:reasoning_reset, node_id})

  @doc """
  Tells a live run about the AI label that landed after it started (spec 13 §4
  + §11 A-3). The server keeps its own copy of the `runs` row and broadcasts it
  on every flush, so without this the next token update would push the creation
  time fallback label back into the UI — the label only appeared after a
  reload.
  """
  @spec set_label(String.t(), String.t()) :: :ok
  def set_label(run_id, label) when is_binary(label) do
    GenServer.cast(via(run_id), {:set_label, label})
  catch
    :exit, _ -> :ok
  end

  @doc "Appends a user message to the root agent's next LLM call (see item 5, steering)."
  @spec steer(String.t(), String.t(), [map()]) :: :ok | {:error, :not_running | :finished}
  def steer(run_id, text, images \\ [], opts \\ [])

  def steer(run_id, text, images, opts) do
    # Spec 13 §3.6: with `node_id:` the message is delivered to that sub-agent
    # exactly as the root's steer is delivered to the Lead.
    #
    # spec 67 T12 (B13): not `safe_call/2`. Its 5 000 ms `GenServer.call/2`
    # default turned a RunServer stalled on a busy database into "not running",
    # the composer started a fresh turn with the same text, and the `{:steer,
    # …}` still in the mailbox was processed afterwards — the agent read the
    # message twice. A steer waits for its own server; only a server that is
    # gone is `:not_running`.
    GenServer.call(via(run_id), {:steer, text, images, opts[:node_id]}, :infinity)
  catch
    :exit, {:noproc, _} -> {:error, :not_running}
    :exit, {:shutdown, _} -> {:error, :not_running}
    :exit, {{:shutdown, _}, _} -> {:error, :not_running}
    :exit, {:normal, _} -> {:error, :not_running}
    # A server that crashed under the call is no more running than one that is
    # gone; the LiveView must never take an exit from a steer.
    :exit, _other -> {:error, :not_running}
  end

  # spec 66 T4/T5: `safety` is the command's class; `request_approval/3` keeps
  # working and means `:normal`.
  @spec request_approval(String.t(), String.t(), :read | :write | :execute, atom()) ::
          :approved | :denied | :timeout
  def request_approval(run_id, node_id, permission, safety),
    do: GenServer.call(via(run_id), {:request_approval, node_id, permission, safety}, :infinity)

  @spec request_approval(String.t(), String.t(), :read | :write | :execute) ::
          :approved | :denied | :timeout
  def request_approval(run_id, node_id, permission),
    do: request_approval(run_id, node_id, permission, :normal)

  # spec 66 T5/T21: `:always_prefix` carries the command family to remember,
  # `:deny_stop` denies this call and stops the run.
  @spec resolve_approval(
          String.t(),
          String.t(),
          :approve | :deny | :always | :deny_stop | {:always_prefix, String.t()}
        ) :: :ok
  def resolve_approval(run_id, node_id, decision),
    do: GenServer.cast(via(run_id), {:resolve_approval, node_id, decision})

  @doc """
  Interview mode (spec 10 §1): blocks the calling tool until the user answers
  the questions (or the run stops / 30 minutes pass).
  """
  @spec ask_user(String.t(), String.t(), [map()]) :: {:ok, [map()]} | {:error, String.t()}
  def ask_user(run_id, node_id, questions, opts \\ []),
    do:
      GenServer.call(
        via(run_id),
        {:ask_user, node_id, questions, opts[:timeout] || @question_timeout_ms},
        :infinity
      )

  @doc "Spec 37: the run's consensus config and the next 1-based round of `stage`, or `{nil, 0}`."
  @spec consensus_round(String.t(), String.t()) :: {map() | nil, non_neg_integer()}
  def consensus_round(run_id, stage),
    do: GenServer.call(via(run_id), {:consensus_round, stage}, :infinity)

  @doc "Answers one indexed pending question, completing the ask when all are answered."
  @spec answer_question(
          String.t(),
          String.t(),
          non_neg_integer(),
          [non_neg_integer()],
          String.t()
        ) :: :ok | {:error, :not_running | :stale_question | :invalid_answer}
  def answer_question(run_id, node_id, index, option_indices, custom \\ "") do
    try do
      GenServer.call(
        via(run_id),
        {:answer_question, node_id, index, option_indices, custom},
        30_000
      )
    catch
      :exit, _ -> {:error, :not_running}
    end
  end

  @doc "Answers the pending questions of `node_id` (one entry per question)."
  @spec answer(String.t(), String.t(), [map()]) :: :ok
  def answer(run_id, node_id, answers),
    do: GenServer.cast(via(run_id), {:answer, node_id, answers})

  @doc """
  Returns a bounded, transport-safe projection of interactions waiting in this run.
  A stopped or unknown run returns an empty projection; process internals (pids,
  callers, timers and credentials) are never included.
  """
  @spec pending_interactions(String.t()) :: [map()]
  def pending_interactions(run_id) when is_binary(run_id) do
    case GenServer.call(via(run_id), :pending_interactions, 250) do
      rows when is_list(rows) -> rows
      _ -> []
    end
  catch
    :exit, _ -> []
  end

  def pending_interactions(_), do: []

  @doc "The questions waiting for an answer in this run, or `[]`."
  @spec pending_questions(String.t()) :: [{String.t(), [map()]}]
  # Spec 43 §1.4: its own call — `get_state/1` copied the whole run (nodes,
  # previews, project context) to the caller for a list of two-tuples.
  def pending_questions(run_id) do
    case safe_call(run_id, :pending_questions) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  @spec start_agent(String.t(), %{
          parent_id: String.t(),
          name: String.t(),
          task: String.t(),
          context: String.t() | nil,
          depth: non_neg_integer()
        }) :: {:ok, String.t()} | {:error, String.t()}
  def start_agent(run_id, attrs),
    do: GenServer.call(via(run_id), {:start_agent, attrs}, :infinity)

  @spec await_agent(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def await_agent(run_id, node_id), do: await_agent(run_id, node_id, awaiting: nil)

  @doc """
  Two forms. With a keyword list (spec 51 §5.1), `awaiting: parent_node_id`
  names the agent that parks here — its slot goes to the queue while it waits;
  nothing is re-acquired. With a timeout (spec 40 §1.6), `await_agent/2` with a
  wall clock: `{:error, :timeout}` after `timeout` ms. Every other exit keeps
  propagating — a caller that awaits a run which went away still sees the
  original reason.
  """
  @spec await_agent(String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def await_agent(run_id, node_id, opts) when is_list(opts),
    do: GenServer.call(via(run_id), {:await_agent, node_id, opts[:awaiting]}, :infinity)

  @spec await_agent(String.t(), String.t(), timeout()) ::
          {:ok, String.t()} | {:error, String.t() | :timeout}
  def await_agent(run_id, node_id, timeout) do
    GenServer.call(via(run_id), {:await_agent, node_id, nil}, timeout)
  catch
    :exit, {:timeout, {GenServer, :call, _args}} -> {:error, :timeout}
  end

  @spec agent_finished(String.t(), String.t(), {:ok, String.t()} | {:error, String.t()}) :: :ok
  def agent_finished(run_id, node_id, result),
    do: GenServer.cast(via(run_id), {:agent_finished, node_id, result})

  @doc "Stops every live worker of a workflow run (pause) without ending the run."
  @spec stop_workers(String.t()) :: :ok
  def stop_workers(run_id) do
    GenServer.call(via(run_id), :stop_workers, :infinity)
  catch
    :exit, _ -> :ok
  end

  @doc "The `Research.Server` reports the terminal state of its program (spec 24 §3.4)."
  @spec research_finished(String.t(), String.t(), map()) :: :ok
  def research_finished(run_id, status, attrs \\ %{}) do
    GenServer.cast(via(run_id), {:research_finished, status, attrs})
  catch
    :exit, _ -> :ok
  end

  @doc "The Runner reports the terminal state of the program (spec 09 §4.1)."
  @spec workflow_finished(String.t(), String.t(), map()) :: :ok
  def workflow_finished(run_id, status, attrs) do
    GenServer.cast(via(run_id), {:workflow_finished, status, attrs})
  end

  @spec stop(String.t()) :: :ok | {:error, :not_running}
  def stop(run_id), do: safe_call(run_id, :stop)

  @doc """
  Spec 45 §5.2: the run stays alive; every agent finishes the step it is on
  and holds before its next think step; queued workers are not admitted. The
  run row says `paused`. A no-op on a paused run.
  """
  @spec pause(String.t()) :: :ok | {:error, :not_running}
  def pause(run_id), do: safe_call(run_id, :pause)

  @doc "Spec 45 §5.2: the held agents take their next step; the queue drains. A no-op on a running run."
  @spec continue(String.t()) :: :ok | {:error, :not_running}
  def continue(run_id), do: safe_call(run_id, :continue)

  @doc "Spec 45 §6.2: the run's consensus config map (`Consensus.config/1` + `:request`), or nil."
  @spec consensus_config(String.t()) :: map() | nil | {:error, :not_running}
  def consensus_config(run_id), do: safe_call(run_id, :consensus_config)

  @doc "Spec 51 §5.6: the judge's decoded verdict for `stage`, for the next round's judge."
  @spec consensus_verdict(String.t(), String.t(), map()) :: :ok
  def consensus_verdict(run_id, stage, verdict) when is_map(verdict),
    do: GenServer.cast(via(run_id), {:consensus_verdict, stage, verdict})

  @doc "Spec 51 §5.8: the round's outcome, stored on the run row when it is produced."
  @spec consensus_round_done(String.t(), map()) :: :ok
  def consensus_round_done(run_id, entry) when is_map(entry),
    do: GenServer.cast(via(run_id), {:consensus_round_done, entry})

  @spec stop_agent(String.t(), String.t()) :: :ok | {:error, :not_running}
  def stop_agent(run_id, node_id), do: safe_call(run_id, {:stop_agent, node_id})

  # spec 72 B7: a timed-out sub-agent gets :spawn_timeout, not :user_stopped.
  @spec stop_agent_timeout(String.t(), String.t()) :: :ok | {:error, :not_running}
  def stop_agent_timeout(run_id, node_id),
    do: safe_call(run_id, {:stop_agent_timeout, node_id})

  # spec 72 R7: the stop reason as the state owner has it. The row is written
  # up to a flush later, so a parent that reads the DB the moment
  # await_agent/3 returns may still see the previous value.
  # spec 73 T58: the narrow reads for the tools that used to copy the whole
  # state through `get_state/1` (which stays test-only): the live agents by
  # name (`message_agent`), one field of one node (`node_field/3`, spawn_agent)
  # and one agent's result (`agent_result/2`). F2: `get_node/2` had no caller
  # once the tools were routed through these.
  @doc "`[{node_id, name}]` of every agent of the run that has not settled, `{:error, :not_running}` when the run is gone."
  @spec live_agent_names(String.t()) :: [{String.t(), String.t()}] | {:error, :not_running}
  def live_agent_names(run_id), do: safe_call(run_id, :live_agent_names)

  @spec node_error_kind(String.t(), String.t()) :: String.t() | nil
  def node_error_kind(run_id, node_id) do
    case safe_call(run_id, {:node_error_kind, node_id}) do
      kind when is_binary(kind) -> kind
      _none -> nil
    end
  end

  # spec 73 T17: the result as `settle/3` kept it — `{:ok, text}` untouched
  # by `normalize/1`'s 20 000-character node cap, so `agent_result` returns
  # what its description promises. `:running` while the agent has no result,
  # `:unknown` for an id that is not an agent of this run.
  @spec agent_result(String.t(), String.t()) ::
          {:done, {:ok, String.t()} | {:error, String.t()}}
          | :running
          | :unknown
          | {:error, :not_running}
  def agent_result(run_id, node_id), do: safe_call(run_id, {:agent_result, node_id})

  # spec 73 T100: one field of one node, for the tools that read a branch or
  # a name — `get_state/1` copied every node of the run to read one entry.
  @spec node_field(String.t(), String.t(), atom()) :: term() | {:error, :not_running}
  def node_field(run_id, node_id, field) when is_atom(field),
    do: safe_call(run_id, {:node_field, node_id, field})

  # spec 70 C6: register a background agent so its result is injected into the
  # parent's message queue when it finishes.
  @spec register_background(String.t(), String.t(), String.t() | nil) :: :ok | {:error, term()}
  def register_background(run_id, agent_node_id, parent_node_id),
    do: safe_call(run_id, {:register_background, agent_node_id, parent_node_id})

  @spec get_state(String.t()) :: map() | {:error, :not_running}
  def get_state(run_id), do: safe_call(run_id, :get_state)

  # spec 72 C1: deliver a message to an agent's mailbox.
  @spec deliver_message(String.t(), String.t(), String.t(), String.t()) ::
          :ok | {:error, term()}
  def deliver_message(run_id, from_node_id, to_node_id, text),
    do: safe_call(run_id, {:deliver_message, from_node_id, to_node_id, text})

  # spec 72 C1: drain all pending messages from an agent's mailbox.
  @spec drain_inbox(String.t(), String.t()) :: [map()]
  def drain_inbox(run_id, node_id),
    do: safe_call(run_id, {:drain_inbox, node_id})

  # spec 72 C2: block until a message arrives in the agent's mailbox, with timeout.
  @spec wait_for_message(String.t(), String.t(), pos_integer(), String.t() | nil) ::
          {:ok, map()} | {:error, :timeout}
  def wait_for_message(run_id, node_id, timeout_ms, awaiting \\ nil) do
    safe_call(run_id, {:wait_for_message, node_id, timeout_ms, awaiting},
      timeout: timeout_ms + 5_000
    )
  end

  # spec 72 C3: broadcast a message to all live agents in the run except the sender.
  @spec broadcast(String.t(), String.t(), String.t()) :: :ok
  def broadcast(run_id, from_node_id, text),
    do: safe_call(run_id, {:broadcast, from_node_id, text})

  defp safe_call(run_id, msg, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    GenServer.call(via(run_id), msg, timeout)
  catch
    :exit, _ -> {:error, :not_running}
  end

  # ------------------------------------------------------------------ callbacks

  # Spec 13 §11 A-10: a RunServer that crashes or is stopped leaves no pending
  # question behind — the ETS row outlived the process and the amber dot stayed
  # on the conversation for ever.
  @impl true
  def terminate(reason, state) do
    Enum.each(state.pending_isolation, fn {_node_id, %{task: task}} ->
      Task.shutdown(task, 100)
    end)

    Enum.each(state.pending_finalization, fn {_node_id, %{task: task}} ->
      Task.shutdown(task, 100)
    end)

    # spec 73 T8
    if hook = state.pending_session_hook, do: Task.shutdown(hook.task, 100)

    # spec 73 T56 (F1): a background agent's clock goes with its owner.
    Enum.each(state.agents, fn
      {_node_id, %{background_timer: timer}} when is_reference(timer) ->
        Process.cancel_timer(timer)

      _agent ->
        :ok
    end)

    Enum.each(state.approvals, fn {_node_id, %{from: from, timer: timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, :denied)
    end)

    Enum.each(state.questions, fn {_node_id, %{from: from, timer: timer}} ->
      cancel_timer(timer)
      GenServer.reply(from, {:error, "stopped"})
    end)

    # spec 72 C2: settle blocked message waiters on shutdown.
    Enum.each(state.message_waiters, fn waiter ->
      GenServer.reply(waiter.from, {:error, :timeout})
    end)

    SwarmCode.Domain.Engine.Questions.delete_run(state.run.id)
    # Spec 54 §1.1: the columns of the last 100 ms are still in `unsaved` —
    # write them before the terminal row, so a crashed or quit run leaves the
    # node statuses the boot sweep would otherwise have to guess.
    state =
      try do
        flush_writes(state)
      rescue
        _ -> state
      catch
        _, _ -> state
      end

    # spec 55 T11: the terminal row is written even when the flush could not be.
    try do
      write_terminal(reason, state)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    # spec 70 E2: close the run telemetry span.
    if start = state[:telemetry_start] do
      Telemetry.span_stop(Telemetry.run_span(), start, %{
        run_id: state.run.id,
        status: state.run.status
      })
    end

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Spec 51 §4.3: an abnormal end writes the row the boot sweep would have
  # written — `stopped` for a supervisor shutdown (a quit), `failed` for a crash
  # — so the run is resumable now, not after the next restart.
  defp write_terminal(reason, state) do
    unless reason == :normal or terminal?(state.run) do
      status = if shutdown?(reason), do: "stopped", else: "failed"

      # spec 55 T8: one transaction through `Writes.finish_turn/3`; the plain
      # `update_run/2` only when that transaction is refused.
      attrs = %{status: status, finished_at: now(), interrupted: shutdown?(reason)}

      creates =
        if status == "failed" and state.run.kind in ["chat", "compact"],
          do: [
            %{
              conversation_id: state.conversation.id,
              role: "error",
              content:
                "The run crashed: " <>
                  (reason
                   |> inspect()
                   |> SwarmCode.Domain.LLM.HTTP.redact()
                   |> String.slice(0, 200)),
              run_id: state.run.id
            }
          ],
          else: []

      opts =
        [create_messages: creates] ++
          case goal_settlement(state.run, status) do
            nil -> []
            pair -> [goal: pair]
          end

      state =
        case SwarmCode.Domain.Conversations.Writes.finish_turn(state.run, attrs, opts) do
          {:ok, %{run: run}} -> %{state | run: run, run_dirty: true}
          {:error, _} -> update_run(state, attrs)
        end

      announce_run(state)
    end
  end

  # Spec 51 §5.4: a gate question has no timer.
  defp cancel_timer(timer) when is_reference(timer), do: Process.cancel_timer(timer)
  defp cancel_timer(_none), do: :ok

  defp shutdown?(:shutdown), do: true
  defp shutdown?({:shutdown, _}), do: true
  defp shutdown?(_), do: false
  defp terminal?(%{status: s}), do: s in ~w(done failed stopped interrupted)

  @impl true
  def init(args) do
    # Spec 51 §4.3: a supervisor shutdown reaches `terminate/2` too. Nothing
    # links here but the supervisor; every Task is `async_nolink`; the catch-all
    # `handle_info/2` swallows a stray `{:EXIT, _, _}`.
    Process.flag(:trap_exit, true)

    state =
      Map.merge(args, %{
        nodes: %{},
        children: %{},
        # Spec 51 §2.5: per node, the persisted columns changed since its last
        # write — carried into the next UPDATE, so a state-only change (a
        # title, a progress) still reaches the row when the status does.
        # Spec 54 §1.1: `%{node_id => %{column => value}}`, the value as it was
        # when it changed (a finished op's `result` is lit right after).
        unsaved: %{},
        # Spec 54 §1.1: the nodes whose `unsaved` columns include a change that
        # triggers a write, and the nodes whose INSERT a busy database refused.
        # Both are settled by `flush_writes/1`, in one transaction.
        persist_pending: MapSet.new(),
        uninserted: MapSet.new(),
        # Spec 54 §1.5 (54a C1): the finished ops whose text this server has
        # already broadcast and dropped.
        stripped: MapSet.new(),
        busy_warned?: false,
        # spec 55 T8: a busy terminal write waits here for :finish_retry
        finish_pending: nil,
        position: 0,
        agents: %{},
        queue: [],
        active_sub: 0,
        approvals: %{},
        questions: %{},
        waiting_notified: MapSet.new(),
        always: MapSet.new(),
        dirty: MapSet.new(),
        # Spec 54 §2.1: per dirty node, the columns that changed since the last
        # flush — `:all` for a register or any column outside `Node.patch_cols/0`.
        dirty_cols: %{},
        flush_ref: nil,
        assistant_text: Chunks.new(),
        pending_delta: Chunks.new(),
        assistant_reasoning: Chunks.new(),
        pending_reasoning: Chunks.new(),
        stream: %{},
        run_dirty: false,
        totals: %{},
        totals_written: nil,
        root_node_id: nil,
        # Spec 30 §5: one marker per channel. Text and reasoning stream
        # independently, so a shared marker made every reasoning fragment of a
        # new operation look like the start of a new operation.
        last_text_node: nil,
        last_reasoning_node: nil,
        isolation_generation: 0,
        pending_isolation: %{},
        # spec 72 D1: per node_id, the backend used (:clone | :worktree).
        isolation_backends: %{},
        # spec 72 D2: per node_id, the baseline captured before the agent started.
        baselines: %{},
        finalization_generation: 0,
        pending_finalization: %{},
        # spec 73 T8: the chat run's `session_start` hook, while it runs.
        pending_session_hook: nil,
        # spec 70 C6: maps background agent node_id to parent agent node_id.
        background_agents: %{},
        # spec 72 C1: per-agent bounded mailboxes for peer messaging.
        mailboxes: %{},
        # spec 72 C2: agents waiting for a message (wait_for_message tool).
        message_waiters: [],
        # Repository detection belongs to the owned isolation task below: even
        # `git rev-parse` can block and init is the run's state owner.
        worktrees?: args.settings.worktrees_enabled,
        effort: effective_effort(args),
        runner: nil,
        runner_ref: nil,
        # Spec 37 §4.2: how many times the planner has been to the judge.
        # Spec 45 §5.2: a resumed run starts counting where the old one
        # stopped, so its first round is R<n+1>.
        consensus_rounds:
          Map.merge(%{"plan" => 0, "changes" => 0}, Map.get(args, :consensus_rounds) || %{}),
        # Spec 51 §5.6: `%{stage => verdict}` — the latest decoded verdict per
        # stage; a resumed run is seeded from the chain's last round.
        consensus_verdicts: Map.get(args, :consensus_verdicts) || %{},
        # Spec 45 §5.2: pause holds every agent before its next step.
        paused?: false,
        # Spec 51 §6.11: which Settings are the run's and which are live.
        # `max_live` below, `max_agent_turns`, `max_agent_depth`, the effort
        # levels and the pricing table are read once, here, and stay the run's
        # for its whole life — changing them mid-run would make a run's own
        # accounting disagree with itself. Everything a *tool* reads
        # (`command_timeout_ms`, `tool_timeout_ms`) is re-read per tool batch in
        # `AgentServer.dispatch_tools/2`, and the approval mode per op in
        # `Operation.current_mode/1`.
        max_live: max_live(args)
      })

    # spec 70 E2: structured telemetry — Logger metadata + run span start.
    Telemetry.put_run_metadata(args.run.id)

    telemetry_start =
      Telemetry.span_start(Telemetry.run_span(), %{
        run_id: args.run.id,
        kind: args.run.kind
      })

    {:ok, Map.put(state, :telemetry_start, telemetry_start), {:continue, :boot}}
  end

  defp max_live(%{workflow: %{wf: %{max_live: n}}}) when is_integer(n), do: n
  # Spec 24 §3.4: a research brings its own cap, so an `ultra` step can plan ten
  # subagents without ten of them being in flight at once.
  defp max_live(%{research: %{max_live: n}}) when is_integer(n), do: n
  defp max_live(args), do: args.settings.max_concurrent_agents

  # The conversation's own reasoning effort wins over the global default; every
  # agent of the run (lead, subs, assistant) uses the same level. A swarm run
  # has its own level, so a cheap chat model can sit next to a deep-thinking
  # swarm (spec 06 §9).
  # Spec 45 §3.3: any well-formed key passes here; `AgentServer` normalises it
  # against the list of the model each agent actually calls.
  defp effective_effort(%{run: %{kind: "swarm"}} = args) do
    case args do
      %{conversation: %{swarm_effort: effort}} when is_binary(effort) ->
        SwarmCode.Domain.LLM.Request.effort(effort)

      %{settings: %{default_swarm_effort: effort}} ->
        SwarmCode.Domain.LLM.Request.effort(effort)

      _ ->
        "medium"
    end
  end

  defp effective_effort(%{conversation: %{effort: effort}}) when is_binary(effort),
    do: SwarmCode.Domain.LLM.Request.effort(effort)

  defp effective_effort(%{settings: %{default_effort: effort}}),
    do: SwarmCode.Domain.LLM.Request.effort(effort)

  defp effective_effort(_args), do: "medium"

  @impl true
  # Spec 13 §11 A-5: `isolate/3` (a `git worktree add` that can take a minute)
  # runs here, after the caller already has its `{:ok, node_id}`.
  def handle_continue({:start_agent_process, node_id}, state),
    do: {:noreply, start_agent_process(state, node_id)}

  def handle_continue(:boot, %{run: %{kind: "workflow"}} = state) do
    state = load_nodes(state)
    wf = state.workflow.wf

    {node_id, state} =
      case state.run.root_node_id && state.nodes[state.run.root_node_id] do
        nil ->
          {node, state} =
            do_register_node(state, %{
              kind: "workflow",
              parent_id: nil,
              name: wf.display_name,
              role: "workflow",
              title: wf.display_name,
              depth: 0,
              status: "running"
            })

          {node.id, update_run(state, %{root_node_id: node.id})}

        node ->
          {node.id, put_node(state, node.id, %{status: "running", finished_at: nil})}
      end

    runner_args = %{
      run_id: state.run.id,
      conversation_id: state.conversation.id,
      project: state.project,
      settings: state.settings,
      root_node_id: node_id,
      wf: wf,
      ast: state.workflow.ast,
      meta: state.workflow.meta,
      args: state.workflow.args,
      answer: state.workflow[:answer],
      phase: wf.phase
    }

    child = %{
      id: :workflow_runner,
      start: {SwarmCode.Domain.Workflows.Runner, :start_link, [runner_args]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(AgentsSup.via(state.run.id), child) do
      {:ok, pid} ->
        {:noreply,
         %{state | root_node_id: node_id, runner: pid, runner_ref: Process.monitor(pid)}}

      other ->
        workflow_finished(state.run.id, "failed", %{
          pause_message:
            "could not start the workflow runner: " <>
              SwarmCode.Domain.LLM.HTTP.redact(inspect(other))
        })

        {:noreply, %{state | root_node_id: node_id}}
    end
  end

  # Spec 24 §3.4: a research run's root node has no agent of its own — the
  # `Research.Server` drives every step — so nothing here starts one, and the
  # run stays open until `research_finished/3` says otherwise.
  def handle_continue(:boot, %{run: %{kind: "research"}} = state) do
    state = load_nodes(state)

    {node, state} =
      do_register_node(state, %{
        kind: "research",
        parent_id: nil,
        name: "Research",
        role: "research",
        title: "Research",
        depth: 0,
        prompt: state.run.prompt,
        status: "running"
      })

    state =
      %{state | root_node_id: node.id}
      |> update_run(%{root_node_id: node.id})

    SwarmCode.Domain.Research.Server.root_ready(state.research.id, node.id)
    {:noreply, state}
  end

  def handle_continue(:boot, state) do
    spec = root_spec(state)

    {node, state} =
      do_register_node(state, %{
        kind: "agent",
        parent_id: nil,
        name: spec.name,
        role: spec.role,
        title: spec.name,
        depth: 0,
        # Spec 22 §5.1: the `Prompt` panel of a card reads this.
        prompt: state.run.prompt,
        status: "running"
      })

    state =
      %{state | root_node_id: node.id}
      |> put_agent(node.id, new_agent(spec))
      |> update_run(%{root_node_id: node.id})

    # Spec 43 §1.4: the transcript window was only ever read by `root_spec/1`
    # above; the root agent now holds its own copy, and this one would have
    # stayed for the life of the run (and travelled with every `get_state/1`).
    state = %{state | history: []}

    # spec 73 T8: a chat run's `session_start` hook (spec 70 D3) used to run
    # inside `Engine.start_chat_turn` — the LiveView's send handler and the
    # Scheduler's tick — for up to its 30 s cap, on every turn. It is the run's
    # own work now: an owned task started here, its output merged into the
    # project instructions before the root agent starts, cancelled with the
    # run's other background work. Still once per turn, as hooks.ex documents.
    if state.run.kind == "chat",
      do: {:noreply, start_session_hook(state)},
      else: {:noreply, start_agent_process(state, node.id)}
  end

  # spec 73 T8: the hook runs off the state owner; `ProjectConfig.load/1` reads
  # the file there too. The generation is the isolation one — a stop bumps it,
  # so a result that lands after `cancel_background_work(:all)` is ignored.
  defp start_session_hook(state) do
    generation = state.isolation_generation
    root = state.project.root_path

    task =
      Task.Supervisor.async_nolink(SwarmCode.Domain.TaskSupervisor, fn ->
        result =
          try do
            SwarmCode.Domain.Hooks.run(:session_start, %{}, root)
          rescue
            error -> {:error, Exception.message(error)}
          catch
            kind, reason -> {:error, Exception.format_banner(kind, reason)}
          end

        {:session_hook, generation, result}
      end)

    %{state | pending_session_hook: %{task: task, generation: generation}}
  end

  # spec 73 T8: the root agent starts from here. `{:inject, text}` is appended
  # to the instructions and the root's system prompt is rebuilt from them; the
  # spec built at boot is kept otherwise (its `messages` may already carry a
  # steer that arrived while the hook ran).
  defp start_root_after_hook(state, result) do
    root_id = state.root_node_id

    state =
      case result do
        {:inject, text} when is_binary(text) and text != "" ->
          ctx = Map.get(state, :project_context) || %{}

          ctx =
            Map.update(ctx, :instructions, text, fn
              existing when is_binary(existing) and existing != "" ->
                existing <> "\n\n" <> text

              _empty ->
                text
            end)

          state = Map.put(state, :project_context, ctx)
          agent = state.agents[root_id]

          put_agent(state, root_id, %{
            agent
            | spec: %{agent.spec | system: root_spec(state).system}
          })

        {:error, reason} ->
          Logger.warning("swarm_code: session_start hook failed: #{task_reason(reason)}")
          state

        _ok ->
          state
      end

    case state.agents[root_id] do
      %{server: nil, result: nil} -> start_agent_process(state, root_id)
      _started_or_gone -> state
    end
  end

  @impl true
  def handle_call({:register_node, attrs}, _from, state) do
    {node, state} = do_register_node(state, attrs)
    {:reply, {:ok, node}, state}
  end

  def handle_call({:request_approval, node_id, permission, safety}, from, state) do
    # spec 66 T4: a dangerous command is asked about even when the class was
    # "always allow"ed. T5: a command whose family the project already approved
    # never gets here a second time.
    if safety != :dangerous and
         (MapSet.member?(state.always, always_key(state, node_id, permission)) or
            auto_approved?(state, node_id)) do
      {:reply, :approved, state}
    else
      timer = Process.send_after(self(), {:approval_timeout, node_id}, @approval_timeout_ms)

      state =
        state
        |> put_in([:approvals, node_id], %{
          from: from,
          timer: timer,
          permission: permission,
          safety: safety,
          requested_at: DateTime.utc_now()
        })
        # spec 66 T3: the card used to render the node title alone — "run: " and
        # 60 characters of the command — and `detail` said "awaiting approval".
        # The arguments were on the node the whole time.
        |> put_node(node_id, %{
          status: "awaiting_approval",
          detail: approval_detail(state, node_id),
          approval_prefix: approval_prefix(state, node_id, safety)
        })

      SwarmCode.Domain.Engine.Questions.put(
        state.conversation.id,
        state.run.id,
        node_id,
        :approval
      )

      state = notify_waiting(state, node_id)

      {:noreply, state}
    end
  end

  def handle_call({:ask_user, node_id, questions, timeout}, from, state) do
    # Spec 51 §5.4: `:infinity` installs no timer — the consensus gate waits
    # for the user's answer or their Stop, never for a clock.
    timer =
      if timeout == :infinity,
        do: nil,
        else: Process.send_after(self(), {:question_timeout, node_id}, timeout)

    first = questions |> List.first() |> then(&(&1 && &1["question"]))

    state =
      state
      |> put_in([:questions, node_id], %{
        from: from,
        timer: timer,
        questions: questions,
        answers: %{},
        requested_at: DateTime.utc_now()
      })
      |> put_node(node_id, %{status: "awaiting_answer", detail: first})

    SwarmCode.Domain.Engine.Questions.put(state.conversation.id, state.run.id, node_id)
    state = notify_waiting(state, node_id)

    Events.broadcast(
      state.conversation.id,
      {:question, state.run.id, node_id, questions}
    )

    {:noreply, flush(state)}
  end

  # Spec 37 §4.2: `submit_plan` asks for the config and claims a round in one
  # call, so the rounds can never run away even if the planner loops.
  def handle_call({:consensus_round, stage}, _from, state) do
    case Map.get(state, :consensus) do
      nil ->
        {:reply, {nil, 0, nil}, state}

      config ->
        round = Map.get(state.consensus_rounds, stage, 0) + 1
        state = %{state | consensus_rounds: Map.put(state.consensus_rounds, stage, round)}
        # Spec 51 §5.6: the previous verdict of this stage rides along.
        {:reply, {config, round, Map.get(state.consensus_verdicts, stage)}, state}
    end
  end

  def handle_call(:consensus_config, _from, state),
    do: {:reply, Map.get(state, :consensus), state}

  # Spec 45 §5.2: nothing is killed — every live agent is told to hold before
  # its next think step, the queue stops admitting, the run row says so.
  def handle_call(:pause, _from, %{paused?: true} = state), do: {:reply, :ok, state}

  def handle_call(:pause, _from, state) do
    Enum.each(live_agent_servers(state), &SwarmCode.Domain.Engine.AgentServer.pause/1)

    state =
      %{state | paused?: true}
      |> update_run(%{status: "paused"})
      |> announce_run()

    {:reply, :ok, state}
  end

  def handle_call(:continue, _from, %{paused?: false} = state), do: {:reply, :ok, state}

  def handle_call(:continue, _from, state) do
    Enum.each(live_agent_servers(state), &SwarmCode.Domain.Engine.AgentServer.continue/1)

    state =
      %{state | paused?: false}
      |> update_run(%{status: "running"})
      |> announce_run()
      |> drain_queue()

    {:reply, :ok, state}
  end

  def handle_call({:start_agent, %{role: "worker"} = attrs}, _from, state) do
    name = String.slice(to_string(attrs.name), 0, 24)
    opts = attrs.opts || []
    capability = opts[:capability] || :read_only
    schema = opts[:schema]

    # Spec 25 §1.3: a skill's instructions, appended verbatim.
    system =
      Prompts.worker(
        state.project,
        name,
        Keyword.merge(prompt_opts(state), capability: capability)
      ) <>
        if(schema, do: Prompts.structured_output_note(), else: "") <>
        case opts[:system_extra] do
          text when is_binary(text) and text != "" -> "\n\n" <> text
          _other -> ""
        end

    tools =
      Tools.for_worker(capability, state.project.id) ++
        if(schema, do: [Tools.structured_output_ref(schema)], else: [])

    spec = %{
      name: name,
      role: "worker",
      system: system,
      messages: [
        %{role: "user", content: Prompts.worker_user(attrs.prompt, opts[:context])}
        |> maybe_images(opts[:images])
      ],
      # Spec 24 §3.3: a research resolves its own per-tier model and hands the
      # pair over already resolved, so it never falls into the workflow defaults.
      model:
        opts[:model_map] ||
          SwarmCode.Domain.Workflows.resolve_model(opts, state.settings, state.conversation) ||
          state.chat_model,
      depth: 1,
      project_root: state.project.root_path,
      tools: tools,
      max_turns: opts[:max_turns] || state.settings.max_agent_turns,
      effort: SwarmCode.Domain.Workflows.effort(opts, state.settings),
      require_tool: if(schema, do: "structured_output"),
      isolation: opts[:isolation] || :shared,
      # Spec 26 §5.3: an agent whose whole answer is one huge tool call can ask
      # for a bigger output budget; everything else takes the Request default.
      max_tokens: opts[:max_tokens]
    }

    # Spec 45 §5.2: a paused run admits nothing — the worker waits in the queue.
    queued? = state.active_sub >= state.max_live or state.paused?

    {node, state} =
      do_register_node(state, %{
        kind: "agent",
        parent_id: attrs.parent_id,
        name: name,
        role: "worker",
        title: name,
        depth: 1,
        prompt: attrs.prompt,
        phase: attrs[:phase],
        group: attrs[:group],
        status: if(queued?, do: "queued", else: "running")
      })

    state = put_agent(state, node.id, new_agent(spec))

    # Spec 13 §11 A-5: the caller is answered before the git worktree is set
    # up, so a slow repo can never fail the workflow that asked for the agent.
    if queued? do
      {:reply, {:ok, node.id}, %{state | queue: state.queue ++ [node.id]}}
    else
      {:reply, {:ok, node.id}, reserve_slot(state, node.id),
       {:continue, {:start_agent_process, node.id}}}
    end
  end

  # spec 67 T11 (G39): the spawn queue is unbounded — forty `spawn_agent`
  # calls in one response are forty billed children, and a lead that keeps
  # delegating never meets a wall. Codex caps a tree at six live agents; this
  # is a cap on the whole run, high enough that no honest swarm reaches it, and
  # the refusal is a normal tool error the model can read and work around.
  @max_agents_per_run 24

  def handle_call({:start_agent, attrs}, _from, state) do
    if sub_agents(state) >= @max_agents_per_run do
      {:reply,
       {:error,
        "agent limit reached (#{@max_agents_per_run} per run) — do the rest of this work yourself"},
       state}
    else
      name = String.slice(attrs.name, 0, 24)

      # Nested agents branch from their parent's worktree, so the isolation base is
      # the root of the agent that owns the spawn_agent op.
      parent_root = agent_root(state, attrs.parent_id)

      # spec 72 A3: resolve model, effort, max_turns and system prompt from
      # the agent definition and per-spawn overrides.
      agent_def = Map.get(attrs, :agent_def)

      # Model resolution order: the explicit per-spawn override, the agent
      # definition's model (looked up against the configured providers), the
      # run's swarm_model || chat_model.
      default_model = state.swarm_model || state.chat_model

      def_model =
        if agent_def != nil and is_binary(agent_def.model) and agent_def.model != "",
          do: resolve_model_name(agent_def.model, state)

      override_model =
        case Map.get(attrs, :model_override) do
          name when is_binary(name) and name != "" -> resolve_model_name(name, state)
          _none -> nil
        end

      resolved_model = override_model || def_model || default_model

      resolved_effort =
        resolve_agent_effort(
          Map.get(attrs, :effort_override),
          agent_def,
          state
        )

      resolved_max_turns =
        if agent_def, do: agent_def.max_turns, else: nil

      # spec 72 C5: structured output schema for sub-agents.
      output_schema = if is_map(attrs[:output_schema]), do: attrs[:output_schema]

      # spec 72 A3: append the agent definition's system_prompt_addition;
      # spec 72 C5: the structured-output note when a schema was given.
      # spec 73 T7: kept apart from the base as `system_extra` — the isolated
      # clause of `agent_system/4` rebuilds the base for the worktree root and
      # used to drop both, so every isolated `implementer` ran without its
      # definition and every isolated schema worker without the note.
      system_extra =
        if(agent_def && agent_def.system_prompt_addition,
          do: "\n" <> agent_def.system_prompt_addition <> "\n",
          else: ""
        ) <>
          if(output_schema, do: Prompts.structured_output_note(), else: "")

      system = Prompts.sub_agent(state.project, name, prompt_opts(state)) <> system_extra

      # spec 72 A5: prewalk state — start on the strong model, switch to the
      # cheap model at first edit. Only when the definition declares prewalk: true
      # and there is no explicit model_override (which would mean the caller
      # chose exactly which model they want).
      prewalk? = agent_def != nil and agent_def.prewalk and Map.get(attrs, :model_override) == nil
      # spec 72 R8: with no model in the definition the hand-off was
      # swarm -> swarm, a no-op; the spec's cheap side is the chat model.
      prewalk_model = if prewalk?, do: def_model || state.chat_model || default_model
      start_model = if prewalk?, do: default_model, else: resolved_model

      spec = %{
        name: name,
        role: "sub",
        system: system,
        # spec 73 T7: what `agent_system/4` appends again after the base.
        system_extra: system_extra,
        messages: [%{role: "user", content: Prompts.sub_agent_user(attrs.task, attrs.context)}],
        model: start_model,
        depth: attrs.depth,
        project_root: parent_root,
        effort: resolved_effort,
        max_turns: resolved_max_turns,
        # spec 72 A4: tool allow-list from agent definition
        tool_allow_list: if(agent_def, do: agent_def.tools, else: nil),
        # spec 72 A5: prewalk state
        prewalk: prewalk?,
        prewalk_model: prewalk_model,
        # spec 72 C5: tools and require_tool for structured output.
        output_schema: output_schema,
        require_tool: if(output_schema, do: "structured_output")
      }

      queued? = state.active_sub >= state.max_live or state.paused?

      {node, state} =
        do_register_node(state, %{
          kind: "agent",
          parent_id: attrs.parent_id,
          name: name,
          role: "sub",
          title: name,
          depth: attrs.depth,
          prompt: attrs.task,
          status: if(queued?, do: "queued", else: "running")
        })

      state = put_agent(state, node.id, new_agent(spec))

      if queued? do
        {:reply, {:ok, node.id}, %{state | queue: state.queue ++ [node.id]}}
      else
        {:reply, {:ok, node.id}, reserve_slot(state, node.id),
         {:continue, {:start_agent_process, node.id}}}
      end
    end
  end

  def handle_call({:await_agent, node_id, awaiting}, from, state) do
    case state.agents[node_id] do
      nil ->
        {:reply, {:error, "unknown agent"}, state}

      %{result: nil} ->
        # Spec 51 §5.1: a parent that waits for its child does no work; its
        # slot goes to the queue (the child, usually). Nothing is re-acquired:
        # complete_agent/kill_agent take the `slot: false` branch of
        # release_slot/2 when this parent ends.
        state =
          if is_binary(awaiting) and match?(%{slot: true}, state.agents[awaiting]),
            do: release_slot(state, awaiting),
            else: state

        # Spec 51 §2.8: one pending reply per caller pid — a caller that timed
        # out and asks again must not collect a second entry every 5 s.
        agent = state.agents[node_id]
        waiting = [from | Enum.reject(agent.waiting, &(elem(&1, 0) == elem(from, 0)))]
        {:noreply, put_agent(state, node_id, %{agent | waiting: waiting})}

      %{result: result} ->
        {:reply, result, state}
    end
  end

  # spec 70 C6: register a background agent for result injection.
  #
  # spec 73 T56: the registration lands after `start_agent` replied, and a
  # start failure casts `agent_finished` to this process first — so the entry
  # used to be added after the result had already passed through
  # `inject_background_result/3`, and the parent waited for a notification
  # that never came. An agent that has already settled is reported now. The
  # watchdog is the RunServer's own timer (`sub_agent_timeout_s`), cancelled
  # when the agent completes or is killed, instead of a bare `spawn` sleeping
  # for thirty minutes after the run.
  def handle_call({:register_background, agent_id, parent_id}, _from, state) do
    state = %{state | background_agents: Map.put(state.background_agents, agent_id, parent_id)}

    case state.agents[agent_id] do
      %{result: nil} = agent ->
        timer = arm_background_timeout(state, agent_id)
        {:reply, :ok, put_agent(state, agent_id, %{agent | background_timer: timer})}

      %{result: result} ->
        {:reply, :ok, inject_background_result(state, agent_id, result)}

      nil ->
        {:reply, :ok, state}
    end
  end

  # spec 72 C1: deliver a message to an agent's mailbox.
  #
  # spec 73 T9: one delivery path. `message_agent` used to go through `steer`
  # (a `user_message` cast, never the mailbox) while this clause both queued
  # and cast — so a `wait_for_message` waiter could only wake on a broadcast,
  # and a broadcast was read twice (steer + inbox). Now a message is handed to
  # a blocked waiter or queued, and the AgentServer drains its mailbox before
  # each think step (`start_llm/1`): the model still sees it in the next step,
  # `inbox` still returns what arrived since the last one, and a full mailbox
  # still answers the sender with an error.
  def handle_call({:deliver_message, from_id, to_id, text}, _from, state) do
    from_name = get_in(state.nodes, [from_id, Access.key(:name)]) || "agent"

    case enqueue_message(state, to_id, %{from: from_name, text: text}) do
      {:ok, state} ->
        {:reply, :ok, state}

      :full ->
        {:reply,
         {:error,
          "recipient mailbox is full (#{@mailbox_cap} messages) — wait for it to drain its inbox"},
         state}
    end
  end

  # spec 72 R7
  def handle_call({:node_error_kind, node_id}, _from, state),
    do: {:reply, get_in(state.nodes, [node_id, Access.key(:error_kind)]), state}

  # spec 73 T58
  def handle_call(:live_agent_names, _from, state) do
    names =
      for {id, %{result: nil}} <- state.agents,
          name = get_in(state.nodes, [id, Access.key(:name)]),
          is_binary(name),
          do: {id, name}

    {:reply, names, state}
  end

  # spec 73 T100
  def handle_call({:node_field, node_id, field}, _from, state),
    do: {:reply, get_in(state.nodes, [node_id, Access.key(field)]), state}

  # spec 73 T17
  def handle_call({:agent_result, node_id}, _from, state) do
    reply =
      case state.agents[node_id] do
        nil -> :unknown
        %{result: nil} -> :running
        %{result: result} -> {:done, result}
      end

    {:reply, reply, state}
  end

  # spec 72 C1: drain all pending messages from an agent's mailbox.
  def handle_call({:drain_inbox, node_id}, _from, state) do
    {messages, mailboxes} = Map.pop(state.mailboxes, node_id, [])
    {:reply, messages, %{state | mailboxes: mailboxes}}
  end

  # spec 72 C2: block until a message arrives in the agent's mailbox, with timeout.
  def handle_call({:wait_for_message, node_id, timeout_ms, awaiting}, from, state) do
    mailbox = Map.get(state.mailboxes, node_id, [])

    if mailbox != [] do
      # Immediate: return the first message, leave the rest
      [message | rest] = mailbox
      state = %{state | mailboxes: Map.put(state.mailboxes, node_id, rest)}
      {:reply, {:ok, message}, state}
    else
      # Block: register a waiter, release slot like spawn_agent await
      state =
        if is_binary(awaiting) and match?(%{slot: true}, state.agents[awaiting]),
          do: release_slot(state, awaiting),
          else: state

      # spec 72 R6: the deadline used to be checked on the flush tick, which
      # only `mark_dirty/3` arms — in an idle run nobody swept it, the tool's
      # own call timed out and the stale waiter later swallowed a real
      # message. Every waiter owns a timer; a wake cancels it.
      ref = make_ref()
      timer = Process.send_after(self(), {:message_wait_timeout, ref}, timeout_ms)
      waiter = %{ref: ref, timer: timer, from: from, node_id: node_id, awaiting: awaiting}

      state = %{state | message_waiters: [waiter | state.message_waiters]}
      {:noreply, state}
    end
  end

  # spec 72 C3: broadcast a message to all live agents in the run except the sender.
  def handle_call({:broadcast, from_id, text}, _from, state) do
    from_name = get_in(state.nodes, [from_id, Access.key(:name)]) || "agent"

    targets =
      for {id, %{result: nil, server: server}} <- state.agents,
          id != from_id,
          is_pid(server),
          Process.alive?(server),
          do: id

    # spec 73 T9: the same path as a direct message (a waiter wakes, or the
    # mailbox queues); full mailboxes are still skipped silently on broadcast.
    state =
      Enum.reduce(targets, state, fn to_id, acc ->
        case enqueue_message(acc, to_id, %{from: from_name, text: text, broadcast?: true}) do
          {:ok, acc} -> acc
          :full -> acc
        end
      end)

    {:reply, :ok, state}
  end

  def handle_call(:stop_workers, _from, state) do
    ids =
      for {id, node} <- state.nodes,
          node.role == "worker",
          node.status not in @finished,
          do: id

    stopped_ids =
      ids
      |> Enum.flat_map(&subtree(state, &1))
      |> MapSet.new()

    state =
      state
      |> settle_pending_interactions(stopped_ids)
      |> cancel_background_work(stopped_ids)
      # Spec 36 §A9: the ids being stopped leave the queue BEFORE the reduce,
      # not after. Each `kill_agent` releases a slot, and `start_queued/1` would
      # happily pop a queued worker that is itself in `ids` and start it — the
      # reduce then reached an agent it had just brought to life.
      |> then(fn state -> %{state | queue: Enum.reject(state.queue, &(&1 in ids))} end)
      |> then(fn state ->
        Enum.reduce(ids, state, fn id, acc ->
          acc
          |> kill_agent(id)
          |> mark_subtree_stopped(id)
          |> settle(id, {:error, "stopped"})
        end)
      end)

    {:reply, :ok, %{state | queue: []}}
  end

  def handle_call(:stop, _from, state) do
    # spec 55 T8: a busy terminal write keeps the process for `:finish_retry`.
    state = stop_everything(state)

    if state.finish_pending do
      # spec 60 T1: the process stays for the retry; the agents do not.
      Enum.each(state.agents, fn {_id, agent} -> stop_agent_async(state.run.id, agent) end)
      {:reply, :ok, state}
    else
      {:stop, :normal, :ok, state}
    end
  end

  def handle_call({:stop_agent, node_id}, from, state) do
    if node_id == state.root_node_id,
      do: handle_call(:stop, from, state),
      else: {:reply, :ok, stop_subtree(state, node_id, "user_stopped", "was stopped by the user")}
  end

  # spec 72 B7: a timed-out sub-agent gets :spawn_timeout, not :user_stopped.
  def handle_call({:stop_agent_timeout, node_id}, from, state) do
    case state.agents[node_id] do
      %{result: nil} ->
        if node_id == state.root_node_id,
          do: handle_call(:stop, from, state),
          else: {:reply, :ok, stop_subtree(state, node_id, "spawn_timeout", "timed out")}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:steer, text, images, node_id}, _from, state) do
    target = node_id || state.root_node_id

    case state.agents[target] do
      # Spec 51 §5.9 (b): a queued worker has no server yet; the text joins
      # its opening messages (§2.2 drops them from this map only at start).
      %{server: nil, result: nil, spec: %{messages: messages} = spec} = agent ->
        message = %{role: "user", content: to_string(text)}
        message = if images == [], do: message, else: Map.put(message, :images, images)
        spec = %{spec | messages: messages ++ [message]}
        {:reply, :ok, put_agent(state, target, %{agent | spec: spec})}

      # Spec 43 §1.5 (B6): a cast to a pid that has already exited is silently
      # lost, and the caller would then persist a message nobody read.
      %{server: server, result: nil} when is_pid(server) ->
        if Process.alive?(server) do
          SwarmCode.Domain.Engine.AgentServer.user_message(server, text, images)
          {:reply, :ok, state}
        else
          {:reply, {:error, :finished}, state}
        end

      _ ->
        {:reply, {:error, :finished}, state}
    end
  end

  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  def handle_call(:pending_interactions, _from, state) do
    rows =
      SwarmCode.Domain.Engine.PendingInteractions.rows(
        state.approvals,
        state.questions,
        state.nodes,
        # the fixture states of the unit tests carry no project
        Map.get(Map.get(state, :project) || %{}, :root_path)
      )

    {:reply, rows, state}
  end

  def handle_call({:answer_question, node_id, index, option_indices, custom}, _from, state) do
    with {:ok, entry} <-
           SwarmCode.Domain.Engine.PendingInteractions.pending_question_entry(
             state.questions,
             node_id,
             index
           ),
         {:ok, answer} <-
           SwarmCode.Domain.Engine.PendingInteractions.validated_answer(
             entry.questions,
             index,
             option_indices,
             custom
           ) do
      answers = Map.put(Map.get(entry, :answers, %{}), index, answer)
      entry = Map.put(entry, :answers, answers)

      if map_size(answers) == length(entry.questions) do
        ordered = Enum.map(0..(length(entry.questions) - 1), &Map.fetch!(answers, &1))
        # Keep the same reply, timer, node, ETS, event and flush behavior as the
        # existing answer cast. That path owns final interaction settlement.
        {:noreply, next} = handle_cast({:answer, node_id, ordered}, state)
        {:reply, :ok, next}
      else
        next = put_in(state.questions[node_id], entry)
        Events.broadcast(state.conversation.id, {:waiting_changed})
        {:reply, :ok, next}
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call(:pending_questions, _from, state) do
    {:reply, Enum.map(state.questions, fn {node_id, %{questions: qs}} -> {node_id, qs} end),
     state}
  end

  @impl true
  def handle_cast({:update_node, node_id, attrs}, state) do
    {:noreply, put_node(state, node_id, attrs)}
  end

  def handle_cast({:reasoning_delta, node_id, text}, state) do
    case state.nodes[node_id] do
      nil ->
        {:noreply, state}

      node ->
        state = put_stream(state, node_id, :reasoning, text)

        state =
          if assistant_channel?(state, node) do
            delta =
              separator(state.last_reasoning_node, node_id, state.assistant_reasoning) <> text

            %{
              state
              | assistant_reasoning: Chunks.append(state.assistant_reasoning, delta),
                pending_reasoning: Chunks.append(state.pending_reasoning, delta),
                last_reasoning_node: node_id
            }
            |> count_assistant(node_id, :a_reasoning, delta)
          else
            state
          end

        {:noreply, state}
    end
  end

  def handle_cast({:text_delta, node_id, text}, state) do
    case state.nodes[node_id] do
      nil ->
        {:noreply, state}

      node ->
        state = put_stream(state, node_id, :text, text)

        state =
          if assistant_channel?(state, node) do
            # A new llm op of the root agent = a new turn: separate turns with a blank line.
            delta = separator(state.last_text_node, node_id, state.assistant_text) <> text

            %{
              state
              | assistant_text: Chunks.append(state.assistant_text, delta),
                pending_delta: Chunks.append(state.pending_delta, delta),
                last_text_node: node_id
            }
            |> count_assistant(node_id, :a_text, delta)
          else
            state
          end

        {:noreply, state}
    end
  end

  def handle_cast({:set_label, label}, state) do
    {:noreply, %{state | run: %{state.run | label: label}}}
  end

  def handle_cast({:text_reset, node_id}, state) do
    stream = Map.get(state.stream, node_id, %{})
    dropped = Map.get(stream, :a_text, 0)

    state = %{
      state
      | stream: Map.put(state.stream, node_id, reset_stream_channel(stream, :text)),
        # Whatever is left at the tail belongs to an earlier operation, so the
        # retry starts its own paragraph again.
        last_text_node: previous_marker(state.last_text_node, node_id)
    }

    state = put_node(state, node_id, %{detail: "retrying…"})

    assistant_text = Chunks.to_string(state.assistant_text)

    kept =
      if dropped > 0 do
        String.slice(
          assistant_text,
          0,
          max(String.length(assistant_text) - dropped, 0)
        )
      else
        assistant_text
      end

    if state.assistant_message do
      Events.broadcast(
        state.conversation.id,
        {:assistant_reset, state.assistant_message.id, kept}
      )
    end

    {:noreply, %{state | assistant_text: Chunks.new(kept), pending_delta: Chunks.new()}}
  end

  def handle_cast({:reasoning_reset, node_id}, state) do
    stream = Map.get(state.stream, node_id, new_stream())
    dropped = Map.get(stream, :a_reasoning, 0)

    state = %{
      state
      | stream: Map.put(state.stream, node_id, reset_stream_channel(stream, :reasoning)),
        last_reasoning_node: previous_marker(state.last_reasoning_node, node_id)
    }

    reasoning = Chunks.to_string(state.assistant_reasoning)

    kept =
      if dropped > 0,
        do: String.slice(reasoning, 0, max(String.length(reasoning) - dropped, 0)),
        else: reasoning

    if state.assistant_message do
      Events.broadcast(
        state.conversation.id,
        {:reasoning_reset, state.assistant_message.id, kept}
      )
    end

    {:noreply,
     %{
       state
       | assistant_reasoning: Chunks.new(kept),
         pending_reasoning: Chunks.new()
     }}
  end

  def handle_cast({:resolve_approval, node_id, decision}, state) do
    case Map.pop(state.approvals, node_id) do
      {nil, _} ->
        {:noreply, state}

      {%{from: from, timer: timer, permission: permission} = approval, approvals} ->
        Process.cancel_timer(timer)

        {reply, state} =
          case decision do
            :approve ->
              {:approved, state}

            :deny ->
              {:denied, state}

            # spec 66 T21: deny *and* stop, for "no, and stop trying" — a plain
            # Deny still lets the agent pick something else, which is often what
            # the user means.
            :deny_stop ->
              {:denied, state}

            # spec 67 T11 (B22): the class pill is keyed by the tool as well as
            # the permission. "Always allow" on a `run_command` used to put
            # `:execute` in the set — and `:execute` is also every writing MCP
            # tool and `workflow_run`, so one yes to one shell command approved
            # a class of calls the user was never shown.
            :always ->
              {:approved,
               %{state | always: MapSet.put(state.always, always_key(state, node_id, permission))}}

            # spec 66 T5: one command family, remembered on the project. A
            # dangerous command is approved this once and never remembered.
            # spec 67 T11 (B9): the family is the one the *server* computed for
            # this node (`approval_prefix`, written when the approval was
            # raised), never the one the browser sent back. A stale card or a
            # crafted event used to remember any family it liked, on the
            # project, for every later run.
            {:always_prefix, _client_prefix} ->
              prefix = node_prefix(state, node_id)

              if Map.get(approval, :safety) == :dangerous or prefix in [nil, ""] do
                {:approved, state}
              else
                {:approved, remember_prefix(state, prefix)}
              end
          end

        GenServer.reply(from, reply)

        state =
          %{state | approvals: approvals}
          |> put_node(node_id, %{status: "running", detail: nil, approval_prefix: nil})

        SwarmCode.Domain.Engine.Questions.delete(state.run.id, node_id)

        if decision == :deny_stop, do: stop_after_deny(state), else: {:noreply, state}
    end
  end

  def handle_cast({:answer, node_id, answers}, state) do
    case Map.pop(state.questions, node_id) do
      {nil, _} ->
        {:noreply, state}

      {%{from: from, timer: timer}, questions} ->
        cancel_timer(timer)
        GenServer.reply(from, {:ok, answers})

        state =
          %{state | questions: questions}
          |> put_node(node_id, %{status: "running", detail: nil})

        SwarmCode.Domain.Engine.Questions.delete(state.run.id, node_id)
        Events.broadcast(state.conversation.id, {:question_cleared, state.run.id, node_id})
        {:noreply, flush(state)}
    end
  end

  # Spec 51 §5.6
  def handle_cast({:consensus_verdict, stage, verdict}, state),
    do:
      {:noreply, %{state | consensus_verdicts: Map.put(state.consensus_verdicts, stage, verdict)}}

  # Spec 51 §5.8: the round's outcome lives on the run row from the moment it
  # is produced — the prune may null the judge's text later, the card still
  # reads the verdict. No migration: `runs.consensus_config` is a map column.
  def handle_cast({:consensus_round_done, entry}, state) do
    config = state.run.consensus_config || %{}
    rounds = List.wrap(config["rounds_done"]) ++ [entry]
    {:noreply, update_run(state, %{consensus_config: Map.put(config, "rounds_done", rounds)})}
  end

  def handle_cast({:research_finished, status, attrs}, state) do
    {:stop, :normal, finish_research(state, status, attrs)}
  end

  def handle_cast({:workflow_finished, status, attrs}, state) do
    {:stop, :normal, finish_workflow(state, status, attrs)}
  end

  # Spec 43 §1.2 (B1): an agent the user just stopped may still get its last
  # cast in; a settled node keeps what the stop wrote.
  def handle_cast({:agent_finished, node_id, result}, state) do
    if live_node?(state, node_id),
      do: begin_agent_completion(state, node_id, result),
      else: {:noreply, state}
  end

  @impl true
  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush_ref: nil})}

  # spec 72 R6: a wait_for_message waiter's own deadline.
  def handle_info({:message_wait_timeout, ref}, state) do
    case Enum.split_with(state.message_waiters, &(&1.ref == ref)) do
      {[waiter], rest} ->
        GenServer.reply(waiter.from, {:error, :timeout})
        {:noreply, %{state | message_waiters: rest}}

      {[], _all} ->
        {:noreply, state}
    end
  end

  # spec 55 T8 (55a A2): the bounded retry of a busy terminal write.
  def handle_info(:finish_retry, %{finish_pending: %{status: s, result: r}} = state),
    do: finish_run(state, s, r) |> stop_or_retry()

  def handle_info(:finish_retry, state), do: {:noreply, state}

  def handle_info({ref, {:isolated, generation, node_id, result}}, state)
      when is_reference(ref) do
    case Map.get(state.pending_isolation, node_id) do
      %{task: %Task{ref: ^ref}} ->
        Process.demonitor(ref, [:flush])
        state = %{state | pending_isolation: Map.delete(state.pending_isolation, node_id)}

        if generation == state.isolation_generation and live_node?(state, node_id) do
          {:noreply, apply_isolation(state, node_id, result)}
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  # spec 73 T56: the background agent's clock ran out — the same stop the
  # foreground watchdog asks for (spec 72 B7), and the parent hears of it.
  def handle_info({:background_timeout, node_id}, state) do
    case state.agents[node_id] do
      %{result: nil} -> {:noreply, stop_subtree(state, node_id, "spawn_timeout", "timed out")}
      _settled -> {:noreply, state}
    end
  end

  # spec 73 T8
  def handle_info(
        {ref, {:session_hook, generation, result}},
        %{pending_session_hook: %{task: %Task{ref: ref}}} = state
      )
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    state = %{state | pending_session_hook: nil}

    if generation == state.isolation_generation and live_node?(state, state.root_node_id),
      do: {:noreply, start_root_after_hook(state, result)},
      else: {:noreply, state}
  end

  def handle_info({ref, {:finalized, generation, node_id, result}}, state)
      when is_reference(ref) do
    case Map.get(state.pending_finalization, node_id) do
      %{task: %Task{ref: ^ref}, original: original} ->
        Process.demonitor(ref, [:flush])

        state = %{
          state
          | pending_finalization: Map.delete(state.pending_finalization, node_id)
        }

        if generation == state.finalization_generation and live_node?(state, node_id) do
          {state, completed} = finalized_result(state, node_id, original, result)
          complete_agent(state, node_id, completed)
        else
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:approval_timeout, node_id}, state) do
    case Map.pop(state.approvals, node_id) do
      {nil, _} ->
        {:noreply, state}

      {%{from: from}, approvals} ->
        GenServer.reply(from, :timeout)
        SwarmCode.Domain.Engine.Questions.delete(state.run.id, node_id)
        {:noreply, %{state | approvals: approvals}}
    end
  end

  def handle_info({:question_timeout, node_id}, state) do
    case Map.pop(state.questions, node_id) do
      {nil, _} ->
        {:noreply, state}

      # Spec 51 §5.4: a question asked with `timeout: :infinity` has no clock;
      # a stray timeout message for it changes nothing.
      {%{timer: nil}, _} ->
        {:noreply, state}

      {%{from: from}, questions} ->
        GenServer.reply(from, {:error, "no answer"})
        SwarmCode.Domain.Engine.Questions.delete(state.run.id, node_id)
        Events.broadcast(state.conversation.id, {:question_cleared, state.run.id, node_id})
        {:noreply, %{state | questions: questions}}
    end
  end

  # Spec 33 §2: every terminal path in the Runner casts `workflow_finished`
  # first, and that cast stops *this* process — so a DOWN that gets here at all
  # means the program is gone with nothing reported, whatever its exit reason.
  # A `:normal` loss used to just clear the ref: the run stayed `running` with
  # no runner, unresumable and unstoppable until the app restarted.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{runner_ref: ref} = state) do
    message =
      if reason in [:normal, :shutdown] do
        "the workflow runner stopped before reporting a result"
      else
        "the workflow runner crashed: " <>
          (reason |> inspect() |> SwarmCode.Domain.LLM.HTTP.redact() |> String.slice(0, 200))
      end

    state = %{state | runner: nil, runner_ref: nil}
    {:stop, :normal, finish_workflow(state, "failed", %{pause_message: message})}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case pending_task(state.pending_isolation, ref) do
      {node_id, %{generation: generation}} ->
        state = %{state | pending_isolation: Map.delete(state.pending_isolation, node_id)}

        if generation == state.isolation_generation and live_node?(state, node_id) do
          {:noreply, apply_isolation(state, node_id, {:error, task_reason(reason)})}
        else
          {:noreply, state}
        end

      nil ->
        handle_non_isolation_down(ref, reason, state)
    end
  end

  # Spec 51 §4.3: an exit signal from anything but the parent (which GenServer
  # answers itself) still ends the run — through `terminate/2`, which writes the
  # row — instead of being swallowed as a message.
  def handle_info({:EXIT, _from, reason}, state) when reason != :normal,
    do: {:stop, reason, state}

  def handle_info(_other, state), do: {:noreply, state}

  # spec 73 T8: a crashed hook task never blocks the turn.
  defp handle_non_isolation_down(
         ref,
         reason,
         %{pending_session_hook: %{task: %Task{ref: ref}, generation: generation}} = state
       ) do
    state = %{state | pending_session_hook: nil}

    if generation == state.isolation_generation and live_node?(state, state.root_node_id),
      do: {:noreply, start_root_after_hook(state, {:error, task_reason(reason)})},
      else: {:noreply, state}
  end

  defp handle_non_isolation_down(ref, reason, state) do
    case pending_task(state.pending_finalization, ref) do
      {node_id, %{generation: generation, original: original}} ->
        state = %{
          state
          | pending_finalization: Map.delete(state.pending_finalization, node_id)
        }

        if generation == state.finalization_generation and live_node?(state, node_id) do
          {state, completed} =
            finalized_result(state, node_id, original, {:error, task_reason(reason)})

          complete_agent(state, node_id, completed)
        else
          {:noreply, state}
        end

      nil ->
        handle_agent_down(ref, reason, state)
    end
  end

  defp handle_agent_down(ref, reason, state) do
    case Enum.find(state.agents, fn {_id, agent} -> agent.ref == ref end) do
      nil ->
        {:noreply, state}

      {node_id, _agent} ->
        node = state.nodes[node_id]

        if node == nil or node.status in @finished do
          {:noreply, state}
        else
          # Spec 51 §6.9: an exit reason carries the agent's state, and that
          # state carries the provider row — redact before it reaches the node.
          reason_text =
            reason |> inspect() |> SwarmCode.Domain.LLM.HTTP.redact() |> String.slice(0, 200)

          msg = "agent crashed: " <> reason_text

          state =
            state
            |> crash_cleanup(node_id)
            |> put_node(node_id, %{
              status: "failed",
              progress: 100,
              error: msg,
              detail: msg,
              # spec 67 T30 (G42): a crashed agent is SwarmCode's own fault.
              error_kind: "bug",
              finished_at: now()
            })
            |> settle(node_id, {:error, "Agent #{node.name || "agent"} crashed"})
            |> release_slot(node_id)

          if node_id == state.root_node_id do
            crash_msg =
              if state.run.kind == "chat",
                do: "The assistant process crashed: " <> reason_text,
                else: reason_text

            finish_run(state, "failed", {:error, crash_msg}, :bug) |> stop_or_retry()
          else
            {:noreply, state}
          end
        end
    end
  end

  # ------------------------------------------------------------------ nodes

  defp do_register_node(state, attrs) do
    position = state.position + 1

    defaults = %{
      id: Ecto.UUID.generate(),
      run_id: state.run.id,
      status: "running",
      started_at: now(),
      position: position,
      title: "",
      depth: 0
    }

    node = struct(Node, Map.merge(defaults, normalize(attrs)))

    # Spec 54 §1.1 (54a A1): the INSERT stays synchronous — `child_nodes/2`, the
    # Inspector and the message/run pairing read the row — but it can no longer
    # kill the run's sole state owner. A busy database is retried, and if it is
    # still busy the id waits in `uninserted` for the next flush's transaction.
    state =
      case Conversations.with_busy_retry(fn -> Conversations.insert_node(node_attrs(node)) end) do
        {:ok, _} ->
          state

        {:error, :database_busy} ->
          state = warn_busy(state, "insert node #{node.id}")
          %{state | uninserted: MapSet.put(state.uninserted, node.id)}

        # spec 67 T12 (B15): treated like a busy database. The node was put in
        # `state.nodes`, broadcast and returned `{:ok, node}` whatever happened
        # here, so a refused INSERT used to be a log line and then a row that
        # every later flush could not update ("node <id> is not in the table")
        # and that vanished on the next remount. The id waits in `uninserted`
        # and the flush's transaction tries the INSERT again.
        {:error, %Ecto.Changeset{} = cs} ->
          Logger.error("swarm_code db write failed: #{inspect(cs.errors)}")
          %{state | uninserted: MapSet.put(state.uninserted, node.id)}
      end

    # Spec 51 §2.3: prepend — the only reader (`subtree/2`) is order-insensitive.
    children = Map.update(state.children, node.parent_id, [node.id], &[node.id | &1])

    state =
      %{
        state
        | nodes: Map.put(state.nodes, node.id, node),
          children: children,
          position: position
      }
      |> mark_dirty(node.id)

    {node, state}
  end

  # `normalized?: true` — the caller already cut `detail` to one line of
  # `@detail_chars` (the streaming path, spec 43 §1.1); running `normalize/1`
  # again was a second unicode regex pass per token.
  defp put_node(state, node_id, attrs, opts \\ []) do
    case state.nodes[node_id] do
      nil ->
        state

      node ->
        attrs = if opts[:normalized?], do: Map.new(attrs), else: normalize(attrs)
        new = struct(node, attrs)

        persist? =
          new.status != node.status or Map.has_key?(attrs, :finished_at) or
            Enum.any?([:tokens_in, :tokens_out, :cost_usd], &Map.has_key?(attrs, &1)) or
            Map.has_key?(attrs, :result) or
            Map.has_key?(attrs, :turn) or Map.has_key?(attrs, :branch) or
            Map.has_key?(attrs, :changes_stat) or Map.has_key?(attrs, :integrated)

        # Spec 51 §2.5: register was the one full INSERT; everything after is
        # an UPDATE of the changed persisted columns — an agent's 20 KB prompt
        # is never rewritten on a status, turn or token change. A change that
        # did not trigger a write waits in `unsaved` for the next one that does.
        #
        # Spec 54 §1.1 (54a A1): and the write itself no longer happens here.
        # One autocommit UPDATE per node change was 322 write statements per
        # second under eight lanes, each its own acquisition of SQLite's single
        # writer lock — 7 ms for a 0.3 ms statement, and past `busy_timeout` a
        # raise that took the whole swarm down with the RunServer. The columns
        # accumulate in `unsaved`; `flush_writes/1` writes every node that has a
        # triggering change waiting in one IMMEDIATE transaction, 100 ms later
        # at the latest. What the UI shows comes from PubSub, not the row.
        # The *values* are captured here, not read back at flush time: a
        # finished op's `result` is replaced by its light projection a few lines
        # below, and the row must keep the whole text (spec 51 §2.2).
        changed = Map.new(attrs, fn {k, _} -> {k, Map.get(new, k)} end) |> Map.take(@persisted)
        pending = Map.merge(Map.get(state.unsaved, node_id, %{}), changed)

        state =
          cond do
            pending == %{} ->
              state

            persist? ->
              %{
                state
                | unsaved: Map.put(state.unsaved, node_id, pending),
                  persist_pending: MapSet.put(state.persist_pending, node_id)
              }

            true ->
              %{state | unsaved: Map.put(state.unsaved, node_id, pending)}
          end

        # Spec 51 §2.2: once a tool op is finished its full text lives in the
        # row (written just above); the state, the flush and every LiveView
        # keep the light shape (§1.10). The persisted fields of a finished op
        # never change again (mark_stopped/2 skips @finished), so the light
        # struct is never written back.
        new = if new.kind == "op" and new.status in @finished, do: Node.light(new), else: new

        state = %{state | nodes: Map.put(state.nodes, node_id, new)}

        # Spec 43 §1.4: a finished op's preview buffer has nothing left to feed.
        state =
          if new.kind == "op" and new.status in @finished and
               Map.has_key?(state.stream, node_id),
             do: %{state | stream: Map.delete(state.stream, node_id)},
             else: state

        state =
          if new.kind == "agent" and
               Enum.any?([:tokens_in, :tokens_out, :cost_usd], &Map.has_key?(attrs, &1)),
             do: bump_totals(state, node_id, new),
             else: state

        mark_dirty(state, node_id, MapSet.new(Map.keys(attrs)))
    end
  end

  defp normalize(attrs) do
    attrs = Map.new(attrs)

    # spec 66 T3: an approval keeps 2 000 characters and its line breaks — the
    # card renders it in a `<pre>`; every other detail is the 160-character
    # one-liner the collapsed rows have always shown.
    approval? = attrs[:status] == "awaiting_approval"
    chars = if approval?, do: @approval_detail_chars, else: @detail_chars
    scan = if approval?, do: 4 * @approval_detail_chars, else: @detail_scan_bytes

    attrs =
      if is_binary(attrs[:detail]),
        do:
          Map.put(
            attrs,
            :detail,
            attrs[:detail]
            |> head(scan)
            |> then(&if approval?, do: &1, else: one_line(&1))
            |> String.slice(0, chars)
            |> :binary.copy()
          ),
        else: attrs

    # `prompt` and `error` get the same 20 000-char cap `Node.changeset/2`
    # applies at the database (spec 51 §2.1).
    attrs
    |> cap(:result)
    |> cap(:prompt)
    |> cap(:error)
  end

  defp cap(attrs, key) do
    case attrs do
      %{^key => text} when is_binary(text) ->
        Map.put(attrs, key, own(String.slice(text, 0, 20_000), text))

      _ ->
        attrs
    end
  end

  # Spec 51 §2.1: a slice of a 100 KB tool output is a sub-binary that keeps the
  # 100 KB alive for the run's life and in every LiveView that holds the node;
  # copy when the slice is shorter than its parent — or when the text handed in
  # is itself a slice of something bigger (`referenced_byte_size/1` knows).
  defp own(slice, parent) when byte_size(slice) < byte_size(parent), do: :binary.copy(slice)

  defp own(slice, _parent) do
    if :binary.referenced_byte_size(slice) > byte_size(slice),
      do: :binary.copy(slice),
      else: slice
  end

  defp head(text, bytes) when byte_size(text) <= bytes, do: text

  defp head(text, bytes) do
    valid_head(binary_part(text, 0, bytes), 0)
  end

  defp valid_head(text, dropped) when dropped <= 3 do
    if String.valid?(text) do
      text
    else
      valid_head(binary_part(text, 0, byte_size(text) - 1), dropped + 1)
    end
  end

  # A grapheme split by the cut costs at most three bytes. Anything still
  # invalid after that is invalid *inside* the head — binary or latin-1 command
  # output — and must not take the run's state owner down with it: keep only the
  # valid prefix, which is what a preview wants anyway.
  defp valid_head(text, _dropped), do: valid_prefix(text, "")

  defp valid_prefix(<<>>, acc), do: acc

  defp valid_prefix(<<codepoint::utf8, rest::binary>>, acc),
    do: valid_prefix(rest, acc <> <<codepoint::utf8>>)

  defp valid_prefix(<<_byte, rest::binary>>, acc), do: valid_prefix(rest, acc)

  # Spec 51 §2.4: a byte walk that collapses runs of ASCII whitespace into one
  # space — the unicode regex it replaces cost ~85 µs per 800 chars and ran on
  # every streamed delta; this runs once per flush on ≤ 1 280 bytes.
  defp one_line(text), do: collapse_ws(text, <<>>, false)

  defp collapse_ws(<<>>, acc, _ws?), do: acc

  defp collapse_ws(<<c, rest::binary>>, acc, ws?) when c in [?\s, ?\t, ?\n, ?\r, ?\f, ?\v] do
    if ws?,
      do: collapse_ws(rest, acc, true),
      else: collapse_ws(rest, <<acc::binary, ?\s>>, true)
  end

  defp collapse_ws(<<c, rest::binary>>, acc, _ws?),
    do: collapse_ws(rest, <<acc::binary, c>>, false)

  defp last_chars(text, n) do
    if String.length(text) > n, do: String.slice(text, -n, n), else: text
  end

  # Live preview of an llm op: its answer text if it has any, otherwise its
  # reasoning. Both are accumulated per node so one never appends to the other.
  #
  # Spec 51 §2.4: O(1) per delta — a byte-bounded tail, no grapheme walk, no
  # regex. The one-line `detail` is derived once per flush from the dirty
  # entries (`flush_previews/1`).
  defp put_stream(state, node_id, key, text) do
    current = Map.get(state.stream, node_id, new_stream())

    current =
      current
      |> Map.put(key, tail_bytes(Map.fetch!(current, key) <> text, @stream_tail_bytes))
      |> Map.put(:dirty?, true)

    state = %{state | stream: Map.put(state.stream, node_id, current)}

    # A first delta after a retry means the transport is healthy again.
    state =
      if match?(%{status: "retrying"}, state.nodes[node_id]),
        do: put_node(state, node_id, %{status: "running"}, normalized?: true),
        else: state

    # `flush_previews/1` turns the accumulated stream into `detail` at the top
    # of the next flush — that, and nothing else, is what this tick changes.
    mark_dirty(state, node_id, MapSet.new([:detail]))
  end

  defp tail_bytes(bin, n) when byte_size(bin) <= n, do: bin
  defp tail_bytes(bin, n), do: binary_part(bin, byte_size(bin) - n, n)

  # Spec 51 §2.4: the preview of every stream that changed since the last
  # flush, written straight into `state.nodes` — `detail` is not a persist
  # trigger, and the node is already dirty from `put_stream/4`. An empty
  # preview (both channels reset by a retry) leaves the "retrying…" detail alone.
  defp flush_previews(state) do
    Enum.reduce(state.stream, state, fn
      {node_id, %{dirty?: true} = entry}, acc ->
        preview = if entry.text != "", do: entry.text, else: entry.reasoning
        acc = %{acc | stream: Map.put(acc.stream, node_id, %{entry | dirty?: false})}

        case acc.nodes[node_id] do
          node when preview != "" and node != nil ->
            detail =
              preview
              |> tail_bytes(@detail_scan_bytes)
              |> drop_partial_lead()
              |> one_line()
              |> tail_bytes(4 * @detail_chars)
              |> drop_partial_lead()
              |> last_chars(@detail_chars)
              |> :binary.copy()

            %{acc | nodes: Map.put(acc.nodes, node_id, %{node | detail: detail})}

          _ ->
            acc
        end

      _entry, acc ->
        acc
    end)
  end

  # A byte tail can start inside a grapheme: drop up to three continuation bytes.
  defp drop_partial_lead(<<b, rest::binary>>) when b in 0x80..0xBF, do: drop_partial_lead(rest)
  defp drop_partial_lead(bin), do: bin

  # `text`/`reasoning` are the node's own preview; `a_text`/`a_reasoning` count
  # what this node contributed to the *assistant* message, separators included,
  # so a retry takes back exactly what it put there (spec 30 §5). `dirty?` says
  # the preview has to be derived again at the next flush (spec 51 §2.4).
  defp new_stream, do: %{text: "", reasoning: "", a_text: 0, a_reasoning: 0, dirty?: false}

  defp reset_stream_channel(stream, :text),
    do: Map.merge(new_stream(), stream) |> Map.merge(%{text: "", a_text: 0, dirty?: true})

  defp reset_stream_channel(stream, :reasoning),
    do:
      Map.merge(new_stream(), stream) |> Map.merge(%{reasoning: "", a_reasoning: 0, dirty?: true})

  # Only the root agent of a chat run writes the assistant message.
  defp assistant_channel?(state, node),
    do: state.run.kind == "chat" and node.parent_id == state.root_node_id

  defp separator(last, node_id, chunks) do
    if last not in [nil, node_id] and not Chunks.empty?(chunks), do: "\n\n", else: ""
  end

  defp count_assistant(state, node_id, key, delta) do
    stream = Map.get(state.stream, node_id, new_stream())
    stream = Map.update(stream, key, String.length(delta), &(&1 + String.length(delta)))
    %{state | stream: Map.put(state.stream, node_id, stream)}
  end

  # After a reset this node owns nothing at the tail any more; `:previous` says
  # "someone else does", which is what makes the retry re-open a paragraph.
  defp previous_marker(nil, _node_id), do: nil
  defp previous_marker(_marker, _node_id), do: :previous

  defp bump_totals(state, node_id, node) do
    totals =
      Map.put(
        state.totals,
        node_id,
        {node.tokens_in || 0, node.tokens_out || 0, node.cost_usd}
      )

    {tokens_in, tokens_out, cost_usd} =
      Enum.reduce(totals, {0, 0, nil}, fn {_id, {input, output, cost}},
                                          {inputs, outputs, total_cost} ->
        {inputs + input, outputs + output, Pricing.add(total_cost, cost)}
      end)

    run = struct(state.run, %{tokens_in: tokens_in, tokens_out: tokens_out, cost_usd: cost_usd})
    %{state | totals: totals, run: run, run_dirty: true}
  end

  # Spec 54 §2.1: `cols` is what changed — `:all` (a register, or anything the
  # patch shape cannot carry) or the attribute keys of this change. They
  # accumulate until the flush that ships them.
  defp mark_dirty(state, node_id, cols \\ :all) do
    state = %{
      state
      | dirty: MapSet.put(state.dirty, node_id),
        dirty_cols: Map.update(state.dirty_cols, node_id, cols, &merge_cols(&1, cols))
    }

    if state.flush_ref == nil,
      do: %{state | flush_ref: Process.send_after(self(), :flush, @flush_ms)},
      else: state
  end

  defp merge_cols(:all, _cols), do: :all
  defp merge_cols(_prev, :all), do: :all
  defp merge_cols(prev, cols), do: MapSet.union(prev, cols)

  defp flush(state) do
    state = state |> flush_previews() |> flush_writes()
    conv_id = state.conversation.id

    # Spec 54 §2.1 (54a B1): a streaming tick changed `detail`/`progress`/
    # tokens and nothing else — it travels as a column patch. A register or a
    # finish ships the whole light node, so a subscriber that holds no copy of
    # it still gets the row. Both go out from this process, on one topic, in
    # this order, so a patch can never overtake the struct it patches.
    {upserts, patches} = split_dirty(state)
    if upserts != [], do: Events.broadcast(conv_id, {:nodes_upsert, state.run.id, upserts})
    if patches != [], do: Events.broadcast(conv_id, {:nodes_patch, state.run.id, patches})

    if not Chunks.empty?(state.pending_delta) and state.assistant_message != nil do
      Events.broadcast(
        conv_id,
        {:assistant_delta, state.assistant_message.id, Chunks.to_string(state.pending_delta)}
      )
    end

    if not Chunks.empty?(state.pending_reasoning) and state.assistant_message != nil do
      Events.broadcast(
        conv_id,
        {:reasoning_delta, state.assistant_message.id, Chunks.to_string(state.pending_reasoning)}
      )
    end

    if state.run_dirty, do: Events.broadcast(conv_id, {:run_updated, state.run})

    state = drop_finished_text(state, upserts)

    %{
      state
      | dirty: MapSet.new(),
        dirty_cols: %{},
        pending_delta: Chunks.new(),
        pending_reasoning: Chunks.new(),
        run_dirty: false
    }
  end

  # {full light nodes, {id, changed columns} pairs} for this flush.
  defp split_dirty(state) do
    {upserts, patches} =
      Enum.reduce(state.dirty, {[], []}, fn id, {ups, pats} = acc ->
        case state.nodes[id] do
          nil ->
            acc

          node ->
            cols = Map.get(state.dirty_cols, id, :all)

            cond do
              # Spec 54 §1.5: a finished op whose text this server dropped. It
              # went out whole in the flush that finished it and it never
              # changes again, so there is nothing left to say — and saying it
              # would overwrite every subscriber's copy with the stripped one.
              MapSet.member?(state.stripped, id) ->
                acc

              cols != :all and Node.patchable?(cols, node) ->
                {ups, [{id, Node.patch(node, cols)} | pats]}

              true ->
                {[node | ups], pats}
            end
        end
      end)

    {Enum.reverse(upserts), Enum.reverse(patches)}
  end

  # Spec 54 §1.5 (54a C1): a finished op's text is in the row and in every
  # subscriber's copy, and this process never reads it again — `subtree/2`,
  # `mark_stopped/2` and `cleanup_worktrees/1` read ids, statuses and the agent
  # columns only, and `get_state/1` is test-only. Dropping it after the flush
  # that broadcast it is ~70 % of an op-heavy run's server heap (a 1+6 swarm sat
  # at 690 KB, a 500-op workflow run at ≈ 2 MB). A node whose INSERT is still
  # pending keeps its text — `flush_writes/1` writes the whole struct.
  defp drop_finished_text(state, broadcast) do
    Enum.reduce(broadcast, state, fn node, acc ->
      if node.kind == "op" and node.status in @finished and
           not MapSet.member?(acc.uninserted, node.id) do
        stripped = %{node | result: nil, detail: nil, input: nil, error: nil}

        %{
          acc
          | nodes: Map.put(acc.nodes, node.id, stripped),
            stripped: MapSet.put(acc.stripped, node.id)
        }
      else
        acc
      end
    end)
  end

  # Spec 54 §1.1 (54a A1): everything this flush owes the database, in one
  # IMMEDIATE transaction — the nodes whose persisted columns moved, the rows
  # a busy database refused to insert, and the run's token totals. On
  # `{:error, :database_busy}` nothing was written and nothing is dropped: the
  # columns stay in `unsaved` and the next flush tries again. The run never dies
  # for a contended write.
  defp flush_writes(state) do
    # spec 55 T12 (55a A8)
    {inserts, updates} = SwarmCode.Domain.Engine.RunServer.Nodes.pending_writes(state)

    {totals, triple} =
      case pending_totals(state) do
        nil -> {nil, nil}
        {run, attrs, triple} -> {{run, attrs}, triple}
      end

    if updates == [] and inserts == [] and totals == nil do
      state
    else
      try do
        case Conversations.flush_run_writes(inserts, updates, totals) do
          {:ok, run} ->
            state = if run, do: %{state | run: run, totals_written: triple}, else: state

            %{
              state
              | unsaved: Map.drop(state.unsaved, MapSet.to_list(state.persist_pending)),
                persist_pending: MapSet.new(),
                uninserted: MapSet.new()
            }

          {:error, :database_busy} ->
            state |> warn_busy("flush of #{length(updates)} node writes") |> rearm_flush()

          # spec 67 T12 (B16): `flush_ref` was nil'd before this call, so
          # returning the state unchanged left the columns in `unsaved` with
          # nothing armed to write them — on a finishing run the next writer is
          # `terminate/2`, and the run's last progress was simply lost.
          {:error, _reason} ->
            rearm_flush(state)
        end
      rescue
        # spec 55 T11 (55a A4): no write error may end the run's sole state owner.
        error ->
          Logger.error("swarm_code: flush raised #{Exception.message(error)}")
          warn_busy(state, "flush raised")
      end
    end
  end

  # spec 60 T7: a busy flush re-arms itself; `mark_dirty/3` only arms on new events.
  defp rearm_flush(%{flush_ref: nil} = state) do
    if MapSet.size(state.persist_pending) > 0 or MapSet.size(state.uninserted) > 0,
      do: %{state | flush_ref: Process.send_after(self(), :flush, @flush_ms)},
      else: state
  end

  defp rearm_flush(state), do: state

  # `{run as the row has it, the token attrs, the triple that will be written}`
  # — or nil when the totals have not moved since the last flush.
  defp pending_totals(state) do
    triple = {state.run.tokens_in, state.run.tokens_out, state.run.cost_usd}

    if triple == state.totals_written do
      nil
    else
      attrs = %{
        tokens_in: state.run.tokens_in,
        tokens_out: state.run.tokens_out,
        cost_usd: state.run.cost_usd
      }

      persisted_run =
        case state.totals_written do
          {tokens_in, tokens_out, cost_usd} ->
            struct(state.run, tokens_in: tokens_in, tokens_out: tokens_out, cost_usd: cost_usd)

          nil ->
            struct(state.run, tokens_in: nil, tokens_out: nil, cost_usd: nil)
        end

      # spec 36 §A2: the silent write. `flush/1` broadcasts `{:run_updated, …}`
      # itself right below, so announcing from inside the write too sent every
      # open LiveView the same event twice per 100 ms token flush.
      {persisted_run, attrs, triple}
    end
  end

  # One warning per run, not one per attempt (spec 54 §1.1): under load the
  # same run retries every 100 ms and the log was the next bottleneck.
  defp warn_busy(%{busy_warned?: true} = state, _what), do: state

  defp warn_busy(state, what) do
    Logger.warning(
      "swarm_code: database busy, run #{state.run.id} kept its unsaved columns (#{what})"
    )

    %{state | busy_warned?: true}
  end

  defp node_attrs(node), do: SwarmCode.Domain.Engine.RunServer.Nodes.node_attrs(node)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)

  # ------------------------------------------------------------------ agents

  # The conversation goal and the plan-mode instruction go into EVERY agent of the
  # conversation (assistant, lead and sub-agents).
  defp prompt_opts(state) do
    ctx = Map.get(state, :project_context) || %{}

    [
      goal: state.conversation.goal,
      mode: mode(state),
      instructions: Map.get(ctx, :instructions),
      memory: Map.get(ctx, :memory),
      worktrees: state.worktrees?,
      # Spec 38 §4: one mode at a time — a row that still has both flags on
      # runs as consensus, the precedence the composer shows.
      ultra: Map.get(state.conversation, :ultra, false) and is_nil(Map.get(state, :consensus)),
      # Spec 50 §6.1: `authoring:` used to come from
      # `conversation.authoring_workflow`, a flag only a successful
      # `workflow_save` ever cleared. A plan-mode turn after an abandoned
      # /create-workflow therefore got the authoring instructions with none of
      # the authoring tools (tools.ex:116 gates them on the run's `command`,
      # tools.ex:129 strips them again in plan mode) — "unknown tool
      # workflow_save". The command of *this run* is now the only authoring
      # switch, and `Prompts.assistant/2` already derives it from `:command`
      # and `:ultra`, so the prompt and the tool list cannot disagree again.
      command: command(state),
      consensus: Map.get(state, :consensus)
    ]
  end

  # The command the user invoked for this run (spec 12 §5).
  # Spec 54 §5 (54c H7): the names `do_start_agent_process/3` will put in the
  # request, computed here so the prompt and the tool array cannot disagree.
  defp assistant_tool_names(state) do
    spec = %{role: "assistant"}

    Tools.for_agent("assistant", 0, state.settings.max_agent_depth, mode(state),
      project_id: state.project.id,
      command: command(state)
    )
    |> Kernel.++(consensus_tools(state, spec))
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end

  defp command(state), do: Map.get(state, :command)

  defp mode(state), do: Map.get(state, :mode) || state.conversation.mode || "build"

  # Spec 50 §1.4: the compactor reads and writes nothing — one turn, no tools,
  # on the chat model. `tools: []` wins over `Tools.for_agent/5` below because
  # an empty list is truthy in Elixir, and both providers omit the `tools` key
  # entirely when the list is empty (anthropic.ex:67, openai.ex:33), so this is
  # a plain completion.
  defp root_spec(%{run: %{kind: "compact"}} = state) do
    %{
      name: "Compactor",
      role: "assistant",
      system: Prompts.base_only(state.project),
      messages: state.history,
      model: state.chat_model,
      tools: [],
      max_turns: 1,
      depth: 0,
      project_root: state.project.root_path
    }
  end

  defp root_spec(%{run: %{kind: "chat"}} = state) do
    %{
      name: chat_agent_name(state),
      role: "assistant",
      # Spec 54 §5 (54c H7): the system prompt names the tools this request will
      # actually carry, never a hand-written list.
      system:
        Prompts.assistant(
          state.project,
          Keyword.put(prompt_opts(state), :tools, assistant_tool_names(state))
        ),
      messages: state.history,
      model: state.chat_model,
      depth: 0,
      project_root: state.project.root_path
    }
  end

  defp root_spec(state) do
    %{
      name: "Lead",
      role: "lead",
      system:
        Prompts.lead(state.project, state.settings.max_concurrent_agents, prompt_opts(state)),
      messages: [%{role: "user", content: state.prompt}],
      model: state.chat_model,
      depth: 0,
      project_root: state.project.root_path
    }
  end

  # Spec 23 §4: a `/create-workflow` turn is not "the Assistant" — the agents
  # pane said `Assistant` while the card next to it showed the authoring
  # stepper. Only this turn is renamed; `conversation.authoring_workflow` stays
  # on for later turns, and those are ordinary assistant turns again.
  # Spec 50 §4: neither is a plan-mode turn — it is the Planner, and §7's
  # approve gate hangs off exactly that. `Run.agent_name/1` is the one list, so
  # the node, the pane row and the transcript card cannot disagree;
  # `mode(state)` is the value `runs.mode` was written from (engine.ex:82).
  defp chat_agent_name(state) do
    if command(state) == :create_workflow do
      "Workflow author"
    else
      SwarmCode.Domain.Conversations.Run.agent_name(%{
        consensus: Map.get(state.run, :consensus),
        prompt: Map.get(state.run, :prompt),
        mode: mode(state)
      })
    end
  end

  defp new_agent(spec),
    do: %{
      spec: spec,
      sup: nil,
      server: nil,
      ref: nil,
      slot: false,
      waiting: [],
      result: nil,
      # spec 73 T56: the background watchdog, when this agent has one.
      background_timer: nil
    }

  defp put_agent(state, node_id, agent),
    do: %{state | agents: Map.put(state.agents, node_id, agent)}

  # Spec 37 §3.1: the planner — and only the planner — can submit to the judge.
  # Spec 45 §6.2: and, with an implementer configured, hand over a spec.
  # spec 60 T2: plan mode is read-only — no `write_spec` even with an implementer.
  defp consensus_tools(%{consensus: %{} = config} = state, %{role: "assistant"}) do
    [Tools.builtin_ref(SwarmCode.Domain.Tools.SubmitPlan)] ++
      if(Map.get(config, :implementer) && mode(state) != "plan",
        do: [Tools.builtin_ref(SwarmCode.Domain.Tools.WriteSpec)],
        else: []
      )
  end

  defp consensus_tools(_state, _spec), do: []

  defp start_agent_process(state, node_id) do
    agent = state.agents[node_id]
    spec = agent.spec

    case isolation_spec(state, node_id, spec) do
      {:async, work} -> start_isolation(state, node_id, work)
      {:ready, root, branch} -> do_start_agent_process(state, node_id, root, branch)
    end
  end

  defp do_start_agent_process(state, node_id, root, branch) do
    agent = state.agents[node_id]
    spec = agent.spec
    settings = state.settings
    spec = %{spec | project_root: root}
    state = put_agent(state, node_id, %{agent | spec: spec})
    agent = state.agents[node_id]

    args = %{
      run_id: state.run.id,
      node_id: node_id,
      name: spec.name,
      role: spec.role,
      system: agent_system(state, spec, root, branch),
      messages: spec.messages,
      model: spec.model,
      # spec 72 C5: append structured_output ref when output_schema is present.
      tools:
        (Map.get(spec, :tools) ||
           (Tools.for_agent(spec.role, spec.depth, settings.max_agent_depth, mode(state),
              project_id: state.project.id,
              command: command(state)
            ) ++ consensus_tools(state, spec))
           # spec 72 A4: apply the agent definition's tool allow-list
           |> Tools.filter_tools(Map.get(spec, :tool_allow_list))) ++
          if(Map.get(spec, :output_schema),
            do: [Tools.structured_output_ref(spec.output_schema)],
            else: []
          ),
      depth: spec.depth,
      max_turns: Map.get(spec, :max_turns) || settings.max_agent_turns,
      project_root: root,
      approval_mode: state.project.approval_mode,
      project_id: state.project.id,
      # spec 67 T26 (G29): the `<environment>` block this agent's system prompt
      # carries, so its first think step has nothing to compare and nothing to
      # read — the refresh starts from the second one.
      env: Prompts.environment_cached(%{state.project | root_path: root}),
      # Spec 39 §1.1: a research borrows the scratch project in memory only;
      # its ops must never read that project's row for the approval mode.
      run_kind: state.run.kind,
      conversation_id: state.conversation.id,
      effort: Map.get(spec, :effort) || state.effort,
      require_tool: Map.get(spec, :require_tool),
      # Spec 26 §5.3: nil for every agent but the one whose whole answer is a
      # 40 000-character tool call; `AgentServer` then keeps the Request default.
      max_tokens: Map.get(spec, :max_tokens),
      # Spec 45 §5.2: an agent whose isolation finished while the run was
      # paused starts held, before its first think step.
      paused?: state.paused?,
      settings: settings,
      # spec 72 A5: prewalk state passed to agent_server
      prewalk: Map.get(spec, :prewalk, false),
      prewalk_model: Map.get(spec, :prewalk_model)
    }

    with {:ok, sup} <- AgentsSup.start_agent(state.run.id, args),
         [{server, _}] <- Registry.lookup(SwarmCode.Domain.Registry, {:agent, node_id}) do
      ref = Process.monitor(server)

      # spec 73 T9 (F6): messages queued while this agent waited to start are
      # drained at its first think step.
      if Map.get(state.mailboxes, node_id, []) != [],
        do: send(server, {:mailbox_pending, node_id})

      slot? = agent.slot or spec.role in ["sub", "worker"]
      newly_reserved? = slot? and not agent.slot

      state =
        state
        |> put_agent(node_id, %{
          agent
          | sup: sup,
            server: server,
            ref: ref,
            slot: slot?,
            # Spec 51 §2.2: the AgentServer owns these now; only project_root
            # and require_tool are read here afterwards (agent_root/2,
            # structured?/2). 2.5 MB per 50 workers, more with images.
            spec: Map.drop(spec, [:system, :messages, :tools])
        })
        |> then(fn s -> if newly_reserved?, do: %{s | active_sub: s.active_sub + 1}, else: s end)

      state =
        if state.nodes[node_id].status == "queued",
          do: put_node(state, node_id, %{status: "running", started_at: now()}),
          else: state

      # spec 72 F5: carry the agent's model on the node so the inspector's
      # model_chip can render it, and a prewalk switch is visible.
      model_name = if is_map(spec.model), do: spec.model[:model] || spec.model["model"]

      if model_name,
        do: put_node(state, node_id, %{model: model_name}),
        else: state
    else
      other ->
        msg = "could not start agent: " <> String.slice(inspect(other), 0, 200)
        # Handle it exactly like a normal failure (cast to ourselves; processed next).
        agent_finished(state.run.id, node_id, {:error, msg})
        state
    end
  end

  # ------------------------------------------------------------ worktrees (§1)

  defp agent_root(state, op_node_id) do
    with %{parent_id: agent_id} <- state.nodes[op_node_id],
         %{spec: %{project_root: root}} when is_binary(root) <- state.agents[agent_id] do
      root
    else
      _ -> state.project.root_path
    end
  end

  # Sub-agents get their own git worktree + branch so parallel agents never fight
  # over the same files. Anything that goes wrong falls back to the parent root.
  defp isolation_spec(state, node_id, %{role: "sub"} = spec) do
    parent_root = spec.project_root || state.project.root_path

    if state.worktrees? do
      path =
        Path.join(
          Workspace.worktrees_dir(state.project.root_path),
          Isolation.short_id(state.run.id) <> "-" <> Isolation.short_id(node_id)
        )

      branch =
        "swarm/#{Isolation.short_id(state.run.id)}/#{slug(spec.name)}-#{Isolation.short_id(node_id)}"

      # spec 72 D1: choose isolation backend from settings.
      backend = isolation_backend(state)
      {:async, %{parent_root: parent_root, path: path, branch: branch, backend: backend}}
    else
      {:ready, parent_root, nil}
    end
  end

  defp isolation_spec(state, node_id, %{role: "worker", isolation: :worktree} = spec) do
    isolation_spec(state, node_id, %{spec | role: "sub"})
  end

  defp isolation_spec(_state, _node_id, spec), do: {:ready, spec.project_root, nil}

  defp start_isolation(state, node_id, work) do
    generation = state.isolation_generation
    project_root = state.project.root_path

    task =
      Task.Supervisor.async_nolink(SwarmCode.Domain.TaskSupervisor, fn ->
        result =
          try do
            git = git_adapter()

            if git.repo?(work.parent_root) do
              Workspace.ensure!(project_root)

              # spec 72 D1: dispatch to the chosen backend (R12: `auto` is
              # probed here, in the task, not in the state owner).
              backend = settle_isolation_backend(work.backend, work.parent_root)
              backend_mod = isolation_backend_mod(backend)

              # spec 72 D5: the ownership marker goes in before a clone is
              # materialised (a copy takes seconds and a boot sweep must never
              # see an owner-less directory). spec 72 R5: not before a worktree
              # — `git worktree add` refuses a non-empty directory, so the
              # worktree backend had failed every agent since D5.
              if backend == :clone do
                File.mkdir_p!(work.path)
                SwarmCode.Domain.Engine.Isolation.Ownership.write(work.path, node_id)
              end

              case backend_mod.create(work.parent_root, work.path,
                     branch: work.branch,
                     parent_root: work.parent_root,
                     git: git
                   ) do
                {:ok, attrs} ->
                  SwarmCode.Domain.Engine.Isolation.Ownership.write(work.path, node_id)

                  # spec 72 D2: capture the baseline of the isolation directory.
                  baseline =
                    case SwarmCode.Domain.Engine.Isolation.Baseline.capture(work.path) do
                      {:ok, b} -> b
                      {:error, _reason} -> nil
                    end

                  {:ok, attrs |> Map.put(:backend, backend) |> Map.put(:baseline, baseline)}

                {:error, reason} ->
                  {:error, normalize_worktree_reason(reason)}
              end
            else
              {:shared, work.parent_root}
            end
          rescue
            error -> {:error, Exception.message(error)}
          catch
            kind, reason -> {:error, Exception.format_banner(kind, reason)}
          end

        {:isolated, generation, node_id, result}
      end)

    pending = %{task: task, generation: generation}
    %{state | pending_isolation: Map.put(state.pending_isolation, node_id, pending)}
  end

  defp apply_isolation(state, node_id, {:ok, attrs}) do
    state =
      put_node(state, node_id, %{
        workspace_path: attrs.root,
        branch: attrs.branch,
        base_sha: attrs.base_sha,
        detail: "isolated in " <> (attrs.branch || "clone")
      })

    # spec 72 D1: remember which backend was used for cleanup.
    backend = Map.get(attrs, :backend, :worktree)
    state = %{state | isolation_backends: Map.put(state.isolation_backends, node_id, backend)}

    # spec 72 D2: store the baseline for delta capture later.
    baseline = Map.get(attrs, :baseline)

    state =
      if baseline,
        do: %{state | baselines: Map.put(state.baselines, node_id, baseline)},
        else: state

    do_start_agent_process(state, node_id, attrs.root, attrs.branch)
  end

  defp apply_isolation(state, node_id, {:shared, root}) do
    do_start_agent_process(state, node_id, root, nil)
  end

  # spec 67 T11 (G40): the fallback into `root_path` is only safe while the
  # agent is alone in the tree. With worktrees on and siblings already running,
  # it puts two agents on one working tree — T20 serialises writes per agent,
  # not per path, so they interleave `edit_file` on the same files and each
  # one's `git_commit` carries the other's half-work. The agent fails instead,
  # through the same path as any other start failure, and whoever awaits it is
  # told why.
  defp apply_isolation(state, node_id, {:error, reason}) do
    reason = normalize_worktree_reason(reason)
    Logger.warning("swarm_code could not create a worktree: #{reason}")
    agent = state.agents[node_id]
    root = agent.spec.project_root || state.project.root_path
    state = put_node(state, node_id, %{detail: "no worktree: " <> reason})

    if state.settings.worktrees_enabled and map_size(state.agents) > 1 do
      agent_finished(
        state.run.id,
        node_id,
        {:error,
         "could not create a worktree: #{reason} — sub-agents would share the working tree"}
      )

      state
    else
      do_start_agent_process(state, node_id, root, nil)
    end
  end

  # spec 72 R5: git ends its message with a newline, so the "last line" was "".
  defp normalize_worktree_reason(reason),
    do: reason |> to_string() |> String.split("\n", trim: true) |> List.last() |> to_string()

  defp maybe_images(message, images) when is_list(images) and images != [],
    do: Map.put(message, :images, images)

  defp maybe_images(message, _images), do: message

  defp slug(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> case do
      "" -> "agent"
      s -> String.slice(s, 0, 24)
    end
  end

  # spec 73 T7: the definition body and the structured-output note ride along
  # (`system_extra`); only the base is rebuilt for the isolated root.
  defp agent_system(state, %{role: "sub"} = spec, root, branch) when is_binary(branch) do
    Prompts.sub_agent(%{state.project | root_path: root}, spec.name, prompt_opts(state)) <>
      Map.get(spec, :system_extra, "") <>
      "\nYou work in an isolated git worktree of the project at #{root} (branch #{branch}). " <>
      "Every path is relative to that directory; do not touch files outside it. " <>
      "The lead merges your branch when your work is good.\n"
  end

  defp agent_system(_state, %{role: "worker"} = spec, root, branch) when is_binary(branch) do
    spec.system <>
      "\nYou work in an isolated git worktree of the project at #{root} (branch #{branch}). " <>
      "Every path is relative to that directory; do not touch files outside it.\n"
  end

  defp agent_system(_state, spec, _root, _branch), do: spec.system

  # When an isolated agent finishes we commit its worktree so the branch can be
  # merged, and report the diff stat back to the lead's spawn_agent call.
  defp begin_agent_completion(state, node_id, {:ok, _text} = result) do
    case state.nodes[node_id] do
      %{branch: branch, workspace_path: path} = node
      when is_binary(branch) and is_binary(path) ->
        generation = state.finalization_generation
        # spec 72 D3: pass baseline so the task can capture the delta.
        baseline = Map.get(state.baselines, node_id)
        # spec 72 F2: pass project root so the task can persist the delta patch.
        project_root = state.project.root_path
        backend = Map.get(state.isolation_backends, node_id, :worktree)

        task =
          Task.Supervisor.async_nolink(SwarmCode.Domain.TaskSupervisor, fn ->
            finalized =
              try do
                stat = commit_and_stat(path, node)

                # spec 72 R2: the note below tells the lead to integrate the
                # branch, so a clone's branch reaches the project here — not
                # at the run's end, after the lead has read the note.
                if backend == :clone and is_binary(branch),
                  do:
                    SwarmCode.Domain.Engine.Isolation.Clone.export_branch(
                      project_root,
                      path,
                      branch
                    )

                # spec 72 D3: capture delta patch after commit.
                delta_info = capture_delta(path, baseline)

                # spec 72 F2: persist delta patch to disk so integrate_agent can apply it.
                persist_delta_patch(delta_info, project_root, node_id)

                {:ok, {stat, delta_info}}
              rescue
                error -> {:error, Exception.message(error)}
              catch
                kind, reason -> {:error, Exception.format_banner(kind, reason)}
              end

            {:finalized, generation, node_id, finalized}
          end)

        pending = %{task: task, generation: generation, original: result}

        {:noreply,
         state
         |> demonitor(node_id)
         |> then(
           &%{
             &1
             | pending_finalization: Map.put(&1.pending_finalization, node_id, pending)
           }
         )}

      _ ->
        complete_agent(state, node_id, result)
    end
  end

  defp begin_agent_completion(state, node_id, result), do: complete_agent(state, node_id, result)

  # spec 73 T59: the finalization task (`begin_agent_completion/3`) is the
  # only producer of `{:finalized, …}` and always returns
  # `{:ok, {stat, delta_info}}` or `{:error, reason}`; the bare-stat clause
  # that used to follow had no producer.
  defp finalized_result(state, node_id, {:ok, text} = result, {:ok, {stat, delta_info}}) do
    # spec 72 D3: append delta info to the report.
    delta_note =
      case delta_info do
        {:ok, %{patch_bytes: bytes, files: n}} ->
          "\nDelta patch captured: #{bytes} bytes, #{n} files changed"

        _ ->
          ""
      end

    if structured?(state, node_id) do
      {put_node(state, node_id, %{changes_stat: stat}), result}
    else
      branch = state.nodes[node_id].branch
      {state, {:ok, note}} = report_with_note(state, node_id, text, branch, stat)
      {state, {:ok, note <> delta_note}}
    end
  end

  defp finalized_result(state, _node_id, {:ok, text}, {:error, reason}) do
    reason = task_reason(reason)
    Logger.warning("swarm_code could not finalize agent changes: #{reason}")
    result = {:ok, text <> "\n\n[Could not finalize agent changes: " <> reason <> "]"}
    {state, result}
  end

  defp complete_agent(state, node_id, result) do
    # spec 72 B2: extract orchestration stop reason from {:ok, reason, text}
    # or {:error, reason, msg} before the existing kind/strip_error_kind path.
    # When the stop reason is an orchestration atom (B6: :doom_loop), it takes
    # priority over LLM.Error.of which would classify the text as :provider.
    {stop_reason, result} =
      case result do
        {:ok, reason, text} when is_atom(reason) -> {reason, {:ok, text}}
        {:error, reason, msg} when is_atom(reason) -> {reason, {:error, msg}}
        other -> {nil, other}
      end

    # spec 67 T30 (G42): the agent may report `{:error, kind, msg}`; the kind is
    # a column of its own and everything downstream keeps the two-tuple.
    kind = stop_reason || SwarmCode.Domain.LLM.Error.of(result)
    result = strip_error_kind(result)

    attrs =
      case result do
        {:ok, text} ->
          # spec 72 B2: a successful agent gets error_kind "done" (or the
          # orchestration stop reason, e.g. "turn_budget").
          %{
            status: "done",
            progress: 100,
            result: text,
            detail: text,
            finished_at: now(),
            error_kind: to_string(kind || :done)
          }

        {:error, msg} ->
          %{
            status: "failed",
            progress: 100,
            error: msg,
            detail: msg,
            error_kind: to_string(kind),
            finished_at: now()
          }
      end

    state =
      state
      |> put_node(node_id, attrs)
      |> settle(node_id, result)
      |> inject_background_result(node_id, result)
      |> demonitor(node_id)
      |> release_slot(node_id)

    if node_id == state.root_node_id do
      status = if match?({:ok, _}, result), do: "done", else: "failed"
      finish_run(state, status, result, kind) |> stop_or_retry()
    else
      {:noreply, state}
    end
  end

  defp structured?(state, node_id) do
    match?(%{spec: %{require_tool: tool}} when is_binary(tool), state.agents[node_id])
  end

  defp report_with_note(state, node_id, text, branch, stat) do
    note =
      if stat == "",
        do: "[No file changes.]",
        else:
          "[Changes on branch #{branch} (#{stat}). " <>
            "Integrate them with the integrate_agent tool when they are good.]"

    state = put_node(state, node_id, %{changes_stat: stat})
    # Spec 51 §5.3: nothing to integrate — the worktree and the branch go now.
    state = if stat == "", do: schedule_cleanup(state, node_id), else: state
    {state, {:ok, text <> "\n\n" <> note}}
  end

  defp schedule_cleanup(state, node_id) do
    case state.nodes[node_id] do
      %{workspace_path: path} = node when is_binary(path) and path != "" ->
        root = state.project.root_path
        run_id = state.run.id

        Task.Supervisor.start_child(SwarmCode.Domain.TaskSupervisor, fn ->
          if IntegrateAgent.cleanup(root, node) == :ok,
            do: update_node(run_id, node_id, %{integrated: true})
        end)

        state

      _other ->
        state
    end
  end

  # Spec 51 §5.3 (3): every worktree of the run goes when the run ends; a
  # branch with commits over its base stays for the UI's integrate path
  # (`workspace_live.ex`), an empty one is noise and goes with its worktree.
  defp cleanup_worktrees(state) do
    root = state.project.root_path

    nodes =
      for {_id, %{workspace_path: p, integrated: false} = n} <- state.nodes,
          is_binary(p),
          p != "",
          do: n

    if nodes != [] do
      run_id = state.run.id

      Task.Supervisor.start_child(SwarmCode.Domain.TaskSupervisor, fn ->
        git = git_adapter()

        for node <- nodes, :ok == IntegrateAgent.validate_node(root, node) do
          # spec 60 T9 (spec 55 A16): keep the work on the branch; a failed commit never fails the finish.
          try do
            if git.status(node.workspace_path) != [],
              do: git.commit(node.workspace_path, "swarm: #{node.name || "agent"} (stopped)")
          rescue
            _ -> :ok
          end

          # spec 72 D1: the right cleanup per backend (spec 73 T72: decided by
          # the directory itself, in Isolation.cleanup/3). spec 73 T73: a
          # clone whose branch could not be fetched into the project is kept
          # — it holds the only copy of the work — and its branch row is left
          # alone rather than deleted on a stale count.
          with :ok <- cleanup_isolation_dir(git, root, node),
               {:ok, 0} <- git.commits_ahead(root, node.base_sha || "HEAD", node.branch) do
            git.branch_delete(root, node.branch)
            # spec 72 R5: the delta patch goes with its branch — a branch kept
            # for the UI's integrate path keeps the patch that applies it.
            cleanup_delta_dir(root, node)
            Conversations.mark_node_integrated(node.id)
            update_node(run_id, node.id, %{integrated: true})
          else
            _kept_or_unknown -> :ok
          end
        end
      end)
    end

    state
  end

  defp commit_and_stat(path, node) do
    git = git_adapter()
    if git.status(path) != [], do: git.commit(path, "swarm: #{node.name || "agent"}")
    {summary, _files} = git.diff_stat(path, base: node.base_sha || "HEAD")
    summary
  end

  # spec 72 D3: capture delta patch after an agent finishes.
  defp capture_delta(_path, nil), do: nil

  defp capture_delta(path, %SwarmCode.Domain.Engine.Isolation.Baseline{} = baseline) do
    case SwarmCode.Domain.Engine.Isolation.Delta.capture(path, baseline) do
      {:ok, delta} ->
        # spec 72 R4: the note counted untracked files — always 0 after
        # commit_and_stat — instead of the files the patch touches.
        {:ok,
         %{
           patch: delta.patch,
           patch_bytes: byte_size(delta.patch),
           files: SwarmCode.Domain.Engine.Isolation.Delta.files_changed(delta.patch)
         }}

      {:error, reason} ->
        Logger.warning("swarm_code could not capture delta: #{reason}")
        {:error, reason}
    end
  end

  # spec 72 F2: persist the delta patch to .swarm_code/isolation/<short_id>/delta.patch
  # so integrate_agent's D4 path can find and apply it. Runs inside the owned
  # finalization task, never in a GenServer callback.
  defp persist_delta_patch({:ok, %{patch: patch}}, project_root, node_id)
       when is_binary(patch) and patch != "" and is_binary(project_root) do
    # spec 73 T60: the layout `integrate_agent` reads, from the one place.
    dir = SwarmCode.Domain.Engine.Isolation.delta_dir(project_root, node_id)
    path = Path.join(dir, "delta.patch")
    File.mkdir_p!(dir)

    tmp = path <> ".tmp"

    try do
      File.write!(tmp, patch)
      File.rename!(tmp, path)
    rescue
      _ -> File.rm(tmp)
    end
  end

  defp persist_delta_patch(_, _, _), do: :ok

  # The configured adapter is a deterministic test seam for proving that the
  # state owner stays responsive while an OS git command is blocked. Production
  # always uses SwarmCode.Domain.Git.
  defp git_adapter,
    do: Application.get_env(:swarm_code_daemon, :run_server_git_adapter, SwarmCode.Domain.Git)

  # spec 72 D1: resolve the isolation backend setting to an atom. spec 72 R12:
  # `auto` stays `:auto` here — its probe copies a file (`cp -c`), and this
  # runs inside the state owner's start_agent call; the isolation task
  # settles it.
  defp isolation_backend(state) do
    case Map.get(state.settings, :isolation_backend, "auto") do
      "clone" -> :clone
      "worktree" -> :worktree
      _auto -> :auto
    end
  end

  # spec 73 T11: a linked worktree settles to `:worktree` — its `.git` file
  # cannot be cloned.
  defp settle_isolation_backend(:auto, parent_root) do
    if SwarmCode.Domain.Engine.Isolation.Clone.main_checkout?(parent_root) and
         SwarmCode.Domain.Engine.Isolation.Clone.supported?(parent_root),
       do: :clone,
       else: :worktree
  end

  defp settle_isolation_backend(backend, _parent_root), do: backend

  # spec 72 D1: map backend atom to module.
  defp isolation_backend_mod(:clone), do: SwarmCode.Domain.Engine.Isolation.Clone
  defp isolation_backend_mod(:worktree), do: SwarmCode.Domain.Engine.Isolation.Worktree
  defp isolation_backend_mod(_), do: SwarmCode.Domain.Engine.Isolation.Worktree

  # spec 72 D1 / spec 73 T72: one cleanup path for both backends, shared with
  # `IntegrateAgent.cleanup/2`. Returns `:ok`, or `{:error, reason}` when a
  # clone had to be kept because its branch could not be exported (T73) — the
  # warning names the directory the user can still integrate by hand.
  defp cleanup_isolation_dir(git, root, node) do
    case Isolation.cleanup(root, node, git) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("swarm_code kept clone #{node.workspace_path}: #{task_reason(reason)}")
        {:error, reason}
    end
  end

  # spec 72 F2: remove the .swarm_code/isolation/<short_id>/ directory.
  defp cleanup_delta_dir(root, %{id: id}) when is_binary(id) do
    dir = SwarmCode.Domain.Engine.Isolation.delta_dir(root, id)
    if File.dir?(dir), do: File.rm_rf(dir)
  end

  defp cleanup_delta_dir(_, _), do: :ok

  defp settle(state, node_id, result) do
    case state.agents[node_id] do
      nil ->
        state

      agent ->
        Enum.each(agent.waiting, &GenServer.reply(&1, result))
        put_agent(state, node_id, %{agent | result: agent.result || result, waiting: []})
    end
  end

  # spec 70 C6: when a background agent finishes, inject its result into the
  # parent agent's steer queue so the parent sees it on its next LLM turn.
  defp inject_background_result(state, node_id, result) do
    case Map.pop(state.background_agents, node_id) do
      {nil, _} ->
        # Not a background agent — normal path.
        state

      {parent_id, bg} ->
        state = %{state | background_agents: bg} |> cancel_background_timer(node_id)
        name = get_in(state.nodes, [node_id, Access.key(:name)]) || "agent"

        text =
          case result do
            {:ok, text} ->
              # spec 72 C4: cap background agent result at preview_cap.
              preview = SwarmCode.Domain.Tools.SpawnAgent.preview_bg(text, node_id)
              "Background agent #{name} finished:\n#{preview}"

            {:error, text} ->
              "Background agent #{name} failed:\n#{text}"
          end

        # Send to the parent AgentServer process via its server pid.
        case state.agents[parent_id] do
          %{server: server} when is_pid(server) ->
            send(server, {:background_result, text})

          _ ->
            # Parent already finished — result is visible in the node's detail.
            :ok
        end

        state
    end
  end

  defp demonitor(state, node_id) do
    case state.agents[node_id] do
      %{ref: ref} = agent when is_reference(ref) ->
        Process.demonitor(ref, [:flush])
        put_agent(state, node_id, %{agent | ref: nil})

      _ ->
        state
    end
  end

  defp release_slot(state, node_id) do
    case state.agents[node_id] do
      %{slot: true} = agent ->
        state = put_agent(state, node_id, %{agent | slot: false})
        start_queued(%{state | active_sub: max(state.active_sub - 1, 0)})

      _ ->
        %{state | queue: List.delete(state.queue, node_id)}
    end
  end

  # Reserve concurrency before asynchronous repository isolation starts. If
  # the slot were counted only after git returned, several simultaneous spawn
  # calls could all pass the limit and start together.
  defp reserve_slot(state, node_id) do
    case state.agents[node_id] do
      %{slot: false} = agent ->
        state
        |> put_agent(node_id, %{agent | slot: true})
        |> then(&%{&1 | active_sub: &1.active_sub + 1})

      _ ->
        state
    end
  end

  # spec 73 T9: hands `message` to the first `wait_for_message` waiter of
  # `to_id` (spec 72 C2) or appends it to the mailbox, FIFO: a waiter only
  # exists while the mailbox is empty, and the head is what a waiter gets.
  defp enqueue_message(state, to_id, message) do
    mailbox = Map.get(state.mailboxes, to_id, [])

    if length(mailbox) >= @mailbox_cap do
      :full
    else
      message = Map.put(message, :at, System.monotonic_time(:millisecond))

      case pop_message_waiter(state.message_waiters, to_id) do
        {waiter, rest} ->
          [head | queued] = mailbox ++ [message]
          Process.cancel_timer(waiter.timer)
          GenServer.reply(waiter.from, {:ok, head})

          {:ok,
           %{
             state
             | mailboxes: Map.put(state.mailboxes, to_id, queued),
               message_waiters: rest
           }}

        nil ->
          # spec 73 T9 (F6): the recipient learns there is something to drain
          # at its next think step; an agent without a server yet is told
          # when it starts (`do_start_agent_process/4`).
          notify_mailbox(state, to_id)
          {:ok, %{state | mailboxes: Map.put(state.mailboxes, to_id, mailbox ++ [message])}}
      end
    end
  end

  # spec 73 T9 (F6)
  defp notify_mailbox(state, node_id) do
    case state.agents[node_id] do
      %{server: server} when is_pid(server) -> send(server, {:mailbox_pending, node_id})
      _queued_or_gone -> :ok
    end

    :ok
  end

  # spec 72 C2: find and remove the first waiter for a given node_id.
  defp pop_message_waiter(waiters, node_id) do
    case Enum.split_while(waiters, &(&1.node_id != node_id)) do
      {_before, []} -> nil
      {before, [waiter | after_]} -> {waiter, before ++ after_}
    end
  end

  defp start_queued(%{queue: []} = state), do: state
  # Spec 45 §5.2: a released slot admits nobody while the run is paused.
  defp start_queued(%{paused?: true} = state), do: state

  defp start_queued(%{queue: [next | rest]} = state) do
    if state.active_sub < state.max_live,
      do: state |> Map.put(:queue, rest) |> reserve_slot(next) |> start_agent_process(next),
      else: state
  end

  # Spec 45 §5.2: on continue every free slot takes a queued agent, not one.
  defp drain_queue(state) do
    next = start_queued(state)
    if next.queue == state.queue, do: next, else: drain_queue(next)
  end

  # The pids of the agents that are still running (spec 45 §5.2).
  defp live_agent_servers(state) do
    for {_id, %{server: server, result: nil}} <- state.agents,
        is_pid(server),
        Process.alive?(server),
        do: server
  end

  # spec 73 T56
  defp arm_background_timeout(state, node_id) do
    case Map.get(state.settings, :sub_agent_timeout_s) do
      n when is_integer(n) and n > 0 ->
        Process.send_after(self(), {:background_timeout, node_id}, n * 1_000)

      _none_or_zero ->
        nil
    end
  end

  defp cancel_background_timer(state, node_id) do
    case state.agents[node_id] do
      %{background_timer: timer} = agent when is_reference(timer) ->
        Process.cancel_timer(timer)
        put_agent(state, node_id, %{agent | background_timer: nil})

      _none ->
        state
    end
  end

  defp kill_agent(state, node_id) do
    state = state |> demonitor(node_id) |> cancel_background_timer(node_id)

    case state.agents[node_id] do
      %{sup: sup} = agent when is_pid(sup) ->
        stop_agent_async(state.run.id, agent)

        state
        |> put_agent(node_id, %{agent | sup: nil, server: nil})
        |> release_slot(node_id)

      _ ->
        release_slot(state, node_id)
    end
  end

  # Spec 43 §1.2: the RunServer never waits for an agent to die. The AgentServer
  # is the significant child of its `AgentSup` (one_for_all, auto_shutdown on
  # any significant), so one exit signal takes the whole subtree down — the
  # op Task.Supervisor included, with its shutdown timeouts — in the
  # supervisor's own time. `DynamicSupervisor.terminate_child/2` did the same
  # work synchronously from inside this process: with `run_command` ops in
  # flight (each traps exits and kills its process tree, ~1 s) a stop blocked
  # the run, its caller's 5 s `safe_call` and the LiveView behind the button.
  defp stop_agent_async(run_id, %{server: server, sup: sup}) do
    cond do
      is_pid(server) and Process.alive?(server) ->
        Process.exit(server, :shutdown)

      is_pid(sup) ->
        Task.Supervisor.start_child(SwarmCode.Domain.TaskSupervisor, fn ->
          AgentsSup.stop_agent(run_id, sup)
        end)

      true ->
        :ok
    end

    :ok
  end

  # spec 73 T57: the one body behind `{:stop_agent, …}` and
  # `{:stop_agent_timeout, …}` (which used to repeat these thirty lines and
  # then override the kind). Kills the subtree, settles what it was waiting
  # on, clears its question rows and answers whoever awaited it with an error
  # — never a report (spec 51 §5.9 (a)). `error_kind` lands on the stopped
  # node itself; its descendants stay `user_stopped` as before.
  defp stop_subtree(state, node_id, error_kind, message) do
    ids = [node_id | descendants(state, node_id)]
    stopped_ids = MapSet.new(subtree(state, node_id))

    state =
      state
      |> settle_pending_interactions(stopped_ids)
      |> cancel_background_work(stopped_ids)
      |> then(fn state ->
        Enum.reduce(Enum.reverse(ids), state, fn id, acc ->
          acc |> kill_agent(id) |> mark_subtree_stopped(id)
        end)
      end)

    # Spec 13 §11 A-10: a stopped subtree can never answer its `ask_user`, so
    # its rows have to go — otherwise the sidebar keeps an amber dot and the
    # question panel keeps a dead agent's questions for ever.
    Enum.each(subtree(state, node_id), fn id ->
      SwarmCode.Domain.Engine.Questions.delete(state.run.id, id)
      Events.broadcast(state.conversation.id, {:question_cleared, state.run.id, id})
    end)

    state =
      if error_kind == "user_stopped",
        do: state,
        else: put_node(state, node_id, %{error_kind: error_kind})

    name = (state.nodes[node_id] && state.nodes[node_id].name) || "agent"
    error = {:error, "Agent #{name} #{message}"}

    # spec 73 T56: a stopped background agent used to vanish without a word
    # to its parent — the injection only ran on the completion path.
    state |> settle(node_id, error) |> inject_background_result(node_id, error)
  end

  # spec 36 §A1: a settled node's bar is full, whatever it was mid-flight.
  # spec 72 B2: user_stopped / parent_stopped stop reason — spec 73 T57: the
  # kind is the argument; the by-parent copy was this with a literal.
  defp mark_stopped(state, node_id, error_kind \\ "user_stopped") do
    case state.nodes[node_id] do
      %{status: status} when status in @finished ->
        state

      nil ->
        state

      _ ->
        put_node(state, node_id, %{
          status: "stopped",
          progress: 100,
          finished_at: now(),
          error_kind: error_kind
        })
    end
  end

  defp mark_subtree_stopped(state, node_id) do
    Enum.reduce(subtree(state, node_id), state, &mark_stopped(&2, &1))
  end

  # Spec 36 §A1: a crash has to clean up like a stop does. Without this an
  # agent that died left (a) its op nodes `running` in state and in the DB
  # until the next boot's `mark_interrupted`, (b) a pending approval /
  # `ask_user` row in `Engine.Questions` waiting out its 10/30-minute timeout,
  # and (c) every sub-agent it had spawned still alive and spending tokens with
  # nobody awaiting it. Same body as `{:stop_agent, …}` except that the crashed
  # node itself is left alone — the caller writes `"failed"` and the error text
  # over it straight after, and its process is already gone.
  defp crash_cleanup(state, node_id) do
    stopped_ids = MapSet.new(subtree(state, node_id))

    state =
      state
      |> settle_pending_interactions(stopped_ids)
      |> cancel_background_work(stopped_ids)
      |> then(fn state ->
        state
        |> descendants(node_id)
        |> Enum.reverse()
        |> Enum.reduce(state, &kill_agent(&2, &1))
      end)
      |> then(fn state ->
        # Everything below the crashed agent — its own ops as well as the
        # sub-agents just killed and their ops — settles as `"stopped"`.
        # spec 72 B2: children inherit parent_stopped, not user_stopped.
        state
        |> subtree(node_id)
        |> Enum.drop(1)
        |> Enum.reduce(state, &mark_stopped(&2, &1, "parent_stopped"))
      end)

    # The crashed node is included: it may itself have been inside an
    # `ask_user`, and nothing will ever answer that question now.
    Enum.each(subtree(state, node_id), fn id ->
      SwarmCode.Domain.Engine.Questions.delete(state.run.id, id)
      Events.broadcast(state.conversation.id, {:question_cleared, state.run.id, id})
    end)

    state
  end

  # Pre-order list of node ids: the node itself, then its descendants.
  defp subtree(state, node_id) do
    [node_id | Enum.flat_map(state.children[node_id] || [], &subtree(state, &1))]
  end

  # Agent ids below `node_id` (agent → op → agent …), nearest first.
  defp descendants(state, node_id) do
    state
    |> subtree(node_id)
    |> Enum.drop(1)
    |> Enum.filter(fn id -> match?(%{kind: "agent"}, state.nodes[id]) end)
  end

  defp live_node?(state, node_id) do
    match?(%{status: status} when status not in @finished, state.nodes[node_id]) and
      Map.has_key?(state.agents, node_id)
  end

  defp pending_task(pending, ref) do
    Enum.find(pending, fn {_node_id, entry} -> entry.task.ref == ref end)
  end

  defp task_reason(reason) when is_binary(reason), do: reason
  defp task_reason(reason), do: String.slice(inspect(reason), 0, 500)

  defp cancel_background_work(state, :all) do
    # spec 73 T8
    if hook = state.pending_session_hook, do: Task.shutdown(hook.task, 100)

    state
    |> cancel_background_work(Map.keys(state.pending_isolation))
    |> cancel_background_work(Map.keys(state.pending_finalization))
    |> then(fn state ->
      %{
        state
        | pending_session_hook: nil,
          isolation_generation: state.isolation_generation + 1,
          finalization_generation: state.finalization_generation + 1
      }
    end)
  end

  defp cancel_background_work(state, ids) do
    ids = MapSet.new(ids)

    {isolation, kept_isolation} =
      Map.split(
        state.pending_isolation,
        ids
        |> MapSet.intersection(MapSet.new(Map.keys(state.pending_isolation)))
        |> MapSet.to_list()
      )

    {finalization, kept_finalization} =
      Map.split(
        state.pending_finalization,
        ids
        |> MapSet.intersection(MapSet.new(Map.keys(state.pending_finalization)))
        |> MapSet.to_list()
      )

    Enum.each(isolation, fn {_node_id, %{task: task}} -> Task.shutdown(task, 100) end)
    Enum.each(finalization, fn {_node_id, %{task: task}} -> Task.shutdown(task, 100) end)

    %{
      state
      | pending_isolation: kept_isolation,
        pending_finalization: kept_finalization
    }
  end

  defp settle_pending_interactions(state, ids) do
    ids = Enum.to_list(ids)
    {approvals, kept_approvals} = Map.split(state.approvals, ids)

    Enum.each(approvals, fn {node_id, %{from: from, timer: timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, :denied)
      SwarmCode.Domain.Engine.Questions.delete(state.run.id, node_id)
    end)

    {questions, kept_questions} = Map.split(state.questions, ids)

    Enum.each(questions, fn {node_id, %{from: from, timer: timer}} ->
      cancel_timer(timer)
      GenServer.reply(from, {:error, "stopped"})
      SwarmCode.Domain.Engine.Questions.delete(state.run.id, node_id)
      Events.broadcast(state.conversation.id, {:question_cleared, state.run.id, node_id})
    end)

    # spec 73 T61: a stopped or crashed agent's `wait_for_message` waiter
    # (spec 72 C2) went with it only in terminate/2; until its timer fired
    # (up to 300 s) it sat in the list, and a message for that id would have
    # been dequeued for a caller that died with its AgentSup.
    stopped = MapSet.new(ids)
    {waiters, kept_waiters} = Enum.split_with(state.message_waiters, &(&1.node_id in stopped))

    Enum.each(waiters, fn waiter ->
      Process.cancel_timer(waiter.timer)
      GenServer.reply(waiter.from, {:error, :timeout})
    end)

    %{
      state
      | approvals: kept_approvals,
        questions: kept_questions,
        message_waiters: kept_waiters
    }
  end

  defp stop_everything(state) do
    # spec 73 T41: the two settle loops were a byte-for-byte copy of
    # `settle_pending_interactions/2`; every pending approval and question of
    # the run is settled through the one function the stop paths share.
    state =
      settle_pending_interactions(state, Map.keys(state.approvals) ++ Map.keys(state.questions))

    # spec 67 G30 (pass 62 T1 left this call site to pass 63): the commands a
    # run left running in the background are its own. Stop means stop — three
    # "start the server" turns no longer leave three servers on 4000–4002.
    SwarmCode.Domain.Tools.BackgroundProcs.kill_all(state.run.id)

    state = %{state | approvals: %{}, questions: %{}, queue: []} |> cancel_background_work(:all)
    # Spec 43 §1.2: nothing is killed here. The `{:stop, :normal, …}` that
    # follows ends this process, and `RunSup` (one_for_all, auto_shutdown on
    # the RunServer) tears the agents down exactly once — it always did, after
    # the loop below had already done it agent by agent, synchronously. The
    # monitors go first so nothing that dies now is read as a crash.
    state = Enum.reduce(Map.keys(state.agents), state, fn id, acc -> demonitor(acc, id) end)
    state = Enum.reduce(Map.keys(state.nodes), state, fn id, acc -> mark_stopped(acc, id) end)

    case state.run.kind do
      "workflow" -> finish_workflow(state, "stopped", %{})
      "research" -> finish_research(state, "stopped", %{})
      _other -> finish_run(state, "stopped", :stopped)
    end
  end

  defp notify_waiting(state, node_id) do
    if MapSet.member?(state.waiting_notified, node_id) do
      state
    else
      name = SwarmCode.Domain.Conversations.Run.display_name(state.run)
      notify_async(fn -> SwarmCode.Domain.Notifications.notify_waiting(name) end)
      %{state | waiting_notified: MapSet.put(state.waiting_notified, node_id)}
    end
  end

  # Spec 36 §A7: `SwarmCode.Domain.Desktop` asks wx whether the window is active, which
  # is a synchronous round trip into the GUI loop. Run from here that made a
  # stalled wx stall the run's sole state owner — and with it every agent of the
  # run — for as long as it took. It is a notification: it can happen elsewhere.
  defp notify_async(fun) do
    Task.Supervisor.start_child(SwarmCode.Domain.TaskSupervisor, fun)
    :ok
  end

  # ------------------------------------------------------------------ completion

  defp strip_error_kind({:error, kind, msg}) when is_atom(kind), do: {:error, msg}
  defp strip_error_kind(result), do: result

  defp finish_run(state, status, result, error_kind \\ nil) do
    state = flush(state)
    run = state.run
    totals = %{tokens_in: run.tokens_in, tokens_out: run.tokens_out, cost_usd: run.cost_usd}
    conv_id = state.conversation.id

    error_msg =
      case result do
        {:error, msg} -> to_string(msg)
        _ -> ""
      end

    {update, creates} =
      case run.kind do
        # Spec 50 §1.4: a compact run finishes exactly like a chat turn — the text
        # the model produced becomes its one message, with the run's token totals.
        # `tokens_in` is then the history the model was shown and `tokens_out` the
        # summary, which is the `84.2k → 6.1k` the card prints (spec 50 §1.6).
        kind when kind in ["chat", "compact"] ->
          assistant_text = Chunks.to_string(state.assistant_text)
          assistant_reasoning = Chunks.to_string(state.assistant_reasoning)

          text =
            cond do
              String.trim(assistant_text) != "" -> assistant_text
              match?({:ok, _}, result) -> elem(result, 1)
              true -> ""
            end

          text = if status == "stopped", do: text <> "\n\n_(stopped)_", else: text

          update =
            if state.assistant_message do
              attrs =
                totals
                |> Map.put(:content, text)
                |> Map.put(:reasoning, nil_if_blank(assistant_reasoning))

              {state.assistant_message, attrs}
            end

          creates =
            if status == "failed",
              do: [%{conversation_id: conv_id, role: "error", content: error_msg, run_id: run.id}],
              else: []

          {update, creates}

        "swarm" ->
          {role, content} =
            case {status, result} do
              {"done", {:ok, text}} -> {"swarm", text}
              {"failed", _} -> {"error", "Swarm failed: " <> error_msg}
              {"stopped", _} -> {"swarm", "Swarm stopped by user."}
              _ -> {"swarm", ""}
            end

          {nil,
           [
             Map.merge(totals, %{
               conversation_id: conv_id,
               role: role,
               content: content,
               run_id: run.id
             })
           ]}

        # A research run finishes through `finish_research/3`; anything else that
        # ever reaches here must not blow up the run on a missing clause.
        _other ->
          {nil, []}
      end

    # spec 36 §A2: the `flush/1` at the top of this function has already
    # persisted the three totals columns, so repeating them here is a second
    # UPDATE of identical values. The status still has to be written and
    # announced, so the write stays — only the totals drop out of it when
    # `flush_totals/1` has them.
    # spec 67 T30 (G42): why the run failed, as something upstream can branch on.
    # spec 72 B2: all terminal statuses get an error_kind for uniform querying.
    terminal =
      case status do
        "failed" ->
          kind = error_kind || SwarmCode.Domain.LLM.Error.classify(nil, nil, error_msg)
          %{status: status, finished_at: now(), error_kind: to_string(kind)}

        "done" ->
          kind = error_kind || :done
          %{status: status, finished_at: now(), error_kind: to_string(kind)}

        _other ->
          %{status: status, finished_at: now()}
      end

    current_totals = {run.tokens_in, run.tokens_out, run.cost_usd}

    run_attrs =
      if state.totals_written == current_totals,
        do: terminal,
        else: Map.merge(totals, terminal)

    opts =
      [create_messages: creates, touch: conv_id] ++
        if(update, do: [update_message: update], else: []) ++
        case goal_settlement(run, status) do
          nil -> []
          pair -> [goal: pair]
        end

    # spec 55 T8 (55a A2): one transaction; the run is marked finished in the same commit
    # as the answer, and announced last (`announce_run/1`).
    case SwarmCode.Domain.Conversations.Writes.finish_turn(run, run_attrs, opts) do
      {:ok, %{run: written}} ->
        state =
          %{state | run: written, run_dirty: true, finish_pending: nil}
          |> note_totals_written(run_attrs)
          |> cleanup_worktrees()

        if run.kind == "swarm" and status in ["done", "failed"] do
          prompt = String.slice(state.prompt, 0, 60)

          notify_async(fn ->
            SwarmCode.Domain.Notifications.notify_finished("Swarm finished: " <> prompt)
          end)
        end

        announce_run(state)

      {:error, :database_busy} ->
        rounds = if state.finish_pending, do: state.finish_pending.attempts, else: 0

        if rounds + 1 >= 4 do
          bytes =
            case update do
              {_m, a} -> byte_size(a.content)
              nil -> 0
            end

          Logger.error(
            "swarm_code: the answer of run #{run.id} could not be written (database busy) — #{bytes} bytes lost"
          )

          state = update_run(state, %{status: "failed", finished_at: now()})

          write_message(%{
            conversation_id: conv_id,
            role: "error",
            content: "The answer could not be stored: database busy",
            run_id: run.id
          })

          announce_run(%{state | finish_pending: nil})
        else
          Process.send_after(self(), :finish_retry, 250)
          %{state | finish_pending: %{status: status, result: result, attempts: rounds + 1}}
        end

      {:error, changeset} ->
        Logger.error("swarm_code db write failed: #{inspect(changeset.errors)}")
        state = update_run(state, run_attrs)
        announce_run(%{state | finish_pending: nil})
    end
  end

  # Spec 13 §10: nothing used to set a goal to `done`, so the composer kept a
  # goal bar for a goal that had long been reached. A run that finished cleanly
  # closes its goal; a failed or stopped run only pauses it, so ▶ resumes.
  #
  # spec 55 T8: what to write for the goal, decided here, written by `Writes.finish_turn/3`.
  defp goal_settlement(%{goal_id: goal_id} = run, status)
       when is_binary(goal_id) and status in ["done", "failed", "stopped"] do
    case Conversations.get_goal(goal_id) do
      # Only the run that is currently pursuing the goal may close it — a
      # stale run finishing late never touches a goal someone re-started.
      %{status: "active", run_id: rid} = goal when rid in [nil, run.id] ->
        if status == "done",
          do: {goal, %{status: "done", finished_at: now()}},
          else: {goal, %{status: "paused"}}

      _other ->
        nil
    end
  end

  defp goal_settlement(_run, _status), do: nil

  # spec 55 T8: a finish that is waiting for `:finish_retry` keeps the process.
  defp stop_or_retry(%{finish_pending: nil} = state), do: {:stop, :normal, state}
  defp stop_or_retry(state), do: {:noreply, state}

  defp nil_if_blank(text) when is_binary(text) do
    if String.trim(text) == "", do: nil, else: text
  end

  defp nil_if_blank(_), do: nil

  # ------------------------------------------------------------------ workflows

  defp finish_workflow(state, status, attrs) do
    state = flush(state)
    wf = state.workflow.wf
    run = state.run
    totals = %{tokens_in: run.tokens_in, tokens_out: run.tokens_out, cost_usd: run.cost_usd}
    run_attrs = Map.merge(totals, %{status: status, finished_at: now()})

    # spec 55 T9 (55a A3/A9): one transaction, never a bang; totals from the state.
    {wf, state} =
      case SwarmCode.Domain.Conversations.Writes.finish_workflow_run(wf, attrs, run, run_attrs) do
        {:ok, {wf, written}} ->
          {wf, %{state | run: written, run_dirty: true} |> note_totals_written(run_attrs)}

        {:error, :database_busy} ->
          # spec 60 T7: spec 55 5.4 — the run row gets its own retry (`update_run/2` never raises).
          state = warn_busy(update_run(%{state | run: run}, run_attrs), "workflow row")
          {struct(wf, attrs), state}

        {:error, changeset} ->
          Logger.error("swarm_code db write failed: #{inspect(changeset.errors)}")
          {struct(wf, attrs), %{state | run: struct(run, run_attrs), run_dirty: true}}
      end

    state = put_in(state.workflow.wf, wf)

    state =
      put_node(state, state.root_node_id, %{
        status: root_status(status),
        detail: wf.pause_message || wf.gate_question,
        finished_at: now()
      })

    state = if status in ["done", "failed", "stopped"], do: stop_workers_now(state), else: state

    post_workflow_message(state, wf, status, totals)

    state = cleanup_worktrees(state)
    SwarmCode.Domain.Workflows.broadcast(state.conversation.id, wf)
    state = announce_run(state)

    if status in ["done", "failed"] do
      notify_async(fn ->
        SwarmCode.Domain.Notifications.notify_finished("Workflow #{wf.display_name} finished")
      end)
    end

    if status == "done" and wf.auto_continue, do: continue_assistant(state, wf)

    state
  end

  # Spec 24 §3.4: the research twin of `finish_workflow/3`. It never writes a
  # transcript message — the research's own page is where the result lives.
  defp finish_research(state, status, attrs) do
    # Spec 39 §1.2: whoever stops the run — ⌘Q, Engine.stop_all/1, the pane —
    # the research closes with the same status instead of "crashing" when its
    # awaits come back dead.
    SwarmCode.Domain.Research.Server.run_finished(state.research.id, status)
    state = flush(state)
    run = state.run
    totals = %{tokens_in: run.tokens_in, tokens_out: run.tokens_out, cost_usd: run.cost_usd}
    run_attrs = Map.merge(totals, %{status: status, finished_at: now()})

    # spec 55 T9 (55a A3/A9): the retried transaction; totals from the state.
    state =
      case SwarmCode.Domain.Conversations.Writes.finish_turn(state.run, run_attrs,
             touch: state.conversation.id
           ) do
        {:ok, %{run: run}} ->
          %{state | run: run, run_dirty: true} |> note_totals_written(run_attrs)

        {:error, _} ->
          update_run(state, run_attrs)
      end

    state =
      state
      |> put_node(state.root_node_id, %{
        status: root_status(status),
        detail: attrs[:detail],
        finished_at: now()
      })
      |> stop_workers_now()
      |> cleanup_worktrees()

    state = announce_run(state)

    if status in ["done", "failed"] do
      prompt = String.slice(to_string(state.run.prompt), 0, 60)

      notify_async(fn ->
        SwarmCode.Domain.Notifications.notify_finished("Deep research finished: " <> prompt)
      end)
    end

    state
  end

  defp stop_workers_now(state) do
    # Spec 51 §2.7: a released slot must not admit the next queued worker of a
    # run that is ending — `kill_agent/2` → `release_slot/2` → `start_queued/1`
    # used to start an AgentServer (and a `git worktree add`) that terminate/2
    # shut down 100 ms later.
    state = %{state | queue: []}

    Enum.reduce(Map.keys(state.nodes), state, fn id, acc ->
      case acc.nodes[id] do
        %{status: s} when s in @finished -> acc
        %{kind: "agent"} -> acc |> kill_agent(id) |> mark_stopped(id)
        _ -> mark_stopped(acc, id)
      end
    end)
  end

  defp root_status("done"), do: "done"
  defp root_status("failed"), do: "failed"
  defp root_status(_other), do: "stopped"

  # Spec 51 §1.2: `create_message/1` no longer raises when a writer holds the
  # lock past `busy_timeout`; a lost final message is at least in the log.
  defp write_message(attrs) do
    case Conversations.create_message(attrs) do
      {:ok, _message} = ok ->
        ok

      {:error, :database_busy} = busy ->
        Logger.warning("swarm_code: message not written: database busy")
        busy

      {:error, _reason} = error ->
        error
    end
  end

  defp post_workflow_message(state, wf, status, totals) do
    conv_id = state.conversation.id

    case status do
      "done" ->
        write_message(
          Map.merge(totals, %{
            conversation_id: conv_id,
            role: "workflow",
            content: workflow_summary(wf),
            run_id: state.run.id
          })
        )

      "failed" ->
        write_message(%{
          conversation_id: conv_id,
          role: "error",
          content: "Workflow #{wf.display_name} failed: " <> to_string(wf.pause_message),
          run_id: state.run.id
        })

      "stopped" ->
        write_message(%{
          conversation_id: conv_id,
          role: "workflow",
          content: "Workflow #{wf.display_name} stopped.",
          run_id: state.run.id
        })

      _ ->
        :ok
    end
  end

  @doc false
  def workflow_summary(wf) do
    case wf.result && Jason.decode(wf.result) do
      {:ok, %{"summary" => summary}} when is_binary(summary) ->
        summary

      {:ok, value} ->
        "```json\n" <> Jason.encode!(value, pretty: true) <> "\n```"

      _ ->
        "Workflow #{wf.display_name} finished."
    end
  end

  defp continue_assistant(state, wf) do
    conversation = state.conversation

    if SwarmCode.Domain.Engine.chat_run_ids(conversation.id) == [] do
      text = "[workflow #{wf.display_name} finished]\n" <> workflow_summary(wf)
      SwarmCode.Domain.Engine.start_chat_turn(conversation, text, [], store_user: false)
    end
  end

  # A resumed workflow run keeps the nodes of its earlier attempts.
  defp load_nodes(state) do
    # spec 60 T4: finished ops boot light, as a fresh run keeps them after its flush.
    nodes = state.run.id |> Conversations.list_nodes() |> Enum.map(&boot_light/1)

    children =
      Enum.reduce(nodes, %{}, fn node, acc ->
        Map.update(acc, node.parent_id, [node.id], &[node.id | &1])
      end)

    position = nodes |> Enum.map(& &1.position) |> Enum.max(fn -> 0 end)

    totals =
      nodes
      |> Enum.filter(&(&1.kind == "agent"))
      |> Map.new(fn node ->
        {node.id, {node.tokens_in || 0, node.tokens_out || 0, node.cost_usd}}
      end)

    %{
      state
      | nodes: Map.new(nodes, &{&1.id, &1}),
        children: children,
        position: position,
        totals: totals,
        totals_written: {state.run.tokens_in || 0, state.run.tokens_out || 0, state.run.cost_usd},
        stripped: MapSet.union(state.stripped, MapSet.new(for n <- nodes, light?(n), do: n.id))
    }
  end

  # spec 60 T4: a resumed run holds finished ops in the shape a fresh run keeps after its flush
  # (`drop_finished_text/2`); the rows are untouched.
  defp light?(%{kind: "op", status: s, op_type: t}),
    do: s in @finished and t not in Node.whole_ops()

  defp light?(_node), do: false

  defp boot_light(node) do
    if light?(node),
      do: %{Node.light(node) | result: nil, detail: nil, input: nil, error: nil},
      else: node
  end

  # The single announcement of a terminal run write: it is broadcast here, in
  # order, and the dirty flag is cleared so the next flush does not repeat it.
  defp announce_run(state) do
    Events.broadcast(state.conversation.id, {:run_updated, state.run})
    %{state | run_dirty: false}
  end

  # Spec 33 §4: the silent writer. This process announces the run itself, from
  # the flush, after the node and delta events of the same slice.
  defp update_run(state, attrs) do
    # Spec 54 §1.1 (54a A1): retried, never raised. A terminal run row that the
    # database refuses is the one the boot sweep settles; the process must not
    # die here and take its agents with it.
    case Conversations.with_busy_retry(fn -> Conversations.update_run_row(state.run, attrs) end) do
      {:ok, run} ->
        %{state | run: run, run_dirty: true} |> note_totals_written(attrs)

      {:error, :database_busy} ->
        state = warn_busy(state, "run row")
        %{state | run: struct(state.run, attrs), run_dirty: true}

      {:error, cs} ->
        Logger.error("swarm_code db write failed: #{inspect(cs.errors)}")
        %{state | run: struct(state.run, attrs), run_dirty: true}
    end
  end

  # `run_finished` and the workflow paths persist the totals themselves; without
  # this the next flush wrote the same three columns again (spec 20 review).
  defp note_totals_written(state, attrs) do
    if Enum.any?([:tokens_in, :tokens_out, :cost_usd], &Map.has_key?(Map.new(attrs), &1)) do
      %{
        state
        | totals_written: {state.run.tokens_in, state.run.tokens_out, state.run.cost_usd}
      }
    else
      state
    end
  end

  # ------------------------------------------------------------------ approvals (spec 66)

  # T21: the same teardown `handle_call(:stop, …)` does, from a cast.
  defp stop_after_deny(state) do
    state = stop_everything(state)

    if state.finish_pending do
      Enum.each(state.agents, fn {_id, agent} -> stop_agent_async(state.run.id, agent) end)
      {:noreply, state}
    else
      {:stop, :normal, state}
    end
  end

  # T3: what the user is actually being asked to approve — the command (or the
  # path, the query, the url) and the model's one-line justification for it. The
  # arguments were already on the node (`Operation.input_of/1`, 8 KB of JSON);
  # nothing rendered them, so the card showed 60 characters of title.
  defp approval_detail(state, node_id) do
    case Jason.decode(node_input(state, node_id)) do
      {:ok, %{} = args} ->
        body = args["command"] || args["path"] || args["query"] || args["url"]

        [body && String.slice(to_string(body), 0, @approval_detail_chars), args["justification"]]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join("\n— ")
        |> case do
          "" -> "awaiting approval"
          text -> text
        end

      _other ->
        "awaiting approval"
    end
  end

  # T5: the family the fourth pill would remember, or nil when there is nothing
  # safe to remember — a dangerous command is never offered the pill.
  defp approval_prefix(state, node_id, safety) do
    with false <- safety == :dangerous,
         %{op_type: "run_command"} <- state.nodes[node_id],
         command when is_binary(command) and command != "" <- node_command(state, node_id),
         prefix when prefix != "" <- SwarmCode.Domain.Tools.CommandSafety.prefix(command) do
      prefix
    else
      _other -> nil
    end
  end

  # T5: the project already said yes to this family of commands.
  #
  # spec 67 T11 (B4): and to running it where the family was approved. The
  # remembered prefix is the command's first segment; `run_command`'s `workdir`
  # moves that same command into any directory under the project root, which
  # the pill never showed and the user never agreed to.
  defp auto_approved?(state, node_id) do
    with %{op_type: "run_command"} <- state.nodes[node_id],
         command when is_binary(command) and command != "" <- node_command(state, node_id),
         true <- node_workdir(state, node_id) in [nil, ""],
         [_ | _] = prefixes <- project_prefixes(state) do
      SwarmCode.Domain.Tools.CommandSafety.prefix(command) in prefixes
    else
      _other -> false
    end
  end

  # spec 67 T11 (B22): the set `:always` holds `{permission, op_type}` pairs —
  # "every call of *this tool* in this run", which is what the pill says.
  defp always_key(state, node_id, permission) do
    case state.nodes[node_id] do
      %{op_type: op_type} when is_binary(op_type) -> {permission, op_type}
      _other -> {permission, nil}
    end
  end

  # spec 67 T11 (G39): how many sub-agents this run has opened, finished ones
  # included — the cap is on what a run may spend, not on what it runs at once
  # (`max_live` is that).
  defp sub_agents(state) do
    Enum.count(state.agents, fn {_id, agent} -> Map.get(agent.spec, :role) == "sub" end)
  end

  # spec 72 A3: look up a model name against the configured providers.
  defp resolve_model_name(name, state) do
    # First try as a "provider_id|model" option string
    case Providers.parse_option(name) do
      {provider_id, model} ->
        case Providers.get_cached(provider_id) do
          nil -> nil
          provider -> %{provider: provider, model: model}
        end

      nil ->
        # Try matching just the model name against known provider models
        settings = state.settings

        # spec 72 R12: the cached list (invalidated by Providers.broadcast/0),
        # not a Repo.all inside the state owner's start_agent call.
        Enum.find_value(
          SwarmCode.Domain.Cache.fetch({:providers, :all}, &Providers.list/0),
          fn provider ->
            if name in (provider.models || []) do
              %{provider: provider, model: name}
            end
          end
        ) ||
          case Providers.parse_option(Providers.option(settings.default_chat_provider_id, name)) do
            {provider_id, ^name} ->
              case Providers.get_cached(provider_id) do
                nil -> nil
                provider -> %{provider: provider, model: name}
              end

            _ ->
              nil
          end
    end
  end

  # spec 72 A3: effort resolution order:
  # 1. explicit per-spawn override
  # 2. agent definition's effort
  # 3. the run's effort
  defp resolve_agent_effort(override, agent_def, state) do
    cond do
      is_binary(override) and override in ~w(low medium high xhigh max) ->
        override

      agent_def != nil and is_binary(agent_def.effort) ->
        agent_def.effort

      true ->
        state.effort
    end
  end

  # spec 67 T11 (B9): what the server itself offered on the card.
  defp node_prefix(state, node_id) do
    case state.nodes[node_id] do
      %{approval_prefix: prefix} when is_binary(prefix) -> prefix
      _other -> nil
    end
  end

  defp node_input(state, node_id) do
    case state.nodes[node_id] do
      %{input: input} when is_binary(input) -> input
      _other -> ""
    end
  end

  # spec 68 T7: decode once instead of separately for command and workdir.
  defp node_decoded_input(state, node_id) do
    case Jason.decode(node_input(state, node_id)) do
      {:ok, map} when is_map(map) -> map
      _other -> %{}
    end
  end

  defp node_command(state, node_id) do
    Map.get(node_decoded_input(state, node_id), "command")
  end

  defp node_workdir(state, node_id) do
    Map.get(node_decoded_input(state, node_id), "workdir")
  end

  # Read live: a prefix approved in this run applies to the next op of the same
  # run, and `Projects.update/2` drops the cached copy for every other window.
  defp project_prefixes(state) do
    project = SwarmCode.Domain.Projects.get_cached(state.project.id) || state.project
    Map.get(project, :auto_approve_prefixes) || []
  end

  # spec 67 T11 (B23): a conversation without a project runs on
  # `Projects.scratch!/0`, and Settings lists only `scratch == false` — a family
  # remembered there could never be seen, reviewed or forgotten, and it applied
  # to every project-less conversation for ever. It is approved this once.
  defp remember_prefix(%{project: %{scratch: true}} = state, _prefix), do: state

  defp remember_prefix(state, prefix) do
    project = SwarmCode.Domain.Projects.get_cached(state.project.id) || state.project
    known = Map.get(project, :auto_approve_prefixes) || []

    if prefix in known do
      state
    else
      case SwarmCode.Domain.Projects.update(project, %{auto_approve_prefixes: known ++ [prefix]}) do
        {:ok, updated} -> %{state | project: updated}
        {:error, _changeset} -> state
      end
    end
  end
end
