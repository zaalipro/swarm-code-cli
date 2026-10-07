defmodule SwarmCode.Domain.Engine.ResearchContext do
  @moduledoc """
  spec 74 BUGS-76: the attached deep-research reports of a conversation, kept
  in every turn's context — not only the turn they were attached to.

  A user message carries the ids it attached (`messages.research_ids`).
  `Prompts.history_to_messages/1` marks the rebuilt message with them
  (`research_ids:`), and the agent that receives the history expands the
  marks (`expand/1`) in its own process before its first think step — the
  reports are read there, never in the LiveView's send handler. A steer
  carries its ids the same way.

  The block for a list of ids is `SwarmCode.Domain.Research.context_block/1`,
  memoised in a byte-bounded ETS table so it is byte-identical from turn to
  turn (the prompt cache holds). The key names every report by its file's
  stamp (mtime, size, inode) — a report that is rewritten or deleted is a new
  key, a missing one drops out as before. Eviction is oldest first and only
  ever costs an exact recomputation.
  """
  use GenServer

  alias SwarmCode.Domain.Engine.Context

  @table __MODULE__
  @max_bytes 8_000_000

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Every message with a non-empty `research_ids:` mark gets the reports' block
  in front of its content (`block <> "\\n\\n" <> content`, the shape the turn
  that attached them always sent); the mark is dropped either way.
  """
  @spec expand([map()]) :: [map()]
  def expand(messages), do: Enum.map(messages, &expand_one/1)

  defp expand_one(%{research_ids: ids} = message) do
    message = Map.delete(message, :research_ids)

    case block(ids) do
      "" ->
        message

      text ->
        message
        |> Map.put(:content, text <> "\n\n" <> to_string(message[:content] || ""))
        |> recount()
    end
  end

  defp expand_one(message), do: message

  # A message the agent already counted (`Context.count/1`) is counted again.
  defp recount(%{tokens: _} = message), do: Context.count(message)
  defp recount(message), do: message

  @doc "`Research.context_block/1` for `ids`, memoised (see the moduledoc)."
  @spec block([integer()] | nil) :: String.t()
  def block(ids) do
    case ids |> List.wrap() |> Enum.uniq() do
      [] ->
        ""

      ids ->
        key = {ids, Enum.map(ids, &stamp/1)}

        case lookup(key) do
          {:ok, text} ->
            text

          :miss ->
            text = SwarmCode.Domain.Research.context_block(ids)
            store(key, text)
            text
        end
    end
  end

  defp stamp(id) do
    case File.stat(SwarmCode.Domain.Research.result_path(id), time: :posix) do
      {:ok, %{mtime: mtime, size: size, inode: inode}} -> {mtime, size, inode}
      {:error, _reason} -> :missing
    end
  end

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, text}] -> {:ok, text}
      [] -> :miss
    end
  rescue
    # No table: the application is not started (a unit test, a script).
    ArgumentError -> :miss
  end

  defp store(key, text) do
    GenServer.call(__MODULE__, {:store, key, text})
  catch
    :exit, _not_running -> :ok
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{bytes: 0, order: :queue.new()}}
  end

  @impl true
  def handle_call({:store, key, text}, _from, state) do
    if :ets.member(@table, key) do
      {:reply, :ok, state}
    else
      :ets.insert(@table, {key, text})

      state =
        %{
          state
          | bytes: state.bytes + byte_size(text),
            order: :queue.in({key, byte_size(text)}, state.order)
        }
        |> evict()

      {:reply, :ok, state}
    end
  end

  # Oldest first, until the table is back under its bound.
  defp evict(%{bytes: bytes} = state) when bytes <= @max_bytes, do: state

  defp evict(state) do
    case :queue.out(state.order) do
      {{:value, {key, size}}, order} ->
        :ets.delete(@table, key)
        evict(%{state | bytes: state.bytes - size, order: order})

      {:empty, _order} ->
        state
    end
  end
end
