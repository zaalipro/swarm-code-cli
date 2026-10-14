defmodule SwarmCodeCLI.UI.Home.OrbitReducerTest do
  @moduledoc """
  orbit U2: Home as a layer. It opens on the first frame, closes on Esc and on a
  destination change, keeps its draft and its position, asks the service for its
  overview one request at a time and drops the answers it did not ask for.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.OrbitHelpers

  alias SwarmCodeCLI.UI.{Home, Projector, Reducer, State}
  alias SwarmCodeCLI.UI.DataSource.DTO

  defp open_state(options \\ []) do
    {state, _} = start(options)
    state
  end

  defp overview_request(effects) do
    assert [request] = queries(effects, :home_overview)
    assert request.kind == {:home_overview, 6, 12, 131_072}
    assert request.origin == {:home, :overview}
    request
  end

  describe "the first frame" do
    test "Home is on it, over the conversation that opens underneath" do
      {state, effects} = start()
      assert %Home{generation: 1, focus: :composer} = state.home
      assert state.home.opened_over == {:conversation, conversation_id()}
      assert state.destination == {:conversation, conversation_id()}
      assert Enum.any?(effects, &match?({:watch, _}, &1))

      {scene, _table} = Projector.project(state)
      assert [%{id: "home"} | _] = scene.regions
    end

    test "without home? there is no Home" do
      {state, _} = start(home?: false)
      assert state.home == nil
      {scene, _table} = Projector.project(state)
      refute Enum.any?(scene.regions, &(&1.id == "home"))
    end

    test "a resume picker wins when both are set" do
      {state, _} = start(resume_picker?: true)
      assert state.home == nil
      assert state.pending_resume_picker
    end

    test "Settings covers Home (F2 from Home)" do
      state = open_state()
      {state, _} = step(state, {:settings_open, nil})
      assert state.settings != nil and state.home != nil
      {scene, _table} = Projector.project(state)
      assert [%{id: "settings"} | _] = scene.regions
    end

    test "Home's key context follows its focus and yields to a layer" do
      alias SwarmCodeCLI.UI.Keymap.Context
      state = open_state()
      assert Context.of(state) == :home_composer
      assert Context.of(%{state | home: %{state.home | focus: :list}}) == :home_list
      assert Context.of(%{state | home: %{state.home | focus: :map}}) == :home_map
      {opened, _} = step(state, {:open_layer, :help})
      assert Context.of(opened) == :dialog
    end
  end

  describe "Esc, /home and Alt-O" do
    test "Esc with an empty draft closes Home onto the conversation underneath" do
      state = open_state()
      {state, _} = step(state, {:home, :escape})
      assert state.home == nil
      assert state.destination == {:conversation, conversation_id()}
      assert %Home{} = state.home_resume
      {scene, _table} = Projector.project(state)
      refute Enum.any?(scene.regions, &(&1.id == "home"))
    end

    test "typed text survives closing and reopening, through Alt-O and /home" do
      state = open_state()
      {state, _} = type(state, "fix the flaky test")
      assert home_draft(state) == "fix the flaky test"
      assert State.current_draft_key(state) == {"orbit-epoch", :home}

      {state, _} = step(state, {:home, :escape})
      assert State.current_draft_key(state) == {conversation_id(), :main}
      assert home_draft(state) == "fix the flaky test"

      {reopened, _} = step(state, :open_home)
      assert %Home{generation: 2} = reopened.home
      assert home_draft(reopened) == "fix the flaky test"

      {state, _} = step(reopened, {:home, :escape})
      {state, _} = type(state, "/home")
      {state, _} = step(state, {:slash_local, :home})
      assert %Home{generation: 3} = state.home
      assert home_draft(state) == "fix the flaky test"

      assert Reducer.update(state, {:slash_local, :home})
             |> elem(0)
             |> Map.get(:home)
             |> Map.get(:generation) == 3
    end

    test "opening Home while Settings or a layer is open does nothing" do
      state = open_state(home?: false)
      {with_layer, _} = step(state, {:open_layer, :help})
      assert {^with_layer, []} = step(with_layer, :open_home)
    end

    test "the position comes back: the row, the orbit and the bead" do
      state = open_state()
      state = put_conversations(state, for(n <- 1..5, do: summary(n)))
      {state, _} = step(state, {:home, :down})
      {state, _} = step(state, {:home, :down})
      assert state.home.selected == 2
      state = %{state | home: %{state.home | orbit: 1, bead: 3}}
      {state, _} = step(state, {:home, :escape})
      {state, _} = step(state, :open_home)
      assert %Home{selected: 2, orbit: 1, bead: 3} = state.home
    end

    test "Esc from the list or the map returns to the composer" do
      state = open_state()
      {state, _} = step(state, {:home, :focus_next})
      assert state.home.focus == :list
      {state, _} = step(state, {:home, :escape})
      assert state.home.focus == :composer
      {state, _} = step(state, {:home, :focus_previous})
      assert state.home.focus == :map
      {state, _} = step(state, {:home, :focus_next})
      assert state.home.focus == :composer
    end
  end

  describe "the overview request" do
    test "waits for the shell, then asks once" do
      {state, _} = start(shell: :frozen)
      {state, effects} = step(state, :boot)
      assert queries(effects, :home_overview) == []
      assert state.home.overview_request == nil

      ready = ready_shell(state)
      {asked, effects} = step(ready, :boot)
      request = overview_request(effects)
      assert asked.home.overview_request == request.request_id

      {_, again} = step(asked, :boot)
      assert queries(again, :home_overview) == []
    end

    test "the list of conversations is asked for when the shell turns ready under an open Home" do
      {frozen, _} = start(shell: :frozen)
      ready = ready_shell(frozen)
      {_, effects} = Reducer.Home.after_update(frozen, ready)

      assert [%{kind: {:conversation_list, nil, 50, 262_144}}] =
               queries(effects, :conversation_list)
    end

    test "the answer is installed and ends the flight" do
      {state, effects} = step(open_state(), :boot)
      request = overview_request(effects)
      {state, effects} = answer_overview(state, request)
      assert effects == []
      assert %DTO.HomeOverview{state: :ready, revision: 3} = state.home.overview
      assert state.home.overview_request == nil
      assert state.home.seen_revision == 3
      assert state.requests == %{}
    end

    test "an answer for another request id is ignored" do
      {state, effects} = step(open_state(), :boot)
      request = overview_request(effects)
      foreign = %{request | request_id: "someone-elses"}
      state = %{state | requests: Map.put(state.requests, "someone-elses", foreign)}

      {state, _} = answer_overview(state, foreign)
      assert state.home.overview == nil
      assert state.home.overview_request == request.request_id
      refute Map.has_key?(state.requests, "someone-elses")
    end

    test "an answer of an earlier opening is dropped" do
      {state, effects} = step(open_state(), :boot)
      old = overview_request(effects)
      {state, cancels} = step(state, {:home, :escape})
      assert {:cancel_request, old.request_id} in cancels
      refute Map.has_key?(state.requests, old.request_id)

      {state, effects} = step(state, :open_home)
      new = overview_request(effects)
      assert new.request_id != old.request_id

      {state, _} = answer_overview(state, old)
      assert state.home.overview == nil
      {state, _} = answer_overview(state, new)
      assert %DTO.HomeOverview{} = state.home.overview
    end

    test "an error body is kept and nothing asks again until the revision moves" do
      {state, effects} = step(open_state(), :boot)
      request = overview_request(effects)

      error = %DTO.HomeOverview{
        request_id: request.request_id,
        state: :error,
        error: SwarmCodeCLI.UI.DataSource.AdmissionError.new(:not_allowed)
      }

      {state, effects} = respond(state, request, error)
      assert effects == []
      assert state.home.overview.state == :error

      {state, effects} = step(state, :boot)
      assert queries(effects, :home_overview) == []

      {state, effects} = stale(state, 4)
      assert [_] = queries(effects, :home_overview)
      assert state.read_model.home_revision == 4
    end

    test "a request the reducer dropped is forgotten and asked again" do
      {state, effects} = step(open_state(), :boot)
      request = overview_request(effects)
      state = %{state | requests: Map.delete(state.requests, request.request_id)}
      {state, effects} = step(state, :boot)
      assert [again] = queries(effects, :home_overview)
      assert again.request_id != request.request_id
      assert state.home.overview_request == again.request_id
    end
  end

  describe "home_stale" do
    test "one push while Home is open asks once, a second while in flight waits for the answer" do
      {state, effects} = step(open_state(), :boot)
      first = overview_request(effects)
      {state, _} = answer_overview(state, first)

      {state, effects} = stale(state, 5)
      second = overview_request(effects)
      assert state.home.overview_request == second.request_id

      {state, effects} = stale(state, 6)
      assert queries(effects, :home_overview) == []
      assert state.home.dirty?

      {state, effects} = answer_overview(state, second, &Map.put(&1, "revision", 5))
      third = overview_request(effects)
      refute state.home.dirty?
      assert state.home.overview_request == third.request_id

      {state, effects} = answer_overview(state, third, &Map.put(&1, "revision", 6))
      assert effects == []
      assert state.home.seen_revision == 6
    end

    test "a flood of pushes during one flight asks exactly twice in all" do
      {state, effects} = step(open_state(), :boot)
      first = overview_request(effects)

      {state, sent} =
        Enum.reduce(1..20, {state, []}, fn n, {acc, sent} ->
          {next, effects} = stale(acc, n)
          {next, sent ++ queries(effects, :home_overview)}
        end)

      assert sent == []
      {state, effects} = answer_overview(state, first, &Map.put(&1, "revision", 20))
      second = overview_request(effects)
      {state, effects} = answer_overview(state, second, &Map.put(&1, "revision", 20))
      assert effects == []
      assert state.home.seen_revision == 20
    end

    test "while Home is closed a push asks nothing, and opening asks once" do
      {state, effects} = step(open_state(), :boot)
      {state, _} = answer_overview(state, overview_request(effects))
      {state, _} = step(state, {:home, :escape})

      {state, effects} =
        Enum.reduce(1..5, {state, []}, fn n, {acc, sent} ->
          {next, effects} = stale(acc, n)
          {next, sent ++ effects}
        end)

      assert queries(effects, :home_overview) == []
      assert state.read_model.home_revision == 5

      {_, effects} = step(state, :open_home)
      assert [_] = queries(effects, :home_overview)
    end
  end

  describe "a destination change" do
    test "closes Home (D20)" do
      state = open_state()
      other = "1a2b3c4d-0000-4000-8000-000000000002"
      {state, _} = step(state, {:navigate, {:conversation, other}})
      assert state.home == nil
      assert %Home{focus: :composer} = state.home_resume
      assert state.destination == {:conversation, other}
    end

    test "an unchanged destination keeps it" do
      state = open_state()
      {state, _} = step(state, {:navigate, {:conversation, conversation_id()}})
      assert %Home{} = state.home
    end
  end

  describe "the list" do
    test "hides the empty conversations (D11) and keeps the others in order" do
      state =
        open_state()
        |> put_conversations([
          summary(1),
          summary(2, run_count: 0, last_prompt: nil),
          summary(3)
        ])

      assert Enum.map(Home.rows(state), & &1.title) == ["conversation 1", "conversation 3"]
      refute Home.empty_underneath?(state)

      only_empty = put_conversations(state, [summary(1, run_count: 0, last_prompt: nil)])
      assert Home.rows(only_empty) == []
      assert Home.empty_underneath?(only_empty)
    end

    test "the selection never leaves the rows" do
      state = open_state() |> put_conversations([summary(1), summary(2)])
      {state, _} = Enum.reduce(1..5, {state, []}, fn _, {acc, _} -> step(acc, {:home, :down}) end)
      assert state.home.selected == 1
      {state, _} = Enum.reduce(1..5, {state, []}, fn _, {acc, _} -> step(acc, {:home, :up}) end)
      assert state.home.selected == 0
    end
  end
end
