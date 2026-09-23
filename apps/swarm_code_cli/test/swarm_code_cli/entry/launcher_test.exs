defmodule SwarmCodeCLI.Release.LauncherTest do
  @moduledoc """
  Pass 70 E4: `rel/overlays/bin/swarmcode` run as a subprocess against a stub
  release. The launcher owns usage (exit 2, before any VM starts), maps the
  session flags to the environment the release reads, and picks the full
  screen, `-p` or the plain presenter. The stub records what it was asked and
  exits with the code the test chooses, which the launcher must pass through.
  """
  use ExUnit.Case, async: true

  @launcher Path.expand("../../../../../rel/overlays/bin/swarmcode", __DIR__)
  @conversation "7d01acff-1111-4111-8111-111111111111"

  @stub """
  #!/usr/bin/env bash
  {
    printf 'ARGS'
    for a in "$@"; do printf ' [%s]' "$a"; done
    printf '\\n'
    printf 'CONVERSATION=%s\\n' "${SWARM_CONVERSATION-<unset>}"
    printf 'MODEL=%s\\n' "${SWARM_MODEL_OVERRIDE-<unset>}"
    printf 'ROOT=%s\\n' "${SWARM_PROJECT_ROOT-<unset>}"
    printf 'TUI=%s\\n' "${SWARM_RELEASE_TUI-<unset>}"
  } >"$STUB_LOG"
  exit "${STUB_EXIT:-0}"
  """

  setup do
    base =
      Path.join(System.tmp_dir!(), "swarmcode-launcher-#{System.unique_integer([:positive])}")

    bin = Path.join(base, "release/bin")
    project = Path.join(base, "project")
    File.mkdir_p!(bin)
    File.mkdir_p!(project)
    File.mkdir_p!(Path.join(base, "release/releases"))
    File.cp!(@launcher, Path.join(bin, "swarmcode"))
    File.write!(Path.join(bin, "swarm_code_cli"), @stub)
    File.write!(Path.join(bin, "load_provider_env.sh"), ":\n")
    File.write!(Path.join(base, "release/releases/start_erl.data"), "16.0 0.1.0-dev\n")
    File.chmod!(Path.join(bin, "swarmcode"), 0o755)
    File.chmod!(Path.join(bin, "swarm_code_cli"), 0o755)
    on_exit(fn -> File.rm_rf!(base) end)

    %{
      launcher: Path.join(bin, "swarmcode"),
      project: project,
      log: Path.join(base, "stub.log")
    }
  end

  defp launch(context, args, env \\ []) do
    env =
      [
        {"STUB_LOG", context.log},
        {"SWARM_MODEL_OVERRIDE", nil},
        {"SWARM_CONVERSATION", nil},
        {"SWARM_RELEASE_TUI", nil},
        {"TERM", "xterm-256color"}
      ] ++ env

    {output, code} =
      System.cmd("bash", [context.launcher | args],
        env: env,
        cd: context.project,
        stderr_to_stdout: true
      )

    {code, output}
  end

  defp stub(context) do
    context.log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      case String.split(line, ["=", " "], parts: 2) do
        [key, value] -> {key, value}
        [key] -> {key, ""}
      end
    end)
  end

  describe "usage" do
    test "--help and --version answer without starting the release", context do
      assert {0, help} = launch(context, ["--help"])
      assert help =~ "Usage: swarmcode [DIR] [--new | --continue | --resume ID] [--model M]"
      assert help =~ "Exit codes: 0 done, 1 the run failed, 2 usage, 3 startup refused."
      assert {0, "swarmcode 0.1.0-dev\n"} = launch(context, ["--version"])
      refute File.exists?(context.log)
    end

    test "every usage error exits 2 with one line and starts nothing", context do
      for args <- [
            ["--bogus"],
            ["--resume"],
            ["--resume", "not-a-uuid"],
            ["--new", "--continue"],
            ["--model"],
            ["--model", " "],
            ["-p"],
            ["-p", "   "],
            ["-p", "one", "-p", "two"],
            ["--json"],
            ["--ndjson"],
            ["--plain", "-p", "x"],
            ["a", "b"]
          ] do
        assert {2, output} = launch(context, args), inspect(args)
        assert [line] = String.split(output, "\n", trim: true), inspect(args)
        assert line =~ ~r/^swarmcode: .+ Run 'swarmcode --help'\.$/
      end

      refute File.exists?(context.log)
    end

    test "a directory that does not exist is a usage error", context do
      assert {2, "swarmcode: 'nowhere' is not a directory.\n"} = launch(context, ["nowhere"])
    end
  end

  describe "-p" do
    test "evaluates the headless entry with only -p and --json; the rest is exported", context do
      assert {0, ""} =
               launch(context, [
                 "--resume",
                 @conversation,
                 "--model",
                 "anthropic/claude",
                 "-p",
                 "list the notes",
                 "--json"
               ])

      log = stub(context)

      assert log["ARGS"] ==
               "[eval] [SwarmCodeCLI.Release.main(System.argv())] [-p] [list the notes] [--json]"

      assert log["CONVERSATION"] == @conversation
      assert log["MODEL"] == "anthropic/claude"
      # The command ran in the project, so the project is where it ran.
      assert log["ROOT"] == resolved(context.project, "-P")
      assert log["TUI"] == "<unset>"
    end

    test "the run's exit code is the command's", context do
      for code <- [0, 1, 3] do
        assert {^code, _} = launch(context, ["-p", "hi"], [{"STUB_EXIT", "#{code}"}])
      end
    end

    test "without --model an exported override never applies", context do
      launch(context, ["-p", "hi"], [{"SWARM_MODEL_OVERRIDE", "stray"}])
      assert stub(context)["MODEL"] == "<unset>"
    end

    # pass71 F9 (review R6): a one-shot no longer lands in the working
    # conversation; -c and --resume still choose one, and so does the export.
    test "-p alone starts a new conversation", context do
      launch(context, ["-p", "hi"])
      assert stub(context)["CONVERSATION"] == "new"
      launch(context, ["-p", "hi"], [{"SWARM_CONVERSATION", @conversation}])
      assert stub(context)["CONVERSATION"] == @conversation
      launch(context, ["--plain"])
      assert stub(context)["CONVERSATION"] == "<unset>"
    end

    test "--new and --continue name the conversation; the flag wins over the export", context do
      launch(context, ["--new", "-p", "hi"], [{"SWARM_CONVERSATION", @conversation}])
      assert stub(context)["CONVERSATION"] == "new"
      launch(context, ["-c", "-p", "hi"])
      assert stub(context)["CONVERSATION"] == "latest"
    end
  end

  describe "the presenter" do
    test "--plain [--ndjson] evaluates the plain presenter for the named directory", context do
      dir = Path.join(context.project, "sub")
      File.mkdir_p!(dir)
      assert {0, _} = launch(context, ["--plain", "--ndjson", dir])
      log = stub(context)

      assert log["ARGS"] ==
               "[eval] [SwarmCodeCLI.Release.main(System.argv())] [--plain] [--ndjson]"

      assert log["ROOT"] == resolved(dir)
    end

    test "without a terminal the plain presenter answers, and says so", context do
      # System.cmd gives the launcher pipes, not a terminal.
      assert {0, output} = launch(context, [])
      assert output =~ "not a terminal, so the plain presenter answers (--plain)."
      assert stub(context)["ARGS"] =~ "[--plain]"
    end
  end

  # The temporary directory is behind a symlink on macOS: a named directory
  # is resolved the launcher's way (`cd && pwd`), the directory the command
  # runs in is the physical one (`pwd -P`).
  defp resolved(path, flag \\ "-L") do
    {path, 0} = System.cmd("bash", ["-c", "cd -- \"$1\" && pwd " <> flag, "_", path])
    String.trim(path)
  end
end
