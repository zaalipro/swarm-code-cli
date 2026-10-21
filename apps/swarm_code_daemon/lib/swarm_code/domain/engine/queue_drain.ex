defmodule SwarmCode.Domain.Engine.QueueDrain do
  @moduledoc """
  pass 77 D-BUG-2 / D-VER-2: the one owner of "start the next queued message".

  A chat run's end (`RunServer.finish_run/4`) or a window opening an idle conversation asks
  for a drain; the drain holds `{:queue_drain, conversation_id}` in `SwarmCode.Domain.Registry`
  for the whole check -> pop -> launch, so two windows (or a window and the engine) never
  start two queued messages at once. Plain text starts here, with no window needed; a
  queued `/command` is web-dispatched, so it is offered once to an open window of the
  conversation and put back at the head when nobody takes it.

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

  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:swarm_code_daemon, :engine_queue_drain, false) == true

  defp offer_ms, do: Application.get_env(:swarm_code_daemon, :queue_offer_ms, 10_000)

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
    if enabled?() do
      Task.Supervisor.start_child(SwarmCode.Domain.TaskSupervisor, fn ->
        drain(conversation_id, finished_run_id)
      end)
    end

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

  @doc "The window that took an offer has dispatched the command."
  @spec dispatched(pid(), reference()) :: :ok
  def dispatched(drain_pid, ref) do
    send(drain_pid, {:queue_dispatched, ref})
    :ok
  end

  defp drain(conversation_id, finished_run_id) do
    case Registry.register(SwarmCode.Domain.Registry, {:queue_drain, conversation_id}, nil) do
      {:ok, _owner} -> do_drain(conversation_id, finished_run_id)
      # The holder covers it: it checks the same conversation under the same claim.
      {:error, {:already_registered, _pid}} -> :busy
    end
  rescue
    # A test's sandbox owner is gone; nothing to drain for it.
    DBConnection.OwnershipError -> :busy
    error -> Logger.error("swarm_code: the queue drain failed: " <> Exception.message(error))
  end

  defp do_drain(conversation_id, finished_run_id) do
    cond do
      # That chat's own finish drains next; the finished run is excluded because it may
      # still be registered when its finish asks.
      Engine.chat_run_ids(conversation_id) -- List.wrap(finished_run_id) != [] ->
        :busy

      pid = chain_pid(conversation_id) ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, _, _} -> do_drain(conversation_id, nil)
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

  # Nothing was started, so the popped message goes back in front. A requeue that fails too
  # leaves the text in a notice, so it is never silently lost.
  defp requeue(conversation, text, notice) do
    case Conversations.requeue_head(conversation.id, text) do
      {:ok, _updated} ->
        if notice, do: Events.broadcast(conversation.id, {:queue_notice, conversation.id, notice})

      error ->
        Logger.error("swarm_code: a queued message could not be put back: #{inspect(error)}")

        Events.broadcast(
          conversation.id,
          {:queue_notice, conversation.id, "Could not put the queued message back: " <> text}
        )
    end

    :requeued
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
        await_dispatch(conversation, command, ref, Process.monitor(taker))
    after
      offer_ms() -> requeue(conversation, command, nil)
    end
  end

  defp await_dispatch(conversation, command, ref, monitor) do
    receive do
      {:queue_dispatched, ^ref} ->
        Process.demonitor(monitor, [:flush])
        :dispatched

      {:DOWN, ^monitor, :process, _, _} ->
        requeue(conversation, command, nil)

      {:queue_take, ^ref, other, reply} ->
        send(other, {reply, :taken})
        await_dispatch(conversation, command, ref, monitor)
    after
      3 * offer_ms() ->
        # The window owns it now.
        Process.demonitor(monitor, [:flush])
        :dispatched
    end
  end
end
