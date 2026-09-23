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
  require Logger

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

  alias SwarmCodeCLI.Companion
  alias SwarmCodeCLI.UI.DataSource
  alias SwarmCodeCLI.UI.DataSource.DataBridge

  # How long a terminal has to acknowledge a copy before it is taken as unable.
  @copy_ack_ms 1_000
  # How long a terminal has to step aside before Ctrl-X gives up.
  @suspend_ms 5_000
  # The edited draft is read back bounded like a paste (plus a final newline).
  @max_edit_bytes 262_144

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def register_terminal(server, terminal, generation, capabilities),
    do: GenServer.call(server, {:terminal, terminal, generation, capabilities})

  def input(server, input), do: GenServer.call(server, {:input, input})

  @doc "Trusted local semantic input. External delivery and renderer activation use their correlated routes."
  def action(server, action), do: GenServer.call(server, {:action, action})
  def activate(server, revision, id), do: GenServer.call(server, {:activate, revision, id})
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @doc "Names the companion sink (pid or nil) after start; it receives the current state at once."
  def attach_companion(server, companion),
    do: GenServer.call(server, {:attach_companion, companion})

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
    companion = Keyword.get(opts, :companion)

    if not (is_nil(companion) or is_pid(companion)),
      do: raise(ArgumentError, "invalid companion sink")

    push(companion, ui)
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
       wall_clock?: init.now == 0,
       close_ms: timeout,
       draw: :idle,
       frame_timer: nil,
       draw_deadline: nil,
       timers: %{},
       secret: make_ref(),
       sequence: 0,
       instruction_sink: Keyword.get(opts, :instruction_sink),
       companion: companion,
       final_pending?: false,
       close_kind: nil,
       shutdown_token: nil,
       close_timer: nil,
       copy: nil,
       # Ctrl-X: nil, or %{key, dir, file, task, timer} while the editor owns the terminal.
       edit: nil,
       editor: Keyword.get(opts, :editor, &__MODULE__.run_editor/1)
     }}
  end

  @impl true
  def handle_call(:snapshot, _, state), do: {:reply, state.ui, state}

  def handle_call({:attach_companion, companion}, _, state)
      when is_nil(companion) or is_pid(companion) do
    push(companion, state.ui)
    {:reply, :ok, %{state | companion: companion}}
  end

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
        {:external_edit_done, _, _} -> false
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

  def handle_info({:terminal_copy_result, token, result}, %{copy: {token, timer, lines}} = state) do
    cancel(timer)
    {:noreply, copy_notice(state, if(result == :ok, do: {:ok, lines}, else: result))}
  end

  def handle_info({:copy_timeout, token}, %{copy: {token, _, _}} = state),
    do: {:noreply, copy_notice(state, :timeout)}

  def handle_info({ref, result}, %{edit: %{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish_edit(state, result)}
  end

  def handle_info(
        {:DOWN, ref, :process, _, _},
        %{edit: %{task: %Task{ref: ref}}} = state
      ),
      do: {:noreply, finish_edit(state, {:error, :unavailable})}

  def handle_info({:edit_timeout, key}, %{edit: %{key: key, task: nil}} = state),
    do: {:noreply, finish_edit(state, {:error, :terminal})}

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
    next = if ui == state.ui, do: next, else: commit(next, state.ui)
    start_editor(next)
  end

  # Ctrl-X, second step: the terminal has stepped aside, so the editor runs
  # (owned by this process, linked and monitored) on the private copy.
  defp start_editor(%{edit: %{task: nil} = edit, ui: %{lifecycle: :suspended}} = state) do
    cancel(edit.timer)
    runner = state.editor
    file = edit.file

    task =
      Task.async(fn ->
        with :ok <- runner.(file), do: read_back(file)
      end)

    %{state | edit: %{edit | task: task, timer: nil}}
  end

  defp start_editor(state), do: state

  # The terminal comes back, the copy is removed, and the reducer gets the
  # text or the reason; whatever happened, the edit is over.
  defp finish_edit(%{edit: edit} = state, result) do
    cancel(edit.timer)

    if state.terminal,
      do: send(state.terminal, {:terminal_control, :resume, state.ui.terminal_generation})

    remove_edit(edit)

    result =
      if match?({:ok, _}, result) or match?({:error, _}, result),
        do: result,
        else: {:error, :unavailable}

    update(%{state | edit: nil}, {:external_edit_done, edit.key, result})
  end

  @doc false
  # Runs $VISUAL, else $EDITOR, else vi on `file`; the command may carry
  # arguments (`code -w`). A port child runs in a session of its own, so
  # `/dev/tty` is not there: with `:nouse_stdio` it inherits this VM's stdin
  # and stdout, the terminal itself (the native port reopens it the same way).
  def run_editor(file) do
    command =
      [System.get_env("VISUAL"), System.get_env("EDITOR")]
      |> Enum.map(&String.trim(&1 || ""))
      |> Enum.find("vi", &(&1 != ""))

    port =
      Port.open({:spawn_executable, ~c"/bin/sh"}, [
        :exit_status,
        :nouse_stdio,
        args: [
          "-c",
          ~s(exec $SWARM_EDIT_COMMAND "$1" 2>&1),
          "swarmcode-editor",
          file
        ],
        env: [{~c"SWARM_EDIT_COMMAND", String.to_charlist(command)}]
      ])

    receive do
      {^port, {:exit_status, 0}} -> :ok
      {^port, {:exit_status, status}} -> {:error, {:exit, min(max(status, 1), 255)}}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  defp read_back(file) do
    with {:ok, %{size: size}} when size <= @max_edit_bytes + 1 <- File.stat(file),
         {:ok, text} <- File.read(file) do
      # Editors end a file with a newline the draft never had.
      text = String.replace_suffix(text, "\n", "")

      cond do
        byte_size(text) > @max_edit_bytes -> {:error, :too_large}
        not String.valid?(text) -> {:error, :not_utf8}
        true -> {:ok, text}
      end
    else
      {:ok, _} -> {:error, :too_large}
      _ -> {:error, :unavailable}
    end
  end

  # A private directory (0700) holding one file (0600) with the draft.
  defp edit_copy(text) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "swarmcode-edit-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    file = Path.join(dir, "draft.md")

    with :ok <- File.mkdir(dir),
         :ok <- File.chmod(dir, 0o700),
         :ok <- File.write(file, text, [:exclusive]),
         :ok <- File.chmod(file, 0o600) do
      {:ok, dir, file}
    else
      _ ->
        File.rm_rf(dir)
        :error
    end
  end

  defp remove_edit(%{dir: dir}) when is_binary(dir), do: File.rm_rf(dir)
  defp remove_edit(_), do: :ok

  # Every state the terminal will see is also the companion's; the hub
  # coalesces, so this is one message per change and nothing more.
  defp commit(next, previous) do
    next = tick(next)
    push(next.companion, next.ui)

    next
    |> invalidate_generation(previous.terminal_generation)
    |> pause_frame()
    |> project()
    |> schedule()
  end

  # A live session reads the wall clock at every commit, so the tabs' elapsed
  # times move. A scripted session (a demo, a test) was given a fixed clock at
  # init and keeps it, or its golden output would change with the date.
  defp tick(%{wall_clock?: true} = state),
    do: %{state | ui: %{state.ui | now: System.system_time(:millisecond)}}

  defp tick(state), do: state

  defp push(nil, _ui), do: :ok

  defp push(companion, ui) when is_pid(companion) do
    send(companion, {:companion_state, ui})
    :ok
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

  # The palette's "Open visual companion": the reducer only emits, the runtime
  # opens the page and shows the URL through the existing feedback notice so it
  # can be copied even when no browser answers. No action carries free text, so
  # the notice value is written here, as the terminal generation already is.
  defp local_effect(%{phase: :running} = state, {:companion, :open}) do
    text =
      case Companion.url() do
        {:ok, url} ->
          case Companion.open() do
            :ok -> "Companion: " <> url
            {:error, _} -> "Companion: " <> url <> " (browser did not open)"
          end

        :unavailable ->
          "Companion is off (SWARM_COMPANION=0)"
      end

    ui = %{state.ui | notice: {:command_feedback, text}, revision: state.ui.revision + 1}
    commit(%{state | ui: ui}, state.ui)
  end

  # Select mode's `y`. The one terminal message that carries content: the
  # text the user asked to put on the clipboard, which the terminal writes as
  # OSC 52 and acknowledges with `{:terminal_copy_result, token, result}`. A
  # terminal that does not answer within a second cannot copy, and says so.
  defp local_effect(%{phase: :running, terminal: terminal} = state, {:copy, text})
       when is_pid(terminal) do
    token = identity()
    send(terminal, {:terminal_copy, state.ui.terminal_generation, token, text})
    timer = Process.send_after(self(), {:copy_timeout, token}, @copy_ack_ms)
    cancel(elem(state.copy || {nil, nil}, 1))
    lines = length(String.split(text, "\n"))
    %{state | copy: {token, timer, lines}}
  end

  defp local_effect(state, {:copy, _text}), do: copy_notice(state, :unsupported)

  # Ctrl-X, first step: a private copy of the draft, then the terminal is
  # asked to step aside; the editor starts once it has (`start_editor/1`).
  defp local_effect(
         %{phase: :running, terminal: terminal, edit: nil} = state,
         {:edit_externally, key, text}
       )
       when is_pid(terminal) do
    case edit_copy(text) do
      {:ok, dir, file} ->
        send(terminal, {:terminal_control, :suspend, state.ui.terminal_generation})
        timer = Process.send_after(self(), {:edit_timeout, key}, @suspend_ms)
        %{state | edit: %{key: key, dir: dir, file: file, task: nil, timer: timer}}

      :error ->
        update(state, {:external_edit_done, key, {:error, :unavailable}})
    end
  end

  defp local_effect(%{edit: nil} = state, {:edit_externally, key, _text}),
    do: update(state, {:external_edit_done, key, {:error, :terminal}})

  defp local_effect(state, {:edit_externally, key, _text}),
    do: update(state, {:external_edit_done, key, {:error, :busy}})

  # Announcements already live in the safe Scene; no text is sent to terminal state.
  defp local_effect(state, _), do: state

  defp copy_notice(state, result) do
    text =
      case result do
        {:ok, 1} ->
          "Copied 1 line."

        {:ok, lines} ->
          "Copied #{lines} lines."

        {:error, :invalid_text} ->
          "Not copied: the text is over 64 KiB or has control characters."

        _ ->
          "This terminal cannot take a copy from SwarmCode."
      end

    ui = %{state.ui | notice: {:command_feedback, text}, revision: state.ui.revision + 1}
    commit(%{state | ui: ui, copy: nil}, state.ui)
  end

  defp project(state) do
    {scene, table} = Projector.project(state.ui)

    case SceneSlot.put(state.slot, scene) do
      :ok ->
        %{state | table: table}

      _ ->
        explain_invalid_scene(scene, state.instruction_sink)
        begin_shutdown(state, :invalid_scene)
    end
  end

  # A close the user did not ask for is said in plain words; a session that
  # vanishes with exit 0 cannot be reported, let alone fixed. A launcher with
  # an instruction sink (the packaged `swarmcode`) gets the words and prints
  # them after the terminal is restored, with a failure exit status (pass70
  # B3); the details go to the log. Without a sink they go to stderr.
  defp report_shutdown(kind, sink) do
    case shutdown_kind(kind) do
      nil ->
        :ok

      base when is_pid(sink) ->
        Logger.error("session closed: #{inspect(kind, limit: 40)}")
        send(sink, {:session_closed, shutdown_words(base)})

      base ->
        detail =
          case kind do
            {:draw_failed, result} -> ": " <> inspect(result, limit: 40)
            _ -> ""
          end

        IO.puts(
          :stderr,
          "swarmcode: the session closed: " <> shutdown_words(base) <> detail <> "."
        )
    end
  end

  defp shutdown_kind({:draw_failed, _}), do: :draw_failed

  defp shutdown_kind(kind)
       when kind in [
              :binding_failed,
              :draw_failed,
              :source_unavailable,
              :terminal_unavailable,
              :invalid_scene
            ],
       do: kind

  defp shutdown_kind(_kind), do: nil

  defp shutdown_words(:binding_failed), do: "the terminal could not be bound"
  defp shutdown_words(:draw_failed), do: "a frame could not be drawn"
  defp shutdown_words(:source_unavailable), do: "the daemon connection closed"
  defp shutdown_words(:terminal_unavailable), do: "the terminal port went away"
  defp shutdown_words(:invalid_scene), do: "the screen failed validation"

  # A scene the slot refuses closes the session; saying why on stderr is the
  # difference between a bug report and a silent exit. With SWARM_SCENE_DUMP
  # set the scene is written there as an Erlang term for inspection.
  defp explain_invalid_scene(scene, sink) do
    bytes = safe_size(scene)

    text =
      "the screen failed validation " <>
        "(valid: #{inspect(match?(:ok, SwarmCodeCLI.UI.Scene.validate(scene)))}, " <>
        "bytes: #{bytes}, size: #{inspect(Map.get(scene, :size))})"

    if is_pid(sink),
      do: Logger.error("session closed: " <> text),
      else: IO.puts(:stderr, "swarmcode: the session closed: " <> text <> ".")

    case System.get_env("SWARM_SCENE_DUMP") do
      path when is_binary(path) and path != "" ->
        File.write(path, :erlang.term_to_binary(scene))
        IO.puts(:stderr, "Scene written to #{path}.")

      _ ->
        :ok
    end
  end

  defp safe_size(scene) do
    :erlang.external_size(scene)
  rescue
    _ -> -1
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
        result != :ok -> begin_shutdown(next, {:draw_failed, result})
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

    {:ok, detached} =
      SafeText.external(
        if(kind == :plain, do: "Leaving the full-screen view.", else: "Closing SwarmCode."),
        SafeText.Limits.content()
      )

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
    report_shutdown(kind, state.instruction_sink)
    kind = if match?({:draw_failed, _}, kind), do: :draw_failed, else: kind
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
    if state.edit && state.edit.task, do: Task.shutdown(state.edit.task, :brutal_kill)
    remove_edit(state.edit)
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
