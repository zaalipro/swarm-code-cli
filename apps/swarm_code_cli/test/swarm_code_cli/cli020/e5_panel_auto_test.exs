defmodule SwarmCodeCLI.Cli020.E5PanelAutoTest do
  # cli020 E5 (ux-live-15, Q8 and §7.11): the side panel is `:auto` by
  # default: no panel and no strip while the visible runs have fewer than two
  # agents and nothing needs the user; then what `:full` draws (the strip
  # under 120 columns).
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCode.Settings.Registry
  alias SwarmCodeCLI.UI.Init.Preferences
  alias SwarmCodeCLI.UI.Layout
  alias SwarmCodeCLI.UI.DataSource.DTO.PendingInteraction
  alias SwarmCodeCLI.UI.Projector.Panel

  describe "preferences" do
    test "auto is the default and a known value" do
      assert Preferences.defaults().panel_mode == :auto
      assert Preferences.legacy(%{}).panel_mode == :auto
      assert Preferences.legacy(%{"panel" => "auto"}).panel_mode == :auto
      assert Preferences.legacy(%{"panel" => "full"}).panel_mode == :full
      assert Preferences.valid?(%{panel_mode: :auto})
      assert Preferences.changes(%{panel_mode: :auto}) == %{"panel" => "auto"}
    end

    test "the registry offers auto first and defaults to it" do
      entry = Registry.fetch!("terminal.panel")
      assert entry.default == "auto"
      assert Enum.map(entry.choices, & &1.value) == ~w(auto full compact hidden)
    end

    test "the Ctrl-B order E gives D" do
      assert Panel.cycle_order() == [:auto, :full, :compact, :hidden]
    end
  end

  defp auto(state), do: Map.put(state, :panel_mode, :auto)

  test "a plain chat at 120 columns draws no panel" do
    state = fixture(:chat, {120, 30}) |> auto()
    refute Panel.auto_shown?(state)
    assert Panel.effective_mode(state) == :hidden
    refute Map.has_key?(Layout.for_state(state).rects, :inspector)
  end

  test "a plain chat at 100 columns draws no strip" do
    state = fixture(:chat, {100, 30}) |> auto()
    refute Map.has_key?(Layout.for_state(state).rects, :tabline)
  end

  test "a swarm with workers draws the panel at 120 and the strip below" do
    state = fixture(:swarm, {120, 30}) |> auto()
    assert Panel.auto_shown?(state)
    assert Panel.effective_mode(state) == :full
    assert Map.has_key?(Layout.for_state(state).rects, :inspector)

    narrow = fixture(:swarm, {100, 30}) |> auto()
    assert Map.has_key?(Layout.for_state(narrow).rects, :tabline)
  end

  test "an approval opens the panel" do
    interaction = %PendingInteraction{
      id: "approval-1",
      kind: :approval,
      state: :pending,
      run_id: "fixture-run",
      node_id: "node",
      conversation_id: "fixture-conversation",
      expected_revision: 3,
      allowed_actions: [:approve, :deny]
    }

    state = fixture(:chat, {120, 30}) |> auto()
    state = put_in(state.read_model.interactions["approval-1"], interaction)
    assert Panel.auto_shown?(state)
    assert Map.has_key?(Layout.for_state(state).rects, :inspector)
  end

  test "an explicit mode is kept as it is" do
    state = fixture(:chat, {120, 30}) |> Map.put(:panel_mode, :full)
    assert Panel.effective_mode(state) == :full
    assert Map.has_key?(Layout.for_state(state).rects, :inspector)
  end

  test "the chat run's subtitle is chat · <tokens>" do
    state = fixture(:chat, {140, 30}) |> Map.put(:panel_mode, :full)
    text = screen_text(state)
    assert text =~ ~r/chat · \d/
    refute text =~ "chat · in chat"
  end
end
