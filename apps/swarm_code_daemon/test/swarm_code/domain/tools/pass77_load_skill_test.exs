defmodule SwarmCode.Domain.Tools.Pass77LoadSkillTest do
  @moduledoc "pass 77 D3-2 (C-FEAT-2): agents can list and load skills."
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.{Fixtures, Tools}
  alias SwarmCode.Domain.Tools.LoadSkill

  defp project_with_skill do
    dir = Fixtures.tmp_dir()
    skill_dir = Path.join([dir, ".swarm_code", "skills", "release-notes"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      "# Release notes\n\nWrite release notes from the merged pull requests.\n\n1. List the PRs.\n"
    )

    File.write!(Path.join(skill_dir, "template.md"), "## Added\n- item\n")
    dir
  end

  defp run(args, dir), do: LoadSkill.run(args, %{project_root: dir}, fn _, _ -> :ok end)

  test "no name lists the project's skills with their descriptions" do
    dir = project_with_skill()

    assert {:ok, text} = run(%{}, dir)
    assert text =~ "- release-notes — Write release notes from the merged pull requests."
  end

  test "a name loads the skill's instructions and assets" do
    dir = project_with_skill()

    assert {:ok, text} = run(%{"name" => "release-notes"}, dir)
    assert text =~ "# Skill: release-notes"
    assert text =~ "1. List the PRs."
    assert text =~ "release-notes/template.md"
  end

  test "an unknown name is an error that says how to list them" do
    dir = project_with_skill()

    assert {:error, message} = run(%{"name" => "nope"}, dir)
    assert message =~ "no skill named nope"
    assert message =~ "without a name"
  end

  test "a name that tries to leave the skills folder finds nothing" do
    dir = project_with_skill()
    assert {:error, _} = run(%{"name" => "../../../etc"}, dir)
  end

  test "the tool is read-only and parallel" do
    assert LoadSkill.permission(%{}) == :read
    assert LoadSkill.parallel?()
    assert "load_skill" in Tools.read_only()
  end

  test "root assistants, leads, workers and plan mode all get it" do
    assert "load_skill" in Enum.map(Tools.for_agent("assistant", 0, 2), & &1.name)
    assert "load_skill" in Enum.map(Tools.for_agent("lead", 0, 2), & &1.name)
    assert "load_skill" in Enum.map(Tools.for_agent("sub", 1, 2), & &1.name)
    assert "load_skill" in Enum.map(Tools.for_agent("assistant", 0, 2, "plan"), & &1.name)
    assert "load_skill" in Enum.map(Tools.for_worker(:read_only), & &1.name)
    assert "load_skill" in Enum.map(Tools.for_worker(:read_write), & &1.name)
  end

  test "it runs through Tools.run/4" do
    dir = project_with_skill()

    assert {:ok, text} =
             Tools.run("load_skill", %{"name" => "release-notes"}, %{project_root: dir}, fn _,
                                                                                            _ ->
               :ok
             end)

    assert text =~ "Write release notes"
  end
end
