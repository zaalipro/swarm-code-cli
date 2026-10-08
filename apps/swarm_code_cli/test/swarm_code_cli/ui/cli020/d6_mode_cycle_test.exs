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

  describe "fix round U1: one notice carries the mode and the scope" do
    alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery, Delta}
    alias SwarmCodeCLI.UI.Reducer

    defp feedback(text),
      do: %DTO.Feedback{kind: :notice, title: "Project", text: text}

    @auto_words "Auto · edits and safe commands run · Shift-Tab: Plan (this project)"

    defp metadata(state, mode, revision) do
      watch = state.watches.workspace

      Reducer.update(
        state,
        {:data,
         %Delivery{
           kind: :delta,
           watch_ref: watch.watch_ref,
           request_id: nil,
           scope: watch.scope,
           generation: watch.generation,
           revision: revision,
           sequence: watch.sequence + 1,
           body: %Delta{
             kind: :workspace_metadata,
             conversation_id: "c",
             body: struct(DTO.WorkspaceMetadata, conversation_id: "c", approval_mode: mode),
             revision: revision,
             sequence: watch.sequence + 1
           }
         }}
      )
    end

    test "the mode change arriving before the answer keeps the cycle's words" do
      {state, effects} = shift_tab(at(:read_only))
      [request] = requests(effects)

      {state, _} = metadata(state, :auto, 5)
      assert state.notice == {:command_feedback, @auto_words}
      # The change is still said in the transcript.
      assert [%{from: :read_only, to: :auto}] = state.policy_notices

      {state, _} =
        outcome(state, request, :accepted, [], feedback: feedback("Approval mode: auto"))

      assert state.notice == {:command_feedback, @auto_words}
    end

    test "the answer arriving before the mode change keeps the cycle's words too" do
      {state, effects} = shift_tab(at(:read_only))
      [request] = requests(effects)

      {state, _} =
        outcome(state, request, :accepted, [], feedback: feedback("Approval mode: auto"))

      assert state.notice == {:command_feedback, @auto_words}
      {state, _} = metadata(state, :auto, 5)
      assert state.notice == {:command_feedback, @auto_words}
    end

    test "a trust the step caused is said in the same notice" do
      {state, effects} = shift_tab(at(:read_only))
      [request] = requests(effects)
      {state, _} = metadata(state, :auto, 5)

      {state, _} =
        outcome(state, request, :accepted, [],
          feedback: feedback("Approvals: read-only → auto · this project is now trusted")
        )

      assert state.notice == {:command_feedback, @auto_words <> " · this project is now trusted"}
    end

    @plan_words "Plan · read-only tools, a plan first · Shift-Tab: Ask"
    @ask_words "Ask · writes and commands ask first · Shift-Tab: Auto (this project)"

    # cli020 qa2: the Plan step's /plan is a slash command; its answer
    # ("Plan mode enabled") replaced the step's words on the release.
    test "the /plan answer keeps the Plan step's words" do
      {state, effects} = shift_tab(at(:auto))
      [request] = requests(effects)
      assert state.notice == {:command_feedback, @plan_words}

      {state, _} =
        outcome(state, request, :accepted, [],
          feedback: %DTO.Feedback{kind: :notice, title: "Plan", text: "Plan mode enabled"}
        )

      assert state.notice == {:command_feedback, @plan_words}
    end

    test "the /plan answer of the Plan → Ask step keeps the Ask words" do
      {state, effects} = shift_tab(at(:auto, :plan))
      [plan, update] = requests(effects)

      {state, _} =
        outcome(state, update, :accepted, [], feedback: feedback("Approval mode: read-only"))

      {state, _} =
        outcome(state, plan, :accepted, [],
          feedback: %DTO.Feedback{kind: :notice, title: "Plan", text: "Plan mode disabled"}
        )

      assert state.notice == {:command_feedback, @ask_words}
    end

    test "a /plan answer after the step's window says the service's words" do
      {state, effects} = shift_tab(at(:auto))
      [request] = requests(effects)
      state = %{state | now: state.cycle_notice.at + 6_000}

      {state, _} =
        outcome(state, request, :accepted, [],
          feedback: %DTO.Feedback{kind: :notice, title: "Plan", text: "Plan mode enabled"}
        )

      assert state.notice == {:command_feedback, "Plan mode enabled"}
    end

    test "a mode changed some other way afterwards is said as itself" do
      {state, effects} = shift_tab(at(:read_only))
      [request] = requests(effects)
      {state, _} = metadata(state, :auto, 5)
      {state, _} = outcome(state, request, :accepted, [])
      {state, _} = metadata(state, :full_access, 6)

      assert state.notice ==
               {:command_feedback, "Approvals: auto → full access · nothing asks first"}
    end
  end
end
