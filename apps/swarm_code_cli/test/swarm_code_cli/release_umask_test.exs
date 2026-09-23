defmodule SwarmCodeCLI.ReleaseUmaskTest do
  @moduledoc """
  pass71 S3: everything the release writes (logs, sockets, temp files,
  backups) is owner-only. The release's `env.sh` (sourced by every `bin/`
  command, so `swarmcode`, `-p` and `--plain` alike) sets `umask 077`, and the
  VM it starts inherits it; so do the development session launchers.
  """
  use ExUnit.Case, async: true
  import Bitwise

  @root Path.expand("../../../..", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), "pass71-umask-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "a VM started under the release env writes owner-only files and directories", c do
    env_sh = Path.join(c.dir, "env.sh")
    File.write!(env_sh, EEx.eval_file(Path.join(@root, "rel/env.sh.eex")))
    erl = System.find_executable("erl")
    assert erl, "erl is on the PATH under mise"

    file = Path.join(c.dir, "written.log")
    subdir = Path.join(c.dir, "made")

    eval =
      ~s|ok = file:write_file("#{file}", <<"x">>), ok = file:make_dir("#{subdir}"), halt().|

    # A permissive umask first: the env script is what narrows it.
    {output, status} =
      System.cmd(
        "/bin/sh",
        ["-c", ~s(umask 022; . "$1"; exec "$2" -noshell -eval "$3"), "sh", env_sh, erl, eval],
        stderr_to_stdout: true,
        env: [{"ELIXIR_ERL_OPTIONS", nil}]
      )

    assert status == 0, output
    assert mode(file) == 0o600
    assert mode(subdir) == 0o700
  end

  test "the development session launchers narrow the umask too" do
    for script <- ~w(run_saved_session.sh run_plain_session.sh run_live_session.sh) do
      lines = @root |> Path.join("scripts/dev/#{script}") |> File.read!() |> String.split("\n")
      assert "umask 077" in lines, script
    end
  end

  defp mode(path), do: File.stat!(path).mode &&& 0o777
end
