defmodule SwarmCodeCLI.UI.Settings.C74EffortLevelsTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations, as: I
  alias SwarmCodeCLI.UI.Settings.EffortLevels
  alias SwarmCodeCLI.UI.Settings.Sections.Providers
  import SwarmCodeCLI.Test.C74U2Ctx
  alias SwarmCodeCLI.Test.C74U2Ctx.Page

  @ids I.ids()

  defp page_ctx(id, opts \\ []) do
    c =
      ctx(I.seed(),
        records: [{"provider", id}],
        page:
          Map.put(Page.at(:providers, {"provider", id}, :effort_levels), :cursor, opts[:cursor])
      )

    case opts[:draft] do
      nil -> c
      d -> put_layer(c, :drafts, %{"effort_levels" => d})
    end
  end

  defp rows(c, id), do: Providers.record_rows(c, "provider", id)

  defp row(rows, id),
    do:
      Enum.find(rows, &(&1.id == id)) ||
        flunk("no row #{id}: #{inspect(Enum.map(rows, & &1.id))}")

  test "the T§24 sketch: scope, preset, the table and the preview under the focused level" do
    c = page_ctx(@ids.anthropic, cursor: "item:levels:2")
    rows = rows(c, @ids.anthropic)
    assert text(row(rows, "fld:levels:scope").value) == "[this provider]"
    assert text(row(rows, "fld:levels:preset").value) == "Anthropic adaptive (Claude 4.6+, 5) ▾"

    assert Enum.map(row(rows, "info:levels:columns").columns, &elem(&1, 0)) == [
             "key",
             "label",
             "hint",
             "adds to the request",
             "drops"
           ]

    high = row(rows, "item:levels:2")

    assert Enum.map(high.columns, &elem(&1, 0)) == [
             "high",
             "High",
             "deeper reasoning",
             "effort high · thinking adaptive",
             "temperature top_p top_k"
           ]

    assert text(row(rows, "info:levels:preview").value) =~
             ~s(the request gains {"output_config":{"effort":"high"},"thinking":{"display":"summarized","type":"adaptive"}} · drops temperature, top_p, top_k)

    assert Providers.title(c) == "Anthropic › Effort levels"
  end

  test "edits go into the draft; Ctrl-S sends efforts.save with CAS on the stored levels" do
    c = page_ctx(@ids.deepseek)
    rows = rows(c, @ids.deepseek)

    [{:draft_put, "effort_levels", %{"provider_id" => pid, "model" => nil, "rows" => new}}] =
      Providers.act(c, row(rows, "item:levels:0"), :delete)

    assert pid == @ids.deepseek and Enum.map(new, & &1["key"]) == ["high", "max"]

    c =
      page_ctx(@ids.deepseek,
        draft: %{
          fields: %{"provider_id" => @ids.deepseek, "model" => nil, "rows" => new},
          errors: %{},
          dirty?: true
        }
      )

    rows = rows(c, @ids.deepseek)
    assert text(row(rows, "info:levels:head").value) == "unsaved · Ctrl-S saves · Esc asks"
    assert Providers.title(c) == "DeepSeek › Effort levels · unsaved · Ctrl-S saves · Esc asks"

    [{:command, "efforts.save", %{"id" => _, "model" => nil}, %{"rows" => sent}, opts}] =
      Providers.act(c, row(rows, "item:levels:0"), :save)

    assert Enum.map(sent, & &1["key"]) == ["high", "max"]
    assert Enum.map(opts.expected["levels"], & &1["key"]) == ["off", "high", "max"]
    assert opts.errors_to == {:draft, "effort_levels"}
  end

  test "a row error rows[2] lands under the third row" do
    rows3 = [
      %{"key" => "a", "body" => %{}},
      %{"key" => "b", "body" => %{}},
      %{"key" => "c", "body" => %{}}
    ]

    c =
      page_ctx(@ids.ollama,
        draft: %{
          fields: %{"provider_id" => @ids.ollama, "model" => nil, "rows" => rows3},
          errors: %{"rows[2]" => "key: already used"},
          dirty?: true
        }
      )

    third = row(rows(c, @ids.ollama), "item:levels:2")
    assert third.lines == [[{"✗ key: already used", :error}]]
    assert row(rows(c, @ids.ollama), "item:levels:1").lines == []
  end

  test "the level editor validates JSON with line and column and the body shape" do
    assert {:error, "body: must be a JSON object"} =
             EffortLevels.parse_level(~s({"key": "hi", "body": [1]}))

    assert {:error, "key: lowercase letters, digits, - or _ (24 max)"} =
             EffortLevels.parse_level(~s({"key": "Hi There"}))

    assert {:error, "body: line 2, column " <> _} =
             EffortLevels.parse_level("{\"key\": \"x\",\n  \"body\": {,}}")

    assert {:ok, %{"key" => "x", "label" => "X", "body" => %{}}} =
             EffortLevels.parse_level(~s({"key": "x"}))

    c = page_ctx(@ids.deepseek)
    level = row(rows(c, @ids.deepseek), "item:levels:0")

    assert [{:row_error, "item:levels:0", "body: must be a JSON object"}] =
             Providers.commit(c, level, ~s({"key":"off","body":3}))

    [{:draft_put, _, %{"rows" => [first | _]}}] =
      Providers.commit(c, level, ~s({"key":"none","body":{"x":1}}))

    assert first["key"] == "none"
  end

  test "a preset replaces the rows; add, move and the scope switch" do
    c = page_ctx(@ids.ollama)

    [{:picker, picker}] =
      Providers.act(c, row(rows(c, @ids.ollama), "fld:levels:preset"), :open_row)

    assert "DeepSeek V4" in Enum.map(picker.options, & &1.label)

    [{:draft_put, _, %{"rows" => rows}}] =
      EffortLevels.preset_ops(c, @ids.ollama, rfields(c, @ids.ollama), "deepseek")

    assert Enum.map(rows, & &1["key"]) == ["off", "high", "max"]

    # cli74 F35: the picker's own on_pick reaches the same ops through the section.
    assert [{:draft_put, _, %{"rows" => ^rows}}] =
             Providers.picked(c, picker.on_pick |> elem(2), "deepseek")

    [{:draft_put, _, %{"rows" => added}}, {:edit, "item:levels:3"}] =
      Providers.act(c, row(rows(c, @ids.ollama), "act:levels.add"), :open_row)

    assert List.last(added)["key"] == "level1"

    scope = row(rows(c, @ids.ollama), "fld:levels:scope")

    assert [{:stage, {"provider", _}, %{"effort_scope" => "qwen3-coder"}}] =
             Providers.commit(c, scope, "qwen3-coder")
  end

  test "reset to built-in asks when custom levels would be lost; a model override can be removed" do
    c = page_ctx(@ids.deepseek)

    [
      {:confirm, confirm,
       then: [{:draft_discard, _}, {:command, "efforts.save", _, %{"rows" => []}, _}]}
    ] = Providers.act(c, row(rows(c, @ids.deepseek), "act:levels.reset"), :open_row)

    assert confirm.lines == ["3 custom levels of this provider will be lost."]

    state = I.seed()

    {{:ok, _}, state} =
      I.command(state, %{
        "action" => "efforts.save",
        "target" => %{"id" => @ids.ollama, "model" => "qwen3-coder"},
        "attributes" => %{"rows" => [%{"key" => "on", "body" => %{}}]}
      })

    c =
      ctx(state,
        records: [{"provider", @ids.ollama}],
        page: Page.at(:providers, {"provider", @ids.ollama}, :effort_levels)
      )

    c = put_layer(c, :staged, %{{"provider", @ids.ollama} => %{"effort_scope" => "qwen3-coder"}})
    remove = row(rows(c, @ids.ollama), "act:levels.remove_override")

    [{:command, "efforts.remove_override", %{"model" => "qwen3-coder"}, _, _}] =
      Providers.act(c, remove, :open_row)
  end

  test "source words" do
    f = rfields(page_ctx(@ids.deepseek), @ids.deepseek)
    assert EffortLevels.source_words(f) == "DeepSeek V4 · 3 levels"
    assert EffortLevels.source_words(Map.put(f, "effort_levels", nil)) == "built-in levels"

    assert EffortLevels.source_words(Map.put(f, "model_effort_levels", %{"m" => []})) ==
             "DeepSeek V4 · 3 levels + 1 model override"
  end

  defp rfields(c, id),
    do:
      SwarmCodeCLI.UI.Settings.IntegrationRows.fields(
        SwarmCodeCLI.UI.Settings.IntegrationRows.record(c, "provider", id)
      )
end
