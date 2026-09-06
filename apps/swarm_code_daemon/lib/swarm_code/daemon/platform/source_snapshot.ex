defmodule SwarmCode.Daemon.Platform.SourceSnapshot do
  @moduledoc false
  import Bitwise, only: [band: 2]
  alias SwarmCode.Daemon.Platform.{DirectoryHelper, ExternalCommand}

  @files ["snapshot.db", "snapshot.db-wal", "snapshot.db-shm"]
  @test_build Mix.env() == :test
  @allowed_options if(@test_build,
                     do: [
                       :timeout,
                       :callback_timeout,
                       :observer,
                       :test_before_copy,
                       :test_after_copy
                     ],
                     else: [:timeout, :callback_timeout]
                   )
  @cleanup_timeout 3_500
  @maximum_copy_bytes 64 * 1_024 * 1_024 * 1_024

  def with_snapshot(path, uid, expected, callback, opts \\ []) do
    with {:ok, config} <- validate(path, uid, expected, callback, opts) do
      requester = self()
      ref = make_ref()
      {owner, monitor} = spawn_monitor(fn -> owner(requester, ref, config) end)

      receive do
        {^ref, ^owner, result} ->
          Process.demonitor(monitor, [:flush])
          result

        {:DOWN, ^monitor, :process, ^owner, _reason} ->
          {:error, :snapshot_cleanup_pending}
      end
    end
  end

  # Register before executing SQLite statements. Keeping the resource in the owner
  # allows explicit close after a cancelled callback's actual DOWN notification.
  def with_connection(path, function) when is_function(function, 1) do
    case Process.get({__MODULE__, :owner}) do
      {owner, token, ^path} ->
        with {:ok, connection} <- Exqlite.Sqlite3.open(path, mode: :readonly) do
          send(owner, {:snapshot_connection, token, self(), connection})

          receive do
            {:snapshot_connection_registered, ^token} ->
              try do
                function.(connection)
              after
                Exqlite.Sqlite3.close(connection)
              end
          end
        end

      _ ->
        {:error, :snapshot_failed}
    end
  end

  defp owner(requester, ref, config) do
    Process.flag(:trap_exit, true)
    monitor = Process.monitor(requester)

    state =
      Map.merge(config, %{
        requester: requester,
        request_ref: ref,
        requester_monitor: monitor,
        directory: nil,
        directory_stat: nil,
        helper: nil,
        receipts: %{},
        connections: []
      })

    notify(state, {:snapshot_owner_started, self()})
    prepare(state)
  end

  defp prepare(state) do
    directory =
      Path.join(
        Path.dirname(state.path),
        ".swarm-snapshot-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      )

    case File.mkdir(directory) do
      :ok ->
        case File.lstat(directory) do
          {:ok, stat} ->
            state = %{state | directory: directory, directory_stat: stat}

            with :ok <- File.chmod(directory, 0o700),
                 {:ok, current} <- File.lstat(directory),
                 true <- same_object?(stat, current),
                 true <- private_stat?(current, state.uid, :directory) do
              case DirectoryHelper.start(directory) do
                {:ok, helper} ->
                  create_outputs(%{state | helper: helper, directory_stat: current}, @files)

                _ ->
                  # The helper startup API may retain a reaper on failure without
                  # returning its handle. Conservatively retain this workspace.
                  retain(state)
              end
            else
              _ -> finish(state, {:error, :snapshot_failed})
            end

          _ ->
            retain(%{state | directory: directory})
        end

      _ ->
        finish(state, {:error, :snapshot_failed})
    end
  end

  defp create_outputs(state, []) do
    run_worker(state, state.before_copy, fn state -> start_copy(state) end)
  end

  defp create_outputs(state, [name | rest]) do
    case DirectoryHelper.write_private(state.helper, name, <<>>, state.uid) do
      {:ok, identity} ->
        create_outputs(%{state | receipts: Map.put(state.receipts, name, identity)}, rest)

      _ ->
        finish(state, {:error, :snapshot_failed})
    end
  end

  defp start_copy(state) do
    with :ok <- validate_source(state.path, state.uid, state.expected),
         {:ok, executable} <- executable(),
         {:ok, handle} <-
           ExternalCommand.start(executable, arguments(state),
             cwd: state.directory,
             timeout: state.timeout,
             max_line_bytes: 128
           ) do
      await_native(state, handle, nil, deadline(state.timeout + 250), false)
    else
      _ -> finish(state, {:error, :snapshot_failed})
    end
  end

  defp await_native(state, {owner, ref, monitor} = handle, result, limit, cancelled) do
    receive do
      {^ref, ^owner, command_result} ->
        await_native(state, handle, command_result, limit, cancelled)

      {:DOWN, ^monitor, :process, ^owner, :normal} ->
        cond do
          cancelled -> finish(state, {:error, :snapshot_timeout})
          valid_response?(state, result) -> run_worker(state, state.after_copy, &run_callback/1)
          result == {:error, :command_timeout} -> finish(state, {:error, :snapshot_timeout})
          true -> finish(state, {:error, :snapshot_failed})
        end

      {:DOWN, ^monitor, :process, ^owner, _reason} ->
        retain(state)

      {:DOWN, requester_monitor, :process, _requester, _reason}
      when requester_monitor == state.requester_monitor ->
        ExternalCommand.cancel(handle)
        await_native(state, handle, result, deadline(@cleanup_timeout), true)

      {:EXIT, _from, _reason} ->
        ExternalCommand.cancel(handle)
        await_native(state, handle, result, deadline(@cleanup_timeout), true)
    after
      remaining(limit) ->
        if cancelled do
          pending(state, owner, monitor, :native)
        else
          ExternalCommand.cancel(handle)
          await_native(state, handle, result, deadline(@cleanup_timeout), true)
        end
    end
  end

  defp run_callback(state), do: run_worker(state, state.callback, &finish(&1, &2))
  defp run_worker(state, nil, next), do: next.(state)

  defp run_worker(state, function, next) do
    owner = self()
    token = make_ref()
    path = Path.join(state.directory, "snapshot.db")

    {worker, monitor} =
      spawn_monitor(fn ->
        Process.put({__MODULE__, :owner}, {owner, token, path})

        result =
          try do
            function.(path)
          rescue
            _ -> {:error, :snapshot_failed}
          catch
            _, _ -> {:error, :snapshot_failed}
          end

        send(owner, {:snapshot_worker_result, token, self(), result})
      end)

    await_worker(
      state,
      worker,
      monitor,
      token,
      nil,
      next,
      deadline(state.callback_timeout),
      false
    )
  end

  defp await_worker(state, worker, monitor, token, result, next, limit, cancelled) do
    receive do
      {:snapshot_connection, ^token, ^worker, connection} ->
        send(worker, {:snapshot_connection_registered, token})

        await_worker(
          %{state | connections: [connection | state.connections]},
          worker,
          monitor,
          token,
          result,
          next,
          limit,
          cancelled
        )

      {:snapshot_worker_result, ^token, ^worker, value} ->
        await_worker(state, worker, monitor, token, {:result, value}, next, limit, cancelled)

      {:DOWN, ^monitor, :process, ^worker, reason} ->
        state = close_connections(state)

        cond do
          cancelled -> finish(state, {:error, :snapshot_timeout})
          reason != :normal or is_nil(result) -> finish(state, {:error, :snapshot_failed})
          is_function(next, 2) -> next.(state, elem(result, 1))
          elem(result, 1) == :ok -> next.(state)
          true -> finish(state, {:error, :snapshot_failed})
        end

      {:DOWN, requester_monitor, :process, _requester, _reason}
      when requester_monitor == state.requester_monitor ->
        cancel_worker(state, worker)

        await_worker(
          state,
          worker,
          monitor,
          token,
          result,
          next,
          deadline(@cleanup_timeout),
          true
        )

      {:EXIT, _from, _reason} ->
        cancel_worker(state, worker)

        await_worker(
          state,
          worker,
          monitor,
          token,
          result,
          next,
          deadline(@cleanup_timeout),
          true
        )
    after
      remaining(limit) ->
        if cancelled do
          pending(state, worker, monitor, :callback)
        else
          cancel_worker(state, worker)

          await_worker(
            state,
            worker,
            monitor,
            token,
            result,
            next,
            deadline(@cleanup_timeout),
            true
          )
        end
    end
  end

  defp finish(state, result) do
    case cleanup(state) do
      :ok ->
        notify(state, {:snapshot_owner_settled, self(), 0})
        reply(state, result)

      :pending ->
        retain(state)
    end
  end

  defp cleanup(%{directory: nil}), do: :ok

  defp cleanup(state) do
    helper_result =
      if state.helper do
        # The broker's receipt ledger also removes owned files whose lengths SQLite
        # changed, and accepts already absent files; it never adopts replacements.
        Enum.each(state.receipts, fn {name, identity} ->
          DirectoryHelper.unlink_identity(state.helper, name, identity)
        end)

        monitor = Process.monitor(state.helper.owner)
        result = DirectoryHelper.stop(state.helper)

        terminal =
          receive do
            {:DOWN, ^monitor, :process, _owner, :normal} -> :ok
            {:DOWN, ^monitor, :process, _owner, _reason} -> :pending
          after
            @cleanup_timeout -> :pending
          end

        Process.demonitor(monitor, [:flush])
        if result == :ok and terminal == :ok, do: :ok, else: :pending
      else
        :ok
      end

    with :ok <- helper_result,
         {:ok, stat} <- File.lstat(state.directory),
         true <- same_object?(stat, state.directory_stat),
         true <- stat.type == :directory and stat.uid == state.uid,
         :ok <- File.rmdir(state.directory) do
      :ok
    else
      _ -> :pending
    end
  end

  defp pending(state, child, monitor, kind) do
    reply(state, {:error, :snapshot_cleanup_pending})
    notify(state, {:snapshot_owner_pending, self(), 1})
    state = %{state | requester: nil}

    receive do
      {:DOWN, ^monitor, :process, ^child, reason} ->
        if kind == :callback or reason == :normal do
          finish(close_connections(state), {:error, :snapshot_cleanup_pending})
        else
          retain(state, false)
        end
    end
  end

  # Ambiguous terminal evidence cannot authorize unlink. Retain the receipts and
  # helper ownership without polling or signalling a potentially reused OS PID.
  defp retain(state, reply? \\ true) do
    if reply?, do: reply(state, {:error, :snapshot_cleanup_pending})
    notify(state, {:snapshot_owner_pending, self(), map_size(state.receipts)})

    receive do
      {:snapshot_status, from, ref} when is_pid(from) ->
        send(from, {ref, :snapshot_cleanup_pending, map_size(state.receipts)})
        retain(state, false)

      _ ->
        retain(state, false)
    end
  end

  defp cancel_worker(state, worker) do
    Enum.each(state.connections, fn connection ->
      try do
        Exqlite.Sqlite3.cancel(connection)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)

    Process.exit(worker, :kill)
  end

  defp close_connections(state) do
    closed? =
      Enum.all?(state.connections, fn connection ->
        try do
          Exqlite.Sqlite3.close(connection) == :ok
        rescue
          _ -> false
        catch
          _, _ -> false
        end
      end)

    if closed?, do: %{state | connections: []}, else: retain(state)
  end

  defp reply(%{requester: requester} = state, result) when is_pid(requester),
    do: send(requester, {state.request_ref, self(), result})

  defp reply(_, _), do: :ok
  defp notify(%{observer: observer}, event) when is_pid(observer), do: send(observer, event)
  defp notify(_, _), do: :ok
  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
  defp remaining(limit), do: max(limit - System.monotonic_time(:millisecond), 0)

  defp validate(path, uid, expected, callback, opts) do
    with true <- Keyword.keyword?(opts),
         keys = Keyword.keys(opts),
         true <- keys == Enum.uniq(keys) and Enum.all?(keys, &(&1 in @allowed_options)),
         timeout = Keyword.get(opts, :timeout, 3_000),
         callback_timeout = Keyword.get(opts, :callback_timeout, 3_000),
         true <- is_integer(timeout) and timeout in 1..300_000,
         true <- is_integer(callback_timeout) and callback_timeout in 1..300_000,
         observer = Keyword.get(opts, :observer),
         true <- is_nil(observer) or is_pid(observer),
         before_copy = Keyword.get(opts, :test_before_copy),
         after_copy = Keyword.get(opts, :test_after_copy),
         true <- is_nil(before_copy) or is_function(before_copy, 1),
         true <- is_nil(after_copy) or is_function(after_copy, 1),
         true <- is_function(callback, 1),
         :ok <- validate_source(path, uid, expected) do
      {:ok,
       %{
         path: path,
         uid: uid,
         expected: expected,
         callback: callback,
         timeout: timeout,
         callback_timeout: callback_timeout,
         observer: observer,
         before_copy: before_copy,
         after_copy: after_copy
       }}
    else
      _ -> {:error, :snapshot_failed}
    end
  rescue
    _ -> {:error, :snapshot_failed}
  end

  defp validate_source(path, uid, %{main: main, wal: wal, shm: shm, parent: parent} = expected)
       when is_binary(path) and is_integer(uid) and uid >= 0 and map_size(expected) == 4 do
    with true <- String.valid?(path) and not String.contains?(path, [<<0>>, "\n", "\r"]),
         true <- Path.type(path) == :absolute and Path.expand(path) == path,
         true <-
           byte_size(Path.dirname(path)) <= 16_384 and byte_size(Path.basename(path)) in 1..255,
         true <- private_stat?(main, uid, :regular) and private_stat?(parent, uid, :directory),
         true <- is_nil(wal) or private_stat?(wal, uid, :regular),
         true <- is_nil(shm) or private_stat?(shm, uid, :regular),
         true <- not is_nil(wal) or is_nil(shm),
         true <- matches_path?(Path.dirname(path), parent, uid, :directory),
         true <- matches_path?(path, main, uid, :regular),
         true <- matches_path?(path <> "-wal", wal, uid, :regular),
         true <- matches_path?(path <> "-shm", shm, uid, :regular),
         {:error, :enoent} <- File.lstat(path <> "-journal") do
      :ok
    else
      _ -> {:error, :snapshot_failed}
    end
  end

  defp validate_source(_, _, _), do: {:error, :snapshot_failed}

  defp private_stat?(
         %File.Stat{
           type: type,
           uid: uid,
           mode: mode,
           major_device: device,
           inode: inode,
           size: size
         },
         uid,
         type
       )
       when is_integer(mode) and is_integer(device) and device >= 0 and is_integer(inode) and
              inode > 0 and is_integer(size) and size >= 0,
       do: band(mode, 0o7777) == if(type == :directory, do: 0o700, else: 0o600)

  defp private_stat?(_, _, _), do: false

  defp same_object?(%File.Stat{} = left, %File.Stat{} = right),
    do:
      {left.type, left.major_device, left.minor_device, left.inode} ==
        {right.type, right.major_device, right.minor_device, right.inode}

  defp same_object?(_, _), do: false
  defp matches_path?(path, nil, _, _), do: File.lstat(path) == {:error, :enoent}

  defp matches_path?(path, expected, uid, type) do
    case File.lstat(path) do
      {:ok, stat} -> same_object?(stat, expected) and private_stat?(stat, uid, type)
      _ -> false
    end
  end

  defp executable do
    case :code.priv_dir(:swarm_code_daemon) do
      directory when is_list(directory) ->
        path =
          directory
          |> List.to_string()
          |> Path.join("native/swarm-schema-snapshot")
          |> Path.expand()

        case File.lstat(path) do
          {:ok, %File.Stat{type: :regular, mode: mode}} when band(mode, 0o111) != 0 -> {:ok, path}
          _ -> {:error, :snapshot_failed}
        end

      _ ->
        {:error, :snapshot_failed}
    end
  end

  defp arguments(state) do
    expected = state.expected
    main = state.receipts["snapshot.db"]
    wal = state.receipts["snapshot.db-wal"]

    [
      "v1",
      Path.dirname(state.path),
      Path.basename(state.path),
      expected.parent.major_device,
      expected.parent.inode,
      state.uid,
      expected.main.major_device,
      expected.main.inode,
      stat_number(expected.wal, :major_device),
      stat_number(expected.wal, :inode),
      stat_number(expected.shm, :major_device),
      stat_number(expected.shm, :inode),
      elem(main, 1),
      elem(main, 3),
      elem(wal, 1),
      elem(wal, 3),
      state.directory_stat.major_device,
      state.directory_stat.inode,
      state.timeout,
      @maximum_copy_bytes
    ]
    |> Enum.map(&to_string/1)
  end

  defp stat_number(nil, _), do: "-"
  defp stat_number(stat, key), do: Map.fetch!(stat, key)

  defp valid_response?(state, {:ok, response}) do
    case Regex.run(~r/\Asnapshot-v1 (0|[1-9][0-9]*) (0|[1-9][0-9]*) ([01])\n?\z/, response) do
      [_, main, wal, present] ->
        expected_presence = if is_nil(state.expected.wal), do: "0", else: "1"

        present == expected_presence and
          output_matches?(state, "snapshot.db", String.to_integer(main)) and
          output_matches?(state, "snapshot.db-wal", String.to_integer(wal)) and
          output_matches?(state, "snapshot.db-shm", 0) and
          String.to_integer(main) + String.to_integer(wal) <= @maximum_copy_bytes and
          (present == "1" or wal == "0")

      _ ->
        false
    end
  end

  defp valid_response?(_, _), do: false

  defp output_matches?(state, name, size) do
    case DirectoryHelper.private_identity(state.helper, name, state.uid) do
      {:ok, identity} ->
        put_elem(identity, 6, 0) == state.receipts[name] and elem(identity, 6) == size

      _ ->
        false
    end
  end
end
