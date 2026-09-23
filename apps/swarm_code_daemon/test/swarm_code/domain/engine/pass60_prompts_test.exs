defmodule SwarmCode.Domain.Engine.Pass60PromptsTest do
  @moduledoc """
  Spec 66 phase 4: AGENTS.md from the root down (T15) and the `<environment>`
  block that tells the model where it is (T16).
  """
  use ExUnit.Case, async: false

  alias SwarmCode.Domain.Engine.{ProjectContext, Prompts}
  alias SwarmCode.Domain.Projects.Project

  setup do
    dir = Path.join([System.tmp_dir!(), "swarm_code_pass60", Ecto.UUID.generate()])
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    # spec 67 T31: an untrusted project has no instructions at all.
    project = %Project{
      name: "p",
      root_path: dir,
      approval_mode: "auto",
      trusted_at: DateTime.utc_now()
    }

    %{dir: dir, project: project}
  end

  defp write!(dir, rel, content) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  ## T15 — the layered instruction files

  test "one file reads exactly as it always did", %{dir: dir, project: project} do
    write!(dir, "AGENTS.md", "root rules")
    assert ProjectContext.instructions(project) == "root rules"
  end

  test "a package's own file is loaded after the root's, with headers", %{
    dir: dir,
    project: project
  } do
    write!(dir, "AGENTS.md", "root rules")
    write!(dir, "apps/web/AGENTS.md", "web rules")
    write!(dir, "apps/web/deep/nested/too/AGENTS.md", "too deep")

    text = ProjectContext.instructions(project)

    assert text =~ "--- AGENTS.md ---\nroot rules"
    assert text =~ "--- apps/web/AGENTS.md ---\nweb rules"
    refute text =~ "too deep"

    # Root first.
    assert :binary.match(text, "root rules") < :binary.match(text, "web rules")
  end

  test "AGENTS.override.md wins inside its own directory", %{dir: dir, project: project} do
    write!(dir, "AGENTS.md", "root rules")
    write!(dir, "apps/web/AGENTS.md", "normal web rules")
    write!(dir, "apps/web/AGENTS.override.md", "override web rules")

    text = ProjectContext.instructions(project)

    assert text =~ "override web rules"
    refute text =~ "normal web rules"
  end

  test "the 32 000-character budget truncates and reports what it dropped", %{
    dir: dir,
    project: project
  } do
    write!(dir, "AGENTS.md", String.duplicate("a", 40_000))
    write!(dir, "apps/web/AGENTS.md", "web rules")

    text = ProjectContext.instructions(project)

    assert text =~ "…[truncated]"
    refute text =~ "web rules"
    assert text =~ "…[1 more instruction files omitted: apps/web/AGENTS.md]"
    assert String.length(text) < ProjectContext.instructions_cap() + 200
  end

  test "build directories are never read", %{dir: dir, project: project} do
    write!(dir, "AGENTS.md", "root rules")
    write!(dir, "_build.noindex/AGENTS.md", "build rules")
    write!(dir, "deps/foo/AGENTS.md", "dep rules")
    write!(dir, "node_modules/x/AGENTS.md", "node rules")

    text = ProjectContext.instructions(project)

    assert text == "root rules"
  end

  test "the editable path is still the root's normal file", %{dir: dir, project: project} do
    write!(dir, "AGENTS.override.md", "override")
    write!(dir, "CLAUDE.md", "claude")

    assert ProjectContext.instructions_path(project) == Path.join(dir, "CLAUDE.md")
  end

  ## T16 — the environment block

  test "the assistant prompt carries the date, the mode and the writable root", %{
    project: project
  } do
    prompt = Prompts.assistant(project, [])

    assert prompt =~ "<environment>"
    assert prompt =~ "<current_date>#{Date.to_iso8601(Date.utc_today())}</current_date>"
    assert prompt =~ "<approval_mode>auto</approval_mode>"
    assert prompt =~ "<writable>unsandboxed</writable>"
    assert prompt =~ "<cwd>#{project.root_path}</cwd>"
    assert prompt =~ "<shell>"
    assert prompt =~ "<os>"
    assert prompt =~ "The <environment> block above is the truth about this machine"
  end

  test "a read-only project says so", %{project: project} do
    prompt = Prompts.assistant(%{project | approval_mode: "read_only"}, [])
    assert prompt =~ "<approval_mode>read_only</approval_mode>"
  end

  test "every role gets the block", %{project: project} do
    assert Prompts.lead(project, 4) =~ "<environment>"
    assert Prompts.sub_agent(project, "w1") =~ "<environment>"
    assert Prompts.worker(project, "w1") =~ "<environment>"
    assert Prompts.base_only(project) =~ "<environment>"
  end

  test "the branch is there in a repository and absent outside one", %{
    dir: dir,
    project: project
  } do
    refute Prompts.assistant(project, []) =~ "<git_branch>"

    {:ok, _} = SwarmCode.Domain.Git.run(dir, ["init", "-q", "-b", "main"])
    # spec 73 T54: the block is memoised for 2 s under the :project tag.
    SwarmCode.Domain.Cache.invalidate(:project)
    assert Prompts.assistant(project, []) =~ "<git_branch>main</git_branch>"
  end
end
