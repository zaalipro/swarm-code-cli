defmodule SwarmCode.Daemon.Platform.PrivateDirectoryTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias SwarmCode.Daemon.Platform.PrivateDirectory

  test "accepts an owned mode-0700 directory" do
    {leaf, uid} = temp_leaf()
    File.mkdir!(leaf)
    File.chmod!(leaf, 0o700)

    assert :ok = PrivateDirectory.ensure(leaf, uid)
    assert permissions(leaf) == 0o700
  end

  test "fails closed without changing an owned directory with broader permissions" do
    {leaf, uid} = temp_leaf()
    File.mkdir!(leaf)
    File.chmod!(leaf, 0o755)

    assert {:error, {:unsafe_private_directory, ^leaf, :permissions}} =
             PrivateDirectory.ensure(leaf, uid)

    assert permissions(leaf) == 0o755
  end

  test "rejects a symlink" do
    {leaf, uid} = temp_leaf()
    target = Path.join(Path.dirname(leaf), "target")
    File.mkdir!(target)
    File.ln_s!(target, leaf)

    assert {:error, {:unsafe_private_directory, ^leaf, :symlink}} =
             PrivateDirectory.ensure(leaf, uid)
  end

  test "creates an absent mode-0700 leaf when the process umask is 077" do
    {leaf, uid} = temp_leaf()
    elixir = System.find_executable("elixir") || flunk("elixir executable is unavailable")
    ebin = Application.app_dir(:swarm_code_daemon, "ebin")

    code = """
    case SwarmCode.Daemon.Platform.PrivateDirectory.ensure(System.fetch_env!("LEAF"), #{uid}) do
      :ok -> :ok
      error -> IO.inspect(error); System.halt(1)
    end
    """

    assert {"", 0} =
             System.cmd(
               "/bin/sh",
               [
                 "-c",
                 "umask 077; exec \"$@\"",
                 "private-directory-test",
                 elixir,
                 "-pa",
                 ebin,
                 "-e",
                 code
               ],
               env: [{"LEAF", leaf}],
               stderr_to_stdout: true
             )

    assert permissions(leaf) == 0o700
  end

  test "a symlink substituted after absence detection cannot have its target mutated" do
    {leaf, uid} = temp_leaf()
    target = Path.join(Path.dirname(leaf), "target")
    File.mkdir!(target)
    File.chmod!(target, 0o755)

    mkdir = fn ^leaf ->
      File.ln_s!(target, leaf)
      File.mkdir(leaf)
    end

    assert {:error, {:unsafe_private_directory, ^leaf, :symlink}} =
             PrivateDirectory.ensure(leaf, uid, mkdir: mkdir)

    assert permissions(target) == 0o755
  end

  defp temp_leaf do
    parent =
      Path.join(
        System.tmp_dir!(),
        "swarm-code-private-directory-#{System.unique_integer([:positive, :monotonic])}"
      )

    leaf = Path.join(parent, "private")
    File.mkdir_p!(parent)
    on_exit(fn -> File.rm_rf!(parent) end)

    {leaf, File.lstat!(parent).uid}
  end

  defp permissions(path), do: band(File.lstat!(path).mode, 0o777)
end
