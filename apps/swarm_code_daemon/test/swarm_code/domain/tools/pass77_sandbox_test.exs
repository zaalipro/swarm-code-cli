defmodule SwarmCode.Domain.Tools.Pass77SandboxTest do
  @moduledoc "Pass 77 C-FEAT-4: the opt-in macOS Seatbelt sandbox for run_command."
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.Fixtures
  alias SwarmCode.Domain.Tools
  alias SwarmCode.Domain.Tools.Sandbox

  @sandbox_exec "/usr/bin/sandbox-exec"
  @needs_sandbox (not File.exists?(@sandbox_exec) && "needs macOS sandbox-exec") || false

  defp project(config) do
    dir = Fixtures.tmp_dir()

    if config do
      File.mkdir_p!(Path.join(dir, ".swarm_code"))
      File.write!(Path.join(dir, ".swarm_code/config.json"), Jason.encode!(config))
    end

    dir
  end

  describe "profile/3" do
    test "allows writes under the root and the temp dirs, and denies the network when asked" do
      profile = Sandbox.profile("/work/proj", ["/private/var/folders/x/T"], false)

      assert profile =~ "(deny file-write*)"
      assert profile =~ ~s[(subpath "/work/proj")]
      assert profile =~ ~s[(subpath "/private/var/folders/x/T")]
      assert profile =~ ~s[(subpath "/private/tmp")]
      assert profile =~ "(deny network*)"
    end

    test "leaves the network alone when it is allowed" do
      refute Sandbox.profile("/work/proj", [], true) =~ "network"
    end

    test "RD-1: protected policy files lose their write, link and parent removal rights" do
      profile =
        Sandbox.profile("/work/proj", [], true, ["/work/proj/.swarm_code/config.json"])

      assert profile =~
               ~s[(deny file-write* file-link (literal "/work/proj/.swarm_code/config.json"))]

      assert profile =~ ~s[(deny file-write* (literal "/work/proj/.swarm_code"))]
      assert profile =~ ~s[(literal "/work")]
      assert profile =~ ~s[(literal "/work/proj")]
      refute profile =~ ~s[(literal "/")]

      # the deny rules come after the allow, so they win (Seatbelt: last match)
      {allow, _} = :binary.match(profile, "(allow file-write*")
      {deny, _} = :binary.match(profile, "(deny file-write* file-link")
      assert deny > allow
    end

    test "takes several roots" do
      profile = Sandbox.profile(["/work/proj", "/work/owner"], [], true)
      assert profile =~ ~s[(subpath "/work/proj")]
      assert profile =~ ~s[(subpath "/work/owner")]
    end
  end

  describe "mode/1 and network?/1" do
    test "mode follows config.json" do
      assert Sandbox.mode(%{project_root: project(%{"sandbox" => "workspace-write"})}) ==
               :workspace_write

      assert Sandbox.mode(%{project_root: project(%{"sandbox" => "everything"})}) == :off
      assert Sandbox.mode(%{project_root: project(%{})}) == :off
      assert Sandbox.mode(%{project_root: project(nil)}) == :off
      assert Sandbox.mode(%{}) == :off
    end

    test "the network is open only in Full access" do
      refute Sandbox.network?(%{live_mode: "auto"})
      refute Sandbox.network?(%{approval_mode: "read_only"})
      assert Sandbox.network?(%{live_mode: "full_access"})
      assert Sandbox.network?(%{approval_mode: "auto", approval_override: "full_access"})
    end
  end

  describe "wrap/2" do
    test "a project without the setting keeps its command" do
      ctx = %{project_root: project(nil)}
      assert Sandbox.wrap({"/bin/sh", ["-c", "true"]}, ctx) == {"/bin/sh", ["-c", "true"]}
    end

    @tag skip: @needs_sandbox
    test "a sandboxed project runs its shell under sandbox-exec" do
      ctx = %{project_root: project(%{"sandbox" => "workspace-write"})}

      assert {@sandbox_exec, ["-p", profile, "/bin/sh", "-c", "true"]} =
               Sandbox.wrap({"/bin/sh", ["-c", "true"]}, ctx)

      assert profile =~ "(deny network*)"
    end

    @tag skip: @needs_sandbox
    test "a root that cannot be quoted refuses the command" do
      root = Path.join(Fixtures.tmp_dir(), ~s(we"ird))
      File.mkdir_p!(Path.join(root, ".swarm_code"))
      File.write!(Path.join(root, ".swarm_code/config.json"), ~s({"sandbox":"workspace-write"}))

      assert {:error, "sandbox: the project path cannot be expressed" <> _} =
               Sandbox.wrap({"/bin/sh", ["-c", "true"]}, %{project_root: root})
    end
  end

  describe "the environment block" do
    @tag skip: @needs_sandbox
    test "says so when the sandbox is on" do
      on = %SwarmCode.Domain.Projects.Project{
        root_path: project(%{"sandbox" => "workspace-write"}),
        approval_mode: "auto"
      }

      block = SwarmCode.Domain.Engine.Prompts.environment(on)
      assert block =~ "<sandbox>Commands run in a sandbox: writes outside the project"
      assert block =~ "<writable>project and temp folders only</writable>"
    end

    test "stays unsandboxed without the setting" do
      off = %SwarmCode.Domain.Projects.Project{root_path: project(nil), approval_mode: "auto"}
      block = SwarmCode.Domain.Engine.Prompts.environment(off)
      assert block =~ "<writable>unsandboxed</writable>"
      refute block =~ "<sandbox>"
    end
  end

  describe "run_command under the sandbox" do
    setup do
      probe = Path.join([System.user_home!(), ".cache", "ncode", "p77-sbx-probe"])
      File.mkdir_p!(probe)
      on_exit(fn -> File.rm_rf(probe) end)
      {:ok, probe: probe}
    end

    @tag skip: @needs_sandbox
    test "writes land inside the project only", %{probe: probe} do
      dir = project(%{"sandbox" => "workspace-write"})
      outside = Path.join(probe, "outside-#{System.unique_integer([:positive])}.txt")
      progress = fn _, _ -> :ok end

      command = "touch inside.txt; touch #{outside}; echo done"

      assert {:ok, "exit code 0\n" <> output} =
               Tools.run("run_command", %{"command" => command}, %{project_root: dir}, progress)

      assert output =~ "done"
      assert output =~ "Operation not permitted"
      assert File.exists?(Path.join(dir, "inside.txt"))
      refute File.exists?(outside)
    end

    @tag skip: @needs_sandbox
    test "RD-1: a command cannot rewrite, replace or move away the sandbox policy" do
      dir = project(%{"sandbox" => "workspace-write"})
      config = Path.join(dir, ".swarm_code/config.json")
      original = File.read!(config)
      progress = fn _, _ -> :ok end
      ctx = %{project_root: dir}

      attacks = [
        "echo '{}' > .swarm_code/config.json",
        "rm -f .swarm_code/config.json",
        "echo '{}' > swap.json; mv swap.json .swarm_code/config.json",
        "mv .swarm_code .swarm_code.old; mkdir .swarm_code; echo '{}' > .swarm_code/config.json",
        "ln .swarm_code/config.json alias.json; echo '{}' > alias.json",
        "chmod 000 .swarm_code",
        "mv ../#{Path.basename(dir)} ../#{Path.basename(dir)}-moved"
      ]

      for attack <- attacks do
        assert {:ok, "exit code " <> _} =
                 Tools.run("run_command", %{"command" => attack}, ctx, progress)

        assert File.read!(config) == original, "survived: #{attack}"
        assert Sandbox.mode(ctx) == :workspace_write, "survived: #{attack}"
      end

      # the second command is still contained
      probe = Path.join(System.user_home!(), ".cache/ncode/p77-sbx-probe")
      File.mkdir_p!(probe)
      on_exit(fn -> File.rm_rf(probe) end)
      outside = Path.join(probe, "after-attack-#{System.unique_integer([:positive])}.txt")

      assert {:ok, "exit code 1\n" <> out} =
               Tools.run("run_command", %{"command" => "touch #{outside}"}, ctx, progress)

      assert out =~ "Operation not permitted"
      refute File.exists?(outside)

      # ordinary project writes still work, also inside .swarm_code
      assert {:ok, "exit code 0\n"} =
               Tools.run(
                 "run_command",
                 %{"command" => "touch ok.txt .swarm_code/notes.txt"},
                 ctx,
                 progress
               )
    end

    @tag skip: @needs_sandbox
    test "the network is off except in Full access" do
      dir = project(%{"sandbox" => "workspace-write"})
      progress = fn _, _ -> :ok end
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)

      command =
        ~s[python3 -c "import socket; socket.create_connection(('127.0.0.1', #{port}), 3); print('connected')"]

      assert {:ok, "exit code " <> denied} =
               Tools.run("run_command", %{"command" => command}, %{project_root: dir}, progress)

      assert String.starts_with?(denied, "1\n")
      assert denied =~ "Operation not permitted"

      ctx = %{project_root: dir, live_mode: "full_access"}

      assert {:ok, "exit code 0\nconnected\n"} =
               Tools.run("run_command", %{"command" => command}, ctx, progress)
    end

    test "without the setting a command writes where it likes", %{probe: probe} do
      dir = project(nil)
      outside = Path.join(probe, "free-#{System.unique_integer([:positive])}.txt")
      progress = fn _, _ -> :ok end

      assert {:ok, "exit code 0\n"} =
               Tools.run(
                 "run_command",
                 %{"command" => "touch #{outside}"},
                 %{project_root: dir},
                 progress
               )

      assert File.exists?(outside)
    end
  end
end
