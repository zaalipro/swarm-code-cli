defmodule SwarmCode.Daemon.Service.Settings.C74ProvidersTest do
  @moduledoc "pass 74 S2-2/S2-3: the providers handler (§3.5.1) on a fixture database (pool 3)."
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Service.Settings.Providers, as: Handler
  alias SwarmCode.Domain.{Conversations, Providers, Settings}
  alias SwarmCode.Test.C74S2
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  @canary "sk-canary-7Q2X-DO-NOT-SHOW"

  setup_all do
    prior = Application.get_env(:swarm_code_daemon, :llm_providers)

    Application.put_env(:swarm_code_daemon, :llm_providers, %{
      "openai_compatible" => SwarmCode.Domain.LLM.OpenAI,
      "anthropic" => SwarmCode.Domain.LLM.Anthropic
    })

    on_exit(fn ->
      if prior,
        do: Application.put_env(:swarm_code_daemon, :llm_providers, prior),
        else: Application.delete_env(:swarm_code_daemon, :llm_providers)
    end)

    :ok
  end

  setup do
    fx = C74S2.repo!("c74-providers")
    data = C74S2.appendix_a!(fx)
    ctx = C74S2.context(data.ailogic, data.conversation)
    Map.merge(data, %{fx: fx, ctx: ctx})
  end

  defp run(action, c, opts), do: Handler.command(C74S2.command(action, opts), c.ctx)

  defp record_of({:ok, result}), do: result.record
  defp fields_of(result), do: record_of(result)["fields"]

  defp models_server(ids, status \\ 200) do
    HTTP.start(fn socket, _request, _n ->
      body =
        if status == 200,
          do: Jason.encode!(%{"data" => Enum.map(ids, &%{"id" => &1})}),
          else: Jason.encode!(%{"error" => %{"message" => "bad key"}})

      HTTP.respond(socket, status, body, [{"content-type", "application/json"}])
    end)
  end

  defp local_provider!(name, url, key \\ "sk-local-0000000000000000") do
    C74S2.provider!(%{name: name, base_url: url <> "/v1", api_key: key, models: ["m-1"]})
  end

  describe "records and record" do
    test "summaries mask the key and say whether the provider can answer", c do
      {:ok, body} = Handler.query("records", "providers", %{}, c.ctx)
      assert body["kind"] == "provider"
      assert body["total"] == 4
      by_name = Map.new(body["items"], &{&1["fields"]["name"], &1["fields"]})

      assert by_name["DeepSeek"]["api_key"] == %{"set" => true, "hint" => "a1b2"}
      assert by_name["DeepSeek"]["usable"] == true
      assert by_name["Ollama"]["usable"] == true
      assert by_name["Ollama"]["api_key"] == %{"set" => false, "hint" => nil}
      assert by_name["OpenRouter"]["usable"] == false
      assert by_name["DeepSeek"]["models_count"] == 2
      assert by_name["DeepSeek"]["last_test"] == nil
    end

    test "the record names where the provider is used", c do
      {:ok, record} = Handler.query("record", "provider", %{"id" => c.deepseek.id}, c.ctx)
      used = record["fields"]["used_by"]
      assert used["defaults"] == ["models.chat", "models.sub_agent"]
      assert used["research"] == []
      assert used["conversations"] == 1
      assert used["scheduled_tasks"] == 0

      assert record["fields"]["builtin_levels"] |> Enum.map(& &1["key"]) ==
               ~w(low medium high max)

      assert Enum.any?(record["fields"]["presets"], &(&1["id"] == "deepseek"))
      refute Enum.any?(record["fields"]["presets"], &(&1["id"] == "anthropic_adaptive"))
    end

    test "a gone provider is not_found", c do
      assert {:error, %{code: :not_found}} =
               Handler.query("record", "provider", %{"id" => Ecto.UUID.generate()}, c.ctx)
    end
  end

  describe "create and update" do
    test "create with a pasted key answers the masked record", c do
      result =
        run("provider.create", c,
          attributes: %{
            "name" => "Local",
            "kind" => "openai_compatible",
            "base_url" => "http://127.0.0.1:9/v1/",
            "models" => [" a ", "", "b"],
            "effort_levels" => nil
          },
          secrets: [%{slot: "api_key", value: " #{@canary} "}]
        )

      fields = fields_of(result)
      assert fields["api_key"] == %{"set" => true, "hint" => "SHOW"}
      assert fields["base_url"] == "http://127.0.0.1:9/v1"
      assert fields["models"] == ["a", "b"]
      assert Providers.get(fields["id"]).api_key == @canary
      refute inspect(result) =~ @canary
      refute Jason.encode!(record_of(result)) =~ @canary
    end

    test "the desktop changeset's words come back verbatim", c do
      assert {:error, %{field_errors: [%{target: "name", message: "has already been taken"}]}} =
               run("provider.create", c,
                 attributes: %{"name" => "DeepSeek", "base_url" => "https://x.test/v1"}
               )

      assert {:error, %{field_errors: errors}} =
               run("provider.create", c, attributes: %{"name" => "", "base_url" => "ftp://x"})

      assert %{target: "name", message: "can't be blank"} in errors
      assert %{target: "base_url", message: "must start with http:// or https://"} in errors

      assert {:error, %{field_errors: [%{target: "models", message: "already in the list"}]}} =
               run("provider.create", c,
                 attributes: %{
                   "name" => "Dup",
                   "base_url" => "https://x.test",
                   "models" => ["a", "a"]
                 }
               )

      assert {:error, %{field_errors: [%{target: "api_key"}]}} =
               run("provider.create", c,
                 attributes: %{
                   "name" => "Typed",
                   "base_url" => "https://x.test",
                   "api_key" => "sk-x"
                 }
               )
    end

    test "update writes with compare-and-set and answers a conflict with the fresh value", c do
      {:ok, result} =
        run("provider.update", c,
          target: %{"id" => c.openrouter.id},
          attributes: %{"default_model" => "or-1"},
          expected: %{"fields" => %{"default_model" => nil}}
        )

      assert result.status == :accepted
      assert Providers.get(c.openrouter.id).default_model == "or-1"

      # Changed elsewhere in the meantime.
      {:ok, _} = Providers.update(Providers.get(c.openrouter.id), %{default_model: "or-2"})

      {:ok, conflict} =
        run("provider.update", c,
          target: %{"id" => c.openrouter.id},
          attributes: %{"default_model" => "or-3"},
          expected: %{"fields" => %{"default_model" => "or-1"}}
        )

      assert conflict.status == :conflict
      assert [%{target: "default_model", status: :conflict, current: "or-2"}] = conflict.results
      assert Providers.get(c.openrouter.id).default_model == "or-2"

      {:ok, same} =
        run("provider.update", c,
          target: %{"id" => c.openrouter.id},
          attributes: %{"default_model" => "or-2"},
          expected: %{"fields" => %{"default_model" => "or-2"}}
        )

      assert same.status == :unchanged
    end

    test "update without expected is refused", c do
      assert {:error, %{code: :invalid}} =
               run("provider.update", c,
                 target: %{"id" => c.openrouter.id},
                 attributes: %{"name" => "X"}
               )
    end
  end

  describe "keys" do
    test "a first key (test_first false) is saved and never answered back", c do
      {:ok, result} =
        run("provider.set_key", c,
          target: %{"id" => c.openrouter.id},
          attributes: %{"test_first" => false},
          expected: %{"key" => %{"set" => false, "hint" => nil}},
          secrets: [%{slot: "api_key", value: @canary}]
        )

      assert result.status == :accepted
      assert result.record["fields"]["api_key"] == %{"set" => true, "hint" => "SHOW"}
      assert Providers.get(c.openrouter.id).api_key == @canary
      refute inspect(result) =~ @canary
      refute Jason.encode!(result.record) =~ @canary

      {:ok, again} =
        run("provider.set_key", c,
          target: %{"id" => c.openrouter.id},
          attributes: %{"test_first" => false},
          expected: %{"key" => %{"set" => false, "hint" => nil}},
          secrets: [%{slot: "api_key", value: @canary}]
        )

      assert again.status == :unchanged

      {:ok, records} = Handler.query("records", "providers", %{}, c.ctx)
      refute Jason.encode!(records) =~ @canary
    end

    test "a stale expected key is a conflict and writes nothing", c do
      {:ok, result} =
        run("provider.set_key", c,
          target: %{"id" => c.deepseek.id},
          attributes: %{"test_first" => false},
          expected: %{"key" => %{"set" => false, "hint" => nil}},
          secrets: [%{slot: "api_key", value: @canary}]
        )

      assert result.status == :conflict
      assert [%{current: %{"set" => true, "hint" => "a1b2"}}] = result.results
      assert Providers.get(c.deepseek.id).api_key == "sk-test-deepseek-00000000a1b2"
    end

    test "paste checks refuse before anything is written", c do
      assert {:error, %{message: "that is too short to be a key"}} =
               run("provider.set_key", c,
                 target: %{"id" => c.openrouter.id},
                 expected: %{"key" => %{"set" => false, "hint" => nil}},
                 secrets: [%{slot: "api_key", value: "short"}]
               )

      assert {:error, %{message: "paste only the key: it had 2 lines"}} =
               run("provider.set_key", c,
                 target: %{"id" => c.openrouter.id},
                 expected: %{"key" => %{"set" => false, "hint" => nil}},
                 secrets: [%{slot: "api_key", value: "sk-aaaaaaaa\nsk-bbbbbbbb"}]
               )
    end

    test "test_first with a refused key (loopback 401) keeps the stored key", c do
      server = models_server([], 401)
      provider = local_provider!("Gate", server.url, "sk-old-key-00000000wxyz")

      {:task, spec, result} =
        run("provider.set_key", c,
          target: %{"id" => provider.id},
          attributes: %{"test_first" => true},
          expected: %{"key" => %{"set" => true, "hint" => "wxyz"}},
          secrets: [%{slot: "api_key", value: @canary}]
        )

      assert result.status == :accepted
      assert spec.action == "provider.set_key"
      assert spec.timeout_ms == 15_000 and spec.cancellable?
      assert @canary in spec.redact
      refute inspect(spec) =~ @canary

      assert C74S2.run_task(spec) == {:error, "The new key was refused (401)."}
      assert Providers.get(provider.id).api_key == "sk-old-key-00000000wxyz"
      HTTP.stop(server)
    end

    test "test_first with an accepted key writes it after the test", c do
      server = models_server(["x-1", "x-2"])
      provider = local_provider!("Gate", server.url, "sk-old-key-00000000wxyz")

      {:task, spec, _} =
        run("provider.set_key", c,
          target: %{"id" => provider.id},
          attributes: %{"test_first" => true},
          expected: %{"key" => %{"set" => true, "hint" => "wxyz"}},
          secrets: [%{slot: "api_key", value: @canary}]
        )

      assert {:ok, %{"saved" => true, "count" => 2, "name" => "Gate"}} = C74S2.run_task(spec)
      assert Providers.get(provider.id).api_key == @canary
      assert_received {:http_request, 1, %{headers: %{"authorization" => "Bearer " <> @canary}}}
      HTTP.stop(server)
    end

    test "clear_key empties the key and answers set false", c do
      {:ok, result} =
        run("provider.clear_key", c,
          target: %{"id" => c.anthropic.id},
          expected: %{"key" => %{"set" => true, "hint" => "c3d4"}}
        )

      assert result.record["fields"]["api_key"] == %{"set" => false, "hint" => nil}
      assert Providers.get(c.anthropic.id).api_key == ""
    end
  end

  describe "delete" do
    test "replacements re-point the defaults in the same step", c do
      {:ok, result} =
        run("provider.delete", c,
          target: %{"id" => c.deepseek.id},
          attributes: %{
            "replacements" => %{
              "models.chat" => %{"provider_id" => c.anthropic.id, "model" => "claude-opus-5"},
              "models.sub_agent" => %{"provider_id" => c.ollama.id, "model" => "qwen3-coder"}
            }
          },
          expected: %{"updated_at" => DateTime.to_iso8601(c.deepseek.updated_at)}
        )

      assert result.status == :accepted
      assert result.message == "DeepSeek deleted"
      assert result.record == nil
      assert Enum.map(result.results, & &1.target) == ["models.chat", "models.sub_agent"]
      assert Providers.get(c.deepseek.id) == nil

      settings = Settings.get()

      assert {settings.default_chat_provider_id, settings.default_chat_model} ==
               {c.anthropic.id, "claude-opus-5"}

      assert {settings.default_swarm_provider_id, settings.default_swarm_model} ==
               {c.ollama.id, "qwen3-coder"}

      assert Conversations.get(c.conversation.id).chat_provider_id == nil
    end

    test "a moved updated_at is a conflict and deletes nothing", c do
      {:ok, _} = Providers.update(c.deepseek, %{default_model: "deepseek-v4-flash"})

      {:ok, result} =
        run("provider.delete", c,
          target: %{"id" => c.deepseek.id},
          expected: %{"updated_at" => DateTime.to_iso8601(c.deepseek.updated_at)}
        )

      assert result.status == :conflict
      assert Providers.get(c.deepseek.id)
    end

    test "a replacement naming the deleted provider is refused", c do
      assert {:error,
              %{
                field_errors: [
                  %{target: "models.chat", message: "that provider no longer exists"}
                ]
              }} =
               run("provider.delete", c,
                 target: %{"id" => c.deepseek.id},
                 attributes: %{
                   "replacements" => %{
                     "models.chat" => %{
                       "provider_id" => c.deepseek.id,
                       "model" => "deepseek-v4-pro"
                     }
                   }
                 },
                 expected: %{"updated_at" => DateTime.to_iso8601(c.deepseek.updated_at)}
               )
    end
  end

  describe "test and fetch tasks" do
    test "provider.test lists models and writes nothing", c do
      server = models_server(["a", "b", "c"])
      provider = local_provider!("Stub", server.url)

      {:task, spec, _} = run("provider.test", c, target: %{"id" => provider.id})
      assert spec.timeout_ms == 15_000 and spec.kind == :plain and spec.key == provider.id
      assert {:ok, %{"count" => 3, "ms" => ms}} = C74S2.run_task(spec)
      assert is_integer(ms)
      assert Providers.get(provider.id).models == ["m-1"]
      HTTP.stop(server)
    end

    test "provider.test of a draft with an unsaved key", c do
      server = models_server(["a"])

      {:task, spec, _} =
        run("provider.test", c,
          target: %{"draft" => true},
          attributes: %{"kind" => "openai_compatible", "base_url" => server.url <> "/v1"},
          secrets: [%{slot: "api_key", value: @canary}]
        )

      assert spec.key == "draft"
      assert {:ok, %{"count" => 1}} = C74S2.run_task(spec)
      assert_received {:http_request, 1, %{headers: %{"authorization" => "Bearer " <> @canary}}}
      HTTP.stop(server)
    end

    test "a 401 answers the domain's words, redacted", c do
      server = models_server([], 401)
      provider = local_provider!("Stub", server.url)
      {:task, spec, _} = run("provider.test", c, target: %{"id" => provider.id})

      assert C74S2.run_task(spec) ==
               {:error, "Unauthorized (401): check the API key for provider \"Stub\""}

      HTTP.stop(server)
    end

    test "fetch shows the difference and writes nothing until apply", c do
      server = models_server(["m-1", "m-2", "m-3"])

      provider =
        C74S2.provider!(%{
          name: "Stub",
          base_url: server.url <> "/v1",
          api_key: "sk-local-0000000000000000",
          models: ["m-1", "old"]
        })

      {:ok, conv} = Conversations.create(c.ailogic.id)
      {:ok, _} = Conversations.update(conv, %{chat_provider_id: provider.id, chat_model: "old"})

      {:task, spec, _} = run("provider.fetch_models", c, target: %{"id" => provider.id})
      assert spec.timeout_ms == 30_000
      {:ok, fetched} = C74S2.run_task(spec)

      assert fetched["added"] == 2 and fetched["removed"] == 1 and fetched["unchanged"] == 1
      assert fetched["removed_in_use"] == 1
      assert fetched["truncated"] == false

      assert fetched["rows"] == [
               %{"model" => "m-2", "change" => "new", "conversations" => 0},
               %{"model" => "m-3", "change" => "new", "conversations" => 0},
               %{"model" => "old", "change" => "gone", "conversations" => 1},
               %{"model" => "m-1", "change" => "same", "conversations" => 0}
             ]

      summary = spec.summary.(fetched)
      refute Map.has_key?(summary, "rows") or Map.has_key?(summary, "models")
      assert Providers.get(provider.id).models == ["m-1", "old"]

      ctx = %{
        c.ctx
        | task_results: %{
            {"provider.fetch_models", provider.id} => C74S2.task_entry("t-1", :done, fetched)
          }
      }

      {:ok, applied} =
        Handler.command(
          C74S2.command("provider.apply_models",
            target: %{"id" => provider.id},
            attributes: %{"fetch_task_id" => "t-1", "mode" => "replace"},
            expected: %{"fields" => %{"models" => ["m-1", "old"]}}
          ),
          ctx
        )

      assert applied.status == :accepted
      assert Providers.get(provider.id).models == ["m-1", "m-2", "m-3"]
      HTTP.stop(server)
    end

    test "a fetch longer than 2 000 is truncated, replace is refused, add fills up", c do
      ids = for i <- 1..2_500, do: "model-#{String.pad_leading(Integer.to_string(i), 4, "0")}"
      server = models_server(ids)
      provider = local_provider!("Big", server.url)

      {:task, spec, _} = run("provider.fetch_models", c, target: %{"id" => provider.id})
      {:ok, fetched} = C74S2.run_task(spec)
      assert fetched["truncated"] == true
      assert fetched["listed"] == 2_500
      assert fetched["kept"] == 2_000
      assert length(fetched["models"]) == 2_000

      ctx = %{
        c.ctx
        | task_results: %{
            {"provider.fetch_models", provider.id} => C74S2.task_entry("t-2", :done, fetched)
          }
      }

      apply = fn mode ->
        Handler.command(
          C74S2.command("provider.apply_models",
            target: %{"id" => provider.id},
            attributes: %{"fetch_task_id" => "t-2", "mode" => mode},
            expected: %{"fields" => %{"models" => ["m-1"]}}
          ),
          ctx
        )
      end

      assert {:ok,
              %{
                status: :rejected,
                message: "the list was longer than 2 000; add new ones instead"
              }} =
               apply.("replace")

      assert Providers.get(provider.id).models == ["m-1"]

      {:ok, added} = apply.("add")
      assert added.status == :accepted
      assert added.message =~ "1 not added: 2 000 models at most"
      models = Providers.get(provider.id).models
      assert length(models) == 2_000
      assert hd(models) == "m-1"
      HTTP.stop(server)
    end

    test "apply without the fetch in the cache asks to fetch again", c do
      assert {:error, %{code: :not_found, message: "fetch again first"}} =
               run("provider.apply_models", c,
                 target: %{"id" => c.deepseek.id},
                 attributes: %{"fetch_task_id" => "gone", "mode" => "add"},
                 expected: %{"fields" => %{"models" => []}}
               )
    end

    test "fetch_all reports progress per provider and writes nothing", c do
      Enum.each([c.deepseek, c.anthropic, c.ollama, c.openrouter], &Providers.delete/1)
      server = models_server(["a", "b"])
      one = local_provider!("One", server.url)
      two = local_provider!("Two", server.url)

      {:task, spec, _} = run("provider.fetch_all", c, [])
      assert spec.timeout_ms == 120_000
      {:ok, result} = C74S2.run_task(spec)

      assert_received {:progress, %{"done" => 0, "total" => 2}}
      assert_received {:progress, %{"done" => 1, "total" => 2}}
      assert_received {:progress, %{"done" => 2, "total" => 2}}
      assert Enum.map(result["providers"], & &1["name"]) == ["One", "Two"]
      assert Enum.all?(result["providers"], &(&1["state"] == "done" and &1["added"] == 2))
      assert result["changed"] == 2
      refute spec.summary.(result)["providers"] |> hd() |> Map.has_key?("models")
      assert Providers.get(one.id).models == ["m-1"]
      assert Providers.get(two.id).models == ["m-1"]
      HTTP.stop(server)
    end
  end

  describe "attention and glance" do
    test "AT2 for a failed last test, AT3 for a keyless default provider", c do
      ctx = %{
        c.ctx
        | task_results: %{
            {"provider.test", c.anthropic.id} =>
              C74S2.task_entry("t", :failed, nil,
                message: "Unauthorized (401): check the API key"
              )
          }
      }

      assert Handler.attention(c.ctx) == []

      [at2] = Handler.attention(ctx)
      assert at2.title == "Anthropic did not answer its last test"
      assert at2.severity == "error"

      {:ok, _} = Providers.update(c.deepseek, %{api_key: ""})

      assert [%{title: "DeepSeek has no key", reason: "a default model uses it"}] =
               Handler.attention(c.ctx)

      assert %{"providers" => %{"count" => 4, "failed" => 1, "never_tested" => 3}} =
               Handler.glance(ctx)
    end
  end
end
