defmodule SwarmCode.Daemon.Service.Settings.C74LibraryTest do
  @moduledoc "pass 74 S2-12: the library in settings (§3.5.7, AT12)."
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Service.Settings.{Files, Library}
  alias SwarmCode.Test.C74S2

  setup do
    fx = C74S2.repo!("c74-library")
    data = C74S2.appendix_a!(fx)
    Map.merge(data, %{fx: fx, ctx: C74S2.context(data.ailogic, data.conversation)})
  end

  defp records(c, kind, ctx \\ nil) do
    {:ok, page} = Library.query("records", kind, %{}, ctx || c.ctx)
    C74S2.declared!(page)
    Enum.map(page["items"], & &1["fields"])
  end

  defp by(rows, key), do: Enum.group_by(rows, & &1[key])

  describe "lists on the fixture project" do
    test "commands: scope, project over global, the three built-in names", c do
      commands = Path.join([c.ailogic.root_path, ".swarm_code", "commands"])
      File.write!(Path.join(commands, "review.md"), "---\ndescription: Project review\n---\nGo\n")
      File.write!(Path.join([c.fx.config_dir, "commands", "settings.md"]), "Mine\n")

      rows = records(c, "commands")

      assert Enum.map(rows, &{&1["name"], &1["scope"]}) ==
               [{"deploy", "project"}, {"review", "project"}, {"settings", "global"}]

      named = Map.new(rows, &{&1["name"], &1})
      assert named["review"]["overrides_global"]
      refute named["deploy"]["overrides_global"]
      assert named["deploy"]["swarm"] and named["deploy"]["mode"] == "plan"
      assert named["settings"]["shadowed_by_builtin"]
      assert named["deploy"]["ref"] == "command:project:#{c.ailogic.id}:deploy"
      assert {:ok, _} = Files.resolve(named["settings"]["ref"])
    end

    test "agent definitions: three tiers, shadowing, parse errors kept", c do
      File.write!(
        Path.join(c.fx.user_agents_dir, "broken.md"),
        "---\ndescription: no name\n---\nx\n"
      )

      rows = records(c, "agent_defs")
      tiers = by(rows, "name")

      assert [project, bundled] = tiers["reviewer"]

      assert {project["tier"], project["shadowed"], project["shadows"]} ==
               {"project", false, "bundled"}

      assert {bundled["tier"], bundled["shadowed"]} == {"bundled", true}
      assert project["effort"] == "high" and project["tools_label"] == "all tools"

      assert [user_scout, bundled_scout] = tiers["scout"]
      assert user_scout["tier"] == "user" and user_scout["tools_label"] == "read_file, grep"
      assert bundled_scout["shadowed"]

      assert [broken] = tiers["broken"]
      assert broken["parse_error"] == "agent definition missing name"

      assert [
               %{
                 id: "AT12",
                 title: "broken.md: agent definition missing name",
                 reason: "agent definition not read"
               }
             ] =
               Library.attention(c.ctx)
    end

    test "skills: the project skill shadows the built-in one", c do
      rows = records(c, "skills")
      assert [project, builtin] = by(rows, "name")["html-report"]
      assert {project["scope"], project["shadowed"]} == {"project", false}
      assert {builtin["scope"], builtin["shadowed"]} == {"builtin", true}
      assert project["description"] == "Writes an HTML report." and project["files"] == 1
    end

    test "workflows with their smoke from the task cache; the smoke task", c do
      rows = records(c, "workflows")
      named = by(rows, "name")
      assert [%{"scope" => "user", "smoke" => nil}] = named["nightly"]
      assert [%{"scope" => "project"} = broken] = named["broken"]
      assert Enum.any?(rows, &(&1["scope"] == "builtin"))

      {:task, spec, _} = Library.command(C74S2.command("workflow.smoke"), c.ctx)
      assert spec.key == "all" and spec.timeout_ms == 30_000
      {:ok, result} = C74S2.run_task(spec)
      smoke = Map.new(result["rows"], &{&1["name"], &1["smoke"]})
      assert smoke["nightly"] == "ok"
      assert smoke["broken"] =~ "System.os_time/0 is not deterministic"
      assert result["failed"] == 1
      for row <- result["rows"], do: C74S2.declared!(%{"kind" => "smoke_row", "fields" => row})

      ctx = %{
        c.ctx
        | task_results: %{{"workflow.smoke", "all"} => C74S2.task_entry("s1", "done", result)}
      }

      smoked = Map.new(records(c, "workflows", ctx), &{&1["ref"], &1["smoke"]})
      assert smoked[broken["ref"]] =~ "os_time"

      {:task, one, _} =
        Library.command(C74S2.command("workflow.smoke", target: %{"ref" => broken["ref"]}), c.ctx)

      assert {:ok, %{"checked" => 1}} = C74S2.run_task(one)

      assert {:error, %{code: :not_found}} =
               Library.command(
                 C74S2.command("workflow.smoke", target: %{"ref" => "workflow:user:-:nope"}),
                 c.ctx
               )
    end
  end

  describe "file.create" do
    defp create(c, target), do: Files.command(C74S2.command("file.create", target: target), c.ctx)

    test "from the template, in a new 0700 tier folder", c do
      {:ok, created} = create(c, %{"kind" => "skill", "scope" => "user", "name" => "notes-kit"})
      assert created.status == :accepted and created.message == "notes-kit created"
      skills = Path.join(c.fx.config_dir, "skills")

      assert File.read!(Path.join([skills, "notes-kit", "SKILL.md"])) ==
               "# notes-kit\n\nDescribe what this skill does in the first line.\n"

      assert File.stat!(skills).mode |> Bitwise.band(0o777) == 0o700

      {:ok, agent} = create(c, %{"kind" => "agent", "scope" => "project", "name" => "linter"})
      assert agent.record["fields"]["ref"] == "agent:project:#{c.ailogic.id}:linter"

      assert File.read!(Path.join([c.ailogic.root_path, ".swarm_code", "agents", "linter.md"])) =~
               "name: linter\ndescription: What this agent is for\ntools: read_file,grep,find_files"

      {:ok, command} = create(c, %{"kind" => "command", "scope" => "global", "name" => "ship"})
      assert command.status == :accepted
      assert File.read!(Path.join([c.fx.config_dir, "commands", "ship.md"])) =~ "swarm: false"
    end

    test "an existing or bad name is refused", c do
      assert {:error, %{field_errors: [%{target: "name", message: "already exists"}]}} =
               create(c, %{"kind" => "command", "scope" => "project", "name" => "deploy"})

      assert {:error,
              %{field_errors: [%{message: "lowercase letters, digits, ., _ or - (64 max)"}]}} =
               create(c, %{"kind" => "command", "scope" => "global", "name" => "../evil"})

      assert {:error, %{field_errors: [%{message: "lowercase letters, digits, - or _ (24 max)"}]}} =
               create(c, %{
                 "kind" => "agent",
                 "scope" => "user",
                 "name" => String.duplicate("a", 25)
               })

      assert {:error, %{code: :invalid}} =
               create(c, %{"kind" => "agent", "scope" => "bundled", "name" => "mine"})
    end

    test "a bundled file cannot be deleted", c do
      ref = "agent:bundled:-:reviewer"
      {:ok, %{"file" => file}} = Files.query("file", nil, %{"id" => ref}, c.ctx)

      {:ok, refused} =
        Files.command(
          C74S2.command("file.delete",
            target: %{"ref" => ref},
            expected: %{"fingerprint" => file["fields"]["fingerprint"]}
          ),
          c.ctx
        )

      assert refused.status == :rejected

      assert refused.message ==
               "a built-in file cannot be deleted; make a user copy to override it"
    end
  end
end
