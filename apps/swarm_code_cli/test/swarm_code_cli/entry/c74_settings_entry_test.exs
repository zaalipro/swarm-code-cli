defmodule SwarmCodeCLI.Release.C74SettingsEntryTest do
  @moduledoc """
  pass74 S1-13: `swarmcode settings [QUERY] [--dir DIR]` and `swarmcode config`
  in the release grammar and in the launcher script (run as a subprocess
  against a stub release, as `launcher_test.exs` does).
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Release

  @launcher Path.expand("../../../../../rel/overlays/bin/swarmcode", __DIR__)

  @stub """
  #!/usr/bin/env bash
  {
    printf 'ARGS'
    for a in "$@"; do printf ' [%s]' "$a"; done
    printf '\\n'
    printf 'OPEN=%s\\n' "${SWARM_SETTINGS_OPEN-<unset>}"
    printf 'ONLY=%s\\n' "${SWARM_SETTINGS_ONLY-<unset>}"
    printf 'ROOT=%s\\n' "${SWARM_PROJECT_ROOT-<unset>}"
  } >"$STUB_LOG"
  exit "${STUB_EXIT:-0}"
  """

  describe "Release.parse/1" do
    test "settings takes query words and --dir" do
      assert {:ok, %{mode: :settings, query: "", project: nil}} = Release.parse(["settings"])

      assert {:ok, %{mode: :settings, query: "models effort", project: "/tmp/p"}} =
               Release.parse(["settings", "models", "--dir", "/tmp/p", "effort"])

      assert {:ok, %{query: "providers", project: "x"}} =
               Release.parse(["settings", "--dir=x", "providers"])

      assert :help = Release.parse(["settings", "--help"])
    end

    test "settings with any other flag is a usage error" do
      for flag <- ["--new", "--continue", "--resume", "--model", "-p", "--plain", "-c"] do
        assert {:error, "settings takes a query and --dir only."} =
                 Release.parse(["settings", "providers", flag])
      end

      assert {:error, "--dir needs a value."} = Release.parse(["settings", "--dir"])

      assert {:error, "name one directory at most."} =
               Release.parse(["settings", "--dir", "a", "--dir", "b"])
    end

    test "a folder named settings or config opens with ./ or --" do
      assert {:ok, %{mode: :tui, project: "./settings"}} = Release.parse(["./settings"])
      assert {:ok, %{mode: :tui, project: "config"}} = Release.parse(["--", "config"])
      assert {:config, ["list", "--json"]} = Release.parse(["config", "list", "--json"])
    end

    test "the usage text names both subcommands" do
      assert Release.usage() =~ "swarmcode settings [QUERY] [--dir DIR]"
      assert Release.usage() =~ "swarmcode config COMMAND"
    end
  end

  describe "the launcher" do
    setup do
      base = Path.join(System.tmp_dir!(), "c74-launcher-#{System.unique_integer([:positive])}")
      bin = Path.join(base, "release/bin")
      project = Path.join(base, "project")
      File.mkdir_p!(bin)
      File.mkdir_p!(Path.join(project, "settings"))
      File.mkdir_p!(Path.join(base, "release/releases"))
      File.cp!(@launcher, Path.join(bin, "swarmcode"))
      File.write!(Path.join(bin, "swarm_code_cli"), @stub)
      File.write!(Path.join(bin, "load_provider_env.sh"), ":\n")
      File.write!(Path.join(base, "release/releases/start_erl.data"), "16.0 0.1.0-dev\n")
      File.chmod!(Path.join(bin, "swarmcode"), 0o755)
      File.chmod!(Path.join(bin, "swarm_code_cli"), 0o755)
      on_exit(fn -> File.rm_rf!(base) end)
      %{launcher: Path.join(bin, "swarmcode"), project: project, log: Path.join(base, "stub.log")}
    end

    defp launch(c, args, env \\ []) do
      env =
        [
          {"STUB_LOG", c.log},
          {"SWARM_SETTINGS_OPEN", "stale"},
          {"SWARM_SETTINGS_ONLY", "1"},
          {"TERM", "xterm-256color"}
        ] ++ env

      System.cmd("bash", [c.launcher | args], env: env, cd: c.project, stderr_to_stdout: true)
    end

    defp stub(c) do
      c.log
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Map.new(fn line ->
        case String.split(line, ["=", " "], parts: 2) do
          [key, value] -> {key, value}
          [key] -> {key, ""}
        end
      end)
    end

    test "the script parses", c do
      assert {_, 0} = System.cmd("bash", ["-n", c.launcher])
    end

    test "settings usage errors exit 2 and start nothing", c do
      for args <- [
            ["settings", "--new"],
            ["settings", "providers", "-p", "x"],
            ["settings", "--dir"]
          ] do
        {output, code} = launch(c, args)
        assert code == 2, inspect({args, output})
        assert output =~ "swarmcode: "
        refute File.exists?(c.log)
      end

      {output, 2} = launch(c, ["settings", "--plain"])
      assert output =~ "settings takes a query and --dir only."
    end

    test "settings without a terminal says to use config", c do
      {output, 2} = launch(c, ["settings", "providers"])
      assert output =~ "settings needs a terminal"
      refute File.exists?(c.log)
    end

    test "./settings opens the folder, and a stale settings export never applies", c do
      {_output, 0} = launch(c, ["./settings"])
      log = stub(c)
      assert resolve(log["ROOT"]) == Path.join(c.project, "settings") |> resolve()
      assert log["OPEN"] == "<unset>"
      assert log["ONLY"] == "<unset>"
    end

    test "config evaluates the release with the config words, from this folder", c do
      {_output, 0} = launch(c, ["config", "list", "--json"])
      log = stub(c)
      assert log["ARGS"] =~ "[eval]"
      assert log["ARGS"] =~ "[config] [list] [--json]"
      assert resolve(log["ROOT"]) == resolve(c.project)
      assert log["ONLY"] == "<unset>"

      {_output, 3} = launch(c, ["config", "get", "x"], [{"STUB_EXIT", "3"}])
    end

    test "--help names the subcommands", c do
      {output, 0} = launch(c, ["--help"])
      assert output =~ "swarmcode settings [QUERY] [--dir DIR]"
      assert output =~ "swarmcode ./settings"
    end
  end

  defp resolve(path) do
    {real, 0} = System.cmd("bash", ["-c", "cd \"$1\" && pwd -P", "_", path])
    String.trim(real)
  end
end
