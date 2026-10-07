defmodule SwarmCode.Daemon.Boot do
  @moduledoc """
  Startup recovery for a saved session (pass70 B6): the desktop's
  `Bootstrap.run/1` and `Bootstrap.deferred/1` at 4c7c577a, run once the
  guarded Repo is live and before the session's first snapshot.

  In order: runs left `running` by a previous runtime are marked interrupted,
  claimed scheduled occurrences are settled, default providers are seeded on an
  empty database, the legacy search key is adopted, configured MCP servers
  start, orphaned researches are closed, nodes a crash left without a
  `finished_at` are repaired, abandoned attachments are pruned, and (5 s
  later, under `Engine.CleanupSupervisor`, which a quit waits for) stale
  isolation directories and delta patches are swept. The desktop runs the
  repair and the prune 3 s after its window is up (spec 74 EFFICIENCY-23); the
  CLI has no window to wait for, so they stay inline with the other steps.

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
  a zero-arity function, `:sleep` (the retry sleep), `:isolation_cleanup`
  (`false` to skip the delayed sweep), `:isolation_delay_ms` and
  `:sweep_isolation` (the sweep itself).
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
      repair_unfinished_nodes: &Conversations.repair_unfinished_nodes/0,
      prune_attachments: &prune_attachments/0
    ]

    results =
      for {step, default} <- steps do
        {step, retry(step, Keyword.get(opts, step, default), sleep, @retry_delays)}
      end

    if Keyword.get(opts, :isolation_cleanup, true) do
      schedule_isolation_cleanup(
        Keyword.get(opts, :isolation_delay_ms, @isolation_delay_ms),
        Keyword.get(opts, :sweep_isolation, &sweep_isolation/0)
      )
    end

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
  # cut short reads `rendered` again (spec 74 BUGS-60: its stale designed.html
  # is deleted; report.html never moved).
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
  # the session's shutdown takes it down with the runtime. spec 74
  # ARCHITECTURE-6: the sweep itself runs under the cleanup supervisor, which a
  # quit waits for; the settle wait before it does not, so a quick quit is not
  # held by it.
  defp schedule_isolation_cleanup(delay_ms, sweep) do
    Task.Supervisor.start_child(SwarmCode.Domain.TaskSupervisor, fn ->
      receive do
      after
        delay_ms -> :ok
      end

      Task.Supervisor.start_child(SwarmCode.Domain.Engine.CleanupSupervisor, sweep)
    end)
  catch
    _, _ -> :ok
  end

  defp sweep_isolation do
    for project <- Projects.list() do
      worktrees = Projects.Workspace.worktrees_dir(project.root_path)

      # spec 73 T12: the project root lets the sweep keep a dead worker's work.
      if File.dir?(worktrees),
        do:
          SwarmCode.Domain.Engine.Isolation.Ownership.cleanup_stale(
            worktrees,
            project.root_path
          )

      # spec 74 ARCHITECTURE-6: delta patches nothing will integrate any more.
      SwarmCode.Domain.Engine.Isolation.sweep_deltas(project.root_path)
    end
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

  # cli020 A'3 (bugs-4): an image staged for the next message is in no
  # message yet; the staging ledger (C2) names the ones to keep.
  defp prune_attachments do
    Attachments.prune_abandoned(DateTime.utc_now(), 24,
      keep: SwarmCode.Daemon.Service.CommandLedger.staged_attachment_ids()
    )
  end
end
