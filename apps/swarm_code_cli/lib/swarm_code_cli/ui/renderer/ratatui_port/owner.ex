defmodule SwarmCodeCLI.UI.Renderer.RatatuiPort.Owner do
  @moduledoc """
  Owns the guarded native terminal and only bounded transport correlations.

  A drawing problem never ends the session (pass70 B2): a scene that cannot be
  painted or encoded keeps the previous frame on screen with one error line on
  its last row (logged once per reason), a busy port answers the runtime
  `:stale_revision` so it draws the latest state on its next frame, and a slow
  paint is answered early and the next request is queued. The native helper's
  OS process never outlives this owner.

  cli020 R1/R2: a busy port never stops the owner either. A control (shutdown,
  suspend, resume, redraw, a mouse mode change) waits in a small outbox and is
  retried until the port takes it, bounded by the deadline of the phase it
  opened; a slow terminal (the helper waits for it) delays frames, and every
  draw request is still answered well inside the runtime's own deadline.
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
  # terminal is gone. cli020 R2: counted from the request and well below the
  # runtime's own draw deadline (`close_ms`: 1 s by default and in the dev live
  # session, 3 s in the release); a request queued behind a slow paint gets the
  # same bound, so a slow terminal slows the TUI and never ends it.
  @draw_soft_ms 400
  @draw_hard_ms 60_000
  @kill_grace_ms 500
  # cli020 R1: a busy port is tried again after this long (one timer at most).
  @busy_retry_ms 10

  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc """
  pass70 B10: puts `text` on the system clipboard through the terminal (OSC
  52), between frames. The renderer-neutral form is the message
  `{:terminal_copy, text}` to the terminal pid the runtime registered (the UI
  must not name this module); this function is that message plus caller-side
  validation. Asynchronous, so the runtime (which this owner calls) never
  waits on it. `{:error, :invalid_text}` for text the wire refuses: empty,
  over 64 KiB, invalid UTF-8, or a control other than LF and TAB. Terminals
  without OSC 52 ignore it; a suspended terminal drops it.
  """
  @spec copy(pid(), binary()) :: :ok | {:error, :invalid_text}
  def copy(owner, text) when is_pid(owner) do
    case Wire.copy(1, 0, text) do
      {:ok, _} ->
        send(owner, {:terminal_copy, text})
        :ok

      _ ->
        {:error, :invalid_text}
    end
  end

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
       # pass71 F4 (V's request I-2/S-2): the launcher decides the theme once
       # (`Theme.mode/2`: SWARM_THEME, else the desktop settings' mode).
       theme: Keyword.get(options, :theme, :dark),
       # cli020 M2 (E27): the palette (`terminal.palette`), Carbon by default.
       palette: Keyword.get(options, :palette, :carbon),
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
       # cli020 R2: the queued request's own soft deadline and arrival time.
       queued_timer: nil,
       queued_at: nil,
       # cli020 R1: controls waiting for a busy port, and whether the retry
       # timer runs.
       outbox: [],
       retry?: false,
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
    do: {:noreply, paint(state, token, revision, now())}

  # The runtime was answered early for a slow paint and asked again: keep only
  # the newest request and draw it once the port confirms the paint in flight.
  # cli020 R2: a queued request is answered stale after the soft deadline too
  # (the runtime asks again), so a terminal that stays slow never makes the
  # runtime's own draw deadline end the session.
  defp dispatch({:draw, token, revision}, %{phase: :running} = state) do
    state = drop_queued(state)

    {:noreply,
     %{
       state
       | queued: {token, revision},
         queued_timer: timer(:queued, @draw_soft_ms),
         queued_at: now()
     }}
  end

  defp dispatch({:draw, _, _}, state), do: {:noreply, state}

  # The control's token is filled in when the port takes it (cli020 R1).
  defp dispatch({:terminal_control, :shutdown, runtime_token}, state) do
    state = state |> cancel() |> drop_queued()

    {:noreply,
     control(
       %{
         state
         | phase: :closing,
           control: {:shutdown, nil, runtime_token},
           timer: timer(:shutdown)
       },
       :shutdown
     )}
  end

  defp dispatch(
         {:terminal_control, :suspend, generation},
         %{phase: :running, generation: generation} = state
       ) do
    state = state |> cancel() |> drop_queued()

    {:noreply,
     control(
       %{state | phase: :suspending, control: {:suspend, nil}, timer: timer(:suspend)},
       :suspend
     )}
  end

  defp dispatch({:terminal_control, :resume, _}, %{phase: :suspended} = state) do
    {:noreply,
     control(
       %{state | phase: :resuming, control: {:resume, nil}, timer: timer(:resume)},
       :resume
     )}
  end

  # cli020 D11: Ctrl-L. The native painter is invalidated and the next plan
  # is a full one.
  defp dispatch(
         {:terminal_control, :redraw, generation},
         %{phase: :running, generation: generation} = state
       ) do
    {:noreply, %{control(state, :redraw) | last_plan: nil}}
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

  defp dispatch({:deadline, identity, :queued}, %{queued_timer: {_, identity}} = state),
    do: {:noreply, drop_queued(state)}

  # cli020 R1: the port was busy; the waiting controls go first, then a
  # credit if one is due.
  defp dispatch(:busy_retry, state),
    do: {:noreply, %{state | retry?: false} |> flush() |> grant()}

  # A copy spends a control token only when the port accepted it.
  defp dispatch({:terminal_copy, text}, state) do
    {_result, next} = copy_text(state, text)
    {:noreply, next}
  end

  # pass70 F: the session runtime's acknowledged form (select mode's `y`). The
  # runtime waits for `{:terminal_copy_result, token, result}` to say whether
  # the copy left; a copy for an older terminal generation is refused.
  defp dispatch({:terminal_copy, generation, token, text}, state) do
    {result, next} =
      if generation == state.generation,
        do: copy_text(state, text),
        else: {{:error, :stale_generation}, state}

    send(state.runtime, {:terminal_copy_result, token, result})
    {:noreply, next}
  end

  # pass73 T2/T9 (K's `{:terminal_preferences, …}` effect, sent by the
  # session runtime): the theme applies from the next frame; wheel reports go
  # on or off through the port's mode command, and the flags change only when
  # the port took it, so the `ready` of a later resume agrees with them.
  defp dispatch({:terminal_preferences, preferences}, state) when is_map(preferences) do
    state = retheme(state, Map.get(preferences, :theme))
    state = repalette(state, Map.get(preferences, :palette))

    state =
      case Map.get(preferences, :mouse?) do
        on? when is_boolean(on?) -> set_mouse(state, on?)
        _ -> state
      end

    {:noreply, state}
  end

  # cli020 D3: a bell, an OSC 9 notification or the window title, between
  # frames (the session runtime's `{:bell, …}`, `{:notify_os, …}` and
  # `{:terminal_title, …}` effects). A text the wire refuses is dropped here,
  # never sent: the port would end the session on it.
  defp dispatch({:terminal_notify, kind, text}, %{port: port, phase: phase} = state)
       when port != nil and phase in [:running, :suspending, :suspended, :resuming] do
    token = state.counter + 1

    case Wire.notify(1, token, kind, text) do
      {:ok, bytes} ->
        if Port.command(port, bytes, [:nosuspend]),
          do: {:noreply, %{state | counter: token}},
          else: {:noreply, state}

      _ ->
        Logger.info("terminal notify refused: the text is too long or has controls")
        {:noreply, state}
    end
  end

  defp dispatch({:terminal_notify, _kind, _text}, state), do: {:noreply, state}

  defp dispatch({:plain_instruction, "Rerun with --plain"}, %{phase: :restored} = state) do
    IO.puts(
      "Run (cd apps/swarm_code_cli && MIX_QUIET=1 mise exec -- mix swarm_code.demo.plain --script complete)"
    )

    {:noreply, state}
  end

  defp dispatch(_, state), do: {:noreply, state}

  defp copy_text(%{phase: :running, port: port} = state, text) when port != nil do
    token = state.counter + 1

    case Wire.copy(1, token, text) do
      {:ok, bytes} ->
        if Port.command(port, bytes, [:nosuspend]) do
          {:ok, %{state | counter: token}}
        else
          Logger.info("clipboard copy dropped: the terminal was busy")
          {{:error, :busy}, state}
        end

      _ ->
        Logger.info("clipboard copy refused: the text is empty, too long or has controls")
        {{:error, :invalid_text}, state}
    end
  end

  defp copy_text(state, _text), do: {{:error, :unavailable}, state}

  # cli020 R1: a mode change is never dropped on a busy port; it waits in the
  # outbox, and a newer choice replaces one that has not left yet (back to
  # what the terminal has means nothing is left to send).
  defp set_mouse(%{port: port} = state, on?) when port != nil do
    state = %{state | outbox: Enum.reject(state.outbox, &match?({:mouse, _}, &1))}

    if Map.get(state.flags, :mouse?, false) == on?,
      do: state,
      else: control(state, {:mouse, on?})
  end

  defp set_mouse(state, _on?), do: state

  defp record({:resume_needed, 1}, %{phase: :running} = state) do
    if state.pending && not state.pending_replied? do
      {_, revision, token} = state.pending
      send(state.runtime, {:draw_result, token, revision, {:error, :stale_revision}})
    end

    state = state |> cancel() |> drop_queued()

    control(
      %{
        state
        | phase: :resuming,
          pending: nil,
          pending_replied?: false,
          credit: nil,
          input_enabled?: false,
          control: {:resume, nil},
          timer: timer(:resume)
      },
      :resume
    )
  end

  defp record({:ready, 1, size, bits}, state) do
    mouse? = Map.get(state.flags, :mouse?, false)
    # cli020 D2: the kitty keyboard protocol answered the port's probe.
    enhanced? = (bits &&& 128) != 0
    bits = bits &&& bnot(128)

    expected =
      if(state.flags.alternate?, do: 1, else: 0) ||| if(state.flags.focus?, do: 2, else: 0) |||
        if(state.flags.paste?, do: 4, else: 0) ||| if(mouse?, do: 16, else: 0)

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
        enhanced_keys: if(enhanced?, do: :supported, else: :unavailable),
        mouse: feature(mouse?)
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
        paint(cancel_queued(state), queued_token, queued_revision, state.queued_at)

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
  # the token is only spent when the command was accepted. Controls waiting
  # for the port go first (the retry grants after them).
  defp grant(
         %{phase: :running, credit: nil, pending: nil, input_enabled?: true, outbox: []} = state
       ) do
    token = state.counter + 1
    {:ok, bytes} = Wire.control(:credit, 1, token)

    if Port.command(state.port, bytes, [:nosuspend]) do
      observe(state, {:sent, :credit})
      %{state | credit: token, counter: token}
    else
      retry(state)
    end
  end

  defp grant(state), do: state

  # cli020 R1: a control changes the terminal's modes or closes it, so it is
  # never dropped and never crashes the owner on a busy port. It waits in the
  # outbox (at most one of each kind: a shutdown replaces everything still
  # waiting, a newer mouse change an older one) and the port is tried again
  # every @busy_retry_ms. Its token is taken when the port accepts it, so
  # tokens stay increasing whatever was sent in between, and the control the
  # owner awaits gets that token. The deadline of the phase it opened
  # (shutdown, suspend, resume) bounds the wait: `:terminal_timeout`.
  defp control(state, operation), do: state |> enqueue(operation) |> flush()

  defp enqueue(state, :shutdown), do: %{state | outbox: [:shutdown]}

  defp enqueue(state, {:mouse, _} = operation) do
    outbox = Enum.reject(state.outbox, &match?({:mouse, _}, &1))
    %{state | outbox: outbox ++ [operation]}
  end

  defp enqueue(state, operation) do
    if operation in state.outbox,
      do: state,
      else: %{state | outbox: state.outbox ++ [operation]}
  end

  defp flush(%{outbox: []} = state), do: state

  defp flush(%{outbox: [operation | rest]} = state) do
    token = state.counter + 1
    {:ok, bytes} = control_bytes(operation, token)

    if Port.command(state.port, bytes, [:nosuspend]) do
      observe(state, {:sent, operation})
      %{state | outbox: rest, counter: token} |> sent(operation, token) |> flush()
    else
      retry(state)
    end
  end

  defp control_bytes({:mouse, on?}, token), do: Wire.mouse(1, token, on?)
  defp control_bytes(operation, token), do: Wire.control(operation, 1, token)

  defp sent(%{control: {:shutdown, nil, runtime_token}} = state, :shutdown, token),
    do: %{state | control: {:shutdown, token, runtime_token}}

  defp sent(%{control: {kind, nil}} = state, kind, token) when kind in [:suspend, :resume],
    do: %{state | control: {kind, token}}

  defp sent(state, {:mouse, on?}, _token) do
    Logger.info("terminal wheel reports #{if on?, do: "on", else: "off"}")

    %{
      state
      | flags: Map.put(state.flags, :mouse?, on?),
        caps: %{state.caps | mouse: feature(on?)}
    }
  end

  defp sent(state, _operation, _token), do: state

  defp retry(%{retry?: true} = state), do: state

  defp retry(state) do
    Process.send_after(self(), :busy_retry, @busy_retry_ms)
    %{state | retry?: true}
  end

  # `received` is when the runtime asked (cli020 R2): the soft deadline counts
  # from there, not from the end of the paint build.
  defp paint(%{outbox: [_ | _]} = state, token, revision, _received) do
    # Controls wait for the busy port and go first: the runtime draws its
    # latest state on the next frame.
    stale(state, {token, revision})
    %{state | input_enabled?: true}
  end

  defp paint(state, token, revision, received) do
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
              timer: timer(:draw, max(@draw_soft_ms - (now() - received), 0)),
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
          glyph_tier: state.caps.glyph_tier,
          theme: state.theme,
          palette: state.palette
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

  # pass73 T2: `/theme` switches the palette live. A change drops the kept
  # frame, whose palette is the old theme's, so a degraded frame can never
  # repaint old colours; the port diffs cells by colour, so the next frame
  # (the runtime draws the state that changed) repaints every cell.
  defp retheme(state, theme) when theme in [:dark, :light] and theme != state.theme do
    Logger.info("terminal theme switched to #{theme}")
    %{state | theme: theme, last_plan: nil}
  end

  defp retheme(state, _theme), do: state

  # cli020 M2 (E27): the same for a palette (`/theme <palette>`).
  defp repalette(state, palette) when is_atom(palette) and palette != state.palette do
    if palette in SwarmCodeCLI.UI.Theme.palettes() do
      Logger.info("terminal palette switched to #{palette}")
      %{state | palette: palette, last_plan: nil}
    else
      state
    end
  end

  defp repalette(state, _palette), do: state

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
    cancel_queued(state)
  end

  defp cancel_queued(%{queued_timer: nil} = state), do: %{state | queued: nil, queued_at: nil}

  defp cancel_queued(%{queued_timer: {timer, _}} = state) do
    Process.cancel_timer(timer)
    %{state | queued: nil, queued_timer: nil, queued_at: nil}
  end

  defp now, do: System.monotonic_time(:millisecond)

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
      # cli020 R1: a helper that never took the shutdown (its port is busy:
      # it stopped reading) cannot restore by itself, so it is signalled at
      # once instead of being awaited; SIGTERM still restores the terminal.
      if state.phase == :restored or shutdown_now(port, state.counter + 1) do
        case await_exit(port, System.monotonic_time(:millisecond) + @deadline) do
          :exited -> :ok
          :timeout -> reap(port, state.os_pid)
        end
      else
        reap(port, state.os_pid)
      end
    end

    :ok
  end

  def terminate(_, _), do: :ok

  defp shutdown_now(port, token) do
    {:ok, shutdown} = Wire.control(:shutdown, 1, token)
    Port.command(port, shutdown, [:nosuspend])
  rescue
    ArgumentError -> false
  end

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
    |> redact_queue()
  end

  # cli74 (§3.11): messages still in the mailbox (a copy's text) stay out of
  # a crash report too.
  defp redact_queue(%{queue: _} = status), do: Map.put(status, :queue, [])
  defp redact_queue(status), do: status

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
