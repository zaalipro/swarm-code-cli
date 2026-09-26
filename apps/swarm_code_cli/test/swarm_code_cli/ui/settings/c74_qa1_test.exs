defmodule SwarmCodeCLI.UI.Settings.C74Qa1Test do
  @moduledoc """
  cli74 G1 (QA #1 of pass 74, `/Users/zaali/.cache/c74/Q1/qa.md`): each finding the
  polisher fixed, driven through the reducer against `Fake.Settings` (keys as verbs,
  answers served by the fake) and read from the rows or the projected screen.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0, press!: 2, letter: 1]
  import SwarmCodeCLI.UI.C74U3Helpers
  import SwarmCodeCLI.Test.C74U2Ctx, only: [ctx: 2]

  alias SwarmCodeCLI.UI.Input
  alias SwarmCodeCLI.UI.DataSource.Fake.Settings, as: FakeSettings
  alias SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations, as: I
  alias SwarmCodeCLI.Test.C74U2Tasks, as: T
  alias SwarmCodeCLI.Test.C74U2Ctx.Page, as: U2Page
  alias SwarmCodeCLI.UI.Reducer.Settings.Ops
  alias SwarmCodeCLI.UI.Settings.{Layer, Nav, Page}
  alias SwarmCodeCLI.UI.Settings.Sections.{MCP, Providers}

  defp requests(fake) do
    {requests, _, _} = FakeSettings.control(fake, :requests, [])
    requests
  end

  defp record_id(state, prefix) do
    Enum.find_value(Nav.rows(state), fn row ->
      if String.starts_with?(row.id, prefix), do: String.replace_prefix(row.id, prefix, "")
    end)
  end

  # ------------------------------------------------------------------ F-1

  describe "F-1: a created record leaves no draft behind" do
    test "Ctrl-S on a new provider drops the draft and its key; leaving asks nothing" do
      state = %{ready() | capabilities: %{ready().capabilities | paste: :supported}}
      {state, fake} = opened(:providers, state: state)
      {state, fake} = state |> Ops.run(Providers.start_draft("lmstudio")) |> serve(fake)

      state = Nav.put_cursor(state, "fld:provider:draft:api_key")
      {state, _} = act(state, {:settings, {:paste, "sk-lm-local-000000000001"}})
      {state, _} = verb(state, :paste_commit)
      assert Map.has_key?(state.settings.drafts, "provider")

      {state, _fake} = state |> verb(:save) |> serve(fake)

      assert {"provider", id} = Layer.page(state.settings).record
      assert id != "draft"
      refute Map.has_key?(state.settings.drafts, "provider")
      # The created provider's page replaced the draft's: one Esc is the list.
      assert [%Page{record: {"provider", ^id}}, %Page{record: nil}] = state.settings.stack

      {state, _} = verb(state, :back)
      assert state.settings.popover == nil
      assert Layer.page(state.settings).record == nil
    end

    test "Ctrl-S on a new MCP server drops the draft" do
      {state, fake} = opened(:mcp)
      [_ | _] = ops = MCP.act(Nav.ctx(state), %{target: {:add}}, :add)
      {state, fake} = state |> Ops.run(ops) |> serve(fake)

      {state, _} =
        Ops.run(state, [
          {:draft_put, "mcp_server", %{"name" => "fakesrv", "command" => "fake-mcp"}}
        ])

      {state, _fake} = state |> verb(:save) |> serve(fake)

      assert {"mcp_server", id} = Layer.page(state.settings).record
      assert id != "draft"
      refute Map.has_key?(state.settings.drafts, "mcp_server")
      {state, _} = verb(state, :back)
      assert state.settings.popover == nil
    end
  end

  # ------------------------------------------------------------------ F-2

  describe "F-2: undo is a CAS write, and section commands are undo steps" do
    test "undo after a change made elsewhere shows the conflict, and writes nothing" do
      key = "limits.max_concurrent_agents"
      {state, fake} = opened(:agents_limits)
      {state, fake} = state |> Ops.run([{:patch, key, 5}]) |> serve(fake)
      assert stored(fake, key) == 5

      {:ok, fake, _} = FakeSettings.control(fake, :put, [key, 8])
      {state, fake} = state |> verb(:refresh) |> serve(fake)

      {state, effects} = verb(state, :undo)
      [patch] = commands(effects, "values.patch")
      assert patch["expected"] == %{key => 5}

      {state, fake} = serve(state, effects, fake)
      assert stored(fake, key) == 8
      assert Map.has_key?(state.settings.conflicts, {:value, key})
      refute state.settings.status.text =~ "Undid"
    end

    test "a search engine move is one undo step: u moves it back, U again" do
      {state, fake} = opened(:search_web)
      state = Nav.put_cursor(state, "rec:search_provider:exa")
      before = order(fake)

      {state, fake} = state |> verb(:move_down) |> serve(fake)
      moved = order(fake)
      assert moved != before

      {state, fake} = state |> verb(:undo) |> serve(fake)
      assert order(fake) == before
      assert state.settings.status.text =~ "Undid: "

      {_state, fake} = state |> verb(:redo) |> serve(fake)
      assert order(fake) == moved
    end
  end

  defp stored(fake, key), do: fake.global[key]

  defp order(fake) do
    fake.integrations.search
    |> Map.values()
    |> Enum.filter(&(&1["role"] == "engine"))
    |> Enum.sort_by(& &1["position"])
    |> Enum.map(& &1["kind"])
  end

  # ------------------------------------------------------------------ F-3, F-4, F-18

  defp typed(state, text), do: Enum.reduce(String.graphemes(text), state, &press!(&2, letter(&1)))
  defp key(state, name), do: press!(state, Input.key(name))

  describe "F-3: Esc after a search result's editor stays in Settings" do
    test "the editor ends back on the results; Esc clears them, then leaves the search" do
      {state, _fake} = opened(:overview)
      state = state |> press!(letter("/")) |> typed("automatically delete")

      state = key(state, :enter)
      assert state.settings.mode == :editing
      assert state.settings.editing.row.key == "storage.retention_days"

      state = key(state, :escape)
      assert state.settings.mode == :search
      assert state.settings.search.query == "automatically delete"
      assert state.settings.search.cursor == "key:storage.retention_days"

      state = key(state, :escape)
      assert state.settings.search.query == ""
      assert state.settings.mode == :search

      state = key(state, :escape)
      assert %Layer{mode: :browse, search: nil} = state.settings

      assert key(state, :escape).settings == nil
    end

    test "a value kept in a result's editor goes back to the results too" do
      {state, fake} = opened(:overview)
      state = state |> press!(letter("/")) |> typed("max concurrent")
      state = key(state, :enter)
      assert state.settings.editing.row.key == "limits.max_concurrent_agents"

      {state, _fake} =
        state
        |> act({:settings, {:verb, :clear_line}})
        |> elem(0)
        |> typed("7")
        |> then(&serve(act(&1, {:settings, {:verb, :commit}}), fake))

      assert state.settings.mode == :search
      state = key(state, :escape)
      refute state.settings == nil
    end
  end

  describe "F-4: every search result can be reached from the keyboard" do
    test "↓ reaches a fact at the top and then the row below it; Enter on the words picks the best match" do
      {state, _fake} = opened(:overview)
      state = state |> press!(letter("/")) |> typed("monthly budget")

      ids = for row <- Nav.rows(state), SwarmCodeCLI.UI.Settings.Row.focusable?(row), do: row.id
      assert "key:project_file.denied" in ids
      assert "key:budget.monthly_usd" in ids
      assert hd(ids) == "key:project_file.denied"

      down = key(state, :down)
      assert down.settings.search.cursor == "key:project_file.denied"
      down = key(down, :down)
      assert down.settings.search.cursor == "key:budget.monthly_usd"

      entered = key(state, :enter)
      assert entered.settings.mode == :editing
      assert entered.settings.editing.row.key == "budget.monthly_usd"
    end

    test "Enter on a fact result shows it in its section" do
      {state, _fake} = opened(:overview)
      state = state |> press!(letter("/")) |> typed("monthly budget") |> key(:down)
      state = key(state, :enter)
      assert Layer.section(state.settings) == :project_file
      assert state.settings.search == nil
    end
  end

  test "F-18: the result the cursor is on carries the focus mark, under NO_COLOR as `>`" do
    {state, _fake} = opened(:overview)
    caps = %{state.capabilities | ascii?: true, glyph_tier: :ascii, color_mode: :monochrome}
    state = %{state | capabilities: caps}
    state = state |> press!(letter("/")) |> typed("monthly budget") |> key(:down)

    marked = fn state, label ->
      line = state |> screen() |> String.split("\n") |> Enum.find(&(&1 =~ label))
      line =~ ~r/>\s*\S?\s*#{label}/u
    end

    assert marked.(state, "Keys a project file")
    refute marked.(state, "Monthly budget")
    state = key(state, :down)
    assert marked.(state, "Monthly budget")
    refute marked.(state, "Keys a project file")
  end

  # ------------------------------------------------------------------ F-5

  describe "F-5: the keys sheet lists the page's keys, the marks and the layers" do
    test "at 160 x 45 every settings binding shows at once, with the legend and the last line" do
      state =
        ready()
        |> act!({:resize, %SwarmCodeCLI.UI.Size{columns: 160, rows: 45}})
        |> act!({:settings_open, {:section, :appearance}})
        |> press!(letter("?"))

      assert {:help, _} = state.settings.popover
      text = screen(state)

      for binding <- SwarmCodeCLI.UI.Keymap.SettingsBindings.all(),
          :settings in binding.contexts do
        clause = binding.help |> String.split([" (", "; "], parts: 2) |> hd()
        assert text =~ binding.label or text =~ clause, binding.label
      end

      assert text =~ "Delete the record this page shows"
      assert text =~ "marks"
      assert text =~ "needs your attention"
      assert text =~ "where a value comes from, strongest first"
      assert text =~ "shared with the desktop app"
      assert text =~ "Remapped yourself out of a key? swarmcode config reset terminal.keys"
    end

    test "at 90 columns the sheet is one scrolling column with each key's help" do
      state =
        ready()
        |> act!({:resize, %SwarmCodeCLI.UI.Size{columns: 90, rows: 30}})
        |> act!({:settings_open, {:section, :appearance}})
        |> press!(letter("?"))

      text =
        state
        |> SwarmCodeCLI.UI.Projector.Settings.Popover.lines({:help, %{scroll: 0}})
        |> Enum.map_join("\n", fn line -> Enum.map_join(line, "", &elem(&1, 0)) end)

      for binding <- SwarmCodeCLI.UI.Keymap.SettingsBindings.all(),
          :settings in binding.contexts,
          do: assert(text =~ binding.label <> " — " <> binding.help, binding.label)

      assert text =~ "where a value comes from"
    end
  end

  # ------------------------------------------------------------------ F-7, F-10

  defp record_ctx(section, kind, id),
    do: ctx(I.seed(), records: [{kind, id}], page: U2Page.at(section, {kind, id}, nil))

  defp find_row(rows, id), do: Enum.find(rows, &(&1.id == id)) || flunk("no row #{id}")

  describe "F-7: D deletes the record a page shows" do
    test "on a provider's page D from any row does what Enter on its delete row does" do
      id = I.ids().openrouter
      c = record_ctx(:providers, "provider", id)
      rows = Providers.record_rows(c, "provider", id)
      delete = find_row(rows, "act:provider.delete")

      assert {"D", :delete_record, "delete OpenRouter"} in delete.keys
      [_ | _] = ops = Providers.act(c, delete, :delete_record)
      assert ops == Providers.act(c, delete, :open_row)
      assert Providers.act(c, find_row(rows, "fld:provider:#{id}:name"), :delete_record) == ops
    end

    test "on an MCP server's page D asks first, from any row" do
      id = I.ids().fs
      c = record_ctx(:mcp, "mcp_server", id)
      rows = MCP.record_rows(c, "mcp_server", id)
      delete = find_row(rows, "act:mcp.delete")

      assert {"D", :delete_record, "delete"} in delete.keys
      assert [{:confirm, %{id: "mcp.delete"}, then: _}] = MCP.act(c, delete, :delete_record)
      # The head row (the first a page focuses).
      head = find_row(rows, "info:mcp:head:#{id}")
      assert [{:confirm, %{id: "mcp.delete"}, then: _}] = MCP.act(c, head, :delete_record)
    end
  end

  test "F-10: a and + apply a waiting fetch difference from any row of the provider's page" do
    id = I.ids().deepseek
    {_s, tid, task, trows} = T.run(I.seed(), "provider.fetch_models", %{"id" => id})
    c = record_ctx(:providers, "provider", id) |> T.put(tid, task, trows)
    rows = Providers.record_rows(c, "provider", id)

    models = find_row(rows, "fld:provider:#{id}:models")
    assert {"a", :add, "apply all"} in models.keys

    for row <- [find_row(rows, "fld:provider:#{id}:name"), models] do
      assert [{:command, "provider.apply_models", _, %{"mode" => "replace"}, _}] =
               Providers.act(c, row, :add)

      assert [{:command, "provider.apply_models", _, %{"mode" => "add"}, _}] =
               Providers.act(c, row, :add_key)
    end

    # Without a difference `a` on the page is not an apply.
    plain = record_ctx(:providers, "provider", id)
    name = find_row(Providers.record_rows(plain, "provider", id), "fld:provider:#{id}:name")
    assert Providers.act(plain, name, :add) == :default
  end

  test "F-9: two failed servers are two attention items on the client too" do
    item = fn id ->
      %{
        id: "AT1",
        severity: :error,
        section: :mcp,
        target: %{kind: "mcp_server", id: id},
        title: "#{id} MCP server failed to start",
        reason: "command not found"
      }
    end

    ctx = %SwarmCodeCLI.UI.Settings.Ctx{
      data: %SwarmCodeCLI.UI.Settings.Data{overview: %{attention: [item.("a"), item.("b")]}},
      prefs: %{},
      launch_facts: %{}
    }

    items = SwarmCodeCLI.UI.Settings.Sections.Overview.items(ctx)

    assert Enum.map(items, & &1.target) == [
             {:record, "mcp_server", "a"},
             {:record, "mcp_server", "b"}
           ]
  end

  # ------------------------------------------------------------------ F-22

  test "F-22: a renamed price opens the renamed row's page in place of the old one" do
    {state, fake} = opened(:pricing)
    model = record_id(state, "rec:pricing_row:")
    assert is_binary(model)

    {state, fake} =
      state
      |> Ops.run([{:open, %Page{section: :pricing, record: {"pricing_row", model}}}])
      |> serve(fake)

    row = row(state, "fld:pricing_row:#{model}:model")
    ops = SwarmCodeCLI.UI.Settings.Sections.commit(:pricing, Nav.ctx(state), row, "renamed-model")
    {state, _fake} = state |> Ops.run(ops) |> serve(fake)

    assert Layer.page(state.settings).record == {"pricing_row", "renamed-model"}
    assert length(state.settings.stack) == 2
    _ = requests(fake)
  end
end
