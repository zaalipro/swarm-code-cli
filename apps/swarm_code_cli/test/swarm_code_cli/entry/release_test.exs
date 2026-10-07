defmodule SwarmCodeCLI.ReleaseTest do
  @moduledoc """
  Pass 70 E4: the release's own command line, the grammar the launcher shares,
  and the exit codes a real VM halts with.
  """
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias SwarmCodeCLI.Release

  @conversation "7d01acff-1111-4111-8111-111111111111"

  describe "parse/1" do
    test "the full grammar" do
      assert {:ok, %{mode: :tui, project: nil, conversation: nil, model: nil, format: :text}} =
               Release.parse([])

      assert {:ok, %{mode: :prompt, prompt: "hi", format: :json, conversation: "new"}} =
               Release.parse(["--new", "-p", "hi", "--json"])

      assert {:ok, %{mode: :plain, format: :ndjson, project: "dir", conversation: "latest"}} =
               Release.parse(["dir", "--plain", "--ndjson", "--continue"])

      assert {:ok, %{conversation: @conversation, model: "p/m"}} =
               Release.parse(["--resume=" <> @conversation, "--model=p/m"])

      assert {:ok, %{project: "-dir"}} = Release.parse(["--", "-dir"])
      assert {:ok, %{prompt: "-v means verbose?"}} = Release.parse(["-p", "-v means verbose?"])
      assert :help = Release.parse(["--help", "--bogus"])
      assert :version = Release.parse(["-V"])
      # cli020 B16
      assert :version = Release.parse(["-v"])
      assert :version = Release.parse(["version"])
      assert :help = Release.parse(["help"])
      assert {:config, ["doctor", "--json"]} = Release.parse(["doctor", "--json"])
      assert Release.usage() =~ "Examples:"
    end

    # cli020 B3: `--fail-on-denied` goes with -p or --plain.
    test "--fail-on-denied" do
      assert {:ok, %{mode: :prompt, fail_on_denied: true}} =
               Release.parse(["-p", "hi", "--fail-on-denied"])

      assert {:ok, %{mode: :plain, fail_on_denied: true}} =
               Release.parse(["--fail-on-denied", "--plain"])

      assert {:ok, %{fail_on_denied: false}} = Release.parse(["-p", "hi"])

      assert {:error, "--fail-on-denied goes with -p or --plain."} =
               Release.parse(["--fail-on-denied"])

      assert {:error, "--fail-on-denied is given twice."} =
               Release.parse(["-p", "x", "--fail-on-denied", "--fail-on-denied"])
    end

    test "usage errors name the problem" do
      for {args, text} <- [
            {["--bogus"], "unknown option '--bogus'."},
            # cli020 B19: a prefix or a title is resolved later; bare
            # --resume is the launcher's picker.
            {["--resume"],
             "--resume needs an id or a title here; ncode --resume alone opens the picker."},
            {["--resume", " "],
             "--resume needs an id or a title here; ncode --resume alone opens the picker."},
            {["--new", "--resume", @conversation],
             "choose one of --new, --continue and --resume."},
            {["--json"], "--json goes with -p."},
            {["--ndjson"], "--ndjson goes with --plain."},
            {["--plain", "-p", "x"], "-p and --plain do not go together."},
            {["-p", "a", "--prompt", "b"], "-p is given twice."},
            {["-p", " "], "-p needs a prompt of at most 256 KiB."},
            {["-p", String.duplicate("x", 262_145)], "-p needs a prompt of at most 256 KiB."},
            {["--model", ""], "--model needs a model name."},
            {["a", "b"], "name one directory at most."}
          ] do
        assert {:error, ^text} = Release.parse(args), inspect(args, limit: 3)
      end
    end
  end

  describe "run/1" do
    test "help, version and usage errors" do
      assert capture_io(fn -> assert Release.run(["--help"]) == 0 end) =~ "Usage: ncode"
      assert capture_io(fn -> assert Release.run(["--version"]) == 0 end) =~ ~r/^ncode \S+/

      assert capture_io(:stderr, fn -> assert Release.run(["--bogus"]) == 2 end) ==
               "ncode: unknown option '--bogus'. Run 'ncode --help'.\n"
    end

    test "the full screen is not started from eval" do
      assert capture_io(:stderr, fn -> assert Release.run([]) == 2 end) =~
               "starts from the ncode command"
    end
  end

  # The VM halts with the code: a subprocess on this build's code paths.
  describe "main/1 in a VM of its own" do
    defp halt_code(args) do
      paths =
        for app <- [:swarm_code_cli, :swarm_code_core],
            do: ["-pa", Path.join(Application.app_dir(app), "ebin")]

      expression = "SwarmCodeCLI.Release.main(System.argv())"

      {output, code} =
        System.cmd(
          System.find_executable("elixir"),
          List.flatten(paths) ++ ["-e", expression, "--" | args],
          stderr_to_stdout: true
        )

      {code, output}
    end

    test "exits 0 for --version and 2 for a usage error" do
      assert {0, "ncode " <> _} = halt_code(["--version"])
      assert {2, "ncode: unknown option '--nope'." <> _} = halt_code(["--nope"])
      assert {2, "ncode: --json goes with -p." <> _} = halt_code(["--json"])
    end
  end
end
