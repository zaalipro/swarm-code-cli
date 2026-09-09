defmodule SwarmCode.Domain.MarkdownCache do
  @moduledoc "Byte-bounded LRU memo for exact Markdown renders."
  use GenServer
  import Ecto.Query, only: [from: 2]

  alias SwarmCode.Domain.Conversations.{Message, Node, Run}
  alias SwarmCode.Domain.Repo

  @table __MODULE__
  @lru Module.concat(__MODULE__, LRU)
  @meta Module.concat(__MODULE__, Meta)
  # Spec 51 §3.8: 16 MB / 2 000 entries (was 64 MB / 4 000) — a miss is a
  # 25 ms re-render, the resident set is what the desktop app pays for.
  @max_entries 2_000
  @max_bytes 16_777_216
  @max_entry_bytes 4_194_304
  # Spec 51 §3.8: the op-keyed renders (`chat.ex` caches a plan, a spec, a
  # report and a disposition under `{op_id, kind}`), evicted with their
  # conversation like the message renders.
  @op_kinds [:spec, :report, :plan, :disp]
  @op_types ~w(submit_plan write_spec)

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@lru, [:named_table, :public, :ordered_set])
    :ets.new(@meta, [:named_table, :public, :set])
    :ets.insert(@meta, [{:seq, 0}, {:bytes, 0}])
    {:ok, %{}}
  end

  # Spec 43 §2.3: a hit is an ETS read in the caller — the table is public and
  # built for concurrent reads, yet every message of every render went through
  # the server's mailbox (and copied the HTML twice). The LRU bump is a cast,
  # and only once the entry has aged past `@touch_every` newer insertions: a
  # message rendered on every flush touched the LRU eight times a second.
  @touch_every 64

  def get(id, hash) do
    case :ets.lookup(@table, id) do
      [{^id, ^hash, html, _bytes, seq}] ->
        if meta(:seq) - seq > @touch_every, do: GenServer.cast(__MODULE__, {:touch, id, seq})
        html

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  def put(id, hash, html),
    do: safe(:ok, fn -> GenServer.call(__MODULE__, {:put, id, hash, html}) end)

  def clear, do: safe(:ok, fn -> GenServer.call(__MODULE__, :clear) end)
  def size, do: stats().entries
  def stats, do: safe(%{bytes: 0, entries: 0}, fn -> GenServer.call(__MODULE__, :stats) end)

  @doc "Evicts every cached render owned by one conversation."
  def delete_conversation(conversation_id) when is_binary(conversation_id) do
    safe(:ok, fn ->
      ids =
        Repo.all(
          from(m in Message,
            where: m.conversation_id == ^conversation_id,
            select: m.id
          )
        )

      op_ids =
        Repo.all(
          from(n in Node,
            join: r in Run,
            on: r.id == n.run_id,
            where: r.conversation_id == ^conversation_id and n.op_type in ^@op_types,
            select: n.id
          )
        )

      GenServer.call(__MODULE__, {:delete_messages, ids, op_ids})
    end)
  end

  def delete_conversation(_conversation_id), do: :ok

  @impl true
  def handle_cast({:touch, id, old_seq}, state) do
    case :ets.lookup(@table, id) do
      # Still the same entry (a `put` in between gave it a newer seq).
      [{^id, hash, html, bytes, ^old_seq}] ->
        seq = next_seq()
        :ets.delete(@lru, old_seq)
        :ets.insert(@lru, {seq, id})
        :ets.insert(@table, {id, hash, html, bytes, seq})

      _ ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:get, id, hash}, _from, state) do
    {:reply, get(id, hash), state}
  end

  def handle_call({:put, id, hash, html}, _from, state) do
    bytes = IO.iodata_length(html)
    # An oversized replacement is deliberately not cached, but it must still
    # invalidate the smaller stale value previously stored under this id.
    delete_id(id)

    if bytes <= @max_entry_bytes do
      seq = next_seq()
      :ets.insert(@table, {id, hash, html, bytes, seq})
      :ets.insert(@lru, {seq, id})
      add_bytes(bytes)
      evict()
    end

    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, state) do
    :ets.delete_all_objects(@table)
    :ets.delete_all_objects(@lru)
    :ets.insert(@meta, [{:seq, 0}, {:bytes, 0}])
    {:reply, :ok, state}
  end

  def handle_call({:delete_messages, ids}, from, state),
    do: handle_call({:delete_messages, ids, []}, from, state)

  def handle_call({:delete_messages, ids, op_ids}, _from, state) do
    Enum.each(ids, fn id ->
      delete_id(id)
      delete_id({id, :stable})
    end)

    for id <- op_ids, kind <- @op_kinds, do: delete_id({id, kind})

    {:reply, :ok, state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, %{bytes: meta(:bytes), entries: :ets.info(@table, :size) || 0}, state}
  end

  defp safe(default, fun) do
    fun.()
  rescue
    _ -> default
  catch
    _, _ -> default
  end

  defp next_seq, do: :ets.update_counter(@meta, :seq, {2, 1}, {:seq, 0})
  defp add_bytes(n), do: :ets.update_counter(@meta, :bytes, {2, n}, {:bytes, 0})

  defp meta(key) do
    case :ets.lookup(@meta, key) do
      [{^key, value}] -> max(value, 0)
      _ -> 0
    end
  end

  defp delete_id(id) do
    case :ets.lookup(@table, id) do
      [{^id, _hash, _html, bytes, seq}] ->
        :ets.delete(@table, id)
        :ets.delete(@lru, seq)
        add_bytes(-bytes)

      _ ->
        :ok
    end
  end

  defp evict do
    if meta(:bytes) > @max_bytes or (:ets.info(@table, :size) || 0) > @max_entries do
      case :ets.first(@lru) do
        :"$end_of_table" ->
          :ok

        seq ->
          case :ets.lookup(@lru, seq) do
            [{^seq, id}] -> delete_id(id)
            _ -> :ets.delete(@lru, seq)
          end

          evict()
      end
    end
  end
end
