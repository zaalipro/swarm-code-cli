defmodule SwarmCodeCLI.Plain.OneShotFollowTest do
  @moduledoc """
  `ncode -p` follows the runs its runs launch (a swarm or workflow a tool
  started, transitively through `parent_run_id`), waits for them, reports
  them, and fails when one failed; a run parked as `paused` ends the wait
  with the way to continue and exit 1.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Test.OneShotHarness
  alias SwarmCodeCLI.Test.OneShotHarness, as: H
  alias SwarmCodeCLI.UI.DataSource.{Delta, DTO, Request}

  @swarm "66666666-6666-4666-8666-666666666666"
  @workflow "77777777-7777-4777-8777-777777777777"

  setup do
    source = start_supervised!({H.Source, self()})
    {:ok, output} = StringIO.open("")
    {:ok, error} = StringIO.open("")
    %{source: source, output: output, error: error}
  end

  defp child(id, kind, state, parent, extra \\ []) do
    struct!(
      %DTO.RunSummary{
        id: id,
        conversation_id: H.conversation(),
        kind: kind,
        state: state,
        title: "use 4 agents to review",
        parent_run_id: parent,
        created_sequence: 2,
        allowed_actions: [:stop]
      },
      extra
    )
  end

  defp child_update(session, %DTO.RunSummary{} = run) do
    body = %{run | revision: session.sequence + 1}

    delta(session, %Delta{
      kind: :run_update,
      entity_id: run.id,
      run_id: run.id,
      conversation_id: H.conversation(),
      body: body
    })
  end

  defp json(context), do: context.output |> text() |> String.trim() |> Jason.decode!()

  defp refute_completion_query,
    do: refute_receive({:source, {:request, :query, %Request{}}}, 200)

  test "waits for the swarm a chat run launched, then reports it and exits 0", context do
    session =
      start(context, format: :json)
      |> accept()
      |> run_update(:running)
      |> upsert(message("Launching the swarm."))
      |> child_update(child(@swarm, :swarm, :running, H.run_id()))
      |> run_update(:done)

    # The chat run is done, the swarm is not: nothing is concluded yet.
    refute_completion_query()
    refute_received {:code, _}

    session = child_update(session, child(@swarm, :swarm, :done, H.run_id()))
    complete(session, [run(:done), child(@swarm, :swarm, :done, H.run_id())], [message("ok")])
    assert code(session) == 0

    assert %{
             "exit_code" => 0,
             "state" => "done",
             "runs" => [
               %{"id" => run_id, "launched" => false},
               %{"id" => @swarm, "kind" => "swarm", "state" => "done", "launched" => true}
             ]
           } = json(context)

    assert run_id == H.run_id()
    assert text(context.error) =~ ~s(ncode: the swarm "use 4 agents to review" finished.)
  end

  test "a failed swarm fails the session and is named", context do
    session =
      start(context, format: :json)
      |> accept()
      |> run_update(:running)
      |> child_update(child(@swarm, :swarm, :running, H.run_id()))
      |> run_update(:done)
      |> child_update(child(@swarm, :swarm, :failed, H.run_id(), error: "worker crashed"))

    complete(
      session,
      [run(:done), child(@swarm, :swarm, :failed, H.run_id(), error: "worker crashed")],
      []
    )

    assert code(session) == 1

    assert %{"exit_code" => 1, "state" => "failed", "error" => error, "runs" => runs} =
             json(context)

    assert error == ~s(the swarm "use 4 agents to review" failed: worker crashed)
    assert Enum.map(runs, & &1["state"]) == ["done", "failed"]
    assert text(context.error) =~ ~s(ncode: the swarm "use 4 agents to review" failed: worker)
  end

  test "a run launched by a launched run is followed too", context do
    session =
      start(context, format: :json)
      |> accept()
      |> child_update(child(@swarm, :swarm, :done, H.run_id()))
      |> child_update(child(@workflow, :workflow, :running, @swarm, created_sequence: 3))
      |> run_update(:done)

    refute_completion_query()
    session = child_update(session, child(@workflow, :workflow, :done, @swarm))

    complete(
      session,
      [
        run(:done),
        child(@swarm, :swarm, :done, H.run_id()),
        child(@workflow, :workflow, :done, @swarm)
      ],
      []
    )

    assert code(session) == 0
    assert %{"runs" => runs} = json(context)
    assert Enum.map(runs, & &1["id"]) == [H.run_id(), @swarm, @workflow]
  end

  test "a launched run only the completion snapshot shows is waited for", context do
    session =
      start(context, format: :json)
      |> accept()
      |> run_update(:done)

    # The model never heard of the swarm; the final read does.
    complete(session, [run(:done), child(@swarm, :swarm, :running, H.run_id())], [])
    refute_received {:code, _}

    session = child_update(session, child(@swarm, :swarm, :done, H.run_id()))
    complete(session, [run(:done), child(@swarm, :swarm, :done, H.run_id())], [])
    assert code(session) == 0
    assert %{"runs" => [_, %{"id" => @swarm, "state" => "done"}]} = json(context)
  end

  test "a paused workflow ends the wait with why and how to continue, exit 1", context do
    why = "The model provider has been unreachable for over three minutes."
    paused = child(@workflow, :workflow, :paused, H.run_id(), error: why, title: "review flow")

    session =
      start(context, format: :json)
      |> accept()
      |> run_update(:running)
      |> run_update(:done)
      |> child_update(paused)

    complete(session, [run(:done), paused], [])
    assert code(session) == 1

    assert %{"exit_code" => 1, "state" => "paused", "error" => error, "runs" => runs} =
             json(context)

    assert error =~ ~s(the workflow "review flow" paused: The model provider has been unreachable)
    assert Enum.map(runs, & &1["state"]) == ["done", "paused"]

    err = text(context.error)
    assert err =~ "ncode --resume #{H.conversation()}"
    assert err =~ "/resume-run"
    assert err =~ "unreachable for over three minutes"
  end

  test "a paused workflow waits until the swarm beside it has ended", context do
    paused = child(@workflow, :workflow, :paused, H.run_id(), created_sequence: 3)

    session =
      start(context, format: :json)
      |> accept()
      |> child_update(child(@swarm, :swarm, :running, H.run_id()))
      |> child_update(paused)
      |> run_update(:done)

    refute_completion_query()
    session = child_update(session, child(@swarm, :swarm, :done, H.run_id()))
    complete(session, [run(:done), child(@swarm, :swarm, :done, H.run_id()), paused], [])
    assert code(session) == 1
    assert %{"state" => "paused"} = json(context)
  end

  test "--max-budget-usd counts the launched swarm's cost and stops every live run", context do
    session =
      start(context, max_budget_usd: 0.05)
      |> accept()
      |> child_update(child(@swarm, :swarm, :running, H.run_id(), cost_usd: 0.01))
      |> run_update(:done, cost_usd: 0.03)

    refute_receive {:source, {:request, :command, _}}, 100
    session = child_update(session, child(@swarm, :swarm, :running, H.run_id(), cost_usd: 0.04))

    assert_receive {:source, {:request, :command, %Request{kind: {:run_control, :stop, @swarm}}}},
                   5_000

    session = child_update(session, child(@swarm, :swarm, :stopped, H.run_id(), cost_usd: 0.04))

    complete(
      session,
      [run(:done, cost_usd: 0.03), child(@swarm, :swarm, :stopped, H.run_id(), cost_usd: 0.04)],
      []
    )

    assert code(session) == 1
    assert text(context.error) =~ "stopped at --max-budget-usd 0.05 (the runs cost $0.07)."
  end
end
