defmodule SwarmCodeCLI.UI.Settings.Sections.C74PricingTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations, as: I
  alias SwarmCodeCLI.UI.Settings.Sections.Pricing
  alias SwarmCodeCLI.UI.Settings.IntegrationRows, as: R
  import SwarmCodeCLI.Test.C74U2Ctx
  alias SwarmCodeCLI.Test.C74U2Ctx.Page

  defp row(rows, id),
    do:
      Enum.find(rows, &(&1.id == id)) ||
        flunk("no row #{id}: #{inspect(Enum.map(rows, & &1.id))}")

  defp cols(row), do: Enum.map(row.columns, &elem(&1, 0))

  test "the sketch: unpriced group, the table in the fixed order, derived cells marked" do
    rows = Pricing.rows(ctx())

    assert Enum.map(rows, & &1.id) == [
             "info:pricing:head",
             "head:used but unpriced",
             "rec:unpriced_model:claude-sonnet-5",
             "rec:unpriced_model:qwen3-coder",
             "info:pricing:columns",
             "rec:pricing_row:claude-opus-5",
             "rec:pricing_row:deepseek-v4-flash",
             "rec:pricing_row:deepseek-v4-pro",
             "info:derived",
             "act:pricing.add"
           ]

    assert text(row(rows, "rec:unpriced_model:claude-sonnet-5").value) ==
             "used by 14 conversations"

    assert cols(row(rows, "info:pricing:columns")) == [
             "model",
             "in $/M",
             "out $/M",
             "cache read",
             "cache write",
             "context"
           ]

    assert Enum.map(row(rows, "info:pricing:columns").columns, &elem(&1, 2)) == [1, 2, 3, 5, 6, 4]

    assert cols(row(rows, "rec:pricing_row:claude-opus-5")) == [
             "claude-opus-5",
             "15.00",
             "75.00",
             "1.50 ·",
             "18.75 ·",
             "200 000"
           ]

    assert cols(row(rows, "rec:pricing_row:deepseek-v4-flash")) == [
             "deepseek-v4-flash",
             "0.07",
             "0.28",
             "0.007 ·",
             "0.088 ·",
             "family default"
           ]

    assert cols(row(rows, "rec:pricing_row:deepseek-v4-pro")) == [
             "deepseek-v4-pro",
             "0.27",
             "1.10",
             "0.027 ·",
             "0.34 ·",
             "family default"
           ]

    assert text(row(rows, "info:derived").value) ==
             "· = derived from the input price (read × 0.1, write × 1.25)"
  end

  test "Enter on an unpriced model starts a draft prefilled with it; a adds an empty one" do
    rows = Pricing.rows(ctx())

    [
      {:draft_discard, "pricing_row"},
      {:draft_put, "pricing_row", %{"model" => "qwen3-coder"}},
      {:open, page}
    ] =
      Pricing.act(ctx(), row(rows, "rec:unpriced_model:qwen3-coder"), :open_row)

    assert page.record == {"pricing_row", "draft"}

    [_, {:draft_put, _, %{"model" => ""}}, _] =
      Pricing.act(ctx(), row(rows, "info:pricing:head"), :add)
  end

  defp draft_ctx(fields) do
    ctx(I.seed(), page: Page.at(:pricing, {"pricing_row", "draft"}))
    |> put_layer(:drafts, %{
      "pricing_row" => %{fields: fields, errors: %{}, secrets: %{}, dirty?: true}
    })
  end

  test "a row with one price stays a draft; both prices send pricing.put_row" do
    c = draft_ctx(%{"model" => "qwen3-coder", "input" => nil, "output" => nil})
    rows = Pricing.record_rows(c, "pricing_row", "draft")

    assert Pricing.commit(c, row(rows, "fld:pricing_row:draft:input"), 0.1) == [
             {:draft_put, "pricing_row", %{"input" => 0.1}}
           ]

    c = draft_ctx(%{"model" => "qwen3-coder", "input" => 0.1, "output" => nil})

    [{:command, "pricing.put_row", nil, attrs, opts}] =
      Pricing.commit(c, row(rows, "fld:pricing_row:draft:output"), 0.2)

    assert attrs == %{
             "model" => "qwen3-coder",
             "input" => 0.1,
             "output" => 0.2,
             "cache_read" => nil,
             "cache_write" => nil,
             "context_window" => nil
           }

    assert opts.expected == %{"row" => nil}

    assert [{:row_error, "fld:pricing_row:draft:output", "output: must be a number ≥ 0"}] =
             Pricing.commit(c, row(rows, "fld:pricing_row:draft:output"), -1)

    assert Pricing.title(c) =~ "New price · unsaved"
  end

  test "a saved row's cell writes the whole row with CAS; context bounds and rename" do
    c = ctx(I.seed(), page: Page.at(:pricing, {"pricing_row", "claude-opus-5"}))
    rows = Pricing.record_rows(c, "pricing_row", "claude-opus-5")

    assert text(row(rows, "fld:pricing_row:claude-opus-5:cache_read").value) ==
             "$1.50 · derived from the input price"

    [{:command, "pricing.put_row", nil, attrs, opts}] =
      Pricing.commit(c, row(rows, "fld:pricing_row:claude-opus-5:output"), 70)

    assert attrs["output"] == 70 and attrs["input"] == 15 and attrs["model"] == "claude-opus-5"

    assert opts.expected == %{
             "row" => %{
               "input" => 15,
               "output" => 75,
               "cache_read" => nil,
               "cache_write" => nil,
               "context_window" => 200_000
             }
           }

    assert {:command, "pricing.put_row", nil, %{"output" => 75}, _} = opts.undo

    assert [{:row_error, _, "context window: a whole number of tokens between 8000 and 2000000"}] =
             Pricing.commit(c, row(rows, "fld:pricing_row:claude-opus-5:context_window"), 100)

    [
      {:command, "pricing.put_row", nil,
       %{"model" => "claude-opus-5.1", "rename_from" => "claude-opus-5"}, _}
    ] =
      Pricing.commit(c, row(rows, "fld:pricing_row:claude-opus-5:model"), "claude-opus-5.1")
  end

  test "x removes a row, undoable" do
    c = ctx()

    [{:command, "pricing.delete_row", %{"model" => "claude-opus-5"}, %{}, opts}] =
      Pricing.act(c, row(Pricing.rows(c), "rec:pricing_row:claude-opus-5"), :delete)

    assert {:command, "pricing.put_row", nil, %{"model" => "claude-opus-5", "input" => 15}, _} =
             opts.undo
  end

  test "money in words" do
    assert R.money(15) == "15.00"
    assert R.money(0.27) == "0.27"
    assert R.money(0.07) == "0.07"
    assert R.money(0.007) == "0.007"
    assert R.money(0) == "0.00"
    assert Pricing.group_digits(2_000_000) == "2 000 000"
  end
end
