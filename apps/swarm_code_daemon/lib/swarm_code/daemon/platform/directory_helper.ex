defmodule SwarmCode.Daemon.Platform.DirectoryHelper do
  @moduledoc false

  alias SwarmCode.Daemon.Platform.DirectoryProtocol

  @request_timeout 5_000
  @long_request_timeout 300_000
  @startup_timeout 10_000
  @terminate_grace 250
  @kill_grace 2_000
  @shutdown_timeout @terminate_grace + @kill_grace + 1_000
  @maximum_basename_bytes 255
  @test_build Mix.env() == :test
  @allowed_options if(@test_build,
                     do: [
                       :source_basenames,
                       :test_fail_after_port_open,
                       :test_observer,
                       :test_broker_fault
                     ],
                     else: [:source_basenames]
                   )

  @type file_identity ::
          {:regular, non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
           non_neg_integer(), non_neg_integer()}
  @type t :: %{owner: pid(), monitor: reference(), os_pid: pos_integer()}

  @spec start(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def start(directory, opts \\ [])

  def start(directory, opts) when is_binary(directory) and is_list(opts) do
    sources = Keyword.get(opts, :source_basenames, [])
    fail_after_port_open? = fail_after_port_open?(opts)
    observer = observer(opts)
    broker_fault = broker_fault(opts)

    with :ok <- validate_options(opts, sources, fail_after_port_open?, observer, broker_fault),
         {:ok, executable, arguments} <- broker_command() do
      do_start(
        directory,
        sources,
        executable,
        arguments,
        fail_after_port_open?,
        observer,
        broker_fault
      )
    end
  end

  def start(_directory, _opts), do: {:error, :invalid_directory}

  @spec pwd(t()) :: {:ok, Path.t()} | {:error, term()}
  def pwd(helper), do: request(helper, :pwd)

  @spec link(t(), String.t(), String.t()) :: :ok | {:error, term()}
  def link(helper, source, destination), do: request(helper, {:link, source, destination})

  @spec link_owned(t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, file_identity()} | {:error, term()}
  def link_owned(helper, source, destination, uid),
    do: request(helper, {:link_owned, source, destination, uid})

  @spec unlink(t(), String.t()) :: :ok | {:error, term()}
  def unlink(helper, basename), do: request(helper, {:unlink, basename})

  @spec unlink_identity(t(), String.t(), file_identity()) :: :ok | {:error, term()}
  def unlink_identity(helper, basename, identity),
    do: request(helper, {:unlink_identity, basename, identity})

  @spec link_source(t(), 0..2, String.t()) :: :ok | {:error, term()}
  def link_source(helper, index, destination),
    do: request(helper, {:link_source, index, destination})

  @spec write_private(t(), String.t(), binary(), non_neg_integer()) ::
          {:ok, file_identity()} | {:error, term()}
  def write_private(helper, basename, contents, uid),
    do: request(helper, {:write_private, basename, contents, uid})

  @spec read_private(t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def read_private(helper, basename, uid, maximum),
    do: request(helper, {:read_private, basename, uid, maximum})

  @spec copy_private(t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, file_identity()} | {:error, term()}
  def copy_private(helper, source, destination, uid),
    do: request(helper, {:copy_private, source, destination, uid})

  @spec prepare_copy(t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, file_identity()} | {:error, term()}
  def prepare_copy(helper, source, destination, uid),
    do: request(helper, {:prepare_copy, source, destination, uid})

  @spec finish_copy(t()) :: {:ok, file_identity()} | {:error, term()}
  def finish_copy(helper), do: request(helper, :finish_copy)

  @spec cancel_copy(t()) :: :ok | {:error, term()}
  def cancel_copy(helper), do: request(helper, :cancel_copy)

  @spec private_identity(t(), String.t(), non_neg_integer()) ::
          {:ok, file_identity()} | {:error, term()}
  def private_identity(helper, basename, uid),
    do: request(helper, {:private_identity, basename, uid})

  @spec sync_file(t(), String.t(), file_identity(), non_neg_integer()) :: :ok | {:error, term()}
  def sync_file(helper, basename, identity, uid),
    do: request(helper, {:sync_file, basename, identity, uid})

  @spec adopt(t(), String.t(), file_identity(), non_neg_integer()) :: :ok | {:error, term()}
  def adopt(helper, basename, identity, uid),
    do: request(helper, {:adopt, basename, identity, uid})

  @spec commit(t(), [{String.t(), file_identity()}], non_neg_integer()) :: :ok | {:error, term()}
  def commit(helper, files, uid), do: request(helper, {:commit, files, uid})

  @spec sync_directory(t()) :: :ok | {:error, term()}
  def sync_directory(helper), do: request(helper, :sync_directory)

  @spec repair_mode(t(), 0o700, non_neg_integer()) :: :ok | {:error, term()}
  def repair_mode(helper, mode, uid), do: request(helper, {:repair_mode, mode, uid})

  @spec directory_identity(t()) :: {:ok, tuple()} | {:error, term()}
  def directory_identity(helper), do: request(helper, :directory_identity)

  @spec entry_state(t(), String.t(), non_neg_integer()) ::
          :absent | {:ok, file_identity()} | {:error, term()}
  def entry_state(helper, basename, uid), do: request(helper, {:entry_state, basename, uid})

  @spec file_entry(t(), String.t(), non_neg_integer(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def file_entry(helper, basename, uid, published_name),
    do: request(helper, {:file_entry, basename, uid, published_name})

  @spec verify_database(t(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def verify_database(helper, basename, expected_probe),
    do: request(helper, {:verify_database, basename, expected_probe})

  @spec open_source(
          t(),
          [{:main | :wal | :shm, Path.t(), String.t(), file_identity() | nil}],
          term(),
          non_neg_integer()
        ) ::
          {:ok, map()} | {:error, term()}
  def open_source(helper, specs, expected_probe, uid),
    do: request(helper, {:open_source, specs, expected_probe, uid})

  @spec vacuum(t(), String.t(), non_neg_integer()) :: {:ok, file_identity()} | {:error, term()}
  def vacuum(helper, destination, uid), do: request(helper, {:vacuum, destination, uid})

  @spec close_source(t()) :: :ok | {:error, term()}
  def close_source(helper), do: request(helper, :close_source)

  @spec stop(t()) :: :ok | {:error, :directory_helper_cleanup_pending}
  def stop(%{owner: owner, monitor: original_monitor}) do
    monitor = Process.monitor(owner)
    ref = make_ref()
    send(owner, {:stop, self(), ref})

    result =
      receive do
        {^ref, :stopping} ->
          result =
            receive do
              {^ref, :ok} ->
                case await_down(owner, monitor, @shutdown_timeout) do
                  :ok -> :ok
                  :timeout -> {:error, :directory_helper_cleanup_pending}
                end

              {^ref, {:error, :directory_helper_cleanup_pending}} ->
                {:error, :directory_helper_cleanup_pending}

              {:DOWN, ^monitor, :process, ^owner, _reason} ->
                :ok
            after
              @shutdown_timeout -> {:error, :directory_helper_cleanup_pending}
            end

          result

        {^ref, :ok} ->
          case await_down(owner, monitor, @shutdown_timeout) do
            :ok -> :ok
            :timeout -> {:error, :directory_helper_cleanup_pending}
          end

        {^ref, {:error, :directory_helper_cleanup_pending}} ->
          {:error, :directory_helper_cleanup_pending}

        {:DOWN, ^monitor, :process, ^owner, _reason} ->
          :ok
      after
        @shutdown_timeout -> {:error, :directory_helper_cleanup_pending}
      end

    Process.demonitor(original_monitor, [:flush])
    Process.demonitor(monitor, [:flush])
    result
  end

  defp do_start(
         directory,
         sources,
         executable,
         arguments,
         fail_after_port_open?,
         observer,
         broker_fault
       ) do
    :ok = DirectoryProtocol.preload()
    caller = self()
    ref = make_ref()

    {owner, monitor} =
      spawn_monitor(fn ->
        owner_init(
          caller,
          ref,
          directory,
          sources,
          executable,
          arguments,
          fail_after_port_open?,
          observer,
          broker_fault
        )
      end)

    await_start(owner, monitor, ref)
  end

  defp await_start(owner, monitor, ref) do
    receive do
      {^ref, ^owner, {:starting, _os_pid}} ->
        await_started(owner, monitor, ref)

      {^ref, ^owner, {:ready, os_pid}} ->
        {:ok, %{owner: owner, monitor: monitor, os_pid: os_pid}}

      {^ref, ^owner, {:error, reason}} ->
        await_down(owner, monitor, @startup_timeout)
        {:error, reason}

      {:DOWN, ^monitor, :process, ^owner, reason} ->
        {:error, {:helper_start_failed, reason}}
    after
      @startup_timeout ->
        cancel_start(owner, monitor, ref)
        {:error, :helper_start_timeout}
    end
  end

  defp await_started(owner, monitor, ref) do
    receive do
      {^ref, ^owner, {:ready, os_pid}} ->
        {:ok, %{owner: owner, monitor: monitor, os_pid: os_pid}}

      {^ref, ^owner, {:error, reason}} ->
        await_down(owner, monitor, @startup_timeout)
        {:error, reason}

      {:DOWN, ^monitor, :process, ^owner, reason} ->
        {:error, {:helper_start_failed, reason}}
    after
      @startup_timeout ->
        cancel_start(owner, monitor, ref)
        {:error, :helper_start_timeout}
    end
  end

  defp cancel_start(owner, monitor, ref) do
    send(owner, {:cancel_start, self(), ref})
    await_down(owner, monitor, @request_timeout + @kill_grace)
  end

  defp owner_init(
         caller,
         ref,
         directory,
         sources,
         executable,
         arguments,
         fail_after_port_open?,
         observer,
         broker_fault
       ) do
    caller_monitor = Process.monitor(caller)

    case open_port(directory, executable, arguments, broker_fault) do
      {:ok, port, port_monitor, os_pid} ->
        send(caller, {ref, self(), {:starting, os_pid}})
        notify(observer, {:directory_helper_started, os_pid})

        if fail_after_port_open? do
          ready_result = await_ready(port, port_monitor, caller_monitor)

          case cleanup_failed_start(
                 port,
                 port_monitor,
                 caller_monitor,
                 os_pid,
                 terminal_evidence(ready_result)
               ) do
            :ok ->
              notify(observer, {:directory_helper_terminal, os_pid})
              send(caller, {ref, self(), {:error, :injected_helper_start_failure}})

            {:error, :directory_helper_cleanup_pending, reaper} ->
              send(caller, {ref, self(), {:error, :directory_helper_cleanup_pending}})
              reaper_loop(elem(reaper, 0), elem(reaper, 1), elem(reaper, 2), elem(reaper, 3))

            {:error, _reason} ->
              send(caller, {ref, self(), {:error, :helper_cleanup_failed}})
          end
        else
          finish_owner_start(caller, ref, sources, caller_monitor, port, port_monitor, os_pid)
        end

      {:error, reason} ->
        send(caller, {ref, self(), {:error, reason}})
    end
  end

  defp finish_owner_start(caller, ref, sources, caller_monitor, port, port_monitor, os_pid) do
    result =
      with :ok <- await_ready(port, port_monitor, caller_monitor),
           {:ok, :ok} <-
             broker_request(port, port_monitor, caller_monitor, {:configure_sources, sources}) do
        :ok
      end

    case result do
      :ok ->
        send(caller, {ref, self(), {:ready, os_pid}})
        owner_loop(caller_monitor, port, port_monitor, os_pid)

      _other ->
        shutdown_result =
          graceful_stop(port, port_monitor, caller_monitor, os_pid, terminal_evidence(result))

        send(caller, {ref, self(), {:error, :helper_start_failed}})

        if shutdown_result == {:error, :directory_helper_cleanup_pending},
          do: reaper_loop(port, port_monitor, caller_monitor, os_pid)
    end
  end

  defp owner_loop(caller_monitor, port, port_monitor, os_pid) do
    receive do
      {:request, from, ref, operation} ->
        case broker_request(port, port_monitor, caller_monitor, operation) do
          {:ok, result} ->
            send(from, {ref, result})
            owner_loop(caller_monitor, port, port_monitor, os_pid)

          {:requester_down, _reason} ->
            shutdown_and_reap(port, port_monitor, caller_monitor, os_pid)

          {:cleanup, reason} ->
            send(from, {ref, {:error, reason}})
            shutdown_and_reap(port, port_monitor, caller_monitor, os_pid)

          {:terminal, reason, evidence} ->
            send(from, {ref, {:error, reason}})
            shutdown_and_reap(port, port_monitor, caller_monitor, os_pid, evidence)

          {:error, reason} ->
            send(from, {ref, {:error, reason}})
            shutdown_and_reap(port, port_monitor, caller_monitor, os_pid)
        end

      {:stop, from, ref} ->
        send(from, {ref, :stopping})
        result = graceful_stop(port, port_monitor, caller_monitor, os_pid)

        case result do
          :ok ->
            send(from, {ref, :ok})

          {:error, :directory_helper_cleanup_pending} ->
            send(from, {ref, {:error, :directory_helper_cleanup_pending}})
            reaper_loop(port, port_monitor, caller_monitor, os_pid)
        end

      {:DOWN, ^caller_monitor, :process, _caller, _reason} ->
        shutdown_and_reap(port, port_monitor, caller_monitor, os_pid)

      {^port, {:exit_status, _status}} ->
        shutdown_and_reap(port, port_monitor, caller_monitor, os_pid, {true, false})

      {^port, _unexpected} ->
        shutdown_and_reap(port, port_monitor, caller_monitor, os_pid)

      {:DOWN, ^port_monitor, :port, ^port, _reason} ->
        shutdown_and_reap(port, port_monitor, caller_monitor, os_pid, {false, true})
    end
  end

  defp shutdown_and_reap(port, port_monitor, caller_monitor, os_pid, evidence \\ {false, false}) do
    case graceful_stop(port, port_monitor, caller_monitor, os_pid, evidence) do
      :ok ->
        :ok

      {:error, :directory_helper_cleanup_pending} ->
        reaper_loop(port, port_monitor, caller_monitor, os_pid)
    end
  end

  defp request(%{owner: owner, monitor: monitor}, operation) do
    if DirectoryProtocol.valid_request?(operation) do
      do_request(owner, monitor, operation)
    else
      {:error, :unsafe_helper_request}
    end
  end

  defp request(_helper, _operation), do: {:error, :unsafe_helper_request}

  defp do_request(owner, monitor, operation) do
    ref = make_ref()
    send(owner, {:request, self(), ref, operation})

    receive do
      {^ref, result} ->
        result

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        {:error, :directory_helper_stopped}
    after
      operation_timeout(operation) + @terminate_grace + @kill_grace + 1_000 ->
        {:error, :directory_helper_timeout}
    end
  end

  defp open_port(directory, executable, arguments, broker_fault) do
    port =
      Port.open({:spawn_executable, String.to_charlist(executable)}, [
        :binary,
        :exit_status,
        :hide,
        :use_stdio,
        {:cd, String.to_charlist(directory)},
        {:args, Enum.map(arguments, &String.to_charlist/1)},
        {:env,
         release_environment() ++
           [
             {~c"ERL_AFLAGS", ~c""},
             {~c"ERL_CRASH_DUMP", ~c"/dev/null"},
             {~c"ERL_FLAGS", ~c""},
             {~c"ERL_LIBS", ~c""},
             {~c"ERL_ZFLAGS", ~c""}
             | test_broker_fault_environment(broker_fault)
           ]}
      ])

    monitor = Port.monitor(port)

    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 0 ->
        {:ok, port, monitor, os_pid}

      _other ->
        Port.demonitor(monitor, [:flush])
        Port.close(port)
        {:error, :missing_helper_os_pid}
    end
  rescue
    _error -> {:error, :helper_port_open_failed}
  end

  defp await_ready(port, port_monitor, caller_monitor) do
    case receive_frame(port, port_monitor, caller_monitor, @request_timeout) do
      {:ok, payload} ->
        case DirectoryProtocol.decode_ready(payload) do
          {:ok, {:ready, _path, {:ok, _identity}}} -> :ok
          {:error, _reason} -> {:error, :invalid_helper_ready}
        end

      {:error, reason, evidence} ->
        {:terminal, reason, evidence}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp broker_request(port, port_monitor, caller_monitor, operation) do
    with {:ok, frame} <- DirectoryProtocol.encode_request(operation),
         true <- Port.command(port, frame) do
      case receive_frame(port, port_monitor, caller_monitor, operation_timeout(operation)) do
        {:ok, payload} ->
          case DirectoryProtocol.decode_reply(operation, payload) do
            {:ok, {:error, :helper_operation_failed}} ->
              {:cleanup, :helper_operation_failed}

            {:ok, reply} ->
              if queued_frame?(port), do: {:cleanup, :invalid_helper_response}, else: {:ok, reply}

            {:error, _reason} ->
              {:cleanup, :invalid_helper_response}
          end

        {:error, :directory_helper_owner_stopped} ->
          request_broker_stop(port)
          {:requester_down, :directory_helper_owner_stopped}

        {:error, :directory_helper_timeout} ->
          request_broker_stop(port)
          {:cleanup, :directory_helper_timeout}

        {:error, :invalid_helper_response} ->
          {:cleanup, :invalid_helper_response}

        {:error, reason, evidence} ->
          {:terminal, reason, evidence}

        {:error, reason} ->
          {:error, reason}
      end
    else
      _other ->
        {:cleanup, :helper_command_failed}
    end
  end

  defp receive_frame(port, port_monitor, caller_monitor, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_receive_frame(port, port_monitor, caller_monitor, deadline)
  end

  defp do_receive_frame(port, port_monitor, caller_monitor, deadline) do
    case take_queued_frame(port) do
      {:ok, payload} ->
        {:ok, payload}

      :empty ->
        timeout = max(deadline - System.monotonic_time(:millisecond), 0)

        receive do
          {^port, {:data, bytes}} when is_binary(bytes) ->
            case ingest_frames(port, bytes) do
              :ok -> do_receive_frame(port, port_monitor, caller_monitor, deadline)
              {:error, _reason} -> {:error, :invalid_helper_response}
            end

          {^port, {:exit_status, _status}} ->
            {:error, :directory_helper_stopped, {true, false}}

          {:DOWN, ^port_monitor, :port, ^port, _reason} ->
            {:error, :directory_helper_stopped, {false, true}}

          {:DOWN, ^caller_monitor, :process, _caller, _reason} ->
            {:error, :directory_helper_owner_stopped}

          {:cancel_start, _caller, _ref} ->
            {:error, :helper_start_cancelled}
        after
          timeout -> {:error, :directory_helper_timeout}
        end
    end
  end

  defp ingest_frames(port, bytes) do
    state = frame_state(port)
    maximum_bytes = DirectoryProtocol.maximum_bytes()

    if state.queued_bytes + DirectoryProtocol.collected_bytes(state.decoder) + byte_size(bytes) >
         maximum_bytes do
      {:error, :invalid_frame}
    else
      ingest_frame_bytes(port, state, bytes, maximum_bytes)
    end
  end

  defp ingest_frame_bytes(_port, _state, <<>>, _maximum_bytes), do: :ok

  defp ingest_frame_bytes(port, state, bytes, maximum_bytes) do
    case DirectoryProtocol.push(state.decoder, bytes) do
      {:more, decoder} ->
        put_frame_state(port, %{state | decoder: decoder})
        :ok

      {:ok, payload, rest} ->
        queued_bytes = state.queued_bytes + byte_size(payload)

        if queued_bytes > maximum_bytes or state.queued_count >= 64 do
          {:error, :invalid_frame}
        else
          next_state = %{
            decoder: DirectoryProtocol.new_decoder(),
            frames: :queue.in(payload, state.frames),
            queued_bytes: queued_bytes,
            queued_count: state.queued_count + 1
          }

          put_frame_state(port, next_state)
          ingest_frame_bytes(port, next_state, rest, maximum_bytes)
        end

      {:error, _reason} ->
        {:error, :invalid_frame}
    end
  end

  defp take_queued_frame(port) do
    state = frame_state(port)

    case :queue.out(state.frames) do
      {{:value, payload}, frames} ->
        put_frame_state(port, %{
          state
          | frames: frames,
            queued_bytes: state.queued_bytes - byte_size(payload),
            queued_count: state.queued_count - 1
        })

        {:ok, payload}

      {:empty, _frames} ->
        :empty
    end
  end

  defp queued_frame?(port) do
    state = frame_state(port)
    state.queued_count > 0
  end

  defp frame_state(port) do
    Process.get({__MODULE__, :frames, port}) ||
      %{
        decoder: DirectoryProtocol.new_decoder(),
        frames: :queue.new(),
        queued_bytes: 0,
        queued_count: 0
      }
  end

  defp put_frame_state(port, state), do: Process.put({__MODULE__, :frames, port}, state)

  defp graceful_stop(port, port_monitor, caller_monitor, os_pid) do
    graceful_stop(port, port_monitor, caller_monitor, os_pid, {false, false})
  end

  defp graceful_stop(port, port_monitor, caller_monitor, os_pid, {exit?, down?}) do
    if not exit? and not down? do
      request_broker_stop(port)
      _ = signal(os_pid, "-CONT")
    end

    await_broker_terminal(
      port,
      port_monitor,
      caller_monitor,
      exit?,
      down?,
      @shutdown_timeout
    )
  end

  defp terminal_evidence({:terminal, _reason, evidence}), do: evidence
  defp terminal_evidence(_result), do: {false, false}

  defp cleanup_failed_start(port, port_monitor, _caller_monitor, os_pid, {false, false}),
    do: terminate(port, port_monitor, os_pid)

  defp cleanup_failed_start(port, port_monitor, caller_monitor, os_pid, {exit?, down?}) do
    case await_broker_terminal(
           port,
           port_monitor,
           caller_monitor,
           exit?,
           down?,
           @shutdown_timeout
         ) do
      :ok ->
        :ok

      {:error, :directory_helper_cleanup_pending} ->
        {:error, :directory_helper_cleanup_pending, {port, port_monitor, caller_monitor, os_pid}}
    end
  end

  defp await_broker_terminal(_port, _monitor, _caller_monitor, true, true, _timeout), do: :ok

  defp await_broker_terminal(port, monitor, caller_monitor, exit?, down?, timeout) do
    receive do
      {:stop, from, ref} when is_pid(from) ->
        send(from, {ref, {:error, :directory_helper_cleanup_pending}})
        await_broker_terminal(port, monitor, caller_monitor, exit?, down?, timeout)

      {^port, {:exit_status, _status}} ->
        await_broker_terminal(port, monitor, caller_monitor, true, down?, timeout)

      {:DOWN, ^monitor, :port, ^port, _reason} ->
        await_broker_terminal(port, monitor, caller_monitor, exit?, true, timeout)

      {^port, _data} ->
        await_broker_terminal(port, monitor, caller_monitor, exit?, down?, timeout)

      {:DOWN, ^caller_monitor, :process, _caller, _reason} ->
        await_broker_terminal(port, monitor, caller_monitor, exit?, down?, timeout)
    after
      timeout -> {:error, :directory_helper_cleanup_pending}
    end
  end

  # The owner remains the explicit reaper after the bounded caller response.
  defp reaper_loop(port, monitor, caller_monitor, _os_pid) do
    case await_broker_terminal(port, monitor, caller_monitor, false, false, :infinity) do
      :ok -> :ok
      _other -> :ok
    end
  end

  defp request_broker_stop(port) do
    case DirectoryProtocol.encode_request(:stop) do
      {:ok, frame} -> _ = Port.command(port, frame)
      {:error, _reason} -> :ok
    end

    :ok
  rescue
    _error -> :ok
  end

  defp terminate(port, port_monitor, os_pid) do
    if await_port_terminal(port, port_monitor, 0) do
      :ok
    else
      _ = signal(os_pid, "-TERM")

      if await_port_terminal(port, port_monitor, @terminate_grace) do
        :ok
      else
        _ = signal(os_pid, "-KILL")

        if await_port_terminal(port, port_monitor, @kill_grace),
          do: :ok,
          else: {:error, :directory_helper_cleanup_failed}
      end
    end
  end

  defp await_port_terminal(port, monitor, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_port_terminal(port, monitor, deadline, false, false)
  end

  defp await_port_terminal(_port, _monitor, _deadline, true, true), do: true

  defp await_port_terminal(port, monitor, deadline, exit?, down?) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:exit_status, _}} ->
        await_port_terminal(port, monitor, deadline, true, down?)

      {:DOWN, ^monitor, :port, ^port, _} ->
        await_port_terminal(port, monitor, deadline, exit?, true)

      {^port, _} ->
        await_port_terminal(port, monitor, deadline, exit?, down?)
    after
      timeout -> false
    end
  end

  defp broker_command do
    with {:ok, [[bindir]]} <- :init.get_argument(:bindir),
         erl = Path.join(List.to_string(bindir), "erl"),
         true <- File.regular?(erl),
         true <- File.regular?("/bin/sh"),
         {:ok, daemon} <- app_ebin(:swarm_code_daemon),
         {:ok, core} <- app_ebin(:swarm_code_core),
         {:ok, exqlite} <- app_ebin(:exqlite),
         {:ok, jason} <- app_ebin(:jason),
         {:ok, elixir} <- app_ebin(:elixir) do
      erl_arguments =
        release_boot_arguments() ++
          [
            "+S",
            "1:1",
            "+A",
            "1",
            "+SDio",
            "1",
            "+SDcpu",
            "1",
            "-noshell",
            "-boot",
            boot_file(),
            "-kernel",
            "error_logger",
            "silent",
            "-pa",
            daemon,
            "-pa",
            core,
            "-pa",
            exqlite,
            "-pa",
            jason,
            "-pa",
            elixir,
            "-s",
            "Elixir.SwarmCode.Daemon.Platform.DirectoryBroker",
            "main"
          ]

      {:ok, "/bin/sh", ["-c", "umask 077; exec \"$@\"", "directory-broker", erl | erl_arguments]}
    else
      _other -> {:error, :helper_runtime_unavailable}
    end
  end

  defp app_ebin(application) do
    case :code.lib_dir(application) do
      path when is_list(path) ->
        {:ok, path |> List.to_string() |> Path.join("ebin") |> Path.expand()}

      _other ->
        {:error, :missing_application_ebin}
    end
  end

  defp boot_file do
    case {System.get_env("RELEASE_ROOT"), System.get_env("RELEASE_VSN")} do
      {root, version} when is_binary(root) and is_binary(version) ->
        Path.join([root, "releases", version, "start_clean"])

      _ ->
        "no_dot_erlang"
    end
  end

  defp release_environment do
    base =
      for name <- ~w(RELEASE_ROOT RELEASE_VSN),
          value = System.get_env(name),
          is_binary(value),
          do: {String.to_charlist(name), String.to_charlist(value)}

    case System.get_env("RELEASE_ROOT") do
      root when is_binary(root) ->
        [{~c"RELEASE_LIB", String.to_charlist(Path.join(root, "lib"))} | base]

      _ ->
        base
    end
  end

  defp release_boot_arguments do
    case {System.get_env("RELEASE_ROOT"), System.get_env("RELEASE_VSN")} do
      {root, version} when is_binary(root) and is_binary(version) ->
        [
          "-boot_var",
          "RELEASE_LIB",
          Path.join(root, "lib"),
          "-boot_var",
          "RELEASE_ROOT",
          root,
          "-boot_var",
          "RELEASE_VSN",
          version
        ]

      _ ->
        []
    end
  end

  defp signal(pid, signal) do
    case System.cmd("/bin/kill", [signal, Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      _other -> {:error, :helper_signal_failed}
    end
  rescue
    _error -> {:error, :helper_signal_failed}
  end

  defp operation_timeout({operation, _, _})
       when operation in [:verify_database, :vacuum],
       do: @long_request_timeout

  defp operation_timeout({operation, _, _, _})
       when operation in [
              :copy_private,
              :file_entry,
              :open_source,
              :prepare_copy,
              :read_private,
              :sync_file,
              :write_private
            ],
       do: @long_request_timeout

  defp operation_timeout(:finish_copy), do: @long_request_timeout

  defp operation_timeout(_operation), do: @request_timeout

  defp validate_options(opts, sources, fail_after_port_open?, observer, broker_fault) do
    keys = Keyword.keys(opts)

    if Keyword.keyword?(opts) and keys == Enum.uniq(keys) and
         Enum.all?(keys, &(&1 in @allowed_options)) and is_list(sources) and
         is_boolean(fail_after_port_open?) and (is_nil(observer) or is_pid(observer)) and
         broker_fault in [
           nil,
           :crash_finish_copy,
           :extra_frame_write_private,
           :malformed_write_private,
           :oversized_write_private,
           :pause_link_before_reserve,
           :pause_link_source_before_reserve,
           :pause_shm_before_reserve,
           :pause_vacuum_after_step,
           :pause_vacuum_before_step,
           :pause_write_private_before_reserve,
           :stall_stop
         ] and
         length(sources) <= 3 and
         Enum.all?(sources, &safe_source_basename?/1),
       do: :ok,
       else: {:error, :invalid_directory_helper_options}
  end

  defp safe_source_basename?(name) when is_binary(name),
    do:
      byte_size(name) in 1..@maximum_basename_bytes//1 and String.valid?(name) and
        name not in [".", ".."] and not String.contains?(name, [<<0>>, "\n", "\r"]) and
        Path.basename(name) == name

  defp safe_source_basename?(_name), do: false

  if @test_build do
    defp fail_after_port_open?(opts), do: Keyword.get(opts, :test_fail_after_port_open, false)
    defp observer(opts), do: Keyword.get(opts, :test_observer)
    defp broker_fault(opts), do: Keyword.get(opts, :test_broker_fault)

    defp test_broker_fault_environment(nil),
      do: [{~c"SWARM_CODE_DIRECTORY_BROKER_TEST_FAULT", false}]

    defp test_broker_fault_environment(fault),
      do: [{~c"SWARM_CODE_DIRECTORY_BROKER_TEST_FAULT", Atom.to_charlist(fault)}]
  else
    defp fail_after_port_open?(_opts), do: false
    defp observer(_opts), do: nil
    defp broker_fault(_opts), do: nil
    defp test_broker_fault_environment(_fault), do: []
  end

  defp notify(nil, _event), do: :ok
  defp notify(observer, event), do: send(observer, event)

  defp await_down(owner, monitor, timeout) do
    receive do
      {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
    after
      timeout -> :timeout
    end
  end
end
