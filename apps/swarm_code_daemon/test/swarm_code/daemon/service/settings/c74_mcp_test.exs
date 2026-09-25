defmodule SwarmCode.Daemon.Service.Settings.C74MCPTest do
  @moduledoc "pass 74 S2-7: MCP servers in settings (§3.5.4, AT1)."
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias SwarmCode.Daemon.Service.Settings.{MCP, Secrets}
  alias SwarmCode.Domain.MCP, as: Domain
  alias SwarmCode.Domain.MCP.Server
  alias SwarmCode.Domain.Repo
  alias SwarmCode.Test.C74S2
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  @canary "sk-canary-7Q2X-DO-NOT-SHOW"
  @secret_values [
    "ghp_test_0000000000000000i9j0",
    "Bearer test-token-0000000000k1l2",
    "test-token-0000000000k1l2"
  ]

  setup do
    fx = C74S2.repo!("c74-mcp")
    data = C74S2.appendix_a!(fx)

    on_exit(fn ->
      for server <- [data.github, data.fs, data.docs], do: Domain.stop_client(server.id)
    end)

    Map.merge(data, %{ctx: C74S2.context(data.ailogic, data.conversation)})
  end

  defp run(c, action, opts), do: MCP.command(C74S2.command(action, opts), c.ctx)
  defp fields({:ok, result}), do: result.record["fields"]

  defp record(id) do
    {:ok, record} = MCP.query("record", "mcp_server", %{"id" => id}, %{})
    record
  end

  defp no_secret!(term) do
    text = inspect(term, limit: :infinity, printable_limit: :infinity)
    for value <- [@canary | @secret_values], do: refute(text =~ value, "leaked #{value}")
    term
  end

  defp mcp_http(tools) do
    server =
      HTTP.start(fn socket, request, _n ->
        json = [{"content-type", "application/json"}]

        case Jason.decode(request.body) do
          {:ok, %{"method" => "initialize", "id" => id}} ->
            HTTP.respond(
              socket,
              200,
              Jason.encode!(%{
                "jsonrpc" => "2.0",
                "id" => id,
                "result" => %{
                  "protocolVersion" => "2025-06-18",
                  "capabilities" => %{"tools" => %{}},
                  "serverInfo" => %{"name" => "fixture", "version" => "1"}
                }
              }),
              json
            )

          {:ok, %{"method" => "tools/list", "id" => id}} ->
            HTTP.respond(
              socket,
              200,
              Jason.encode!(%{
                "jsonrpc" => "2.0",
                "id" => id,
                "result" => %{
                  "tools" =>
                    Enum.map(tools, &%{"name" => &1, "inputSchema" => %{"type" => "object"}})
                }
              }),
              json
            )

          _notification ->
            HTTP.respond(socket, 202, "")
        end
      end)

    on_exit(fn -> HTTP.stop(server) end)
    server
  end

  describe "records" do
    test "global servers first, then the page project's; status and tool counts", c do
      {:ok, page} = MCP.query("records", "mcp_servers", %{}, c.ctx)
      C74S2.declared!(page)
      no_secret!(page)
      rows = Map.new(page["items"], &{&1["fields"]["name"], &1["fields"]})

      assert Enum.map(page["items"], & &1["fields"]["name"]) == ["docs", "github", "fs"]
      assert rows["github"]["status"] == "error"
      assert rows["github"]["status_message"] == "command not found: github-mcp-server"
      assert rows["fs"]["scope"] == "project" and rows["fs"]["status"] == "ready"
      assert {rows["fs"]["tools_total"], rows["fs"]["tools_enabled"]} == {12, 10}
      assert {rows["docs"]["tools_total"], rows["docs"]["tools_enabled"]} == {29, 28}
      assert rows["docs"]["slug"] == "docs"

      notes = C74S2.context(c.notes)
      {:ok, other} = MCP.query("records", "mcp_servers", %{}, notes)
      assert Enum.map(other["items"], & &1["fields"]["name"]) == ["docs", "github"]
    end

    test "a record masks secret env and header values and lists the tools", c do
      github = record(c.github.id)
      docs = record(c.docs.id)
      C74S2.declared!(github)
      C74S2.declared!(docs)
      no_secret!([github, docs])

      assert github["fields"]["env"] == [
               %{
                 "name" => "GITHUB_PERSONAL_ACCESS_TOKEN",
                 "secret" => true,
                 "value" => nil,
                 "hint" => "i9j0"
               },
               %{
                 "name" => "GITHUB_TOOLSETS",
                 "secret" => false,
                 "value" => "repos,issues",
                 "hint" => nil
               }
             ]

      assert [%{"name" => "Authorization", "secret" => true, "hint" => "k1l2"}] =
               docs["fields"]["headers"]

      tools = docs["fields"]["tools"]
      assert length(tools) == 29

      assert %{"name" => "docs_01", "enabled" => false} =
               Enum.find(tools, &(&1["name"] == "docs_01"))

      assert Enum.find(tools, &(&1["name"] == "docs_02"))["published_name"] ==
               "mcp__docs__docs_02"
    end

    test "40 names and values: every desktop secret and every known shape is masked" do
      samples = [
        {"Authorization", "Bearer abcdefgh"},
        {"Proxy-Authorization", "Basic dXNlcjpwYXNz"},
        {"Cookie", "session=1"},
        {"X-API-Key", "value"},
        {"X-Api-Token", "v1"},
        {"apikey", "v"},
        {"API_KEY", "k"},
        {"MY_TOKEN", "t"},
        {"ACCESS_TOKEN", "t2"},
        {"client_secret", "s"},
        {"PASSWORD", "p"},
        {"DB_PASSWD", "hunter22"},
        {"PGPASSWORD", "pw"},
        {"CREDENTIALS", "c"},
        {"GOOGLE_APPLICATION_CREDENTIALS", "/tmp/creds.json"},
        {"GH_PAT", "abcdefghijklmnop"},
        {"GITLAB_PAT", "glpat-0000000000"},
        {"OPENAI_KEY", "not-a-sk-value-0000"},
        {"STRIPE_KEY", "sk_live_0000000000000000"},
        {"PLAIN", "sk-abcd1234"},
        {"H", "Bearer tokentoken"},
        {"SLACK", "xoxb-000000000000"},
        {"SLACK_USER", "xoxp-1-000000"},
        {"AWS", "AKIA0000000000000000"},
        {"GITHUB", "ghp_000000000000000000"},
        {"GITHUB_FINE", "github_pat_0000000000"},
        {"ANTHROPIC", "sk-ant-000000000000"},
        {"DATABASE_URL", "postgres://u:pw@h/db"},
        {"REDIS_URL", "redis://default:secret@h:6379"},
        {"MONGO", "mongodb+srv://user:pass@cluster/db"},
        {"content-type", "application/json"},
        {"Accept", "text/event-stream"},
        {"LOG_LEVEL", "debug"},
        {"GITHUB_TOOLSETS", "repos,issues"},
        {"NODE_ENV", "production"},
        {"PORT", "8080"},
        {"HOME_URL", "https://example.test/a"},
        {"PATH_PREFIX", "/v1"},
        {"LANG", "en_US.UTF-8"},
        {"MODE", "fast"}
      ]

      assert length(samples) == 40
      server = %Server{env: Map.new(samples), headers: %{}}
      desktop = MapSet.new(Server.secrets(server))

      entries = Secrets.masked_entries(Map.new(samples))
      masked = for %{"secret" => true, "name" => n} <- entries, into: MapSet.new(), do: n
      masked_values = for {n, v} <- samples, n in masked, into: MapSet.new(), do: v
      assert MapSet.subset?(desktop, masked_values)

      for name <-
            ~w(GH_PAT OPENAI_KEY STRIPE_KEY DB_PASSWD DATABASE_URL SLACK AWS GITHUB GITHUB_FINE MONGO REDIS_URL) do
        assert name in masked, "#{name} is shown"
      end

      shown = for %{"secret" => false, "name" => n} <- entries, do: n

      assert Enum.sort(shown) ==
               Enum.sort(
                 ~w(content-type Accept LOG_LEVEL GITHUB_TOOLSETS NODE_ENV PORT HOME_URL PATH_PREFIX LANG MODE)
               )
    end
  end

  describe "create and update" do
    test "create builds the maps from values and slots; secrets never come back", c do
      result =
        run(c, "mcp.create",
          attributes: %{
            "name" => "search",
            "transport" => "http",
            "url" => "http://127.0.0.1:9/mcp",
            "enabled" => false,
            "headers" => [%{"name" => "Authorization"}, %{"name" => "X-Team", "value" => "core"}],
            "env" => []
          },
          secrets: [%{slot: "header:Authorization", value: "Bearer " <> @canary}]
        )

      assert {:ok, %{status: :accepted, message: "search added"}} = result
      no_secret!(result)
      server = Repo.get_by!(Server, name: "search")
      assert server.headers == %{"Authorization" => "Bearer " <> @canary, "X-Team" => "core"}
      assert server.project_id == nil

      assert [
               %{"name" => "Authorization", "secret" => true},
               %{"name" => "X-Team", "value" => "core"}
             ] =
               fields(result)["headers"]
    end

    test "names are checked with the cli words", c do
      assert {:error,
              %{
                field_errors: [
                  %{target: "env[0]", message: "use a variable name: A–Z, 0–9 and _"}
                ]
              }} =
               run(c, "mcp.create",
                 attributes: %{
                   "name" => "x",
                   "transport" => "stdio",
                   "command" => "x",
                   "env" => [%{"name" => "BAD NAME", "value" => "1"}]
                 }
               )

      assert {:error, %{field_errors: [%{target: "headers[1]", message: "already in the list"}]}} =
               run(c, "mcp.create",
                 attributes: %{
                   "name" => "x",
                   "transport" => "http",
                   "url" => "https://x.test",
                   "headers" => [
                     %{"name" => "A", "value" => "1"},
                     %{"name" => "A", "value" => "2"}
                   ]
                 }
               )

      assert {:error, %{field_errors: [%{target: "headers[0]", message: "not a header name"}]}} =
               run(c, "mcp.create",
                 attributes: %{
                   "name" => "x",
                   "transport" => "http",
                   "url" => "https://x.test",
                   "headers" => [%{"name" => "X Team", "value" => "1"}]
                 }
               )

      assert {:error, %{field_errors: [%{target: "name"} | _]}} =
               run(c, "mcp.create",
                 attributes: %{
                   "name" => String.duplicate("n", 65),
                   "transport" => "stdio",
                   "command" => "x"
                 }
               )

      assert {:error,
              %{
                message:
                  "Couldn't save: name shares the tool prefix mcp__github__ with \"github\""
              }} =
               run(c, "mcp.create",
                 attributes: %{"name" => "github", "transport" => "stdio", "command" => "x"}
               )

      assert {:error, %{field_errors: [%{target: "project_id", message: "no such project"}]}} =
               run(c, "mcp.create",
                 attributes: %{
                   "name" => "y",
                   "transport" => "stdio",
                   "command" => "y",
                   "project_id" => Ecto.UUID.generate()
                 }
               )
    end

    test "update keeps stored secrets, deletes missing names, never moves the scope unless asked",
         c do
      fs = record(c.fs.id)["fields"]

      result =
        run(c, "mcp.update",
          target: %{"id" => c.github.id},
          attributes: %{
            "args" => ["stdio", "--read-only"],
            "env" => [%{"name" => "GITHUB_PERSONAL_ACCESS_TOKEN", "keep" => true}]
          },
          expected: %{"fields" => %{"args" => ["stdio"]}}
        )

      assert {:ok, %{status: :accepted}} = result
      no_secret!(result)
      github = Domain.get(c.github.id)
      assert github.env == %{"GITHUB_PERSONAL_ACCESS_TOKEN" => "ghp_test_0000000000000000i9j0"}
      assert github.args == ["stdio", "--read-only"]
      assert github.project_id == nil

      # the project server keeps its project when the attributes do not name one
      {:ok, _} =
        run(c, "mcp.update",
          target: %{"id" => c.fs.id},
          attributes: %{"command" => "mcp-fs2"},
          expected: %{"fields" => %{"command" => fs["command"]}}
        )

      assert Domain.get(c.fs.id).project_id == c.ailogic.id

      {:ok, moved} =
        run(c, "mcp.update",
          target: %{"id" => c.fs.id},
          attributes: %{"project_id" => nil},
          expected: %{"fields" => %{"project_id" => c.ailogic.id}}
        )

      assert moved.status == :accepted and Domain.get(c.fs.id).project_id == nil
    end

    test "a stale expectation is a conflict with the current fields", c do
      {:ok, result} =
        run(c, "mcp.update",
          target: %{"id" => c.github.id},
          attributes: %{"command" => "gh-mcp"},
          expected: %{"fields" => %{"command" => "something-else"}}
        )

      assert result.status == :conflict
      assert [%{target: "command", current: "github-mcp-server"}] = result.results
      assert Domain.get(c.github.id).command == "github-mcp-server"

      {:ok, same} =
        run(c, "mcp.update",
          target: %{"id" => c.github.id},
          attributes: %{"command" => "github-mcp-server"},
          expected: %{"fields" => %{"command" => "github-mcp-server"}}
        )

      assert same.status == :unchanged
    end

    test "set_secret puts one entry with CAS on its mask", c do
      mask = %{"set" => true, "hint" => "i9j0"}

      result =
        run(c, "mcp.set_secret",
          target: %{"id" => c.github.id, "map" => "env", "name" => "GITHUB_PERSONAL_ACCESS_TOKEN"},
          expected: %{"key" => mask},
          secrets: [%{slot: "env:GITHUB_PERSONAL_ACCESS_TOKEN", value: @canary}]
        )

      assert {:ok, %{status: :accepted}} = result
      no_secret!(result)
      assert Domain.get(c.github.id).env["GITHUB_PERSONAL_ACCESS_TOKEN"] == @canary

      {:ok, stale} =
        run(c, "mcp.set_secret",
          target: %{"id" => c.github.id, "map" => "env", "name" => "GITHUB_PERSONAL_ACCESS_TOKEN"},
          expected: %{"key" => mask},
          secrets: [%{slot: "value", value: "ghp_other_00000000000000"}]
        )

      assert stale.status == :conflict
      assert Domain.get(c.github.id).env["GITHUB_PERSONAL_ACCESS_TOKEN"] == @canary
    end

    test "toggle writes enabled with CAS", c do
      {:ok, off} =
        run(c, "mcp.toggle",
          target: %{"id" => c.docs.id},
          attributes: %{"enabled" => false},
          expected: %{"fields" => %{"enabled" => true}}
        )

      assert off.status == :accepted and off.message == "docs off"
      refute Domain.get(c.docs.id).enabled

      {:ok, stale} =
        run(c, "mcp.toggle",
          target: %{"id" => c.docs.id},
          attributes: %{"enabled" => true},
          expected: %{"fields" => %{"enabled" => true}}
        )

      assert stale.status == :conflict
    end
  end

  describe "set_tools" do
    test "300 tools are one row update, and the tool table follows", c do
      Domain.put_tools(Domain.get(c.docs.id), C74S2.tools("docs", 300))

      tools =
        for i <- 1..300,
            into: %{},
            do: {"docs_" <> String.pad_leading("#{i}", 2, "0"), rem(i, 2) == 0}

      handler = self()
      ref = make_ref()

      :telemetry.attach(
        "c74-mcp-updates-#{inspect(ref)}",
        [:swarm_code, :domain, :repo, :query],
        fn _event, _measure, meta, _ ->
          if meta[:source] == "mcp_servers" and String.starts_with?(meta[:query] || "", "UPDATE"),
            do: send(handler, {:update, ref})
        end,
        nil
      )

      result =
        try do
          run(c, "mcp.set_tools",
            target: %{"id" => c.docs.id},
            attributes: %{"tools" => tools},
            expected: %{"disabled_tools" => ["docs_01"]}
          )
        after
          :telemetry.detach("c74-mcp-updates-#{inspect(ref)}")
        end

      assert {:ok, %{status: :accepted}} = result

      updates =
        Stream.repeatedly(fn -> receive do: ({:update, ^ref} -> 1), after: (0 -> nil) end)
        |> Enum.take_while(& &1)
        |> length()

      assert updates == 1

      disabled = Domain.get(c.docs.id).disabled_tools
      assert length(disabled) == 150 and "docs_01" in disabled and "docs_02" not in disabled
      assert Enum.count(Domain.tools_of(c.docs.id), & &1.enabled?) == 150
    end

    test "a stale list is a conflict; the same list is unchanged", c do
      {:ok, stale} =
        run(c, "mcp.set_tools",
          target: %{"id" => c.fs.id},
          attributes: %{"tools" => %{"fs_03" => false}},
          expected: %{"disabled_tools" => ["fs_01"]}
        )

      assert stale.status == :conflict
      assert [%{current: ["fs_01", "fs_02"]}] = stale.results

      {:ok, same} =
        run(c, "mcp.set_tools",
          target: %{"id" => c.fs.id},
          attributes: %{"tools" => %{"fs_01" => false}},
          expected: %{"disabled_tools" => ["fs_02", "fs_01"]}
        )

      assert same.status == :unchanged
    end
  end

  describe "reconnect" do
    test "a disabled server is rejected", c do
      {:ok, _} = Domain.update(Domain.get(c.docs.id), %{enabled: false})
      {:ok, result} = run(c, "mcp.reconnect", target: %{"id" => c.docs.id})
      assert result.status == :rejected and result.message == "turn it on first"
    end

    test "the status that arrives while reconnect runs is not lost (subscribe first)", c do
      server = Domain.get(c.docs.id)

      assert {:ok, %{"status" => "ready", "tools_total" => 29, "tools_enabled" => 28}} =
               MCP.reconnect_run(server, fn id -> Domain.put_status(id, :ready) end, 0)

      assert {:error, "boom " <> _} =
               MCP.reconnect_run(
                 server,
                 fn id -> Domain.put_status(id, {:error, "boom test-token-0000000000k1l2"}) end,
                 0
               )
               |> no_secret!()

      assert {:error, "no answer in 35 s"} = MCP.reconnect_run(server, fn _ -> :ok end, 0)
    end

    test "the task spec", c do
      {:task, spec, result} = run(c, "mcp.reconnect", target: %{"id" => c.github.id})
      assert result.status == :accepted and spec.action == "mcp.reconnect"
      assert spec.key == c.github.id and spec.timeout_ms == 35_000
      assert "ghp_test_0000000000000000i9j0" in spec.redact
    end
  end

  describe "test (probe)" do
    test "a draft is probed over loopback without saving; its header travels", c do
      fixture = mcp_http(["b_tool", "a_tool"])

      {:task, spec, _} =
        run(c, "mcp.test",
          target: %{"draft" => true},
          attributes: %{
            "name" => "draft",
            "transport" => "http",
            "url" => fixture.url <> "/mcp",
            "headers" => [%{"name" => "Authorization"}]
          },
          secrets: [%{slot: "header:Authorization", value: "Bearer " <> @canary}]
        )

      assert spec.kind == :probe and spec.timeout_ms == 65_000 and spec.key == "draft"
      no_secret!(spec)
      assert {:ok, %{"tools" => ["a_tool", "b_tool"], "count" => 2}} = C74S2.run_task(spec)
      assert_received {:http_request, 1, %{headers: %{"authorization" => "Bearer " <> @canary}}}
      refute Repo.get_by(Server, name: "draft")
    end

    test "an invalid draft answers field errors and starts nothing; a failing probe is redacted",
         c do
      assert {:error, %{field_errors: [%{target: "url"} | _]}} =
               run(c, "mcp.test",
                 target: %{"draft" => true},
                 attributes: %{"name" => "d", "transport" => "http"}
               )

      {:task, spec, _} =
        run(c, "mcp.test",
          target: %{"draft" => true},
          attributes: %{
            "name" => "d",
            "transport" => "stdio",
            "command" => "c74-no-such-mcp-server-#{System.unique_integer([:positive])}",
            "env" => [%{"name" => "TOKEN"}]
          },
          secrets: [%{slot: "env:TOKEN", value: @canary}]
        )

      assert {:error, message} = C74S2.run_task(spec)
      no_secret!(message)
    end
  end

  describe "delete" do
    test "CAS on updated_at; the client and its tools go", c do
      docs = Domain.get(c.docs.id)

      {:ok, stale} =
        run(c, "mcp.delete",
          target: %{"id" => docs.id},
          expected: %{"updated_at" => "2020-01-01T00:00:00Z"}
        )

      assert stale.status == :conflict and Domain.get(docs.id)

      {:ok, deleted} =
        run(c, "mcp.delete",
          target: %{"id" => docs.id},
          expected: %{"updated_at" => DateTime.to_iso8601(docs.updated_at)}
        )

      assert deleted.message == "docs deleted · agents lose its 29 tools"
      refute Domain.get(docs.id)
      assert Domain.tools_of(docs.id) == []
    end
  end

  describe "attention and glance" do
    test "AT1 for github on Appendix A", c do
      assert [item] = MCP.attention(c.ctx)
      assert item.id == "AT1" and item.severity == "error"
      assert item.title == "github MCP server failed to start"
      assert item.reason == "command not found: github-mcp-server"
      assert item.target == %{"kind" => "mcp_server", "id" => c.github.id}

      assert %{"mcp" => %{"servers" => 3, "ready" => 2, "failed" => 1, "tools" => 38}} =
               MCP.glance(c.ctx)

      {:ok, _} = Repo.update(Server.changeset(Domain.get(c.github.id), %{enabled: false}))
      assert MCP.attention(c.ctx) == []
    end
  end
end
