defmodule SwarmCodeCLI.UI.Settings.C74PopoverTest do
  @moduledoc """
  cli74 U1-13: the settings popovers — confirmations (safe first, Tab
  trapped, the destructive letter, typed words, counts loading, Esc once),
  pickers (filter, move, choose, `on_pick`), the enum picker for long
  choice lists, the generated keys sheet (F13).
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0, press!: 2, letter: 1]

  alias SwarmCodeCLI.UI.{Input, Projector, Reducer, SafeText}
  alias SwarmCodeCLI.UI.Reducer.Settings.{Edit, Ops}
  alias SwarmCodeCLI.UI.Settings
  alias SwarmCodeCLI.UI.Settings.{Confirm, Editors, Nav, Picker, Row}

  defp act(state, action), do: Reducer.update(state, action)
  defp act!(state, action), do: elem(act(state, action), 0)
  defp verb!(state, verb), do: act!(state, {:settings, {:verb, verb}})

  defp opened, do: act!(ready(), {:settings_open, {:key, "terminal.panel"}})

  defp run(state, ops), do: Ops.run(state, ops)

  defp screen(state) do
    {scene, _} = Projector.project(state)

    scene.regions
    |> Enum.flat_map(& &1.blocks)
    |> Enum.map_join("\n", fn block ->
      Enum.map_join(block.spans, "", &SafeText.value(&1.text))
    end)
  end

  # A confirmation as a section builds it: a plain map with the struct's fields.
  defp delete_confirm(extra \\ %{}) do
    {:confirm,
     Map.merge(
       %{
         title: "Delete DeepSeek?",
         lines: ["its API key is deleted with it"],
         safe: "Keep DeepSeek",
         danger: "Delete DeepSeek",
         letter: "D",
         undoable?: false
       },
       extra
     ), then: [{:toast, "Deleted DeepSeek", :success}]}
  end

  describe "confirmations" do
    test "the safe button is focused; Tab moves between the two buttons and stays inside" do
      {state, _} = run(opened(), [delete_confirm()])
      assert {:confirm, %{confirm: %Confirm{focus: :safe}}} = state.settings.popover
      assert Settings.context(state.settings) == :settings_popover
      assert screen(state) =~ "Delete DeepSeek?"
      assert screen(state) =~ "not undoable"

      state = press!(state, Input.key(:tab))
      assert {:confirm, %{confirm: %Confirm{focus: :danger}}} = state.settings.popover
      state = press!(state, Input.key(:tab))
      assert {:confirm, %{confirm: %Confirm{focus: :safe}}} = state.settings.popover

      # Enter on the safe button closes without doing anything.
      state = press!(state, Input.key(:enter))
      assert state.settings.popover == nil
      assert state.settings.status == nil
    end

    test "the destructive letter presses its button; Esc closes once and the layer stays" do
      {state, _} = run(opened(), [delete_confirm()])
      pressed = press!(state, letter("D"))
      assert pressed.settings.popover == nil
      assert pressed.settings.status.text == "Deleted DeepSeek"

      escaped = press!(state, Input.key(:escape))
      assert escaped.settings.popover == nil
      assert escaped.settings != nil
      assert escaped.settings.status == nil
    end

    test "a typed confirmation needs the word before the button works" do
      {state, _} = run(opened(), [delete_confirm(%{typed: "delete", letter: nil})])
      # The destructive button cannot take focus before the word is typed.
      state = press!(state, Input.key(:tab))
      assert {:confirm, %{confirm: %Confirm{focus: :safe}}} = state.settings.popover

      state = Enum.reduce(String.graphemes("delete"), state, &press!(&2, letter(&1)))
      state = press!(state, Input.key(:tab))

      assert {:confirm, %{confirm: %Confirm{focus: :danger, input: "delete"}}} =
               state.settings.popover

      state = press!(state, Input.key(:enter))
      assert state.settings.status.text == "Deleted DeepSeek"
    end

    test "the button stays disabled while the counts load" do
      {state, _} = run(opened(), [delete_confirm(%{counting?: true})])
      state = press!(state, letter("D"))
      assert {:confirm, _} = state.settings.popover
      assert screen(state) =~ "counting…"
    end
  end

  describe "pickers" do
    test "typing filters, arrows move, Enter chooses through on_pick" do
      picker = %{
        title: "Side panel",
        options: [
          %{value: "full", label: "Full"},
          %{value: "compact", label: "Compact"},
          %{value: "hidden", label: "Hidden"}
        ],
        on_pick: {:patch, "terminal.panel"}
      }

      {state, _} = run(opened(), [{:picker, picker}])
      assert Settings.context(state.settings) == :settings_picker
      state = press!(state, letter("h"))
      assert {:picker, %Picker{query: "h"}} = state.settings.popover
      assert screen(state) =~ "1 of 1 · Enter chooses · Esc closes"

      {state, effects} = act(state, {:settings, {:verb, :enter}})
      assert state.settings.popover == nil

      assert Enum.any?(
               effects,
               &match?({:settings_cli_write, _, _, %{"panel" => "hidden"}, _}, &1)
             )
    end

    test "an enum with more than five choices opens a picker whose choice commits the row" do
      choices = for n <- 1..7, do: %{value: "v#{n}", label: "Value #{n}", hint: nil}

      row = %Row{
        id: "key:terminal.panel",
        key: "terminal.panel",
        label: "Side panel",
        editor: {Editors.Enum, %{choices: choices, value: "v1"}}
      }

      {state, []} = Edit.open(opened(), row)

      assert {:picker, %Picker{on_pick: {:commit, %Row{id: "key:terminal.panel"}}}} =
               state.settings.popover

      state = verb!(state, :down)
      {_state, effects} = act(state, {:settings, {:verb, :enter}})
      assert Enum.any?(effects, &match?({:settings_cli_write, _, _, %{"panel" => "v2"}, _}, &1))
    end
  end

  describe "the keys sheet (F13)" do
    test "? opens the generated sheet with the effective keys; Esc closes it" do
      state =
        ready()
        |> act!({:resize, %SwarmCodeCLI.UI.Size{columns: 160, rows: 45}})
        |> act!({:settings_open, {:key, "terminal.panel"}})

      state = press!(state, letter("?"))
      assert {:help, _} = state.settings.popover
      text = screen(state)
      assert text =~ "Keys in settings"
      assert text =~ "move"
      assert text =~ "Remapped yourself out of a key? swarmcode config reset terminal.keys"
      assert press!(state, Input.key(:escape)).settings.popover == nil
    end
  end

  test "the row keeps the cursor under a popover (focus returns to the opener)" do
    state = opened()
    cursor = Nav.current(state).id
    {state, _} = run(state, [delete_confirm()])
    state = press!(state, Input.key(:escape))
    assert Nav.current(state).id == cursor
  end
end
