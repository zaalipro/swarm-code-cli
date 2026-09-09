defmodule SwarmCode.Domain.UIState do
  @moduledoc """
  Per-conversation UI state that must survive LiveView remounts (spec 10 §18):
  which agent cards are expanded, which operations drawers are open, which
  sub-agent groups are collapsed, which folders of the Changes tree the user
  opened (spec 12 §8) and which runs already got their default. Nothing derives
  it from run status — only the user's own toggles change it.

  A public ETS table owned by this process (started next to the Endpoint), so
  it is cleared when the app restarts.
  """
  use GenServer

  @table __MODULE__

  @type state :: %{
          expanded: MapSet.t(),
          open_ops: MapSet.t(),
          extended_turns: MapSet.t(),
          collapsed_subtrees: MapSet.t(),
          collapsed_runs: MapSet.t(),
          open_threads: MapSet.t(),
          thread_defaulted: MapSet.t(),
          user_threads: MapSet.t(),
          open_dirs: MapSet.t(),
          seen: MapSet.t(),
          timeline_run: String.t() | nil,
          timeline_zoom: String.t(),
          timeline_scroll: non_neg_integer(),
          bench_layout: String.t() | nil,
          bench_round_open: %{optional(String.t()) => integer() | nil},
          task_runs_shown: %{optional(String.t()) => pos_integer()}
        }

  # spec 55 T31 (55b B2): written only through update/3; put/2 never carries them.
  # `consensus_open`, `seen` and the `timeline_*` keys stay whole-copy.
  @per_key [
    :expanded,
    :open_ops,
    :open_threads,
    :thread_defaulted,
    :user_threads,
    :bench_layout,
    :bench_round_open,
    # spec 58 T9: the sidebar's per-task run counts — update/3 only
    :task_runs_shown,
    # spec 60 T58: the four folds `remember_ui_state/1` still whole-copied
    :collapsed_runs,
    :collapsed_subtrees,
    :extended_turns,
    :open_dirs
  ]

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  # ------------------------------------------------------------- presence (§4)

  @doc """
  Remembers that this process has `conversation_id` open (spec 49 §4.2).

  There was no presence in the app before pass 43, and a cleanup must never
  delete the session someone is looking at in another window. The row is keyed
  by pid and dropped when that pid dies, so a crashed LiveView cannot pin a
  conversation open for ever.
  """
  @spec opened(String.t() | nil) :: :ok
  def opened(nil), do: :ok
  def opened(conversation_id), do: GenServer.cast(__MODULE__, {:opened, conversation_id, self()})

  @doc "Ids of the conversations open in a window right now (spec 49 §4.2)."
  @spec open_conversation_ids() :: [String.t()]
  def open_conversation_ids do
    @table
    |> :ets.select([{{{:open, :_}, :"$1"}, [], [:"$1"]}])
    |> Enum.uniq()
  rescue
    _ -> []
  catch
    _, _ -> []
  end

  @impl true
  def handle_cast({:opened, conversation_id, pid}, monitors) do
    monitors =
      if Map.has_key?(monitors, pid) do
        monitors
      else
        Map.put(monitors, pid, Process.monitor(pid))
      end

    :ets.insert(@table, {{:open, pid}, conversation_id})
    {:noreply, monitors}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, monitors) do
    :ets.delete(@table, {:open, pid})
    {:noreply, Map.delete(monitors, pid)}
  end

  def handle_info(_message, monitors), do: {:noreply, monitors}

  @doc "The remembered state of a conversation (empty sets when it has none)."
  @spec get(String.t() | nil) :: state()
  def get(nil), do: empty()

  def get(conversation_id) do
    case :ets.lookup(@table, conversation_id) do
      # Merged with the defaults: a state stored before a new key existed is
      # still a valid state.
      [{^conversation_id, state}] ->
        state |> Map.drop([:side_open?, :side_run_id]) |> then(&Map.merge(empty(), &1))

      _ ->
        empty()
    end
  rescue
    _ -> empty()
  catch
    _, _ -> empty()
  end

  @doc "Remembers the state of a conversation."
  @spec put(String.t() | nil, state()) :: :ok
  def put(nil, _state), do: :ok

  def put(conversation_id, state) do
    # spec 60 T58: the read-merge-insert runs inside the owner, like
    # `update/3`, so two windows' `put/2`s cannot interleave.
    GenServer.call(__MODULE__, {:put, conversation_id, state})
  catch
    :exit, _ -> :ok
  end

  @doc "Read-modify-write of one key, atomic across windows (spec 55 T31)."
  @spec update(String.t() | nil, atom(), (term() -> term())) :: :ok
  def update(nil, _key, _fun), do: :ok

  def update(conversation_id, key, fun) when is_atom(key) and is_function(fun, 1) do
    GenServer.call(__MODULE__, {:update, conversation_id, key, fun})
  catch
    :exit, _ -> :ok
  end

  @impl true
  def handle_call({:update, conversation_id, key, fun}, _from, monitors) do
    row = raw(conversation_id)
    current = Map.get(row, key, Map.get(empty(), key))
    :ets.insert(@table, {conversation_id, Map.put(row, key, fun.(current))})
    {:reply, :ok, monitors}
  end

  def handle_call({:put, conversation_id, state}, _from, monitors) do
    # spec 55 T31 (55b B2): the per-key sets are the `update/3` deltas' — a
    # window's whole copy would undo what another window folded.
    :ets.insert(
      @table,
      {conversation_id,
       Map.merge(raw(conversation_id), Map.drop(state, @per_key ++ [:side_open?, :side_run_id]))}
    )

    {:reply, :ok, monitors}
  end

  defp raw(conversation_id) do
    case :ets.lookup(@table, conversation_id) do
      [{^conversation_id, state}] -> state
      _ -> %{}
    end
  end

  def get_window(_conversation_id, nil), do: empty_window()

  def get_window(conversation_id, window_id) do
    case :ets.lookup(@table, {:window, conversation_id, window_id}) do
      [{{:window, ^conversation_id, ^window_id}, state}] ->
        state |> Map.delete(:written_at) |> then(&Map.merge(empty_window(), &1))

      _ ->
        empty_window()
    end
  rescue
    _ -> empty_window()
  catch
    _, _ -> empty_window()
  end

  def put_window(_conversation_id, nil, _state), do: :ok

  def put_window(conversation_id, window_id, state) do
    value =
      state
      |> Map.take([
        :side_open?,
        :side_run_id,
        :pane_view,
        :pane_hidden,
        :side_cards_collapsed?,
        # Spec 45 §9
        :side_sections
      ])
      |> Map.put(:written_at, System.monotonic_time())

    :ets.insert(@table, {{:window, conversation_id, window_id}, value})
    prune_windows()
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # Spec 43 §2.5 (W19): the walk over every window row happens only once the
  # table is over its cap, not on every card toggle.
  defp prune_windows do
    if :ets.select_count(@table, [{{{:window, :_, :_}, :_}, [], [true]}]) > 200,
      do: prune_windows_now()
  end

  defp prune_windows_now do
    rows = :ets.match_object(@table, {{:window, :_, :_}, :_})

    rows
    |> Enum.sort_by(fn {_, state} -> Map.get(state, :written_at, 0) end)
    |> Enum.take(max(length(rows) - 200, 0))
    |> Enum.each(fn {key, _} -> :ets.delete(@table, key) end)
  end

  defp empty_window,
    do: %{
      side_open?: false,
      side_run_id: nil,
      pane_view: nil,
      pane_hidden: nil,
      # Spec 40 §3.4
      side_cards_collapsed?: false,
      # Spec 45 §9: the folded sections of the side column (key → false).
      side_sections: %{}
    }

  @doc "Forgets one conversation's remembered UI state."
  def delete(nil), do: :ok

  def delete(conversation_id) do
    :ets.delete(@table, conversation_id)
    :ets.match_delete(@table, {{:window, conversation_id, :_}, :_})
    # Spec 49 §4.2: a deleted conversation is no longer open anywhere.
    :ets.match_delete(@table, {{:open, :_}, conversation_id})
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Forgets everything (tests)."
  def clear do
    :ets.delete_all_objects(@table)
    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  def empty do
    %{
      expanded: MapSet.new(),
      open_ops: MapSet.new(),
      # Spec 13 §1: the chat turns the user opened into their full card.
      extended_turns: MapSet.new(),
      collapsed_subtrees: MapSet.new(),
      collapsed_runs: MapSet.new(),
      # Spec 12 §2: the run threads the user has open, and the runs that already
      # got their open/closed default.
      open_threads: MapSet.new(),
      thread_defaulted: MapSet.new(),
      user_threads: MapSet.new(),
      open_dirs: MapSet.new(),
      seen: MapSet.new(),
      # Spec 40 §2.3: the consensus rounds the user opened or closed.
      consensus_open: %{},
      # Spec 57 §6: the layout override and the one open round per run.
      bench_layout: nil,
      bench_round_open: %{},
      # Spec 58 §5: how many runs each task node shows (absent = six).
      task_runs_shown: %{},
      # Spec 12 §7: which run the Timeline is focused on, how dense it is and
      # where it was scrolled to — all per conversation.
      timeline_run: nil,
      timeline_zoom: "md",
      timeline_scroll: 0
    }
  end
end
