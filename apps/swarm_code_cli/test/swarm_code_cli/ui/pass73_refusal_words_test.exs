defmodule SwarmCodeCLI.UI.Pass73RefusalWordsTest do
  @moduledoc """
  pass73 T3/T8: the footer said "The daemon refused that request" when a
  `/compact` or a `/plan` was sent while work ran. A request SwarmCode did not
  carry out now says why and what to do, in words, and never that sentence.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Paint, Projector, Size, State}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}
  alias SwarmCodeCLI.UI.Projector.Status

  @size %Size{columns: 170, rows: 40}

  test "a refused send says it was not sent, why, and what to do" do
    state = refused(base(), :rejected)
    row = status(state)
    refute row =~ "daemon"
    refute row =~ "refused that request"
    assert row =~ "Not sent: SwarmCode turned it down · try again, or see cli.log for why"
  end

  test "the typed reason the daemon gave picks the words" do
    key = State.current_draft_key(base())

    state =
      base()
      |> refused(:rejected)
      |> Map.put(:mutation_reasons, %{{:draft, key} => :capacity_exceeded})

    assert status(state) =~
             "Not sent: too much is in flight at once · wait a moment and send it again"

    state =
      Map.put(state, :mutation_reasons, %{{:draft, key} => %{reason: "the project is gone"}})

    assert status(state) =~ "Not sent: the project is gone"
  end

  test "K's refused delivery of this conversation gives the words when the outcome has none" do
    state = refused(base(), :rejected)
    {conversation, _} = State.current_draft_key(state)

    state =
      Map.put(state, :deliveries, [
        %{
          id: "d1",
          conversation_id: conversation,
          run_id: nil,
          text: "hi",
          status: :refused,
          at: 1,
          reason: "the conversation was deleted"
        }
      ])

    assert status(state) =~ "Not sent: the conversation was deleted"
  end

  test "every outcome that did not go through reads as a sentence with a next step" do
    for outcome <- [:rejected, :deadline_exceeded, :revision_conflict, :outcome_unknown] do
      row = status(refused(base(), outcome))
      assert row =~ " · ", "#{outcome}: #{row}"
      refute row =~ "daemon"
    end
  end

  test "each known reason has its own words, and an answer is 'Not answered'" do
    reasons = [
      :not_allowed,
      :stale_revision,
      :capacity_exceeded,
      :deadline_expired,
      :source_unavailable,
      :request_conflict,
      :invalid_request,
      "untrusted",
      "read_only",
      "no_provider",
      "not_found"
    ]

    words = Enum.map(reasons, &Status.refusal_words({:draft, {"c", :main}}, &1))
    assert length(Enum.uniq(words)) == length(reasons)
    assert Enum.all?(words, &String.starts_with?(&1, "Not sent: "))

    assert Status.refusal_words({:interaction, "a", 1}, :stale_revision) ==
             "Not answered: it changed meanwhile · look at it again and retry"

    # A code this client does not know yet still reads as words.
    assert Status.refusal_words({:draft, {"c", :main}}, "turn_still_running") ==
             "Not sent: turn still running · try again, or see cli.log for why"

    assert Status.refusal_words({:run, "r"}, "untrusted") ==
             "Not done: the project is not trusted · /trust trusts it"
  end

  describe "the approval-policy change (T7)" do
    test "names both modes the way the status row does" do
      assert Status.policy_words(:auto, :full_access) == "Approvals: auto → full access"
      assert Status.policy_words(:read_only, :auto) == "Approvals: read-only → auto"
      assert Status.policy_words(nil, "read_only") == "Approvals: read-only"

      assert Status.policy_words(:auto, :full_access, true) ==
               "Approvals: auto → full access · nothing asks first"

      assert Status.policy_words(:full_access, :auto, true) ==
               "Approvals: full access → auto · edits go ahead, commands ask first"
    end
  end

  defp base do
    %{Fixtures.representative(:chat, @size, %Capabilities{size: @size}) | focus: "composer"}
  end

  defp refused(state, outcome) do
    key = State.current_draft_key(state)
    %{state | mutations: Map.put(state.mutations, {:draft, key}, {:settled, "req-1", outcome})}
  end

  defp status(state) do
    {scene, _} = Projector.project(state)
    {:ok, plan} = Paint.build(scene, %Options{color_mode: :truecolor})
    y = state.size.rows - 1

    0..(state.size.columns - 1)
    |> Enum.map_join("", fn x ->
      case Plan.cell(plan, x, y) do
        {:glyph, g, _, _} -> g
        _ -> " "
      end
    end)
  end
end
