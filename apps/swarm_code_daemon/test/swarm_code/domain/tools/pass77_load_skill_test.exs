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

  describe "RD-2: a project skill cannot read outside the project through a link" do
    setup do
      outside = Fixtures.tmp_dir()
      File.write!(Path.join(outside, "secret.txt"), "TOP-SECRET")
      File.write!(Path.join(outside, "SKILL.md"), "# Stolen\n\nTOP-SECRET skill body\n")
      {:ok, dir: project_with_skill(), outside: outside}
    end

    test "a linked asset is not loaded", %{dir: dir, outside: outside} do
      skill = Path.join([dir, ".swarm_code", "skills", "release-notes"])
      File.ln_s!(Path.join(outside, "secret.txt"), Path.join(skill, "linked.txt"))

      assert {:ok, text} = run(%{"name" => "release-notes"}, dir)
      assert text =~ "release-notes/template.md"
      refute text =~ "TOP-SECRET"
      refute text =~ "linked.txt"
    end

    test "a linked SKILL.md is not loaded, listed or described", %{dir: dir, outside: outside} do
      skills = Path.join([dir, ".swarm_code", "skills"])
      File.mkdir_p!(Path.join(skills, "stolen"))
      File.ln_s!(Path.join(outside, "SKILL.md"), Path.join([skills, "stolen", "SKILL.md"]))

      assert {:error, _} = run(%{"name" => "stolen"}, dir)
      assert {:ok, listing} = run(%{}, dir)
      refute listing =~ "stolen"
      refute listing =~ "TOP-SECRET"
    end

    test "a linked skill directory is not loaded or listed", %{dir: dir, outside: outside} do
      skills = Path.join([dir, ".swarm_code", "skills"])
      File.ln_s!(outside, Path.join(skills, "linked-dir"))

      assert {:error, _} = run(%{"name" => "linked-dir"}, dir)
      assert {:ok, listing} = run(%{}, dir)
      refute listing =~ "linked-dir"
    end

    test "a link that stays inside the project still works", %{dir: dir} do
      skill = Path.join([dir, ".swarm_code", "skills", "release-notes"])
      File.write!(Path.join(dir, "shared.md"), "shared notes")
      File.ln_s!(Path.join(dir, "shared.md"), Path.join(skill, "shared-link.md"))

      assert {:ok, text} = run(%{"name" => "release-notes"}, dir)
      assert text =~ "shared notes"
    end

    test "dot and dot-dot are not skill names", %{dir: dir} do
      File.write!(
        Path.join([dir, ".swarm_code", "SKILL.md"]),
        "# Up\n\nabove the skills folder\n"
      )

      assert {:error, _} = run(%{"name" => ".."}, dir)
      assert {:error, _} = run(%{"name" => "."}, dir)
    end
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
