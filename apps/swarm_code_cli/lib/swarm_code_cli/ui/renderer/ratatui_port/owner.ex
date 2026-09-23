defmodule SwarmCodeCLI.UI.Renderer.RatatuiPort.Owner do
  @moduledoc """
  Owns the guarded native terminal and only bounded transport correlations.

  A drawing problem never ends the session (pass70 B2): a scene that cannot be
  painted or encoded keeps the previous frame on screen with one error line on
  its last row (logged once per reason), a busy port answers the runtime
  `:stale_revision` so it draws the latest state on its next frame, and a slow
  paint is answered early and the next request is queued. The native helper's
  OS process never outlives this owner.
  """
  use GenServer, restart: :temporary
  import Bitwise
  require Logger
  alias SwarmCodeCLI.UI.{Capabilities, Paint, SceneSlot, SessionRuntime, Size}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.Renderer.RatatuiPort.{Decoder, Frame, Wire}
  @deadline 3_000
  # A paint the port has not confirmed after this long is answered to the
  # runtime as stale (it redraws later); only a much longer silence means the
  # terminal is gone.
  @draw_soft_ms 1_000
  @draw_hard_ms 60_000
  @kill_grace_ms 500

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

    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    unless Port.command(port, init, [:nosuspend]) do
      reap(port, os_pid)
      raise "terminal port refused its init command"
    end

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
       observer: Keyword.get(options, :observer),
       os_pid: os_pid,
       pending_replied?: false,
       queued: nil,
       last_plan: nil,
       draw_errors: MapSet.new()
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

  defp dispatch({:draw, token, revision}, %{phase: :running, pending: nil} = state),
    do: {:noreply, paint(state, token, revision)}

  # The runtime was answered early for a slow paint and asked again: keep only
  # the newest request and draw it once the port confirms the paint in flight.
  defp dispatch({:draw, token, revision}, %{phase: :running} = state) do
    if state.queued, do: stale(state, state.queued)
    {:noreply, %{state | queued: {token, revision}}}
  end

  defp dispatch({:draw, _, _}, state), do: {:noreply, state}

  defp dispatch({:terminal_control, :shutdown, runtime_token}, state) do
    state = state |> cancel() |> drop_queued()
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
    state = state |> cancel() |> drop_queued()
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

  defp dispatch({:deadline, identity, :draw}, %{timer: {_, identity}, pending: pending} = state)
       when pending != nil do
    {_, revision, token} = pending
    unless state.pending_replied?, do: stale(state, {token, revision})
    {:noreply, %{state | pending_replied?: true, timer: timer(:draw_hard, @draw_hard_ms)}}
  end

  defp dispatch({:deadline, identity, _}, %{timer: {_, identity}} = state),
    do: {:stop, :terminal_timeout, state}

  defp dispatch(:grant, state), do: {:noreply, grant(state)}

  defp dispatch({:plain_instruction, "Rerun with --plain"}, %{phase: :restored} = state) do
    IO.puts(
      "Run (cd apps/swarm_code_cli && MIX_QUIET=1 mise exec -- mix swarm_code.demo.plain --script complete)"
    )

    {:noreply, state}
  end

  defp dispatch(_, state), do: {:noreply, state}

  defp record({:resume_needed, 1}, %{phase: :running} = state) do
    if state.pending && not state.pending_replied? do
      {_, revision, token} = state.pending
      send(state.runtime, {:draw_result, token, revision, {:error, :stale_revision}})
    end

    state = state |> cancel() |> drop_queued()
    {token, state} = control(state, :resume)

    %{
      state
      | phase: :resuming,
        pending: nil,
        pending_replied?: false,
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

    unless state.pending_replied?,
      do: send(state.runtime, {:draw_result, token, revision, result})

    observe(state, {kind, revision})
    state = if state.phase == :running, do: cancel(state), else: state
    state = %{state | pending: nil, pending_replied?: false}

    case state do
      %{phase: :running, queued: {queued_token, queued_revision}} ->
        paint(%{state | queued: nil}, queued_token, queued_revision)

      _ ->
        grant(state)
    end
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

    %{
      cancel(state)
      | phase: :suspended,
        control: nil,
        pending: nil,
        pending_replied?: false,
        credit: nil
    }
  end

  defp record({:error, 1, code}, _)
       when code in [:protocol, :initialization, :draw, :read, :write, :restoration],
       do: throw({:terminal_error, code})

  defp record(_, _), do: raise("terminal protocol failed")

  defp feature(true), do: :best_effort
  defp feature(false), do: :unavailable

  # A credit that cannot be queued on a busy port is granted a moment later;
  # the token is only spent when the command was accepted.
  defp grant(%{phase: :running, credit: nil, pending: nil, input_enabled?: true} = state) do
    token = state.counter + 1
    {:ok, bytes} = Wire.control(:credit, 1, token)

    if Port.command(state.port, bytes, [:nosuspend]) do
      %{state | credit: token, counter: token}
    else
      Process.send_after(self(), :grant, 10)
      state
    end
  end

  defp grant(state), do: state

  defp control(state, operation) do
    token = state.counter + 1
    {:ok, bytes} = Wire.control(operation, 1, token)
    true = Port.command(state.port, bytes, [:nosuspend])
    {token, %{state | counter: token}}
  end

  defp paint(state, token, revision) do
    sequence = state.sequence + 1

    {result, state} = frame(state, revision, sequence)

    case result do
      {:ok, bytes, plan} ->
        if Port.command(state.port, bytes, [:nosuspend]) do
          %{
            state
            | sequence: sequence,
              pending: {sequence, revision, token},
              pending_replied?: false,
              timer: timer(:draw, @draw_soft_ms),
              input_enabled?: true,
              last_plan: plan
          }
          |> grant()
        else
          # A busy port: the runtime draws its latest state on the next frame.
          stale(state, {token, revision})
          grant(%{state | input_enabled?: true})
        end

      {:error, _stale_or_closed} ->
        stale(state, {token, revision})
        grant(%{state | input_enabled?: true})
    end
  end

  defp frame(state, revision, sequence) do
    case SceneSlot.fetch(state.slot, revision) do
      {:ok, scene} ->
        options = %Options{
          color_mode: state.caps.color_mode,
          ascii?: state.caps.ascii?,
          glyph_tier: state.caps.glyph_tier
        }

        case encode(fn -> Paint.build(scene, options) end, sequence) do
          {:ok, _bytes, _plan} = ok ->
            {ok, state}

          {:error, reason} ->
            state = note_draw_error(state, reason)
            {encode(fn -> {:ok, degraded(state.last_plan, scene, reason)} end, sequence), state}
        end

      error ->
        {error, state}
    end
  end

  defp encode(build, sequence) do
    with {:ok, plan} <- build.(),
         {:ok, bytes} <- Frame.encode(plan, sequence) do
      {:ok, bytes, plan}
    else
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _ -> {:error, :invalid_scene}
    end
  rescue
    _ -> {:error, :draw_exception}
  catch
    _, _ -> {:error, :draw_exception}
  end

  defp note_draw_error(state, reason) do
    if MapSet.member?(state.draw_errors, reason) do
      state
    else
      Logger.error("terminal frame could not be drawn (#{reason}); kept the previous frame")
      %{state | draw_errors: MapSet.put(state.draw_errors, reason)}
    end
  end

  # The previous frame (same size) with one error line on its last row, or a
  # blank frame with that line. Plain ASCII in reverse video is valid in every
  # colour mode and under both ambiguous-width policies.
  defp degraded(last, scene, reason) do
    %Size{columns: columns, rows: rows} = size = scene.size

    base =
      case last do
        %Plan{size: ^size} = plan -> plan
        _ -> blank(size, scene.ambiguous_width, last)
      end

    {palette, style} = error_style(base.palette)
    line = error_text(reason) |> String.slice(0, columns) |> String.pad_trailing(columns)
    offset = (rows - 1) * columns

    cells =
      line
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.reduce(base.cells, fn {char, x}, cells ->
        put_elem(cells, offset + x, {:glyph, char, 1, style})
      end)

    %Plan{
      base
      | revision: scene.revision,
        cells: cells,
        palette: palette,
        cursor: nil,
        focus: nil,
        actions: %{},
        diagnostics: []
    }
  end

  defp blank(%Size{columns: columns, rows: rows} = size, ambiguous_width, last) do
    %Plan{
      size: size,
      ambiguous_width: ambiguous_width,
      color_mode: if(last, do: last.color_mode, else: :monochrome),
      cells: List.to_tuple(List.duplicate({:glyph, " ", 1, 0}, columns * rows)),
      palette: {%{foreground: nil, background: nil, modifiers: []}}
    }
  end

  defp error_style(palette) do
    entry = %{foreground: nil, background: nil, modifiers: [:reversed]}
    list = Tuple.to_list(palette)

    case Enum.find_index(list, &(&1 == entry)) do
      nil when tuple_size(palette) < 4096 ->
        {Tuple.insert_at(palette, tuple_size(palette), entry), tuple_size(palette)}

      nil ->
        {palette, 0}

      index ->
        {palette, index}
    end
  end

  defp error_text(:capacity_exceeded),
    do: " This view is too large to draw. Press End or resize; the session keeps running. "

  defp error_text(_reason),
    do: " Part of this screen could not be drawn; the session keeps running. "

  defp stale(state, {token, revision}),
    do: send(state.runtime, {:draw_result, token, revision, {:error, :stale_revision}})

  defp drop_queued(%{queued: nil} = state), do: state

  defp drop_queued(state) do
    stale(state, state.queued)
    %{state | queued: nil}
  end

  defp timer(kind, ms \\ @deadline) do
    identity = make_ref()
    {Process.send_after(self(), {:deadline, identity, kind}, ms), identity}
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

      case await_exit(port, System.monotonic_time(:millisecond) + @deadline) do
        :exited -> :ok
        :timeout -> reap(port, state.os_pid)
      end
    end

    :ok
  end

  def terminate(_, _), do: :ok

  defp await_exit(port, deadline) do
    receive do
      {^port, {:exit_status, _}} -> :exited
      {^port, {:data, _}} -> await_exit(port, deadline)
      {:EXIT, ^port, _} -> await_exit(port, deadline)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> :timeout
    end
  end

  # rel F17: closing the port only closes the helper's stdin. A helper blocked
  # opening or restoring the tty of a vanished pty never reads that EOF, so it
  # is signalled: TERM (it restores the terminal and exits), then KILL.
  defp reap(port, os_pid) do
    if Port.info(port) do
      try do
        Port.close(port)
      rescue
        ArgumentError -> :ok
      end
    end

    if is_integer(os_pid) and alive?(os_pid) do
      signal(os_pid, "-TERM")
      deadline = System.monotonic_time(:millisecond) + @kill_grace_ms
      unless exited_by?(os_pid, deadline), do: signal(os_pid, "-KILL")
    end

    :ok
  end

  defp exited_by?(os_pid, deadline) do
    cond do
      not alive?(os_pid) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        receive do
        after
          20 -> exited_by?(os_pid, deadline)
        end
    end
  end

  defp alive?(os_pid), do: signal(os_pid, "-0") == 0

  defp signal(os_pid, flag) do
    {_, status} =
      System.cmd("/bin/kill", [flag, Integer.to_string(os_pid)], stderr_to_stdout: true)

    status
  rescue
    _ -> 1
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
