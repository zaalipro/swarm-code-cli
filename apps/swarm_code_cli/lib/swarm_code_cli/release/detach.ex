defmodule SwarmCodeCLI.Release.Detach do
  @moduledoc """
  pass 77 C-FEAT-3: what a closed terminal (SIGHUP) does with the runs still
  going.

  Before, a hang-up stopped every live run: closing the window threw away an
  hour of work. Now the session, with its terminal gone, keeps the runs going
  headless until none of them is progressing. A run is progressing when it is
  live and does not wait for a person (an approval or an `ask_user`); a run
  that waits cannot move without the terminal, so it is left to the normal
  close (`stop_live_runs/0`), which stops it.

  `await/1` is event driven: it wakes on a run's status change or a change of
  the waits, and rechecks every `recheck_ms` because the run registry can lag a
  status event. It holds no state and does no I/O besides reading the
  registry and the waits.
  """

  # The daemon app is not a compile-time dependency of this one.
  @compile {:no_warn_undefined,
            [
              SwarmCode.Domain.Conversations,
              SwarmCode.Domain.Engine,
              SwarmCode.Domain.Engine.Events,
              SwarmCode.Domain.Engine.Questions
            ]}
  require Logger

  @recheck_ms 5_000

  @doc "True when some live run is not waiting for a person."
  @spec progressing?() :: boolean()
  def progressing? do
    progressing?(live_run_ids(), waiting_run_ids())
  end

  @doc false
  @spec progressing?([String.t()], [String.t()]) :: boolean()
  def progressing?(live_ids, wait_run_ids) when is_list(live_ids) and is_list(wait_run_ids) do
    Enum.any?(live_ids, &(&1 not in wait_run_ids))
  end

  @doc """
  Blocks until no run is progressing. Options (tests): `:progressing?`, a
  zero-arity function; `:count`, a zero-arity function for the log line;
  `:recheck_ms`.
  """
  @spec await(keyword()) :: :settled
  def await(opts \\ []) do
    check = Keyword.get(opts, :progressing?, &progressing?/0)
    count = Keyword.get(opts, :count, fn -> length(live_run_ids()) end)
    recheck_ms = Keyword.get(opts, :recheck_ms, @recheck_ms)

    subscribe()
    Logger.info("detached: #{count.()} live runs still working")
    wait(check, recheck_ms)
    Logger.info("detached: settled")
    :settled
  end

  defp wait(check, recheck_ms) do
    if check.() do
      receive do
        {:run_lifecycle, _conversation_id, _status} -> :ok
        {:waiting_changed} -> :ok
      after
        recheck_ms -> :ok
      end

      wait(check, recheck_ms)
    else
      :ok
    end
  end

  # A session without the domain's PubSub (a test) still rechecks on the timer.
  defp subscribe do
    SwarmCode.Domain.Conversations.subscribe_run_lifecycle()
    SwarmCode.Domain.Engine.Events.ui_subscribe()
    :ok
  catch
    _kind, _reason -> :ok
  end

  defp live_run_ids do
    SwarmCode.Domain.Engine.running_run_ids()
  catch
    _kind, _reason -> []
  end

  defp waiting_run_ids do
    for %{run_id: id} <- SwarmCode.Domain.Engine.Questions.list(), is_binary(id), do: id
  catch
    _kind, _reason -> []
  end
end
