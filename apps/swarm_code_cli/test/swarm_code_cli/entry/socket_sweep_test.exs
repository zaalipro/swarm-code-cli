defmodule SwarmCodeCLI.Release.SocketSweepTest do
  @moduledoc """
  cli020 B10 (bugs-15): at start a session removes the private socket
  folders (`scl-p-*`, `scl-h-*`) a hard exit left behind: same owner, older
  than 60 s, and a socket that refuses connections. A live session's folder
  and a young one stay.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Release.SocketSweep

  setup do
    base = Path.join(System.tmp_dir!(), "b10-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    %{base: base}
  end

  defp folder(base, name, age_s) do
    dir = Path.join(base, name)
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    old = System.os_time(:second) - age_s
    File.touch!(dir, old)
    dir
  end

  defp stale_socket(dir) do
    path = Path.join(dir, "s")
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false])
    :ok = :gen_tcp.close(listen)
    path
  end

  test "only the stale folder of a dead session is removed", %{base: base} do
    stale = folder(base, "scl-p-stale", 120)
    stale_socket(stale)
    File.touch!(stale, System.os_time(:second) - 120)

    empty = folder(base, "scl-h-empty", 120)

    live = folder(base, "scl-p-live", 120)
    path = Path.join(live, "s")
    {:ok, listen} = :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false])
    on_exit(fn -> :gen_tcp.close(listen) end)
    File.touch!(live, System.os_time(:second) - 120)

    young = folder(base, "scl-p-young", 0)
    stale_socket(young)
    other = folder(base, "unrelated-folder", 120)

    removed = SocketSweep.sweep(base, System.os_time(:second))

    assert Enum.sort(removed) == Enum.sort([stale, empty])
    refute File.exists?(stale)
    refute File.exists?(empty)
    assert File.dir?(live)
    assert File.dir?(young)
    assert File.dir?(other)
  end

  test "a missing base folder is nothing to sweep" do
    assert SocketSweep.sweep("/nonexistent-#{System.unique_integer([:positive])}") == []
  end
end
