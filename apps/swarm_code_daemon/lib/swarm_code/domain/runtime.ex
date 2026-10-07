defmodule SwarmCode.Domain.Runtime do
  @moduledoc """
  The synced domain's process tree (desktop `application.ex` at 4c7c577a, minus
  the web, window, Repo, Bootstrap, Scheduler and Watchdog: the desktop owns
  schedules). Storage is not here: the guarded Repo belongs to
  `Daemon.RepoLauncher`. The children keep the desktop's order.
  """
  use Supervisor
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: SwarmCode.Domain.Registry},
      {Task.Supervisor, name: SwarmCode.Domain.TaskSupervisor},
      # Spec 74 EFFICIENCY-2: the janitors that drain what a command left
      # running (they linger 5 min after it exits) have their own owner, so
      # nothing that waits on `TaskSupervisor`'s work waits on them.
      {Task.Supervisor, name: SwarmCode.Domain.Tools.BackgroundProcs.Supervisor},
      # pass74 (spec 74) BUGS-50: the LLM connection pool (256 per origin).
      SwarmCode.Domain.LLM.HTTP.finch_child_spec(),
      SwarmCode.Domain.PubSub,
      SwarmCode.Domain.MarkdownCache,
      SwarmCode.Domain.UIState,
      # Before any run supervisor: an agent operation must never be the one
      # that creates the provider capability table.
      SwarmCode.Domain.LLM.ProviderCaps,
      SwarmCode.Domain.Cache,
      # Spec 75: the speed monitor's table — before any run can stream.
      SwarmCode.Domain.LLM.Speed,
      # spec 74 BUGS-76: the attached-research blocks the agents expand.
      SwarmCode.Domain.Engine.ResearchContext,
      SwarmCode.Domain.Engine.Questions,
      # spec 67 G30: the book of what a run left running, before any run can
      # leave something running.
      SwarmCode.Domain.Tools.BackgroundProcs,
      # spec 74 ARCHITECTURE-6: the run-end and boot isolation cleanups.
      # Before the runs, so it stops after them and outlives their finish;
      # `Daemon.Shutdown.run/1` waits for its children (bounded).
      {Task.Supervisor, name: SwarmCode.Domain.Engine.CleanupSupervisor},
      # spec 70 F1: the supervised home of fire-and-forget tool hooks; every
      # tool call's post-hook starts a task here.
      {Task.Supervisor, name: SwarmCode.Domain.Hooks.TaskSupervisor},
      SwarmCode.Domain.Research.Supervisor,
      SwarmCode.Domain.MCP.Supervisor,
      # spec 70 B3: one LSP client per {project, language}, started lazily.
      SwarmCode.Domain.LSP.Supervisor,
      # spec 74 ARCHITECTURE-13: after everything a run calls (hooks, MCP and
      # LSP clients, the cleanup supervisor, the background-process book),
      # because a supervisor stops its children in reverse start order: on a
      # VM stop or a max-restart shutdown the runs go first and never call a
      # client that is already gone — the order `Daemon.Shutdown` keeps.
      SwarmCode.Domain.Engine.RunSupervisor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
