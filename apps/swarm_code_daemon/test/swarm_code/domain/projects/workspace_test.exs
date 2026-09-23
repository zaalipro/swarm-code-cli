defmodule SwarmCode.Domain.Projects.WorkspaceTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.{Git, Projects.Workspace}

  setup do
    dir = Path.join([System.tmp_dir!(), "swarm_code_ws", Ecto.UUID.generate()])
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "path helpers", %{dir: dir} do
    assert Workspace.dir(dir) == Path.join(dir, ".swarm_code")
    assert Workspace.memory_file(dir) == Path.join(dir, ".swarm_code/MEMORY.md")
    assert Workspace.commands_dir(dir) == Path.join(dir, ".swarm_code/commands")
    assert Workspace.worktrees_dir(dir) == Path.join(dir, ".swarm_code/worktrees")
  end

  test "global paths live under the config dir" do
    config = SwarmCode.Domain.Paths.config_dir()
    assert Workspace.global_memory_file() == Path.join(config, "MEMORY.md")
    assert Workspace.global_commands_dir() == Path.join(config, "commands")
    assert Workspace.attachments_dir() == Path.join(config, "attachments")
    # The test config points somewhere disposable, never the user's real folder.
    refute config =~ "Application Support"
  end

  test "ensure! creates the dir and excludes it in a git repo", %{dir: dir} do
    {:ok, _} = Git.run(dir, ["init", "-q"])
    Workspace.ensure!(dir)

    assert File.dir?(Workspace.dir(dir))
    assert File.read!(Path.join(dir, ".git/info/exclude")) =~ ".swarm_code/"
  end

  test "ensure! works outside a git repo", %{dir: dir} do
    Workspace.ensure!(dir)
    assert File.dir?(Workspace.dir(dir))
  end
end
