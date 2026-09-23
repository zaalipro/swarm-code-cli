defmodule SwarmCode.Domain.Engine.ProjectContextTest do
  use ExUnit.Case, async: false

  alias SwarmCode.Domain.Engine.{ProjectContext, Prompts}
  alias SwarmCode.Domain.Projects.Workspace

  setup do
    # CLI: the global MEMORY.md below is a private temporary one, never the real one.
    SwarmCode.Domain.TestGlobalDir.isolate!()
    dir = Path.join([System.tmp_dir!(), "swarm_code_pctx", Ecto.UUID.generate()])
    File.mkdir_p!(dir)
    global = Workspace.global_memory_file()
    File.rm(global)

    on_exit(fn ->
      File.rm_rf(dir)
      File.rm(global)
    end)

    %{
      project: %SwarmCode.Domain.Projects.Project{
        name: "p",
        root_path: dir,
        # spec 67 T31: an untrusted project has no instructions at all.
        trusted_at: DateTime.utc_now()
      },
      dir: dir
    }
  end

  test "reads AGENTS.md first", %{project: project, dir: dir} do
    File.write!(Path.join(dir, "CLAUDE.md"), "claude text")
    assert ProjectContext.instructions(project) == "claude text"

    File.write!(Path.join(dir, "AGENTS.md"), "agents text")
    assert ProjectContext.instructions(project) == "agents text"
  end

  test "instructions are head-capped", %{project: project, dir: dir} do
    File.write!(Path.join(dir, "AGENTS.md"), String.duplicate("a", 40_000) <> "TAIL")
    text = ProjectContext.instructions(project)

    assert String.length(text) ==
             ProjectContext.instructions_cap() + String.length("\n…[truncated]")

    refute text =~ "TAIL"
  end

  test "memory keeps the tail and merges both files", %{project: project, dir: dir} do
    File.mkdir_p!(Workspace.dir(dir))
    File.write!(Workspace.memory_file(dir), "- project fact")
    File.mkdir_p!(Workspace.global_dir())
    File.write!(Workspace.global_memory_file(), "- global fact")

    memory = ProjectContext.memory(project)
    assert memory =~ "Project memory:\n- project fact"
    assert memory =~ "Global memory:\n- global fact"

    File.write!(Workspace.memory_file(dir), "HEAD" <> String.duplicate("m", 20_000) <> "END")
    memory = ProjectContext.memory(project)
    assert memory =~ "END"
    refute memory =~ "HEAD"
  end

  test "build/2 and the prompt suffix", %{project: project, dir: dir} do
    File.write!(Path.join(dir, "AGENTS.md"), "use two spaces")
    File.mkdir_p!(Workspace.dir(dir))
    File.write!(Workspace.memory_file(dir), "- the db is sqlite")

    ctx = ProjectContext.build(project, %{goal: "ship it", mode: "build"})
    assert ctx.goal == "ship it"

    suffix =
      Prompts.suffix(Keyword.merge([goal: ctx.goal, mode: ctx.mode], ProjectContext.to_opts(ctx)))

    # spec 66 T15: the section header now says how the layered files relate.
    assert suffix =~ "Project instructions (AGENTS.md; deeper files win"
    assert suffix =~ "their directory):\nuse two spaces"
    assert suffix =~ "Memory (facts saved earlier"
    assert suffix =~ "- the db is sqlite"
    assert suffix =~ "ship it"
  end

  test "no files means no sections", %{project: project} do
    ctx = ProjectContext.build(project, nil)
    assert ctx.instructions == nil
    assert ctx.memory == nil
    assert Prompts.suffix(ProjectContext.to_opts(ctx)) == ""
  end

  # ------------------------------------- sakana task 3: project-owned symlinks

  describe "symlinked project files" do
    setup %{dir: dir} do
      outside = Path.join([System.tmp_dir!(), "swarm_code_pctx_out", Ecto.UUID.generate()])
      File.mkdir_p!(outside)
      on_exit(fn -> File.rm_rf(outside) end)
      %{outside: outside, dir: dir}
    end

    test "a symlinked AGENTS.md contributes no text and is not the editable path",
         %{project: project, dir: dir, outside: outside} do
      secret = Path.join(outside, "secret.md")
      File.write!(secret, "OUTSIDE SECRET")
      File.ln_s!(secret, Path.join(dir, "AGENTS.md"))

      refute ProjectContext.instructions(project) == "OUTSIDE SECRET"
      assert ProjectContext.instructions(project) == nil
      assert ProjectContext.instructions_path(project) == Path.join(dir, "AGENTS.md")
    end

    test "an in-project instruction file still wins over an unsafe one",
         %{project: project, dir: dir, outside: outside} do
      File.ln_s!(Path.join(outside, "secret.md"), Path.join(dir, "AGENTS.md"))
      File.write!(Path.join(outside, "secret.md"), "OUTSIDE SECRET")
      File.write!(Path.join(dir, "CLAUDE.md"), "claude text")

      assert ProjectContext.instructions(project) == "claude text"
      assert ProjectContext.instructions_path(project) == Path.join(dir, "CLAUDE.md")
    end

    test "a symlinked project MEMORY.md contributes nothing",
         %{project: project, dir: dir, outside: outside} do
      secret = Path.join(outside, "mem.md")
      File.write!(secret, "OUTSIDE MEMORY")
      memory = Workspace.memory_file(dir)
      File.mkdir_p!(Path.dirname(memory))
      File.ln_s!(secret, memory)

      refute to_string(ProjectContext.memory(project)) =~ "OUTSIDE MEMORY"
    end

    test "an ordinary project MEMORY.md is still read", %{project: project, dir: dir} do
      memory = Workspace.memory_file(dir)
      File.mkdir_p!(Path.dirname(memory))
      File.write!(memory, "remember this")

      assert ProjectContext.memory(project) =~ "remember this"
    end
  end
end
