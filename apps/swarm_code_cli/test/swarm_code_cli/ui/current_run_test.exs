defmodule SwarmCodeCLI.UI.CurrentRunTest do
  @moduledoc """
  Which run a conversation shows. A sent message starts a new run, and the
  transcript, the run card and the tab row all follow `Support.run/1`, so it
  has to land on that run or the reply streams into a tab nobody is watching.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Size}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Projector.{Shell, Support}

  @size %Size{columns: 170, rows: 40}

  test "a conversation's current run is its newest, whatever its id sorts like" do
    state = with_runs([{"zzz-first", 1}, {"aaa-second", 2}])
    assert %{id: "aaa-second"} = Support.run(state)

    # The tab row leads with the same run, so the stripe and the transcript agree.
    assert [%{id: "aaa-second"} | _] = Shell.tabline_runs(state)
  end

  test "a run destination shows that run, newest or not" do
    state = %{with_runs([{"first", 1}, {"second", 2}]) | destination: {:run, "first"}}
    assert %{id: "first"} = Support.run(state)
  end

  test "runs of other conversations never become current" do
    state = with_runs([{"mine", 1}])

    other = %DTO.RunSummary{
      id: "theirs",
      conversation_id: "other-conversation",
      created_sequence: 9,
      title: "Elsewhere",
      revision: 1,
      state: :running,
      allowed_actions: []
    }

    state = %{
      state
      | read_model: %{state.read_model | runs: Map.put(state.read_model.runs, "theirs", other)}
    }

    assert %{id: "mine"} = Support.run(state)
  end

  test "a conversation with no runs has no current run" do
    state = with_runs([])
    assert Support.run(state) == nil
  end

  # A representative shell on a conversation, with exactly these runs in it,
  # each `{id, created_sequence}`.
  defp with_runs(specs) do
    state = Fixtures.representative(:chat, @size, %Capabilities{size: @size})
    conversation = "conversation-under-test"

    runs =
      Map.new(specs, fn {id, sequence} ->
        {id,
         %DTO.RunSummary{
           id: id,
           conversation_id: conversation,
           created_sequence: sequence,
           title: "Run " <> id,
           revision: 1,
           state: :running,
           allowed_actions: [:pause, :stop, :mark_seen]
         }}
      end)

    %{
      state
      | destination: {:conversation, conversation},
        read_model: %{state.read_model | runs: runs, order: %{}}
    }
  end
end
