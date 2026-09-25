defmodule SwarmCodeCLI.UI.Settings.C74UndoTest do
  @moduledoc """
  cli74 U1-11: undo and redo that survive closing the layer, the section
  reset with its confirmation (one list of what changes), and the pending
  question when leaving a page with a paste, a draft or staged fields.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0, press!: 2, letter: 1]

  alias SwarmCodeCLI.UI.{Input, Reducer}
  alias SwarmCodeCLI.UI.Reducer.Settings.Ops
  alias SwarmCodeCLI.UI.Settings.{Confirm, Layer, Nav}

  defp act(state, action), do: Reducer.update(state, action)
  defp act!(state, action), do: elem(act(state, action), 0)

  defp writes(effects),
    do: for({:settings_cli_write, _, _, changes, expected} <- effects, do: {changes, expected})

  defp answer(state, effects) do
    Enum.reduce(effects, state, fn
      {:settings_cli_write, generation, ref, changes, _}, acc ->
        values =
          Enum.reduce(changes, acc.prefs, fn
            {name, :remove}, prefs -> Map.delete(prefs, name)
            {name, value}, prefs -> Map.put(prefs, name, value)
          end)

        act!(
          acc,
          {:settings, {:cli_result, generation, ref, {:ok, %{values: values, status: :ok}}}}
        )

      _, acc ->
        acc
    end)
  end

  test "undo survives closing and reopening the layer, and sends the inverse CAS" do
    state = act!(ready(), {:settings_open, {:key, "terminal.panel"}})
    {state, effects} = act(state, {:settings, {:verb, :right}})
    state = answer(state, effects)
    assert state.prefs["panel"] == "compact"

    state = press!(state, Input.key(:escape))
    assert state.settings == nil
    state = act!(state, {:settings_open, nil})

    {state, effects} = act(state, {:settings, {:verb, :undo}})
    assert [{%{"panel" => :remove}, %{"panel" => "compact"}}] = writes(effects)
    state = answer(state, effects)
    assert state.panel_mode == :full

    {_state, effects} = act(state, {:settings, {:verb, :redo}})
    assert [{%{"panel" => "compact"}, %{"panel" => :absent}}] = writes(effects)
  end

  test "nothing to undo says so" do
    state = ready() |> act!({:settings_open, nil}) |> act!({:settings, {:verb, :undo}})
    assert state.settings.status.text == "Nothing to undo"
  end

  test "the section reset lists what changes and resets it after R" do
    state = %{ready() | prefs: %{"panel" => "compact", "composer_rows" => 5}}
    state = act!(state, {:settings_open, {:section, :layout}})
    state = Nav.put_cursor(state, "act:reset_section")
    state = act!(state, {:settings, {:verb, :enter}})

    assert {:confirm, %{confirm: %Confirm{title: "Reset Layout & transcript?", lines: lines}}} =
             state.settings.popover

    assert Enum.any?(lines, &(&1 =~ "Side panel"))
    assert Enum.any?(lines, &(&1 =~ "Composer height  5 → 3"))

    {state, effects} = act(state, {:settings, {:text, "R"}})

    assert Enum.sort(Enum.map(writes(effects), &elem(&1, 0))) == [
             %{"composer_rows" => :remove},
             %{"panel" => :remove}
           ]

    assert state.settings.status.text =~ "Reset 2 values in Layout & transcript"
  end

  describe "pending on leave" do
    test "leaving with a paste asks; d discards and leaves; Esc stays" do
      state = act!(ready(), {:settings_open, {:key, "terminal.panel"}})

      {state, _} =
        Ops.run(state, [
          {:paste,
           %{row_id: "key:terminal.panel", label: "Tavily API key", action: "search.set_key"}}
        ])

      state = act!(state, {:settings, {:paste, "0123456789abcdef"}})
      state = %{state | settings: %{state.settings | mode: :browse}}

      asked = act!(state, {:settings, {:verb, :close}})
      assert {:pending, %{items: ["the pasted Tavily API key"]}} = asked.settings.popover

      stayed = press!(asked, Input.key(:escape))
      assert %Layer{popover: nil} = stayed.settings

      left = press!(asked, letter("d"))
      assert left.settings == nil
    end

    test "staged fields and a filled draft are named; d unstages and discards them" do
      state = act!(ready(), {:settings_open, {:section, :mcp}})

      {state, _} =
        Ops.run(state, [
          {:stage, {"mcp_server", "github"}, %{"command" => "npx"}},
          {:draft_put, "provider", %{"name" => "DeepSeek"}}
        ])

      asked = act!(state, {:settings, {:verb, :next_section}})
      assert {:pending, %{items: items}} = asked.settings.popover
      assert "changes to mcp_server github" in items
      assert "the new provider (not created yet)" in items

      left = press!(asked, letter("d"))
      assert left.settings.staged == %{}
      assert left.settings.drafts == %{}
      assert Layer.section(left.settings) != :mcp
    end
  end
end
