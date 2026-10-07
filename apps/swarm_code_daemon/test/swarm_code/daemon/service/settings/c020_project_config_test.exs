defmodule SwarmCode.Daemon.Service.Settings.C020ProjectConfigTest do
  @moduledoc """
  cli020 C23 (competitors-10, competitors-11): the five new hook events and
  the `"permissions"` key are known to the project file's record, malformed
  rules are listed, and `project_config.summary` answers hooks and rules.
  """
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Service.Settings.ProjectConfig
  alias SwarmCode.Test.C74S2

  setup do
    fx = C74S2.repo!("c020-project-config")
    data = C74S2.appendix_a!(fx)
    Map.merge(data, %{fx: fx})
  end

  defp write!(project, json) do
    dir = Path.join(project.root_path, ".swarm_code")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "config.json"), Jason.encode!(json))
  end

  defp fields!(project) do
    {:ok, record} = ProjectConfig.query("record", "project_config", %{"id" => project.id}, %{})
    C74S2.declared!(record)
    record["fields"]
  end

  test "the new events and permissions are known; bad rules are listed", c do
    write!(c.ailogic, %{
      "hooks" => %{
        "stop" => [%{"command" => "say done"}],
        "session_end" => [%{"command" => "echo bye"}],
        "user_prompt_submit" => [%{"command" => "./check"}]
      },
      "permissions" => %{
        "allow" => ["read_file", "run_command(mix test*)"],
        "ask" => [42, "bad rule!"],
        "deny" => ["run_command(rm -rf *)", String.duplicate("x", 257)],
        "sometimes" => []
      }
    })

    fields = fields!(c.ailogic)
    assert fields["unknown_keys"] == []
    assert fields["top_level"] == %{}
    assert [%{"command" => "say done"}] = fields["hooks"]["stop"]
    assert [%{"command" => "echo bye"}] = fields["hooks"]["session_end"]

    assert Enum.map(fields["ignored_entries"], &{&1["path"], &1["severity"]}) == [
             {"permissions.ask[0]", "error"},
             {"permissions.ask[1]", "error"},
             {"permissions.deny[1]", "error"},
             {"permissions.sometimes", "warning"}
           ]
  end

  test "permissions that are not an object, and more than 100 rules", c do
    write!(c.ailogic, %{"permissions" => ["read_file"]})

    assert [%{"path" => "permissions", "severity" => "error"}] =
             fields!(c.ailogic)["ignored_entries"]

    write!(c.ailogic, %{"permissions" => %{"allow" => for(i <- 1..101, do: "tool_#{i}")}})

    assert [%{"path" => "permissions.allow", "severity" => "warning", "reason" => reason}] =
             fields!(c.ailogic)["ignored_entries"]

    assert reason =~ "first 100"
  end

  test "project_config.summary: hooks (120 bytes) and the three rule lists", c do
    long = String.duplicate("a", 200)

    write!(c.ailogic, %{
      "hooks" => %{
        "pre_compact" => [%{"command" => long}],
        "post_tool_use" => [%{"command" => "mix format"}]
      },
      "permissions" => %{"allow" => ["read_file"], "deny" => ["run_command(rm *)", 7]}
    })

    assert {:ok, summary} =
             ProjectConfig.query("project_config.summary", nil, %{"id" => c.ailogic.id}, %{})

    assert %{"event" => "post_tool_use", "command" => "mix format"} in summary["hooks"]

    assert %{"event" => "pre_compact", "command" => String.duplicate("a", 120)} in summary[
             "hooks"
           ]

    assert summary["permissions"] == %{
             "allow" => ["read_file"],
             "ask" => [],
             "deny" => ["run_command(rm *)"]
           }

    assert {:ok, module} =
             SwarmCode.Daemon.Service.Settings.Router.view("project_config.summary", nil)

    assert module == ProjectConfig
  end

  test "a missing file has no hooks and no rules", c do
    File.rm_rf!(Path.join(c.ailogic.root_path, ".swarm_code/config.json"))

    assert {:ok, %{"hooks" => [], "permissions" => %{"allow" => [], "ask" => [], "deny" => []}}} =
             ProjectConfig.query("project_config.summary", nil, %{"id" => c.ailogic.id}, %{})
  end
end
