defmodule SwarmCodeCLI.UI.Settings.C74BudgetDesktopTest do
  @moduledoc "cli74 U3-11: Budget & usage (§2.19) and Desktop app (§2.20)."
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.C74U3Helpers

  alias SwarmCodeCLI.UI.Settings.{Layer, Nav, Page, Sections}
  alias SwarmCodeCLI.UI.Settings.Editors.{KeyCapture, Toggle}
  alias SwarmCodeCLI.UI.Settings.Editors.Enum, as: EnumEditor
  alias SwarmCodeCLI.UI.Settings.Sections.BudgetUsage

  describe "Budget & usage" do
    test "this month's spend against the budget with a gauge" do
      {state, _fake} = opened(:budget)
      assert words(key_row(state, "budget.monthly_usd")) == "$50"
      month = words(key_row(state, "budget.month"))
      assert month =~ "$38.20 of $50"
      assert month =~ "76 %"
    end

    test "the last 30 days by model: tokens, cost, and no price for an unpriced model" do
      {state, _fake} = opened(:budget)
      text = page_text(state)
      assert text =~ "deepseek-v4-pro   21.40 M 3.10 M $30.10"
      assert text =~ "claude-sonnet-5   120.0 k 18.0 k no price"
    end

    test "money and tokens" do
      assert BudgetUsage.money(50) == "$50"
      assert BudgetUsage.money(50.0) == "$50"
      assert BudgetUsage.money(38.2) == "$38.20"
      assert BudgetUsage.money(0.5) == "$0.50"
      assert BudgetUsage.tokens(812) == "812"
      assert BudgetUsage.tokens(41_200) == "41.2 k"
      assert BudgetUsage.tokens(nil) == "—"
    end
  end

  describe "Desktop app" do
    test "every row says no effect in the terminal, and the CLI can still edit them" do
      {state, _fake} = opened(:desktop)
      theme = key_row(state, "desktop.theme")
      assert {EnumEditor, _} = theme.editor
      assert Enum.any?(theme.lines, &(words(&1) =~ "no effect in the terminal"))
      assert {Toggle, _} = key_row(state, "desktop.reduce_motion").editor
      assert {KeyCapture, %{mode: :desktop}} = key_row(state, "desktop.keys.quit").editor
      assert words(row(state, "info:desktop-intro")) =~ "The terminal ignores them"
    end

    test "Reset all desktop keys resets every shortcut" do
      {state, _fake} = opened(:desktop)
      reset = row(state, "act:reset_desktop_keys")

      assert [{:reset, keys}, {:toast, _, :success}] =
               Sections.act(:desktop, Nav.ctx(state), reset, :open_row)

      assert "desktop.keys.quit" in keys
      assert Enum.all?(keys, &String.starts_with?(&1, "desktop.keys."))
    end

    test "the window state is one row that opens its sub-page" do
      {state, _fake} = opened(:desktop)
      assert words(row(state, "act:window_state")) =~ "values"
      {state, _effects} = press(state, "act:window_state", :enter)
      assert %Page{sub: :window_state} = Layer.page(state.settings)
      assert Enum.any?(rows(state), &String.starts_with?(&1.id, "key:desktop."))
    end
  end
end
