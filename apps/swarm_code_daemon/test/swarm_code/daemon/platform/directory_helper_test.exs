defmodule SwarmCode.Daemon.Platform.DirectoryHelperTest do
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Platform.DirectoryHelper
  alias SwarmCode.Daemon.Schema.Probe
  alias Exqlite.Sqlite3

  test "relative source links, publication links, and unlinks follow the held directory" do
    directory = private_directory!()
    source_basename = "source database.sqlite3"
    source = Path.join(directory, source_basename)
    File.write!(source, "source inode")
    File.chmod!(source, 0o600)

    assert {:ok, helper} =
             DirectoryHelper.start(directory, source_basenames: [source_basename])

    on_exit(fn -> terminate_os_pid(helper.os_pid) end)
    assert {:ok, physical_directory} = DirectoryHelper.pwd(helper)
    assert same_object?(physical_directory, directory)

    assert :ok = DirectoryHelper.link_source(helper, 0, ".pinned.sqlite3")
    assert same_object?(source, Path.join(directory, ".pinned.sqlite3"))

    moved = directory <> "-moved"
    on_exit(fn -> File.rm_rf!(moved) end)
    File.rename!(directory, moved)
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)

    assert {:ok, current_directory} = DirectoryHelper.pwd(helper)
    assert same_object?(current_directory, moved)
    assert :ok = DirectoryHelper.link(helper, ".pinned.sqlite3", ".published.sqlite3")

    assert same_object?(
             Path.join(moved, source_basename),
             Path.join(moved, ".published.sqlite3")
           )

    assert :ok = DirectoryHelper.unlink(helper, ".published.sqlite3")
    assert :ok = DirectoryHelper.unlink(helper, ".pinned.sqlite3")
    assert File.ls!(directory) == []
    assert File.ls!(moved) == [source_basename]
    assert :ok = DirectoryHelper.stop(helper)
    refute os_pid_alive?(helper.os_pid)
  end

  test "relative create, copy, read, stat, sync, and identity-clean removal follow the held cwd" do
    directory = private_directory!()
    source = Path.join(directory, "source.sqlite3")
    File.write!(source, String.duplicate("bounded-source", 128))
    File.chmod!(source, 0o600)
    uid = File.lstat!(directory).uid

    assert {:ok, helper} = DirectoryHelper.start(directory)
    on_exit(fn -> terminate_os_pid(helper.os_pid) end)

    moved = directory <> "-moved"
    on_exit(fn -> File.rm_rf!(moved) end)
    File.rename!(directory, moved)
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)

    assert {:ok, written_identity} =
             DirectoryHelper.write_private(helper, ".manifest.json", ~s({"ok":true}), uid)

    assert {:ok, ~s({"ok":true})} =
             DirectoryHelper.read_private(helper, ".manifest.json", uid, 1_024)

    assert :ok = DirectoryHelper.sync_file(helper, ".manifest.json", written_identity, uid)

    assert {:ok, copied_identity} =
             DirectoryHelper.copy_private(helper, "source.sqlite3", ".restore.sqlite3", uid)

    assert {:ok, ^copied_identity} =
             DirectoryHelper.private_identity(helper, ".restore.sqlite3", uid)

    assert File.read!(Path.join(moved, ".restore.sqlite3")) ==
             File.read!(Path.join(moved, "source.sqlite3"))

    assert File.ls!(directory) == []
    assert :ok = DirectoryHelper.unlink_identity(helper, ".restore.sqlite3", copied_identity)
    assert :ok = DirectoryHelper.unlink_identity(helper, ".manifest.json", written_identity)
    assert :ok = DirectoryHelper.stop(helper)
    refute os_pid_alive?(helper.os_pid)
  end

  test "a prepared copy keeps its descriptors alive until the finishing request" do
    directory = private_directory!()
    source = Path.join(directory, "source.sqlite3")
    destination = Path.join(directory, ".restore.sqlite3")
    File.write!(source, :binary.copy("prepared-copy", 128))
    File.chmod!(source, 0o600)
    uid = File.lstat!(directory).uid

    assert {:ok, helper} = DirectoryHelper.start(directory)
    on_exit(fn -> terminate_os_pid(helper.os_pid) end)

    assert {:ok, {:regular, _, _, _, ^uid, _, 0}} =
             DirectoryHelper.prepare_copy(
               helper,
               Path.basename(source),
               Path.basename(destination),
               uid
             )

    assert {:ok, finished_identity} = DirectoryHelper.finish_copy(helper)
    assert File.read!(destination) == File.read!(source)

    assert :ok =
             DirectoryHelper.unlink_identity(
               helper,
               Path.basename(destination),
               finished_identity
             )

    assert :ok = DirectoryHelper.stop(helper)
    refute os_pid_alive?(helper.os_pid)
  end

  test "cleanup can restore the held directory mode without touching its pathname replacement" do
    directory = private_directory!()
    uid = File.lstat!(directory).uid
    assert {:ok, helper} = DirectoryHelper.start(directory)
    on_exit(fn -> terminate_os_pid(helper.os_pid) end)

    assert {:ok, identity} =
             DirectoryHelper.write_private(helper, ".owned", "owned", uid)

    moved = directory <> "-moved"
    on_exit(fn -> File.rm_rf!(moved) end)
    File.rename!(directory, moved)
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    File.write!(Path.join(directory, ".owned"), "substitute")
    File.chmod!(moved, 0o500)

    assert :ok = DirectoryHelper.repair_mode(helper, 0o700, uid)
    assert :ok = DirectoryHelper.unlink_identity(helper, ".owned", identity)
    assert File.read!(Path.join(directory, ".owned")) == "substitute"
    assert File.ls!(moved) == []
    assert :ok = DirectoryHelper.stop(helper)
  end

  test "a partial source-pin set is identity-cleaned before open_source returns an error" do
    directory = private_directory!()
    source = SchemaFixture.database!(:current)
    uid = File.lstat!(source).uid
    assert {:ok, probe} = Probe.inspect(source)
    assert {:ok, helper} = DirectoryHelper.start(directory)
    on_exit(fn -> terminate_os_pid(helper.os_pid) end)

    main_identity = file_identity(source)
    wrong_wal_identity = put_elem(main_identity, 3, elem(main_identity, 3) + 1)

    assert {:error, _reason} =
             DirectoryHelper.open_source(
               helper,
               [
                 {:main, source, ".pin.sqlite3", main_identity},
                 {:wal, source, ".pin.sqlite3-wal", wrong_wal_identity}
               ],
               probe,
               uid
             )

    assert File.ls!(directory) == []
    assert :ok = DirectoryHelper.stop(helper)
    refute os_pid_alive?(helper.os_pid)
  end

  @tag timeout: 60_000
  test "a private SHM inode is removed when mode changes after its exclusive create" do
    directory = private_directory!()
    database = SchemaFixture.database!(:current)
    assert {:ok, probe} = Probe.inspect(database)
    shm_source = Path.join(Path.dirname(database), "large-private-shm")
    write_mebibytes!(shm_source, 256)
    File.chmod!(shm_source, 0o600)
    uid = File.lstat!(database).uid
    assert {:ok, helper} = DirectoryHelper.start(directory)
    on_exit(fn -> terminate_os_pid(helper.os_pid) end)
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        DirectoryHelper.open_source(
          helper,
          [
            {:shm, shm_source, ".pin.sqlite3-shm", file_identity(shm_source)},
            {:main, database, ".pin.sqlite3", file_identity(database)}
          ],
          probe,
          uid
        )
      end)

    wait_for_path!(Path.join(directory, ".pin.sqlite3-shm"), 10_000)
    signal_os_pid!(helper.os_pid, "-STOP")
    File.chmod!(directory, 0o500)
    signal_os_pid!(helper.os_pid, "-CONT")

    assert {:error, _reason} = Task.await(task, 30_000)
    assert :ok = DirectoryHelper.stop(helper)
    assert permissions(directory) == 0o700
    assert File.ls!(directory) == []
  end

  @tag timeout: 60_000
  test "requester death during a private SHM copy reaps the helper and removes every pin" do
    directory = private_directory!()
    database = SchemaFixture.database!(:current)
    assert {:ok, probe} = Probe.inspect(database)
    shm_source = Path.join(Path.dirname(database), "large-requester-death-shm")
    write_mebibytes!(shm_source, 256)
    File.chmod!(shm_source, 0o600)
    uid = File.lstat!(database).uid
    test = self()
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        {:ok, helper} = DirectoryHelper.start(directory)
        send(test, {:copying_shm_helper, helper})

        DirectoryHelper.open_source(
          helper,
          [
            {:shm, shm_source, ".pin.sqlite3-shm", file_identity(shm_source)},
            {:main, database, ".pin.sqlite3", file_identity(database)}
          ],
          probe,
          uid
        )
      end)

    assert_receive {:copying_shm_helper, helper}, 5_000
    owner_monitor = Process.monitor(helper.owner)
    on_exit(fn -> terminate_os_pid(helper.os_pid) end)
    wait_for_path!(Path.join(directory, ".pin.sqlite3-shm"), 10_000)
    signal_os_pid!(helper.os_pid, "-STOP")
    assert Task.shutdown(task, :brutal_kill) == nil

    assert_receive {:DOWN, ^owner_monitor, :process, _owner, :normal}, 10_000
    refute os_pid_alive?(helper.os_pid)
    assert permissions(directory) == 0o700
    assert File.ls!(directory) == []
  end

  @tag timeout: 60_000
  test "requester death during a private SHM copy never adopts a substituted pathname" do
    directory = private_directory!()
    database = SchemaFixture.database!(:current)
    assert {:ok, probe} = Probe.inspect(database)
    shm_source = Path.join(Path.dirname(database), "large-substitution-shm")
    write_mebibytes!(shm_source, 256)
    File.chmod!(shm_source, 0o600)
    uid = File.lstat!(database).uid
    test = self()
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        {:ok, helper} = DirectoryHelper.start(directory)
        send(test, {:substitution_shm_helper, helper})

        DirectoryHelper.open_source(
          helper,
          [
            {:shm, shm_source, ".pin.sqlite3-shm", file_identity(shm_source)},
            {:main, database, ".pin.sqlite3", file_identity(database)}
          ],
          probe,
          uid
        )
      end)

    assert_receive {:substitution_shm_helper, helper}, 5_000
    owner_monitor = Process.monitor(helper.owner)
    on_exit(fn -> terminate_os_pid(helper.os_pid) end)
    substituted = Path.join(directory, ".pin.sqlite3-shm")
    wait_for_path!(substituted, 10_000)
    signal_os_pid!(helper.os_pid, "-STOP")
    File.rm!(substituted)
    File.write!(substituted, "substitute")
    File.chmod!(substituted, 0o600)
    assert Task.shutdown(task, :brutal_kill) == nil

    assert_receive {:DOWN, ^owner_monitor, :process, _owner, :normal}, 10_000
    refute os_pid_alive?(helper.os_pid)
    assert permissions(directory) == 0o700
    assert File.read!(substituted) == "substitute"
    assert File.ls!(directory) == [".pin.sqlite3-shm"]
  end

  test "a WAL source without SHM gets a private rebuildable SHM pin and leaves no aliases" do
    directory = private_directory!()
    database = SchemaFixture.database!(:current)
    writer = SchemaFixture.open_uncheckpointed_wal!(database)
    on_exit(fn -> Sqlite3.close(writer) end)
    assert {:ok, probe} = Probe.inspect(database)

    source_directory = private_directory!()
    source = Path.join(source_directory, "source.sqlite3")
    File.cp!(database, source)
    File.cp!(database <> "-wal", source <> "-wal")
    File.chmod!(source, 0o600)
    File.chmod!(source <> "-wal", 0o600)
    refute File.exists?(source <> "-shm")

    uid = File.lstat!(source).uid
    assert {:ok, helper} = DirectoryHelper.start(directory)
    on_exit(fn -> terminate_os_pid(helper.os_pid) end)

    assert {:ok, %{main: _, wal: _, shm: nil}} =
             DirectoryHelper.open_source(
               helper,
               [
                 {:main, source, ".pin.sqlite3", file_identity(source)},
                 {:wal, source <> "-wal", ".pin.sqlite3-wal", file_identity(source <> "-wal")},
                 {:shm, source <> "-shm", ".pin.sqlite3-shm", nil}
               ],
               probe,
               uid
             )

    assert :ok = DirectoryHelper.close_source(helper)
    assert File.ls!(directory) == []
    assert :ok = DirectoryHelper.stop(helper)
  end

  test "failure after helper Port open terminates, reaps, and releases the exact child" do
    directory = private_directory!()

    assert {:error, :injected_helper_start_failure} =
             DirectoryHelper.start(directory,
               test_fail_after_port_open: true,
               test_observer: self()
             )

    assert_receive {:directory_helper_started, os_pid}
    assert_receive {:directory_helper_terminal, ^os_pid}
    refute os_pid_alive?(os_pid)
  end

  test "requester death terminates and reaps the exact helper shell" do
    directory = private_directory!()
    test = self()
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        {:ok, helper} = DirectoryHelper.start(directory)
        send(test, {:directory_helper_started, helper})

        receive do
          :keep_helper_alive -> :ok
        end
      end)

    assert_receive {:directory_helper_started, helper}, 5_000
    owner_monitor = Process.monitor(helper.owner)
    on_exit(fn -> terminate_os_pid(helper.os_pid) end)

    assert Task.shutdown(task, :brutal_kill) == nil
    assert_receive {:DOWN, ^owner_monitor, :process, _owner, :normal}, 5_000
    refute os_pid_alive?(helper.os_pid)
  end

  test "requester death removes a source link reserved by the broker" do
    directory = private_directory!()
    source_basename = "source.sqlite3"
    source = Path.join(directory, source_basename)
    File.write!(source, "source inode")
    File.chmod!(source, 0o600)
    test = self()
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        {:ok, helper} =
          DirectoryHelper.start(directory, source_basenames: [source_basename])

        :ok = DirectoryHelper.link_source(helper, 0, ".pinned.sqlite3")
        send(test, {:linked_source_helper, helper})

        receive do
          :keep_helper_alive -> :ok
        end
      end)

    assert_receive {:linked_source_helper, helper}, 5_000
    owner_monitor = Process.monitor(helper.owner)
    on_exit(fn -> terminate_os_pid(helper.os_pid) end)
    assert Task.shutdown(task, :brutal_kill) == nil
    assert_receive {:DOWN, ^owner_monitor, :process, _owner, :normal}, 5_000
    refute os_pid_alive?(helper.os_pid)
    assert File.ls!(directory) == [source_basename]
  end

  test "requester death cleans the ledger after the operation child is SIGSTOPed" do
    directory = private_directory!()
    uid = File.lstat!(directory).uid
    test = self()
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        {:ok, helper} = DirectoryHelper.start(directory)
        {:ok, _identity} = DirectoryHelper.write_private(helper, ".owned-temp", "owned", uid)
        send(test, {:stoppable_directory_helper, helper})

        receive do
          :keep_helper_alive -> :ok
        end
      end)

    assert_receive {:stoppable_directory_helper, helper}, 5_000
    owner_monitor = Process.monitor(helper.owner)
    on_exit(fn -> terminate_os_pid(helper.os_pid) end)
    signal_os_pid!(helper.os_pid, "-STOP")
    assert Task.shutdown(task, :brutal_kill) == nil
    assert_receive {:DOWN, ^owner_monitor, :process, _owner, :normal}, 10_000
    refute os_pid_alive?(helper.os_pid)
    assert permissions(directory) == 0o700
    assert File.ls!(directory) == []
  end

  for fault <- [:malformed_write_private, :oversized_write_private] do
    test "a #{fault} reply cleans broker-owned files before the helper exits normally" do
      directory = private_directory!()
      uid = File.lstat!(directory).uid

      assert {:ok, helper} =
               DirectoryHelper.start(directory, test_broker_fault: unquote(fault))

      owner_monitor = Process.monitor(helper.owner)
      on_exit(fn -> terminate_os_pid(helper.os_pid) end)

      assert {:error, :invalid_helper_response} =
               DirectoryHelper.write_private(helper, ".owned-by-broker", "owned", uid)

      assert_receive {:DOWN, ^owner_monitor, :process, _owner, :normal}, 5_000
      refute os_pid_alive?(helper.os_pid)
      assert permissions(directory) == 0o700
      assert File.ls!(directory) == []
    end
  end

  test "an unexpected prepared-copy worker exit retains cleanup ownership" do
    directory = private_directory!()
    source = Path.join(directory, "source.sqlite3")
    File.write!(source, :binary.copy("copy-owner-crash", 128))
    File.chmod!(source, 0o600)
    uid = File.lstat!(directory).uid

    assert {:ok, helper} =
             DirectoryHelper.start(directory, test_broker_fault: :crash_finish_copy)

    on_exit(fn -> terminate_os_pid(helper.os_pid) end)

    assert {:ok, _identity} =
             DirectoryHelper.prepare_copy(helper, "source.sqlite3", ".restore.sqlite3", uid)

    assert {:error, :directory_operation_failed} = DirectoryHelper.finish_copy(helper)
    assert :ok = DirectoryHelper.stop(helper)
    refute os_pid_alive?(helper.os_pid)
    assert File.ls!(directory) == ["source.sqlite3"]
  end

  defp private_directory! do
    directory =
      Path.join(
        System.tmp_dir!(),
        "swarm-code-directory-helper-" <>
          Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)
    directory
  end

  defp same_object?(left, right) do
    left_stat = File.lstat!(left)
    right_stat = File.lstat!(right)

    {left_stat.type, left_stat.major_device, left_stat.minor_device, left_stat.inode} ==
      {right_stat.type, right_stat.major_device, right_stat.minor_device, right_stat.inode}
  end

  defp file_identity(path) do
    stat = File.lstat!(path)

    {stat.type, stat.major_device, stat.minor_device, stat.inode, stat.uid, stat.mode, stat.size}
  end

  defp os_pid_alive?(pid) do
    case System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp signal_os_pid!(pid, signal) do
    assert {_, 0} =
             System.cmd("/bin/kill", [signal, Integer.to_string(pid)], stderr_to_stdout: true)

    :ok
  end

  defp write_mebibytes!(path, count) do
    chunk = :binary.copy(<<0>>, 1_024 * 1_024)
    {:ok, io} = File.open(path, [:write, :binary, :exclusive])

    try do
      for _index <- 1..count do
        :ok = IO.binwrite(io, chunk)
      end
    after
      :ok = File.close(io)
    end
  end

  defp wait_for_path!(path, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_for_path!(path, deadline)
  end

  defp do_wait_for_path!(path, deadline) do
    cond do
      File.exists?(path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("timed out waiting for #{Path.basename(path)}")

      true ->
        receive do
        after
          1 -> do_wait_for_path!(path, deadline)
        end
    end
  end

  defp permissions(path), do: Bitwise.band(File.lstat!(path).mode, 0o7777)

  defp terminate_os_pid(pid) do
    if os_pid_alive?(pid) do
      _ = System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
    end

    :ok
  end
end
