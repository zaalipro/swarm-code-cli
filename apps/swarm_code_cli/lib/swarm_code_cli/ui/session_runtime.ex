defmodule SwarmCodeCLI.UI.SessionRuntime do
  @moduledoc """
  Serialized owner of semantic UI state, effects and a protected latest-scene slot.

  A registered terminal receives only `{:draw, token, revision}` and responds with
  `{:draw_result, token, revision, :ok | {:error, code}}`. It must fetch that exact
  revision from SceneSlot and discard its local scene immediately. Shutdown uses
  `{:terminal_control, :shutdown, token}` / `{:terminal_shutdown, token, result}`.
  Shutdown acknowledges terminal-resource restoration. The stable terminal handle
  stays alive until runtime DOWN, forwarding the fixed plain instruction after
  restoration; a launcher can instead supply `:instruction_sink`.
  No terminal message contains drafts, transcript, source DTOs or scene values.
  `{:error, :stale_revision}` is a compact retryable draw result when semantic
  progress replaced the slot before its reader fetched the attempted revision.
  Direct close tokens and external confirmation Actions never bypass Keymap.

  The deterministic three-run test uses `{"message-A-2", 2, :top}`: the committed
  fixture has three lines and logical anchors are zero-based. The older plan's
  line 3 literal would address a fourth line that this fixture does not contain.
  """
  use GenServer, restart: :temporary

  alias SwarmCodeCLI.UI.{
    Action,
    Init,
    Reducer,
    Projector,
    Keymap,
    SceneSlot,
    TimerSupervisor,
    EffectRunner,
    Scene,
    SafeText
  }

  alias SwarmCodeCLI.UI.DataSource
  alias SwarmCodeCLI.UI.DataSource.DataBridge

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def register_terminal(server, terminal, generation, capabilities),
    do: GenServer.call(server, {:terminal, terminal, generation, capabilities})

  def input(server, input), do: GenServer.call(server, {:input, input})

  @doc "Trusted local semantic input. External delivery and renderer activation use their correlated routes."
  def action(server, action), do: GenServer.call(server, {:action, action})
  def activate(server, revision, id), do: GenServer.call(server, {:activate, revision, id})
  def snapshot(server), do: GenServer.call(server, :snapshot)
  def status(server), do: GenServer.call(server, :status)
  def close(server, token), do: GenServer.call(server, {:close, token})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    %Init{} = init = Keyword.fetch!(opts, :init)
    frame = Keyword.fetch!(opts, :frame_ms)
    source = resolve(Keyword.fetch!(opts, :data_source))

    if not is_pid(source) or not is_integer(frame) or frame < 1,
      do: raise(ArgumentError, "invalid runtime initialization")

    {ui, effects} = Reducer.init(init)
    binding = identity()
    owner = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            DataSource.bind_owner(source, owner, binding)
          catch
            _, _ -> {:error, :binding_failed}
          end

        send(owner, {:bound, binding, result})
      end)

    timeout = Keyword.get(opts, :close_ms, 1000)

    {:ok,
     %{
       phase: :binding,
       ui: ui,
       initial_effects: effects,
       data_source: source,
       source_monitor: Process.monitor(source),
       terminal: nil,
       terminal_monitor: nil,
       bound?: false,
       binding: binding,
       binder: {worker, monitor},
       binding_timer:
         Process.send_after(
           self(),
           {:binding_timeout, binding},
           Keyword.get(opts, :bind_ms, 2000)
         ),
       slot: SceneSlot.new(),
       table: %{},
       frame_ms: frame,
       close_ms: timeout,
       draw: :idle,
       frame_timer: nil,
       draw_deadline: nil,
       timers: %{},
       secret: make_ref(),
       sequence: 0,
       instruction_sink: Keyword.get(opts, :instruction_sink),
       final_pending?: false,
       close_kind: nil,
       shutdown_token: nil,
       close_timer: nil
     }}
  end

  @impl true
  def handle_call(:snapshot, _, state), do: {:reply, state.ui, state}
  def handle_call(:status, _, state), do: {:reply, summary(state), state}
  def handle_call({:close, _}, _, state), do: {:reply, {:error, :confirmation_required}, state}

  def handle_call({:terminal, _, _, _}, _, %{terminal: terminal} = state)
      when not is_nil(terminal),
      do: {:reply, {:error, :duplicate_terminal}, begin_shutdown(state, :binding_failed)}

  def handle_call({:terminal, _, _, _}, _, %{phase: phase} = state) when phase != :binding,
    do: {:reply, {:error, :not_binding}, state}

  def handle_call({:terminal, terminal, generation, caps}, _, state) do
    pid = resolve(terminal)

    if is_pid(pid) and Process.alive?(pid) and generation >= state.ui.terminal_generation and
         match?({:ok, _}, Action.validate({:terminal_capabilities, generation, caps})) do
      ui = %{state.ui | terminal_generation: generation, capabilities: caps, size: caps.size}
      next = %{state | terminal: pid, terminal_monitor: Process.monitor(pid), ui: ui}
      {:reply, {:ok, state.slot}, maybe_start(next)}
    else
      {:reply, {:error, :binding_failed}, begin_shutdown(state, :binding_failed)}
    end
  end

  def handle_call({:input, input}, _, %{phase: :running} = state),
    do: {:reply, :ok, resolved(state, Keymap.resolve(input, state.ui, state.table))}

  def handle_call({:action, action}, _, %{phase: :running} = state) do
    allowed =
      case action do
        {:data, _} -> false
        {:draw_result, _, _, _} -> false
        {:quit_confirmed, _} -> false
        {:presenter_handoff_confirmed, _} -> false
        {:invoke, _, _} -> false
        {:timer_fired, _} -> false
        _ -> true
      end

    {:reply, :ok, if(allowed, do: update(state, action), else: state)}
  end

  def handle_call({:activate, revision, id}, _, %{phase: :running} = state) do
    result =
      if revision == state.ui.revision and Map.has_key?(state.table, id),
        do: Keymap.activate(state.table[id], state.ui, state.table),
        else: :ignore

    {:reply, :ok, resolved(state, result)}
  end

  def handle_call(_, _, state), do: {:reply, :ok, state}

  @impl true
  def handle_info(
        {:bound, ref, {:ok, ref}},
        %{binding: ref, phase: :binding, bound?: false} = state
      ) do
    clear_binder(state.binder)
    {:noreply, maybe_start(%{state | bound?: true, binder: nil})}
  end

  def handle_info({:bound, _, _}, state), do: {:noreply, begin_shutdown(state, :binding_failed)}

  def handle_info({:binding_timeout, ref}, %{phase: :binding, binding: ref} = state),
    do: {:noreply, begin_shutdown(state, :binding_failed)}

  def handle_info({:frame, id}, %{phase: :running, draw: {:timer, id}} = state),
    do: {:noreply, draw(%{state | draw: :idle, frame_timer: cancel(state.frame_timer)})}

  def handle_info({:draw_result, token, revision, result}, state),
    do: {:noreply, settle_draw(state, token, revision, result)}

  def handle_info({:draw_timeout, token}, %{draw: {:in_flight, token, _, _}} = state) do
    next =
      if state.final_pending?,
        do:
          final_paint(
            %{state | draw: :idle, draw_deadline: nil, final_pending?: false},
            state.close_kind
          ),
        else: begin_shutdown(state, state.close_kind || :draw_failed)

    {:noreply, next}
  end

  def handle_info({:owned_effect, secret, effect}, %{secret: secret} = state),
    do: {:noreply, local_effect(state, effect)}

  def handle_info({:owned_timer, id, token}, %{phase: :running} = state) do
    case TimerSupervisor.settle(state.timers, id, token) do
      {:ok, action, timers} -> {:noreply, update(%{state | timers: timers}, action)}
      :stale -> {:noreply, state}
    end
  end

  def handle_info(
        {:swarm_code_ui_closed, source, epoch},
        %{data_source: source, ui: %{source_epoch: epoch}} = state
      ),
      do: {:noreply, begin_shutdown(state, :source_unavailable)}

  def handle_info({:swarm_code_ui_data, _, receipt, _} = envelope, %{phase: :running} = state) do
    case DataBridge.normalize(envelope, state.ui.source_epoch) do
      {:ok, action} ->
        next = update(state, action)

        case consume(state.data_source, receipt, :applied) do
          :ok -> {:noreply, next}
          _ -> {:noreply, begin_shutdown(next, :source_unavailable)}
        end

      _ ->
        consume(state.data_source, receipt, :discarded)
        {:noreply, state}
    end
  end

  def handle_info({:swarm_code_ui_data, _, _} = envelope, %{phase: :running} = state) do
    case DataBridge.normalize(envelope, state.ui.source_epoch) do
      {:ok, action} -> {:noreply, update(state, action)}
      _ -> {:noreply, state}
    end
  end

  def handle_info(
        {:terminal_shutdown, token, _},
        %{phase: :closing, shutdown_token: token} = state
      )
      when not is_nil(token),
      do: finish_shutdown(state)

  def handle_info({:shutdown_timeout, token}, %{phase: :closing, shutdown_token: token} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, monitor, :process, _, _}, state) do
    cond do
      monitor == state.terminal_monitor ->
        next =
          begin_shutdown(%{state | terminal: nil, terminal_monitor: nil}, :terminal_unavailable)

        {:stop, :normal, next}

      monitor == state.source_monitor ->
        {:noreply, begin_shutdown(state, :source_unavailable)}

      state.binder != nil and monitor == elem(state.binder, 1) ->
        {:noreply, begin_shutdown(state, :binding_failed)}

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, _, :shutdown}, state), do: {:stop, :normal, state}
  def handle_info(_, state), do: {:noreply, state}

  defp maybe_start(%{bound?: true, terminal: terminal, phase: :binding} = state)
       when not is_nil(terminal) do
    cancel(state.binding_timer)
    state = %{state | phase: :running, binding_timer: nil}
    effects(state, state.initial_effects)
    project(%{state | initial_effects: []}) |> schedule()
  end

  defp maybe_start(state), do: state
  defp resolved(state, {:ok, action}), do: update(state, action)
  defp resolved(state, _), do: state

  defp consume(source, receipt, disposition) do
    DataSource.consume(source, receipt, disposition)
  catch
    :exit, _ -> {:error, :source_unavailable}
  end

  defp update(%{ui: %{lifecycle: :closing}} = state, _), do: state

  defp update(state, action) do
    {ui, emitted} = Reducer.update(state.ui, action)
    next = %{state | ui: ui}
    effects(next, emitted)

    if ui == state.ui,
      do: next,
      else:
        next
        |> invalidate_generation(state.ui.terminal_generation)
        |> pause_frame()
        |> project()
        |> schedule()
  end

  defp effects(state, emitted) do
    Enum.each(emitted, fn effect ->
      EffectRunner.run(effect, %{
        data_source: state.data_source,
        owner: self(),
        source_epoch: state.ui.source_epoch,
        local: fn value -> send(self(), {:owned_effect, state.secret, value}) end
      })
    end)
  end

  defp local_effect(%{phase: :running} = state, {:start_timer, id, ms, action}),
    do: %{state | timers: TimerSupervisor.start(state.timers, id, ms, action)}

  defp local_effect(state, {:cancel_timer, id}),
    do: %{state | timers: TimerSupervisor.cancel(state.timers, id)}

  defp local_effect(%{phase: :running} = state, {:detach, _}), do: final_paint(state, :detach)

  defp local_effect(%{phase: :running} = state, {:presenter_handoff, :plain}),
    do: final_paint(state, :plain)

  defp local_effect(state, {:terminal_control, op}) when op in [:suspend, :resume] do
    if state.terminal,
      do: send(state.terminal, {:terminal_control, op, state.ui.terminal_generation})

    state
  end

  defp local_effect(state, {:terminal_control, :shutdown}), do: begin_shutdown(state, :detach)
  # Announcements already live in the safe Scene; no text is sent to terminal state.
  defp local_effect(state, _), do: state

  defp project(state) do
    {scene, table} = Projector.project(state.ui)

    case SceneSlot.put(state.slot, scene) do
      :ok -> %{state | table: table}
      _ -> begin_shutdown(state, :invalid_scene)
    end
  end

  defp pause_frame(%{ui: %{lifecycle: lifecycle}, draw: {:timer, _}} = state)
       when lifecycle != :running do
    cancel(state.frame_timer)
    %{state | draw: :idle, frame_timer: nil}
  end

  defp pause_frame(state), do: state

  defp schedule(%{phase: :running, draw: :idle, ui: %{lifecycle: :running}} = state) do
    id = identity()

    %{
      state
      | draw: {:timer, id},
        frame_timer: Process.send_after(self(), {:frame, id}, state.frame_ms)
    }
  end

  defp schedule(state), do: state

  defp draw(state) do
    token = identity()
    revision = state.ui.revision
    send(state.terminal, {:draw, token, revision})

    %{
      state
      | draw: {:in_flight, token, revision, state.ui.terminal_generation},
        draw_deadline: Process.send_after(self(), {:draw_timeout, token}, state.close_ms)
    }
  end

  defp settle_draw(
         %{draw: {:in_flight, token, revision, generation}} = state,
         token,
         revision,
         result
       ) do
    if generation == state.ui.terminal_generation and valid_result?(result) do
      cancel(state.draw_deadline)
      next = %{state | draw: :idle, draw_deadline: nil}

      cond do
        state.final_pending? -> final_paint(%{next | final_pending?: false}, state.close_kind)
        state.phase == :closing -> begin_shutdown(next, state.close_kind)
        result == {:error, :stale_revision} -> schedule(next)
        result != :ok -> begin_shutdown(next, :draw_failed)
        state.ui.revision != revision -> schedule(next)
        true -> next
      end
    else
      state
    end
  end

  defp settle_draw(state, _, _, _), do: state
  defp valid_result?(:ok), do: true
  defp valid_result?({:error, :stale_revision}), do: true
  defp valid_result?({:error, code}), do: Action.terminal_error_code?(code)
  defp valid_result?(_), do: false

  defp invalidate_generation(state, old) do
    if state.ui.terminal_generation != old do
      cancel(state.frame_timer)
      cancel(state.draw_deadline)
      %{state | draw: :idle, frame_timer: nil, draw_deadline: nil}
    else
      state
    end
  end

  defp final_paint(%{draw: {:in_flight, _, _, _}} = state, kind) do
    cancel(state.frame_timer)

    %{
      state
      | phase: :closing,
        close_kind: kind,
        final_pending?: true,
        table: %{},
        frame_timer: nil
    }
  end

  defp final_paint(state, kind) do
    cancel(state.frame_timer)
    cancel(state.draw_deadline)
    ui = %{state.ui | revision: state.ui.revision + 1}
    {:ok, detached} = SafeText.external("DETACHED — RUNS CONTINUE", SafeText.Limits.content())

    scene = %Scene{
      revision: ui.revision,
      size: ui.size,
      ambiguous_width: ui.capabilities.ambiguous_width,
      regions: [
        %Scene.Region{
          id: "detached",
          role: :status,
          rect: %Scene.Rect{x: 0, y: 0, width: ui.size.columns, height: 1},
          label: SafeText.chrome(:empty),
          blocks: [%Scene.Block.Text{text: detached}]
        }
      ]
    }

    :ok = SceneSlot.put(state.slot, scene)

    draw(%{
      state
      | phase: :closing,
        ui: ui,
        close_kind: kind,
        table: %{},
        frame_timer: nil,
        draw_deadline: nil
    })
  end

  defp begin_shutdown(%{shutdown_token: token} = state, _) when not is_nil(token), do: state

  defp begin_shutdown(state, kind) do
    cancel(state.binding_timer)
    cancel(state.frame_timer)
    cancel(state.draw_deadline)
    clear_binder(state.binder)
    timers = TimerSupervisor.close(state.timers)

    Enum.each(state.ui.requests, fn {id, _} ->
      safe(fn -> DataSource.cancel(state.data_source, id) end)
    end)

    Enum.each(state.ui.watches, fn {_, watch} ->
      if watch.watch_ref,
        do: safe(fn -> DataSource.unwatch(state.data_source, watch.watch_ref) end)
    end)

    safe(fn -> DataSource.close(state.data_source) end)
    token = identity()

    if state.terminal,
      do: send(state.terminal, {:terminal_control, :shutdown, token}),
      else: send(self(), {:terminal_shutdown, token, :ok})

    %{
      state
      | phase: :closing,
        close_kind: kind,
        shutdown_token: token,
        timers: timers,
        binder: nil,
        frame_timer: nil,
        binding_timer: nil,
        draw_deadline: nil,
        draw: :idle,
        close_timer: Process.send_after(self(), {:shutdown_timeout, token}, state.close_ms)
    }
  end

  defp finish_shutdown(state) do
    sink = state.instruction_sink || state.terminal

    if state.close_kind == :plain and sink,
      do: send(sink, {:plain_instruction, "Rerun with --plain"})

    {:stop, :normal, state}
  end

  @impl true
  def terminate(_, state) do
    cancel(state.close_timer)
    cancel(state.binding_timer)
    cancel(state.frame_timer)
    cancel(state.draw_deadline)
    clear_binder(state.binder)
    TimerSupervisor.close(state.timers)
    safe(fn -> DataSource.close(state.data_source) end)

    if state.terminal && state.shutdown_token == nil,
      do: send(state.terminal, {:terminal_control, :shutdown, identity()})

    SceneSlot.destroy(state.slot)
    :ok
  end

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, summary(status.state))
    |> Map.put(:message, :redacted)
    |> Map.put(:reason, :redacted)
    |> Map.put(:log, [])
  end

  defp summary(state),
    do: %{
      phase: state.phase,
      revision: state.ui.revision,
      generation: state.ui.terminal_generation,
      draw: state.draw,
      timer_count: map_size(state.timers),
      watch_count: map_size(state.ui.watches),
      request_count: map_size(state.ui.requests)
    }

  defp identity, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  defp resolve(pid) when is_pid(pid), do: pid
  defp resolve(name), do: GenServer.whereis(name)
  defp cancel(nil), do: nil

  defp cancel(timer),
    do:
      (
        Process.cancel_timer(timer)
        nil
      )

  defp clear_binder(nil), do: :ok

  defp clear_binder({pid, monitor}) do
    Process.demonitor(monitor, [:flush])
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    :ok
  end

  defp safe(fun) do
    fun.()
  catch
    _, _ -> :ok
  end
end
