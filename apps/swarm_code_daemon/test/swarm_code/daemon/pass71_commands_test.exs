defmodule SwarmCode.Daemon.Pass71CommandsTest do
  @moduledoc """
  pass71 finisher, from the dogfood review:

  - R3: a model polls a background process with `poll: pid, command: "true"`;
    `run/3` never runs the command when polling, but the permission asked for
    an approval to run `$ true` on every poll.
  - R7: the release runs under `umask 077`, and a `touch` the model ran in the
    project made a 0600 file. Commands and hooks get the user's own umask back
    from `SWARM_USER_UMASK`, which `rel/env.sh` keeps.
  """
  use ExUnit.Case, async: false
  import Bitwise

  alias SwarmCode.Domain.Tools.RunCommand

  test "a poll is a read whatever command rides along; a stop is not" do
    assert RunCommand.permission(%{"poll" => 4242}) == :read
    assert RunCommand.permission(%{"poll" => 4242, "command" => "true"}) == :read
    assert RunCommand.permission(%{"poll" => "4242", "command" => "rm -rf x"}) == :read
    assert RunCommand.permission(%{"poll" => 4242, "stop" => 4242}) == :execute
    assert RunCommand.permission(%{"stop" => 4242}) == :execute
    assert RunCommand.permission(%{"command" => "true"}) == :execute
  end

  test "a command gets the user's umask back from the private VM's" do
    dir = Path.join(System.tmp_dir!(), "pass71-umask-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    previous = System.get_env("SWARM_USER_UMASK")

    on_exit(fn ->
      if previous,
        do: System.put_env("SWARM_USER_UMASK", previous),
        else: System.delete_env("SWARM_USER_UMASK")
    end)

    System.put_env("SWARM_USER_UMASK", "0022")
    assert RunCommand.umask_prefix() == "umask 0022\n"

    {_, 0} =
      System.cmd("/bin/sh", ["-c", "umask 077\n" <> RunCommand.umask_prefix() <> "touch made"],
        cd: dir
      )

    assert (File.stat!(Path.join(dir, "made")).mode &&& 0o777) == 0o644

    # Anything that is not an octal umask is ignored, never interpolated.
    for bad <- ["", "022; rm -rf /", "999", "u=rwx"] do
      System.put_env("SWARM_USER_UMASK", bad)
      assert RunCommand.umask_prefix() == ""
    end
  end
end
