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

  alias SwarmCodeCLI.UI.OsCommand
  alias SwarmCodeCLI.UI.Reducer.ImagePaste
  alias SwarmCodeCLI.Companion
  alias SwarmCodeCLI.UI.Init.{Preferences, PrefsQueue}
  alias SwarmCodeCLI.UI.DataSource
  alias SwarmCodeCLI.UI.DataSource.DataBridge

  # How long a terminal has to acknowledge a copy before it is taken as unable.
  @copy_ack_ms 1_000
  # How long a terminal has to step aside before Ctrl-X gives up.
  @suspend_ms 5_000
  # The edited draft is read back bounded like a paste (plus a final newline).
  @max_edit_bytes 262_144
  # cli74: how long the desktop has to open a folder (`o` in Settings).
  @folder_ms 5_000
  # cli020 D4: pbcopy's bounds; the terminal clipboard (OSC 52) takes 64 KiB.
  @max_scene_failures 5
  @image_ms 25_000
  @osascript_ms 5_000
  @sips_ms 10_000
  @copy_ms 5_000
  @max_pbcopy 1_048_576
  @max_osc_copy 65_536
  # cli020 D3: how long an OS notification (osascript) may take.
  @notify_ms 5_000
  # cli020 D3: terminals that show OSC 9 as a notification (`terminal.notify
  # auto`); any other gets the bell.
  @osc9_terminals ["iTerm.app", "ghostty", "WezTerm"]

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
       # pass70 Q2: a launcher that reads the clock says so (`wall_clock:
       # true`); inferring it from a zero `init.now` left the release, which
       # starts from the real time, on a clock stopped at launch.
       wall_clock?: Keyword.get(opts, :wall_clock, init.now == 0),
       # Only a launcher that asked for the wall clock repaints on the clock.
       ticking?: Keyword.get(opts, :wall_clock, false) == true,
       clock_timer: nil,
       # pass70 Q4: a typed key is being applied without projecting it
       # (`lazy?`); the scene and table are behind the state (`dirty?`).
       lazy?: false,
       dirty?: false,
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
       editor: Keyword.get(opts, :editor, &__MODULE__.run_editor/1),
       # cli74: nil, or %{task, timer, generation} while the desktop opens a
       # folder for the settings layer.
       folder: nil,
       # pass72-O: the CLI preferences file (`:preferences_path`; nil keeps
       # the panel's mode in memory only). cli74: every read and write of it
       # is a job of one FIFO (`Init.PrefsQueue`, at most 32) run one at a
       # time in a task this process owns.
       prefs:
         start_preferences(Keyword.get_lazy(opts, :preferences_path, &default_preferences/0)),
       # cli020 lane D: the owned external work (the OS notification, pbcopy,
       # the clipboard image) runs in tasks of this supervisor, one entry per
       # task in `jobs` (ref => %{kind, task, timer}), each with a deadline.
       jobs_sup: start_jobs(),
       jobs: %{},
       # cli020 D12: the projector (a test injects a failing one) and the
       # failed screen updates in a row.
       projector: Keyword.get(opts, :projector, &Projector.project/1),
       scene_failures: 0,
       # cli020 D9: the slot token of the image paste in flight; a job
       # result for another token is stale and deletes its file.
       image_token: nil,
       # The facts of the machine the runtime reads once (a test injects them):
       # `TERM_PROGRAM`, the OS, and the environment the copy and the image
       # paste look at (`SSH_CONNECTION`, `TMUX`).
       term_program:
         Keyword.get_lazy(opts, :term_program, fn -> System.get_env("TERM_PROGRAM") end),
       os_type: Keyword.get_lazy(opts, :os_type, &:os.type/0),
       env: Keyword.get_lazy(opts, :env, &System.get_env/0),
       # How an external command runs: `OsCommand.run/3`, or a test's stub.
       command_runner: Keyword.get(opts, :command_runner, &OsCommand.run/3)
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

  # pass70 Q4: plain typing is applied at once and projected with the next
  # frame, so a burst of keys costs one projection per frame instead of one
  # per key (40 typed characters took ~5 s in the release). Any other key
  # needs the action table of what is on screen, so a pending projection is
  # made first.
  def handle_call({:input, input}, _, %{phase: :running} = state) do
    if Keymap.typing?(input, state.ui) do
      state = %{state | lazy?: true}
      next = resolved(state, Keymap.resolve(input, state.ui, state.table))
      {:reply, :ok, %{next | lazy?: false}}
    else
      state = projected(state)
      {:reply, :ok, resolved(state, Keymap.resolve(input, state.ui, state.table))}
    end
  end

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
        {:paste_image_done, _, _, _} -> false
        _ -> true
      end

    {:reply, :ok, if(allowed, do: update(state, action), else: state)}
  end

  def handle_call({:activate, revision, id}, _, %{phase: :running} = state) do
    state = projected(state)

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

  def handle_info({:clock, id}, %{phase: :running, clock_timer: {id, _}} = state) do
    state = %{state | clock_timer: nil}

    if time_dependent?(state.ui),
      do:
        {:noreply, commit(%{state | ui: %{state.ui | revision: state.ui.revision + 1}}, state.ui)},
      else: {:noreply, state}
  end

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

  def handle_info({ref, result}, %{prefs: %{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, preferences_done(state, result)}
  end

  def handle_info({ref, result}, %{folder: %{task: %Task{ref: ref}}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, folder_done(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{folder: %{task: %Task{ref: ref}}} = state),
    do: {:noreply, folder_done(state, {:error, :failed})}

  def handle_info({:folder_timeout, ref}, %{folder: %{task: %Task{ref: ref} = task}} = state) do
    Task.shutdown(task, :brutal_kill)
    {:noreply, folder_done(state, {:error, :timeout})}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{prefs: %{task: %Task{ref: ref}}} = state),
    do: {:noreply, preferences_done(state, {:error, :crashed})}

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

  # cli020 lane D: an owned job answered, crashed or ran out of time.
  def handle_info({ref, result}, %{jobs: jobs} = state) when is_map_key(jobs, ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, job_done(state, ref, {:ok, result})}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{jobs: jobs} = state)
      when is_map_key(jobs, ref),
      do: {:noreply, job_done(state, ref, {:error, :crashed})}

  def handle_info({:job_timeout, ref}, %{jobs: jobs} = state) when is_map_key(jobs, ref) do
    %{task: task} = Map.fetch!(jobs, ref)
    Task.Supervisor.terminate_child(state.jobs_sup, task.pid)
    Process.demonitor(ref, [:flush])
    {:noreply, job_done(state, ref, {:error, :timeout})}
  end

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
      do: {:noreply, source_lost(state, "the data source announced it closed")}

  def handle_info({:swarm_code_ui_data, _, receipt, _} = envelope, %{phase: :running} = state) do
    case DataBridge.normalize(envelope, state.ui.source_epoch) do
      {:ok, action} ->
        next = update(state, action)

        case consume(state.data_source, receipt, :applied) do
          :ok -> {:noreply, next}
          other -> {:noreply, source_lost(next, "consume answered #{inspect(other, limit: 8)}")}
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
        {:noreply, source_lost(state, "the data source process went down")}

      state.binder != nil and monitor == elem(state.binder, 1) ->
        {:noreply, begin_shutdown(state, :binding_failed)}

      true ->
        {:noreply, state}
    end
  end

  # cli020 D12: the one re-projection after a failed screen update.
  def handle_info(:reproject, %{phase: :running} = state),
    do: {:noreply, state |> project() |> schedule()}

  def handle_info(:reproject, state), do: {:noreply, state}

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
    :exit, reason -> {:error, {:exit, exit_kind(reason)}}
  end

  # pass72 F (P's request 3): a session that closes because the data source
  # went away says why in cli.log; the reason is a shape, never a payload.
  defp source_lost(state, why) do
    Logger.warning("data source lost: " <> why)
    begin_shutdown(state, :source_unavailable)
  end

  defp exit_kind({:timeout, _}), do: :timeout
  defp exit_kind({:noproc, _}), do: :noproc
  defp exit_kind({:nodedown, _}), do: :nodedown
  defp exit_kind({reason, _}) when is_atom(reason), do: reason
  defp exit_kind(reason) when is_atom(reason), do: reason
  defp exit_kind(_), do: :other

  defp update(%{ui: %{lifecycle: :closing}} = state, _), do: state

  defp update(state, action) do
    # The reducer stamps what it shows with the owner's clock (a notice's
    # appearance, pass70 Q2), so a wall-clock session reads it first.
    state = tick(state)
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
    runner = editor_runner(state)
    file = edit.file
    # A draft never ends in the newline editors add; a settings file keeps
    # its bytes exactly.
    strip? = not match?({:settings, _, _}, edit.key)

    task =
      Task.async(fn ->
        with :ok <- runner.(file), do: read_back(file, strip?)
      end)

    %{state | edit: %{edit | task: task, timer: nil}}
  end

  defp start_editor(state), do: state

  # cli74: `terminal.editor` (cli.json's "editor") comes before VISUAL and
  # EDITOR; a runner injected by a test is used as it is.
  defp editor_runner(%{editor: editor, ui: ui}) do
    if editor == (&__MODULE__.run_editor/1),
      do: &run_editor(&1, Map.get(ui.prefs, "editor")),
      else: editor
  end

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

    case edit.key do
      {:settings, generation, ref} ->
        update(%{state | edit: nil}, {:settings, {:external_result, generation, ref, result}})

      key ->
        update(%{state | edit: nil}, {:external_edit_done, key, result})
    end
  end

  @doc false
  # Runs $VISUAL, else $EDITOR, else vi on `file`; the command may carry
  # arguments (`code -w`). A port child runs in a session of its own, so
  # `/dev/tty` is not there: with `:nouse_stdio` it inherits this VM's stdin
  # and stdout, the terminal itself (the native port reopens it the same way).
  def run_editor(file, preferred \\ nil) do
    command =
      [preferred, System.get_env("VISUAL"), System.get_env("EDITOR")]
      |> Enum.map(&String.trim(&1 || ""))
      |> Enum.find("vi", &(&1 != ""))

    port =
      Port.open({:spawn_executable, ~c"/bin/sh"}, [
        :exit_status,
        :nouse_stdio,
        args: [
          "-c",
          ~s(exec $SWARM_EDIT_COMMAND "$1" 2>&1),
          "ncode-editor",
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

  defp read_back(file, strip?) do
    with {:ok, %{size: size}} when size <= @max_edit_bytes + 1 <- File.stat(file),
         {:ok, text} <- File.read(file) do
      # Editors end a file with a newline the draft never had.
      text = if strip?, do: String.replace_suffix(text, "\n", ""), else: text

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
  defp edit_copy(text, name \\ "draft.md") do
    dir =
      Path.join(
        System.tmp_dir!(),
        "ncode-edit-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    file = Path.join(dir, name)

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
    |> project_or_defer()
    |> schedule()
    |> clock()
  end

  defp project_or_defer(%{lazy?: true} = state), do: %{state | dirty?: true}
  defp project_or_defer(state), do: project(state)

  # The scene and table of the latest state, projected now if a typed key
  # deferred it.
  defp projected(%{dirty?: true} = state), do: project(state)
  defp projected(state), do: state

  # pass70 Q2: what the screen says about time (a live run's elapsed clock, a
  # toast that fades after a few seconds) changes while nothing else does, so
  # a wall-clock session repaints once a second while any of it is on screen,
  # and not at all when idle.
  @clock_ms 1_000
  @toast_window_ms 8_000
  @live_run_states [
    :queued,
    :running,
    :streaming,
    :waiting_question,
    :waiting_approval,
    :paused,
    :retrying
  ]

  defp clock(%{ticking?: true, wall_clock?: true, phase: :running, clock_timer: nil} = state) do
    if time_dependent?(state.ui) do
      id = make_ref()
      %{state | clock_timer: {id, Process.send_after(self(), {:clock, id}, @clock_ms)}}
    else
      state
    end
  end

  defp clock(state), do: state

  @doc false
  def time_dependent?(%{lifecycle: :running, read_model: model, now: now} = ui) do
    Enum.any?(model.runs, fn {_, run} -> run.state in @live_run_states end) or
      SwarmCodeCLI.UI.State.fading_notice?(ui) or settings_ticking?(ui) or
      case Map.get(model, :toasts, []) do
        [%{at: at} | _] when is_integer(at) and is_integer(now) -> now - at < @toast_window_ms
        _ -> false
      end
  end

  def time_dependent?(_ui), do: false

  # cli74 §4.9: an open settings layer repaints each second only while a
  # task it shows is running, a write is saving or a toast is fading.
  defp settings_ticking?(%{settings: %SwarmCodeCLI.UI.Settings.Layer{} = layer, now: now}) do
    Enum.any?(layer.tasks, fn {_id, task} -> SwarmCodeCLI.UI.Settings.Tasks.running?(task) end) or
      Enum.any?(layer.writes, fn {_key, write} -> Map.get(write, :saving?) == true end) or
      case layer.status do
        %{at: at, ms: ms} when is_integer(at) and is_integer(now) -> now - at < ms
        _ -> false
      end
  end

  defp settings_ticking?(_ui), do: false

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
    note_resyncs(state.ui, emitted)

    Enum.each(emitted, fn effect ->
      EffectRunner.run(effect, %{
        data_source: state.data_source,
        owner: self(),
        source_epoch: state.ui.source_epoch,
        local: fn value -> send(self(), {:owned_effect, state.secret, value}) end
      })
    end)
  end

  # pass73 G2 (QA Q2-05): a resync the client asks for (a sequence gap, a
  # delta the read model cannot apply, a window past its bound) says so in
  # cli.log, as the daemon's own requests for one already do.
  @resync_words %{
    gap: "a delta arrived out of order",
    snapshot_required: "a delta needed the whole snapshot",
    overflow: "the window outgrew its bound",
    unbounded: "the snapshot outgrew its bound",
    retry: "a retry"
  }

  defp note_resyncs(ui, emitted) do
    for {:query, %{kind: {:resync_watch, ref}}} <- emitted,
        {slot, %{watch_ref: ^ref} = watch} <- ui.watches do
      why = Map.get(@resync_words, Map.get(watch, :resync_reason), "a retry")
      Logger.info("SwarmCode: asked the daemon for a fresh #{slot} snapshot (#{why})")
    end

    :ok
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

  # cli020 D11: the port forgets what it painted; the next frame (asked at
  # once) repaints every cell.
  defp local_effect(%{terminal: terminal} = state, {:terminal_control, :redraw})
       when is_pid(terminal) do
    send(terminal, {:terminal_control, :redraw, state.ui.terminal_generation})
    commit(%{state | ui: %{state.ui | revision: state.ui.revision + 1}}, state.ui)
  end

  defp local_effect(state, {:terminal_control, :redraw}), do: state

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

    state = tick(state)

    ui = %{
      state.ui
      | notice: {:command_feedback, text},
        notice_at: state.ui.now,
        revision: state.ui.revision + 1
    }

    commit(%{state | ui: ui}, state.ui)
  end

  # Select mode's `y`. cli020 D4: on macOS outside SSH the text goes to
  # `/usr/bin/pbcopy` in an owned job (at most 1 MiB, 5 s), which really
  # copies; elsewhere, or when pbcopy fails, through the terminal (OSC 52).
  defp local_effect(%{phase: :running} = state, {:copy, text}) do
    lines = length(String.split(text, "\n"))

    if pbcopy?(state, text) do
      runner = state.command_runner
      start_job(state, {:copy, lines, text}, fn -> pbcopy(runner, text) end, @copy_ms)
    else
      osc_copy(state, text, lines)
    end
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

  # cli74: the external editor on a settings text or file. The same private
  # copy and the same terminal hand-over as Ctrl-X in the composer; the
  # answer goes to the settings layer that asked, by generation and ref.
  defp local_effect(
         %{phase: :running, terminal: terminal, edit: nil} = state,
         {:settings_external_edit, generation, ref, %{content: content, suffix: suffix}}
       )
       when is_pid(terminal) do
    key = {:settings, generation, ref}

    case edit_copy(content, "edit" <> suffix) do
      {:ok, dir, file} ->
        send(terminal, {:terminal_control, :suspend, state.ui.terminal_generation})
        timer = Process.send_after(self(), {:edit_timeout, key}, @suspend_ms)
        %{state | edit: %{key: key, dir: dir, file: file, task: nil, timer: timer}}

      :error ->
        update(state, {:settings, {:external_result, generation, ref, {:error, :unavailable}}})
    end
  end

  defp local_effect(%{edit: nil} = state, {:settings_external_edit, generation, ref, _spec}),
    do: update(state, {:settings, {:external_result, generation, ref, {:error, :terminal}}})

  defp local_effect(state, {:settings_external_edit, generation, ref, _spec}),
    do: update(state, {:settings, {:external_result, generation, ref, {:error, :busy}}})

  # cli74: `o` on a folder or path row. The desktop opens it in a task this
  # process owns, bounded by a timer; one at a time.
  defp local_effect(%{folder: nil} = state, {:settings_open_folder, generation, path}) do
    task = Task.async(fn -> open_folder(path) end)
    timer = Process.send_after(self(), {:folder_timeout, task.ref}, @folder_ms)
    %{state | folder: %{task: task, timer: timer, generation: generation}}
  end

  defp local_effect(state, {:settings_open_folder, generation, _path}),
    do: update(state, {:settings, {:folder_result, generation, {:error, :busy}}})

  # pass73-K, cli74: every cli.json read and write is one job of the
  # preference queue; the legacy saves write only the keys they change.
  defp local_effect(state, {:save_preferences, wanted}),
    do: enqueue(%{state | prefs: %{state.prefs | changed?: true}}, {:legacy, wanted})

  defp local_effect(state, {:settings_cli_read, generation}),
    do: enqueue(state, {:read, generation})

  defp local_effect(state, {:settings_cli_write, generation, ref, changes, expected}),
    do: enqueue(state, {:write, generation, ref, changes, expected})

  defp local_effect(state, {:settings_cli_write_text, generation, ref, text, fingerprint}),
    do: enqueue(state, {:write_text, generation, ref, text, fingerprint})

  # pass73-K (T2, T9): the terminal's owner repaints in the other theme or
  # turns wheel reports on or off; an owner that does not know the message
  # ignores it.
  # The frame that shows the change is asked for after the message, so the
  # owner paints it with the new theme (both go from this process, in order).
  defp local_effect(%{terminal: terminal} = state, {:terminal_preferences, preferences})
       when is_pid(terminal) do
    send(terminal, {:terminal_preferences, preferences})
    commit(%{state | ui: %{state.ui | revision: state.ui.revision + 1}}, state.ui)
  end

  # cli020 D3: the needs-you signal. `terminal.notify` picks how it shows:
  # the bell (BEL), OSC 9 (a terminal notification), the OS notification
  # centre (osascript, macOS) or nothing; `auto` is OSC 9 on the terminals
  # that show it, else the bell. The reducer sends the bell and the words; the
  # mode decides which of the two goes out.
  defp local_effect(%{terminal: terminal} = state, {:bell, _kind}) when is_pid(terminal) do
    if notify_mode(state) == :bell, do: send(terminal, {:terminal_notify, :bell, ""})
    state
  end

  defp local_effect(%{terminal: terminal} = state, {:notify_os, text}) when is_pid(terminal) do
    words = SafeText.value(text)

    case notify_mode(state) do
      :osc9 ->
        send(terminal, {:terminal_notify, :notification, words})
        state

      :os ->
        runner = state.command_runner

        start_job(
          state,
          :notify_os,
          fn -> runner.("/usr/bin/osascript", os_notification_args(words), @notify_ms) end,
          @notify_ms
        )

      _ ->
        state
    end
  end

  # cli020 D3: the window title (`terminal.title on`); the port saves the
  # terminal's own title first and restores it at exit.
  defp local_effect(%{terminal: terminal} = state, {:terminal_title, text})
       when is_pid(terminal) do
    send(terminal, {:terminal_notify, :title, SafeText.value(text)})
    state
  end

  # cli020 D9: Ctrl-V. Only a Mac's own clipboard has the image; the slot
  # comes from the daemon (the reducer asks), then an owned job writes it.
  defp local_effect(%{phase: :running} = state, {:paste_image, conversation}) do
    cond do
      state.os_type != {:unix, :darwin} ->
        runtime_notice(state, ImagePaste.words(:not_macos))

      present?(Map.get(state.env, "SSH_CONNECTION")) ->
        runtime_notice(state, ImagePaste.words(:ssh))

      true ->
        update(state, {:paste_image_slot, conversation})
    end
  end

  defp local_effect(
         %{phase: :running} = state,
         {:paste_image_write, conversation, token, path}
       ) do
    runner = state.command_runner

    start_job(
      %{state | image_token: token},
      {:paste_image, conversation, token, path},
      fn -> clipboard_image(runner, path) end,
      @image_ms
    )
  end

  # Announcements already live in the safe Scene; no text is sent to terminal state.
  defp local_effect(state, _), do: state

  # --------------------------------------------- cli020 lane D: owned jobs

  defp start_jobs do
    {:ok, supervisor} = Task.Supervisor.start_link()
    supervisor
  end

  defp start_job(state, kind, fun, timeout) do
    task = Task.Supervisor.async_nolink(state.jobs_sup, fun)
    timer = Process.send_after(self(), {:job_timeout, task.ref}, timeout + 500)
    %{state | jobs: Map.put(state.jobs, task.ref, %{kind: kind, task: task, timer: timer})}
  end

  defp job_done(state, ref, result) do
    {job, jobs} = Map.pop(state.jobs, ref)
    cancel(job.timer)
    job_result(%{state | jobs: jobs}, job.kind, result)
  end

  defp job_result(state, :notify_os, {:ok, {:ok, 0, _}}), do: state

  defp job_result(state, :notify_os, result) do
    Logger.info("SwarmCode: the OS notification was not shown (#{inspect(result, limit: 4)})")
    state
  end

  # cli020 D4: pbcopy took it; otherwise the terminal is asked instead.
  defp job_result(state, {:copy, lines, _text}, {:ok, {:ok, 0, _}}),
    do: copy_notice(state, {:copied, lines})

  defp job_result(state, {:copy, lines, text}, _result), do: osc_copy(state, text, lines)

  # cli020 D9: the image is on disk (or not); a result for a paste that is
  # no longer the one in flight deletes its file.
  defp job_result(state, {:paste_image, conversation, token, path}, result) do
    outcome =
      case result do
        {:ok, :ok} -> :ok
        {:ok, {:error, :no_image}} -> {:error, :no_image}
        _ -> {:error, :failed}
      end

    cond do
      state.image_token != token ->
        File.rm(path)
        state

      true ->
        if outcome != :ok, do: File.rm(path)
        update(%{state | image_token: nil}, {:paste_image_done, conversation, token, outcome})
    end
  end

  defp job_result(state, _kind, _result), do: state

  @doc false
  # cli020 D9: writes the clipboard's image as PNG to `path` (macOS only):
  # PNG as it is, TIFF converted by `sips`; `{:error, :no_image}` when the
  # clipboard has neither. Every failure deletes what it wrote.
  def clipboard_image(runner, path) do
    tiff = path <> ".tiff"

    result =
      case runner.("/usr/bin/osascript", ["-e", "clipboard info"], @osascript_ms) do
        {:ok, 0, info} ->
          cond do
            String.contains?(info, "PNGf") -> write_clipboard(runner, "PNGf", path)
            String.contains?(info, "TIFF") -> clipboard_tiff(runner, tiff, path)
            true -> {:error, :no_image}
          end

        _ ->
          {:error, :failed}
      end

    File.rm(tiff)
    if result != :ok, do: File.rm(path)
    result
  end

  defp clipboard_tiff(runner, tiff, path) do
    with :ok <- write_clipboard(runner, "TIFF", tiff),
         {:ok, 0, _} <-
           runner.("/usr/bin/sips", ["-s", "format", "png", tiff, "--out", path], @sips_ms) do
      :ok
    else
      _ -> {:error, :failed}
    end
  end

  defp write_clipboard(runner, class, path) do
    args = [
      "-e",
      "on run argv",
      "-e",
      "set f to open for access (POSIX file (item 1 of argv)) with write permission",
      "-e",
      "set eof f to 0",
      "-e",
      "write (the clipboard as «class #{class}») to f",
      "-e",
      "close access f",
      "-e",
      "end run",
      path
    ]

    case runner.("/usr/bin/osascript", args, @osascript_ms) do
      {:ok, 0, _} -> :ok
      _ -> {:error, :failed}
    end
  end

  # The one terminal message that carries content: the text the user asked
  # to put on the clipboard, which the terminal writes as OSC 52 (inside tmux
  # through its passthrough) and acknowledges with `{:terminal_copy_result,
  # token, result}`. A terminal that does not answer within a second cannot
  # copy, and says so. OSC 52 carries at most 64 KiB.
  defp osc_copy(state, text, _lines) when byte_size(text) > @max_osc_copy,
    do: copy_notice(state, :too_large)

  defp osc_copy(%{terminal: terminal} = state, text, lines) when is_pid(terminal) do
    token = identity()
    send(terminal, {:terminal_copy, state.ui.terminal_generation, token, text})
    timer = Process.send_after(self(), {:copy_timeout, token}, @copy_ack_ms)
    cancel(elem(state.copy || {nil, nil}, 1))
    %{state | copy: {token, timer, lines}}
  end

  defp osc_copy(state, _text, _lines), do: copy_notice(state, :unsupported)

  defp pbcopy?(state, text) do
    state.os_type == {:unix, :darwin} and not present?(Map.get(state.env, "SSH_CONNECTION")) and
      byte_size(text) <= @max_pbcopy
  end

  @doc false
  # cli020 D4: `pbcopy` reads the text from a private copy (0600 in a 0700
  # folder, removed afterwards): an Erlang port cannot close the stdin of the
  # program it runs while still waiting for its exit status.
  def pbcopy(runner, text) do
    case edit_copy(text, "copy.txt") do
      {:ok, dir, file} ->
        try do
          runner.(
            "/bin/sh",
            ["-c", ~s(exec /usr/bin/pbcopy < "$1"), "ncode-copy", file],
            @copy_ms
          )
        after
          File.rm_rf(dir)
        end

      :error ->
        {:error, :unavailable}
    end
  end

  @doc false
  # cli020 D3: what `terminal.notify` means here. `auto` is OSC 9 on iTerm2,
  # ghostty and WezTerm, else the bell; `os` is macOS only (the bell
  # elsewhere).
  def notify_mode(%{ui: %{notify: :auto}, term_program: program}),
    do: if(program in @osc9_terminals, do: :osc9, else: :bell)

  def notify_mode(%{ui: %{notify: :os}, os_type: {:unix, :darwin}}), do: :os
  def notify_mode(%{ui: %{notify: :os}}), do: :bell
  def notify_mode(%{ui: %{notify: mode}}), do: mode

  @doc false
  def os_notification_args(text),
    do: [
      "-e",
      "on run argv",
      "-e",
      ~s[display notification (item 1 of argv) with title "ncode"],
      "-e",
      "end run",
      text
    ]

  # ------------------------------------------- pass72-O: the preferences file

  # Only the packaged TUI keeps preferences unless the launcher names a
  # path: tests and the fake demos never touch the user's config directory.
  defp default_preferences do
    if System.get_env("SWARM_RELEASE_TUI") == "1",
      do: SwarmCodeCLI.Release.preferences_path(),
      else: nil
  end

  defp start_preferences(path) when is_binary(path),
    do: start_job(empty_preferences(path), :boot)

  defp start_preferences(_path), do: empty_preferences(nil)

  defp empty_preferences(path),
    do: %{path: path, task: nil, job: nil, queue: PrefsQueue.new(), known: %{}, changed?: false}

  # The values the session last read travel with the job: a legacy save
  # expects each key it writes to still hold them.
  defp start_job(%{path: path, known: known} = prefs, job),
    do: %{prefs | task: Task.async(fn -> Preferences.run(path, job, known) end), job: job}

  defp enqueue(%{prefs: %{path: nil}} = state, job),
    do: preferences_answer(state, Preferences.unavailable(job))

  defp enqueue(%{prefs: %{task: nil} = prefs} = state, job),
    do: %{state | prefs: start_job(prefs, job)}

  defp enqueue(%{prefs: prefs} = state, job) do
    case PrefsQueue.push(prefs.queue, job) do
      {:ok, queue} -> %{state | prefs: %{prefs | queue: queue}}
      {:error, :busy} -> preferences_answer(state, Preferences.unavailable(job, :busy))
    end
  end

  defp preferences_done(%{prefs: prefs} = state, {answer, known}) when is_map(known) do
    state = %{state | prefs: %{prefs | task: nil, job: nil, known: known}}
    state |> preferences_answer(answer) |> next_job()
  end

  defp preferences_done(%{prefs: prefs} = state, _crashed) do
    state = %{state | prefs: %{prefs | task: nil, job: nil}}
    state |> preferences_answer(Preferences.unavailable(prefs.job, :crashed)) |> next_job()
  end

  defp next_job(%{prefs: %{task: nil} = prefs} = state) do
    case PrefsQueue.pop(prefs.queue) do
      {:ok, job, queue} -> %{state | prefs: start_job(%{prefs | queue: queue}, job)}
      :empty -> state
    end
  end

  defp next_job(state), do: state

  # The boot read answers once and is ignored for the legacy four when the
  # user has already chosen; every snapshot refreshes `state.prefs`.
  defp preferences_answer(state, {:boot, snapshot}) do
    state =
      if state.prefs.changed? do
        state
      else
        read = Preferences.legacy(snapshot.values)
        state = update(state, {:panel_preferences_loaded, read.panel_mode})
        update(state, {:preferences_loaded, Map.take(read, [:show_diffs, :theme, :mouse?])})
      end

    update(state, {:settings, {:cli_snapshot, nil, snapshot}})
  end

  defp preferences_answer(state, {:legacy, _wanted, {:ok, snapshot}}),
    do: update(state, {:settings, {:cli_snapshot, nil, snapshot}})

  defp preferences_answer(state, {:legacy, _wanted, {:conflict, current}}),
    do: update(state, {:settings, {:prefs_conflict, current}})

  defp preferences_answer(state, {:legacy, _wanted, {:error, reason}}) do
    if reason != :unavailable,
      do: Logger.info("SwarmCode: cli.json was not written (#{inspect(reason)})")

    state
  end

  defp preferences_answer(state, {:legacy, _wanted, {:error, :invalid, _messages}}), do: state

  defp preferences_answer(state, {:cli_snapshot, generation, snapshot}),
    do: update(state, {:settings, {:cli_snapshot, generation, snapshot}})

  defp preferences_answer(state, {:cli_result, generation, ref, result}),
    do: update(state, {:settings, {:cli_result, generation, ref, result}})

  defp preferences_answer(state, _answer), do: state

  defp folder_done(%{folder: folder} = state, result) do
    cancel(folder.timer)
    update(%{state | folder: nil}, {:settings, {:folder_result, folder.generation, result}})
  end

  @doc false
  # cli74: `o` in Settings. macOS opens the folder with `open`; Linux with
  # `xdg-open` when a display is there; never over SSH. A folder that does
  # not exist is not created by a read.
  def open_folder(path, env \\ System.get_env(), os \\ :os.type()) do
    with {:ok, command} <- folder_opener(os, env),
         {:dir, true} <- {:dir, File.dir?(path)},
         executable when is_binary(executable) <- System.find_executable(command) do
      case System.cmd(executable, [path], stderr_to_stdout: true) do
        {_output, 0} -> :ok
        _ -> {:error, :failed}
      end
    else
      {:dir, false} -> {:error, :missing}
      nil -> {:error, :no_desktop}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def folder_opener(os, env) do
    ssh? = present?(Map.get(env, "SSH_CONNECTION"))
    display? = present?(Map.get(env, "DISPLAY")) or present?(Map.get(env, "WAYLAND_DISPLAY"))

    case os do
      _ when ssh? -> {:error, :no_desktop}
      {:unix, :darwin} -> {:ok, "open"}
      {:unix, _} when display? -> {:ok, "xdg-open"}
      _ -> {:error, :no_desktop}
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp copy_notice(state, result) do
    text =
      case result do
        {:copied, 1} ->
          "Copied 1 line."

        {:copied, lines} ->
          "Copied #{lines} lines."

        # cli020 D4: OSC 52 cannot say whether the terminal took it.
        {:ok, lines} ->
          "Sent #{lines} #{if lines == 1, do: "line", else: "lines"} to the terminal clipboard; " <>
            "if nothing arrived, your terminal does not allow OSC 52."

        :too_large ->
          "Not copied: the terminal clipboard takes at most 64 KiB."

        {:error, :invalid_text} ->
          "Not copied: the text has control characters."

        # cli74 (§3.7.2): `y` in Settings copies a key or a path, which the
        # detail pane always shows.
        _ when is_struct(state.ui.settings) ->
          "Couldn't copy · the path is shown in the detail"

        _ ->
          "This terminal cannot take a copy from ncode."
      end

    runtime_notice(%{state | copy: nil}, text)
  end

  # A notice the runtime itself shows (the copy, the image paste).
  defp runtime_notice(state, text) do
    state = tick(state)

    ui = %{
      state.ui
      | notice: {:command_feedback, text},
        notice_at: state.ui.now,
        revision: state.ui.revision + 1
    }

    commit(%{state | ui: ui}, state.ui)
  end

  # cli020 D12 (tui-code-8): a scene that fails validation, or a projector
  # that raises, keeps the last good scene on screen (the slot still holds
  # it), says so, and asks for one more projection; only the fifth failure
  # in a row closes the session.
  defp project(state) do
    state = %{state | dirty?: false}

    case safe_project(state) do
      {:ok, scene, table} ->
        case SceneSlot.put(state.slot, scene) do
          :ok ->
            %{state | table: table, scene_failures: 0}

          _ ->
            if state.scene_failures + 1 >= @max_scene_failures,
              do: explain_invalid_scene(scene, state.instruction_sink),
              else: Logger.warning("ncode: " <> invalid_scene_words(scene))

            scene_failed(state)
        end

      {:raised, words} ->
        Logger.error("ncode: the screen update raised: " <> words)
        scene_failed(state)
    end
  end

  defp safe_project(state) do
    {scene, table} = state.projector.(state.ui)
    {:ok, scene, table}
  rescue
    error -> {:raised, Exception.format(:error, error, __STACKTRACE__) |> String.slice(0, 4_000)}
  end

  defp scene_failed(%{scene_failures: failures} = state)
       when failures + 1 >= @max_scene_failures,
       do: begin_shutdown(%{state | scene_failures: failures + 1}, :invalid_scene)

  defp scene_failed(state) do
    ui = %{
      state.ui
      | notice: {:command_feedback, "A screen update failed; showing the last good one."},
        notice_at: state.ui.now,
        revision: state.ui.revision + 1
    }

    send(self(), :reproject)
    %{state | ui: ui, scene_failures: state.scene_failures + 1}
  end

  # A close the user did not ask for is said in plain words; a session that
  # vanishes with exit 0 cannot be reported, let alone fixed. A launcher with
  # an instruction sink (the packaged `ncode`) gets the words and prints
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
          "ncode: the session closed: " <> shutdown_words(base) <> detail <> "."
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
  defp invalid_scene_words(scene),
    do:
      "the screen failed validation " <>
        "(valid: #{inspect(match?(:ok, SwarmCodeCLI.UI.Scene.validate(scene)))}, " <>
        "bytes: #{safe_size(scene)}, size: #{inspect(Map.get(scene, :size))})"

  defp explain_invalid_scene(scene, sink) do
    text = invalid_scene_words(scene)

    if is_pid(sink),
      do: Logger.error("session closed: " <> text),
      else: IO.puts(:stderr, "ncode: the session closed: " <> text <> ".")

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

  defp draw(%{dirty?: true} = state) do
    case projected(state) do
      %{phase: :running} = next -> draw(next)
      closing -> closing
    end
  end

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
    if state.prefs.task, do: Task.shutdown(state.prefs.task, 1_000)
    if state.folder, do: Task.shutdown(state.folder.task, :brutal_kill)
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
    |> redact_queue()
  end

  # cli74 (§3.11): a paste waiting in the mailbox is a secret too.
  defp redact_queue(%{queue: _} = status), do: Map.put(status, :queue, [])
  defp redact_queue(status), do: status

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
