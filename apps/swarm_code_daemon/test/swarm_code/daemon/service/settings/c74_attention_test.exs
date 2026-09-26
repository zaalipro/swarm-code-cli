defmodule SwarmCode.Daemon.Service.Settings.C74AttentionTest do
  @moduledoc """
  pass 74 S2-14: every S2 handler's `attention/1` and `glance/1` on the
  Appendix A fixture — the expected items (AT1, AT5, AT8), their wire shape,
  and no secret in any of them.
  """
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Service.Settings, as: S
  alias SwarmCode.Daemon.Service.Settings.Wire
  alias SwarmCode.Settings.Sections
  alias SwarmCode.Test.C74S2

  @handlers [
    S.Providers,
    S.Efforts,
    S.Models,
    S.Pricing,
    S.Search,
    S.MCP,
    S.MCPImport,
    S.Storage,
    S.LSP,
    S.Files,
    S.Library,
    S.ProjectConfig
  ]

  @secrets [
    "sk-test-deepseek-00000000a1b2",
    "sk-ant-test-000000000000c3d4",
    "tvly-test-000000000000e5f6",
    "exa-test-0000000000000g7h8",
    "ghp_test_0000000000000000i9j0",
    "test-token-0000000000k1l2"
  ]

  setup do
    fx = C74S2.repo!("c74-attention")
    data = C74S2.appendix_a!(fx)

    on_exit(fn ->
      for server <- [data.github, data.fs, data.docs],
          do: SwarmCode.Domain.MCP.stop_client(server.id)
    end)

    Map.merge(data, %{ctx: C74S2.context(data.ailogic, data.conversation)})
  end

  defp attention(ctx) do
    for handler <- @handlers,
        Code.ensure_loaded?(handler),
        function_exported?(handler, :attention, 1),
        item <- handler.attention(ctx),
        do: item
  end

  defp glance(ctx) do
    for handler <- @handlers,
        Code.ensure_loaded?(handler),
        function_exported?(handler, :glance, 1),
        reduce: %{},
        do: (acc -> Map.merge(acc, handler.glance(ctx)))
  end

  test "Appendix A raises AT1, AT5 and AT8 — nothing else", c do
    items = attention(c.ctx)

    assert Enum.map(items, &{&1.id, &1.severity, &1.title}) |> Enum.sort() == [
             {"AT1", "error", "github MCP server failed to start"},
             {"AT5", "warning", "2 models in use have no price"},
             {"AT8", "warning", "ailogic's project file has entries SwarmCode ignores"}
           ]

    by_id = Map.new(items, &{&1.id, &1})
    assert by_id["AT1"].reason == "command not found: github-mcp-server"
    assert by_id["AT5"].reason == "claude-sonnet-5, qwen3-coder count as $0.00 in every cost"
    assert by_id["AT8"].reason == "effort, hooks.post_edit, profiles.fast.mode"
  end

  # cli74 G1 (QA F-9): the overview kept only the first handler item (every
  # atom-keyed item read as id nil), so the failed server behind the pricing
  # item was never counted.
  test "the overview counts every handler's items, one per source and target", c do
    items = S.Overview.attention_items(c.ctx)
    ids = Enum.map(items, & &1["id"])

    for id <- ~w(AT1 AT5 AT8), do: assert(id in ids, inspect(ids))
    assert Enum.all?(items, &is_binary(&1["id"]))

    at1 = Enum.find(items, &(&1["id"] == "AT1"))
    assert at1["title"] == "github MCP server failed to start"
    assert at1["severity"] == "error"
    # Errors first.
    assert hd(items)["severity"] == "error"

    two = S.Overview.finish([at1, %{at1 | "target" => %{"kind" => "mcp_server", "id" => "x"}}])
    assert length(two) == 2
    assert length(S.Overview.finish([at1, at1])) == 1
  end

  test "every item has the overview's wire shape and no secret", c do
    items = attention(c.ctx)
    json = items |> Wire.json() |> Jason.encode!()

    for secret <- @secrets, do: refute(json =~ secret)

    for item <- Wire.json(items) do
      assert Map.keys(item) |> Enum.sort() ==
               ~w(id reason section severity target title)

      assert item["severity"] in ~w(error warning)
      assert {:ok, _} = Sections.fetch(item["section"])
      assert Map.keys(item["target"]) in [["id", "kind"], ["key"]]
      assert is_binary(item["title"]) and is_binary(item["reason"])
    end
  end

  test "the glance: providers, search, mcp, storage — numbers and strings, ≤ 16 each", c do
    glance = glance(c.ctx)
    assert Map.keys(glance) |> Enum.sort() == ~w(mcp providers search storage)

    for {_name, fragment} <- glance do
      assert map_size(fragment) <= 16
      for {_k, v} <- fragment, do: assert(is_number(v) or is_binary(v))
    end

    assert glance["providers"]["count"] == 4 and glance["providers"]["usable"] == 3
    assert glance["search"]["on"] == 2
    assert glance["mcp"]["failed"] == 1
    refute glance |> Jason.encode!() |> String.contains?(@secrets)
  end

  test "a broken session raises the other items (AT2, AT3, AT6, AT7, AT12, AT15, AT17)", c do
    {:ok, _} = SwarmCode.Domain.Providers.update(c.deepseek, %{api_key: ""})
    {:ok, _} = SwarmCode.Domain.Search.upsert("tavily", %{enabled: false})
    {:ok, _} = SwarmCode.Domain.Search.upsert("exa", %{enabled: false})
    {:ok, _} = SwarmCode.Domain.Settings.update(%{research_reader: "firecrawl"})

    File.write!(
      Path.join([c.ailogic.root_path, ".swarm_code", "config.json"]),
      "{ not json"
    )

    File.write!(
      Path.join(S.Files.user_agents_dir(), "nameless.md"),
      "---\ndescription: x\n---\nbody\n"
    )

    ctx = %{
      c.ctx
      | task_results: %{
          {"provider.test", c.anthropic.id} =>
            C74S2.task_entry("t1", "failed", nil, message: "Anthropic rejected the API key (401)")
        }
    }

    ids = ctx |> attention() |> Enum.map(& &1.id) |> Enum.uniq() |> Enum.sort()
    assert ids == ~w(AT1 AT12 AT15 AT2 AT3 AT5 AT6 AT7)

    # AT17: a failed test of an enabled engine
    {:ok, _} = SwarmCode.Domain.Search.upsert("exa", %{enabled: true})

    ctx = %{
      ctx
      | task_results:
          Map.put(
            ctx.task_results,
            {"search.test", "exa"},
            C74S2.task_entry("t2", "failed", nil, message: "Exa error (500)")
          )
    }

    assert "AT17" in Enum.map(attention(ctx), & &1.id)
  end
end
