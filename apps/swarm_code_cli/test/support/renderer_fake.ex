defmodule SwarmCodeCLI.Test.RendererFake do
  @moduledoc "Deterministic renderer barrier. State retains only handles and compact draw identities."
  use GenServer, restart: :temporary
  alias SwarmCodeCLI.UI.{SessionRuntime, SceneSlot, Scene}
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def settle(server, result \\ :ok), do: GenServer.call(server, {:settle, result})
  def barrier(server), do: GenServer.call(server, :barrier)
  @impl true
  def init(opts) do
    runtime = Keyword.fetch!(opts, :runtime)

    {:ok, slot} =
      SessionRuntime.register_terminal(
        runtime,
        self(),
        Keyword.get(opts, :generation, 0),
        Keyword.fetch!(opts, :capabilities)
      )

    {:ok,
     %{
       runtime: runtime,
       monitor: Process.monitor(runtime),
       slot: slot,
       observer: Keyword.fetch!(opts, :observer),
       pending: nil,
       draws: 0
     }}
  end

  @impl true
  def handle_call(:barrier, _, state), do: {:reply, Map.take(state, [:pending, :draws]), state}

  def handle_call({:settle, result}, _, %{pending: {token, revision}} = state) do
    send(state.runtime, {:draw_result, token, revision, result})
    {:reply, :ok, %{state | pending: nil}}
  end

  def handle_call({:settle, _}, _, state), do: {:reply, {:error, :no_draw}, state}
  @impl true
  def handle_info({:draw, token, revision}, state) do
    result =
      case SceneSlot.fetch(state.slot, revision) do
        {:ok, scene} -> Scene.validate(scene)
        error -> error
      end

    send(state.observer, {:renderer_draw, self(), token, revision, result})
    {:noreply, %{state | pending: {token, revision}, draws: state.draws + 1}}
  end

  def handle_info({:terminal_control, :shutdown, token}, state) do
    send(state.runtime, {:terminal_shutdown, token, :ok})
    send(state.observer, {:renderer_shutdown, self()})
    {:noreply, %{state | pending: nil}}
  end

  def handle_info({:plain_instruction, "Rerun with --plain"}, state) do
    send(state.observer, {:plain_instruction, "Rerun with --plain"})
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor, :process, _, _}, %{monitor: monitor} = state),
    do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}
  @impl true
  def format_status(status), do: Map.put(status, :message, :redacted)
end
