defmodule SwarmCodeCLI.UI.Pass73DeliveryTest do
  @moduledoc """
  pass73 T3/T8 (client side): every message sent while runs are live is
  recorded until the daemon says where it went (steered into the running
  turn, queued behind it, started a run) or why it was not sent, with the
  draft kept. T7: a change of the project's approval mode, however it
  happens, is noted for the transcript and said on the status line.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.Reducer
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, DTO, Delivery, Delta}

  defp sent(state, text) do
    {state, effects} = state |> paste(text) |> send()
    [request] = requests(effects)
    {state, request}
  end

  test "a send while idle starts a run" do
    {state, request} = sent(ready(), "hello")
    assert [%{status: :sending, text: "hello", turn_id: nil, id: id}] = state.deliveries
    assert id == request.request_id

    {state, _} = outcome(state, request, :accepted, ["new-run"])
    assert [%{status: :started, run_id: "new-run"}] = state.deliveries
  end

  test "a message to the running chat turn is marked steered" do
    {state, request} = sent(ready([run("t", :streaming)]), "  also check the router  ")
    assert [%{status: :sending, text: "also check the router", turn_id: "t"}] = state.deliveries

    {state, _} = outcome(state, request, :accepted, ["t"])
    assert [%{status: :steered, run_id: "t"}] = state.deliveries

    # The daemon may also say so in words.
    {state, request} = sent(ready([run("t", :running)]), "and the tests")

    {state, _} =
      outcome(state, request, :accepted, [],
        feedback: %DTO.Feedback{kind: :notice, title: "Steer", text: "Sent to the running turn."}
      )

    assert [%{status: :steered, run_id: "t"}] = state.deliveries
  end

  test "a message the daemon queues is marked queued" do
    {state, request} = sent(ready([run("t", :queued)]), "after that, deploy")

    {state, _} =
      outcome(state, request, :accepted, ["c"],
        feedback: %DTO.Feedback{
          kind: :notice,
          title: "Queue",
          text: "Queued; it starts when this turn ends."
        }
      )

    assert [%{status: :queued}] = state.deliveries
  end

  test "a refusal says why in words and keeps the draft; Enter tries again" do
    {state, request} = sent(ready([run("t", :running)]), "/compact")
    {state, _} = outcome(state, request, :rejected, [])

    assert [%{status: :refused, reason: "it is not allowed right now"}] = state.deliveries

    assert state.notice ==
             {:command_feedback,
              "Not sent: it is not allowed right now. Your draft is kept; Enter tries again."}

    assert text(state) == "/compact"
    refute state.notice == {:command_feedback, "The daemon refused that request"}

    {state, request} = sent(ready(), "hello")

    {state, _} =
      outcome(state, request, :rejected, [], error: AdmissionError.new(:capacity_exceeded))

    assert [%{status: :refused, reason: "SwarmCode is busy"}] = state.deliveries

    {state, request} = sent(ready(), "hello")
    {state, _} = outcome(state, request, :deadline_exceeded, [])
    assert [%{status: :refused, reason: "SwarmCode did not answer in time"}] = state.deliveries
  end

  test "Enter again before the daemon answers says it is still sending" do
    {state, _request} = sent(ready([run("t", :running)]), "first")
    {state, effects} = send(state)
    assert requests(effects) == []
    assert state.notice == {:command_feedback, "Still sending the last message; one moment."}
  end

  describe "with the daemon's disposition and reason (pass73 S)" do
    alias SwarmCodeCLI.UI.Reducer.Deliveries

    defp settle(state, request, fields) do
      outcome = Map.merge(%DTO.Outcome{request_id: request.request_id}, Map.new(fields))
      Deliveries.settled(state, request, outcome)
    end

    test "the disposition decides, whatever the words" do
      {state, request} = sent(ready([run("t", :running)]), "look at the router")

      assert [%{status: :steered, run_id: "t"}] =
               settle(state, request,
                 status: :accepted,
                 identifiers: ["t"],
                 disposition: :steered
               ).deliveries

      assert [%{status: :queued}] =
               settle(state, request, status: :accepted, identifiers: [], disposition: :queued).deliveries

      assert [%{status: :started, run_id: "s"}] =
               settle(state, request,
                 status: :accepted,
                 identifiers: ["s"],
                 disposition: :started
               ).deliveries
    end

    test "a refusal's own sentence is the status line, alone" do
      {state, request} = sent(ready(), "/compact")

      state =
        settle(state, request,
          status: :rejected,
          error: AdmissionError.new(:not_allowed),
          reason: %{
            code: "nothing_to_compact",
            text: "Nothing to compact yet: this conversation has no history to summarise."
          }
        )

      assert [%{status: :refused, reason: "Nothing to compact yet" <> _}] = state.deliveries

      assert state.notice ==
               {:command_feedback,
                "Nothing to compact yet: this conversation has no history to summarise."}
    end
  end

  test "a workflow message is recorded as the user typed it" do
    {state, request} = sent(ready(), "make a workflow for releases")

    assert request.kind ==
             {:dispatch, :send, "/create-workflow make a workflow for releases", :main, []}

    assert [%{text: "make a workflow for releases"}] = state.deliveries
  end

  test "at most fifty are kept, newest first" do
    state =
      Enum.reduce(1..55, ready(), fn n, state ->
        {state, request} = sent(state, "m#{n}")
        {state, _} = outcome(state, request, :accepted, ["r#{n}"])
        state
      end)

    assert length(state.deliveries) == 50
    assert hd(state.deliveries).text == "m55"
  end

  describe "T7: the approval policy" do
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

    test "a change of mode, from anywhere, is noted once and said" do
      state = ready([], snapshot: %{approval_mode: :auto})
      assert state.policy_notices == []

      {state, _} = metadata(state, :full_access, 5)
      assert [%{from: :auto, to: :full_access, conversation_id: "c"}] = state.policy_notices

      assert state.notice ==
               {:command_feedback, "Approvals: auto → full access · nothing asks first"}

      # The same mode again is not a change.
      {state, _} = metadata(state, :full_access, 6)
      assert length(state.policy_notices) == 1

      {state, _} = metadata(state, :read_only, 7)
      assert [%{from: :full_access, to: :read_only} | _] = state.policy_notices

      assert state.notice ==
               {:command_feedback,
                "Approvals: full access → read-only · nothing is written or run without you"}
    end

    test "a change that arrives with a fresh snapshot is noticed too" do
      state = ready([], snapshot: %{approval_mode: :read_only})
      {state, _} = watch_ready(state, [], %{approval_mode: :auto}, 9)
      assert [%{from: :read_only, to: :auto}] = state.policy_notices

      assert state.notice ==
               {:command_feedback,
                "Approvals: read-only → auto · edits go ahead, commands ask first"}
    end

    test "the service's answer after the change keeps the change's words" do
      state = ready([], snapshot: %{approval_mode: :auto})
      {state, effects} = state |> paste("/approval full") |> send()
      [request] = requests(effects)
      {state, _} = metadata(state, :full_access, 5)

      {state, _} =
        outcome(state, request, :accepted, [],
          feedback: %DTO.Feedback{
            kind: :notice,
            title: "Project",
            text: "Approval mode: full access"
          }
        )

      assert state.notice ==
               {:command_feedback, "Approvals: auto → full access · nothing asks first"}
    end

    test "the first snapshot is not a change" do
      state = ready([], snapshot: %{approval_mode: :read_only})
      assert state.policy_notices == []
      refute match?({:command_feedback, "Approvals:" <> _}, state.notice)
    end
  end
end
