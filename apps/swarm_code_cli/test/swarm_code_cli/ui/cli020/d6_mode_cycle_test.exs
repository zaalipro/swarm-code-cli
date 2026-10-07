defmodule SwarmCodeCLI.UI.Cli020.D6ModeCycleTest do
  @moduledoc """
  cli020 D6 (competitors-18, decision 4b): Shift-Tab in the composer cycles
  Ask (read-only) → Auto → Plan → Ask through /approval and /plan.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Input, Keymap}

  defp at(approval, mode \\ :build),
    do:
      ready([],
        snapshot: %{approval_mode: approval, mode: mode, allowed_actions: [:send, :queue]}
      )

  defp shift_tab(state), do: press(state, Input.key(:back_tab))

  defp kinds(effects), do: for({:command, request} <- effects, do: request.kind)

  test "Shift-Tab and BackTab resolve to the cycle in the composer only" do
    state = at(:read_only)
    assert {:ok, {:cycle_permission_mode}} = Keymap.resolve(Input.key(:back_tab), state, %{})

    assert {:ok, {:cycle_permission_mode}} =
             Keymap.resolve(Input.key(:tab, [:shift]), state, %{})

    refute match?(
             {:ok, {:cycle_permission_mode}},
             Keymap.resolve(Input.key(:back_tab), %{state | focus: "main"}, %{})
           )
  end

  test "Ask → Auto sets the project's mode" do
    {state, effects} = shift_tab(at(:read_only))
    assert kinds(effects) == [{:project_update, :auto, nil}]

    assert state.notice ==
             {:command_feedback,
              "Auto · edits and safe commands run · Shift-Tab: Plan (this project)"}
  end

  test "Auto → Plan sends /plan" do
    {state, effects} = shift_tab(at(:auto))
    assert [{:dispatch, :send, "/plan", :main, []}] = kinds(effects)

    assert state.notice ==
             {:command_feedback, "Plan · read-only tools, a plan first · Shift-Tab: Ask"}
  end

  test "Plan → Ask turns plan off and the project back to read-only" do
    {state, effects} = shift_tab(at(:auto, :plan))

    assert [{:dispatch, :send, "/plan", :main, []}, {:project_update, :read_only, nil}] =
             kinds(effects)

    assert state.notice ==
             {:command_feedback,
              "Ask · writes and commands ask first · Shift-Tab: Auto (this project)"}
  end

  test "full access is never entered: from full the step is Plan" do
    {_state, effects} = shift_tab(at(:full_access))
    assert [{:dispatch, :send, "/plan", :main, []}] = kinds(effects)
  end

  test "a second Shift-Tab waits for the first step's answer" do
    {state, _} = shift_tab(at(:read_only))
    {_state, effects} = shift_tab(state)
    assert effects == []
  end

  test "the draft the user typed is kept, with its undo history" do
    state = at(:auto) |> type("half a thought")
    {state, effects} = shift_tab(state)
    assert [{:dispatch, :send, "/plan", :main, []}] = kinds(effects)
    assert text(state) == "half a thought"
    [request] = requests(effects)
    {state, _} = outcome(state, request, :accepted, [])
    assert text(state) == "half a thought"
  end

  test "a refused step shows the service's own words" do
    {state, effects} = shift_tab(at(:read_only))
    [request] = requests(effects)

    {state, _} =
      outcome(state, request, :rejected, [],
        reason: %SwarmCodeCLI.UI.DataSource.DTO.Refusal{
          code: "untrusted",
          text: "Trust the project first: /trust"
        }
      )

    assert state.notice == {:command_feedback, "Trust the project first: /trust"}
  end
end
