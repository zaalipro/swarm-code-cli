defmodule SwarmCode.Daemon.Service.Settings.C74SearchTest do
  @moduledoc "pass 74 S2-6: search providers in settings (§3.5.3, AT6, AT15, AT17)."
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Service.Settings.Search, as: Handler
  alias SwarmCode.Domain.{Repo, Search, Settings}
  alias SwarmCode.Domain.Search.SearchProvider
  alias SwarmCode.Test.C74S2
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  @canary "sk-canary-7Q2X-DO-NOT-SHOW"

  setup do
    fx = C74S2.repo!("c74-search")
    data = C74S2.appendix_a!(fx)
    Map.merge(data, %{ctx: C74S2.context(data.ailogic, data.conversation)})
  end

  defp run(c, action, kind, opts \\ []) do
    Handler.command(C74S2.command(action, Keyword.put(opts, :target, %{"kind" => kind})), c.ctx)
  end

  defp key(kind), do: Search.get(kind) && Search.get(kind).api_key

  defp mask(kind) do
    {:ok, record} = Handler.query("record", "search_provider", %{"id" => kind}, %{})
    record["fields"]["api_key"]
  end

  defp tavily_server(status) do
    server =
      HTTP.start(fn socket, _request, _n ->
        body =
          if status == 200,
            do:
              Jason.encode!(%{
                "results" =>
                  for(
                    i <- 1..3,
                    do: %{"title" => "r#{i}", "url" => "https://e.test/#{i}", "content" => "c"}
                  )
              }),
            else: Jason.encode!(%{"detail" => "no"})

        HTTP.respond(socket, status, body, [{"content-type", "application/json"}])
      end)

    on_exit(fn -> HTTP.stop(server) end)
    server
  end

  defp kinds(page), do: Enum.map(page["items"], & &1["id"])

  describe "records" do
    test "every kind, placeholders synthesised without an insert (D24)", c do
      before = Repo.aggregate(SearchProvider, :count)
      {:ok, page} = Handler.query("records", "search_providers", %{}, c.ctx)
      assert Repo.aggregate(SearchProvider, :count) == before
      C74S2.declared!(page)

      assert kinds(page) == ~w(tavily exa brave serper jina firecrawl)
      by_kind = Map.new(page["items"], &{&1["id"], &1["fields"]})

      assert by_kind["tavily"]["api_key"] == %{"set" => true, "hint" => "e5f6"}
      assert by_kind["exa"]["api_key"] == %{"set" => true, "hint" => "g7h8"}
      assert by_kind["tavily"]["enabled"] and by_kind["tavily"]["persisted"]
      refute by_kind["brave"]["persisted"] or by_kind["brave"]["enabled"]
      assert by_kind["brave"]["position"] == 2
      assert by_kind["jina"]["role"] == "reader" and by_kind["jina"]["needs_key"] == false
      assert by_kind["firecrawl"]["needs_key"] and by_kind["serper"]["label"] == "Serper (Google)"
      assert by_kind["tavily"]["default_base_url"] =~ "tavily"
      refute inspect(page) =~ "tvly-test"
    end

    test "one record by kind; an unknown kind is not found", c do
      {:ok, record} = Handler.query("record", "search_provider", %{"id" => "brave"}, c.ctx)
      assert record["id"] == "brave" and record["kind"] == "search_provider"

      assert {:error, %{code: :not_found}} =
               Handler.query("record", "search_provider", %{"id" => "bing"}, c.ctx)

      assert {:error, %{code: :not_found}} = run(c, "search.update", "bing")
    end
  end

  describe "search.update" do
    test "a placeholder is created at its place; base URL trimmed; CAS on fields", c do
      {:ok, result} =
        run(c, "search.update", "serper",
          attributes: %{"base_url" => " https://proxy.test/serper/ "},
          expected: %{"fields" => %{"base_url" => nil}}
        )

      assert result.status == :accepted
      assert result.record["fields"]["persisted"]
      row = Search.get("serper")
      assert row.base_url == "https://proxy.test/serper" and row.position == 3

      {:ok, stale} =
        run(c, "search.update", "serper",
          attributes: %{"base_url" => "https://other.test"},
          expected: %{"fields" => %{"base_url" => nil}}
        )

      assert stale.status == :conflict
      assert [%{target: "base_url", current: "https://proxy.test/serper"}] = stale.results

      {:ok, same} =
        run(c, "search.update", "serper",
          attributes: %{"base_url" => "https://proxy.test/serper/"},
          expected: %{"fields" => %{"base_url" => "https://proxy.test/serper"}}
        )

      assert same.status == :unchanged

      assert {:error, %{field_errors: [%{target: "base_url"}]}} =
               run(c, "search.update", "serper",
                 attributes: %{"base_url" => "ftp://x"},
                 expected: %{"fields" => %{}}
               )
    end

    test "turning a key-needing kind on without a key is refused", c do
      assert {:error, %{code: :invalid, field_errors: [%{target: "enabled", message: msg}]}} =
               run(c, "search.update", "brave",
                 attributes: %{"enabled" => true},
                 expected: %{"fields" => %{"enabled" => false}}
               )

      assert msg == "is needed to enable brave"
      assert Search.get("brave") == nil

      {:ok, jina} =
        run(c, "search.update", "jina",
          attributes: %{"enabled" => true},
          expected: %{"fields" => %{"enabled" => false}}
        )

      assert jina.status == :accepted and jina.message == "Jina Reader on"

      assert {:error, %{code: :invalid}} =
               run(c, "search.update", "jina", attributes: %{"api_key" => "x"})
    end
  end

  describe "keys" do
    test "a direct paste saves, masks and answers unchanged the second time", c do
      cmd = [
        secrets: [%{slot: "api_key", value: " #{@canary} "}],
        expected: %{"key" => mask("brave")}
      ]

      {:ok, result} = run(c, "search.set_key", "brave", cmd)
      assert result.status == :accepted
      assert key("brave") == @canary
      assert result.record["fields"]["api_key"] == %{"set" => true, "hint" => "SHOW"}
      refute inspect(result) =~ @canary

      {:ok, again} =
        run(c, "search.set_key", "brave", Keyword.put(cmd, :expected, %{"key" => mask("brave")}))

      assert again.status == :unchanged

      {:ok, stale} =
        run(c, "search.set_key", "brave",
          secrets: [%{slot: "api_key", value: "brave-other-000000000000"}],
          expected: %{"key" => %{"set" => false, "hint" => nil}}
        )

      assert stale.status == :conflict
      assert key("brave") == @canary

      assert {:error, %{message: "paste only the key: it had 2 lines"}} =
               run(c, "search.set_key", "brave",
                 secrets: [%{slot: "api_key", value: "a1234567\nb1234567"}],
                 expected: %{"key" => mask("brave")}
               )
    end

    test "test first: an accepted key is saved; a refused one keeps the old key", c do
      ok = tavily_server(200)
      {:ok, _} = Search.upsert("tavily", %{base_url: ok.url})

      {:task, spec, result} =
        run(c, "search.set_key", "tavily",
          attributes: %{"test_first" => true},
          secrets: [%{slot: "api_key", value: @canary}],
          expected: %{"key" => mask("tavily")}
        )

      assert result.status == :accepted and spec.action == "search.set_key" and
               spec.key == "tavily"

      assert spec.timeout_ms == 20_000 and @canary in spec.redact
      refute inspect(spec) =~ @canary
      assert key("tavily") == "tvly-test-000000000000e5f6"
      assert {:ok, %{"saved" => true, "count" => 3}} = C74S2.run_task(spec)
      assert key("tavily") == @canary

      for {status, words} <- [
            {401, "The new key was refused (401)."},
            {432, "The new key was refused (rate or plan limit, 432)."}
          ] do
        bad = tavily_server(status)
        {:ok, _} = Search.upsert("tavily", %{base_url: bad.url})

        {:task, spec, _} =
          run(c, "search.set_key", "tavily",
            attributes: %{"test_first" => true},
            secrets: [%{slot: "api_key", value: "tvly-new-0000000000000#{status}"}],
            expected: %{"key" => mask("tavily")}
          )

        assert C74S2.run_task(spec) == {:error, words}
        assert key("tavily") == @canary
      end
    end

    test "clearing the key of an enabled key-needing engine turns it off", c do
      {:ok, result} = run(c, "search.clear_key", "tavily", expected: %{"key" => mask("tavily")})
      assert result.status == :accepted
      assert result.message == "Tavily key removed · Tavily is off: it needs a key"
      row = Search.get("tavily")
      assert row.api_key == "" and row.enabled == false

      {:ok, again} =
        run(c, "search.clear_key", "tavily",
          expected: %{"key" => %{"set" => false, "hint" => nil}}
        )

      assert again.status == :unchanged
      {:ok, none} = run(c, "search.clear_key", "brave", expected: %{"key" => mask("brave")})
      assert none.status == :unchanged and Search.get("brave") == nil
    end
  end

  describe "search.move" do
    test "swaps engines with CAS on the order", c do
      {:ok, page} = Handler.query("records", "search_providers", %{}, c.ctx)
      order = kinds(page)

      {:ok, moved} =
        run(c, "search.move", "exa", attributes: %{"dir" => -1}, expected: %{"order" => order})

      assert moved.status == :accepted and moved.message == "Exa moved up"
      assert [%{target: "order", value: ["exa", "tavily" | _]}] = moved.results

      {:ok, stale} =
        run(c, "search.move", "exa", attributes: %{"dir" => 1}, expected: %{"order" => order})

      assert stale.status == :conflict
      assert [%{current: ["exa", "tavily" | _]}] = stale.results

      {:ok, edge} =
        run(c, "search.move", "exa",
          attributes: %{"dir" => -1},
          expected: %{"order" => ["exa", "tavily" | Enum.drop(order, 2)]}
        )

      assert edge.status == :unchanged

      assert {:error, %{message: "readers have no order"}} =
               run(c, "search.move", "jina",
                 attributes: %{"dir" => -1},
                 expected: %{"order" => order}
               )
    end
  end

  describe "search.test" do
    test "engines answer {count, ms}; failures carry the domain's words; nothing is written", c do
      ok = tavily_server(200)

      {:task, spec, _} =
        run(c, "search.test", "tavily",
          attributes: %{"base_url" => ok.url},
          secrets: [%{slot: "api_key", value: @canary}]
        )

      assert spec.action == "search.test" and spec.timeout_ms == 20_000
      assert {:ok, %{"count" => 3, "ms" => ms}} = C74S2.run_task(spec)
      assert is_integer(ms)
      assert key("tavily") == "tvly-test-000000000000e5f6"
      assert Search.get("tavily").base_url == nil

      assert_received {:http_request, 1, %{headers: %{"authorization" => "Bearer " <> @canary}}}

      limited = tavily_server(432)
      {:task, spec, _} = run(c, "search.test", "tavily", attributes: %{"base_url" => limited.url})
      assert C74S2.run_task(spec) == {:error, "Tavily rate or plan limit (432)"}
    end
  end

  describe "attention and glance" do
    test "Appendix A raises nothing", c do
      assert Handler.attention(c.ctx) == []

      assert %{
               "search" => %{
                 "on" => 2,
                 "engines" => 4,
                 "first" => "Tavily",
                 "reader" => "web_fetch"
               }
             } = Handler.glance(c.ctx)
    end

    test "AT6 with no engine on, AT15 with a keyless Firecrawl reader, AT17 after a failed test",
         c do
      {:ok, _} = Search.upsert("tavily", %{enabled: false})
      {:ok, _} = Search.upsert("exa", %{enabled: false})
      {:ok, _} = Settings.update(%{research_reader: "firecrawl"})

      assert [
               %{
                 id: "AT6",
                 title: "Agents cannot search the web",
                 reason: "no search engine is on"
               },
               %{
                 id: "AT15",
                 title: "Page reader is Firecrawl but it has no key",
                 reason: "pages use the plain fetch",
                 target: %{"id" => "firecrawl"}
               }
             ] = Handler.attention(c.ctx)

      {:ok, _} = Search.upsert("exa", %{enabled: true})

      ctx = %{
        c.ctx
        | task_results: %{
            {"search.test", "exa"} =>
              C74S2.task_entry("t1", "failed", nil, message: "Exa rejected the API key (401)")
          }
      }

      assert [
               %{id: "AT15"},
               %{
                 id: "AT17",
                 title: "Exa did not answer its last test",
                 reason: "Exa rejected the API key (401)"
               }
             ] =
               Handler.attention(ctx)

      assert %{"search" => %{"failed" => 1}} = Handler.glance(ctx)
    end
  end
end
