defmodule SwarmCode.Domain.Research.Server do
  @moduledoc """
  One deep research, conducted (spec 24 §3.1).

  The Server owns the row, the hidden conversation and the run; the step
  pipeline itself lives in `Research.Program`, running in a Task so nothing here
  ever blocks on an agent. Stopping, crashing and finishing all converge on
  `close/3`, so a research is never left `running` with nobody driving it.
  """
  use GenServer, restart: :temporary

  alias SwarmCode.Domain.Engine.{ProjectContext, RunServer}
  alias SwarmCode.Domain.Research
  alias SwarmCode.Domain.Research.Program
  alias SwarmCode.Domain.{Conversations, Projects, Providers, Settings}

  require Logger

  # ------------------------------------------------------------------ client

  def start_link({id, mode}),
    do: GenServer.start_link(__MODULE__, {id, mode}, name: via(id), hibernate_after: 15_000)

  def via(id), do: {:via, Registry, {SwarmCode.Domain.Registry, {:research, id}}}

  @spec whereis(integer()) :: pid() | nil
  def whereis(id) do
    case Registry.lookup(SwarmCode.Domain.Registry, {:research, id}) do
      [{pid, _value}] -> pid
      _other -> nil
    end
  end

  @doc "The RunServer has registered the run's root node; the program can start."
  @spec root_ready(integer(), String.t()) :: :ok
  def root_ready(id, node_id), do: GenServer.cast(via(id), {:root_ready, node_id})

  @spec stop(integer()) :: :ok
  def stop(id) do
    GenServer.call(via(id), :stop, 15_000)
  catch
    :exit, _reason -> :ok
  end

  @doc "The run closed under the program (spec 39 §1.2); close with its status."
  @spec run_finished(integer(), String.t()) :: :ok
  def run_finished(id, status), do: GenServer.cast(via(id), {:run_finished, status})

  # ------------------------------------------------------------------ boot

  @impl true
  def init({id, mode}) do
    # Spec 51 §4.5: the Program is linked below, and a shutdown has to reach
    # `terminate/2` so the row and the run close with the server.
    Process.flag(:trap_exit, true)

    {:ok, %{id: id, mode: mode, run_id: nil, root_id: nil, ctx: nil, task: nil, closed?: false},
     {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    case Research.get(state.id) do
      nil -> {:stop, :normal, state}
      research -> boot(state, research)
    end
  end

  @busy_boot "database busy — try again"

  # spec 55 T17 (55a A20): every boot write is retried; a busy one fails the
  # research honestly instead of killing the server.
  defp boot(state, research) do
    settings = Settings.get()
    dir = Research.ensure_dir!(research)
    title = research.title || Research.fallback_title(research.question)

    # Spec 36 §A6: a report rebuild borrows the research's own hidden
    # conversation. It used to create a fresh one every time and — in `:report`
    # mode — never write the id back, so each "rebuild report" left one more
    # orphan conversation (and its finished run) behind for ever.
    reusable =
      if state.mode == :report and is_binary(research.conversation_id),
        do: Conversations.get(research.conversation_id)

    conversation =
      if reusable do
        {:ok, reusable, false}
      else
        case SwarmCode.Domain.Repo.retry(:research_boot, fn ->
               Conversations.create_for_research(research.id, "Research ##{research.id}")
             end) do
          {:ok, conversation} -> {:ok, conversation, true}
          {:error, :database_busy} -> :busy
        end
      end

    case conversation do
      :busy ->
        fail(state, research, @busy_boot)

      {:ok, conversation, created_conversation?} ->
        boot_model(state, research, conversation, created_conversation?, settings, dir, title)
    end
  end

  defp boot_model(state, research, conversation, created_conversation?, settings, dir, title) do
    case Providers.effective_model(conversation, :swarm) do
      {:error, :not_configured} ->
        # Only a conversation this boot created is thrown away again.
        if created_conversation?, do: Conversations.delete(conversation)
        fail(state, research, "no model is configured — add a provider in Settings")

      {:ok, model} ->
        # A real project row with its root swapped in memory: `Tools.Path` then
        # confines every file tool to this research's own directory, which is
        # also where the reporter writes result.md (spec 24 §3.1).
        #
        # `auto`, not `read_only`: the reporters have to be able to call
        # write_file, and read_only denies every :write in `Policy.decide/3`.
        # Read-only is enforced per agent by `capability` instead — only the two
        # reporters are handed a write tool, and `root_path` pins them here.
        # Spec 39 §1.1: `Operation.current_mode/1` honours this in-memory mode
        # for a research run instead of re-reading the scratch row per op.
        project = %{Projects.scratch!() | root_path: dir, approval_mode: "auto"}

        run_attrs = %{
          conversation_id: conversation.id,
          kind: "research",
          prompt: research.question,
          model: model.model,
          label: title,
          started_at: now()
        }

        case SwarmCode.Domain.Repo.retry(:research_boot, fn ->
               Conversations.create_run(run_attrs)
             end) do
          {:error, :database_busy} ->
            if created_conversation?, do: Conversations.delete(conversation)
            fail(state, research, @busy_boot)

          {:ok, run} ->
            case boot_row(state, research, run, conversation, title) do
              {:error, :database_busy} ->
                # spec 60 T43: the run row already exists — left `running` with
                # no process behind it, and its conversation would stay too.
                SwarmCode.Domain.Repo.retry(:research_boot_undo, fn ->
                  Conversations.update_run(run, %{status: "failed", finished_at: now()})
                end)

                if created_conversation? do
                  SwarmCode.Domain.Repo.retry(:research_boot_undo, fn ->
                    Conversations.delete(conversation)
                  end)
                end

                fail(state, research, @busy_boot)

              {:ok, research} ->
                launch(state, research, run, conversation, project, model, settings)
            end
        end
    end
  end

  # Spec 26 §5.2: a report rebuild must not reopen a finished research —
  # it borrows the tree to run one agent and leaves the row's status,
  # step, run_id and timings exactly as the real run left them.
  defp boot_row(%{mode: :report}, research, _run, _conversation, _title), do: {:ok, research}

  defp boot_row(_state, research, run, conversation, _title) do
    SwarmCode.Domain.Repo.retry(:research_boot, fn ->
      # Pass 64: the row keeps no placeholder title — every reader falls back
      # to `fallback_title/1` — so the planner's name (round 1) or the
      # reporter's H1 is the first title it gets; `title` labels the run.
      Research.update(research, %{
        status: "running",
        title: research.title,
        step: 0,
        run_id: run.id,
        conversation_id: conversation.id,
        started_at: now()
      })
    end)
  end

  defp launch(state, research, run, conversation, project, model, settings) do
    args = %{
      run: run,
      conversation: conversation,
      project: project,
      project_context: ProjectContext.build(nil, conversation),
      settings: settings,
      chat_model: model,
      swarm_model: model,
      history: [],
      prompt: research.question,
      # "build", never "plan": `Prompts.suffix/1` appends PLAN MODE ("do not
      # write files … produce a numbered plan") for mode "plan", and every
      # research agent obeyed it — the reporters answered with a plan for
      # writing result.md instead of writing it. Read-only is enforced per
      # agent by `capability`, not by the conversation mode.
      mode: "build",
      assistant_message: nil,
      research: %{id: research.id, max_live: settings.research_max_live}
    }

    case SwarmCode.Domain.Engine.start_run(args) do
      {:ok, _run_id} ->
        ctx = %{
          id: research.id,
          run_id: run.id,
          root_id: nil,
          question: research.question,
          level: research.level,
          steps_total: research.steps_total,
          fanout: research.fanout,
          interpretation: nil,
          max_sources: settings.research_max_sources,
          settings: settings,
          fallback_model: model,
          # Spec 40 §1.0: the row's own model, over every tier.
          override: Research.override(research),
          # Spec 40 §1.6: the agents' wall clock. The app env is a test
          # seam — the changeset floors the setting at 60 s.
          timeout_ms:
            Application.get_env(:swarm_code_daemon, :research_timeout_ms) ||
              (settings.research_agent_timeout_s || 600) * 1_000,
          # Spec 47 §2.1: the seam wins over the Fastest per-tier table
          # too, so a fast test still runs in milliseconds.
          timeout_forced?:
            not is_nil(Application.get_env(:swarm_code_daemon, :research_timeout_ms)),
          retry?: settings.research_retry_timeouts != false,
          max_retries: settings.research_max_retries || 1
        }

        {:noreply, %{state | run_id: run.id, ctx: ctx}}

      {:error, reason} ->
        fail(state, research, "could not start the run: " <> inspect(reason))
    end
  end

  # ------------------------------------------------------------------ program

  @impl true
  def handle_cast({:root_ready, node_id}, %{ctx: ctx} = state) when is_map(ctx) do
    ctx = %{ctx | root_id: node_id}

    # Spec 47 §2.6: a rebuild is not on anybody's critical path — it takes the
    # deep clock and the deep turn cap even when the row is a Fastest one.
    ctx = if state.mode == :report, do: Map.put(ctx, :rebuild?, true), else: ctx

    program = if state.mode == :report, do: &report_only/1, else: &Program.run/1

    # Spec 51 §4.5: linked — a dead server takes its Program with it instead
    # of leaving it spending tokens against a run nobody closes.
    task =
      Task.Supervisor.async(SwarmCode.Domain.TaskSupervisor, fn ->
        program.(refresh(ctx))
      end)

    {:noreply, %{state | root_id: node_id, ctx: ctx, task: task}}
  end

  def handle_cast({:root_ready, _node_id}, state), do: {:noreply, state}

  def handle_cast({:run_finished, status}, state) do
    status = if status in ["done", "failed"], do: status, else: "stopped"
    {:stop, :normal, close(state, status, %{})}
  end

  # The interpretation the first round recorded belongs in the reporter's ctx,
  # so it is read back from the row rather than threaded through the Task.
  defp refresh(ctx) do
    case Research.get(ctx.id) do
      nil -> ctx
      research -> %{ctx | interpretation: research.interpretation}
    end
  end

  # Spec 26 §5.2: only the HTML pass, over the `result.md` already on disk.
  defp report_only(ctx) do
    path = Research.result_path(ctx.id)

    if File.exists?(path) do
      sources = Research.get(ctx.id).sources || []
      {:ok, %{report_path: Program.html_report(ctx, path, sources)}}
    else
      {:error, "there is no result.md to build a report from"}
    end
  end

  @impl true
  def handle_call(:stop, _from, state) do
    {:stop, :normal, :ok, close(state, "stopped", %{})}
  end

  @impl true
  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, outcome} -> {:stop, :normal, close(state, "done", outcome)}
      {:error, reason} -> {:stop, :normal, close(state, "failed", %{error: to_string(reason)})}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    if run_gone?(reason) do
      # The RunServer went away under an await: the run was stopped, the
      # program did not crash (spec 39 §1.2).
      {:stop, :normal, close(state, "stopped", %{})}
    else
      message = "the research program crashed: " <> String.slice(inspect(reason), 0, 300)
      Logger.error("swarm_code research #{state.id}: #{message}")
      {:stop, :normal, close(state, "failed", %{error: message})}
    end
  end

  # Spec 51 §4.5: the linked Program's exit; the `{:DOWN, …}` clause above does
  # the closing. Any other exit signal ends the server through `terminate/2`.
  def handle_info({:EXIT, pid, _reason}, %{task: %Task{pid: pid}} = state),
    do: {:noreply, state}

  def handle_info({:EXIT, _from, reason}, state) when reason != :normal,
    do: {:stop, reason, state}

  def handle_info(_message, state), do: {:noreply, state}

  # Spec 51 §4.5: a shutdown (a quit, a supervisor) closes the research as
  # stopped; anything else failed. `close/3` kills the Program and closes the
  # borrowed run.
  @impl true
  def terminate(reason, %{closed?: false} = state) do
    status =
      if reason == :shutdown or match?({:shutdown, _}, reason), do: "stopped", else: "failed"

    close(state, status, %{error: if(status == "failed", do: "the research server stopped")})
    :ok
  rescue
    _ -> :ok
  end

  def terminate(_reason, _state), do: :ok

  defp run_gone?({reason, {GenServer, :call, _}}) when reason in [:normal, :noproc, :shutdown],
    do: true

  defp run_gone?({{:shutdown, _}, {GenServer, :call, _}}), do: true
  defp run_gone?(_reason), do: false

  # ------------------------------------------------------------------ closing

  # Idempotent: whichever of stop / finish / crash / terminate arrives first wins.
  defp close(%{closed?: true} = state, _status, _outcome), do: state

  # Spec 39 §1.5 (F7): the page always hears how a rebuild ended — a failed
  # pass used to write nothing and leave the button on "Building…" for ever.
  defp close(%{mode: :report} = state, status, outcome) do
    if state.task, do: Task.shutdown(state.task, :brutal_kill)
    research = settling(state, "read", fn -> Research.get(state.id) end)

    case {research, outcome[:report_path]} do
      {nil, _} ->
        :ok

      {research, path} when is_binary(path) ->
        # Spec 48 §2: the row now says what its report *is*, so the page reads
        # "designing…" while this runs and stops offering the button after it.
        settling(state, "write", fn ->
          Research.update(research, %{report_path: path, design_state: "designed"})
        end)

        Research.Events.report_built(state.id, {:ok, path})

      {research, nil} ->
        # A stopped design leaves the rendered report and the button; a failed
        # one says so. Either way the research itself stays `done`.
        #
        # spec 60 T44: the program task was just killed — its own restore never
        # ran — so the kept rendered.html goes back to report_path/1 here.
        Research.restore_rendered_file(research)

        if research.design_state == "designing",
          do:
            settling(state, "write", fn ->
              Research.update(research, %{
                design_state: if(status == "stopped", do: "rendered", else: "failed")
              })
            end)

        Research.Events.report_built(
          state.id,
          {:error, outcome[:error] || "the HTML pass wrote no report"}
        )
    end

    # The row is untouched otherwise, but the borrowed run still has to close or
    # its RunServer would sit there with an open root node.
    if state.run_id, do: RunServer.research_finished(state.run_id, "done", %{})
    %{state | closed?: true}
  end

  defp close(state, status, outcome) do
    if state.task, do: Task.shutdown(state.task, :brutal_kill)

    research = settling(state, "read", fn -> Research.get(state.id) end)

    if research && research.status in ["queued", "running"] do
      settling(state, "write", fn ->
        totals = if state.run_id, do: Conversations.run_totals(state.run_id), else: %{}

        Research.update(
          research,
          totals
          |> Map.take([:tokens_in, :tokens_out, :cost_usd])
          |> Map.merge(%{
            status: status,
            finished_at: now(),
            summary: outcome[:summary] || research.summary,
            sources: outcome[:sources] || research.sources,
            report_path: outcome[:report_path] || research.report_path,
            # Pass 64: the planner's short title stays; the reporter's H1 is
            # the report's own headline, not the list entry.
            title: research.title || outcome[:title],
            error: outcome[:error],
            # Spec 48 §2: "rendered" the moment the answer is readable.
            design_state: outcome[:design_state] || research.design_state,
            # Spec 39 §1.2 (F10): a research stopped in round 1 of 4 reads 1/4.
            step: if(status == "done", do: research.steps_total, else: research.step)
          })
        )
      end)

      # Spec 48 §2: the row is `done` and written before the designed pass is
      # asked for, so the page reads the answer first and the design second.
      # `:research_background_design` is the test seam (`config/test.exs` turns
      # it off): a design that outlives its test would otherwise still be
      # writing rows through the next test's sandbox connection.
      if status == "done" and outcome[:design?] == true and background_design?(),
        do: Research.design_later(state.id)
    end

    if state.run_id, do: RunServer.research_finished(state.run_id, status, outcome)
    %{state | closed?: true}
  end

  # Spec 51 §4.5 (Blockers → Orchestrator): the read and the write that settle
  # the row run right after the Program's brutal kill. A client killed mid-query
  # costs the pool that connection ("client … exited"), and a checkout queued
  # behind it exits with the same error; one retry after a beat is served by the
  # pool's next connection. A second failure is logged and the close goes on —
  # the borrowed run is told either way, so no RunServer sits on an open root.
  # (Under the test sandbox the one shared connection does not come back; the
  # tests that kill wait until nothing is querying, `server_test.exs`.)
  defp settling(state, what, fun, attempt \\ 0) do
    fun.()
  rescue
    error in [DBConnection.ConnectionError, DBConnection.OwnershipError] ->
      settle_again(state, what, fun, attempt, error)
  catch
    :exit, reason ->
      settle_again(state, what, fun, attempt, reason)
  end

  defp settle_again(state, what, fun, 0, _reason) do
    Process.sleep(50)
    settling(state, what, fun, 1)
  end

  defp settle_again(state, what, _fun, _attempt, reason) do
    Logger.error(
      "swarm_code research #{state.id}: could not #{what} the row while closing: " <>
        String.slice(inspect(reason), 0, 200)
    )

    nil
  end

  defp background_design?,
    do: Application.get_env(:swarm_code_daemon, :research_background_design, true)

  # spec 60 T45: a report rebuild borrows a *done* research — a boot that cannot
  # start (no provider, busy row) fails the design, never the research.
  defp fail(%{mode: :report} = state, research, message) do
    SwarmCode.Domain.Repo.retry(:research_fail, fn ->
      Research.update(research, %{design_state: "failed"})
    end)

    Research.Events.report_built(state.id, {:error, message})
    Logger.error("swarm_code research #{research.id}: report rebuild failed: #{message}")
    {:stop, :normal, %{state | closed?: true}}
  end

  defp fail(state, research, message) do
    # spec 55 T17 (55a A20): the failure row is retried too; a busy one is logged, never raised.
    case SwarmCode.Domain.Repo.retry(:research_fail, fn ->
           Research.update(research, %{status: "failed", error: message, finished_at: now()})
         end) do
      {:error, :database_busy} ->
        Logger.error(
          "swarm_code research #{research.id}: could not record the failure (database busy)"
        )

      _written ->
        :ok
    end

    Logger.error("swarm_code research #{research.id} failed to start: #{message}")
    {:stop, :normal, %{state | closed?: true}}
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
