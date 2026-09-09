defmodule SwarmCode.Daemon.Service.FeatureRequestTest do
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.FeatureRequest
  alias SwarmCode.Domain.{Cache, Conversations, Projects, Repo, Scheduled, Settings}
  alias SwarmCode.Protocol.{Scope, ServiceRequest}

  setup_all do
    root = Path.join(System.tmp_dir!(), "feature-wire-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    File.mkdir_p!(Path.join(root, "other"))

    on_exit(fn ->
      Cache.clear()
      File.rm_rf!(root)
    end)

    start_supervised!(
      {Repo,
       database: Path.join(root, "fixture.db"), domain_fixture: true, pool_size: 1, log: false}
    )

    Ecto.Migrator.run(
      Repo,
      Application.app_dir(:swarm_code_daemon, "priv/domain_repo/migrations"),
      :up,
      all: true,
      log: false
    )

    Cache.clear()
    {:ok, project} = Projects.create(%{name: "One", root_path: root})
    {:ok, other} = Projects.create(%{name: "Two", root_path: Path.join(root, "other")})
    {:ok, conv} = Conversations.create(project.id)

    %{
      project: project,
      other: other,
      conv: conv,
      scope: %Scope{kind: :conversation, id: conv.id, generation: 2}
    }
  end

  test "settings changes return bounded outcome and queries omit credentials", _c do
    {:ok, _} = Settings.update(%{tavily_api_key: "private-value"})
    global = %Scope{kind: :global, id: nil, generation: 2}

    assert {:ok, %{"value" => %{"status" => "accepted", "request_id" => "change"}}} =
             command(global, "settings", "update", "settings", %{"max_concurrent_agents" => 7})

    assert Settings.get().max_concurrent_agents == 7

    query = %ServiceRequest{
      operation: :feature_query,
      params: %{
        "feature" => "settings",
        "id" => nil,
        "cursor" => nil,
        "page_size" => 20,
        "byte_limit" => 65_536
      },
      timeout_ms: 5000
    }

    assert {:ok, %{"response_kind" => "library_snapshot", "value" => page}} =
             FeatureRequest.execute(query, global, "query", 4)

    assert page["through_sequence"] == 4
    refute inspect(page) =~ "private-value"
  end

  test "memory update and clear stay scoped to the admitted project", c do
    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             command(c.scope, "memory", "update", c.project.id, %{"content" => "CLI fact"})

    assert File.read!(Path.join(c.project.root_path, ".swarm_code/MEMORY.md")) == "CLI fact"

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             command(c.scope, "memory", "clear", c.project.id, %{})

    assert File.read!(Path.join(c.project.root_path, ".swarm_code/MEMORY.md")) == ""

    assert {:ok, %{"value" => %{"status" => "rejected"}}} =
             command(c.scope, "memory", "update", c.other.id, %{"content" => "nope"})
  end

  test "schedule creation binds ownership to the selected project", c do
    attrs = %{
      "name" => "Daily",
      "prompt" => "Review",
      "kind" => "chat",
      "schedule_kind" => "daily",
      "time_of_day" => "09:00",
      "timezone" => "UTC"
    }

    assert {:ok, %{"value" => %{"status" => "accepted", "identifiers" => [id]}}} =
             command(c.scope, "schedules", "save", nil, attrs)

    assert Scheduled.get(id).project_id == c.project.id

    assert {:ok, %{"value" => %{"status" => "rejected"}}} =
             command(c.scope, "schedules", "save", nil, Map.put(attrs, "project_id", c.other.id))
  end

  test "cross-project schedule mutations are refused before changing persisted rows", c do
    {:ok, row} =
      Scheduled.create(%{
        name: "Foreign",
        prompt: "Review",
        kind: "chat",
        project_id: c.other.id,
        schedule_kind: "daily",
        time_of_day: "09:00",
        timezone: "UTC"
      })

    for action <- ["toggle", "run_now", "delete"] do
      assert {:ok, %{"value" => %{"status" => "rejected", "error" => %{"code" => "not_allowed"}}}} =
               command(c.scope, "schedules", action, row.id, %{})
    end

    assert Scheduled.get(row.id).enabled == row.enabled
  end

  test "research start binds the admitted project and rejects foreign project", c do
    attrs = %{"question" => "Fixture research", "level" => "medium", "project_id" => c.other.id}

    assert {:ok, %{"value" => %{"status" => "rejected"}}} =
             command(c.scope, "research", "start", nil, attrs)
  end

  test "MCP server form saves a project-scoped disabled server and exposes safe controls", c do
    attrs = %{
      "name" => "Fixture MCP",
      "transport" => "stdio",
      "command" => "fixture-mcp",
      "enabled" => false
    }

    assert {:ok, %{"value" => %{"status" => "accepted", "identifiers" => [id]}}} =
             command(c.scope, "mcp", "save", nil, attrs)

    query = %ServiceRequest{
      operation: :feature_query,
      params: %{
        "feature" => "mcp",
        "id" => nil,
        "cursor" => nil,
        "page_size" => 20,
        "byte_limit" => 65_536
      },
      timeout_ms: 5_000
    }

    assert {:ok, %{"response_kind" => "library_snapshot", "value" => %{"items" => items}}} =
             FeatureRequest.execute(query, c.scope, "mcp-query", 1)

    row = Enum.find(items, &(&1["id"] == id))
    assert row["status"] == "disabled"
    assert "toggle" in row["actions"]
    assert get_in(row, ["form", "title"]) == "Configure MCP server"
    refute inspect(row) =~ "fixture-secret"
  end

  test "research creation persists the requested question and depth and starts a real provider turn",
       c do
    alias SwarmCode.Test.LoopbackHTTP, as: HTTP
    alias SwarmCode.Domain.{Providers, Research}
    config = Application.get_env(:swarm_code_daemon, :domain_config_dir)
    research_root = Application.get_env(:swarm_code_daemon, :research_root)
    llm = Application.get_env(:swarm_code_daemon, :llm_providers)

    Application.put_env(
      :swarm_code_daemon,
      :domain_config_dir,
      Path.join(c.project.root_path, "research-config")
    )

    Application.put_env(
      :swarm_code_daemon,
      :research_root,
      Path.join(c.project.root_path, "research-output")
    )

    Application.put_env(:swarm_code_daemon, :llm_providers, %{
      "openai_compatible" => SwarmCode.Domain.LLM.OpenAI
    })

    server =
      HTTP.start(fn socket, _request, _index ->
        HTTP.stream(socket, [
          HTTP.sse(%{
            "choices" => [
              %{"delta" => %{"content" => "Research fixture response"}, "finish_reason" => "stop"}
            ]
          })
        ])
      end)

    on_exit(fn ->
      HTTP.stop(server)

      if research_root,
        do: Application.put_env(:swarm_code_daemon, :research_root, research_root),
        else: Application.delete_env(:swarm_code_daemon, :research_root)

      if config,
        do: Application.put_env(:swarm_code_daemon, :domain_config_dir, config),
        else: Application.delete_env(:swarm_code_daemon, :domain_config_dir)

      if llm,
        do: Application.put_env(:swarm_code_daemon, :llm_providers, llm),
        else: Application.delete_env(:swarm_code_daemon, :llm_providers)
    end)

    {:ok, provider} =
      Providers.create(%{
        name: "research-fixture",
        kind: "openai_compatible",
        base_url: server.url <> "/v1",
        api_key: "fixture",
        models: ["research-model"],
        default_model: "research-model"
      })

    {:ok, _} =
      Settings.update(%{
        default_swarm_provider_id: provider.id,
        default_swarm_model: "research-model",
        research_auto_design: "never"
      })

    assert {:ok, %{"value" => %{"status" => "accepted", "identifiers" => [id]}}} =
             command(c.scope, "research", "start", nil, %{
               "question" => "Compare local database engines",
               "level" => "low"
             })

    research_id = String.to_integer(id)
    on_exit(fn -> Research.stop(research_id) end)
    row = Research.get(research_id)
    assert row.question == "Compare local database engines"
    assert row.level == "low"
    assert row.project_id == c.project.id
    assert String.starts_with?(row.dir, c.project.root_path)
    assert_receive {:http_request, _, request}, 10_000
    assert request.body =~ "Compare local database engines"
    assert request.body =~ "research-model"
    Research.stop(research_id)
  end

  test "unknown operations and attributes do not reach domain mutation", c do
    assert {:ok, %{"value" => %{"status" => "rejected"}}} =
             command(c.scope, "settings", "update", "settings", %{
               "tavily_api_key" => "not-allowed"
             })

    assert {:ok, %{"value" => %{"status" => "rejected"}}} =
             command(c.scope, "settings", "delete", "settings", %{})
  end

  defp command(scope, feature, action, id, attrs) do
    request = %ServiceRequest{
      operation: :feature_command,
      timeout_ms: 5_000,
      params: %{"feature" => feature, "action" => action, "id" => id, "attributes" => attrs}
    }

    FeatureRequest.execute(request, scope, "change", 0)
  end
end
