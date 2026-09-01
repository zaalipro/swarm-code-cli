defmodule SwarmCode.Daemon.Platform.DirectoryHelper do
  @moduledoc false

  alias SwarmCode.Daemon.Platform.DirectoryProtocol

  @request_timeout 5_000
  @long_request_timeout 300_000
  @startup_timeout 10_000
  @terminate_grace 250
  @kill_grace 2_000
  @maximum_basename_bytes 255
  @maximum_contents_bytes 4 * 1_024 * 1_024
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
  def link(helper, source, destination) do
    checked_request(helper, [source, destination], {:link, source, destination})
  end

  @spec unlink(t(), String.t()) :: :ok | {:error, term()}
  def unlink(helper, basename), do: checked_request(helper, [basename], {:unlink, basename})

  @spec unlink_identity(t(), String.t(), file_identity()) :: :ok | {:error, term()}
  def unlink_identity(helper, basename, identity) do
    with :ok <- safe_basename(basename), true <- valid_file_identity?(identity) do
      request(helper, {:unlink_identity, basename, identity})
    else
      _other -> {:error, :unsafe_helper_request}
    end
  end

  @spec link_source(t(), 0..2, String.t()) :: :ok | {:error, term()}
  def link_source(helper, index, destination) when index in 0..2 do
    checked_request(helper, [destination], {:link_source, index, destination})
  end

  def link_source(_helper, _index, _destination), do: {:error, :unsafe_helper_request}

  @spec write_private(t(), String.t(), binary(), non_neg_integer()) ::
          {:ok, file_identity()} | {:error, term()}
  def write_private(helper, basename, contents, uid) do
    with :ok <- safe_basename(basename),
         true <- is_binary(contents) and byte_size(contents) <= @maximum_contents_bytes,
         true <- valid_uid?(uid) do
      request(helper, {:write_private, basename, contents, uid})
    else
      _other -> {:error, :unsafe_helper_request}
    end
  end

  @spec read_private(t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def read_private(helper, basename, uid, maximum) do
    with :ok <- safe_basename(basename),
         true <- valid_uid?(uid),
         true <- is_integer(maximum) and maximum in 0..@maximum_contents_bytes//1 do
      request(helper, {:read_private, basename, uid, maximum})
    else
      _other -> {:error, :unsafe_helper_request}
    end
  end

  @spec copy_private(t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, file_identity()} | {:error, term()}
  def copy_private(helper, source, destination, uid) do
    with :ok <- safe_basename(source),
         :ok <- safe_basename(destination),
         true <- valid_uid?(uid) do
      request(helper, {:copy_private, source, destination, uid})
    else
      _other -> {:error, :unsafe_helper_request}
    end
  end

  @spec prepare_copy(t(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, file_identity()} | {:error, term()}
  def prepare_copy(helper, source, destination, uid) do
    with :ok <- safe_basename(source),
         :ok <- safe_basename(destination),
         true <- valid_uid?(uid) do
      request(helper, {:prepare_copy, source, destination, uid})
    else
      _other -> {:error, :unsafe_helper_request}
    end
  end

  @spec finish_copy(t()) :: {:ok, file_identity()} | {:error, term()}
  def finish_copy(helper), do: request(helper, :finish_copy)

  @spec cancel_copy(t()) :: :ok | {:error, term()}
  def cancel_copy(helper), do: request(helper, :cancel_copy)

  @spec private_identity(t(), String.t(), non_neg_integer()) ::
          {:ok, file_identity()} | {:error, term()}
  def private_identity(helper, basename, uid) do
    with :ok <- safe_basename(basename), true <- valid_uid?(uid) do
      request(helper, {:private_identity, basename, uid})
    else
      _other -> {:error, :unsafe_helper_request}
    end
  end

  @spec sync_file(t(), String.t(), file_identity(), non_neg_integer()) :: :ok | {:error, term()}
  def sync_file(helper, basename, identity, uid) do
    with :ok <- safe_basename(basename),
         true <- valid_file_identity?(identity),
         true <- valid_uid?(uid) do
      request(helper, {:sync_file, basename, identity, uid})
    else
      _other -> {:error, :unsafe_helper_request}
    end
  end

  @spec adopt(t(), String.t(), file_identity(), non_neg_integer()) :: :ok | {:error, term()}
  def adopt(helper, basename, identity, uid) do
    with :ok <- safe_basename(basename),
         true <- valid_file_identity?(identity),
         true <- valid_uid?(uid) do
      request(helper, {:adopt, basename, identity, uid})
    else
      _other -> {:error, :unsafe_helper_request}
    end
  end

  @spec commit(t(), [{String.t(), file_identity()}], non_neg_integer()) :: :ok | {:error, term()}
  def commit(helper, files, uid) when is_list(files) do
    valid? =
      valid_uid?(uid) and files != [] and
        Enum.all?(files, fn {basename, identity} ->
          safe_basename(basename) == :ok and valid_file_identity?(identity)
        end)

    if valid?, do: request(helper, {:commit, files, uid}), else: {:error, :unsafe_helper_request}
  end

  @spec sync_directory(t()) :: :ok | {:error, term()}
  def sync_directory(helper), do: request(helper, :sync_directory)

  @spec repair_mode(t(), 0o700, non_neg_integer()) :: :ok | {:error, term()}
  def repair_mode(helper, 0o700, uid) when is_integer(uid) and uid >= 0,
    do: request(helper, {:repair_mode, 0o700, uid})

  def repair_mode(_helper, _mode, _uid), do: {:error, :unsafe_helper_request}

  @spec directory_identity(t()) :: {:ok, tuple()} | {:error, term()}
  def directory_identity(helper), do: request(helper, :directory_identity)

  @spec entry_state(t(), String.t(), non_neg_integer()) ::
          :absent | {:ok, file_identity()} | {:error, term()}
  def entry_state(helper, basename, uid) do
    with :ok <- safe_basename(basename), true <- valid_uid?(uid) do
      request(helper, {:entry_state, basename, uid})
    else
      _other -> {:error, :unsafe_helper_request}
    end
  end

  @spec file_entry(t(), String.t(), non_neg_integer(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def file_entry(helper, basename, uid, published_name) do
    with :ok <- safe_basename(basename),
         :ok <- safe_basename(published_name),
         true <- valid_uid?(uid) do
      request(helper, {:file_entry, basename, uid, published_name})
    else
      _other -> {:error, :unsafe_helper_request}
    end
  end

  @spec verify_database(t(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def verify_database(helper, basename, expected_probe) do
    with :ok <- safe_basename(basename) do
      request(helper, {:verify_database, basename, expected_probe})
    end
  end

  @spec open_source(
          t(),
          [{:main | :wal | :shm, Path.t(), String.t(), file_identity() | nil}],
          term(),
          non_neg_integer()
        ) ::
          {:ok, map()} | {:error, term()}
  def open_source(helper, specs, expected_probe, uid) do
    if valid_uid?(uid) and valid_source_specs?(specs) do
      request(helper, {:open_source, specs, expected_probe, uid})
    else
      {:error, :unsafe_helper_request}
    end
  end

  @spec vacuum(t(), String.t(), non_neg_integer()) :: {:ok, file_identity()} | {:error, term()}
  def vacuum(helper, destination, uid) do
    with :ok <- safe_basename(destination), true <- valid_uid?(uid) do
      request(helper, {:vacuum, destination, uid})
    else
      _other -> {:error, :unsafe_helper_request}
    end
  end

  @spec close_source(t()) :: :ok | {:error, term()}
  def close_source(helper), do: request(helper, :close_source)

  @spec stop(t()) :: :ok
  def stop(%{owner: owner, monitor: original_monitor}) do
    monitor = Process.monitor(owner)
    ref = make_ref()
    send(owner, {:stop, self(), ref})

    receive do
      {^ref, :ok} -> await_down(owner, monitor, :infinity)
      {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
    end

    Process.demonitor(original_monitor, [:flush])
    Process.demonitor(monitor, [:flush])
    :ok
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
          _ = await_ready(port, port_monitor, caller_monitor)

          case terminate(port, port_monitor, os_pid) do
            :ok ->
              notify(observer, {:directory_helper_terminal, os_pid})
              send(caller, {ref, self(), {:error, :injected_helper_start_failure}})

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
        terminate(port, port_monitor, os_pid)
        send(caller, {ref, self(), {:error, :helper_start_failed}})
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
            graceful_stop(port, port_monitor, caller_monitor, os_pid)

          {:cleanup, reason} ->
            graceful_stop(port, port_monitor, caller_monitor, os_pid)
            send(from, {ref, {:error, reason}})

          {:error, reason} ->
            terminate(port, port_monitor, os_pid)
            send(from, {ref, {:error, reason}})
        end

      {:stop, from, ref} ->
        graceful_stop(port, port_monitor, caller_monitor, os_pid)
        send(from, {ref, :ok})

      {:DOWN, ^caller_monitor, :process, _caller, _reason} ->
        graceful_stop(port, port_monitor, caller_monitor, os_pid)

      {^port, _unexpected} ->
        graceful_stop(port, port_monitor, caller_monitor, os_pid)

      {:DOWN, ^port_monitor, :port, ^port, _reason} ->
        :ok
    end
  end

  defp request(%{owner: owner, monitor: monitor}, operation) do
    ref = make_ref()
    send(owner, {:request, self(), ref, operation})

    receive do
      {^ref, result} -> result
      {:DOWN, ^monitor, :process, ^owner, _reason} -> {:error, :directory_helper_stopped}
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
            {:ok, reply} ->
              {:ok, reply}

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

        {:error, reason} ->
          {:error, reason}
      end
    else
      _other -> {:error, :helper_command_failed}
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
            {:error, :directory_helper_stopped}

          {:DOWN, ^port_monitor, :port, ^port, _reason} ->
            {:error, :directory_helper_stopped}

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

    case DirectoryProtocol.push(state.decoder, bytes) do
      {:more, decoder} ->
        put_frame_state(port, %{state | decoder: decoder})
        :ok

      {:ok, payload, rest} ->
        put_frame_state(port, %{
          decoder: DirectoryProtocol.new_decoder(),
          frames: :queue.in(payload, state.frames)
        })

        if rest == <<>>, do: :ok, else: ingest_frames(port, rest)

      {:error, _reason} ->
        {:error, :invalid_frame}
    end
  end

  defp take_queued_frame(port) do
    state = frame_state(port)

    case :queue.out(state.frames) do
      {{:value, payload}, frames} ->
        put_frame_state(port, %{state | frames: frames})
        {:ok, payload}

      {:empty, _frames} ->
        :empty
    end
  end

  defp frame_state(port) do
    Process.get({__MODULE__, :frames, port}) ||
      %{
        decoder: DirectoryProtocol.new_decoder(),
        frames: :queue.new()
      }
  end

  defp put_frame_state(port, state), do: Process.put({__MODULE__, :frames, port}, state)

  defp graceful_stop(port, port_monitor, caller_monitor, os_pid) do
    _ = signal(os_pid, "-CONT")
    request_broker_stop(port)
    await_broker_terminal(port, port_monitor, caller_monitor, false, false)
  end

  defp await_broker_terminal(_port, _monitor, _caller_monitor, true, true), do: :ok

  defp await_broker_terminal(port, monitor, caller_monitor, exit?, down?) do
    receive do
      {^port, {:exit_status, _status}} ->
        await_broker_terminal(port, monitor, caller_monitor, true, down?)

      {:DOWN, ^monitor, :port, ^port, _reason} ->
        await_broker_terminal(port, monitor, caller_monitor, exit?, true)

      {^port, _data} ->
        await_broker_terminal(port, monitor, caller_monitor, exit?, down?)

      {:DOWN, ^caller_monitor, :process, _caller, _reason} ->
        await_broker_terminal(port, monitor, caller_monitor, exit?, down?)
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
         {:ok, exqlite} <- app_ebin(:exqlite),
         {:ok, elixir} <- app_ebin(:elixir) do
      erl_arguments =
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
          "no_dot_erlang",
          "-kernel",
          "error_logger",
          "silent",
          "-pa",
          daemon,
          "-pa",
          exqlite,
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

  defp checked_request(helper, names, request) do
    with true <- Enum.all?(names, &(safe_basename(&1) == :ok)), do: request(helper, request)
  end

  defp safe_basename(name)
       when is_binary(name) and byte_size(name) in 1..@maximum_basename_bytes//1 do
    if Regex.match?(~r/\A[.a-zA-Z0-9_-]+\z/, name) and Path.basename(name) == name,
      do: :ok,
      else: {:error, :unsafe_helper_basename}
  end

  defp safe_basename(_name), do: {:error, :unsafe_helper_basename}

  defp validate_options(opts, sources, fail_after_port_open?, observer, broker_fault) do
    keys = Keyword.keys(opts)

    if Keyword.keyword?(opts) and keys == Enum.uniq(keys) and
         Enum.all?(keys, &(&1 in @allowed_options)) and is_list(sources) and
         is_boolean(fail_after_port_open?) and (is_nil(observer) or is_pid(observer)) and
         broker_fault in [
           nil,
           :crash_finish_copy,
           :malformed_write_private,
           :oversized_write_private
         ] and
         length(sources) <= 3 and
         Enum.all?(sources, &safe_source_basename?/1),
       do: :ok,
       else: {:error, :invalid_directory_helper_options}
  end

  defp safe_source_basename?(name) when is_binary(name),
    do:
      byte_size(name) in 1..@maximum_basename_bytes//1 and String.valid?(name) and
        not String.contains?(name, [<<0>>, "\n", "\r"]) and Path.basename(name) == name

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

  defp valid_uid?(uid), do: is_integer(uid) and uid >= 0

  defp valid_file_identity?({:regular, a, b, c, d, e, f}),
    do: Enum.all?([a, b, c, d, e, f], &(is_integer(&1) and &1 >= 0))

  defp valid_file_identity?({:regular, a, b, c, d}),
    do: Enum.all?([a, b, c, d], &(is_integer(&1) and &1 >= 0))

  defp valid_file_identity?(_identity), do: false

  defp valid_source_specs?(specs) when is_list(specs) and length(specs) in 1..3//1 do
    Enum.all?(specs, fn
      {kind, source, destination, nil} when kind in [:wal, :shm] ->
        safe_source_path?(source) and safe_basename(destination) == :ok

      {kind, source, destination, identity} when kind in [:main, :wal, :shm] ->
        safe_source_path?(source) and safe_basename(destination) == :ok and
          valid_file_identity?(identity)

      _other ->
        false
    end) and Enum.count(specs, fn {kind, _, _, _} -> kind == :main end) == 1
  end

  defp valid_source_specs?(_specs), do: false

  defp safe_source_path?(path) when is_binary(path) do
    Path.type(path) == :absolute and byte_size(path) in 1..16_384//1 and String.valid?(path) and
      not String.contains?(path, <<0>>)
  end

  defp safe_source_path?(_path), do: false

  defp await_down(owner, monitor, :infinity) do
    receive do
      {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
    end
  end

  defp await_down(owner, monitor, timeout) do
    receive do
      {:DOWN, ^monitor, :process, ^owner, _reason} -> :ok
    after
      timeout -> :ok
    end
  end
end
