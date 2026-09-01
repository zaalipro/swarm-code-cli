defmodule SwarmCode.Daemon.Files.AtomicReplaceTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias SwarmCode.Daemon.Files.AtomicReplace

  test "atomically replaces a file at the requested exact mode" do
    dir = private_tmp!()
    path = Path.join(dir, "owner.json")

    File.write!(path, "old")
    File.chmod!(path, 0o644)

    assert :ok = AtomicReplace.write(path, ["new", "\n"], mode: 0o600)
    assert File.read!(path) == "new\n"
    assert permissions(path) == 0o600
    assert temp_files(dir, ".owner.json.tmp.") == []
  end

  test "a write failure preserves the old file and cleans only its own random temp" do
    dir = private_tmp!()
    path = Path.join(dir, "owner.json")
    sentinel = Path.join(dir, ".owner.json.tmp.keep")

    File.write!(path, "old")
    File.chmod!(path, 0o600)
    File.write!(sentinel, "not ours")

    assert {:error, _reason} = AtomicReplace.write(path, ["partial", %{invalid: :iodata}])
    assert File.read!(path) == "old"
    assert permissions(path) == 0o600
    assert temp_files(dir, ".owner.json.tmp.") == [sentinel]
    assert File.read!(sentinel) == "not ours"
  end

  test "no-replace publication refuses an existing path unchanged" do
    dir = private_tmp!()
    path = Path.join(dir, "lease.db")
    File.write!(path, "existing")
    File.chmod!(path, 0o644)
    before = File.lstat!(path)

    assert {:error, {:pre_publication, :eexist}} =
             AtomicReplace.write(path, "replacement", mode: 0o600, replace: false)

    after_attempt = File.lstat!(path)
    assert File.read!(path) == "existing"

    assert {after_attempt.inode, band(after_attempt.mode, 0o7777)} ==
             {before.inode, band(before.mode, 0o7777)}

    assert temp_files(dir, ".lease.db.tmp.") == []
  end

  test "a publication failure is tagged pre-publication and preserves the destination" do
    dir = private_tmp!()
    path = Path.join(dir, "owner.json")
    File.write!(path, "old")
    File.chmod!(path, 0o600)

    publish = fn _temp, _path, _replace -> {:error, :injected_publish_failure} end

    assert {:error, {:pre_publication, :injected_publish_failure}} =
             AtomicReplace.write(path, "new", publish: publish)

    assert File.read!(path) == "old"
    assert temp_files(dir, ".owner.json.tmp.") == []
  end

  test "a directory sync failure is tagged post-publication after changing the destination" do
    dir = private_tmp!()
    path = Path.join(dir, "owner.json")
    File.write!(path, "old")

    sync_directory = fn _directory -> {:error, :injected_directory_sync_failure} end

    assert {:error, {:post_publication, :injected_directory_sync_failure}} =
             AtomicReplace.write(path, "new", sync_directory: sync_directory)

    assert File.read!(path) == "new"
    assert temp_files(dir, ".owner.json.tmp.") == []
  end

  test "a no-replace temp cleanup failure is tagged post-publication" do
    dir = private_tmp!()
    path = Path.join(dir, "lease.db")

    cleanup_temp = fn temp ->
      :ok = File.rm(temp)
      {:error, :injected_cleanup_failure}
    end

    assert {:error, {:post_publication, :injected_cleanup_failure}} =
             AtomicReplace.write(path, <<>>, replace: false, cleanup_temp: cleanup_temp)

    assert File.read!(path) == ""
    assert permissions(path) == 0o600
    assert temp_files(dir, ".lease.db.tmp.") == []
  end

  defp private_tmp! do
    dir =
      Path.join(
        System.tmp_dir!(),
        "swarm-code-atomic-replace-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp permissions(path), do: band(File.lstat!(path).mode, 0o7777)

  defp temp_files(dir, prefix) do
    dir
    |> File.ls!()
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(&Path.join(dir, &1))
    |> Enum.sort()
  end
end
