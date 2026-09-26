defmodule SwarmCode.Daemon.Service.Settings.C74OverviewTest do
  @moduledoc """
  pass74 S1-8: the overview (attention order and cap, AT10 with the one usable
  predicate), facts (no secret environment value), usage (`no price` rows),
  `records:projects` and the `open` view equal to the four views it combines.
  """
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Service.SessionConfiguration
  alias SwarmCode.Daemon.Service.Settings
  alias SwarmCode.Daemon.Service.Settings.Overview
  alias SwarmCode.Domain.{Conversations, Projects, Providers, Repo}
  alias SwarmCode.Test.C74S1

  setup do
    %{dir: dir} = C74S1.repo!()
    %{dir: dir}
  end

  test "attention: errors first, then warnings, then rail order; at most 64" do
    items =
      for i <- 1..70 do
        %{
          "id" => "i#{i}",
          "severity" => if(rem(i, 3) == 0, do: "error", else: "warning"),
          "section" => Enum.at(["storage", "mcp", "providers", "overview"], rem(i, 4)),
          "target" => nil,
          "title" => "t",
          "reason" => nil
        }
      end

    sorted = Overview.sort(items)
    {errors, warnings} = Enum.split_while(sorted, &(&1["severity"] == "error"))
    assert length(errors) == 23 and Enum.all?(warnings, &(&1["severity"] == "warning"))

    rail = SwarmCode.Settings.Sections.id_strings()
    order = fn list -> Enum.map(list, &Enum.find_index(rail, fn s -> s == &1["section"] end)) end
    assert order.(errors) == Enum.sort(order.(errors))
    assert order.(warnings) == Enum.sort(order.(warnings))
    assert length(Overview.finish(items)) == 64
  end

  test "AT10 on a fresh database seeded without a key; a keyless private-host provider is usable",
       %{dir: dir} do
    prior = System.get_env("LLMOTIONS_API_KEY")
    System.delete_env("LLMOTIONS_API_KEY")
    on_exit(fn -> if prior, do: System.put_env("LLMOTIONS_API_KEY", prior) end)

    :ok = Providers.seed_defaults()
    project = C74S1.project!(dir, "fresh")
    ctx = C74S1.context(%{ailogic: project, conversation: nil})

    assert {:ok, %{"attention" => attention}} = Settings.query("overview", %{}, ctx)
    assert [%{"id" => "no_provider", "severity" => "error"} | _] = attention
    assert hd(attention)["title"] == "No provider can answer"

    C74S1.provider!(%{
      name: "LAN",
      kind: "openai_compatible",
      base_url: "http://192.168.1.20:8000/v1",
      models: ["m"],
      default_model: "m"
    })

    assert {:ok, %{"attention" => attention}} = Settings.query("overview", %{}, ctx)
    refute Enum.any?(attention, &(&1["id"] == "no_provider"))

    assert %{"title" => "The chat model's provider llmotions has no key"} =
             Enum.find(attention, &(&1["id"] == "chat_provider_keyless"))
  end

  test "the usable predicate (D11)" do
    usable = fn attrs -> SessionConfiguration.usable?(Map.merge(%{api_key: nil}, attrs)) end

    assert usable.(%{api_key: "sk-x", base_url: "https://api.example.com/v1"})
    assert usable.(%{base_url: "http://127.0.0.1:11434/v1"})
    assert usable.(%{base_url: "http://192.168.1.20:8000/v1"})
    assert usable.(%{base_url: "http://box.local:8000/v1"})
    refute usable.(%{base_url: "https://openrouter.ai/api/v1"})
    refute usable.(%{api_key: "  ", base_url: "https://openrouter.ai/api/v1"})
    refute SessionConfiguration.usable?(nil)
  end

  test "facts never carry a secret environment value", %{dir: dir} do
    fixture = C74S1.appendix_a!(dir)
    canary = C74S1.canary()

    ctx =
      C74S1.context(fixture,
        env: %{
          "OPENAI_API_KEY" => canary,
          "SWARM_API_KEY" => canary,
          "VISUAL" => "hx",
          "SWARM_BASE_URL" => "https://user:#{canary}@example.com"
        }
      )

    assert {:ok, facts} = Settings.query("facts", %{}, ctx)
    refute Jason.encode!(facts) =~ canary
    visual = Enum.find(facts["env"], &(&1["name"] == "VISUAL"))
    assert %{"set" => true, "value" => "hx", "secret" => false} = visual
    key = Enum.find(facts["env"], &(&1["name"] == "OPENAI_API_KEY"))
    assert %{"set" => true, "value" => nil, "secret" => true} = key
    assert facts["scheduler"] == "desktop_only"
    # cli74 F42: the database the service has open, and its bytes (it read a config key).
    assert File.regular?(facts["paths"]["database"])
    assert facts["database_bytes"] > 0
    assert facts["paths"]["project_dir"] =~ ".swarm_code"
    assert length(facts["research_levels"]) == 4
  end

  test "usage: this month's spend and a no-price row", %{dir: dir} do
    fixture = C74S1.appendix_a!(dir)

    {:ok, _} =
      SwarmCode.Domain.Settings.update(%{
        pricing: %{"deepseek-v4-pro" => %{"input" => 0.27, "output" => 1.1}}
      })

    for {model, cost} <- [{"deepseek-v4-pro", 30.1}, {"claude-sonnet-5", nil}] do
      {:ok, _} =
        Conversations.create_run(%{
          conversation_id: fixture.conversation.id,
          kind: "chat",
          status: "done",
          started_at: DateTime.utc_now(),
          model: model,
          tokens_in: 1000,
          tokens_out: 100,
          cost_usd: cost
        })
    end

    assert {:ok, usage} = Settings.query("usage", %{}, C74S1.context(fixture))
    assert usage["month"]["budget_usd"] == 50
    assert_in_delta usage["month"]["spend_usd"], 30.1, 0.001
    by_model = Map.new(usage["by_model"], &{&1["model"], &1})
    assert by_model["claude-sonnet-5"]["cost_usd"] == nil
    assert_in_delta by_model["deepseek-v4-pro"]["cost_usd"], 30.1, 0.001
  end

  test "records:projects: newest first, scratch only when current", %{dir: dir} do
    fixture = C74S1.appendix_a!(dir)
    scratch = Projects.scratch!()
    {:ok, _} = Projects.touch(fixture.notes)

    assert {:ok, %{"items" => items, "total" => 2}} =
             Settings.query("records", %{"kind" => "projects"}, C74S1.context(fixture))

    assert Enum.map(items, & &1["fields"]["name"]) == ["notes", "ailogic"]
    assert Enum.find(items, & &1["fields"]["current"])["id"] == fixture.ailogic.id

    in_scratch = C74S1.context(fixture, project: scratch)

    assert {:ok, %{"total" => 3}} =
             Settings.query("records", %{"kind" => "projects"}, in_scratch)
  end

  test "open equals the four views it combines", %{dir: dir} do
    fixture = C74S1.appendix_a!(dir)
    ctx = C74S1.context(fixture)

    assert {:ok, open} = Settings.query("open", %{}, ctx)
    assert {:ok, values} = Settings.query("values", %{}, ctx)
    assert {:ok, overview} = Settings.query("overview", %{}, ctx)
    assert {:ok, facts} = Settings.query("facts", %{}, ctx)

    assert {:ok, projects} =
             Settings.query("records", %{"kind" => "projects", "page_size" => 200}, ctx)

    assert open["values"] == values
    assert open["overview"] == overview
    assert Map.delete(open["facts"], "database_bytes") == Map.delete(facts, "database_bytes")
    assert open["projects"] == projects
    assert Repo.aggregate(SwarmCode.Domain.Settings.Setting, :count) == 1
  end
end
