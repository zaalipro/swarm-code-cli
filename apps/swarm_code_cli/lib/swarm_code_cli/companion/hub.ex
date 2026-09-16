defmodule SwarmCodeCLI.Companion.Hub do
  @moduledoc """
  Owns the latest companion view.

  The session runtime pushes `{:companion_state, ui}` after every change. The
  hub rebuilds the view at most ten times a second, bumps `revision` only when
  the view actually changed, keeps one encoded JSON copy, and fans it out to
  subscribed processes as `{:companion_view, revision, json}`. Focus requests
  from the page are translated here into existing `Action` shapes and handed
  to `SessionRuntime.action/2`; nothing new enters the reducer.
  """
  use GenServer

  alias SwarmCodeCLI.Companion.View
  alias SwarmCodeCLI.UI.{Intent, SessionRuntime, State}

  @interval_ms 100

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The current revision and its JSON."
  @spec view(GenServer.server()) :: {:ok, non_neg_integer(), binary()}
  def view(hub), do: GenServer.call(hub, :view)

  @doc "`:unchanged` when `revision` is still current, else the newer view."
  @spec view_since(GenServer.server(), non_neg_integer()) ::
          :unchanged | {:ok, non_neg_integer(), binary()}
  def view_since(hub, revision), do: GenServer.call(hub, {:view_since, revision})

  @doc "Registers the caller for `{:companion_view, revision, json}` and returns the current view."
  @spec subscribe(GenServer.server()) :: {:ok, non_neg_integer(), binary()}
  def subscribe(hub), do: GenServer.call(hub, :subscribe)

  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(hub), do: GenServer.call(hub, :unsubscribe)

  @doc "Names the runtime that focus requests are injected into."
  @spec attach(GenServer.server(), pid()) :: :ok
  def attach(hub, runtime) when is_pid(runtime), do: GenServer.call(hub, {:attach, runtime})

  @doc "Focuses `kind`/`id` in the TUI through the attached runtime."
  @spec focus(GenServer.server(), term(), term()) ::
          :ok | {:error, :invalid | :unsupported | :unavailable}
  def focus(hub, kind, id), do: GenServer.call(hub, {:focus, kind, id})

  @doc """
  The existing actions that focus `kind`/`id`, looked up against the last state.

  A run or conversation navigates; an agent navigates to its run and opens the
  agents tab; an item navigates to its run, focuses the transcript and expands
  the item. There is no action that selects one agent or item directly, so
  those two are best effort. Anything else is `:unsupported`.
  """
  @spec actions_for(State.t() | nil, term(), term()) ::
          {:ok, [SwarmCodeCLI.UI.Action.t(), ...]} | {:error, :invalid | :unsupported}
  def actions_for(_ui, "composer", _id), do: {:ok, [{:focus_region, "composer"}]}

  def actions_for(_ui, "run", id) do
    if Intent.valid_id?(id), do: {:ok, [{:navigate, {:run, id}}]}, else: {:error, :invalid}
  end

  def actions_for(_ui, "conversation", id) do
    if Intent.valid_id?(id),
      do: {:ok, [{:navigate, {:conversation, id}}]},
      else: {:error, :invalid}
  end

  def actions_for(%State{} = ui, "agent", id) do
    case Map.get(ui.read_model.agents, id) do
      %{run_id: run} when is_binary(run) -> {:ok, [{:navigate, {:run, run}}, {:set_tab, :agents}]}
      _ -> {:error, :invalid}
    end
  end

  def actions_for(%State{} = ui, "item", id) do
    case Map.get(ui.read_model.transcript, id) do
      %{run_id: run} when is_binary(run) ->
        {:ok, [{:navigate, {:run, run}}, {:focus_region, "main"}, {:expand, id, true}]}

      _ ->
        {:error, :invalid}
    end
  end

  def actions_for(nil, kind, _id) when kind in ["agent", "item"], do: {:error, :invalid}
  def actions_for(_ui, _kind, _id), do: {:error, :unsupported}

  @impl true
  def init(opts) do
    runtime = Keyword.get(opts, :runtime)

    unless is_nil(runtime) or is_pid(runtime),
      do: raise(ArgumentError, "companion hub needs a runtime pid or nil")

    state = %{
      runtime: runtime,
      meta: [
        project: Keyword.get(opts, :project),
        started_at: Keyword.get(opts, :started_at, System.system_time(:millisecond))
      ],
      interval: Keyword.get(opts, :interval_ms, @interval_ms),
      ui: nil,
      pending: seed(runtime),
      revision: 0,
      json: nil,
      fingerprint: nil,
      subscribers: %{},
      timer: nil,
      last_flush: nil
    }

    {:ok, flush(state)}
  end

  @impl true
  def handle_call(:view, _from, state), do: {:reply, {:ok, state.revision, state.json}, state}

  def handle_call({:view_since, revision}, _from, %{revision: revision} = state),
    do: {:reply, :unchanged, state}

  def handle_call({:view_since, _}, _from, state),
    do: {:reply, {:ok, state.revision, state.json}, state}

  def handle_call(:subscribe, {pid, _}, state) do
    subscribers =
      if Enum.any?(state.subscribers, fn {_, subscriber} -> subscriber == pid end),
        do: state.subscribers,
        else: Map.put(state.subscribers, Process.monitor(pid), pid)

    {:reply, {:ok, state.revision, state.json}, %{state | subscribers: subscribers}}
  end

  def handle_call(:unsubscribe, {pid, _}, state) do
    {gone, kept} = Enum.split_with(state.subscribers, fn {_, subscriber} -> subscriber == pid end)
    Enum.each(gone, fn {ref, _} -> Process.demonitor(ref, [:flush]) end)
    {:reply, :ok, %{state | subscribers: Map.new(kept)}}
  end

  def handle_call({:attach, runtime}, _from, state),
    do: {:reply, :ok, %{state | runtime: runtime}}

  def handle_call({:focus, kind, id}, _from, state) do
    reply =
      with {:ok, actions} <- actions_for(state.ui, kind, id) do
        inject(state.runtime, actions)
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:companion_state, %State{} = ui}, state),
    do: {:noreply, schedule(%{state | pending: ui})}

  def handle_info(:flush, state), do: {:noreply, flush(%{state | timer: nil})}

  def handle_info({:DOWN, ref, :process, _, _}, state),
    do: {:noreply, %{state | subscribers: Map.delete(state.subscribers, ref)}}

  def handle_info(_, state), do: {:noreply, state}

  # A push inside the interval waits for the timer; the first one after a quiet
  # spell goes out immediately, so a lone keystroke never pays the latency.
  defp schedule(%{timer: timer} = state) when timer != nil, do: state

  defp schedule(state) do
    elapsed =
      case state.last_flush do
        nil -> state.interval
        at -> System.monotonic_time(:millisecond) - at
      end

    if elapsed >= state.interval,
      do: flush(state),
      else: %{state | timer: Process.send_after(self(), :flush, state.interval - elapsed)}
  end

  defp flush(state) do
    ui = state.pending || state.ui || %State{}
    state = %{state | ui: ui, pending: nil, last_flush: System.monotonic_time(:millisecond)}

    case build(ui, state.meta) do
      {:ok, view} ->
        fingerprint = View.fingerprint(view)

        if fingerprint == state.fingerprint do
          state
        else
          revision = state.revision + 1
          json = Jason.encode!(%{view | revision: revision})

          Enum.each(state.subscribers, fn {_, pid} ->
            send(pid, {:companion_view, revision, json})
          end)

          %{state | revision: revision, json: json, fingerprint: fingerprint}
        end

      :error ->
        state
    end
  end

  # A state the builder cannot read keeps the previous view rather than taking
  # the companion down with it; the TUI is unaffected either way.
  defp build(ui, meta) do
    {:ok, View.build(ui, System.system_time(:millisecond), meta)}
  rescue
    _ -> :error
  end

  defp seed(nil), do: nil

  defp seed(runtime) do
    case SessionRuntime.snapshot(runtime) do
      %State{} = ui -> ui
      _ -> nil
    end
  catch
    :exit, _ -> nil
  end

  defp inject(nil, _actions), do: {:error, :unavailable}

  defp inject(runtime, actions) do
    Enum.each(actions, &SessionRuntime.action(runtime, &1))
    :ok
  catch
    :exit, _ -> {:error, :unavailable}
  end
end
