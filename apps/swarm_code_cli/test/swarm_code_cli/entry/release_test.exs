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
    end

    test "usage errors name the problem" do
      for {args, text} <- [
            {["--bogus"], "unknown option '--bogus'."},
            {["--resume"], "--resume needs a value."},
            {["--resume", "x"], "--resume needs a conversation id."},
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
      assert capture_io(fn -> assert Release.run(["--help"]) == 0 end) =~ "Usage: swarmcode"
      assert capture_io(fn -> assert Release.run(["--version"]) == 0 end) =~ ~r/^swarmcode \S+/

      assert capture_io(:stderr, fn -> assert Release.run(["--bogus"]) == 2 end) ==
               "swarmcode: unknown option '--bogus'. Run 'swarmcode --help'.\n"
    end

    test "the full screen is not started from eval" do
      assert capture_io(:stderr, fn -> assert Release.run([]) == 2 end) =~
               "starts from the swarmcode command"
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
      assert {0, "swarmcode " <> _} = halt_code(["--version"])
      assert {2, "swarmcode: unknown option '--nope'." <> _} = halt_code(["--nope"])
      assert {2, "swarmcode: --json goes with -p." <> _} = halt_code(["--json"])
    end
  end
end
