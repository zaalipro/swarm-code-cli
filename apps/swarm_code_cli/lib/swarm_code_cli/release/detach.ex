defmodule SwarmCodeCLI.Release.Detach do
  @moduledoc """
  pass 77 C-FEAT-3: what a closed terminal (SIGHUP) does with the runs still
  going.

  Before, a hang-up stopped every live run: closing the window threw away an
  hour of work. Now the session, with its terminal gone, keeps the runs going
  headless until none of them is progressing. A run is progressing when it is
  live, does not wait for a person (an approval or an `ask_user`) and was not
  paused by hand; a run that waits or is paused cannot move without the terminal,
  so it is left to the normal close (`stop_live_runs/0`), which stops it. A pending
  automatic-compaction chain (`{:chain, conversation, compact_run}`) is work too:
  between the compaction's end and the chat turn's registration no run is
  registered, and the chain is what starts that turn (review 1019 RC-5).

  `await/1` is event driven: it wakes on a run's status change or a change of
  the waits, and rechecks every `recheck_ms` because the run registry can lag a
  status event. It holds no state and does no I/O besides reading the
  registry, the waits and the status of each live run. Its subscriptions end
  with the wait, whatever way it ends: a registry registration links the caller
  to the registry, so a subscription left behind would take the session owner
  down with the daemon's shutdown (`:shutdown`) before the normal close and
  exit (validator 1019, C-FEAT-3).
  """

  # The daemon app is not a compile-time dependency of this one.
  @compile {:no_warn_undefined,
            [
              SwarmCode.Daemon.Service.LiveRuns,
              SwarmCode.Domain.Conversations,
              SwarmCode.Domain.Engine,
              SwarmCode.Domain.Engine.Events,
              SwarmCode.Domain.Engine.Questions,
              SwarmCode.Domain.PubSub
            ]}
  require Logger

  @recheck_ms 5_000

  # A run in one of these states cannot move without a person: paused by hand, or parked on a
  # gate question of a workflow.
  @stalled_statuses ["paused", "waiting_user"]

  @doc """
  True when some live run is neither waiting for a person nor paused, or a compaction
  chain still has to start its turn.
  """
  @spec progressing?() :: boolean()
  def progressing? do
    live = live_run_ids()
    progressing?(live, waiting_run_ids() ++ paused_run_ids(live)) or chains?()
  end

  @doc false
  @spec progressing?([String.t()], [String.t()]) :: boolean()
  def progressing?(live_ids, stalled_run_ids)
      when is_list(live_ids) and is_list(stalled_run_ids) do
    Enum.any?(live_ids, &(&1 not in stalled_run_ids))
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

    held = subscribed_topics()

    try do
      subscribe()
      Logger.info("detached: #{count.()} live runs still working")
      wait(check, recheck_ms)
    after
      release(held)
    end

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

  # The topics the caller is registered on: `release/1` ends only the ones `await/1` added, so
  # a subscription the caller held before stays.
  defp subscribed_topics do
    Registry.keys(SwarmCode.Domain.PubSub, self())
  catch
    _kind, _reason -> []
  end

  defp release(held) do
    for topic <- subscribed_topics() -- held do
      SwarmCode.Domain.PubSub.unsubscribe(SwarmCode.Domain.PubSub, topic)
    end

    :ok
  catch
    _kind, _reason -> :ok
  end

  defp live_run_ids do
    SwarmCode.Domain.Engine.running_run_ids()
  catch
    _kind, _reason -> []
  end

  # A run paused by hand stays registered (its server holds every agent) and sits in no waits
  # list; the engine's own record of it is the run row's status.
  defp paused_run_ids(live_ids) do
    Enum.filter(
      live_ids,
      &(SwarmCode.Domain.Conversations.run_status(&1) in @stalled_statuses)
    )
  catch
    _kind, _reason -> []
  end

  # A pending automatic-compaction chain: the engine registers its owner until the turn it
  # waits to start has been written, so it is work whatever the run registry shows.
  defp chains? do
    SwarmCode.Daemon.Service.LiveRuns.any_chain?()
  catch
    _kind, _reason -> false
  end

  defp waiting_run_ids do
    for %{run_id: id} <- SwarmCode.Domain.Engine.Questions.list(), is_binary(id), do: id
  catch
    _kind, _reason -> []
  end
end
