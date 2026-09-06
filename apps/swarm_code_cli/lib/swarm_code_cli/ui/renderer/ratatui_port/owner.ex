defmodule SwarmCodeCLI.UI.Renderer.RatatuiPort.Owner do
  @moduledoc "Owns the guarded native terminal and only bounded transport correlations."
  use GenServer, restart: :temporary
  import Bitwise
  alias SwarmCodeCLI.UI.{Capabilities, Paint, SceneSlot, SessionRuntime}
  alias SwarmCodeCLI.UI.Paint.Options
  alias SwarmCodeCLI.UI.Renderer.RatatuiPort.{Decoder, Frame, Wire}
  @deadline 3_000

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    runtime = Keyword.fetch!(options, :runtime)
    executable = Keyword.fetch!(options, :executable)
    %Capabilities{} = caps = Keyword.fetch!(options, :capabilities)
    flags = Keyword.fetch!(options, :flags)
    true = is_pid(runtime) and Path.type(executable) == :absolute
    {:ok, init} = Wire.init(1, flags)

    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :nouse_stdio,
        :hide,
        args: [~c"--beam-port"]
      ])

    true = Port.command(port, init, [:nosuspend])
    timer = timer(:init)

    {:ok,
     %{
       runtime: runtime,
       monitor: Process.monitor(runtime),
       port: port,
       decoder: Decoder.new(),
       caps: caps,
       flags: flags,
       slot: nil,
       generation: 1,
       counter: 0,
       sequence: 0,
       pending: nil,
       credit: nil,
       control: nil,
       phase: :initializing,
       timer: timer,
       input_enabled?: false,
       runtime_down?: false,
       observer: Keyword.get(options, :observer)
     }}
  rescue
    _ -> {:stop, :terminal_initialization_failed}
  end

  @impl true
  def handle_info(message, state) do
    try do
      dispatch(message, state)
    rescue
      _ -> {:stop, :terminal_protocol_failed, state}
    catch
      _, _ -> {:stop, :terminal_protocol_failed, state}
    end
  end

  defp dispatch({port, {:data, bytes}}, %{port: port} = state) do
    with {:ok, records, decoder} <- Decoder.push(state.decoder, bytes) do
      next = Enum.reduce(records, %{state | decoder: decoder}, &record/2)
      {:noreply, next}
    else
      _ -> {:stop, :terminal_protocol_failed, state}
    end
  rescue
    _ -> {:stop, :terminal_protocol_failed, state}
  catch
    :throw, {:terminal_error, code} -> {:stop, code, state}
    _, _ -> {:stop, :terminal_protocol_failed, state}
  end

  defp dispatch({:draw, token, revision}, %{phase: :running, pending: nil} = state) do
    sequence = state.sequence + 1

    result =
      with {:ok, scene} <- SceneSlot.fetch(state.slot, revision),
           {:ok, plan} <-
             Paint.build(scene, %Options{
               color_mode: state.caps.color_mode,
               ascii?: state.caps.ascii?
             }),
           {:ok, bytes} <- Frame.encode(plan, sequence),
           true <- Port.command(state.port, bytes, [:nosuspend]),
           do: :ok

    case result do
      :ok ->
        state = %{
          state
          | sequence: sequence,
            pending: {sequence, revision, token},
            timer: timer(:draw),
            input_enabled?: true
        }

        {:noreply, grant(state)}

      {:error, reason} when reason in [:stale_revision, :closed] ->
        send(state.runtime, {:draw_result, token, revision, {:error, :stale_revision}})
        {:noreply, grant(%{state | input_enabled?: true})}

      _ ->
        {:stop, :terminal_draw_failed, state}
    end
  rescue
    _ -> {:stop, :terminal_draw_failed, state}
  end

  defp dispatch({:draw, _, _}, %{phase: phase} = state) when phase != :running,
    do: {:noreply, state}

  defp dispatch({:draw, _, _}, state), do: {:stop, :terminal_protocol_failed, state}

  defp dispatch({:terminal_control, :shutdown, runtime_token}, state) do
    state = cancel(state)
    {token, state} = control(state, :shutdown)

    {:noreply,
     %{
       state
       | phase: :closing,
         control: {:shutdown, token, runtime_token},
         timer: timer(:shutdown)
     }}
  end

  defp dispatch(
         {:terminal_control, :suspend, generation},
         %{phase: :running, generation: generation} = state
       ) do
    state = cancel(state)
    {token, state} = control(state, :suspend)

    {:noreply,
     %{
       state
       | phase: :suspending,
         control: {:suspend, token},
         timer: timer(:suspend)
     }}
  end

  defp dispatch({:terminal_control, :resume, _}, %{phase: :suspended} = state) do
    {token, state} = control(state, :resume)
    {:noreply, %{state | phase: :resuming, control: {:resume, token}, timer: timer(:resume)}}
  end

  defp dispatch({:terminal_control, _, _}, state), do: {:noreply, state}

  defp dispatch({port, {:exit_status, _}}, %{port: port, phase: :restored} = state) do
    state = %{cancel(state) | port: nil}
    observe(state, :exited)
    if state.runtime_down?, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  defp dispatch({port, {:exit_status, _}}, %{port: port} = state),
    do: {:stop, :terminal_unavailable, %{state | port: nil}}

  defp dispatch({:EXIT, port, :normal}, %{port: port} = state), do: {:noreply, state}

  defp dispatch({:EXIT, port, _}, %{port: port} = state),
    do: {:stop, :terminal_unavailable, state}

  # Only successful Ready registration creates the scene slot. The runtime's
  # shorter binding deadline may end normally before the native init deadline.
  defp dispatch({:DOWN, monitor, :process, _, _}, %{monitor: monitor, slot: nil} = state),
    do: {:stop, :terminal_initialization_failed, state}

  defp dispatch({:DOWN, monitor, :process, _, _}, %{monitor: monitor, port: nil} = state),
    do: {:stop, :normal, state}

  defp dispatch(
         {:DOWN, monitor, :process, _, _},
         %{monitor: monitor, phase: :restored} = state
       ),
       do: {:noreply, %{state | runtime_down?: true}}

  defp dispatch({:DOWN, monitor, :process, _, _}, %{monitor: monitor} = state),
    do: {:stop, :normal, state}

  defp dispatch({:deadline, identity, _}, %{timer: {_, identity}} = state),
    do: {:stop, :terminal_timeout, state}

  defp dispatch({:plain_instruction, "Rerun with --plain"}, %{phase: :restored} = state) do
    IO.puts(
      "Run (cd apps/swarm_code_cli && MIX_QUIET=1 mise exec -- mix swarm_code.demo.plain --script complete)"
    )

    {:noreply, state}
  end

  defp dispatch(_, state), do: {:noreply, state}

  defp record({:resume_needed, 1}, %{phase: :running} = state) do
    if state.pending do
      {_, revision, token} = state.pending
      send(state.runtime, {:draw_result, token, revision, {:error, :stale_revision}})
    end

    state = cancel(state)
    {token, state} = control(state, :resume)

    %{
      state
      | phase: :resuming,
        pending: nil,
        credit: nil,
        input_enabled?: false,
        control: {:resume, token},
        timer: timer(:resume)
    }
  end

  defp record({:ready, 1, size, bits}, state) do
    expected =
      if(state.flags.alternate?, do: 1, else: 0) ||| if(state.flags.focus?, do: 2, else: 0) |||
        if state.flags.paste?, do: 4, else: 0

    true = bits == expected and state.phase in [:initializing, :resuming]

    caps = %{
      state.caps
      | size: size,
        tty?: true,
        controlling_tty?: true,
        stdin_tty?: state.caps.stdin_tty?,
        stdout_tty?: state.caps.stdout_tty?,
        full_screen?: true,
        paste_preallocation_bound?: true,
        alternate_screen: feature(state.flags.alternate?),
        focus: feature(state.flags.focus?),
        paste: feature(state.flags.paste?),
        enhanced_keys: :unavailable,
        mouse: :unavailable
    }

    state = cancel(state)

    if state.slot == nil do
      {:ok, slot} = SessionRuntime.register_terminal(state.runtime, self(), 1, caps)
      observe(state, :ready)
      %{state | slot: slot, caps: caps, phase: :running}
    else
      generation = state.generation + 1
      :ok = SessionRuntime.action(state.runtime, {:terminal_capabilities, generation, caps})

      :ok =
        SessionRuntime.action(
          state.runtime,
          {:terminal_lifecycle, :resumed, generation, :runtime}
        )

      %{
        state
        | generation: generation,
          caps: caps,
          phase: :running,
          pending: nil,
          credit: nil,
          control: nil,
          input_enabled?: false
      }
    end
  end

  defp record({kind, 1, sequence, revision}, %{pending: {sequence, revision, token}} = state)
       when kind in [:painted, :skipped] do
    result = if kind == :painted, do: :ok, else: {:error, :stale_revision}
    send(state.runtime, {:draw_result, token, revision, result})
    observe(state, {kind, revision})
    state = if state.phase == :running, do: cancel(state), else: state
    grant(%{state | pending: nil})
  end

  defp record({:input, 1, token, event}, %{phase: :running, credit: token} = state)
       when is_integer(token) do
    :ok = SessionRuntime.input(state.runtime, event)
    grant(%{state | credit: nil})
  end

  # A revoked credit may already have produced one ordered response before shutdown.
  defp record({:input, 1, token, _}, %{phase: phase, credit: token} = state)
       when phase in [:closing, :suspending] and is_integer(token),
       do: %{state | credit: nil}

  defp record(
         {:restored, 1, token, :closed},
         %{control: {:shutdown, token, runtime_token}} = state
       ) do
    send(state.runtime, {:terminal_shutdown, runtime_token, :ok})
    observe(state, :restored)

    %{
      cancel(state)
      | phase: :restored,
        control: nil,
        pending: nil,
        credit: nil,
        timer: timer(:exit)
    }
  end

  defp record({:restored, 1, token, :suspended}, %{control: {:suspend, token}} = state) do
    :ok =
      SessionRuntime.action(
        state.runtime,
        {:terminal_lifecycle, :suspended, state.generation, :runtime}
      )

    %{cancel(state) | phase: :suspended, control: nil, pending: nil, credit: nil}
  end

  defp record({:error, 1, code}, _)
       when code in [:protocol, :initialization, :draw, :read, :write, :restoration],
       do: throw({:terminal_error, code})

  defp record(_, _), do: raise("terminal protocol failed")

  defp feature(true), do: :best_effort
  defp feature(false), do: :unavailable

  defp grant(%{phase: :running, credit: nil, pending: nil, input_enabled?: true} = state) do
    {token, state} = control(state, :credit)
    %{state | credit: token}
  end

  defp grant(state), do: state

  defp control(state, operation) do
    token = state.counter + 1
    {:ok, bytes} = Wire.control(operation, 1, token)
    true = Port.command(state.port, bytes, [:nosuspend])
    {token, %{state | counter: token}}
  end

  defp timer(kind) do
    identity = make_ref()
    {Process.send_after(self(), {:deadline, identity, kind}, @deadline), identity}
  end

  defp cancel(%{timer: nil} = state), do: state

  defp cancel(%{timer: {timer, _}} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp observe(%{observer: pid}, event) when is_pid(pid),
    do: send(pid, {:terminal_owner, self(), event})

  defp observe(_, _), do: :ok

  @impl true
  def terminate(_, %{port: port} = state) when is_port(port) do
    if Port.info(port) do
      if state.phase != :restored do
        {:ok, shutdown} = Wire.control(:shutdown, 1, state.counter + 1)

        try do
          Port.command(port, shutdown, [:nosuspend])
        rescue
          ArgumentError -> :ok
        end
      end

      await_exit(port, System.monotonic_time(:millisecond) + @deadline)
    end

    :ok
  end

  def terminate(_, _), do: :ok

  defp await_exit(port, deadline) do
    receive do
      {^port, {:exit_status, _}} -> :ok
      {^port, {:data, _}} -> await_exit(port, deadline)
      {:EXIT, ^port, _} -> await_exit(port, deadline)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        if Port.info(port), do: Port.close(port)
        :ok
    end
  end

  @impl true
  def format_status(status) do
    status
    |> Map.put(:state, :redacted)
    |> Map.put(:message, :redacted)
    |> Map.put(:reason, safe_reason(Map.get(status, :reason)))
    |> Map.put(:log, [])
  end

  defp safe_reason(reason)
       when reason in [
              :terminal_initialization_failed,
              :terminal_protocol_failed,
              :terminal_unavailable,
              :terminal_timeout,
              :terminal_draw_failed,
              :protocol,
              :initialization,
              :draw,
              :read,
              :write,
              :restoration
            ],
       do: reason

  defp safe_reason(_), do: :terminal_failure
end
