defmodule SwarmCode.Daemon.Service.RunProcesses do
  @moduledoc """
  Whether a run still has a launch of its own that no run row shows yet.

  A run's row can read `done` while the run is not over. A workflow's server
  starts its automatic continuation (a fresh chat turn that records the
  workflow as its launcher) after the row is written, and only then stops; that
  start can wait on a trusted `user_prompt_submit` hook before any row exists.
  When the conversation asked for a compaction, the start is handed on: a
  compaction run is created (it records the workflow as its launcher too) and a
  chain task, registered as `{:chain, conversation_id, compact_run_id}` with the
  workflow's id as its value, waits for it and only then writes the turn's row.
  A headless `-p` that concluded on the rows alone would close the session on a
  turn that does not exist yet.

  `pending?/1` is that fact, read from the registry: the run's server lives, or
  a chain task waits on its behalf. The registry drops an entry only after its
  process is gone, so an entry whose pid is dead counts as gone. A server stops
  right after it has started its continuation, and a chain task ends when its
  turn's row is written (or after the chain's own wait for the compaction), so
  the fact ends with the launch and needs no time limit of its own.
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

  @doc "True while a turn is chained onto a compaction on behalf of the run."
  @spec chained?(term()) :: boolean()
  def chained?(run_id) when is_binary(run_id) do
    SwarmCode.Domain.Registry
    |> Registry.select([{{{:chain, :_, :_}, :"$1", run_id}, [], [:"$1"]}])
    |> Enum.any?(&Process.alive?/1)
  rescue
    ArgumentError -> false
  end

  def chained?(_run_id), do: false

  @doc "True while the run's server lives or a turn is chained on its behalf."
  @spec pending?(term()) :: boolean()
  def pending?(run_id), do: alive?(run_id) or chained?(run_id)
end
