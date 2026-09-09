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
  alias SwarmCode.Domain.Engine.{AgentsSup, Events, Prompts}
  alias SwarmCode.Domain.LLM.Chunks
  alias SwarmCode.Domain.{Pricing, Tools}
  alias SwarmCode.Domain.Tools.IntegrateAgent
  alias SwarmCode.Domain.Projects.Workspace

  @flush_ms 100
  # The one-line preview a node carries. It is pushed to every open LiveView on
  # every flush, so 8 streaming agents at 500 chars were ~40 KB/s of text the UI
  # truncates anyway (spec 12 §11.2).
  @detail_chars 160
  @detail_scan_bytes 1_280
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
  @persisted ~w(status progress detail result error tokens_in tokens_out cache_read cache_write
                cost_usd turn max_turns title started_at finished_at workspace_path branch
                base_sha changes_stat integrated phase group)a
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
    safe_call(run_id, {:steer, text, images, opts[:node_id]})
  end

  @spec request_approval(String.t(), String.t(), :read | :write | :execute) ::
          :approved | :denied | :timeout
  def request_approval(run_id, node_id, permission),
    do: GenServer.call(via(run_id), {:request_approval, node_id, permission}, :infinity)

  @spec resolve_approval(String.t(), String.t(), :approve | :deny | :always) :: :ok
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
        }) :: {:ok, String.t()}
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

  @spec get_state(String.t()) :: map() | {:error, :not_running}
  def get_state(run_id), do: safe_call(run_id, :get_state)

  defp safe_call(run_id, msg) do
    GenServer.call(via(run_id), msg)
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

    Enum.each(state.approvals, fn {_node_id, %{from: from, timer: timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, :denied)
    end)

    Enum.each(state.questions, fn {_node_id, %{from: from, timer: timer}} ->
      cancel_timer(timer)
      GenServer.reply(from, {:error, "stopped"})
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
        finalization_generation: 0,
        pending_finalization: %{},
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

    {:ok, state, {:continue, :boot}}
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
      |> start_agent_process(node.id)

    # Spec 43 §1.4: the transcript window was only ever read by `root_spec/1`
    # above; the root agent now holds its own copy, and this one would have
    # stayed for the life of the run (and travelled with every `get_state/1`).
    {:noreply, %{state | history: []}}
  end

  @impl true
  def handle_call({:register_node, attrs}, _from, state) do
    {node, state} = do_register_node(state, attrs)
    {:reply, {:ok, node}, state}
  end

  def handle_call({:request_approval, node_id, permission}, from, state) do
    if MapSet.member?(state.always, permission) do
      {:reply, :approved, state}
    else
      timer = Process.send_after(self(), {:approval_timeout, node_id}, @approval_timeout_ms)

      state =
        state
        |> put_in([:approvals, node_id], %{from: from, timer: timer, permission: permission})
        |> put_node(node_id, %{status: "awaiting_approval", detail: "awaiting approval"})

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
        answers: %{}
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

  def handle_call({:start_agent, attrs}, _from, state) do
    name = String.slice(attrs.name, 0, 24)

    # Nested agents branch from their parent's worktree, so the isolation base is
    # the root of the agent that owns the spawn_agent op.
    parent_root = agent_root(state, attrs.parent_id)

    spec = %{
      name: name,
      role: "sub",
      system: Prompts.sub_agent(state.project, name, prompt_opts(state)),
      messages: [%{role: "user", content: Prompts.sub_agent_user(attrs.task, attrs.context)}],
      model: state.swarm_model || state.chat_model,
      depth: attrs.depth,
      project_root: parent_root
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
    if node_id == state.root_node_id do
      handle_call(:stop, from, state)
    else
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

      # Spec 51 §5.9 (a): a stop is an error for whoever awaits it, never a
      # report — write_spec printed it as an IMPLEMENTER REPORT.
      name = (state.nodes[node_id] && state.nodes[node_id].name) || "agent"
      state = settle(state, node_id, {:error, "Agent #{name} was stopped by the user"})
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
    approvals =
      state.approvals
      |> Enum.take(64)
      |> Enum.map(fn {node_id, %{permission: permission}} ->
        node = Map.get(state.nodes, node_id, %{})

        %{
          node_id: node_id,
          kind: :approval,
          permission: permission,
          tool: bound_text(Map.get(node, :op_type), 128),
          args: bound_args(Map.get(node, :input)),
          questions: []
        }
      end)

    questions =
      state.questions
      |> Enum.take(64 - length(approvals))
      |> Enum.map(fn {node_id, entry} ->
        %{
          node_id: node_id,
          kind: :question,
          permission: nil,
          tool: nil,
          args: "{}",
          questions: unanswered_question_data(entry)
        }
      end)

    {:reply, Enum.take(approvals ++ questions, 64), state}
  end

  def handle_call({:answer_question, node_id, index, option_indices, custom}, _from, state) do
    with {:ok, entry} <- pending_question_entry(state.questions, node_id, index),
         {:ok, answer} <- validated_answer(entry.questions, index, option_indices, custom) do
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

      {%{from: from, timer: timer, permission: permission}, approvals} ->
        Process.cancel_timer(timer)

        {reply, state} =
          case decision do
            :approve -> {:approved, state}
            :deny -> {:denied, state}
            :always -> {:approved, %{state | always: MapSet.put(state.always, permission)}}
          end

        GenServer.reply(from, reply)

        state =
          %{state | approvals: approvals}
          |> put_node(node_id, %{status: "running", detail: nil})

        SwarmCode.Domain.Engine.Questions.delete(state.run.id, node_id)

        {:noreply, state}
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
              finished_at: now()
            })
            |> settle(node_id, {:error, "Agent #{node.name || "agent"} crashed"})
            |> release_slot(node_id)

          if node_id == state.root_node_id do
            crash_msg =
              if state.run.kind == "chat",
                do: "The assistant process crashed: " <> reason_text,
                else: reason_text

            finish_run(state, "failed", {:error, crash_msg}) |> stop_or_retry()
          else
            {:noreply, state}
          end
        end
    end
  end

  defp pending_question_entry(questions, node_id, index) do
    case Map.get(questions, node_id) do
      nil ->
        {:error, :stale_question}

      entry ->
        if Map.has_key?(Map.get(entry, :answers, %{}), index),
          do: {:error, :stale_question},
          else: {:ok, entry}
    end
  end

  defp validated_answer(questions, index, indices, custom)
       when is_list(questions) and length(questions) in 1..4 and
              is_integer(index) and index >= 0 and index < length(questions) and
              is_list(indices) and length(indices) <= 12 and
              is_binary(custom) and byte_size(custom) <= 4_000 do
    question = Enum.at(questions, index)
    options = if is_map(question), do: question["options"] || question[:options] || [], else: []

    multi =
      is_map(question) and (question["multi_select"] == true or question[:multi_select] == true)

    if is_list(options) and String.valid?(custom) and
         (indices != [] or String.trim(custom) != "") and
         (multi or length(indices) <= 1) and
         length(indices) == length(Enum.uniq(indices)) and
         Enum.all?(indices, &(is_integer(&1) and &1 >= 0 and &1 < min(length(options), 12))) do
      labels = Enum.map(indices, fn i -> original_option_label(Enum.at(options, i)) end)

      if Enum.all?(labels, &is_binary/1),
        do: {:ok, %{"labels" => labels, "custom" => custom}},
        else: {:error, :invalid_answer}
    else
      {:error, :invalid_answer}
    end
  end

  defp validated_answer(_, _, _, _), do: {:error, :invalid_answer}
  defp original_option_label(%{"label" => label}) when is_binary(label), do: label
  defp original_option_label(%{label: label}) when is_binary(label), do: label
  defp original_option_label(label) when is_binary(label), do: label
  defp original_option_label(_), do: nil

  defp unanswered_question_data(entry) do
    entry.questions
    |> bound_list(4)
    |> Enum.with_index()
    |> Enum.reject(fn {_q, index} -> Map.has_key?(Map.get(entry, :answers, %{}), index) end)
    |> Enum.map(fn {q, index} -> bound_question_data(q, index) end)
  end

  # This projection crosses a process boundary. Keep it independent of the
  # runtime maps and reject malformed input instead of reflecting it verbatim.
  defp bound_question_data(question, index) when is_map(question) do
    %{
      index: index,
      question: bound_text(question["question"] || question[:question], 4_000),
      options:
        bound_list(question["options"] || question[:options], 12) |> Enum.map(&bound_option/1),
      multiple: question["multi_select"] == true or question[:multi_select] == true
    }
  end

  defp bound_question_data(_, index),
    do: %{index: index, question: "", options: [], multiple: false}

  defp bound_option(option) when is_map(option) do
    %{
      label: bound_text(option["label"] || option[:label], 500),
      description: bound_text(option["description"] || option[:description], 500)
    }
  end

  defp bound_option(option), do: %{label: bound_text(option, 500), description: ""}
  defp bound_list(list, count) when is_list(list), do: Enum.take(list, count)
  defp bound_list(_, _), do: []

  # The node input is already an 8 KiB JSON prefix. Do not decode an arbitrarily
  # large term supplied by a corrupted/legacy node, nor return truncated raw JSON
  # that could include credentials. Redaction precedes output truncation.
  defp bound_args(input) when is_binary(input) and byte_size(input) <= 8_192 do
    case Jason.decode(input) do
      {:ok, map} when is_map(map) ->
        map |> bound_value(0) |> Jason.encode!() |> bound_text(8_192)

      _ ->
        "{}"
    end
  end

  defp bound_args(_), do: "{}"

  defp bound_value(_, depth) when depth > 4, do: "[TRUNCATED]"
  defp bound_value(value, _) when is_binary(value), do: bound_text(value, 2_000)

  defp bound_value(value, depth) when is_list(value),
    do: value |> Enum.take(16) |> Enum.map(&bound_value(&1, depth + 1))

  defp bound_value(value, depth) when is_map(value) do
    value
    |> Enum.take(16)
    |> Map.new(fn {key, item} ->
      normalized = String.downcase(key) |> String.replace(~r/[^a-z0-9]/, "")

      secret? =
        Enum.any?(
          ~w(apikey token secret authorization password credential cookie headers env privatekey),
          &String.contains?(normalized, &1)
        )

      {bound_text(key, 128), if(secret?, do: "[REDACTED]", else: bound_value(item, depth + 1))}
    end)
  end

  defp bound_value(value, _) when is_number(value) or is_boolean(value) or is_nil(value),
    do: value

  defp bound_value(_, _), do: nil

  defp bound_text(value, max) when is_binary(value) do
    # Validate only a bounded prefix; copy it so a multi-MB source is not retained.
    prefix = binary_part(value, 0, min(byte_size(value), max))

    case :unicode.characters_to_binary(prefix) do
      result when is_binary(result) -> result |> redact_preview() |> byte_prefix(max)
      {:incomplete, valid, _} -> valid |> redact_preview() |> byte_prefix(max)
      {:error, valid, _} -> valid |> redact_preview() |> byte_prefix(max)
    end
  end

  defp bound_text(_, _), do: ""

  defp redact_preview(text) do
    text
    |> SwarmCode.Domain.LLM.HTTP.redact()
    |> String.replace(
      ~r/((?:api[_-]?key|access[_-]?token|password|secret)\s*[=:]\s*)[^\s,;]+/i,
      "\\1[REDACTED]"
    )
  end

  defp byte_prefix(value, max) when byte_size(value) <= max, do: :binary.copy(value)

  defp byte_prefix(value, max) do
    prefix = binary_part(value, 0, max)
    if String.valid?(prefix), do: :binary.copy(prefix), else: byte_prefix(value, max - 1)
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

        {:error, %Ecto.Changeset{} = cs} ->
          Logger.error("swarm_code db write failed: #{inspect(cs.errors)}")
          state
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

    attrs =
      if is_binary(attrs[:detail]),
        do:
          Map.put(
            attrs,
            :detail,
            attrs[:detail]
            |> head(@detail_scan_bytes)
            |> one_line()
            |> String.slice(0, @detail_chars)
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

          {:error, _reason} ->
            state
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
    do: %{spec: spec, sup: nil, server: nil, ref: nil, slot: false, waiting: [], result: nil}

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
      tools:
        Map.get(spec, :tools) ||
          Tools.for_agent(spec.role, spec.depth, settings.max_agent_depth, mode(state),
            project_id: state.project.id,
            command: command(state)
          ) ++ consensus_tools(state, spec),
      depth: spec.depth,
      max_turns: Map.get(spec, :max_turns) || settings.max_agent_turns,
      project_root: root,
      approval_mode: state.project.approval_mode,
      project_id: state.project.id,
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
      settings: settings
    }

    with {:ok, sup} <- AgentsSup.start_agent(state.run.id, args),
         [{server, _}] <- Registry.lookup(SwarmCode.Domain.Registry, {:agent, node_id}) do
      ref = Process.monitor(server)
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

      if state.nodes[node_id].status == "queued",
        do: put_node(state, node_id, %{status: "running", started_at: now()}),
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
          short(state.run.id) <> "-" <> short(node_id)
        )

      branch = "swarm/#{short(state.run.id)}/#{slug(spec.name)}-#{short(node_id)}"
      {:async, %{parent_root: parent_root, path: path, branch: branch}}
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

              case git.worktree_add(work.parent_root, work.path, work.branch) do
                {:ok, _} ->
                  {:ok,
                   %{
                     root: work.path,
                     branch: work.branch,
                     base_sha: git.head(work.parent_root)
                   }}

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
        detail: "isolated in " <> attrs.branch
      })

    do_start_agent_process(state, node_id, attrs.root, attrs.branch)
  end

  defp apply_isolation(state, node_id, {:shared, root}) do
    do_start_agent_process(state, node_id, root, nil)
  end

  defp apply_isolation(state, node_id, {:error, reason}) do
    reason = normalize_worktree_reason(reason)
    Logger.warning("swarm_code could not create a worktree: #{reason}")
    agent = state.agents[node_id]
    root = agent.spec.project_root || state.project.root_path
    state = put_node(state, node_id, %{detail: "no worktree: " <> reason})
    do_start_agent_process(state, node_id, root, nil)
  end

  defp normalize_worktree_reason(reason),
    do: reason |> to_string() |> String.split("\n") |> List.last() |> to_string()

  defp maybe_images(message, images) when is_list(images) and images != [],
    do: Map.put(message, :images, images)

  defp maybe_images(message, _images), do: message

  defp short(id), do: id |> to_string() |> String.replace("-", "") |> String.slice(0, 8)

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

  defp agent_system(state, %{role: "sub"} = spec, root, branch) when is_binary(branch) do
    Prompts.sub_agent(%{state.project | root_path: root}, spec.name, prompt_opts(state)) <>
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

        task =
          Task.Supervisor.async_nolink(SwarmCode.Domain.TaskSupervisor, fn ->
            finalized =
              try do
                {:ok, commit_and_stat(path, node)}
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

  defp finalized_result(state, node_id, {:ok, text} = result, {:ok, stat}) do
    if structured?(state, node_id) do
      {put_node(state, node_id, %{changes_stat: stat}), result}
    else
      branch = state.nodes[node_id].branch
      report_with_note(state, node_id, text, branch, stat)
    end
  end

  defp finalized_result(state, _node_id, {:ok, text}, {:error, reason}) do
    reason = task_reason(reason)
    Logger.warning("swarm_code could not finalize agent changes: #{reason}")
    result = {:ok, text <> "\n\n[Could not finalize agent changes: " <> reason <> "]"}
    {state, result}
  end

  defp complete_agent(state, node_id, result) do
    attrs =
      case result do
        {:ok, text} ->
          %{status: "done", progress: 100, result: text, detail: text, finished_at: now()}

        {:error, msg} ->
          %{status: "failed", progress: 100, error: msg, detail: msg, finished_at: now()}
      end

    state =
      state
      |> put_node(node_id, attrs)
      |> settle(node_id, result)
      |> demonitor(node_id)
      |> release_slot(node_id)

    if node_id == state.root_node_id do
      status = if match?({:ok, _}, result), do: "done", else: "failed"
      finish_run(state, status, result) |> stop_or_retry()
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

          git.worktree_remove(root, node.workspace_path)

          case git.commits_ahead(root, node.base_sha || "HEAD", node.branch) do
            {:ok, 0} ->
              git.branch_delete(root, node.branch)
              Conversations.mark_node_integrated(node.id)
              update_node(run_id, node.id, %{integrated: true})

            _kept_or_unknown ->
              :ok
          end
        end

        git.worktree_prune(root)
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

  # The configured adapter is a deterministic test seam for proving that the
  # state owner stays responsive while an OS git command is blocked. Production
  # always uses SwarmCode.Domain.Git.
  defp git_adapter,
    do: Application.get_env(:swarm_code_daemon, :run_server_git_adapter, SwarmCode.Domain.Git)

  defp settle(state, node_id, result) do
    case state.agents[node_id] do
      nil ->
        state

      agent ->
        Enum.each(agent.waiting, &GenServer.reply(&1, result))
        put_agent(state, node_id, %{agent | result: agent.result || result, waiting: []})
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

  defp kill_agent(state, node_id) do
    state = demonitor(state, node_id)

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

  defp mark_stopped(state, node_id) do
    case state.nodes[node_id] do
      %{status: status} when status in @finished -> state
      nil -> state
      # spec 36 §A1: a settled node's bar is full, whatever it was mid-flight.
      _ -> put_node(state, node_id, %{status: "stopped", progress: 100, finished_at: now()})
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
        state |> subtree(node_id) |> Enum.drop(1) |> Enum.reduce(state, &mark_stopped(&2, &1))
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
    state
    |> cancel_background_work(Map.keys(state.pending_isolation))
    |> cancel_background_work(Map.keys(state.pending_finalization))
    |> then(fn state ->
      %{
        state
        | isolation_generation: state.isolation_generation + 1,
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

    %{state | approvals: kept_approvals, questions: kept_questions}
  end

  defp stop_everything(state) do
    Enum.each(state.approvals, fn {node_id, %{from: from, timer: timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, :denied)
      SwarmCode.Domain.Engine.Questions.delete(state.run.id, node_id)
    end)

    Enum.each(state.questions, fn {node_id, %{from: from, timer: timer}} ->
      cancel_timer(timer)
      GenServer.reply(from, {:error, "stopped"})
      SwarmCode.Domain.Engine.Questions.delete(state.run.id, node_id)
      Events.broadcast(state.conversation.id, {:question_cleared, state.run.id, node_id})
    end)

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

  defp finish_run(state, status, result) do
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
    terminal = %{status: status, finished_at: now()}
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
end
