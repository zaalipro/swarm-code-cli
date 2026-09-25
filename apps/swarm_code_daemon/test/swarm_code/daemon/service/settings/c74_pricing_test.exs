defmodule SwarmCode.Daemon.Service.Settings.C74PricingTest do
  @moduledoc "pass 74 S2-5: pricing rows and unpriced models (§3.5.2, AT5)."
  use ExUnit.Case, async: false

  import Ecto.Query

  alias SwarmCode.Daemon.Service.Settings.Pricing
  alias SwarmCode.Domain.{Conversations, Repo, Settings}
  alias SwarmCode.Domain.Conversations.Conversation
  alias SwarmCode.Test.C74S2

  setup do
    fx = C74S2.repo!("c74-pricing")
    data = C74S2.appendix_a!(fx)
    Map.merge(data, %{ctx: C74S2.context(data.ailogic, data.conversation)})
  end

  defp put(c, attrs, expected) do
    Pricing.command(
      C74S2.command("pricing.put_row", attributes: attrs, expected: expected),
      c.ctx
    )
  end

  defp pricing, do: Settings.get().pricing

  describe "records" do
    test "rows sorted by model with the derived cache rates", c do
      {:ok, page} = Pricing.query("records", "pricing_rows", %{}, c.ctx)
      C74S2.declared!(page)

      assert Enum.map(page["items"], & &1["id"]) ==
               ["claude-opus-5", "deepseek-v4-flash", "deepseek-v4-pro"]

      opus = hd(page["items"])["fields"]
      assert opus["input"] == 15 and opus["cache_read"] == nil
      assert opus["derived_cache_read"] == 1.5
      assert opus["derived_cache_write"] == 18.75
    end

    test "a fable/mythos id reads cache at 0.025 of input", c do
      {:ok, _} =
        put(c, %{"model" => "claude-fable-5-1", "input" => 10, "output" => 50}, %{"row" => nil})

      {:ok, page} = Pricing.query("records", "pricing_rows", %{}, c.ctx)
      fable = Enum.find(page["items"], &(&1["id"] == "claude-fable-5-1"))["fields"]
      assert fable["derived_cache_read"] == 0.25
    end

    test "unpriced detection over defaults and the last 30 days' conversations", c do
      {:ok, page} = Pricing.query("records", "unpriced_models", %{}, c.ctx)
      C74S2.declared!(page)

      assert Enum.map(page["items"], & &1["fields"]) == [
               %{"model" => "claude-sonnet-5", "conversations_30d" => 1, "in_defaults" => false},
               %{"model" => "qwen3-coder", "conversations_30d" => 1, "in_defaults" => false}
             ]

      # a default names an unpriced model; an old conversation no longer counts
      {:ok, _} =
        Settings.update(%{
          research_lead_provider_id: c.anthropic.id,
          research_lead_model: "claude-haiku-5"
        })

      old = DateTime.add(DateTime.utc_now(), -31 * 86_400, :second)

      from(v in Conversation, where: v.chat_model == "qwen3-coder")
      |> Repo.update_all(set: [updated_at: old])

      {:ok, page} = Pricing.query("records", "unpriced_models", %{}, c.ctx)

      assert Enum.map(page["items"], &{&1["id"], &1["fields"]["in_defaults"]}) == [
               {"claude-haiku-5", true},
               {"claude-sonnet-5", false}
             ]

      # a priced row takes a model off the list
      {:ok, _} =
        put(c, %{"model" => "claude-sonnet-5", "input" => 3, "output" => 15}, %{"row" => nil})

      {:ok, page} = Pricing.query("records", "unpriced_models", %{}, c.ctx)
      assert Enum.map(page["items"], & &1["id"]) == ["claude-haiku-5"]
    end

    test "reading writes nothing (D24)", c do
      Repo.delete_all(SwarmCode.Domain.Settings.Setting)
      {:ok, page} = Pricing.query("records", "pricing_rows", %{}, c.ctx)
      assert page["total"] == 0
      {:ok, _} = Pricing.query("records", "unpriced_models", %{}, c.ctx)
      assert Repo.aggregate(SwarmCode.Domain.Settings.Setting, :count) == 0
    end
  end

  describe "pricing.put_row" do
    test "a row needs both prices, with the desktop's exact texts", c do
      assert {:error,
              %{code: :invalid, message: "output: must be a number ≥ 0", field_errors: errors}} =
               put(c, %{"model" => "m", "input" => "3"}, %{"row" => nil})

      assert errors == [%{target: "output", message: "output: must be a number ≥ 0"}]

      assert {:error, %{message: "input: must be a number ≥ 0"}} =
               put(c, %{"model" => "m", "input" => "-1", "output" => 2}, %{"row" => nil})

      assert {:error, %{message: "cache read: must be a number ≥ 0"}} =
               put(
                 c,
                 %{"model" => "m", "input" => 1, "output" => 2, "cache_read" => "x"},
                 %{"row" => nil}
               )

      assert {:error, %{message: "cache write: must be a number ≥ 0"}} =
               put(
                 c,
                 %{"model" => "m", "input" => 1, "output" => 2, "cache_write" => -2},
                 %{"row" => nil}
               )

      for window <- [7_999, 2_000_001, "12.5", "lots"] do
        assert {:error,
                %{message: "context window: a whole number of tokens between 8000 and 2000000"}} =
                 put(
                   c,
                   %{"model" => "m", "input" => 1, "output" => 2, "context_window" => window},
                   %{"row" => nil}
                 )
      end

      assert {:error, %{field_errors: [%{target: "model"}]}} =
               put(c, %{"model" => "  ", "input" => 1, "output" => 2}, %{"row" => nil})

      refute Map.has_key?(pricing(), "m")
    end

    test "a new row is saved as the desktop stores it; blanks leave keys out", c do
      {:ok, result} =
        put(
          c,
          %{
            "model" => " claude-sonnet-5 ",
            "input" => "3",
            "output" => 15,
            "cache_read" => "",
            "cache_write" => nil,
            "context_window" => "200000"
          },
          %{"row" => nil}
        )

      assert result.status == :accepted
      assert result.record["id"] == "claude-sonnet-5"
      C74S2.declared!(result.record)

      assert pricing()["claude-sonnet-5"] ==
               %{"input" => 3.0, "output" => 15.0, "context_window" => 200_000}
    end

    test "an edit is CAS-checked on the row as read; an equal row is unchanged", c do
      row = pricing()["deepseek-v4-pro"]
      attrs = %{"model" => "deepseek-v4-pro", "input" => 0.28, "output" => 1.1}
      {:ok, ok} = put(c, attrs, %{"row" => row})
      assert ok.status == :accepted
      assert pricing()["deepseek-v4-pro"]["input"] == 0.28

      {:ok, stale} = put(c, Map.put(attrs, "input", 0.3), %{"row" => row})
      assert stale.status == :conflict
      assert [%{target: "deepseek-v4-pro", current: %{"input" => 0.28}}] = stale.results
      assert pricing()["deepseek-v4-pro"]["input"] == 0.28

      {:ok, same} = put(c, attrs, %{"row" => pricing()["deepseek-v4-pro"]})
      assert same.status == :unchanged

      {:ok, any} = put(c, Map.put(attrs, "input", 0.31), %{"row" => %{"$any" => true}})
      assert any.status == :accepted
    end

    test "duplicate model on add and on rename; a rename moves the row", c do
      assert {:error, %{message: "duplicate model", field_errors: [%{target: "model"}]}} =
               put(c, %{"model" => "claude-opus-5", "input" => 1, "output" => 2}, %{"row" => nil})

      flash = pricing()["deepseek-v4-flash"]

      assert {:error, %{message: "duplicate model"}} =
               put(
                 c,
                 %{
                   "model" => "deepseek-v4-pro",
                   "input" => 1,
                   "output" => 2,
                   "rename_from" => "deepseek-v4-flash"
                 },
                 %{"row" => nil, "rename_row" => flash}
               )

      assert {:error, %{message: "expected is missing for rename_row"}} =
               put(
                 c,
                 %{
                   "model" => "deepseek-v4-lite",
                   "input" => 0.05,
                   "output" => 0.2,
                   "rename_from" => "deepseek-v4-flash"
                 },
                 %{"row" => nil}
               )

      {:ok, renamed} =
        put(
          c,
          %{
            "model" => "deepseek-v4-lite",
            "input" => 0.05,
            "output" => 0.2,
            "rename_from" => "deepseek-v4-flash"
          },
          %{"row" => nil, "rename_row" => flash}
        )

      assert renamed.status == :accepted
      refute Map.has_key?(pricing(), "deepseek-v4-flash")
      assert pricing()["deepseek-v4-lite"] == %{"input" => 0.05, "output" => 0.2}
    end

    test "dry run validates and writes nothing; expected is required", c do
      cmd =
        C74S2.command("pricing.put_row",
          attributes: %{"model" => "x-1", "input" => 1, "output" => 2},
          expected: %{"row" => nil},
          dry_run: true
        )

      {:ok, result} = Pricing.command(cmd, c.ctx)
      assert result.status == :accepted
      refute Map.has_key?(pricing(), "x-1")

      assert {:error, %{code: :invalid, message: "expected is missing for row"}} =
               put(c, %{"model" => "x-1", "input" => 1, "output" => 2}, nil)
    end
  end

  describe "pricing.delete_row" do
    test "removes the key after a CAS check", c do
      row = pricing()["claude-opus-5"]

      delete = fn expected ->
        Pricing.command(
          C74S2.command("pricing.delete_row",
            target: %{"model" => "claude-opus-5"},
            expected: %{"row" => expected}
          ),
          c.ctx
        )
      end

      {:ok, stale} = delete.(%{"input" => 1, "output" => 2})
      assert stale.status == :conflict
      assert Map.has_key?(pricing(), "claude-opus-5")

      {:ok, gone} = delete.(row)
      assert gone.status == :accepted and gone.record == nil
      refute Map.has_key?(pricing(), "claude-opus-5")

      {:ok, again} = delete.(nil)
      assert again.status == :unchanged
    end
  end

  describe "attention" do
    test "AT5 on Appendix A", c do
      assert [item] = Pricing.attention(c.ctx)
      assert item.id == "AT5" and item.severity == "warning" and item.section == "pricing"
      assert item.title == "2 models in use have no price"
      assert item.reason == "claude-sonnet-5, qwen3-coder count as $0.00 in every cost"
    end

    test "one model, more than three, none", c do
      Settings.update(%{
        pricing: Map.merge(pricing(), %{"claude-sonnet-5" => %{"input" => 3, "output" => 15}})
      })

      assert [%{title: "1 model in use has no price"}] = Pricing.attention(c.ctx)

      for model <- ~w(a-1 a-2 a-3 a-4) do
        {:ok, conv} = Conversations.create(c.ailogic.id)
        {:ok, _} = Conversations.update(conv, %{chat_model: model})
      end

      assert [%{reason: "a-1, a-2, a-3 +2 count as $0.00 in every cost"}] =
               Pricing.attention(c.ctx)

      Settings.update(%{
        pricing:
          Map.merge(
            pricing(),
            Map.new(~w(a-1 a-2 a-3 a-4 qwen3-coder), &{&1, %{"input" => 0, "output" => 0}})
          )
      })

      assert Pricing.attention(c.ctx) == []
    end
  end
end
