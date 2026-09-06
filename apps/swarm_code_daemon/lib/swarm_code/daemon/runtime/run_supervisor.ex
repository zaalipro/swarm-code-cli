defmodule SwarmCode.Daemon.Runtime.RunSupervisor do
  @moduledoc """
  Owns coding runs beyond the lifetime of a submitting client process.

  This internal runtime boundary does not perform durable command admission.
  The production service must commit admission before calling it. Runs are
  temporary children: a crash never implicitly repeats a tool. The service
  reconciles failed runs and retires settled children after persisting outcomes.
  """
  use DynamicSupervisor

  alias SwarmCode.Daemon.Runtime.Run

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one, max_children: 64)

  def start_run(opts), do: DynamicSupervisor.start_child(__MODULE__, {Run, opts})
end
