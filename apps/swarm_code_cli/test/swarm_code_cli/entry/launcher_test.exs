defmodule SwarmCodeCLI.Release.LauncherTest do
  @moduledoc """
  Pass 70 E4: `rel/overlays/bin/ncode` run as a subprocess against a stub
  release. The launcher owns usage (exit 2, before any VM starts), maps the
  session flags to the environment the release reads, and picks the full
  screen, `-p` or the plain presenter. The stub records what it was asked and
  exits with the code the test chooses, which the launcher must pass through.
  """
  use ExUnit.Case, async: true

  @launcher Path.expand("../../../../../rel/overlays/bin/ncode", __DIR__)
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
    printf 'PIPED=%s\\n' "${SWARM_STDIN_PIPED-<unset>}"
    printf 'PICKER=%s\\n' "${SWARM_RESUME_PICKER-<unset>}"
    printf 'APPROVAL=%s\\n' "${SWARM_HEADLESS_APPROVAL-<unset>}"
  } >"$STUB_LOG"
  exit "${STUB_EXIT:-0}"
  """

  setup do
    base =
      Path.join(System.tmp_dir!(), "ncode-launcher-#{System.unique_integer([:positive])}")

    bin = Path.join(base, "release/bin")
    project = Path.join(base, "project")
    File.mkdir_p!(bin)
    File.mkdir_p!(project)
    File.mkdir_p!(Path.join(base, "release/releases"))
    File.cp!(@launcher, Path.join(bin, "ncode"))
    File.write!(Path.join(bin, "swarm_code_cli"), @stub)
    File.write!(Path.join(bin, "load_provider_env.sh"), ":\n")
    File.write!(Path.join(base, "release/releases/start_erl.data"), "16.0 0.1.0\n")
    File.chmod!(Path.join(bin, "ncode"), 0o755)
    File.chmod!(Path.join(bin, "swarm_code_cli"), 0o755)
    on_exit(fn -> File.rm_rf!(base) end)

    %{
      launcher: Path.join(bin, "ncode"),
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

  # The launcher on a pseudo-terminal (script(1)), for the full-screen path.
  defp tty(context, args) do
    {output, code} =
      System.cmd("script", ["-q", "/dev/null", "bash", context.launcher | args],
        env: [{"STUB_LOG", context.log}, {"TERM", "xterm-256color"}, {"SWARM_CONVERSATION", nil}],
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
    # cli020 finisher: bash 5.3 writes a here-document into a pipe when it
    # fits the pipe size it was built for; when macOS hands out small (512
    # byte) pipes under pipe-memory pressure, `cat <<'HELP'` waited for ever
    # and `ncode --help` hung. The launcher prints its words with builtins.
    test "the launcher uses no here-document" do
      refute File.read!(@launcher) =~ ~r/<<-?\s*['"]?[A-Z_]+/
    end

    test "--help and --version answer without starting the release", context do
      assert {0, help} = launch(context, ["--help"])
      assert help =~ "Usage: ncode [DIR] [--new | --continue | --resume ID] [--model M]"

      assert help =~
               "Exit codes: 0 done, 1 the run failed, 2 usage, 3 startup refused,\n4 changed"

      assert {0, "ncode 0.1.0\n"} = launch(context, ["--version"])
      refute File.exists?(context.log)
    end

    test "every usage error exits 2 with one line and starts nothing", context do
      for args <- [
            ["--bogus"],
            ["--resume"],
            ["--resume", " "],
            ["--new", "--continue"],
            ["--model"],
            ["--model", " "],
            ["-p"],
            ["-p", "   "],
            ["-p", "one", "-p", "two"],
            ["--ndjson"],
            ["--plain", "-p", "x"],
            ["a", "b"]
          ] do
        assert {2, output} = launch(context, args), inspect(args)
        assert [line] = String.split(output, "\n", trim: true), inspect(args)
        assert line =~ ~r/^ncode: .+ Run 'ncode --help'\.$/
      end

      refute File.exists?(context.log)
    end

    # cli020 B4: with --json the usage error is also the JSON summary on stdout.
    test "with --json a usage error prints the summary object on stdout", context do
      for {args, sentence} <- [
            {["--json"], "--json goes with -p. Run 'ncode --help'."},
            {["-p", "x", "--json", "--bogus\"\\"],
             "unknown option '--bogus\"\\'. Run 'ncode --help'."}
          ] do
        {stdout, 2} =
          System.cmd("bash", ["-c", "bash \"$@\" 2>/dev/null", "_", context.launcher | args],
            env: [{"STUB_LOG", context.log}],
            cd: context.project
          )

        assert %{"exit_code" => 2, "state" => "not_started", "error" => ^sentence, "denied" => []} =
                 Jason.decode!(stdout)
      end

      refute File.exists?(context.log)
    end

    test "a directory that does not exist is a usage error", context do
      assert {2, "ncode: './nowhere' is not a directory.\n"} = launch(context, ["./nowhere"])
    end

    # cli020 B16 (onboarding-10, onboarding-24).
    test "help, version, -v and doctor are words; an unknown word says so", context do
      assert {0, help} = launch(context, ["help"])
      assert help =~ "Examples:\n  ncode\n  ncode -p \"explain this repo\" --json\n"
      assert help =~ "ncode settings providers\n  ncode config doctor\n"
      assert help =~ "--fail-on-denied"
      assert help =~ "--model, -m M"
      assert help =~ "4 changed elsewhere (ncode config)"
      assert {0, "ncode 0.1.0\n"} = launch(context, ["version"])
      assert {0, "ncode 0.1.0\n"} = launch(context, ["-v"])
      refute File.exists?(context.log)

      assert {0, _} = launch(context, ["doctor", "--json"])

      assert stub(context)["ARGS"] ==
               "[eval] [SwarmCodeCLI.Release.main(System.argv())] [config] [doctor] [--json]"

      assert {2, output} = launch(context, ["sttings"])

      assert output ==
               "ncode: 'sttings' is not a folder or a command. Did you mean --help? " <>
                 "(To open a folder named sttings, use ./sttings.)\n"

      File.mkdir_p!(Path.join(context.project, "help"))
      assert {0, _} = launch(context, ["./help"])
      assert stub(context)["ROOT"] =~ "/help"
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

    # cli020 B1: piped stdin goes with the prompt; /dev/null and `-p -` never
    # mark it (the release reads `-p -` itself).
    test "a pipe or a file on stdin is marked for the prompt; /dev/null is not", context do
      launch(context, ["-p", "hi"])
      assert stub(context)["PIPED"] == "1"

      file = Path.join(context.project, "input.txt")
      File.write!(file, "diff")

      for {redirect, expected} <- [{file, "1"}, {"/dev/null", "<unset>"}] do
        System.cmd("bash", ["-c", "bash \"$1\" -p hi < \"$2\"", "_", context.launcher, redirect],
          env: [{"STUB_LOG", context.log}, {"SWARM_STDIN_PIPED", "1"}],
          cd: context.project
        )

        assert stub(context)["PIPED"] == expected, redirect
      end

      launch(context, ["-p", "-"])
      assert stub(context)["PIPED"] == "<unset>"
    end

    test "--fail-on-denied is passed to the headless entry", context do
      launch(context, ["-p", "hi", "--fail-on-denied", "--json"])

      assert stub(context)["ARGS"] ==
               "[eval] [SwarmCodeCLI.Release.main(System.argv())] [-p] [hi] [--json] [--fail-on-denied]"

      launch(context, ["--plain", "--fail-on-denied"])
      assert stub(context)["ARGS"] =~ "[--plain] [--fail-on-denied]"

      assert {2, "ncode: --fail-on-denied goes with -p or --plain. Run 'ncode --help'.\n"} =
               launch(context, ["--fail-on-denied"])
    end

    # cli020 B19: a prefix or a title passes to the release, which resolves it.
    test "--resume takes a prefix or a title; bare --resume is the TUI's picker", context do
      launch(context, ["-r", "Fix the login", "-p", "hi"])
      assert stub(context)["CONVERSATION"] == "Fix the login"
      launch(context, ["--resume", "7d01ac", "--plain"])
      assert stub(context)["CONVERSATION"] == "7d01ac"

      for args <- [["--resume", "-p", "hi"], ["--plain", "--resume"]] do
        assert {2, output} = launch(context, args), inspect(args)

        assert output ==
                 "ncode: --resume needs an id or a title here; ncode --resume alone opens the picker. Run 'ncode --help'.\n"
      end

      assert {0, output} = tty(context, ["--resume"])
      assert stub(context)["TUI"] == "1"
      assert stub(context)["PICKER"] == "1"
      assert stub(context)["CONVERSATION"] == "latest"
      # cli020 B20 (onboarding-18): the startup line, no newline.
      assert output =~ "Starting ncode…"
      refute output =~ "Starting ncode…\r\n"

      tty(context, [])
      assert stub(context)["PICKER"] == "<unset>"
    end

    # cli020 B23 (competitors-4).
    test "the other headless flags pass to the release; --approval is exported", context do
      launch(context, [
        "-p",
        "hi",
        "--output-format",
        "stream-json",
        "--max-turns",
        "5",
        "--max-budget-usd=0.25",
        "--approval",
        "full"
      ])

      log = stub(context)

      assert log["ARGS"] ==
               "[eval] [SwarmCodeCLI.Release.main(System.argv())] [-p] [hi] " <>
                 "[--output-format] [stream-json] [--max-turns] [5] [--max-budget-usd] [0.25]"

      assert log["APPROVAL"] == "full_access"

      launch(context, ["-p", "hi", "--output-format", "json"], [
        {"SWARM_HEADLESS_APPROVAL", "auto"}
      ])

      log = stub(context)
      assert log["ARGS"] =~ "[-p] [hi] [--json]"
      assert log["APPROVAL"] == "<unset>"

      for {args, line} <- [
            {["--max-turns", "2"], "--max-turns goes with -p."},
            {["-p", "x", "--max-turns", "300"], "--max-turns needs a number from 1 to 200."},
            {["-p", "x", "--max-budget-usd", "0.0"],
             "--max-budget-usd needs an amount above 0 (in dollars)."},
            {["-p", "x", "--approval", "yolo"], "--approval is read-only, auto or full."},
            {["-p", "x", "--output-format", "xml"],
             "--output-format is text, json or stream-json."}
          ] do
        assert {2, output} = launch(context, args), inspect(args)
        assert output == "ncode: #{line} Run 'ncode --help'.\n"
      end

      {stdout, 2} =
        System.cmd(
          "bash",
          [
            "-c",
            "bash \"$@\" 2>/dev/null",
            "_",
            context.launcher,
            "-p",
            "x",
            "--output-format",
            "stream-json",
            "--max-turns",
            "0"
          ],
          env: [{"STUB_LOG", context.log}],
          cd: context.project
        )

      assert %{"exit_code" => 2, "state" => "not_started", "type" => "summary"} =
               Jason.decode!(stdout)
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
