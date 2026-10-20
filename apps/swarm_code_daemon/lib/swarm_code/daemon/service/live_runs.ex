defmodule SwarmCode.Daemon.Service.LiveRuns do
  @moduledoc """
  The one place that reads the engine registry's run entries (pass 77
  C-ARCH-11). The engine registers `{:run, run_id}` with the value
  `{conversation_id, kind}` and, for a pending automatic-compaction chain,
  `{:chain, conversation_id, compact_run_id}`; the match-specs for both live
  here so the service does not repeat them.

  Every read is one `Registry.select/2` over this VM's registry. A registry
  that is not started (a test, a shutdown) reads as empty.
  """

  @registry SwarmCode.Domain.Registry

  @type live :: %{
          run_id: binary(),
          pid: pid(),
          conversation_id: binary(),
          kind: binary()
        }

  @doc "Every running run (all conversations)."
  @spec all() :: [live()]
  def all do
    select([{{{:run, :"$1"}, :"$2", {:"$3", :"$4"}}, [], [{{:"$1", :"$2", :"$3", :"$4"}}]}])
    |> Enum.map(fn {run_id, pid, conversation_id, kind} ->
      %{run_id: run_id, pid: pid, conversation_id: conversation_id, kind: kind}
    end)
  end

  @doc "The running runs of `conversation_id` whose kind is in `kinds`, as `{run_id, pid}`."
  @spec of_conversation(binary(), [binary()]) :: [{binary(), pid()}]
  def of_conversation(conversation_id, kinds) do
    select([
      {{{:run, :"$1"}, :"$2", {:"$3", :"$4"}}, [{:==, :"$3", conversation_id}],
       [{{:"$1", :"$2", :"$4"}}]}
    ])
    |> Enum.filter(fn {_id, _pid, kind} -> kind in kinds end)
    |> Enum.map(fn {id, pid, _kind} -> {id, pid} end)
  end

  @doc "The conversations that have a running run (with repeats, one per run)."
  @spec conversation_ids() :: [binary()]
  def conversation_ids, do: select([{{{:run, :_}, :_, {:"$1", :_}}, [], [:"$1"]}])

  @doc "The pending compaction chains of `conversation_id`, as `{compact_run_id, owner_pid}`."
  @spec chains(binary()) :: [{binary(), pid()}]
  def chains(conversation_id) do
    select([{{{:chain, conversation_id, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end

  defp select(spec) do
    Registry.select(@registry, spec)
  rescue
    ArgumentError -> []
  end
end
