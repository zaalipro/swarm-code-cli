defmodule SwarmCodeCLI.UI.Settings.Sections.C74McpTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations, as: I
  alias SwarmCodeCLI.UI.Settings.Sections.MCP
  alias SwarmCodeCLI.Test.C74U2Tasks, as: T
  import SwarmCodeCLI.Test.C74U2Ctx
  alias SwarmCodeCLI.Test.C74U2Ctx.Page

  defp row(rows, id),
    do:
      Enum.find(rows, &(&1.id == id)) ||
        flunk("no row #{id}: #{inspect(Enum.map(rows, & &1.id))}")

  defp server_ctx(id, opts \\ []) do
    state = Keyword.get(opts, :state, I.seed())

    ctx(state,
      records: [{"mcp_server", id}],
      page: Page.at(:mcp, {"mcp_server", id}, Keyword.get(opts, :sub)),
      layer: Keyword.get(opts, :layer, [])
    )
  end

  defp staged(id, fields), do: [staged: %{{"mcp_server", id} => fields}]

  defp import_ctx(opts \\ []) do
    {state, tid, task, rows} =
      T.run(I.seed(), "mcp.import.read", nil, %{"path" => nil}, :run, "imp-1")

    ctx(state, page: Page.at(:mcp, nil, :import), layer: Keyword.get(opts, :layer, []))
    |> T.put(tid, task, rows)
  end

  test "the list groups servers by scope with state words, tools and the import action" do
    ids = I.ids()
    rows = MCP.rows(ctx())
    github = row(rows, "rec:mcp_server:#{ids.github}")

    assert text(github.value) == "✗ failed: command not found: github-mcp-server"
    assert :attention in github.marks
    assert Enum.any?(rows, &(&1.id == "act:mcp.import"))
    assert Enum.any?(rows, &(&1.id == "act:mcp.add"))
    ids_in_order = Enum.map(rows, & &1.id)

    assert Enum.find_index(ids_in_order, &(&1 == "head:every project")) <
             Enum.find_index(ids_in_order, &(&1 == "rec:mcp_server:#{ids.github}"))

    assert [{:command, "mcp.toggle", %{"id" => gid}, %{"enabled" => false}, opts}] =
             MCP.act(ctx(), github, :toggle)

    assert gid == ids.github and opts.expected == %{"fields" => %{"enabled" => true}}
    assert [{:task, "mcp.reconnect", _, _}] = MCP.act(ctx(), github, :restart)
  end

  test "the import preview masks secrets and offers the choices for ${GITHUB_TOKEN}" do
    c = import_ctx()
    rows = MCP.rows(c)
    github = row(rows, "item:import:github")
    assert text(github.value) =~ "npx -y @modelcontextprotocol/server-github"

    var = row(rows, "item:importvar:github:env.GITHUB_TOKEN")
    assert text(var.value) =~ "GITHUB_TOKEN = ${GITHUB_TOKEN}"
    assert text(hd(var.lines)) =~ "paste a value"
    assert text(hd(var.lines)) =~ "keep it literally"

    masked = row(rows, "info:import:docs:Authorization")
    assert text(masked.value) =~ "●●●●●●●●"
    refute Enum.any?(rows, fn r -> text(r.value || []) =~ "test-token-import" end)

    events = row(rows, "item:import:events")
    assert events.state == :disabled
    assert text(hd(events.lines)) =~ "SSE servers are not supported"
  end

  test "apply sends the ticked names, renames and choices; pasted values ride only in secrets" do
    c = import_ctx()
    rows = MCP.rows(c)
    # both names exist in the seed: unticked until renamed
    assert text(row(rows, "item:import:github").value) =~ "[ ]"
    [{:draft_put, "mcp_import", fields}] = MCP.act(c, row(rows, "item:import:github"), :new)
    c = put_layer(c, :drafts, %{"mcp_import" => %{fields: fields}})
    rows = MCP.rows(c)

    [{:draft_put, "mcp_import", fields} | paste] =
      MCP.act(c, row(rows, "item:importvar:github:env.GITHUB_TOKEN"), :var_paste)

    assert [{:paste, target}] = paste
    assert target.slot == "import:github:env:GITHUB_TOKEN" and target.draft == "mcp_import"

    assert [
             {:toast, "Paste a value for GITHUB_TOKEN of github first, or choose another way",
              :warning}
           ] =
             MCP.act(
               put_layer(c, :drafts, %{"mcp_import" => %{fields: fields}}),
               row(rows, "act:import.apply"),
               :open_row
             )

    c =
      put_layer(c, :drafts, %{"mcp_import" => %{fields: fields, secrets: %{target.slot => true}}})

    rows = MCP.rows(c)

    [{:command, "mcp.import.apply", nil, attrs, opts}] =
      MCP.act(c, row(rows, "act:import.apply"), :open_row)

    assert attrs["import_id"] == "imp-1"
    assert attrs["names"] == ["github"]
    assert attrs["rename"] == %{"github" => "github-2"}
    assert attrs["values"] == %{"github" => %{"env.GITHUB_TOKEN" => "paste"}}
    assert opts.secrets_from == {:draft, "mcp_import"}
    refute inspect(attrs) =~ "secret"

    {{:ok, result}, _} =
      I.command(c_state(), %{
        "action" => "mcp.import.apply",
        "target" => nil,
        "attributes" => attrs,
        "secrets" => [
          %{"slot" => "import:github:env:GITHUB_TOKEN", "value" => "ghp_pasted0000000000000000"}
        ]
      })

    assert result["status"] == "accepted", inspect(result)
  end

  defp c_state do
    {state, _tid, _task, _rows} =
      T.run(I.seed(), "mcp.import.read", nil, %{"path" => nil}, :run, "imp-1")

    state
  end

  test "a conflicting name is unticked; n imports it as name-2 and ticks it" do
    {state, tid, task, rows} =
      T.run(I.seed(), "mcp.import.read", nil, %{"path" => nil}, :run, "imp-1")

    rows = Enum.map(rows, &if(&1["name"] == "docs", do: Map.put(&1, "conflict", true), else: &1))
    c = ctx(state, page: Page.at(:mcp, nil, :import)) |> T.put(tid, task, rows)
    docs = row(MCP.rows(c), "item:import:docs")
    assert text(docs.value) =~ "[ ]"

    [{:draft_put, "mcp_import", f}] = MCP.act(c, docs, :new)
    assert f["rename"] == %{"docs" => "docs-2"} and f["ticks"]["docs"] == true
  end

  test "leaving the server page applies the staged fields in one mcp.update" do
    id = I.ids().fs
    c = server_ctx(id, layer: staged(id, %{"name" => "files", "args" => ["--root", "/tmp"]}))
    rows = MCP.rows(c) ++ MCP.record_rows(c, "mcp_server", id)
    head = row(rows, "info:mcp:head:#{id}")
    assert text(hd(head.lines)) =~ "2 changes not applied"

    [{:command, "mcp.update", %{"id" => ^id}, attrs, opts}] = MCP.act(c, head, :leave)
    assert attrs == %{"name" => "files", "args" => ["--root", "/tmp"]}
    assert opts.expected == %{"fields" => %{"name" => "fs", "args" => rec_args(id)}}

    assert [{:command, "mcp.update", _, ^attrs, _}] = MCP.act(c, head, :restart)
    assert [] == MCP.act(server_ctx(id), head, :leave)
  end

  defp rec_args(id) do
    {:ok, rec} = I.query(I.seed(), %{"view" => "record", "kind" => "mcp_server", "id" => id})
    rec["fields"]["args"]
  end

  test "r reverts a staged field without a request; a clean field says so" do
    id = I.ids().fs
    c = server_ctx(id, layer: staged(id, %{"name" => "files"}))
    rows = MCP.record_rows(c, "mcp_server", id)

    assert [{:unstage, {"mcp_server", ^id}, ["name"]}] =
             MCP.act(c, row(rows, "fld:mcp_server:#{id}:name"), :reset)

    assert [{:toast, _, :info}] = MCP.act(c, row(rows, "fld:mcp_server:#{id}:command"), :reset)
  end

  test "editing a field stages it; blank names and bad URLs stay on the row" do
    id = I.ids().fs
    c = server_ctx(id)
    rows = MCP.record_rows(c, "mcp_server", id)
    name = row(rows, "fld:mcp_server:#{id}:name")

    assert [{:stage, {"mcp_server", ^id}, %{"name" => "files"}}] = MCP.commit(c, name, " files ")
    assert [{:row_error, _, "can't be blank"}] = MCP.commit(c, name, "  ")
    assert [{:unstage, _, ["name"]}] = MCP.commit(c, name, "fs")

    args = row(rows, "fld:mcp_server:#{id}:args")

    assert [{:stage, _, %{"args" => ["--root", "/my dir", "it's"]}}] =
             MCP.commit(c, args, ~s(--root "/my dir" 'it'\\''s'))

    assert [{:row_error, _, "a quote is not closed"}] = MCP.commit(c, args, "'open")
  end

  test "scope changes only from the scope row's picker" do
    id = I.ids().fs
    c = server_ctx(id)
    rows = MCP.record_rows(c, "mcp_server", id)
    [{:picker, picker}] = MCP.act(c, row(rows, "fld:mcp_server:#{id}:project_id"), :open_row)
    assert Map.get(picker, :on_pick) == {:section, :mcp, {:scope, id}}

    assert [{:stage, {"mcp_server", ^id}, %{"project_id" => "p1"}}] =
             MCP.picked(c, {:scope, id}, "p1")

    refute Enum.any?(rows, &(Map.get(&1, :key) == "mcp_server.project_id" and &1.editor != nil))
  end

  test "the tools checklist sends mcp.set_tools with CAS; A and N switch every tool" do
    id = I.ids().fs
    c = server_ctx(id)
    rows = MCP.record_rows(c, "mcp_server", id)
    tool = row(rows, "item:tools:read_file")

    [{:command, "mcp.set_tools", %{"id" => ^id}, %{"tools" => %{"read_file" => false}}, opts}] =
      MCP.act(c, tool, :toggle)

    assert opts.expected == %{"disabled_tools" => ["fs_01", "fs_02"]}
    [{:command, "mcp.set_tools", _, %{"tools" => off}, _}] = MCP.act(c, tool, :all_off)
    assert map_size(off) == 10
    [{:command, "mcp.set_tools", _, %{"tools" => on}, _}] = MCP.act(c, tool, :all_on)
    assert on == %{"fs_01" => true, "fs_02" => true}
  end

  test "D asks first and names the tools agents lose" do
    id = I.ids().fs
    c = server_ctx(id)
    rows = MCP.record_rows(c, "mcp_server", id)

    [{:confirm, confirm, then: [{:command, "mcp.delete", %{"id" => ^id}, %{}, _}]}] =
      MCP.act(c, row(rows, "act:mcp.delete"), :delete)

    assert Map.get(confirm, :lines) == [
             "Agents lose its 12 tools; conversations that used them keep their history"
           ]
  end

  test "environment: secrets never drawn, Enter pastes, plain values stage the desired list" do
    id = I.ids().github
    c = server_ctx(id, sub: :env)
    rows = MCP.record_rows(c, "mcp_server", id)
    secret = row(rows, "kv:env:0")
    assert secret.label == "GITHUB_PERSONAL_ACCESS_TOKEN"
    assert text(secret.value) == "●●●●●●●● secret · set · ends i9j0"
    assert [{:paste, target}] = MCP.act(c, secret, :open_row)
    assert target.action == "mcp.set_secret" and target.slot == "env:GITHUB_PERSONAL_ACCESS_TOKEN"

    plain = row(rows, "kv:env:1")

    assert [{:stage, {"mcp_server", ^id}, %{"env" => desired}}] =
             MCP.commit(c, plain, "repos")

    assert desired == [
             %{"name" => "GITHUB_PERSONAL_ACCESS_TOKEN", "keep" => true},
             %{"name" => "GITHUB_TOOLSETS", "value" => "repos"}
           ]

    add = row(rows, "act:kv.add")
    assert [{:paste, _}] = MCP.commit(c, add, "API_TOKEN=sk-live-abcdefghijklmnop")
    assert [{:row_error, _, _}] = MCP.commit(c, add, "1BAD=x")
  end

  test "shell-quoting round-trips arguments" do
    args = ["-y", "a b", "it's", ""]
    line = Enum.map_join(args, " ", &MCP.quote_arg/1)
    assert {:ok, ^args} = MCP.split_args(line)
  end
end
