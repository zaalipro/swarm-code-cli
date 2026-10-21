defmodule SwarmCode.Domain.Engine.QueueDrain do
  @moduledoc """
  pass 77 D-BUG-2 / D-VER-2: the one owner of "start the next queued message".

  A chat run's end (`RunServer.finish_run/4`) or a window opening an idle conversation asks
  for a drain; the drain holds `{:queue_drain, conversation_id}` in `SwarmCode.Domain.Registry`
  for the whole check -> pop -> launch, so two windows (or a window and the engine) never
  start two queued messages at once. Plain text starts here, with no window needed; a
  queued `/command` is web-dispatched, so it is offered once to an open window of the
  conversation and put back at the head when nobody takes it.

  RD-9: a request that finds the claim held does not vanish. It leaves a `:queue_recheck` with
  the holder and checks the claim is still the holder's; the holder releases the claim and then
  reads its mailbox once more, so a finish that arrives while a drain is launching the previous
  turn is looked at again (a run that ends before `start_chat_turn` has returned to its own
  drain no longer strands the next queued message).

  RD-3: `with_hold/2` (the `stop_all` paths) keeps new drains from starting while runs are being
  stopped, tells an active drain to stop and waits for it. The queue is left as it is: nothing a
  stop causes launches the next queued message.

  RD-4: a window that took a `/command` answers `dispatched/2` (started or settled),
  `deferred/2` (parked until a command listing or an MCP prompt lands: the claim is kept until
  its `dispatched/2`, or the window goes away and the command returns to the head) or
  `rejected/2` (no room right now: the command returns to the head).

  RD-5: a popped message whose launch failed is put back by the drain itself, retrying while the
  database is busy; when that never works the text is written to a recovery file.

  Inert unless `config :swarm_code_daemon, :engine_queue_drain, true` (the CLI copies this file).
  """

  require Logger

  alias SwarmCode.Domain.{Conversations, Engine}
  alias SwarmCode.Domain.Engine.Events

  # A compaction chain is bounded by its own wait (`@auto_compact_wait_ms`); this only keeps a
  # drain from holding its claim for ever if the chain never ends.
  @chain_wait_ms 120_000
  # A window that took an offer answers `take/2` at once; this only bounds a wedged drain.
  @take_timeout_ms 5_000
  # RD-3: how long `with_hold/2` waits for an active drain to end.
  @settle_ms 3_000
  # RD-9: tries to hand a request to the claim holder / take the claim when it is released.
  @claim_attempts 5

  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:swarm_code_daemon, :engine_queue_drain, false) == true

  defp offer_ms, do: Application.get_env(:swarm_code_daemon, :queue_offer_ms, 10_000)
  # RD-4: how long a drain keeps its claim for a command a window parked (the window answers
  # `dispatched/2` as soon as the command starts; a window that is gone returns the command).
  defp defer_wait_ms, do: Application.get_env(:swarm_code_daemon, :queue_defer_wait_ms, 60_000)
  # RD-5
  defp requeue_rounds, do: Application.get_env(:swarm_code_daemon, :queue_requeue_rounds, 20)

  defp requeue_retry_ms,
    do: Application.get_env(:swarm_code_daemon, :queue_requeue_retry_ms, 1_000)

  @doc "A chat run of the conversation ended: start the next queued message, if any."
  @spec after_finish(String.t(), String.t()) :: :ok
  def after_finish(conversation_id, finished_run_id),
    do: request(conversation_id, finished_run_id)

  @doc """
  Asks for a drain: `after_finish/2` and a window opening a conversation both call it. The
  work runs in a `SwarmCode.Domain.TaskSupervisor` child, never in the caller.
  """
  @spec request(String.t(), String.t() | nil) :: :ok
  def request(conversation_id, finished_run_id \\ nil) when is_binary(conversation_id) do
    # RD-3: while a stop of this conversation (or of everything) is under way, a finish it
    # caused does not start the next queued message.
    if enabled?() and not held?(conversation_id) do
      Task.Supervisor.start_child(SwarmCode.Domain.TaskSupervisor, fn ->
        drain(conversation_id, List.wrap(finished_run_id))
      end)
    end

    :ok
  end

  @doc "True while `with_hold/2` is stopping this conversation (or everything)."
  @spec held?(String.t()) :: boolean()
  def held?(conversation_id) do
    Registry.select(SwarmCode.Domain.Registry, [
      {{{:queue_hold, conversation_id, :_}, :_, :_}, [], [true]},
      {{{:queue_hold, :all, :_}, :_, :_}, [], [true]}
    ]) != []
  end

  @doc """
  RD-3: runs `fun` (the stop of `scope`, a conversation id or `:all`) with the queue held: no
  drain starts or pops for the scope, an active drain is told to stop and waited for (bounded),
  and the queue is untouched. The hold belongs to the calling process, is its own registration
  (concurrent and nested holds do not release each other) and always ends with this call.
  """
  @spec with_hold(String.t() | :all, (-> result)) :: result when result: term()
  def with_hold(scope, fun) when is_function(fun, 0) do
    key = {:queue_hold, scope, make_ref()}
    {:ok, _owner} = Registry.register(SwarmCode.Domain.Registry, key, nil)

    try do
      settle(scope)
      fun.()
    after
      Registry.unregister(SwarmCode.Domain.Registry, key)
    end
  end

  # Tells every active drain of the scope to stop and waits for it to end.
  defp settle(scope) do
    spec =
      case scope do
        :all -> [{{{:queue_drain, :_}, :"$1", :_}, [], [:"$1"]}]
        id -> [{{{:queue_drain, id}, :"$1", :_}, [], [:"$1"]}]
      end

    monitors =
      for pid <- Registry.select(SwarmCode.Domain.Registry, spec), pid != self() do
        monitor = Process.monitor(pid)
        send(pid, :queue_abort)
        {pid, monitor}
      end

    deadline = System.monotonic_time(:millisecond) + @settle_ms

    Enum.each(monitors, fn {pid, monitor} ->
      remaining = max(deadline - System.monotonic_time(:millisecond), 0)

      receive do
        {:DOWN, ^monitor, :process, ^pid, _reason} -> :ok
      after
        remaining -> Process.demonitor(monitor, [:flush])
      end
    end)

    :ok
  end

  @doc "The pid of a pending compaction chain of the conversation, or nil."
  @spec chain_pid(String.t()) :: pid() | nil
  def chain_pid(conversation_id) do
    case Registry.select(SwarmCode.Domain.Registry, [
           {{{:chain, conversation_id, :_}, :"$1", :_}, [], [:"$1"]}
         ]) do
      [pid | _] -> pid
      [] -> nil
    end
  end

  @doc """
  A window that got a `{:queue_offer, conversation_id, drain_pid, ref, command}`: exactly one
  caller gets `{:ok, command}`, every other one `:taken`.
  """
  @spec take(pid(), reference()) :: {:ok, String.t()} | :taken
  def take(drain_pid, ref) do
    mref = Process.monitor(drain_pid)
    reply = make_ref()
    send(drain_pid, {:queue_take, ref, self(), reply})

    receive do
      {^reply, answer} ->
        Process.demonitor(mref, [:flush])
        answer

      {:DOWN, ^mref, :process, _, _} ->
        :taken
    after
      @take_timeout_ms ->
        Process.demonitor(mref, [:flush])
        :taken
    end
  end

  @doc "The window that took an offer has started (or finally settled) the command."
  @spec dispatched(pid(), reference()) :: :ok
  def dispatched(drain_pid, ref) do
    send(drain_pid, {:queue_dispatched, ref})
    :ok
  end

  @doc """
  RD-4: the window parked the command (a command listing or an MCP prompt is still loading). The
  drain keeps its claim until `dispatched/2` with the same ref, or until the window is gone.
  """
  @spec deferred(pid(), reference()) :: :ok
  def deferred(drain_pid, ref) do
    send(drain_pid, {:queue_deferred, ref})
    :ok
  end

  @doc "RD-4: the window had no room for the command; the drain puts it back at the head."
  @spec rejected(pid(), reference()) :: :ok
  def rejected(drain_pid, ref) do
    send(drain_pid, {:queue_rejected, ref})
    :ok
  end

  defp drain(conversation_id, finished, attempts \\ @claim_attempts) do
    case Registry.register(SwarmCode.Domain.Registry, {:queue_drain, conversation_id}, nil) do
      {:ok, _owner} ->
        own(conversation_id, finished)

      {:error, {:already_registered, holder}} ->
        coalesce(conversation_id, finished, holder, attempts)
    end
  rescue
    # A test's sandbox owner is gone; nothing to drain for it.
    DBConnection.OwnershipError -> :busy
    error -> Logger.error("swarm_code: the queue drain failed: " <> Exception.message(error))
  end

  # RD-9: the holder re-checks after this request; if it released the claim in the meantime,
  # the claim is taken here instead (the message stays in the old holder's mailbox, harmless).
  defp coalesce(conversation_id, finished, holder, attempts) do
    send(holder, {:queue_recheck, finished})

    case Registry.lookup(SwarmCode.Domain.Registry, {:queue_drain, conversation_id}) do
      [{^holder, _}] -> :coalesced
      _released when attempts > 1 -> drain(conversation_id, finished, attempts - 1)
      _released -> :busy
    end
  end

  # One check -> pop -> launch under the claim, then the claim is released and the mailbox read
  # once more: a request that was handed to this holder before the release is not lost.
  defp own(conversation_id, finished) do
    result = do_drain(conversation_id, finished)
    Registry.unregister(SwarmCode.Domain.Registry, {:queue_drain, conversation_id})

    case take_rechecks(:none) do
      :none -> result
      {:some, finished} -> drain(conversation_id, finished)
    end
  end

  # `:none`, or `{:some, finished_run_ids}` of every recheck in the mailbox (a recheck from a
  # request without a finished run still counts).
  defp take_rechecks(acc) do
    receive do
      {:queue_recheck, ids} ->
        take_rechecks({:some, ids ++ if(acc == :none, do: [], else: elem(acc, 1))})
    after
      0 -> acc
    end
  end

  defp do_drain(conversation_id, finished) do
    cond do
      held?(conversation_id) ->
        :held

      # That chat's own finish drains next; the finished run is excluded because it may
      # still be registered when its finish asks.
      Engine.chat_run_ids(conversation_id) -- finished != [] ->
        :busy

      pid = chain_pid(conversation_id) ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, _, _} -> do_drain(conversation_id, [])
          :queue_abort -> Process.demonitor(ref, [:flush]) && :held
        after
          @chain_wait_ms ->
            Process.demonitor(ref, [:flush])
            :busy
        end

      not Conversations.queued?(conversation_id) ->
        :empty

      true ->
        pop(conversation_id)
    end
  end

  defp pop(conversation_id) do
    case Conversations.pop_queued(conversation_id) do
      {:ok, "/" <> _ = command, conversation} -> offer(conversation, command)
      {:ok, text, conversation} -> start_text(conversation, text)
      :empty -> :empty
      {:error, :database_busy} -> :busy
    end
  end

  defp start_text(conversation, text) do
    result =
      try do
        Engine.start_chat_turn(conversation, text)
      rescue
        error -> {:error, Exception.message(error)}
      end

    case result do
      {:ok, _run_id} ->
        Events.broadcast(conversation.id, {:queue_started, conversation.id})
        seam(:launched)
        :started

      {:error, :not_configured} ->
        requeue(conversation, text, "No model configured — add a provider in Settings")

      {:error, reason} ->
        requeue(
          conversation,
          text,
          "The queued message could not start: " <>
            SwarmCode.Domain.LLM.HTTP.redact(inspect(reason))
        )
    end
  end

  # The test seam (like `Repo`'s `:busy_write_seam`): an arity-1 function called with the stage.
  defp seam(stage) do
    case Application.get_env(:swarm_code_daemon, :queue_drain_seam) do
      fun when is_function(fun, 1) -> fun.(stage)
      _none -> :ok
    end
  end

  # Nothing was started, so the popped message goes back in front. RD-5: this process keeps the
  # text until the put-back commits: it retries while the database is busy, and when that never
  # works the text is written to a recovery file (and logged), not left to a broadcast.
  defp requeue(conversation, text, notice) do
    case requeue_owned(conversation.id, text, requeue_rounds()) do
      :ok ->
        if notice, do: Events.broadcast(conversation.id, {:queue_notice, conversation.id, notice})

      :gone ->
        Logger.warning("swarm_code: a queued message was dropped, its conversation is gone")

      {:lost, error} ->
        path = save_recovery(conversation.id, text)
        Logger.error("swarm_code: a queued message could not be put back: #{inspect(error)}")

        Events.broadcast(
          conversation.id,
          {:queue_notice, conversation.id,
           "Could not put the queued message back: " <>
             text <>
             if(path, do: " (saved to #{path})", else: "")}
        )
    end

    :requeued
  end

  defp requeue_owned(conversation_id, text, rounds) do
    case Conversations.requeue_head(conversation_id, text) do
      {:ok, _updated} ->
        :ok

      {:error, :not_found} ->
        :gone

      {:error, :database_busy} when rounds > 1 ->
        Process.sleep(requeue_retry_ms())
        requeue_owned(conversation_id, text, rounds - 1)

      error ->
        {:lost, error}
    end
  end

  # An inspectable record of a message that is in neither the queue nor a run: one 0600 file in
  # the data folder, written beside its final name and renamed into place. nil when it cannot.
  defp save_recovery(conversation_id, text) do
    dir = Path.join(SwarmCode.Domain.Projects.Workspace.global_dir(), "queue-recovery")

    name =
      "#{conversation_id}-#{System.system_time(:millisecond)}-#{System.unique_integer([:positive])}.txt"

    path = Path.join(dir, name)
    tmp = path <> ".tmp"

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, text, [:exclusive]),
         :ok <- File.chmod(tmp, 0o600),
         :ok <- File.rename(tmp, path) do
      path
    else
      _error ->
        File.rm(tmp)
        nil
    end
  end

  # A `/command` is dispatched by the web layer (a card action). One open window of the
  # conversation takes the offer; with none the command goes back to the head, so the next
  # window that opens the conversation gets it.
  defp offer(conversation, command) do
    ref = make_ref()
    Events.broadcast(conversation.id, {:queue_offer, conversation.id, self(), ref, command})

    receive do
      {:queue_take, ^ref, taker, reply} ->
        send(taker, {reply, {:ok, command}})
        await_dispatch(conversation, command, ref, Process.monitor(taker), 3 * offer_ms())

      :queue_abort ->
        requeue(conversation, command, nil)
    after
      offer_ms() -> requeue(conversation, command, nil)
    end
  end

  # The window that took the command answers with how it went: `dispatched` (started, or
  # settled with its own notice), `deferred` (parked: wait for its `dispatched`), `rejected`
  # (no room: back to the head). A window that goes away before `dispatched` returns the
  # command. RD-3: an abort ends the wait; the window owns the command from here.
  defp await_dispatch(conversation, command, ref, monitor, wait_ms) do
    receive do
      {:queue_dispatched, ^ref} ->
        Process.demonitor(monitor, [:flush])
        :dispatched

      {:queue_deferred, ^ref} ->
        await_dispatch(conversation, command, ref, monitor, defer_wait_ms())

      {:queue_rejected, ^ref} ->
        Process.demonitor(monitor, [:flush])
        requeue(conversation, command, nil)

      {:DOWN, ^monitor, :process, _, _} ->
        requeue(conversation, command, nil)

      {:queue_take, ^ref, other, reply} ->
        send(other, {reply, :taken})
        await_dispatch(conversation, command, ref, monitor, wait_ms)

      :queue_abort ->
        Process.demonitor(monitor, [:flush])
        :aborted
    after
      wait_ms ->
        # The window owns it now.
        Process.demonitor(monitor, [:flush])
        :dispatched
    end
  end
end
