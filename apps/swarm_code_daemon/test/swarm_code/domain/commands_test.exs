defmodule SwarmCode.Domain.CommandsTest do
  use ExUnit.Case, async: false

  alias SwarmCode.Domain.{Commands, Projects.Workspace}

  setup do
    # CLI: the global commands directory below is a private temporary one.
    SwarmCode.Domain.TestGlobalDir.isolate!()
    dir = Path.join([System.tmp_dir!(), "swarm_code_cmds", Ecto.UUID.generate()])
    File.mkdir_p!(Workspace.commands_dir(dir))
    File.rm_rf(Workspace.global_commands_dir())

    on_exit(fn ->
      File.rm_rf(dir)
      File.rm_rf(Workspace.global_commands_dir())
    end)

    %{dir: dir, project: %SwarmCode.Domain.Projects.Project{name: "p", root_path: dir}}
  end

  defp write_project(dir, name, text),
    do: File.write!(Path.join(Workspace.commands_dir(dir), name), text)

  defp write_global(name, text) do
    File.mkdir_p!(Workspace.global_commands_dir())
    File.write!(Path.join(Workspace.global_commands_dir(), name), text)
  end

  test "parses front matter and body", %{dir: dir, project: project} do
    write_project(dir, "tidy.md", """
    ---
    description: Tidy the code
    swarm: true
    mode: plan
    ---
    Please tidy: $ARGUMENTS
    """)

    assert [command] = Commands.list(project)
    assert command.name == "tidy"
    assert command.description == "Tidy the code"
    assert command.swarm
    assert command.mode == "plan"
    assert command.scope == :project
    assert command.body == "Please tidy: $ARGUMENTS"
  end

  test "a file without front matter still works", %{dir: dir, project: project} do
    write_project(dir, "plain.md", "just do the thing")

    assert [%{name: "plain", description: "plain", swarm: false, mode: nil}] =
             Commands.list(project)
  end

  test "project commands override global ones", %{dir: dir, project: project} do
    write_global("dup.md", "---\ndescription: global one\n---\nglobal body")
    write_project(dir, "dup.md", "---\ndescription: project one\n---\nproject body")

    assert [command] = Commands.list(project)
    assert command.description == "project one"
    assert command.scope == :project

    # Without a project only the global one is visible.
    assert [%{scope: :global}] = Commands.list(nil)
  end

  test "$ARGUMENTS is replaced and trimmed", %{dir: dir, project: project} do
    write_project(dir, "fix.md", "---\ndescription: Fix\n---\nFix this: $ARGUMENTS")
    command = Commands.get(project, "fix")

    assert Commands.expand(command, "the parser") == "Fix this: the parser"
    assert Commands.expand(command, "  spaced  ") == "Fix this: spaced"
    assert Commands.expand(command, "") == "Fix this:"
  end

  test "names are lowercased and looked up case-insensitively", %{dir: dir, project: project} do
    write_project(dir, "Shout.md", "hello")
    assert Commands.get(project, "SHOUT").name == "shout"
  end

  test "create/3 writes a template", %{project: project} do
    assert {:ok, path} = Commands.create(project, :project, "sample")
    assert File.read!(path) =~ "description:"
    assert Commands.get(project, "sample")
  end

  test "no commands folder means no commands" do
    empty = %SwarmCode.Domain.Projects.Project{name: "e", root_path: System.tmp_dir!()}
    assert Commands.list(empty) == []
  end
end
