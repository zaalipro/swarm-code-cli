defmodule SwarmCode.Daemon.Service.Settings.C74EffortsModelsTest do
  @moduledoc "pass 74 S2-4: effort levels (efforts.save) and model options (§3.5.1)."
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Service.Settings.{Efforts, Models}
  alias SwarmCode.Domain.Providers
  alias SwarmCode.Test.C74S2

  setup do
    fx = C74S2.repo!("c74-efforts")
    data = C74S2.appendix_a!(fx)
    Map.merge(data, %{ctx: C74S2.context(data.ailogic, data.conversation)})
  end

  defp save(c, target, rows, expected) do
    Efforts.command(
      C74S2.command("efforts.save",
        target: target,
        attributes: %{"rows" => rows},
        expected: %{"levels" => expected}
      ),
      c.ctx
    )
  end

  @good [
    %{
      "key" => "off",
      "label" => "",
      "hint" => "no thinking",
      "body" => %{"thinking" => %{"type" => "disabled"}},
      "drop" => []
    },
    %{
      "key" => "high",
      "label" => "High",
      "hint" => "",
      "body" => %{"reasoning_effort" => "high"},
      "drop" => ["temperature"]
    }
  ]

  describe "efforts.save" do
    test "a provider's levels are saved and the record comes back", c do
      {:ok, result} = save(c, %{"id" => c.deepseek.id, "model" => nil}, @good, nil)
      assert result.status == :accepted
      levels = Providers.get(c.deepseek.id).effort_levels
      assert Enum.map(levels, & &1["key"]) == ["off", "high"]
      assert hd(levels)["label"] == "Off"
      assert List.last(levels)["drop"] == ["temperature"]
      assert Enum.map(result.record["fields"]["effort_levels"], & &1["key"]) == ["off", "high"]
    end

    test "a row error lands on rows[i] with the domain's words", c do
      rows = [
        hd(@good),
        List.last(@good),
        %{"key" => "max", "body" => [1], "drop" => []},
        %{"key" => "Bad Key", "body" => %{}, "drop" => []}
      ]

      assert {:error, %{field_errors: errors, message: "rows[2]: body: must be a JSON object"}} =
               save(c, %{"id" => c.deepseek.id}, rows, nil)

      assert errors == [
               %{target: "rows[2]", message: "body: must be a JSON object"},
               %{target: "rows[3]", message: "key: lowercase letters, digits, - or _ (24 max)"}
             ]

      assert {:error, %{field_errors: [%{target: "rows[1]", message: "key: already used"}]}} =
               save(c, %{"id" => c.deepseek.id}, [hd(@good), hd(@good)], nil)

      assert Providers.get(c.deepseek.id).effort_levels == nil
    end

    test "a model override is saved, conflicts on stale levels, and is removed", c do
      target = %{"id" => c.deepseek.id, "model" => "deepseek-v4-pro"}
      {:ok, _} = save(c, target, [hd(@good)], nil)
      [level] = Providers.get(c.deepseek.id).model_effort_levels["deepseek-v4-pro"]
      assert level["key"] == "off"

      {:ok, conflict} = save(c, target, @good, nil)
      assert conflict.status == :conflict
      assert [%{target: "levels", current: [%{"key" => "off"} | _]}] = conflict.results

      {:ok, removed} =
        Efforts.command(
          C74S2.command("efforts.remove_override",
            target: target,
            expected: %{
              "levels" => Providers.get(c.deepseek.id).model_effort_levels["deepseek-v4-pro"]
            }
          ),
          c.ctx
        )

      assert removed.status == :accepted
      assert Providers.get(c.deepseek.id).model_effort_levels == %{}
    end

    test "more than 32 rows are refused before any write", c do
      rows = for i <- 1..33, do: %{"key" => "k#{i}", "body" => %{}, "drop" => []}
      assert {:error, %{code: :invalid}} = save(c, %{"id" => c.deepseek.id}, rows, nil)
    end

    test "presets filtered by kind", c do
      {:ok, body} =
        Efforts.query(
          "records",
          "effort_presets",
          %{"options" => %{"kind" => "anthropic"}},
          c.ctx
        )

      ids = Enum.map(body["items"], & &1["id"])
      assert "anthropic_adaptive" in ids and "anthropic_budget" in ids and "off" in ids
      refute "openai" in ids
    end
  end

  describe "records:model_options" do
    test "every provider × model, sorted by provider then model, with prices", c do
      {:ok, body} = Models.query("records", "model_options", %{}, c.ctx)
      rows = Enum.map(body["items"], &{&1["fields"]["provider_name"], &1["fields"]["model"]})

      assert rows == [
               {"Anthropic", "claude-opus-5"},
               {"Anthropic", "claude-sonnet-5"},
               {"DeepSeek", "deepseek-v4-flash"},
               {"DeepSeek", "deepseek-v4-pro"},
               {"Ollama", "qwen3-coder"}
             ]

      by_model = Map.new(body["items"], &{&1["fields"]["model"], &1["fields"]})
      assert by_model["deepseek-v4-pro"]["price"]["input"] == 0.27
      assert by_model["deepseek-v4-pro"]["provider_default"] == true
      assert by_model["claude-sonnet-5"]["price"] == nil
      assert by_model["qwen3-coder"]["in_last_fetch"] == nil
    end

    test "paged and filtered, with the last fetch's marks", c do
      {:ok, page} = Models.query("records", "model_options", %{"page_size" => 2}, c.ctx)
      assert length(page["items"]) == 2 and page["next_cursor"] == "2" and page["total"] == 5

      {:ok, next} =
        Models.query("records", "model_options", %{"page_size" => 2, "cursor" => "4"}, c.ctx)

      assert length(next["items"]) == 1 and next["next_cursor"] == nil

      ctx = %{
        c.ctx
        | task_results: %{
            {"provider.fetch_models", c.deepseek.id} =>
              C74S2.task_entry("t", :done, %{
                "provider_id" => c.deepseek.id,
                "models" => ["deepseek-v4-pro"]
              })
          }
      }

      {:ok, only} =
        Models.query(
          "records",
          "model_options",
          %{"options" => %{"provider_id" => c.deepseek.id}},
          ctx
        )

      assert Enum.map(only["items"], &{&1["fields"]["model"], &1["fields"]["in_last_fetch"]}) == [
               {"deepseek-v4-flash", false},
               {"deepseek-v4-pro", true}
             ]
    end
  end
end
