defmodule SwarmCode.Domain.Runtime do
  @moduledoc """
  The synced domain's process tree (desktop `application.ex` at 6dd8d82, minus
  the web, window, Scheduler and Watchdog: the desktop owns schedules).
  Storage is not here: the guarded Repo belongs to `Daemon.RepoLauncher`.
  """
  use Supervisor
  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: SwarmCode.Domain.Registry},
      {Task.Supervisor, name: SwarmCode.Domain.TaskSupervisor},
      SwarmCode.Domain.PubSub,
      SwarmCode.Domain.MarkdownCache,
      SwarmCode.Domain.UIState,
      SwarmCode.Domain.Cache,
      SwarmCode.Domain.LLM.ProviderCaps,
      SwarmCode.Domain.Engine.Questions,
      # spec 67 G30: the book of what a run left running, before any run can
      # leave something running.
      SwarmCode.Domain.Tools.BackgroundProcs,
      SwarmCode.Domain.Engine.RunSupervisor,
      # spec 70 F1: the supervised home of fire-and-forget tool hooks; every
      # tool call's post-hook starts a task here.
      {Task.Supervisor, name: SwarmCode.Domain.Hooks.TaskSupervisor},
      SwarmCode.Domain.Research.Supervisor,
      SwarmCode.Domain.MCP.Supervisor,
      # spec 70 B3: one LSP client per {project, language}, started lazily.
      SwarmCode.Domain.LSP.Supervisor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
