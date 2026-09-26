defmodule SwarmCodeCLI.UI.Settings.C74Qa2Test do
  @moduledoc """
  cli74 G2 (QA #2 of pass 74, `/Users/zaali/.cache/c74/Q2/qa.md`): each finding the
  polisher fixed, driven through the reducer against `Fake.Settings` and read from the
  rows or the projected screen. Where the fake answered what the service refuses (a
  record decoded with atom keys, an undo without `expected`), the test builds the
  service's shape itself; `c74_qa2_e2e_test` in the daemon runs them for real.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0, press!: 2, letter: 1]
  import SwarmCodeCLI.UI.C74U3Helpers

  alias SwarmCodeCLI.UI.{Input, Projector, SafeText, Size}
  alias SwarmCodeCLI.UI.DataSource.DTO.SettingsRecord
  alias SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations, as: I
  alias SwarmCodeCLI.UI.DataSource.Fake.Settings, as: FakeSettings
  alias SwarmCodeCLI.UI.Reducer.Settings.{Edit, Ops}
  alias SwarmCodeCLI.UI.Settings.{KeyValueSecrets, Layer, ModelPicker, Nav, Page, Wire}

  defp sized(columns, rows),
    do: act!(ready(), {:resize, %Size{columns: columns, rows: rows}})

  defp lines(state) do
    {scene, _actions} = Projector.project(state)

    scene.regions
    |> Enum.flat_map(& &1.blocks)
    |> Enum.map(fn block -> Enum.map_join(block.spans, "", &SafeText.value(&1.text)) end)
  end

  defp cells(line), do: SwarmCodeCLI.UI.Width.cells(line, :narrow)
  defp typed(state, text), do: Enum.reduce(String.graphemes(text), state, &press!(&2, letter(&1)))
  defp key(state, name), do: press!(state, Input.key(name))

  defp queries(effects, kind) do
    for request <- sent(effects),
        match?({:settings_query, _}, request.kind),
        params(request)["view"] == "records",
        params(request)["kind"] == kind,
        do: request
  end

  # ------------------------------------------------------------------ P0-1

  describe "P0-1: the model picker is drawn" do
    for {columns, rows} <- [{160, 45}, {80, 24}] do
      test "Enter on Chat model floats the F4 box at #{columns}×#{rows}" do
        {state, fake} = opened(:models_effort, state: sized(unquote(columns), unquote(rows)))
        state = Nav.put_cursor(state, "key:models.chat")
        {state, _fake} = state |> verb(:enter) |> serve(fake)
        assert state.settings.mode == :editing
        assert state.settings.editing.module == ModelPicker

        lines = lines(state)

        if out = System.get_env("C74_QA2_OUT"),
          do: File.write!(Path.join(out, "picker#{unquote(columns)}.txt"), Enum.join(lines, "\n"))

        assert length(lines) == unquote(rows)

        assert Enum.all?(lines, &(cells(&1) == unquote(columns))),
               inspect(Enum.map(lines, &cells/1))

        top = Enum.find_index(lines, &(&1 =~ "┌─ Chat model"))
        assert top, Enum.join(lines, "\n")
        assert Enum.at(lines, top) =~ ~r/providers · \d+ models ─┐/
        assert Enum.at(lines, top + 1) =~ "/ type to filter · provider/model works too"
        text = Enum.join(lines, "\n")
        assert text =~ "DeepSeek"
        assert text =~ ~r/✓ deepseek-v4-pro/
        assert text =~ ~r/Enter choose .* \d+ of \d+/
        assert Enum.any?(lines, &(&1 =~ "└"))
      end
    end

    test "the filter is drawn as it is typed, and Enter chooses what is seen" do
      {state, fake} = opened(:models_effort, state: sized(160, 45))
      state = Nav.put_cursor(state, "key:models.chat")
      {state, fake} = state |> verb(:enter) |> serve(fake)
      state = typed(state, "opus")

      text = state |> lines() |> Enum.join("\n")
      assert text =~ "/ opus"
      assert text =~ "claude-opus-5"
      refute text =~ "deepseek-v4-flash "

      {_state, effects} = act(state, {:settings, {:verb, :commit}})
      _ = fake
      assert [%{"value" => %{"model" => "claude-opus-5"}}] = patches(effects)
    end
  end

  defp patches(effects) do
    for patch <- commands(effects, "values.patch"),
        change <- patch["attributes"]["changes"],
        do: change
  end

  # ------------------------------------------------------------------ P0-2

  describe "P0-2: the picker has its options before Enter can choose" do
    test "opening the picker asks for the options again, even when the page holds them" do
      {state, _fake} = opened(:models_effort)
      assert state.settings.data.records |> Map.has_key?({"model_options", %{}})

      state = Nav.put_cursor(state, "key:models.sub_agent")
      {_state, effects} = verb(state, :enter)
      assert [_] = queries(effects, "model_options")
    end

    test "Enter while the options are on their way writes nothing (it erased the model)" do
      {state, fake} = opened(:models_effort)
      layer = state.settings
      state = %{state | settings: %{layer | data: %{layer.data | records: %{}}}}
      state = Nav.put_cursor(state, "key:models.sub_agent")
      {state, loads} = verb(state, :enter)
      assert state.settings.editing.module == ModelPicker
      assert [_] = queries(loads, "model_options")

      {state, effects} = act(state, {:settings, {:verb, :commit}})
      assert sent(effects) == []
      assert state.settings.mode == :editing
      text = state |> lines() |> Enum.join("\n")
      assert text =~ "┌─ Sub-agent model"

      # the options arrive: the cursor is on the current value, not the null choice
      {state, _fake} = serve(state, loads, fake)
      display = ModelPicker.display(state.settings.editing.state, Nav.ctx(state))
      assert [{"deepseek-v4-flash", _} | _] = display.value
    end

    test "a sub-agent model row names its provider, never the id (P1-1)" do
      {state, _fake} = opened(:models_effort)
      row = key_row(state, "models.sub_agent")
      refute words(row) =~ I.ids().deepseek
      assert words(row) =~ "· DeepSeek"
    end
  end

  # ------------------------------------------------------------------ P1-7, P2-7

  defp env_page do
    state = %{ready() | capabilities: %{ready().capabilities | paste: :supported}}
    {state, fake} = opened(:mcp, state: state)
    id = I.ids().github
    record = %Page{section: :mcp, record: {"mcp_server", id}}
    {state, _} = Ops.run(state, [{:open, record}])
    {state, _} = Ops.run(state, [{:open, %Page{record | sub: :env}}])
    {state, fake} = state |> Wire.sync() |> serve(fake)
    {state, fake, id}
  end

  describe "P1-7: a stored secret stays stored when another variable is added" do
    test "the service's entries (atom keys) read as secrets: the staged list keeps them" do
      {state, _fake, id} = env_page()
      token = row(state, "kv:env:0")
      assert token.label == "GITHUB_PERSONAL_ACCESS_TOKEN"
      assert token.marks == []

      state = state |> Nav.put_cursor("act:kv.add") |> key(:enter) |> typed("MODE=fast")
      state = key(state, :enter)

      assert %{"env" => env} = state.settings.staged[{"mcp_server", id}]
      assert %{"name" => "GITHUB_PERSONAL_ACCESS_TOKEN", "keep" => true} in env
      assert %{"name" => "MODE", "value" => "fast"} in env

      # P2-7: only the staged row is pending; the saved secret keeps its hint
      assert row(state, "kv:env:0").marks == []
      assert words(row(state, "kv:env:0")) =~ "secret · set · ends i9j0"
      assert Enum.find(rows(state), &(&1.label == "MODE")).marks == [:pending]
    end

    test "a decoded env entry is secret by its field, not only by its name" do
      {:ok, record} =
        SettingsRecord.decode(%{
          "kind" => "mcp_server",
          "id" => "s1",
          "fields" => %{
            "name" => "fakeq2",
            "env" => [%{"name" => "OPAQUE", "secret" => true, "value" => nil, "hint" => "9911"}]
          }
        })

      ctx = %SwarmCodeCLI.UI.Settings.Ctx{layer: %Layer{}, data: %SwarmCodeCLI.UI.Settings.Data{}}

      assert KeyValueSecrets.desired(ctx, "s1", :env, record.fields) == [
               %{"name" => "OPAQUE", "keep" => true}
             ]
    end
  end

  test "P2-7: a secret typed on the add row names its variable while it waits for the paste" do
    {state, _fake, _id} = env_page()
    state = state |> Nav.put_cursor("act:kv.add") |> key(:enter) |> typed("SLACK_TOKEN=")
    assert state.settings.mode == :paste
    line = state |> lines() |> Enum.find(&(&1 =~ "Add a variable"))
    assert line =~ "SLACK_TOKEN · paste the value · Cmd-V", line
  end

  # ------------------------------------------------------------------ P1-2, P1-5

  # A store that refuses a compare-and-set command without `expected`, as the
  # service does (the fake took them, so every undo passed its tests).
  defp strict, do: FakeSettings.seed(strict_expected: true)

  defp undo_redo(state, fake) do
    {state, fake} = state |> verb(:undo) |> serve(fake)
    undone = state.settings.status.text
    {state, fake} = state |> verb(:redo) |> serve(fake)
    {state, fake, undone, state.settings.status.text}
  end

  defp engines(fake) do
    fake.integrations.search
    |> Map.values()
    |> Enum.filter(&(&1["role"] == "engine"))
    |> Enum.sort_by(& &1["position"])
    |> Enum.map(& &1["kind"])
  end

  describe "P1-2, P1-5: every section command with an inverse undoes and redoes as a CAS write" do
    test "a search engine move (K, then u, then U)" do
      {state, fake} = opened(:search_web, fake: strict())
      before = engines(fake)
      state = Nav.put_cursor(state, "rec:search_provider:exa")
      {state, fake} = state |> verb(:move_up) |> serve(fake)
      moved = engines(fake)
      assert moved != before

      {state, fake} = state |> verb(:undo) |> serve(fake)
      assert state.settings.status.text =~ "Undid: ", state.settings.status.text
      assert engines(fake) == before

      {state, fake} = state |> verb(:redo) |> serve(fake)
      assert state.settings.status.text =~ "Redid: ", state.settings.status.text
      assert engines(fake) == moved
    end

    test "all of an MCP server's tools off (N), then u, then U" do
      {state, fake} = opened(:mcp, fake: strict())
      id = I.ids().docs
      {state, _} = Ops.run(state, [{:open, %Page{section: :mcp, record: {"mcp_server", id}}}])
      {state, fake} = state |> Wire.sync() |> serve(fake)
      before = fake.integrations.mcp[id]["disabled_tools"]
      [first | _] = for %{id: "item:tools:" <> _} = row <- rows(state), do: row.id

      {state, fake} = state |> Nav.put_cursor(first) |> verb(:all_off) |> serve(fake)
      all_off = fake.integrations.mcp[id]["disabled_tools"]
      assert length(all_off) > length(before)

      {_state, fake, undone, redone} = undo_redo(state, fake)
      assert undone =~ "Undid: ", undone
      assert redone =~ "Redid: ", redone
      assert Enum.sort(fake.integrations.mcp[id]["disabled_tools"]) == Enum.sort(all_off)
    end

    test "a price edit, then u, then U" do
      model = "claude-opus-5"
      {state, fake} = opened(:pricing, fake: strict())

      {state, _} =
        Ops.run(state, [{:open, %Page{section: :pricing, record: {"pricing_row", model}}}])

      {state, fake} = state |> Wire.sync() |> serve(fake)
      row = row(state, "fld:pricing_row:#{model}:output")
      {state, fake} = state |> Nav.put_cursor(row.id) |> Edit.commit(row, 70) |> serve(fake)
      assert fake.integrations.pricing[model]["output"] == 70

      {state, fake} = state |> verb(:undo) |> serve(fake)
      assert state.settings.status.text =~ "Undid: ", state.settings.status.text
      assert fake.integrations.pricing[model]["output"] == 75

      {state, fake} = state |> verb(:redo) |> serve(fake)
      assert state.settings.status.text =~ "Redid: ", state.settings.status.text
      assert fake.integrations.pricing[model]["output"] == 70
    end

    test "a price renamed, then u" do
      {state, fake} = opened(:pricing, fake: strict())
      page = %Page{section: :pricing, record: {"pricing_row", "claude-opus-5"}}
      {state, _} = Ops.run(state, [{:open, page}])
      {state, fake} = state |> Wire.sync() |> serve(fake)
      row = row(state, "fld:pricing_row:claude-opus-5:model")
      {state, fake} = state |> Edit.commit(row, "claude-opus-5.1") |> serve(fake)
      assert Map.has_key?(fake.integrations.pricing, "claude-opus-5.1")
      refute Map.has_key?(fake.integrations.pricing, "claude-opus-5")

      {state, fake} = state |> verb(:undo) |> serve(fake)
      assert state.settings.status.text =~ "Undid: ", state.settings.status.text
      assert Map.has_key?(fake.integrations.pricing, "claude-opus-5")
      refute Map.has_key?(fake.integrations.pricing, "claude-opus-5.1")
    end

    test "a staged MCP connection change applied, then u, then U" do
      {state, fake} = opened(:mcp, fake: strict())
      id = I.ids().docs
      {state, _} = Ops.run(state, [{:open, %Page{section: :mcp, record: {"mcp_server", id}}}])
      {state, fake} = state |> Wire.sync() |> serve(fake)
      url = fake.integrations.mcp[id]["url"]

      {state, _} =
        Ops.run(state, [{:stage, {"mcp_server", id}, %{"url" => "https://mine.example/mcp"}}])

      {state, fake} = state |> verb(:restart) |> serve(fake)
      assert fake.integrations.mcp[id]["url"] == "https://mine.example/mcp"

      {state, fake} = state |> verb(:undo) |> serve(fake)
      assert state.settings.status.text =~ "Undid: ", state.settings.status.text
      assert fake.integrations.mcp[id]["url"] == url

      {_state, fake} = state |> verb(:redo) |> serve(fake)
      assert fake.integrations.mcp[id]["url"] == "https://mine.example/mcp"
    end
  end

  # ------------------------------------------------------------------ P1-4

  test "P1-4: a tool switched with Space keeps the focus through the delta's reload" do
    {state, fake} = opened(:mcp, fake: strict())
    id = I.ids().docs
    {state, _} = Ops.run(state, [{:open, %Page{section: :mcp, record: {"mcp_server", id}}}])
    {state, fake} = state |> Wire.sync() |> serve(fake)
    tools = for %{id: "item:tools:" <> _} = row <- rows(state), do: row.id
    third = Enum.at(tools, 2)

    {state, fake} = state |> Nav.put_cursor(third) |> verb(:toggle) |> serve(fake)
    assert Nav.current(state).id == third

    # the write's delta: the page's records go and are asked for again
    update = %SwarmCodeCLI.UI.DataSource.DTO.SettingsUpdate{
      revision: state.settings.data.revision + 10,
      sections: [:mcp, :overview],
      origin: :settings
    }

    {state, effects} = SwarmCodeCLI.UI.Reducer.Settings.Responses.delta(state, update)
    assert [_ | _] = sent(effects)

    # answered one at a time, the server's own record last: the cursor never
    # leaves the tool
    {state, _fake} =
      effects
      |> sent()
      |> Enum.sort_by(&(params(&1)["view"] == "record"))
      |> Enum.reduce({state, fake}, fn request, {acc, fake} ->
        {acc, fake} = serve(acc, [{:query, request}], fake)
        assert Layer.page(acc.settings).cursor == third
        {acc, fake}
      end)

    assert Nav.current(state).id == third
  end

  # ------------------------------------------------------------------ P1-6

  test "P1-6: Test it first on a new MCP server shows the test and the tools it listed" do
    {state, fake} = opened(:mcp)

    [_ | _] =
      ops = SwarmCodeCLI.UI.Settings.Sections.MCP.act(Nav.ctx(state), %{target: {:add}}, :add)

    {state, fake} = state |> Ops.run(ops) |> serve(fake)

    {state, _} =
      Ops.run(state, [{:draft_put, "mcp_server", %{"name" => "fakeq2", "command" => "fake-mcp"}}])

    state = Nav.put_cursor(state, "act:mcp.test_draft")
    assert {"Enter", :open_row, "test"} in row(state, "act:mcp.test_draft").keys

    {state, effects} = verb(state, :enter)
    assert [%{"target" => %{"draft" => true}}] = commands(effects, "mcp.test")
    {state, _fake} = serve(state, effects, fake)
    assert words(row(state, "act:mcp.test_draft")) =~ "starting it to list its tools"

    [{task_id, _}] = Enum.filter(state.settings.tasks, fn {_, t} -> t["action"] == "mcp.test" end)

    done = %SwarmCodeCLI.UI.DataSource.DTO.SettingsTask{
      task_id: task_id,
      action: "mcp.test",
      target: %{"draft" => true},
      state: :done,
      summary: %{"tools" => ["alpha", "beta", "gamma"], "count" => 3}
    }

    {state, _} = SwarmCodeCLI.UI.Reducer.Settings.Responses.delta(state, done)
    assert words(row(state, "act:mcp.test_draft")) =~ "connected · 3 tools: alpha, beta, gamma"
  end

  # ------------------------------------------------------------------ P1-3

  defp exa_base_url_conflict do
    {state, fake} = opened(:search_web, fake: strict())
    page = %Page{section: :search_web, record: {"search_provider", "exa"}}
    {state, _} = Ops.run(state, [{:open, page}])
    {state, fake} = state |> Wire.sync() |> serve(fake)
    row = row(state, "fld:search_provider:exa:base_url")
    assert row, inspect(Enum.map(rows(state), & &1.id))

    # someone else writes the field while it is being edited
    fake = put_in(fake.integrations.search["exa"]["base_url"], "https://theirs.example")

    {state, fake} =
      state |> Nav.put_cursor(row.id) |> Edit.commit(row, "https://mine.example") |> serve(fake)

    assert fake.integrations.search["exa"]["base_url"] == "https://theirs.example"
    {state, fake}
  end

  describe "P1-3: a record field changed elsewhere keeps yours on its row" do
    test "the row shows both values; Enter writes yours expecting theirs" do
      {state, fake} = exa_base_url_conflict()
      conflicted = row(state, "fld:search_provider:exa:base_url")
      assert :conflict in conflicted.marks
      text = all_words(conflicted)

      assert text =~
               "! changed while you edited (elsewhere in this session): now https://theirs.example"

      assert text =~
               "Enter keep yours (https://mine.example) · Esc take theirs (https://theirs.example)"

      assert state.settings.status.text =~ "Enter keeps yours"

      {state, effects} = verb(state, :enter)
      assert [update] = commands(effects, "search.update")
      assert update["expected"] == %{"fields" => %{"base_url" => "https://theirs.example"}}

      {state, fake} = serve(state, effects, fake)
      assert fake.integrations.search["exa"]["base_url"] == "https://mine.example"
      refute :conflict in row(state, "fld:search_provider:exa:base_url").marks
    end

    test "Esc takes theirs and writes nothing" do
      {state, _fake} = exa_base_url_conflict()
      {state, effects} = verb(state, :back)
      assert sent(effects) == []
      assert state.settings.conflicts == %{}
      refute all_words(row(state, "fld:search_provider:exa:base_url")) =~ "mine.example"
      assert Layer.page(state.settings).record == {"search_provider", "exa"}
    end
  end

  # ------------------------------------------------------------------ P2

  test "P2-12: Providers opened while its list loads focuses the first provider" do
    {state, _fake} = opened(:providers)
    assert "rec:provider:" <> _ = Layer.page(state.settings).cursor
    assert "rec:provider:" <> _ = Nav.current(state).id
  end

  test "P2-4: a search engine's page is named by its label in the crumb" do
    {state, fake} = opened(:search_web, state: sized(160, 45))

    {state, _} =
      Ops.run(state, [{:open, %Page{section: :search_web, record: {"search_provider", "exa"}}}])

    {state, _fake} = state |> Wire.sync() |> serve(fake)
    assert hd(lines(state)) =~ "Search & web › Exa"
  end

  defp provider_page(fake, id) do
    {state, fake} = opened(:providers, fake: fake)
    {state, _} = Ops.run(state, [{:open, %Page{section: :providers, record: {"provider", id}}}])
    state |> Wire.sync() |> serve(fake)
  end

  test "P2-9: after Fetch every provider's models a provider's page says it was fetched" do
    id = I.ids().deepseek
    {state, _fake} = provider_page(FakeSettings.seed(), id)
    assert words(row(state, "fld:provider:#{id}:models")) =~ "not fetched this session"

    task = %{
      "task_id" => "t-all",
      "action" => "provider.fetch_all",
      "target" => nil,
      "state" => "done",
      "summary" => %{"providers" => [%{"id" => id, "state" => "done", "count" => 3}]},
      "received_at_ms" => System.system_time(:millisecond)
    }

    layer = state.settings
    state = %{state | settings: %{layer | tasks: Map.put(layer.tasks, "t-all", task)}}
    text = words(row(state, "fld:provider:#{id}:models"))
    assert text =~ ~r/fetched this session \d\d:\d\d/
    refute text =~ "not fetched"
  end

  test "P2-11: a provider with models and no default model says how to pick one" do
    id = I.ids().deepseek
    fake = FakeSettings.seed()
    fake = put_in(fake.integrations.providers[id]["default_model"], nil)
    {state, _fake} = provider_page(fake, id)

    assert words(row(state, "fld:provider:#{id}:default_model")) =~
             ~r/none · Enter picks one of its \d+ models/
  end

  test "P2-5: the page filter counts its rows in agreement (1 match, 2 matches)" do
    {state, _fake} = opened(:keys, state: sized(160, 45))
    {state, _} = Ops.run(state, [{:open, %Page{section: :keys, sub: {:key_bindings, nil}}}])
    state = press!(state, letter("/"))

    for {query, noun} <- [{"palette", "match"}, {"scroll", "matches"}] do
      [_header, search | _] = state |> typed(query) |> lines()
      [_, count, said] = Regex.run(~r/· (\d+) (match(?:es)?) /, search)
      assert said == noun, search
      assert if(count == "1", do: noun == "match", else: noun == "matches"), search
    end
  end

  test "P2-1: the enum editor keeps the focused choice in view (‹ … Firecrawl ›)" do
    alias SwarmCodeCLI.UI.Settings.Editors.Enum, as: EnumEditor

    choices = [
      %{value: "web_fetch", label: "Plain fetch (strip HTML)", hint: nil},
      %{value: "jina", label: "Jina Reader", hint: nil},
      %{value: "firecrawl", label: "Firecrawl", hint: nil}
    ]

    ctx = %{size: %{columns: 160, rows: 45}}
    {:ok, editor} = EnumEditor.init(%{}, %{choices: choices, value: "firecrawl"}, ctx)
    shown = EnumEditor.display(editor, ctx).value
    text = words(shown)
    assert text =~ ~r/^‹ … .*Firecrawl ›$/, text
    assert {"Firecrawl", :selection} in shown
    assert String.length(text) <= 40

    # at 200 columns they all fit, as §4.5 draws them
    wide = %{size: %{columns: 200, rows: 45}}

    assert words(EnumEditor.display(editor, wide).value) ==
             "‹ Plain fetch (strip HTML)  Jina Reader  Firecrawl ›"
  end

  describe "P2-10: the Overview's counts and storage line" do
    test "the rail counts providers and MCP servers before their sections are opened" do
      {state, _fake} = opened(:overview, state: sized(160, 45))
      refute Map.has_key?(state.settings.data.records, {"providers", %{}})
      text = state |> lines() |> Enum.join("\n")
      assert text =~ ~r/Providers\s+4 │/
    end

    test "at a glance has a storage line from the service's fragment" do
      {state, _fake} = opened(:overview)
      layer = state.settings
      overview = layer.data.overview

      glance =
        Map.put(overview.glance, "storage", %{
          "retention_days" => 90,
          "cleanup" => "idle",
          "sessions_measured" => 214
        })

      data = %{layer.data | overview: %{overview | glance: glance}}
      state = %{state | settings: %{layer | data: data}}
      text = words(row(state, "info:glance:storage"))
      assert text == "214 sessions · never cleaned up · deletes sessions after 90 days"
    end
  end
end
