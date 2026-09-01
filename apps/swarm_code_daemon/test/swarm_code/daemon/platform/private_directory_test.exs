defmodule SwarmCode.Daemon.Platform.PrivateDirectoryTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias SwarmCode.Daemon.Platform.PrivateDirectory

  test "creates a mode-0700 leaf and rejects a symlink in its place" do
    parent =
      Path.join(
        System.tmp_dir!(),
        "swarm-code-private-directory-#{System.unique_integer([:positive, :monotonic])}"
      )

    leaf = Path.join(parent, "private")
    File.mkdir_p!(parent)
    on_exit(fn -> File.rm_rf!(parent) end)

    uid = File.lstat!(parent).uid

    assert :ok = PrivateDirectory.ensure(leaf, uid)
    assert band(File.stat!(leaf).mode, 0o777) == 0o700

    File.rm_rf!(leaf)
    File.ln_s!(parent, leaf)

    assert {:error, {:unsafe_private_directory, ^leaf, :symlink}} =
             PrivateDirectory.ensure(leaf, uid)
  end
end
