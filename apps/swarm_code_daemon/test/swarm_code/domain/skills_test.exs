defmodule SwarmCode.Domain.SkillsTest do
  @moduledoc "Spec 25 §1: discovery, scope precedence, caps, and the html-report skill."
  use ExUnit.Case, async: false

  alias SwarmCode.Domain.Skills

  setup do
    Skills.reset_builtins()
    on_exit(&Skills.reset_builtins/0)
    :ok
  end

  describe "§1.1 discovery" do
    test "the built-in skills are found and cached" do
      names = Enum.map(Skills.builtins(), & &1.name)
      assert "html-report" in names
      # Cached: the second call does not re-read the disk.
      assert Skills.builtins() == Skills.builtins()
    end

    test "a project skill shadows a built-in of the same name" do
      root = Path.join(System.tmp_dir!(), "sk-#{System.unique_integer([:positive])}")
      dir = Path.join([root, ".swarm_code", "skills", "html-report"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), "# mine\n\nA project override.\n")
      on_exit(fn -> File.rm_rf(root) end)

      skill = Skills.get(%{root_path: root}, "html-report")
      assert skill.scope == "project"
      assert skill.description == "A project override."
    end

    test "a folder with no SKILL.md is not a skill" do
      root = Path.join(System.tmp_dir!(), "sk-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join([root, ".swarm_code", "skills", "empty"]))
      on_exit(fn -> File.rm_rf(root) end)

      refute Enum.any?(Skills.list(%{root_path: root}), &(&1.name == "empty"))
    end

    test "get/2 answers nil for an unknown name" do
      assert is_nil(Skills.get(nil, "nope"))
    end
  end

  describe "§1.1 prompt" do
    test "the prompt carries SKILL.md and every asset, under its own heading" do
      skill = Skills.get(nil, "html-report")
      prompt = Skills.prompt(skill)

      assert prompt =~ "# Skill: html-report"
      assert prompt =~ "The six hard constraints"
      assert prompt =~ "html-report/themes.css"
      assert prompt =~ "html-report/components.html"
      assert prompt =~ "html-report/EXAMPLES.md"
      assert String.length(prompt) <= Skills.prompt_cap() + 20
    end

    test "an oversized asset is truncated, not dropped" do
      root = Path.join(System.tmp_dir!(), "sk-#{System.unique_integer([:positive])}")
      dir = Path.join([root, ".swarm_code", "skills", "big"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), "# big\n\nA skill.\n")
      File.write!(Path.join(dir, "huge.txt"), String.duplicate("x", Skills.asset_cap() * 2))
      on_exit(fn -> File.rm_rf(root) end)

      [asset] = Skills.get(%{root_path: root}, "big").assets
      assert String.length(asset.body) <= Skills.asset_cap() + 20
      assert String.ends_with?(asset.body, "…[truncated]")
    end

    test "prompt/1 of nil is empty" do
      assert Skills.prompt(nil) == ""
    end

    # spec 60 T23: a 1 MB asset is read bounded and capped exactly as before.
    test "a huge asset is read bounded and capped the same" do
      root = Path.join(System.tmp_dir!(), "sk-#{System.unique_integer([:positive])}")
      dir = Path.join([root, ".swarm_code", "skills", "mega"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), "# mega\n\nA skill.\n")
      content = String.duplicate("y", 1_000_000)
      File.write!(Path.join(dir, "huge.txt"), content)
      on_exit(fn -> File.rm_rf(root) end)

      project = %{root_path: root}
      [asset] = Skills.get(project, "mega").assets
      assert asset.body == String.slice(content, 0, 24_000) <> "\n…[truncated]"

      assert Skills.get(project, "../etc") == nil
      assert Skills.get(nil, "html-report").name == "html-report"
      assert Skills.get(nil, "html-report").scope == "builtin"
    end
  end

  describe "§1.2 the html-report skill" do
    test "it states all six hard constraints and the component vocabulary" do
      body = Skills.get(nil, "html-report").body

      assert body =~ "One file"
      assert body =~ "No JavaScript for content"
      assert body =~ ":root` token block"
      assert body =~ "Three fonts, three jobs"
      assert body =~ "letter-spacing"
      assert body =~ "Every number carries its source"

      for component <- ~w(hero stat-strip spec-row compare-table callout verdict sources) do
        assert body =~ component, "the vocabulary is missing #{component}"
      end
    end

    test "themes.css has five palettes and four font pairings" do
      css = asset("themes.css")
      assert length(String.split(css, ":root {")) - 1 == 5
      for f <- ~w(font-a font-b font-c font-d), do: assert(css =~ "." <> f)
      # Constraint 4: numbers are always mono and tabular.
      assert css =~ "font-variant-numeric: tabular-nums"
    end

    # spec 60 T98: the shared rules read `--a1-dim` (links), `--warn`/`--gold`
    # (callouts); ledger lacked the second pair, editorial the first.
    test "every palette defines what the shared rules use" do
      css = asset("themes.css")
      blocks = Regex.scan(~r/:root \{([^}]*)\}/, css) |> Enum.map(fn [_, body] -> body end)
      assert length(blocks) == 5

      for body <- blocks do
        assert body =~ "--a1-dim:", "a palette lacks --a1-dim"
        assert body =~ "--a2-dim:", "a palette lacks --a2-dim"
        assert body =~ "--warn:" or body =~ "--gold:", "a palette lacks --warn/--gold"
      end
    end

    test "components.html has a snippet for every component and no CDN script" do
      html = asset("components.html")

      for component <- ~w(hero stat-strip section-header spec-row bar-track compare
                          callout verdict chip-tag quote timeline sources) do
        assert html =~ component, "components.html is missing #{component}"
      end

      refute html =~ "<script"
      refute html =~ "cdn."
    end

    test "EXAMPLES.md names each of the six reference reports" do
      examples = asset("EXAMPLES.md")

      for report <- ~w(nvfp4-dgx-spark-dashboard xmrig-vps-mining-report algae_biofuel_report
                       china_ai_gpus_report qwen35_122b_memory mlx_quantization) do
        assert examples =~ report
      end
    end
  end

  defp asset(name) do
    skill = Skills.get(nil, "html-report")
    Enum.find_value(skill.assets, "", fn a -> if a.name == name, do: a.body end)
  end
end
