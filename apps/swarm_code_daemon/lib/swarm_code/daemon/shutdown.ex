defmodule SwarmCode.Daemon.Shutdown do
  @moduledoc """
  What quitting a saved session stops (pass70 B6): the desktop's
  `Quit.stop_everything/0` at 6dd8d82.

  Pauses the running workflows (they resume from their journal), stops every
  run, kills every command a run left running (`run_command` with `yield_ms`,
  `cmd &`), waits for the runs' journals to flush, then takes the subtrees that
  own OS processes down in order: runs, researches, MCP clients, LSP clients.
  Every step is bounded and logged; a subtree that will not stop within its
  deadline is left to the application stop that follows.
  """
  require Logger

  alias SwarmCode.Domain.{Conversations, Engine, Workflows}
  alias SwarmCode.Domain.Tools.BackgroundProcs

  @runtime SwarmCode.Domain.Runtime
  @teardown [
    SwarmCode.Domain.Engine.RunSupervisor,
    SwarmCode.Domain.Research.Supervisor,
    SwarmCode.Domain.MCP.Supervisor,
    SwarmCode.Domain.LSP.Supervisor
  ]
  @flush_ms 10_000
  @flush_step_ms 100
  @teardown_ms 5_000

  @typedoc """
  `stopped_runs` (pass71 S4): the runs the quit stopped, oldest first, each
  `%{id, kind, title}` (`title` is the run's label, else its prompt; either
  may be nil). `stopped` is their count.
  """
  @type stopped_run :: %{id: binary(), kind: binary() | nil, title: binary() | nil}
  @type result :: %{
          paused: non_neg_integer(),
          stopped: non_neg_integer(),
          stopped_runs: [stopped_run()],
          reaped: non_neg_integer()
        }

  @doc """
  Stops everything. `opts`: `:flush_ms` (journal wait, default 10 s),
  `:teardown` (`false` keeps the supervisors, for tests), `:teardown_ms`.
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    paused = step(:pause_workflows, &pause_workflows/0, 0)
    stopped_runs = step(:stop_runs, &stop_runs/0, [])
    reaped = step(:reap_background_commands, &reap_survivors/0, 0)
    step(:wait_for_flush, fn -> wait_for_flush(Keyword.get(opts, :flush_ms, @flush_ms)) end, :ok)

    if Keyword.get(opts, :teardown, true),
      do: teardown(Keyword.get(opts, :teardown_ms, @teardown_ms))

    %{
      paused: paused,
      stopped: length(stopped_runs),
      stopped_runs: stopped_runs,
      reaped: reaped
    }
  end

  # The workflows a quit pauses: an active row with a live runner.
  defp pause_workflows do
    active =
      Workflows.list_runs(:active)
      |> Enum.filter(&(&1.run.status in ["running", "waiting_user"]))
      |> Enum.map(& &1.wf)
      |> Enum.filter(&(Workflows.Runner.whereis(&1.run_id) != nil))

    Enum.each(active, &Workflows.control(&1.run_id, :pause, []))
    length(active)
  end

  # The runs are described before they stop, while their rows say running.
  defp stop_runs do
    running = Engine.running_run_ids() |> Enum.map(&describe_run/1) |> Enum.sort_by(& &1.at)
    Engine.stop_all()
    Enum.map(running, &Map.delete(&1, :at))
  end

  defp describe_run(id) do
    case Conversations.get_run(id) do
      %{} = run ->
        %{
          id: id,
          kind: run.kind,
          title: text(run.label) || text(run.prompt),
          at: run.inserted_at && DateTime.to_unix(run.inserted_at, :microsecond)
        }

      nil ->
        %{id: id, kind: nil, title: nil, at: nil}
    end
  rescue
    _ -> %{id: id, kind: nil, title: nil, at: nil}
  end

  defp text(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp text(_), do: nil

  # Spec 67 G30: a command that yielded or was left running with `&` belongs to
  # a run that may be long over; nothing else would ever stop it.
  defp reap_survivors do
    survivors = BackgroundProcs.list_all()

    for %{run_id: run_id, os_pid: os_pid} <- survivors,
        do: BackgroundProcs.kill(run_id, os_pid)

    length(survivors)
  end

  defp wait_for_flush(left) when left <= 0, do: :ok

  defp wait_for_flush(left) do
    if Engine.running_run_ids() == [] do
      :ok
    else
      receive do
      after
        @flush_step_ms -> wait_for_flush(left - @flush_step_ms)
      end
    end
  end

  defp teardown(deadline) do
    if Process.whereis(@runtime) do
      for child <- @teardown do
        task =
          Task.Supervisor.async_nolink(SwarmCode.Domain.TaskSupervisor, fn ->
            Supervisor.terminate_child(@runtime, child)
          end)

        case Task.yield(task, deadline) || Task.shutdown(task, :brutal_kill) do
          {:ok, _} -> :ok
          _ -> Logger.warning("shutdown: #{inspect(child)} did not stop in #{deadline} ms")
        end
      end
    end

    :ok
  catch
    kind, reason -> Logger.warning("shutdown teardown: #{Exception.format(kind, reason)}")
  end

  defp step(name, fun, fallback) do
    fun.()
  rescue
    error ->
      Logger.warning("shutdown step #{name} failed: #{Exception.message(error)}")
      fallback
  catch
    kind, reason ->
      Logger.warning("shutdown step #{name} failed: #{inspect({kind, reason}, limit: 20)}")
      fallback
  end
end
