defmodule SwarmCode.Daemon.Boot do
  @moduledoc """
  Startup recovery for a saved session (pass70 B6): the desktop's
  `Bootstrap.run/1` at 6dd8d82, run once the guarded Repo is live and before
  the session's first snapshot.

  In order: runs left `running` by a previous runtime are marked interrupted,
  claimed scheduled occurrences are settled, default providers are seeded on an
  empty database, the legacy search key is adopted, configured MCP servers
  start, orphaned researches are closed, abandoned attachments are pruned, and
  (5 s later, supervised) stale isolation directories are swept.

  Every step is bounded (retried after 100, 250 and 500 ms) and logged; none can
  stop the session. The Scheduler and the workflow Watchdog are not started:
  the desktop owns scheduled work.
  """
  require Logger

  alias SwarmCode.Domain.{
    Attachments,
    Conversations,
    MCP,
    Projects,
    Providers,
    Research,
    Scheduled,
    Search
  }

  @retry_delays [100, 250, 500]
  @isolation_delay_ms 5_000

  @typedoc """
  `interrupted` counts the workflow runs a restart left resumable (what
  `Conversations.mark_interrupted/0` reports); `failed` names the steps that
  still failed after their retries.
  """
  @type result :: %{interrupted: non_neg_integer(), failed: [atom()]}

  @doc """
  Runs the recovery steps. `opts` are test seams: any step name below mapped to
  a zero-arity function, `:sleep` (the retry sleep) and `:isolation_cleanup`
  (`false` to skip the delayed sweep).
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)

    steps = [
      mark_interrupted: &Conversations.mark_interrupted/0,
      reconcile_scheduled: &Scheduled.reconcile_claimed/0,
      seed_defaults: &Providers.seed_defaults/0,
      adopt_legacy_search_key: &Search.adopt_legacy_key/0,
      start_mcp: &MCP.start_all/0,
      sweep_researches: &sweep_researches/0,
      prune_attachments: &Attachments.prune_abandoned/0
    ]

    results =
      for {step, default} <- steps do
        {step, retry(step, Keyword.get(opts, step, default), sleep, @retry_delays)}
      end

    if Keyword.get(opts, :isolation_cleanup, true), do: schedule_isolation_cleanup()

    failed = for {step, {:error, _}} <- results, do: step

    interrupted =
      case results[:mark_interrupted] do
        {:ok, count} when is_integer(count) -> count
        _ -> 0
      end

    %{interrupted: interrupted, failed: failed}
  end

  # Spec 24 §3.5 / 51 §4.6: deep research is not resumable; a research still
  # marked running after a restart is closed, and a designed pass the restart
  # cut short gets its rendered report back.
  @doc false
  def sweep_researches do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    for research <- Research.orphans() do
      Research.update(research, %{
        status: "failed",
        error: "interrupted by a restart",
        finished_at: now
      })
    end

    for research <- Research.list(design_state: "designing"),
        is_nil(Research.Server.whereis(research.id)) do
      Research.restore_rendered(research)
    end

    :ok
  end

  # spec 72 D6 / 73 T12: stale isolation directories after boot, supervised so
  # the session's shutdown takes it down with the runtime.
  defp schedule_isolation_cleanup do
    Task.Supervisor.start_child(SwarmCode.Domain.TaskSupervisor, fn ->
      receive do
      after
        @isolation_delay_ms -> :ok
      end

      for project <- Projects.list() do
        worktrees = Projects.Workspace.worktrees_dir(project.root_path)

        if File.dir?(worktrees),
          do:
            SwarmCode.Domain.Engine.Isolation.Ownership.cleanup_stale(
              worktrees,
              project.root_path
            )
      end
    end)
  catch
    _, _ -> :ok
  end

  defp retry(step, fun, sleep, delays) do
    case invoke(fun) do
      {:ok, value} ->
        {:ok, value}

      {:error, reason} ->
        case delays do
          [delay | rest] ->
            sleep.(delay)
            retry(step, fun, sleep, rest)

          [] ->
            Logger.warning("boot step #{step} failed: #{redact(reason)}")
            {:error, reason}
        end
    end
  end

  defp invoke(fun) do
    case fun.() do
      {:error, reason} -> {:error, reason}
      {:ok, value} -> {:ok, value}
      value -> {:ok, value}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp redact(value), do: SwarmCode.Domain.LLM.HTTP.redact(inspect(value, limit: 20))
end
