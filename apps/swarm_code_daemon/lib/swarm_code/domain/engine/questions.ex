defmodule SwarmCode.Domain.Engine.Questions do
  @moduledoc """
  Which conversations are waiting for an answer to an `ask_user` call
  (spec 10 §1). A tiny public ETS table so the sidebar can draw its amber dot
  without calling every RunServer.
  """
  use GenServer

  @table __MODULE__
  @approval_timeout_ms 600_000
  @question_timeout_ms 1_800_000

  def deadline_ms(:approval), do: @approval_timeout_ms
  def deadline_ms(:question), do: @question_timeout_ms

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @doc "Remembers that `node_id` of `run_id` is waiting for the user."
  @spec put(String.t(), String.t(), String.t(), :question | :approval) :: :ok
  def put(conversation_id, run_id, node_id, kind \\ :question) do
    change(fn ->
      :ets.insert(@table, {{run_id, node_id}, conversation_id, kind, DateTime.utc_now()})
    end)
  end

  @doc "Forgets one pending question."
  @spec delete(String.t(), String.t()) :: :ok
  def delete(run_id, node_id),
    do:
      change(fn ->
        :ets.select_delete(@table, [{{{run_id, node_id}, :_, :_, :_}, [], [true]}])
      end)

  @doc "Forgets every pending question of a run."
  @spec delete_run(String.t()) :: :ok
  def delete_run(run_id),
    do: change(fn -> :ets.select_delete(@table, [{{{run_id, :_}, :_, :_, :_}, [], [true]}]) end)

  @doc "Whether `node_id` of `run_id` is still waiting for the user (spec 55 T1)."
  @spec pending?(String.t(), String.t()) :: boolean()
  def pending?(run_id, node_id) do
    :ets.member(@table, {run_id, node_id})
  rescue
    ArgumentError -> false
  end

  @doc "The ids of the conversations that are waiting for an answer."
  @spec waiting() :: MapSet.t()
  def waiting do
    MapSet.new(:ets.select(@table, [{{:_, :"$1", :_, :_}, [], [:"$1"]}]))
  rescue
    _ -> MapSet.new()
  catch
    _, _ -> MapSet.new()
  end

  @doc "All pending questions and approvals, oldest first."
  @spec list() :: [map()]
  def list do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {{run_id, node_id}, conversation_id, kind, since} ->
      %{
        conversation_id: conversation_id,
        run_id: run_id,
        node_id: node_id,
        kind: kind,
        since: since
      }
    end)
    |> Enum.sort_by(& &1.since, DateTime)
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @doc "Pending questions and approvals for one conversation, oldest first."
  @spec list(String.t()) :: [map()]
  def list(conversation_id) do
    Enum.filter(list(), &(&1.conversation_id == conversation_id))
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  # Spec 54 §1.4 (54a A4): `fun` returns how many rows went, and the broadcast
  # only happens when that is not zero. `RunServer.terminate/2` calls
  # `delete_run/1` for *every* run, and every one of those made every open
  # window re-run `waiting_runs/1` (a `tab2list` + sort + two `Map.new`s) and
  # reload its sidebar — 1 414 events in 54a's fast scenario, one per finished
  # run, almost none of them deleting anything.
  defp change(fun) do
    safe(fn ->
      case fun.() do
        0 -> :ok
        _deleted -> SwarmCode.Domain.Engine.Events.ui_broadcast({:waiting_changed})
      end
    end)
  end

  defp safe(fun) do
    fun.()
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end
end
