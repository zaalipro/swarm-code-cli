defmodule SwarmCodeCLI.UI.Settings.Sections.C74SearchWebTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations, as: I
  alias SwarmCodeCLI.UI.Settings.Sections.SearchWeb
  alias SwarmCodeCLI.Test.C74U2Tasks, as: T
  import SwarmCodeCLI.Test.C74U2Ctx
  alias SwarmCodeCLI.Test.C74U2Ctx.Page

  defp row(rows, id),
    do:
      Enum.find(rows, &(&1.id == id)) ||
        flunk("no row #{id}: #{inspect(Enum.map(rows, & &1.id))}")

  defp record_ctx(kind, state \\ I.seed()),
    do: ctx(state, page: Page.at(:search_web, {"search_provider", kind}))

  test "F7's first page: engines in order with keys and tests, then readers, the reader, the facts" do
    {state, id, task, _} = T.run(I.seed(), "search.test", %{"kind" => "tavily"})
    c = ctx(state) |> T.put(id, task, [])
    rows = SearchWeb.rows(c)

    assert Enum.map(rows, & &1.id) == [
             "head:search providers",
             "rec:search_provider:tavily",
             "rec:search_provider:exa",
             "rec:search_provider:brave",
             "rec:search_provider:serper",
             "head:readers",
             "rec:search_provider:jina",
             "rec:search_provider:firecrawl",
             "head:reading pages",
             "key:web.reader",
             "key:web.fetch_facts",
             "link:tool_timeout"
           ]

    assert text(row(rows, "rec:search_provider:tavily").value) ==
             "1 [✓] key ●●●●●●●● set · ends e5f6"

    assert text(row(rows, "rec:search_provider:tavily").tag) == "✓ searched 18:40"
    assert text(row(rows, "rec:search_provider:exa").tag) == "never tested"
    assert text(row(rows, "rec:search_provider:brave").value) == "3 [ ] no key"

    assert text(row(rows, "rec:search_provider:jina").value) ==
             "no key · optional · reads pages without a key, rate limited"

    assert text(row(rows, "key:web.reader").value) == "Plain fetch (strip HTML)"
  end

  test "J and K send search.move with CAS on the order" do
    c = ctx()
    exa = row(SearchWeb.rows(c), "rec:search_provider:exa")

    [{:command, "search.move", %{"kind" => "exa"}, %{"dir" => 1}, opts}] =
      SearchWeb.act(c, exa, :move_down)

    # cli74 F13: the whole order the service reads, readers too (the
    # engines alone were a conflict every time, found in the sandbox).
    assert opts.expected == %{"order" => ~w(tavily exa brave serper jina firecrawl)}
    [{:command, "search.move", _, %{"dir" => -1}, _}] = SearchWeb.act(c, exa, :move_up)

    assert [{:toast, "readers have no order", :info}] =
             SearchWeb.act(c, row(SearchWeb.rows(c), "rec:search_provider:jina"), :move_up)
  end

  test "Space switches; enabling a key-needing engine without a key opens the paste first" do
    c = ctx()

    [{:command, "search.update", %{"kind" => "exa"}, %{"enabled" => false}, opts}] =
      SearchWeb.act(c, row(SearchWeb.rows(c), "rec:search_provider:exa"), :toggle)

    assert opts.expected == %{"fields" => %{"enabled" => true}}

    [{:toast, words, :info}, {:paste, target}] =
      SearchWeb.act(c, row(SearchWeb.rows(c), "rec:search_provider:brave"), :toggle)

    assert words == "Brave needs a key first · paste it and it turns on"
    assert target.action == "search.set_key" and target.attributes == %{"test_first" => false}

    assert [{:command, "search.update", %{"kind" => "brave"}, %{"enabled" => true}, _}] =
             target.then
  end

  test "the record page: key paste tests first when replacing; test words carry the plan warning" do
    c = record_ctx("tavily")
    rows = SearchWeb.record_rows(c, "search_provider", "tavily")
    assert text(row(rows, "info:search:head").value) == "search engine · tried first · global"

    [{:paste, target}] =
      SearchWeb.act(c, row(rows, "fld:search_provider:tavily:api_key"), :open_row)

    assert target.attributes == %{"test_first" => true}

    assert text(row(rows, "act:search.test").value) ==
             "searches “swarmcode deep research test” · uses 1 search from your Tavily plan"

    assert text(row(rows, "fld:search_provider:tavily:base_url").value) ==
             "https://api.tavily.com · the default"

    running =
      put_task(c, "t1", %{
        action: "search.test",
        target: %{"kind" => "tavily"},
        state: "running",
        elapsed_ms: 1_000
      })

    assert text(
             row(SearchWeb.record_rows(running, "search_provider", "tavily"), "act:search.test").value
           ) == "◷ searching · uses 1 search from your Tavily plan · 1 s"

    {state, id, task, _} = T.run(I.seed(), "search.test", %{"kind" => "tavily"})
    done = record_ctx("tavily", state) |> T.put(id, task, [])

    assert text(
             row(SearchWeb.record_rows(done, "search_provider", "tavily"), "act:search.test").value
           ) == "✓ 3 results · 612 ms · 18:42"

    failed =
      record_ctx("tavily")
      |> put_task("t2", %{
        action: "search.test",
        target: %{"kind" => "tavily"},
        state: "failed",
        message: "rate or plan limit (432)",
        at: "2026-09-25T18:43:00Z"
      })

    assert text(
             row(SearchWeb.record_rows(failed, "search_provider", "tavily"), "act:search.test").value
           ) == "✗ rate or plan limit (432) · 18:43"
  end

  test "a refused replacement keeps the old key; s saves it anyway" do
    {_s, id, task, _} =
      T.run(
        I.seed(),
        "search.set_key",
        %{"kind" => "tavily"},
        %{"test_first" => true},
        {:error, "401"},
        nil,
        [%{"slot" => "api_key", "value" => "tvly-new-0000000000000"}]
      )

    c = record_ctx("tavily") |> T.put(id, task, [])

    key =
      row(
        SearchWeb.record_rows(c, "search_provider", "tavily"),
        "fld:search_provider:tavily:api_key"
      )

    assert Enum.map(key.lines, &text/1) == [
             "The new key was refused (401).",
             "s save it anyway · Esc keep the old key"
           ]

    [{:command, "search.set_key", _, %{"test_first" => false}, %{secrets_from: :paste}}] =
      SearchWeb.act(c, key, :alt)
  end

  test "x removes a key after asking, and says the engine turns off" do
    c = record_ctx("tavily")

    key =
      row(
        SearchWeb.record_rows(c, "search_provider", "tavily"),
        "fld:search_provider:tavily:api_key"
      )

    [{:confirm, confirm, then: [{:command, "search.clear_key", _, _, _}]}] =
      SearchWeb.act(c, key, :delete)

    assert confirm.lines == [
             "Tavily will answer nothing until you paste a new key",
             "It is turned off with it."
           ]
  end

  test "base URL: blank goes back to the default, a bad URL stays with the message" do
    c = record_ctx("exa")

    url =
      row(SearchWeb.record_rows(c, "search_provider", "exa"), "fld:search_provider:exa:base_url")

    assert [{:row_error, _, "must start with http:// or https://"}] =
             SearchWeb.commit(c, url, "api.exa.ai")

    [{:command, "search.update", _, %{"base_url" => "https://proxy.test"}, _}] =
      SearchWeb.commit(c, url, " https://proxy.test/ ")

    assert SearchWeb.commit(c, url, "") == []
  end

  test "the reader row warns when Firecrawl reads without a key; no engine on says so" do
    values =
      Map.put(default_values(), "web.reader", %{
        key: "web.reader",
        value: "firecrawl",
        state: "ok"
      })

    c = ctx(I.seed(), values: values)
    reader = row(SearchWeb.rows(c), "key:web.reader")
    assert text(reader.value) == "Firecrawl — no key, falls back"

    assert Enum.map(reader.lines, &text/1) == [
             "! Page reader is Firecrawl but it has no key · pages use the plain fetch"
           ]

    state = I.seed()

    {{:ok, _}, state} =
      I.command(state, %{
        "action" => "search.update",
        "target" => %{"kind" => "tavily"},
        "attributes" => %{"enabled" => false}
      })

    {{:ok, _}, state} =
      I.command(state, %{
        "action" => "search.update",
        "target" => %{"kind" => "exa"},
        "attributes" => %{"enabled" => false}
      })

    assert text(row(SearchWeb.rows(ctx(state)), "info:search:none").value) ==
             "Agents cannot search the web: no search engine is on"
  end
end
