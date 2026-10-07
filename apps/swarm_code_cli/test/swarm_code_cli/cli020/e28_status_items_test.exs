defmodule SwarmCodeCLI.Cli020.E28StatusItemsTest do
  # cli020 E28 (competitors-20): `terminal.status_items` picks the status
  # line's facts and their order; `branch` draws the git branch and dirty count.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCode.Settings.Registry

  defp state(prefs, caps \\ []) do
    fixture(:chat, {160, 30}, caps)
    |> put_workspace(
      chat_model: "claude-sonnet-5",
      effort: "high",
      approval_mode: "auto",
      git_branch: "cli020/E",
      git_dirty: 3
    )
    |> Map.put(:prefs, prefs)
  end

  defp status(state), do: state |> screen() |> List.last()

  test "the default: every item but branch, in today's order" do
    line = status(state(%{}))
    assert line =~ ~r/Build · auto · claude-sonnet-5 · high/
    refute line =~ "⎇"
    refute line =~ "cli020/E"
  end

  test "an empty list draws none of the eight" do
    line = status(state(%{"status_items" => []}))
    refute line =~ "Build"
    refute line =~ "auto"
    refute line =~ "claude-sonnet-5"
  end

  test "the listed items in the listed order, branch among them" do
    line = status(state(%{"status_items" => ["branch", "model", "mode"]}))
    assert line =~ ~r/⎇ cli020\/E \+3 · claude-sonnet-5 · Build/
    refute line =~ "high"
    refute line =~ " auto "
  end

  test "branch in ASCII, and with a clean tree" do
    line = status(state(%{"status_items" => ["branch"]}, ascii?: true))
    assert line =~ "br: cli020/E +3"

    clean = state(%{"status_items" => ["branch"]}) |> put_workspace(git_dirty: 0)
    assert status(clean) =~ ~r/⎇ cli020\/E(?! \+)/
  end

  test "a bad value reads as the default" do
    line = status(state(%{"status_items" => ["mode", "nope"]}))
    assert line =~ ~r/Build · auto · claude-sonnet-5/
  end

  test "the registry row" do
    entry = Enum.find(Registry.all(), &(&1.key == "terminal.status_items"))
    assert entry.storage == {:cli, "status_items"}
    assert entry.type == :checklist
    assert entry.default == ~w(mode approval model effort ctx cost waiting)
    assert length(entry.choices) == 8
  end
end
