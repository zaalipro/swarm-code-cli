defmodule SwarmCodeCLI.UI.Settings.Sections.C74ProvidersTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations, as: I
  alias SwarmCodeCLI.UI.Settings.Sections.Providers
  alias SwarmCodeCLI.Test.C74U2Tasks, as: T
  import SwarmCodeCLI.Test.C74U2Ctx
  alias SwarmCodeCLI.Test.C74U2Ctx.Page

  @ids I.ids()

  defp row(rows, id),
    do:
      Enum.find(rows, &(&1.id == id)) ||
        flunk("no row #{id} in #{inspect(Enum.map(rows, & &1.id))}")

  defp record_ctx(id, opts \\ []) do
    state = Keyword.get(opts, :state, I.seed())

    ctx(
      state,
      [records: [{"provider", id}], page: Page.at(:providers, {"provider", id}, opts[:sub])] ++
        Keyword.drop(opts, [:sub, :state])
    )
  end

  defp record_rows(c, id), do: Providers.record_rows(c, "provider", id)

  describe "list page (U2-3)" do
    test "a table of providers with key state, models and last test" do
      rows = Providers.rows(ctx())
      deepseek = row(rows, "rec:provider:#{@ids.deepseek}")

      assert Enum.map(deepseek.columns, &elem(&1, 0)) == [
               "DeepSeek",
               "OpenAI-compatible",
               "●●●●●●●● set · ends a1b2",
               "2 models",
               "not tested this session"
             ]

      assert Enum.map(deepseek.columns, &elem(&1, 2)) == [1, 4, 2, 3, 5]

      assert Enum.at(row(rows, "rec:provider:#{@ids.ollama}").columns, 2) |> elem(0) ==
               "no key · local"

      assert row(rows, "rec:provider:#{@ids.openrouter}").marks == [:attention]
      assert Providers.loads(ctx()) == [{:records, "providers", %{}}]
      assert Providers.counts(ctx()) == %{records: 4}
    end

    test "an empty database says how to add one; loading shows the ellipsis" do
      c = ctx(I.seed(), kinds: [])
      assert Enum.any?(Providers.rows(c), &(&1.id == "info:loading"))
      empty = put_in(ctx().data.records[{"providers", %{}}].items, [])
      assert text(row(Providers.rows(empty), "info:empty").value) =~ "a adds one from a preset"
    end

    test "the environment row appears when onboarding variables are set" do
      c = put_in(ctx().launch_facts, %{env: %{"SWARM_API_KEY" => "set"}})
      env = row(Providers.rows(c), "info:environment")

      assert text(hd(env.lines)) ==
               "used only when no provider can answer; nothing is saved from them"
    end

    test "a opens the presets in §2.3's order and a pick starts a draft" do
      [{:picker, picker}] =
        Providers.act(ctx(), row(Providers.rows(ctx()), "act:providers.add"), :open_row)

      assert Enum.map(picker.options, & &1.label) == [
               "Anthropic",
               "OpenAI",
               "OpenRouter",
               "DeepSeek",
               "llmotions",
               "Ollama",
               "LM Studio",
               "Other"
             ]

      assert [{:draft_discard, "provider"}, {:draft_put, "provider", fields}, {:open, page}] =
               Providers.start_draft("deepseek")

      assert fields["base_url"] == "https://api.deepseek.com/v1" and
               fields["preset"] == "deepseek"

      assert page.record == {"provider", "draft"}
    end

    test "fetch every provider's models is a task with its words" do
      c = ctx()

      assert [{:task, "provider.fetch_all", nil, %{}}] =
               Providers.act(c, row(Providers.rows(c), "act:providers.fetch_all"), :open_row)

      {_s, id, task, rows} = T.run(I.seed(), "provider.fetch_all", nil)
      c = T.put(c, id, task, rows)

      assert text(row(Providers.rows(c), "act:providers.fetch_all").value) =~
               "✓ 4 providers · 1 changed lists"
    end
  end

  describe "the draft (U2-3)" do
    defp draft_ctx(fields, extra \\ %{}) do
      ctx(I.seed(), page: Page.at(:providers, {"provider", "draft"}))
      |> put_layer(:drafts, %{
        "provider" => Map.merge(%{fields: fields, secrets: %{}, errors: %{}, dirty?: true}, extra)
      })
    end

    test "Ctrl-S creates it with the preset's levels and the pasted key from the draft" do
      [_, {:draft_put, "provider", fields}, _] = Providers.start_draft("deepseek")
      c = draft_ctx(fields)
      rows = Providers.record_rows(c, "provider", "draft")

      assert text(row(rows, "fld:provider:draft:effort_levels").value) ==
               "DeepSeek · from the preset"

      assert Providers.title(c) == "New provider · unsaved · Ctrl-S creates it · Esc discards"

      [{:command, "provider.create", nil, attrs, opts}] =
        Providers.act(c, row(rows, "act:provider.create"), :save)

      assert attrs["name"] == "DeepSeek" and attrs["base_url"] == "https://api.deepseek.com/v1"
      assert attrs["effort_levels"] == Enum.find(I.presets(), &(&1["id"] == "deepseek"))["levels"]
      assert opts.secrets_from == {:draft, "provider"}

      # cli74 G1 (QA F-1): the created provider's page replaces the draft's and the draft goes.
      assert {:discard_draft, "provider",
              then: [
                :back,
                {:open_record, :providers, "provider",
                 then: [{:task, "provider.test", %{"id" => :record_id}, %{}}]}
              ]} = opts.after

      assert opts.errors_to == {:draft, "provider"}
    end

    test "a built-in preset sends no levels; a field error lands under its row" do
      [_, {:draft_put, "provider", fields}, _] = Providers.start_draft("ollama")
      c = draft_ctx(fields, %{errors: %{"name" => "has already been taken"}})
      rows = Providers.record_rows(c, "provider", "draft")
      assert text(row(rows, "fld:provider:draft:effort_levels").value) == "built-in levels"
      name = row(rows, "fld:provider:draft:name")
      assert name.lines == [[{"✗ has already been taken", :error}]] and :invalid in name.marks
      [{:command, _, _, attrs, _}] = Providers.act(c, row(rows, "act:provider.create"), :open_row)
      assert attrs["effort_levels"] == nil
    end

    test "draft fields go into the draft; the key is pasted into it" do
      c = draft_ctx(%{"name" => "X"})
      rows = Providers.record_rows(c, "provider", "draft")

      assert Providers.commit(c, row(rows, "fld:provider:draft:name"), "Y") == [
               {:draft_put, "provider", %{"name" => "Y"}}
             ]

      [{:paste, target}] = Providers.act(c, row(rows, "fld:provider:draft:api_key"), :open_row)
      assert target.draft == "provider" and target.slot == "api_key"
    end
  end

  describe "the record page (U2-4)" do
    test "F5 rows: connection, key, test, models, effort levels, used by, danger" do
      c = record_ctx(@ids.deepseek)
      ids = Enum.map(record_rows(c, @ids.deepseek), & &1.id)

      assert ids == [
               "info:head:#{@ids.deepseek}",
               "head:connection",
               "fld:provider:#{@ids.deepseek}:name",
               "fld:provider:#{@ids.deepseek}:kind",
               "fld:provider:#{@ids.deepseek}:base_url",
               "fld:provider:#{@ids.deepseek}:api_key",
               "act:provider.test",
               "head:models",
               "fld:provider:#{@ids.deepseek}:default_model",
               "fld:provider:#{@ids.deepseek}:models",
               "act:provider.fetch_models",
               "fld:provider:#{@ids.deepseek}:effort_levels",
               "head:used by",
               "info:used_by",
               "head:danger",
               "act:provider.delete"
             ]

      rows = record_rows(c, @ids.deepseek)

      assert text(row(rows, "fld:provider:#{@ids.deepseek}:api_key").value) ==
               "●●●●●●●● set · ends a1b2 · stored in SwarmCode's database"

      assert text(row(rows, "fld:provider:#{@ids.deepseek}:effort_levels").value) ==
               "DeepSeek V4 · 3 levels"

      assert text(row(rows, "info:used_by").value) ==
               "the chat default · the sub-agent default · 12 conversations · 2 scheduled tasks"

      assert text(row(rows, "info:head:#{@ids.deepseek}").value) ==
               "OpenAI-compatible · global · 12 conversations use it"
    end

    test "fallbacks only for Anthropic; forget caps only after a refusal" do
      rows = record_rows(record_ctx(@ids.anthropic), @ids.anthropic)
      assert Enum.any?(rows, &(&1.id == "fld:provider:#{@ids.anthropic}:fallbacks"))
      assert text(row(rows, "act:provider.forget_caps").value) == "it refused prompt caching"

      refute Enum.any?(
               record_rows(record_ctx(@ids.deepseek), @ids.deepseek),
               &(&1.id =~ "fallbacks")
             )
    end

    test "a field commit writes with CAS on the value read, undoable" do
      c = record_ctx(@ids.deepseek)
      name = row(record_rows(c, @ids.deepseek), "fld:provider:#{@ids.deepseek}:name")

      [{:command, "provider.update", %{"id" => id}, %{"name" => "DS"}, opts}] =
        Providers.commit(c, name, " DS ")

      assert id == @ids.deepseek
      assert opts.expected == %{"fields" => %{"name" => "DeepSeek"}}
      assert opts.write_key == {:record, "provider", @ids.deepseek, "name"}

      assert {:command, "provider.update", _, %{"name" => "DeepSeek"},
              %{expected: %{"fields" => %{"name" => "DS"}}}} = opts.undo

      assert Providers.commit(c, name, "DeepSeek") == []
    end

    test "a kind change asks first" do
      c = record_ctx(@ids.deepseek)
      kind = row(record_rows(c, @ids.deepseek), "fld:provider:#{@ids.deepseek}:kind")

      [{:confirm, confirm, then: [{:command, "provider.update", _, %{"kind" => "anthropic"}, _}]}] =
        Providers.commit(c, kind, "anthropic")

      assert confirm.title == "Switch DeepSeek to Anthropic?"
      assert confirm.lines == ["The effort levels go back to the built-in ones for Anthropic."]
    end

    test "the key: a first key saves then tests; a replacement is tested first" do
      c = record_ctx(@ids.openrouter)
      key = row(record_rows(c, @ids.openrouter), "fld:provider:#{@ids.openrouter}:api_key")
      [{:paste, target}] = Providers.act(c, key, :open_row)
      assert target.attributes == %{"test_first" => false}
      assert target.then == [{:task, "provider.test", %{"id" => @ids.openrouter}, %{}}]

      c = record_ctx(@ids.deepseek)
      key = row(record_rows(c, @ids.deepseek), "fld:provider:#{@ids.deepseek}:api_key")
      [{:paste, target}] = Providers.act(c, key, :open_row)
      assert target.attributes == %{"test_first" => true} and target.then == []
      assert target.expected == %{"key" => %{"set" => true, "hint" => "a1b2"}}
      assert target.action == "provider.set_key" and target.slot == "api_key"
    end

    test "a refused replacement keeps the old key and s sends test_first false" do
      {_s, id, task, _} =
        T.run(
          I.seed(),
          "provider.set_key",
          %{"id" => @ids.deepseek},
          %{"test_first" => true},
          {:error, "401"},
          nil,
          [%{"slot" => "api_key", "value" => "sk-new-0000000000000000"}]
        )

      c = record_ctx(@ids.deepseek) |> T.put(id, task, [])
      # cli74 F16: the refusal and its keys show while the refused paste
      # waits (after Esc nothing is left to save).
      assert row(record_rows(c, @ids.deepseek), "fld:provider:#{@ids.deepseek}:api_key").lines ==
               []

      c = with_refused_paste(c, "fld:provider:#{@ids.deepseek}:api_key")
      key = row(record_rows(c, @ids.deepseek), "fld:provider:#{@ids.deepseek}:api_key")

      assert Enum.map(key.lines, &text/1) == [
               "The new key was refused (401).",
               "s save it anyway · Esc keep the old key"
             ]

      assert text(key.value) =~ "ends a1b2"

      [{:command, "provider.set_key", _, %{"test_first" => false}, opts}] =
        Providers.act(c, key, :alt)

      assert opts.secrets_from == :paste
    end

    test "x on a set key asks, then clears with CAS" do
      c = record_ctx(@ids.deepseek)
      key = row(record_rows(c, @ids.deepseek), "fld:provider:#{@ids.deepseek}:api_key")

      [{:confirm, confirm, then: [{:command, "provider.clear_key", _, _, opts}]}] =
        Providers.act(c, key, :delete)

      assert confirm.title == "Remove DeepSeek's API key?"

      assert confirm.lines == [
               "Requests to api.deepseek.com will be refused until you paste a new key"
             ]

      assert opts.expected == %{"key" => %{"set" => true, "hint" => "a1b2"}}
    end

    test "fetch shows the exact difference; a applies all, + adds the new ones" do
      {_s, id, task, rows} = T.run(I.seed(), "provider.fetch_models", %{"id" => @ids.deepseek})
      c = record_ctx(@ids.deepseek) |> T.put(id, task, rows)
      page = record_rows(c, @ids.deepseek)
      assert text(row(page, "item:diff:deepseek-v4-lite").value) == "+ deepseek-v4-lite  new"

      assert text(row(page, "item:diff:deepseek-v4-flash").value) ==
               "− deepseek-v4-flash  not listed any more · 3 conversations use it"

      same = row(page, "info:diff:same")
      assert text(same.value) == "1 unchanged"

      assert text(hd(same.lines)) ==
               "a apply all   + add the new ones only   Esc keep the old list"

      assert text(row(page, "fld:provider:#{@ids.deepseek}:models").value) ==
               "2 → 3 after this fetch"

      assert text(row(page, "act:provider.fetch_models").value) =~
               "✓ 2 models from api.deepseek.com · 380 ms"

      [
        {:command, "provider.apply_models", _, %{"fetch_task_id" => ^id, "mode" => "replace"},
         opts}
      ] = Providers.act(c, same, :add)

      assert opts.expected == %{
               "fields" => %{"models" => ["deepseek-v4-pro", "deepseek-v4-flash"]}
             }

      [{:command, "provider.apply_models", _, %{"mode" => "add"}, _}] =
        Providers.act(c, same, :add_key)
    end

    test "a truncated fetch offers only adding" do
      {_s, id, task, rows} =
        T.run(I.seed(), "provider.fetch_models", %{"id" => @ids.ollama}, %{
          "listed" => for(i <- 1..2_100, do: "m#{i}")
        })

      c = record_ctx(@ids.ollama) |> T.put(id, task, rows)
      page = record_rows(c, @ids.ollama)
      same = row(page, "info:diff:same")
      assert text(hd(same.lines)) == "+ add the new ones only   Esc keep the old list"

      assert [{:toast, "the list was longer than 2 000; add new ones instead", :warning}] =
               Providers.act(c, same, :add)

      assert Enum.any?(page, &(&1.id == "info:diff:truncated"))
    end

    test "a test's result stays on its row" do
      {_s, id, task, _} = T.run(I.seed(), "provider.test", %{"id" => @ids.deepseek})
      c = record_ctx(@ids.deepseek) |> T.put(id, task, [])

      assert text(row(record_rows(c, @ids.deepseek), "act:provider.test").value) ==
               "✓ listed 2 models in 412 ms · #{local_hhmm(18, 42)}"

      running =
        record_ctx(@ids.deepseek)
        |> put_task("r", %{
          action: "provider.test",
          target: %{"id" => @ids.deepseek},
          state: "running",
          elapsed_ms: 2_000
        })

      test_row = row(record_rows(running, @ids.deepseek), "act:provider.test")
      assert text(test_row.value) == "◷ testing the connection · 2 s"
      assert text(test_row.tag) == "c stop"
    end

    test "use for new chats appears on a usable provider that is not the chat default" do
      c = record_ctx(@ids.anthropic)
      use = row(record_rows(c, @ids.anthropic), "act:provider.use_for_chats")
      assert use.label == "▸ Use Anthropic · claude-sonnet-5 for new chats"
      pair = %{"provider_id" => @ids.anthropic, "model" => "claude-sonnet-5"}

      assert Providers.act(c, use, :open_row) == [
               {:patch, "models.chat", pair},
               {:patch, "models.sub_agent", pair}
             ]

      refute Enum.any?(
               record_rows(record_ctx(@ids.openrouter), @ids.openrouter),
               &(&1.id == "act:provider.use_for_chats")
             )
    end

    test "delete: a provider that serves defaults needs every replacement" do
      c = record_ctx(@ids.deepseek)

      [{:open, page}] =
        Providers.act(c, row(record_rows(c, @ids.deepseek), "act:provider.delete"), :delete)

      assert page.sub == :delete

      c = record_ctx(@ids.deepseek, sub: :delete)
      rows = record_rows(c, @ids.deepseek)

      assert Enum.map(Enum.filter(rows, &(&1.kind == :field)), & &1.key) == [
               "models.chat",
               "models.sub_agent"
             ]

      assert row(rows, "act:delete:confirm").state == :disabled

      pair = %{"provider_id" => @ids.anthropic, "model" => "claude-opus-5"}
      chat = row(rows, "fld:replacement:models.chat")

      assert [{:stage, {"provider", _}, %{"replacements" => %{"models.chat" => ^pair}}}] =
               Providers.commit(c, chat, pair)

      c =
        put_layer(c, :staged, %{
          {"provider", @ids.deepseek} => %{
            "replacements" => %{"models.chat" => pair, "models.sub_agent" => pair}
          }
        })

      rows = record_rows(c, @ids.deepseek)
      assert row(rows, "act:delete:confirm").state == :normal

      [{:command, "provider.delete", _, %{"replacements" => reps}, opts}, :back] =
        Providers.act(c, row(rows, "act:delete:confirm"), :delete)

      assert Map.keys(reps) == ["models.chat", "models.sub_agent"]
      assert opts.expected == %{"updated_at" => "2026-09-25T18:40:00Z#0"}
    end

    test "delete: a provider nothing depends on asks in a dialog" do
      c = record_ctx(@ids.openrouter)

      [{:confirm, confirm, then: [{:command, "provider.delete", _, %{"replacements" => %{}}, _}]}] =
        Providers.act(c, row(record_rows(c, @ids.openrouter), "act:provider.delete"), :delete)

      assert confirm.title == "Delete OpenRouter?" and confirm.letter == "D" and
               confirm.undoable? == false

      assert "its API key is deleted with it" in confirm.lines
    end

    test "the models list: remove, move, add with the list rules" do
      c = record_ctx(@ids.deepseek, sub: :models)
      rows = record_rows(c, @ids.deepseek)
      assert [_, "item:models:0", "item:models:1", "act:models.add"] = Enum.map(rows, & &1.id)

      [{:command, "provider.update", _, %{"models" => ["deepseek-v4-pro"]}, _}] =
        Providers.act(c, row(rows, "item:models:1"), :delete)

      [
        {:command, "provider.update", _, %{"models" => ["deepseek-v4-flash", "deepseek-v4-pro"]},
         _}
      ] = Providers.act(c, row(rows, "item:models:0"), :move_down)

      assert [{:toast, "already in the list", :error}] =
               Providers.commit(c, row(rows, "act:models.add"), "deepseek-v4-pro")

      [{:command, _, _, %{"models" => [_, _, "deepseek-v4-lite"]}, _}] =
        Providers.commit(c, row(rows, "act:models.add"), "deepseek-v4-lite")
    end

    test "a provider deleted while its page is open says so" do
      c = record_ctx(@ids.deepseek)
      c = put_in(c.data.record, %{})
      c = put_in(c.data.records[{"providers", %{}}].items, [])
      assert [%{id: "info:gone"}] = record_rows(c, @ids.deepseek)
    end
  end

  defp with_refused_paste(ctx, row_id) do
    paste = %SwarmCodeCLI.UI.Settings.Paste{
      target: %{row_id: row_id},
      bytes: "sk-new-0000000000000000",
      refused: {:replacement, "The new key was refused (401)."}
    }

    %{ctx | layer: Map.put(ctx.layer || %{}, :paste, paste)}
  end
end
