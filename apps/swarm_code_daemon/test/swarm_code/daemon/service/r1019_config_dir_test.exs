defmodule SwarmCode.Daemon.Service.R1019ConfigDirTest do
  @moduledoc """
  Pass 77 C-ARCH-7: a test that reads `Paths.config_dir/0` only in its own
  process sets the directory for that process (`SwarmCode.Test.ConfigDir.put/1`)
  and runs `async: true`: no application env, no other test affected.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Daemon.Service.ClipboardInbox
  alias SwarmCode.Daemon.Service.Settings.{Context, Facts}
  alias SwarmCode.Domain.Paths
  alias SwarmCode.Test.ConfigDir

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", 0::64>>

  @tag :tmp_dir
  test "the process key wins for this process only", %{tmp_dir: dir} do
    before = Application.get_env(:swarm_code_daemon, :domain_config_dir)
    other = Path.join(dir, "other")

    assert ConfigDir.put(other) == other
    assert Paths.config_dir() == other

    # Another process (here a task) does not see it, and nothing global moved.
    assert Task.async(fn -> Paths.config_dir() end) |> Task.await() != other
    assert Application.get_env(:swarm_code_daemon, :domain_config_dir) == before
  end

  @tag :tmp_dir
  test "the clipboard inbox lives under the process's directory", %{tmp_dir: dir} do
    ConfigDir.put(dir)
    now = System.monotonic_time(:millisecond)

    assert {:ok, %{"token" => token, "path" => path}, slots} = ClipboardInbox.open(%{}, now)
    assert path == Path.join([dir, "cli-inbox", token <> ".png"])
    assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700

    File.write!(path, @png)
    assert {:ok, @png, %{}} = ClipboardInbox.take(slots, token, now)
    refute File.exists?(path)

    assert {:ok, %{"path" => second}, slots} = ClipboardInbox.open(%{}, now)
    assert File.exists?(second)
    assert :ok = ClipboardInbox.close_all(slots)
    refute File.exists?(second)
  end

  @tag :tmp_dir
  test "the settings facts name the process's directory", %{tmp_dir: dir} do
    ConfigDir.put(dir)
    paths = Facts.body(%Context{}) |> Map.fetch!("paths")

    # The facts show a path under the home folder as `~/...`.
    assert paths["config_dir"] == tilde(dir)
    assert paths["user_skills"] == tilde(Path.join(dir, "skills"))
    assert paths["user_commands"] == tilde(Path.join(dir, "commands"))
    assert paths["user_workflows"] == tilde(Path.join(dir, "workflows"))
  end

  defp tilde(path) do
    home = System.user_home!()

    if String.starts_with?(path, home <> "/"),
      do: "~" <> String.replace_prefix(path, home, ""),
      else: path
  end
end
