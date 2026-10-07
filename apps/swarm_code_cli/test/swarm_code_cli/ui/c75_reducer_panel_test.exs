defmodule SwarmCodeCLI.UI.C75ReducerPanelTest do
  @moduledoc """
  pass75 (task 114, was 151): `/panel summaries on|off` switches the panel's
  AI status lines and remembers it in cli.json; `/panel summaries` says which
  it is. Every key goes through `Keymap.resolve/3` and `Reducer.update/2`, as
  it does in the session.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Capabilities, Init, Input, Keymap, Reducer, Size}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery}

  test "/panel summaries off turns the lines off, saves it and clears the command" do
    {state, effects} = send_draft(ready(), "/panel summaries off")
    assert state.agent_summaries? == false
    assert {:save_preferences, %{agent_summaries?: false}} in effects

    assert state.notice ==
             {:command_feedback, "AI status lines off · /panel summaries on brings them back"}

    assert Keymap.draft_text(state) == ""
  end

  test "/panel summaries on turns them back on" do
    {state, _} = send_draft(ready(), "/panel summaries off")
    {state, effects} = send_draft(state, "/panel summaries on")
    assert state.agent_summaries? == true
    assert {:save_preferences, %{agent_summaries?: true}} in effects

    assert state.notice ==
             {:command_feedback, "AI status lines on · /panel summaries off hides them"}

    assert Keymap.draft_text(state) == ""
  end

  test "/panel summaries says which it is and saves nothing" do
    {state, effects} = send_draft(ready(), "/panel summaries")
    assert state.notice == {:command_feedback, "AI status lines are on: /panel summaries off"}
    refute Enum.any?(effects, &match?({:save_preferences, _}, &1))
  end

  test "the argument is read in any case" do
    {state, effects} = send_draft(ready(), "/panel SUMMARIES Off")
    assert state.agent_summaries? == false
    assert {:save_preferences, %{agent_summaries?: false}} in effects
  end

  test "an unknown summaries argument is the panel's usage line" do
    {state, effects} = send_draft(ready(), "/panel summaries maybe")
    assert state.agent_summaries? == true

    assert state.notice ==
             {:command_feedback, "Panel is auto, full, compact or hidden: /panel compact."}

    refute Enum.any?(effects, &match?({:save_preferences, _}, &1))
  end

  test "/panel compact still sets the panel's shape" do
    {state, effects} = send_draft(ready(), "/panel compact")
    assert state.panel_mode == :compact
    assert {:save_preferences, %{panel_mode: :compact}} in effects
  end

  test "the save effect is valid" do
    effect = {:save_preferences, %{agent_summaries?: false}}
    assert SwarmCodeCLI.UI.Effect.validate(effect) == {:ok, effect}
  end

  # ------------------------------------------------------------------ helpers

  defp ready(opts \\ []) do
    size = Keyword.get(opts, :size, %Size{columns: 160, rows: 45})

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "e",
        destination: {:conversation, "c"},
        focus: "composer"
      })

    watch = state.watches.workspace

    body = %DTO.WorkspaceSnapshot{
      conversation_id: "c",
      allowed_actions: [:send, :queue],
      runs: Keyword.get(opts, :runs, []),
      agents: Keyword.get(opts, :agents, []),
      interactions: Keyword.get(opts, :interactions, []),
      transcript: %DTO.TranscriptWindow{items: Keyword.get(opts, :items, [])},
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    }

    delivery = %Delivery{
      kind: :watch_ready,
      watch_ref: watch.watch_ref,
      request_id: nil,
      scope: watch.scope,
      generation: watch.generation,
      revision: 0,
      sequence: nil,
      body: body
    }

    {state, _} = Reducer.update(state, {:data, delivery})
    state
  end

  defp press(state, input) do
    case Keymap.resolve(input, state, %{}) do
      {:ok, action} -> Reducer.update(state, action)
      :ignore -> {state, []}
    end
  end

  defp press!(state, input), do: elem(press(state, input), 0)
  defp letter(text, mods \\ []), do: Input.text_fragment(:press, text, mods)

  defp type(state, text),
    do: text |> String.graphemes() |> Enum.reduce(state, &press!(&2, letter(&1)))

  defp send_draft(state, text) do
    state = type(state, text)
    intent = {:dispatch, :send, text, :main, []}
    {:ok, action} = Keymap.activate({:intent, intent}, state, %{"send" => {:intent, intent}})
    Reducer.update(state, action)
  end
end
