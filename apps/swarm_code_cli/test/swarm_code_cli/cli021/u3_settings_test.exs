defmodule SwarmCodeCLI.Cli021.U3SettingsTest do
  # cli021 U3: the per-model context window is a visible, editable row for
  # each model the conversation uses (1M by default, K1); a fetch's result
  # or error is shown where the fetch was started (C1's words).
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.C74U3Helpers, except: [row: 2]
  import SwarmCodeCLI.Test.C74U2Ctx

  alias SwarmCodeCLI.Test.C74U2Ctx.Page
  alias SwarmCodeCLI.Test.C74U2Tasks, as: T
  alias SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations, as: I
  alias SwarmCodeCLI.UI.Settings.Sections.{ModelsEffort, Pricing, Providers}
  alias SwarmCodeCLI.UI.Settings.Nav

  @deepseek I.ids().deepseek

  defp record_ctx(state \\ I.seed()),
    do:
      ctx(state,
        records: [{"provider", @deepseek}],
        page: Page.at(:providers, {"provider", @deepseek})
      )

  defp find(rows, id),
    do:
      Enum.find(rows, &(&1.id == id)) ||
        flunk("no row #{id}: #{inspect(Enum.map(rows, & &1.id))}")

  describe "context windows" do
    test "1M is the default the pricing table and row page name" do
      rows = Pricing.rows(ctx())
      flash = find(rows, "rec:pricing_row:deepseek-v4-flash")
      assert {"1M default", :text_faint, 4} in flash.columns

      page = Pricing.record_rows(ctx(), "pricing_row", "deepseek-v4-flash")
      cell = find(page, "fld:pricing_row:deepseek-v4-flash:context_window")
      assert text(cell.value) == "1M default"
      {_editor, opts} = cell.editor
      assert opts.null_label == "1M default"
    end

    test "a row per model this conversation uses, on Models & effort" do
      {state, _fake} = opened(:models_effort)
      ids = Enum.map(rows(state), & &1.id)
      assert "head:context windows" in ids
      # cli021 qa: the windows sit with the models, before the danger group.
      assert Enum.find_index(ids, &(&1 == "head:context windows")) <
               Enum.find_index(ids, &(&1 == "head:danger"))

      # This conversation's worker follows its chat model: one row, both slots.
      pro = find(rows(state), "ctx:deepseek-v4-pro")
      assert pro.label == "deepseek-v4-pro"
      assert words(pro.value) =~ "1M default"
      assert words(pro.tag) == "chat · worker"
      assert Enum.count(rows(state), &String.starts_with?(&1.id, "ctx:")) == 1

      assert {SwarmCodeCLI.UI.Settings.Editors.Number, %{min: 8_000, max: 2_000_000}} =
               pro.editor
    end

    test "a priced model's window writes its price row with CAS; r goes back to 1M" do
      {state, _fake} = opened(:models_effort)
      state = Nav.put_cursor(state, "ctx:deepseek-v4-pro")
      row = Nav.current(state)

      {_state, effects} = SwarmCodeCLI.UI.Reducer.Settings.Edit.commit(state, row, 1_000_000)

      assert [%{"attributes" => attrs, "expected" => expected}] =
               commands(effects, "pricing.put_row")

      assert attrs["model"] == "deepseek-v4-pro"
      assert attrs["context_window"] == 1_000_000
      assert attrs["input"] == 0.27
      assert expected == %{"row" => %{"input" => 0.27, "output" => 1.1}}

      ops = ModelsEffort.commit(ctx_of(state), row, 100)
      assert [{:row_error, "ctx:deepseek-v4-pro", message}] = ops
      assert message =~ "between 8000 and 2000000"

      # `r` on a set window writes nil (the 1M default) with CAS on the row as read;
      # on a window already at the default it does nothing.
      opus = %SwarmCodeCLI.UI.Settings.Row{
        id: "ctx:claude-opus-5",
        target: {:context_window, "claude-opus-5"}
      }

      assert [
               {:command, "pricing.put_row", nil,
                %{"model" => "claude-opus-5", "context_window" => nil},
                %{expected: %{"row" => %{"context_window" => 200_000}}}}
             ] = ModelsEffort.act(ctx(), opus, :reset)

      assert [] = ModelsEffort.act(ctx_of(state), row, :reset)
    end

    test "an unpriced model opens its price draft, where the window is set with the prices" do
      ops = ModelsEffort.window_ops_for_unpriced("claude-sonnet-5")
      assert {:draft_put, "pricing_row", %{"model" => "claude-sonnet-5"}} = Enum.at(ops, 1)
      assert {:open, %{section: :pricing}} = List.last(ops)
    end

    test "a model past the loaded page of prices is not called unpriced" do
      c = ctx()
      key = {"pricing_rows", %{}}
      page = c.data.records[key] || flunk("no pricing page in the ctx")
      c = put_in(c.data.records[key], Map.merge(page, %{total: 250, next_cursor: "200"}))

      assert {:unknown, nil} = Pricing.window(c, "some-model-on-page-two")
      assert {:priced, nil} = Pricing.window(c, "deepseek-v4-flash")
      assert {:error, _} = Pricing.window_ops(c, "some-model-on-page-two", 64_000)
    end
  end

  describe "a fetch's result where it was started" do
    test "one provider: the models in words" do
      {_s, id, task, rows} = T.run(I.seed(), "provider.fetch_models", %{"id" => @deepseek})
      c = record_ctx() |> T.put(id, task, rows)
      page = Providers.record_rows(c, "provider", @deepseek)
      assert text(find(page, "act:provider.fetch_models").value) =~ ~r/✓ \d+ models? · /
    end

    test "the service's words win; a failure says its sentence" do
      saved = %{
        action: "provider.fetch_models",
        target: %{"id" => @deepseek},
        state: "done",
        summary: %{
          "listed" => 12,
          "added" => 3,
          "removed" => 2,
          "saved" => true,
          "words" => "12 models · 3 new · 2 removed"
        }
      }

      c = record_ctx() |> put_task("t1", saved)
      page = Providers.record_rows(c, "provider", @deepseek)

      assert text(find(page, "act:provider.fetch_models").value) =~
               "✓ 12 models · 3 new · 2 removed"

      # saved: nothing waits to be applied
      refute Enum.any?(page, &String.starts_with?(&1.id, "item:diff:"))

      failed = %{
        action: "provider.fetch_models",
        target: %{"id" => @deepseek},
        state: "failed",
        message: "the key was refused (401)"
      }

      c = record_ctx() |> put_task("t2", failed)
      page = Providers.record_rows(c, "provider", @deepseek)
      assert text(find(page, "act:provider.fetch_models").value) =~ "the key was refused (401)"
    end

    test "every provider: the total in words and one line per provider" do
      {_s, id, task, rows} = T.run(I.seed(), "provider.fetch_all", nil)
      c = T.put(ctx(), id, task, rows)
      row = find(Providers.rows(c), "act:providers.fetch_all")
      assert text(row.value) =~ ~r/✓ \d+ providers · /
      lines = Enum.map(row.lines, &text/1)
      assert Enum.any?(lines, &(&1 =~ "DeepSeek"))
      assert Enum.any?(lines, &(&1 =~ "the key was refused (401)"))
    end

    test "the model picker's provider heading says it too" do
      done = %{
        action: "provider.fetch_models",
        target: %{"id" => I.ids().anthropic},
        state: "done",
        summary: %{"listed" => 12, "added" => 3, "removed" => 0, "saved" => true}
      }

      c = ctx() |> put_task("pf", done)
      row = %{key: "models.chat", label: "Chat model"}
      current = %{"provider_id" => @deepseek, "model" => "deepseek-v4-pro"}
      {:ok, s} = SwarmCodeCLI.UI.Settings.ModelPicker.init(row, %{current: current}, c)

      heads =
        for r <- SwarmCodeCLI.UI.Settings.ModelPicker.display(s, c).popover.rows,
            match?({_left, _right}, r.segments),
            do: text(elem(r.segments, 0))

      assert Enum.any?(heads, &(&1 =~ "Anthropic Anthropic · 12 models · 3 new"))
    end

    test "Models & effort's fetch row says it too" do
      {state, _fake} = opened(:models_effort)

      done = %{
        action: "provider.fetch_all",
        target: nil,
        state: "done",
        summary: %{
          "words" => "3 providers · 2 updated · 1 failed",
          "providers" => [
            %{"name" => "Ollama", "state" => "failed", "message" => "no answer in 30 s"}
          ]
        }
      }

      state =
        put_in(state.settings.tasks["fa"], Map.merge(%{received_at_ms: 1, elapsed_ms: 0}, done))

      row = key_row(state, "models.fetch_all")
      assert words(row.value) =~ "3 providers · 2 updated · 1 failed"
      assert Enum.any?(row.lines, &(words(&1) =~ "Ollama · no answer in 30 s"))
    end
  end

  defp ctx_of(state), do: SwarmCodeCLI.UI.Settings.Nav.ctx(state)
end
