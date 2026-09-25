defmodule SwarmCodeCLI.UI.DataSource.C74SettingsIntegrationsTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations, as: I

  @ids I.ids()
  @canary "sk-test-CANARY-0000000000zz99"

  defp cmd(action, target \\ %{}, attributes \\ %{}, opts \\ []) do
    %{
      "action" => action,
      "target" => target,
      "attributes" => attributes,
      "expected" => Keyword.get(opts, :expected),
      "secrets" => Keyword.get(opts, :secrets, []),
      "dry_run" => false
    }
  end

  defp ok(state, command) do
    {{:ok, result}, state} = I.command(state, command)
    {result, state}
  end

  defp started(state, command) do
    {{:task, task, result}, state} = I.command(state, command)
    assert result["status"] == "accepted"
    {Map.put(task, "task_id", "task-#{command["action"]}"), state}
  end

  defp record!(state, kind, id) do
    {:ok, rec} = I.query(state, %{"view" => "record", "kind" => kind, "id" => id})
    rec["fields"]
  end

  defp items(state, kind, options \\ %{}) do
    {:ok, page} = I.query(state, %{"view" => "records", "kind" => kind, "options" => options})
    page["items"]
  end

  # a minimal, valid command for every action; the point is that each one answers
  defp sample(action) do
    %{
      "provider.create" =>
        cmd(action, %{}, %{
          "name" => "LM Studio",
          "kind" => "openai_compatible",
          "base_url" => "http://localhost:1234/v1"
        }),
      "provider.update" => cmd(action, %{"id" => @ids.deepseek}, %{"name" => "DeepSeek 2"}),
      "provider.set_key" =>
        cmd(action, %{"id" => @ids.openrouter}, %{"test_first" => false},
          secrets: [%{"slot" => "api_key", "value" => @canary}]
        ),
      "provider.clear_key" => cmd(action, %{"id" => @ids.deepseek}),
      "provider.delete" => cmd(action, %{"id" => @ids.openrouter}),
      "provider.test" => cmd(action, %{"id" => @ids.deepseek}),
      "provider.fetch_models" => cmd(action, %{"id" => @ids.deepseek}),
      "provider.apply_models" =>
        cmd(action, %{"id" => @ids.deepseek}, %{"fetch_task_id" => "gone", "mode" => "add"}),
      "provider.fetch_all" => cmd(action),
      "provider.forget_caps" => cmd(action, %{"id" => @ids.anthropic}),
      "efforts.save" =>
        cmd(action, %{"id" => @ids.ollama, "model" => nil}, %{
          "rows" => [%{"key" => "on", "body" => %{}}]
        }),
      "efforts.remove_override" => cmd(action, %{"id" => @ids.ollama, "model" => "qwen3-coder"}),
      "pricing.put_row" =>
        cmd(action, %{}, %{"model" => "qwen3-coder", "input" => 0, "output" => 0}),
      "pricing.delete_row" => cmd(action, %{"model" => "claude-opus-5"}),
      "search.update" => cmd(action, %{"kind" => "jina"}, %{"enabled" => true}),
      "search.set_key" =>
        cmd(action, %{"kind" => "brave"}, %{"test_first" => false},
          secrets: [%{"slot" => "api_key", "value" => "BSA-0000000000000000"}]
        ),
      "search.clear_key" => cmd(action, %{"kind" => "exa"}),
      "search.move" => cmd(action, %{"kind" => "exa"}, %{"dir" => -1}),
      "search.test" => cmd(action, %{"kind" => "tavily"}),
      "mcp.create" =>
        cmd(action, %{}, %{"name" => "echo", "transport" => "stdio", "command" => "echo-mcp"}),
      "mcp.update" => cmd(action, %{"id" => @ids.fs}, %{"args" => ["/tmp"]}),
      "mcp.set_secret" =>
        cmd(
          action,
          %{"id" => @ids.github, "map" => "env", "name" => "GITHUB_PERSONAL_ACCESS_TOKEN"},
          %{},
          secrets: [
            %{
              "slot" => "env:GITHUB_PERSONAL_ACCESS_TOKEN",
              "value" => "ghp_new_000000000000000000"
            }
          ]
        ),
      "mcp.toggle" => cmd(action, %{"id" => @ids.docs}, %{"enabled" => false}),
      "mcp.set_tools" => cmd(action, %{"id" => @ids.fs}, %{"tools" => %{"fs_01" => true}}),
      "mcp.reconnect" => cmd(action, %{"id" => @ids.fs}),
      "mcp.test" => cmd(action, %{"id" => @ids.fs}),
      "mcp.delete" => cmd(action, %{"id" => @ids.docs}),
      "mcp.import.read" => cmd(action, %{}, %{"path" => nil}),
      "mcp.import.apply" => cmd(action, %{}, %{"import_id" => "gone", "names" => []}),
      "storage.measure" => cmd(action),
      "storage.plan" => cmd(action, %{}, %{"selection" => %{"older_than_days" => 30}}),
      "storage.run" => cmd(action, %{}, %{"plan_id" => "gone"}),
      "storage.vacuum" => cmd(action),
      "storage.apply_retention" => cmd(action),
      "lsp.check" => cmd(action),
      "lsp.stop" => cmd(action, %{"all" => true}),
      "lsp.remove_key" => cmd(action, %{"key" => "kotlin"}),
      "file.save" =>
        cmd(action, %{"ref" => "memory_project:project:#{@ids.ailogic}:MEMORY"}, %{
          "content" => "- one\n"
        }),
      "file.create" => cmd(action, %{"kind" => "command", "scope" => "global", "name" => "ship"}),
      "file.delete" => cmd(action, %{"ref" => "command:global:-:review"}),
      "file.clear" => cmd(action, %{"ref" => "memory_project:project:#{@ids.ailogic}:MEMORY"}),
      "workflow.smoke" => cmd(action, %{"ref" => "workflow:user:-:nightly"}),
      "project_config.put_hook" =>
        cmd(action, %{"project_id" => @ids.ailogic, "event" => "pre_tool_use", "index" => nil}, %{
          "command" => "true",
          "confirmed" => true
        }),
      "project_config.delete_hook" =>
        cmd(action, %{"project_id" => @ids.ailogic, "event" => "post_tool_use", "index" => 0}),
      "project_config.move_hook" =>
        cmd(action, %{"project_id" => @ids.ailogic, "event" => "post_tool_use", "index" => 0}, %{
          "dir" => 1
        }),
      "project_config.put_profile" =>
        cmd(action, %{"project_id" => @ids.ailogic, "name" => nil}, %{
          "name" => "slow",
          "effort" => "high"
        }),
      "project_config.delete_profile" =>
        cmd(action, %{"project_id" => @ids.ailogic, "name" => "fast"}),
      "project_config.remove_key" =>
        cmd(action, %{"project_id" => @ids.ailogic, "key" => "effort"}),
      "project_config.remove_entry" =>
        cmd(action, %{"project_id" => @ids.ailogic, "path" => "hooks.post_edit"})
    }
    |> Map.fetch!(action)
  end

  test "every S2 action of the closed list answers, and nothing else is simulated here" do
    assert length(I.actions()) == 49
    state = I.seed()

    for action <- I.actions() do
      case I.command(state, sample(action)) do
        {{:ok, %{"status" => status}}, _} ->
          assert status in ~w(accepted unchanged conflict rejected needs_confirmation not_found busy),
                 action

        {{:task, task, %{"status" => "accepted"}}, next} ->
          assert task["action"] == action

          assert {{kind, _, _}, _} =
                   I.run_task(next, Map.put(task, "task_id", "t1"))
                   |> then(fn
                     {{:done, s, r}, st} -> {{:done, s, r}, st}
                     {{:failed, m}, st} -> {{:failed, m, nil}, st}
                   end)

          assert kind in [:done, :failed]
      end
    end

    assert I.command(state, cmd("values.patch")) == :unsupported
    assert I.command(state, cmd("export")) == :unsupported
  end

  test "records hold secrets only as set and a 4-character hint" do
    state = I.seed()

    [deepseek | _] =
      for p <- items(state, "providers"), p["fields"]["name"] == "DeepSeek", do: p["fields"]

    assert deepseek["api_key"] == %{"set" => true, "hint" => "a1b2"}
    github = record!(state, "mcp_server", @ids.github)
    token = Enum.find(github["env"], &(&1["name"] == "GITHUB_PERSONAL_ACCESS_TOKEN"))

    assert token == %{
             "name" => "GITHUB_PERSONAL_ACCESS_TOKEN",
             "secret" => true,
             "value" => nil,
             "hint" => "i9j0"
           }

    assert Enum.find(github["env"], &(&1["name"] == "GITHUB_TOOLSETS"))["value"] == "repos,issues"
  end

  test "a pasted key is never kept: only its hint, and never in any answer" do
    state = I.seed()

    command =
      cmd("provider.set_key", %{"id" => @ids.openrouter}, %{"test_first" => false},
        secrets: [%{"slot" => "api_key", "value" => @canary}]
      )

    {result, state} = ok(state, command)
    assert result["status"] == "accepted"
    assert result["record"]["fields"]["api_key"] == %{"set" => true, "hint" => "zz99"}
    assert result["message"] == "OpenRouter API key saved · ends zz99"
    refute inspect(state) =~ @canary
    refute inspect(result) =~ @canary
  end

  test "paste checks answer the service's words" do
    state = I.seed()

    for {value, words} <- [
          {"one\ntwo", "paste only the key: it had 2 lines"},
          {"a b c d e f g h", "a key has no spaces inside"},
          {"short", "that is too short to be a key"}
        ] do
      {result, _} =
        ok(
          state,
          cmd("provider.set_key", %{"id" => @ids.deepseek}, %{"test_first" => false},
            secrets: [%{"slot" => "api_key", "value" => value}]
          )
        )

      assert result["status"] == "rejected"
      assert result["message"] == words
    end
  end

  test "replacing a key tests first; a held test released with a refusal keeps the old key" do
    state = I.seed()

    command =
      cmd("provider.set_key", %{"id" => @ids.deepseek}, %{"test_first" => true},
        secrets: [%{"slot" => "api_key", "value" => @canary}],
        expected: %{"key" => %{"set" => true, "hint" => "a1b2"}}
      )

    {task, state} = started(state, command)
    refute inspect(task) =~ @canary

    assert {{:failed, "The new key was refused (401)."}, state} =
             I.run_task(state, task, {:error, "401"})

    assert record!(state, "provider", @ids.deepseek)["api_key"] == %{
             "set" => true,
             "hint" => "a1b2"
           }

    {task, state} = started(state, command)
    assert {{:done, %{"saved" => true, "count" => 2}, []}, state} = I.run_task(state, task)

    assert record!(state, "provider", @ids.deepseek)["api_key"] == %{
             "set" => true,
             "hint" => "zz99"
           }
  end

  test "a key replacement whose expectation is stale is a conflict" do
    state = I.seed()

    command =
      cmd("provider.set_key", %{"id" => @ids.deepseek}, %{"test_first" => true},
        secrets: [%{"slot" => "api_key", "value" => @canary}],
        expected: %{"key" => %{"set" => false, "hint" => nil}}
      )

    {result, _} = ok(state, command)
    assert result["status"] == "conflict"
  end

  test "create validates with the desktop's words and carries the preset levels" do
    state = I.seed()

    {result, _} =
      ok(
        state,
        cmd("provider.create", %{}, %{
          "name" => "DeepSeek",
          "kind" => "openai_compatible",
          "base_url" => "https://x.test/v1"
        })
      )

    assert result["status"] == "rejected"

    assert result["field_errors"] == [
             %{"target" => "name", "message" => "has already been taken"}
           ]

    {result, _} =
      ok(state, cmd("provider.create", %{}, %{"name" => "X", "base_url" => "ftp://x"}))

    assert %{"target" => "base_url", "message" => "must start with http:// or https://"} in result[
             "field_errors"
           ]

    levels = Enum.find(I.presets(), &(&1["id"] == "deepseek"))["levels"]

    {result, state} =
      ok(
        state,
        cmd(
          "provider.create",
          %{},
          %{
            "name" => "DS2",
            "base_url" => "https://api.deepseek.com/v1/",
            "effort_levels" => levels
          },
          secrets: [%{"slot" => "api_key", "value" => @canary}]
        )
      )

    assert result["status"] == "accepted"
    fields = result["record"]["fields"]
    assert fields["base_url"] == "https://api.deepseek.com/v1"
    assert fields["effort_levels"] == levels
    assert fields["api_key"]["hint"] == "zz99"
    refute inspect(state) =~ @canary
  end

  test "fetch shows the Appendix A difference and writes nothing until applied" do
    state = I.seed()
    {task, state} = started(state, cmd("provider.fetch_models", %{"id" => @ids.deepseek}))
    {{:done, summary, rows}, state} = I.run_task(state, task)
    assert summary["added"] == 1 and summary["removed"] == 1 and summary["unchanged"] == 1

    assert rows == [
             %{"model" => "deepseek-v4-lite", "change" => "new", "conversations" => 0},
             %{"model" => "deepseek-v4-flash", "change" => "gone", "conversations" => 3},
             %{"model" => "deepseek-v4-pro", "change" => "same", "conversations" => 0}
           ]

    assert record!(state, "provider", @ids.deepseek)["models"] == [
             "deepseek-v4-pro",
             "deepseek-v4-flash"
           ]

    assert record!(state, "provider", @ids.deepseek)["last_fetch"]["state"] == "done"

    {result, state} =
      ok(
        state,
        cmd("provider.apply_models", %{"id" => @ids.deepseek}, %{
          "fetch_task_id" => task["task_id"],
          "mode" => "add"
        })
      )

    assert result["record"]["fields"]["models"] == [
             "deepseek-v4-pro",
             "deepseek-v4-flash",
             "deepseek-v4-lite"
           ]

    {result, _} =
      ok(
        state,
        cmd("provider.apply_models", %{"id" => @ids.deepseek}, %{
          "fetch_task_id" => task["task_id"],
          "mode" => "replace"
        })
      )

    assert result["record"]["fields"]["models"] == ["deepseek-v4-pro", "deepseek-v4-lite"]
  end

  test "a fetch over 2 000 models is truncated: replace refused, add fills to 2 000" do
    state = I.seed()
    {task, state} = started(state, cmd("provider.fetch_models", %{"id" => @ids.ollama}))
    listed = for i <- 1..2_500, do: "m#{i}"
    task = put_in(task["attributes"], %{"listed" => listed})
    {{:done, summary, _rows}, state} = I.run_task(state, task)
    assert summary["truncated"] and summary["listed"] == 2_500

    {result, _} =
      ok(
        state,
        cmd("provider.apply_models", %{"id" => @ids.ollama}, %{
          "fetch_task_id" => task["task_id"],
          "mode" => "replace"
        })
      )

    assert result["message"] == "the list was longer than 2 000; add new ones instead"

    {result, _} =
      ok(
        state,
        cmd("provider.apply_models", %{"id" => @ids.ollama}, %{
          "fetch_task_id" => task["task_id"],
          "mode" => "add"
        })
      )

    assert length(result["record"]["fields"]["models"]) == 2_000
    assert result["message"] == "1 not added: 2 000 models at most"
  end

  test "delete asks for a replacement of every default the provider serves" do
    state = I.seed()
    {result, _} = ok(state, cmd("provider.delete", %{"id" => @ids.deepseek}))
    assert result["status"] == "rejected"
    assert Enum.map(result["field_errors"], & &1["target"]) == ["models.chat", "models.sub_agent"]

    pair = %{"provider_id" => @ids.anthropic, "model" => "claude-opus-5"}

    {result, state} =
      ok(
        state,
        cmd("provider.delete", %{"id" => @ids.deepseek}, %{
          "replacements" => %{"models.chat" => pair, "models.sub_agent" => pair}
        })
      )

    assert result["status"] == "accepted" and result["message"] == "DeepSeek deleted"

    assert I.query(state, %{"view" => "record", "kind" => "provider", "id" => @ids.deepseek}) ==
             {:error, "not_found", "that provider no longer exists"}
  end

  test "efforts.save maps row errors to rows[i]" do
    state = I.seed()

    rows = [
      %{"key" => "low", "body" => %{}},
      %{"key" => "low", "body" => %{}},
      %{"key" => "Bad Key", "body" => %{}},
      %{"key" => "x", "body" => "nope"}
    ]

    {result, _} =
      ok(state, cmd("efforts.save", %{"id" => @ids.ollama, "model" => nil}, %{"rows" => rows}))

    assert result["field_errors"] == [
             %{"target" => "rows[1]", "message" => "key: already used"},
             %{
               "target" => "rows[2]",
               "message" => "key: lowercase letters, digits, - or _ (24 max)"
             },
             %{"target" => "rows[3]", "message" => "body: must be a JSON object"}
           ]
  end

  test "pricing needs both prices and knows the unpriced models" do
    state = I.seed()

    assert Enum.map(items(state, "unpriced_models"), & &1["id"]) == [
             "claude-sonnet-5",
             "qwen3-coder"
           ]

    {result, _} =
      ok(state, cmd("pricing.put_row", %{}, %{"model" => "qwen3-coder", "input" => 0.1}))

    assert result["field_errors"] == [
             %{"target" => "output", "message" => "output: must be a number ≥ 0"}
           ]

    {result, state} =
      ok(
        state,
        cmd("pricing.put_row", %{}, %{"model" => "qwen3-coder", "input" => 0.1, "output" => 0.2},
          expected: %{"row" => nil}
        )
      )

    assert result["status"] == "accepted"
    assert Enum.map(items(state, "unpriced_models"), & &1["id"]) == ["claude-sonnet-5"]
    [row | _] = items(state, "pricing_rows")
    assert row["fields"]["derived_cache_write"] == 18.75
  end

  test "search: order, enable without a key, clear key turns it off, test words" do
    state = I.seed()

    assert Enum.map(items(state, "search_providers"), & &1["id"]) ==
             ~w(tavily exa brave serper jina firecrawl)

    {result, state} =
      ok(
        state,
        cmd("search.move", %{"kind" => "exa"}, %{"dir" => -1},
          expected: %{"order" => ~w(tavily exa brave serper jina firecrawl)}
        )
      )

    assert result["message"] == "Moved Exa above Tavily"

    assert Enum.map(items(state, "search_providers"), & &1["id"]) ==
             ~w(exa tavily brave serper jina firecrawl)

    {result, _} = ok(state, cmd("search.update", %{"kind" => "brave"}, %{"enabled" => true}))
    assert result["message"] == "is needed to enable brave"

    {result, state} = ok(state, cmd("search.clear_key", %{"kind" => "tavily"}))
    assert result["message"] == "Tavily API key removed · turned off"
    refute record!(state, "search_provider", "tavily")["enabled"]

    {task, state} = started(state, cmd("search.test", %{"kind" => "exa"}))
    assert {{:done, %{"count" => 3, "ms" => 612}, []}, state} = I.run_task(state, task)
    assert record!(state, "search_provider", "exa")["last_test"]["state"] == "done"
  end

  test "mcp: update keeps the scope unless named; set_tools is one write; reconnect of github fails" do
    state = I.seed()
    {result, state} = ok(state, cmd("mcp.update", %{"id" => @ids.fs}, %{"args" => ["/tmp"]}))
    assert result["record"]["fields"]["project_id"] == @ids.ailogic

    {result, state} =
      ok(
        state,
        cmd("mcp.set_tools", %{"id" => @ids.fs}, %{
          "tools" => %{"fs_01" => true, "read_file" => false}
        })
      )

    assert result["record"]["fields"]["disabled_tools"] == ["fs_02", "read_file"]

    {task, state} = started(state, cmd("mcp.reconnect", %{"id" => @ids.github}))
    assert {{:failed, "command not found: github-mcp-server"}, _} = I.run_task(state, task)

    {_, state} = ok(state, cmd("mcp.toggle", %{"id" => @ids.docs}, %{"enabled" => false}))
    {result, _} = ok(state, cmd("mcp.reconnect", %{"id" => @ids.docs}))
    assert result["message"] == "turn it on first"
  end

  test "mcp env values that look secret are masked, including the broader rules" do
    state = I.seed()

    env = [
      %{"name" => "GH_PAT", "value" => "abc"},
      %{"name" => "STRIPE", "value" => "sk_live_000000000000"},
      %{"name" => "DATABASE_URL", "value" => "postgres://u:pw@h/db"},
      %{"name" => "PLAIN", "value" => "hello"}
    ]

    {result, _} =
      ok(state, cmd("mcp.create", %{}, %{"name" => "x", "command" => "x", "env" => env}))

    masked = Map.new(result["record"]["fields"]["env"], &{&1["name"], &1})

    for n <- ~w(GH_PAT STRIPE DATABASE_URL),
        do: assert(masked[n]["secret"] and masked[n]["value"] == nil)

    assert masked["PLAIN"]["value"] == "hello"
  end

  test "mcp import: variables with in_shell, masked secrets, SSE unsupported, apply per name" do
    state = I.seed(env: %{"GITHUB_TOKEN" => "x"})
    {task, state} = started(state, cmd("mcp.import.read"))
    {{:done, summary, rows}, state} = I.run_task(state, task)
    assert summary["count"] == 3
    [github, docs, events] = rows

    assert github["conflict"] and
             github["variables"] == [
               %{
                 "map" => "env",
                 "name" => "GITHUB_TOKEN",
                 "ref" => "GITHUB_TOKEN",
                 "in_shell" => true
               }
             ]

    assert [%{"name" => "Authorization", "secret" => true, "value" => nil}] = docs["headers"]
    assert events["unsupported"]

    apply =
      cmd(
        "mcp.import.apply",
        %{},
        %{
          "import_id" => task["task_id"],
          "names" => ["github", "docs", "events"],
          "rename" => %{"github" => "github-2", "docs" => "docs-2"},
          "values" => %{"github" => %{"env.GITHUB_TOKEN" => "paste"}}
        },
        secrets: [
          %{"slot" => "import:github:env:GITHUB_TOKEN", "value" => "ghp_pasted_0000000000000000"}
        ]
      )

    {result, state} = ok(state, apply)

    assert Enum.map(result["results"], &{&1["target"], &1["status"]}) == [
             {"github", "accepted"},
             {"docs", "accepted"},
             {"events", "rejected"}
           ]

    assert List.last(result["results"])["message"] ==
             "SSE servers are not supported; use the server's streamable http URL"

    names = state |> items("mcp_servers") |> Enum.map(& &1["fields"]["name"])
    assert "github-2" in names
    refute inspect(state) =~ "ghp_pasted"

    no_shell = I.seed(env: %{})
    {task, no_shell} = started(no_shell, cmd("mcp.import.read"))
    {{:done, _, _}, no_shell} = I.run_task(no_shell, task)

    {result, _} =
      ok(
        no_shell,
        cmd("mcp.import.apply", %{}, %{
          "import_id" => task["task_id"],
          "names" => ["github"],
          "rename" => %{"github" => "gh"},
          "values" => %{"github" => %{"env.GITHUB_TOKEN" => "shell"}}
        })
      )

    assert hd(result["results"])["message"] == "GITHUB_TOKEN is not set in this shell"
  end

  test "storage: measure, sessions paged, plan keeps back, run and busy" do
    state = I.seed()

    assert I.query(state, %{"view" => "records", "kind" => "storage_sessions"}) ==
             {:error, "not_found", "measure first"}

    {task, state} = started(state, cmd("storage.measure"))
    {{:done, summary, _}, state} = I.run_task(state, task)
    assert length(summary["presets"]) == 5

    {:ok, page} =
      I.query(state, %{"view" => "records", "kind" => "storage_sessions", "page_size" => 200})

    assert page["total"] == 214 and length(page["items"]) == 200 and page["next_cursor"] == "200"
    assert hd(page["items"])["fields"]["title"] == "Refactor the parser (old)"
    refute Map.has_key?(hd(page["items"])["fields"], "age_days")

    {task, state} =
      started(state, cmd("storage.plan", %{}, %{"selection" => %{"older_than_days" => 30}}))

    {{:done, plan, _}, state} = I.run_task(state, Map.put(task, "task_id", "plan-1"))

    assert %{"reason" => "pinned — pick it in Sessions to include it", "count" => 1} in plan[
             "skipped"
           ]

    {{:task, run, _}, state} = I.command(state, cmd("storage.run", %{}, %{"plan_id" => "plan-1"}))
    {result, _} = ok(state, cmd("storage.vacuum"))
    assert result["status"] == "busy" and result["message"] == "A cleanup is already running."
    {{:done, done, _}, _} = I.run_task(state, Map.put(run, "task_id", "run-1"))
    assert done["freed_bytes"] > 0
    refute I.cancellable?("storage.run")
  end

  test "retention needs a policy" do
    {result, _} = ok(I.seed(), cmd("storage.apply_retention"))
    assert result["message"] == "set a retention first"
  end

  test "lsp: check rows and unknown keys" do
    state = I.seed()
    {task, state} = started(state, cmd("lsp.check"))
    {{:done, summary, rows}, state} = I.run_task(state, task)
    assert summary["unknown_keys"] == [%{"key" => "kotlin", "value" => "kotlin-language-server"}]
    elixir = Enum.find(rows, &(&1["language"] == "elixir"))
    assert elixir["installed"] == true
    assert Enum.find(rows, &(&1["language"] == "erlang"))["effective"] == "erlang_ls"
    {result, _} = ok(state, cmd("lsp.remove_key", %{"key" => "elixir"}))
    assert result["status"] == "rejected"
  end

  test "files: fingerprint CAS carries no content, instructions winner, bundled refused, hooks confirm" do
    state = I.seed()
    ref = "memory_project:project:#{@ids.ailogic}:MEMORY"
    {:ok, %{"file" => file}} = I.query(state, %{"view" => "file", "id" => ref})
    assert file["lines"] == 42 and file["editable_in_place"]

    {result, _} =
      ok(
        state,
        cmd("file.save", %{"ref" => ref}, %{"content" => "x"},
          expected: %{"fingerprint" => %{"missing" => true}}
        )
      )

    assert result["status"] == "conflict"
    refute inspect(result) =~ "- fact"

    {result, _} =
      ok(
        state,
        cmd("file.save", %{"ref" => ref}, %{"content" => "- one\n"},
          expected: %{"fingerprint" => file["fingerprint"]}
        )
      )

    assert result["message"] == "Saved MEMORY.md (1 lines)"

    [_, _, notes] = items(state, "memory_files", %{"project_id" => @ids.notes})
    assert notes["fields"]["winner"] == "CLAUDE.md" and notes["fields"]["trusted"] == false

    {result, _} = ok(state, cmd("file.delete", %{"ref" => "agent:bundled:-:reviewer"}))

    assert result["message"] ==
             "a built-in file cannot be deleted; make a user copy to override it"

    cfg = "project_config:project:#{@ids.ailogic}:config"

    json =
      ~s({"hooks": {"post_tool_use": [{"command": "mix format"}, {"command": "rm -rf tmp"}]}})

    {result, _} = ok(state, cmd("file.save", %{"ref" => cfg}, %{"content" => json}))
    assert result["status"] == "needs_confirmation"
    assert result["confirm"] == %{"kind" => "hooks", "items" => ["post_tool_use: rm -rf tmp"]}

    {result, _} =
      ok(
        state,
        cmd("file.save", %{"ref" => cfg}, %{"content" => json, "confirmed_hooks" => true})
      )

    assert result["status"] == "accepted"
  end

  test "library lists and creates from a template" do
    state = I.seed()
    assert Enum.map(items(state, "commands"), & &1["fields"]["name"]) == ["deploy", "review"]

    assert Enum.map(
             items(state, "commands", %{"project_id" => @ids.notes}),
             & &1["fields"]["name"]
           ) == ["review"]

    {result, state} =
      ok(
        state,
        cmd("file.create", %{"kind" => "command", "scope" => "global", "name" => "settings"})
      )

    assert result["status"] == "accepted"

    assert Enum.find(items(state, "commands"), &(&1["fields"]["name"] == "settings"))["fields"][
             "shadowed_by_builtin"
           ]

    {result, _} =
      ok(
        state,
        cmd("file.create", %{"kind" => "command", "scope" => "global", "name" => "Bad Name"})
      )

    assert result["message"] == "lowercase letters, digits, ., _ or - (64 max)"

    {task, state} = started(state, cmd("workflow.smoke", nil))
    {{:done, summary, rows}, _} = I.run_task(state, task)
    assert summary == %{"checked" => 2, "failed" => 1}
    assert Enum.find(rows, &(&1["name"] == "broken"))["smoke"] == "calls System.os_time/0"
  end

  test "project config reports the Appendix A ignored entries" do
    fields = record!(I.seed(), "project_config", @ids.ailogic)
    assert fields["top_level"] == %{"effort" => "high"}

    assert Enum.map(fields["ignored_entries"], & &1["path"]) == [
             "hooks.post_edit",
             "profiles.fast.mode"
           ]

    assert fields["unknown_keys"] == ["x-custom"]
  end
end
