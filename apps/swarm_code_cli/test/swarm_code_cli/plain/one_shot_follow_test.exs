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
             "reason" => nil,
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

    assert %{
             "exit_code" => 1,
             "state" => "failed",
             "reason" => "run_failed",
             "error" => error,
             "runs" => runs
           } = json(context)

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

    assert %{
             "exit_code" => 1,
             "state" => "paused",
             "reason" => "paused_workflow",
             "error" => error,
             "runs" => runs
           } = json(context)

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

  describe "a limit that fired before a launched run was heard of" do
    test "--max-budget-usd stops a run whose first update comes after the crossing one",
         context do
      session =
        start(context, format: :json, max_budget_usd: 0.05)
        |> accept()
        |> run_update(:running, cost_usd: 0.06)

      # The chat run crossed the limit; the swarm it launched is not known yet.
      assert_receive {:source, {:request, :command, %Request{kind: {:run_control, :stop, id}}}},
                     5_000

      assert id == H.run_id()
      refute_receive {:source, {:request, :command, _}}, 100

      session = child_update(session, child(@swarm, :swarm, :running, H.run_id()))

      assert_receive {:source,
                      {:request, :command, %Request{kind: {:run_control, :stop, @swarm}}}},
                     5_000

      # Asked once, not on every update that follows.
      session = child_update(session, child(@swarm, :swarm, :running, H.run_id()))
      refute_receive {:source, {:request, :command, _}}, 100

      session =
        session
        |> run_update(:stopped, cost_usd: 0.06)
        |> child_update(child(@swarm, :swarm, :stopped, H.run_id()))

      complete(
        session,
        [run(:stopped, cost_usd: 0.06), child(@swarm, :swarm, :stopped, H.run_id())],
        []
      )

      assert code(session) == 1
      assert %{"reason" => "max_budget", "runs" => runs} = json(context)
      assert Enum.map(runs, & &1["state"]) == ["stopped", "stopped"]
      assert text(context.error) =~ "stopped at --max-budget-usd 0.05"
    end

    test "--max-turns stops a run whose first update comes after the crossing one", context do
      session =
        start(context, format: :json, max_turns: 2)
        |> accept()
        |> run_update(:running)
        |> agent_update(3)

      assert_receive {:source, {:request, :command, %Request{kind: {:run_control, :stop, id}}}},
                     5_000

      assert id == H.run_id()

      session = child_update(session, child(@workflow, :workflow, :running, H.run_id()))

      assert_receive {:source,
                      {:request, :command, %Request{kind: {:run_control, :stop, @workflow}}}},
                     5_000

      session =
        session
        |> run_update(:stopped)
        |> child_update(child(@workflow, :workflow, :stopped, H.run_id()))

      complete(session, [run(:stopped), child(@workflow, :workflow, :stopped, H.run_id())], [])
      assert code(session) == 1
      assert %{"reason" => "max_turns", "runs" => [_, %{"id" => @workflow}]} = json(context)
    end

    test "a run discovered later that offers no stop ends the session, reported as running",
         context do
      session =
        start(context, format: :json, max_budget_usd: 0.05)
        |> accept()
        |> run_update(:running, cost_usd: 0.06)

      assert_receive {:source, {:request, :command, %Request{kind: {:run_control, :stop, _}}}},
                     5_000

      child_update(
        session,
        child(@swarm, :swarm, :running, H.run_id(), allowed_actions: [])
      )

      assert code(session) == 1
      assert %{"reason" => "max_budget", "runs" => runs} = json(context)

      assert Enum.map(runs, &{&1["id"], &1["state"]}) == [
               {H.run_id(), "running"},
               {@swarm, "running"}
             ]
    end
  end

  describe "runs without a cap" do
    @count 70

    defp numbered(n),
      do: "88888888-8888-4888-8888-" <> String.pad_leading(Integer.to_string(n), 12, "0")

    defp workflow(n, state, extra \\ []) do
      child(
        numbered(n),
        :workflow,
        state,
        H.run_id(),
        [created_sequence: n + 1, title: "flow #{n}"] ++ extra
      )
    end

    defp heard(session, runs), do: Enum.reduce(runs, session, &child_update(&2, &1))

    test "a failed run past the 64th is waited for, named, and fails the session", context do
      all =
        for n <- 1..@count,
            do: if(n == 66, do: workflow(n, :failed, error: "boom"), else: workflow(n, :done))

      session =
        start(context, format: :json)
        |> accept()
        |> heard(all)
        |> run_update(:done)

      complete(session, [run(:done) | all], [])
      assert code(session) == 1

      summary = json(context)
      assert %{"exit_code" => 1, "state" => "failed", "reason" => "run_failed"} = summary
      assert summary["error"] == ~s(the workflow "flow 66" failed: boom)
      assert length(summary["runs"]) == @count + 1
      assert numbered(@count) in Enum.map(summary["runs"], & &1["id"])
      assert Enum.count(summary["runs"], &(&1["state"] == "failed")) == 1
      assert text(context.error) =~ ~s(ncode: the workflow "flow 70" finished.)
    end

    test "a run past the 64th that is still running holds the session until it ends", context do
      early = for n <- 1..(@count - 1), do: workflow(n, :done)

      session =
        start(context, format: :json)
        |> accept()
        |> heard(early)
        |> child_update(workflow(@count, :running))
        |> run_update(:done)

      refute_completion_query()
      refute_received {:code, _}

      last = workflow(@count, :done)
      session = child_update(session, last)
      complete(session, [run(:done) | early] ++ [last], [])
      assert code(session) == 0

      assert %{"runs" => runs} = json(context)
      assert length(runs) == @count + 1
      assert Enum.all?(runs, &(&1["state"] == "done"))
    end

    test "a followed run the snapshot's page no longer holds is read from the deltas",
         context do
      all = for n <- 1..@count, do: workflow(n, :done)

      session =
        start(context, format: :json)
        |> accept()
        |> heard(all)
        |> run_update(:done)

      complete(session, [run(:done) | Enum.drop(all, 10)], [])
      assert code(session) == 0
      assert %{"runs" => runs} = json(context)
      assert length(runs) == @count + 1
    end
  end

  describe "the error of a mixed outcome" do
    test "names the first run that did not finish, not a launched run that did", context do
      swarm = child(@swarm, :swarm, :done, H.run_id(), title: "good swarm")

      broken =
        child(@workflow, :workflow, :failed, H.run_id(),
          created_sequence: 3,
          title: "bad flow",
          error: "worker crashed"
        )

      session =
        start(context, format: :json)
        |> accept()
        |> child_update(swarm)
        |> child_update(broken)
        |> run_update(:done)

      complete(session, [run(:done), swarm, broken], [])
      assert code(session) == 1

      assert %{"error" => error, "state" => "failed", "runs" => runs} = json(context)
      assert error == ~s(the workflow "bad flow" failed: worker crashed)
      assert Enum.map(runs, & &1["state"]) == ["done", "done", "failed"]

      stderr = text(context.error)
      assert stderr =~ ~s(ncode: the swarm "good swarm" finished.)
      assert stderr =~ ~s(ncode: the workflow "bad flow" failed: worker crashed)
    end

    test "is the pause sentence when a finished run precedes a paused one", context do
      swarm = child(@swarm, :swarm, :done, H.run_id(), title: "good swarm")

      paused =
        child(@workflow, :workflow, :paused, H.run_id(),
          created_sequence: 3,
          title: "parked flow",
          error: "provider down"
        )

      session =
        start(context, format: :json)
        |> accept()
        |> child_update(swarm)
        |> child_update(paused)
        |> run_update(:done)

      complete(session, [run(:done), swarm, paused], [])
      assert code(session) == 1
      assert %{"error" => error, "state" => "paused"} = json(context)
      assert error =~ ~s(the workflow "parked flow" paused: provider down)
    end
  end

  describe "a finished workflow whose launch is pending" do
    @continuation "99999999-9999-4999-8999-999999999999"
    @compaction "88888888-8888-4888-8888-888888888888"

    defp pending_flag(context) do
      {:ok, flag} = Agent.start_link(fn -> true end)
      on_exit(fn -> if Process.alive?(flag), do: Agent.stop(flag) end)
      Map.put(context, :pending, flag)
    end

    defp pending?(%{pending: flag}), do: fn _id -> Agent.get(flag, & &1) end

    test "is waited for, and the turn it starts is followed to its end", context do
      context = pending_flag(context)
      flow = child(@workflow, :workflow, :done, H.run_id(), title: "review flow")

      session =
        start(context, format: :json, launch_pending?: pending?(context))
        |> accept()
        |> child_update(flow)
        |> run_update(:done)

      # Both rows read done; the workflow's launch has not happened.
      refute_completion_query()
      refute_received {:code, _}

      continuation =
        child(@continuation, :chat, :running, @workflow,
          created_sequence: 3,
          title: "[workflow review flow finished]"
        )

      session = child_update(session, continuation)
      # The recheck timer reads the flag on its own schedule: the one-shot must
      # have heard the continuation before the launch is reported made, or it
      # (rightly) concludes on the two ended rows and asks for the completion.
      _ = :sys.get_state(session.owner)
      Agent.update(context.pending, fn _ -> false end)
      refute_completion_query()

      done = %{continuation | state: :done}
      session = child_update(session, done)
      complete(session, [run(:done), flow, done], [])
      assert code(session) == 0

      assert %{"exit_code" => 0, "runs" => runs} = json(context)

      assert [
               %{"launched" => false},
               %{"id" => @workflow, "launched" => true},
               %{"id" => @continuation, "kind" => "chat", "launched" => true, "state" => "done"}
             ] = runs

      assert text(context.error) =~
               ~s(ncode: the chat "[workflow review flow finished]" finished.)
    end

    # The workflow handed its continuation to a compaction (a run it launched)
    # and a chain task: once the compaction has ended, every row reads done and
    # the turn exists nowhere but in that task.
    test "is waited for when its compaction has ended and only the chained turn is left",
         context do
      context = pending_flag(context)
      flow = child(@workflow, :workflow, :done, H.run_id(), title: "review flow")

      compaction =
        child(@compaction, :chat, :done, @workflow, created_sequence: 3, title: "/compact")

      session =
        start(context, format: :json, launch_pending?: pending?(context), recheck_ms: 1)
        |> accept()
        |> child_update(flow)
        |> child_update(compaction)
        |> run_update(:done)

      refute_completion_query()
      refute_received {:code, _}

      continuation =
        child(@continuation, :chat, :running, @workflow,
          created_sequence: 4,
          title: "[workflow review flow finished]"
        )

      session = child_update(session, continuation)
      _ = :sys.get_state(session.owner)
      Agent.update(context.pending, fn _ -> false end)
      refute_completion_query()

      done = %{continuation | state: :done}
      session = child_update(session, done)
      complete(session, [run(:done), flow, compaction, done], [])
      assert code(session) == 0

      assert %{"exit_code" => 0, "runs" => runs} = json(context)
      assert Enum.map(runs, & &1["id"]) == [H.run_id(), @workflow, @compaction, @continuation]
      assert text(context.error) =~ ~s(ncode: the chat "/compact" finished.)
    end

    test "is not waited for once it has launched nothing", context do
      context = pending_flag(context)
      flow = child(@workflow, :workflow, :done, H.run_id(), title: "review flow")

      session =
        start(context, format: :json, launch_pending?: pending?(context), recheck_ms: 10)
        |> accept()
        |> child_update(flow)
        |> run_update(:done)

      refute_completion_query()
      Agent.update(context.pending, fn _ -> false end)

      complete(session, [run(:done), flow], [])
      assert code(session) == 0
      assert %{"runs" => [_, %{"id" => @workflow}]} = json(context)
    end

    # Running out of rechecks was once taken for "launched nothing" (a 10 s
    # cap): a launch that waits on a hook past it was dropped and the session
    # reported success. Only the launch ending ends the wait.
    test "is waited for however many times it is asked, and never reported as success",
         context do
      test = self()
      {:ok, asked} = Agent.start_link(fn -> 0 end)
      {:ok, held} = Agent.start_link(fn -> true end)

      pending? = fn id ->
        if id == @workflow do
          n = Agent.get_and_update(asked, &{&1 + 1, &1 + 1})
          send(test, {:asked, n})
          Agent.get(held, & &1)
        else
          false
        end
      end

      flow = child(@workflow, :workflow, :done, H.run_id(), title: "review flow")

      session =
        start(context, format: :json, launch_pending?: pending?, recheck_ms: 1)
        |> accept()
        |> child_update(flow)
        |> run_update(:done)

      # Far past any budget a test or a user could have set, and still waiting.
      assert_receive {:asked, 150}, 10_000
      refute_completion_query()
      refute_received {:code, _}

      continuation =
        child(@continuation, :chat, :running, @workflow,
          created_sequence: 3,
          title: "[workflow review flow finished]"
        )

      session = child_update(session, continuation)
      _ = :sys.get_state(session.owner)
      Agent.update(held, fn _ -> false end)
      refute_completion_query()

      done = %{continuation | state: :done}
      session = child_update(session, done)
      complete(session, [run(:done), flow, done], [])
      assert code(session) == 0
      assert %{"runs" => [_, _, %{"id" => @continuation, "state" => "done"}]} = json(context)
    end

    test "a launch that fails is the session's failure once it has been waited for", context do
      context = pending_flag(context)
      flow = child(@workflow, :workflow, :done, H.run_id(), title: "review flow")

      session =
        start(context, format: :json, launch_pending?: pending?(context), recheck_ms: 1)
        |> accept()
        |> child_update(flow)
        |> run_update(:done)

      refute_completion_query()

      broken =
        child(@continuation, :chat, :failed, @workflow,
          created_sequence: 3,
          title: "[workflow review flow finished]",
          error: "provider refused"
        )

      session = child_update(session, broken)
      _ = :sys.get_state(session.owner)
      Agent.update(context.pending, fn _ -> false end)

      complete(session, [run(:done), flow, broken], [])
      assert code(session) == 1

      assert %{"state" => "failed", "reason" => "run_failed", "error" => error} = json(context)
      assert error =~ ~s(the chat "[workflow review flow finished]" failed: provider refused)
    end

    test "is asked again about a workflow only the completion snapshot showed", context do
      context = pending_flag(context)
      Agent.update(context.pending, fn _ -> false end)
      flow = child(@workflow, :workflow, :done, H.run_id(), title: "review flow")

      session =
        start(context, format: :json, launch_pending?: pending?(context))
        |> accept()
        |> run_update(:done)

      # The model never heard of the workflow, so nobody asked about its launch
      # before this read; the read may predate that launch's row.
      complete(session, [run(:done), flow], [])
      refute_received {:code, _}

      continuation = child(@continuation, :chat, :done, @workflow, created_sequence: 3)
      complete(session, [run(:done), flow, continuation], [])
      assert code(session) == 0
      assert %{"runs" => [_, _, %{"id" => @continuation}]} = json(context)
    end

    test "does not outlive a signal: SIGTERM ends the wait with its own code", context do
      flow = child(@workflow, :workflow, :done, H.run_id(), title: "review flow")

      session =
        start(context, format: :json, launch_pending?: fn _id -> true end, recheck_ms: 1)
        |> accept()
        |> child_update(flow)
        |> run_update(:done)

      refute_completion_query()
      SwarmCodeCLI.Release.Signals.notify(session.task.pid, :sigterm)

      assert code(session) == 143
      assert %{"exit_code" => 143, "reason" => "sigterm"} = json(context)
      assert text(context.error) =~ "ncode: stopped by SIGTERM"
    end

    test "a limit still stops the turn the launch made while it was waited for", context do
      context = pending_flag(context)
      flow = child(@workflow, :workflow, :done, H.run_id(), title: "review flow")

      session =
        start(context,
          format: :json,
          launch_pending?: pending?(context),
          recheck_ms: 1,
          max_budget_usd: 0.05
        )
        |> accept()
        |> child_update(flow)
        |> run_update(:done)

      refute_completion_query()
      continuation = child(@continuation, :chat, :running, @workflow, created_sequence: 3)
      session = child_update(session, %{continuation | cost_usd: 0.06})

      assert_receive {:source,
                      {:request, :command, %Request{kind: {:run_control, :stop, @continuation}}}},
                     5_000

      stopped = %{continuation | state: :stopped, cost_usd: 0.06}
      session = child_update(session, stopped)
      Agent.update(context.pending, fn _ -> false end)

      complete(session, [run(:done), flow, stopped], [])
      assert code(session) == 1
      assert %{"reason" => "max_budget", "state" => "stopped"} = json(context)
    end

    test "does not hold a paused run, which launches nothing", context do
      paused = child(@workflow, :workflow, :paused, H.run_id(), error: "parked")

      session =
        start(context, format: :json, launch_pending?: fn id -> id == @workflow end)
        |> accept()
        |> child_update(paused)
        |> run_update(:done)

      complete(session, [run(:done), paused], [])
      assert code(session) == 1
      assert %{"state" => "paused"} = json(context)
    end

    test "does not hold a chat or swarm that lingers: only a workflow launches after it ends",
         context do
      session =
        start(context, format: :json, launch_pending?: fn _id -> true end)
        |> accept()
        |> child_update(child(@swarm, :swarm, :done, H.run_id()))
        |> run_update(:done)

      complete(session, [run(:done), child(@swarm, :swarm, :done, H.run_id())], [])
      assert code(session) == 0
    end
  end
end
