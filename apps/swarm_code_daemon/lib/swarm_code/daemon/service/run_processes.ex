defmodule SwarmCode.Daemon.Service.RunProcesses do
  @moduledoc """
  Whether a run's own process is still there.

  A run's row can read `done` while its `RunServer` is still finishing: a
  workflow's server starts its automatic continuation (a fresh chat turn that
  records the workflow as its launcher) after the row is written, and only then
  stops. A headless `-p` that concluded on the row alone would close the
  session before that turn existed. The registry drops a run's entry only
  after its process is gone, so an entry whose pid is dead counts as gone.
  """

  @doc "True while the run's server process lives."
  @spec alive?(term()) :: boolean()
  def alive?(run_id) when is_binary(run_id) do
    SwarmCode.Domain.Registry
    |> Registry.lookup({:run, run_id})
    |> Enum.any?(fn {pid, _value} -> Process.alive?(pid) end)
  rescue
    ArgumentError -> false
  end

  def alive?(_run_id), do: false
end
