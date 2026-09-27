defmodule SwarmCode.Daemon.Service.C75AgentStatusTest do
  @moduledoc """
  pass75 (tasks 111-113): the Summarizer. `AgentStatus` decides when an agent
  gets an AI status line (change gating, debounce, the per-run cap, the
  final call of a stopped agent), which result wins and whether an answer is
  honest; `PersistedBackend` starts one owned task per call, holds the line
  on the agent's wire body and reads the user's cli.json switch inside the
  task. No model is called: the backend's `work.summarize` is a fake.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @moduletag capture_log: true

  alias SwarmCode.Daemon.Service.AgentStatus
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Engine, Projects, Providers, Repo}
  alias SwarmCode.Protocol.{Scope, ServiceRequest}

  @agent %{id: "a", role: "worker", key: 1, stopped?: false}
  @run %{id: "r", status: "running", kind: "swarm"}
  @t0 ~U[2026-09-24 10:00:00.000000Z]

  setup_all do
    path = Path.join(System.tmp_dir!(), "c75-status-#{System.unique_integer([:positive])}")
    root = Path.join(path, "project")
    File.mkdir_p!(root)
    System.cmd("git", ["init", "-q", root])
    prior = Application.get_env(:swarm_code_daemon, :domain_config_dir)
    Application.put_env(:swarm_code_daemon, :domain_config_dir, Path.join(path, "config"))

    on_exit(fn ->
      Cache.clear()

      if prior,
        do: Application.put_env(:swarm_code_daemon, :domain_config_dir, prior),
        else: Application.delete_env(:swarm_code_daemon, :domain_config_dir)

      File.rm_rf!(path)
    end)

    start_supervised!(
      {Repo,
       database: Path.join(path, "fixture.db"),
       domain_fixture: true,
       pool_size: 1,
       journal_mode: :wal,
       log: false}
    )

    Ecto.Migrator.run(
      Repo,
      Application.app_dir(:swarm_code_daemon, "priv/domain_repo/migrations"),
      :up,
      all: true,
      log: false
    )

    {:ok, project} = Projects.create(%{name: "Status", root_path: root})
    %{project: project, root: root}
  end

  # cli.json lives in the test's own directory; the Summarizer is on here.
  setup c do
    prior_dir = Application.get_env(:swarm_code_daemon, :domain_config_dir)
    prior_on = Application.get_env(:swarm_code_daemon, :summarize_agents)
    Application.put_env(:swarm_code_daemon, :domain_config_dir, c.tmp_dir)
    Application.put_env(:swarm_code_daemon, :summarize_agents, true)

    on_exit(fn ->
      if prior_dir,
        do: Application.put_env(:swarm_code_daemon, :domain_config_dir, prior_dir),
        else: Application.delete_env(:swarm_code_daemon, :domain_config_dir)

      if prior_on == nil,
        do: Application.delete_env(:swarm_code_daemon, :summarize_agents),
        else: Application.put_env(:swarm_code_daemon, :summarize_agents, prior_on)
    end)

    :ok
  end

  # ------------------------------------------------------------- decide/4

  describe "decide/4" do
    test "a first call, the same facts, a change inside and after the debounce" do
      assert {:call, s, 1} = AgentStatus.decide(%AgentStatus{}, @agent, @run, 100_000)
      assert {:skip, _} = AgentStatus.decide(s, @agent, @run, 110_000)
      assert {:wait, _, 35_000} = AgentStatus.decide(s, %{@agent | key: 2}, @run, 110_000)
      assert {:call, _, 2} = AgentStatus.decide(s, %{@agent | key: 2}, @run, 145_000)
    end

    test "leads, a plain chat's assistant, ended runs, a spent run and a pending call skip" do
      s = %AgentStatus{}
      assert {:skip, ^s} = AgentStatus.decide(s, %{@agent | role: "lead"}, @run, 0)

      assert {:skip, ^s} =
               AgentStatus.decide(s, %{@agent | role: "assistant"}, %{@run | kind: "chat"}, 0)

      assert {:skip, ^s} = AgentStatus.decide(s, @agent, %{@run | status: "done"}, 0)

      spent = %AgentStatus{calls: %{"r" => 120}}
      assert {:skip, ^spent} = AgentStatus.decide(spent, @agent, @run, 0)

      pending = AgentStatus.started(s, "a", 1, make_ref(), self())
      assert {:skip, ^pending} = AgentStatus.decide(pending, @agent, @run, 0)
    end

    test "a consensus run's assistant is summarised" do
      assert {:call, _, 1} =
               AgentStatus.decide(
                 %AgentStatus{},
                 %{@agent | role: "assistant"},
                 %{@run | kind: "consensus"},
                 0
               )
    end

    test "120 calls of one run stop the next" do
      s =
        Enum.reduce(1..120, %AgentStatus{}, fn i, acc ->
          assert {:call, acc, 1} = AgentStatus.decide(acc, %{@agent | id: "a#{i}"}, @run, 0)
          acc
        end)

      assert s.calls["r"] == 120
      assert {:skip, _} = AgentStatus.decide(s, %{@agent | id: "a121"}, @run, 0)
    end

    test "a stopped agent gets one final call, loses its held line and is frozen" do
      ref = make_ref()
      {:call, s, 1} = AgentStatus.decide(%AgentStatus{}, @agent, @run, 0)
      s = AgentStatus.started(s, "a", 1, ref, self())
      {:changed, s} = AgentStatus.settle(s, ref, "a", 1, {:ok, "reading the repo"})
      assert AgentStatus.summary(s, "a") == {"reading the repo", 1}

      stopped = %{@agent | key: 2, stopped?: true}
      assert {:call, s, 2} = AgentStatus.decide(s, stopped, @run, 50_000)
      assert AgentStatus.summary(s, "a") == {nil, nil}
      assert MapSet.member?(s.frozen, "a")
      assert {:skip, _} = AgentStatus.decide(s, %{stopped | key: 3}, @run, 200_000)
    end

    test "the call counts keep at most 64 runs" do
      s =
        Enum.reduce(1..65, %AgentStatus{}, fn i, acc ->
          {:call, acc, 1} =
            AgentStatus.decide(acc, %{@agent | id: "a#{i}"}, %{@run | id: "r#{i}"}, 0)

          acc
        end)

      assert map_size(s.calls) == 64
      assert length(s.call_runs) == 64
      refute Map.has_key?(s.calls, "r1")
      assert hd(s.call_runs) == "r65"
    end
  end

  # ------------------------------------------------------------ fact_key/3

  describe "fact_key/3" do
    setup do
      node = %{status: "running"}
      op = op("o1", "read_file", "done", @t0, DateTime.add(@t0, 2, :second))
      %{node: node, ops: [op], at: DateTime.to_unix(DateTime.add(@t0, 5, :second), :millisecond)}
    end

    test "the same facts give the same key; a newly finished op changes it", c do
      key = AgentStatus.fact_key(c.node, c.ops, c.at)
      assert AgentStatus.fact_key(c.node, c.ops, c.at) == key

      newer = op("o2", "edit_file", "done", @t0, DateTime.add(@t0, 3, :second))
      refute AgentStatus.fact_key(c.node, [newer | c.ops], c.at) == key
    end

    test "tokens and the turn are not part of it", c do
      key = AgentStatus.fact_key(c.node, c.ops, c.at)
      assert AgentStatus.fact_key(Map.put(c.node, :tokens_in, 999), c.ops, c.at) == key
      assert AgentStatus.fact_key(Map.put(c.node, :turn, 7), c.ops, c.at) == key
    end

    test "crossing into quiet changes it", c do
      assert AgentStatus.fact_key(c.node, c.ops, c.at + 59_000) !=
               AgentStatus.fact_key(c.node, c.ops, c.at + 61_000)
    end
  end

  # -------------------------------------------------------------- accept/2

  test "accept/2 keeps a short honest line and rejects the rest" do
    notes = AgentStatus.notes(%{title: "Build check", name: "b", prompt_head: "check it"}, [])
    assert AgentStatus.accept("Reading the repo.", notes) == {:ok, "reading the repo"}
    assert AgentStatus.accept("checking lib/foo.ex for imports", notes) == :reject
    assert AgentStatus.accept("one two three four five six seven eight", notes) == :reject
    assert AgentStatus.accept("", notes) == :reject
  end

  # ------------------------------------------------------ settle / summary

  describe "settle/5 and summary/2" do
    setup do
      ref = make_ref()
      s = AgentStatus.started(%AgentStatus{}, "a", 1, ref, self())
      %{s: s, ref: ref}
    end

    test "a new line changes the body; an older one does not", c do
      assert {:changed, s} = AgentStatus.settle(c.s, c.ref, "a", 1, {:ok, "reading the repo"})
      assert AgentStatus.summary(s, "a") == {"reading the repo", 1}
      assert s.pending == %{} and s.refs == %{}

      newer = make_ref()
      s = AgentStatus.started(s, "a", 2, newer, self())
      assert {:changed, s} = AgentStatus.settle(s, newer, "a", 2, {:ok, "checking the tests"})

      older = make_ref()
      s = AgentStatus.started(s, "a", 1, older, self())
      assert {:unchanged, s} = AgentStatus.settle(s, older, "a", 1, {:ok, "late line"})
      assert AgentStatus.summary(s, "a") == {"checking the tests", 2}
    end

    test "a rejected or failed call changes nothing", c do
      assert {:unchanged, s} = AgentStatus.settle(c.s, c.ref, "a", 1, :reject)
      assert AgentStatus.summary(s, "a") == {nil, nil}
      assert s.pending == %{}

      s = AgentStatus.started(s, "a", 2, c.ref, self())
      assert {:unchanged, s} = AgentStatus.settle(s, c.ref, "a", 2, {:error, :boom})
      assert MapSet.member?(s.logged, "a")
      assert AgentStatus.summary(s, "a") == {nil, nil}
    end

    test "the held line stays after a newer decision", c do
      {:changed, s} = AgentStatus.settle(c.s, c.ref, "a", 1, {:ok, "reading the repo"})
      {:call, s, _seq} = AgentStatus.decide(s, %{@agent | key: 9}, @run, 0)
      assert AgentStatus.summary(s, "a") == {"reading the repo", 1}
    end

    test "retain/3 drops an unlisted agent's line and keeps the call counts", c do
      {:changed, s} = AgentStatus.settle(c.s, c.ref, "a", 1, {:ok, "reading the repo"})
      {:call, s, _} = AgentStatus.decide(s, %{@agent | id: "b"}, @run, 0)
      s = AgentStatus.retain(s, ["b"], :no_supervisor_needed)
      assert AgentStatus.summary(s, "a") == {nil, nil}
      assert s.calls == %{"r" => 1}
      assert Map.keys(s.keys) == ["b"]
    end

    # cli75 W review (W-6): retain/3 ends the unlisted agent's call only, and a
    # cancelled call's late answer is not a line.
    test "retain/3 ends only an unlisted agent's call in flight" do
      sup = start_supervised!(Task.Supervisor)
      [a, b] = for _ <- 1..2, do: Task.Supervisor.async_nolink(sup, &hold/0)
      ma = Process.monitor(a.pid)
      mb = Process.monitor(b.pid)

      s =
        %AgentStatus{}
        |> AgentStatus.started("a", 1, a.ref, a.pid)
        |> AgentStatus.started("b", 1, b.ref, b.pid)
        |> AgentStatus.retain(["a"], sup)

      assert_receive {:DOWN, ^mb, :process, _, _}
      refute_receive {:DOWN, ^ma, :process, _, _}, 100
      assert s.pending == %{"a" => {1, a.ref, a.pid}}
      assert s.refs == %{a.ref => "a"}
    end

    test "a cancelled call's late answer changes nothing" do
      sup = start_supervised!(Task.Supervisor)
      task = Task.Supervisor.async_nolink(sup, &hold/0)
      s = AgentStatus.started(%AgentStatus{}, "a", 1, task.ref, task.pid)
      s = AgentStatus.cancel(s, ["a"], sup)
      assert s.pending == %{} and s.refs == %{}

      assert {:unchanged, s} = AgentStatus.settle(s, task.ref, "a", 1, {:ok, "late line"})
      assert AgentStatus.summary(s, "a") == {nil, nil}
      assert s.refs == %{}
    end
  end

  # ------------------------------------------------------ notes / request

  test "notes/2 bounds the task, the events and the result" do
    ops =
      for i <- 1..12,
          do:
            op(
              "o#{String.pad_leading("#{i}", 2, "0")}",
              "read_file",
              "done",
              DateTime.add(@t0, i, :second),
              DateTime.add(@t0, i, :second)
            )

    node = %{
      title: "",
      name: "build-verify",
      prompt_head: String.duplicate("t", 500),
      result_head: String.duplicate("r", 900)
    }

    notes = AgentStatus.notes(node, ops)
    assert notes.title == "build-verify"
    assert String.length(notes.task) == 300
    assert length(notes.events) == 9
    assert hd(notes.events) == "read o05"
    assert List.last(notes.events) == "result: " <> String.duplicate("r", 400)
  end

  test "request/2 is small, cold, bounded and low effort on Anthropic only" do
    notes = AgentStatus.notes(%{title: "T", name: "t", prompt_head: "task"}, [])

    for {kind, effort} <- [{"anthropic", "low"}, {"openai", nil}] do
      request = AgentStatus.request(notes, %{provider: %{kind: kind}, model: "m"})
      assert request.max_tokens == 2048
      assert request.temperature == 0.0
      assert request.deadline_ms == 10_000
      assert request.effort == effort
    end
  end

  # ------------------------------------------------------------ the backend

  describe "the backend" do
    setup c do
      Cache.clear()
      {:ok, conv} = Conversations.create(c.project.id)

      {:ok, provider} =
        Providers.create(%{
          name: "c75-summary-#{conv.id}",
          kind: "openai_compatible",
          base_url: "http://127.0.0.1:9/v1",
          models: ["fixture"],
          default_model: "fixture"
        })

      {:ok, _} =
        Conversations.update(conv, %{chat_provider_id: provider.id, chat_model: "fixture"})

      {:ok, run} =
        Conversations.create_run(%{
          conversation_id: conv.id,
          kind: "swarm",
          prompt: "Review the engine",
          status: "running",
          started_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      lead =
        node!(%{
          run_id: run.id,
          kind: "agent",
          role: "lead",
          name: "Lead",
          status: "running",
          started_at: DateTime.add(DateTime.utc_now(), -60, :second)
        })

      {:ok, run} = Conversations.update_run(run, %{root_node_id: lead.id})

      sub =
        node!(%{
          run_id: run.id,
          parent_id: lead.id,
          kind: "agent",
          role: "worker",
          name: "build-verify",
          title: "Build check",
          prompt: "Check that the build passes",
          status: "running",
          depth: 1,
          max_turns: 30,
          turn: 3,
          started_at: DateTime.add(DateTime.utc_now(), -50, :second)
        })

      node!(%{
        run_id: run.id,
        parent_id: sub.id,
        kind: "op",
        op_type: "read_file",
        title: "read the repo",
        status: "done",
        started_at: DateTime.add(DateTime.utc_now(), -12, :second),
        finished_at: DateTime.add(DateTime.utc_now(), -10, :second)
      })

      on_exit(fn -> Engine.stop_all(conv.id) end)

      %{
        conv: conv,
        run: run,
        lead: lead,
        sub: sub,
        scope: %Scope{kind: :conversation, id: conv.id, generation: 1}
      }
    end

    test "a call's line reaches the agent's body once; a token tick starts no call", c do
      backend = backend!(c, {:ok, "reading the repo"})
      full!(backend)
      assert_receive {:notes, %{title: "Build check", events: ["read the repo"]}}, 5_000

      until!(backend, &(AgentStatus.summary(&1.agent_status, c.sub.id) != {nil, nil}))
      state = full!(backend)

      agents = agents(backend, c.scope)
      assert agents[c.sub.id]["summary"] == "reading the repo"
      assert agents[c.sub.id]["summary_rev"] == 1
      assert agents[c.lead.id]["summary"] == nil
      assert Map.has_key?(state.agent_status.timers, c.sub.id)

      Conversations.update_node_fields(c.sub.id, tokens_in: 999)
      full!(backend)
      refute_receive {:notes, _}, 200
    end

    test "a failed call leaves no line and the backend answers", c do
      backend = backend!(c, {:error, :boom})
      full!(backend)
      assert_receive {:notes, _}, 5_000

      until!(backend, &(&1.agent_status.pending == %{}))
      full!(backend)
      assert agents(backend, c.scope)[c.sub.id]["summary"] == nil
      assert %{agent_status: %AgentStatus{}} = :sys.get_state(backend)
    end

    test "cli.json's agent_summaries false keeps the model silent", c do
      File.write!(Path.join(c.tmp_dir, "cli.json"), ~s({"agent_summaries": false}))
      backend = backend!(c, {:ok, "reading the repo"})
      full!(backend)
      until!(backend, &(&1.agent_status.pending == %{}))
      refute_receive {:notes, _}, 200

      full!(backend)
      assert agents(backend, c.scope)[c.sub.id]["summary"] == nil
    end

    # cli75 W review (W-1, W-6): a query's page is not the service's
    # projection, so it ends no call of an agent outside the page.
    test "a page query keeps the call in flight of an agent outside the page", c do
      backend =
        backend_with!(c, fn _notes, _model ->
          receive do
            :go -> {:ok, "reading the repo"}
          end
        end)

      full!(backend)
      state = until!(backend, &Map.has_key?(&1.agent_status.pending, c.sub.id))
      {1, _ref, pid} = state.agent_status.pending[c.sub.id]
      monitor = Process.monitor(pid)

      {:ok, _later} =
        Conversations.create_run(%{
          conversation_id: c.conv.id,
          kind: "chat",
          prompt: "A later turn",
          status: "done",
          started_at: DateTime.utc_now()
        })

      assert {:ok, %{"value" => page}} = query(backend, c.scope, "workspace", 1)
      refute Enum.any?(page["agents"], &(&1["id"] == c.sub.id))

      refute_receive {:DOWN, ^monitor, :process, _, _}, 200
      assert {1, _ref, ^pid} = :sys.get_state(backend).agent_status.pending[c.sub.id]

      send(pid, :go)

      until!(
        backend,
        &(AgentStatus.summary(&1.agent_status, c.sub.id) == {"reading the repo", 1})
      )
    end

    # cli75 W review (W-2): only the agent's current timer runs the decision;
    # a replaced or cancelled one that still delivers is ignored.
    test "a stale status timer leaves the armed one in place", c do
      backend = backend!(c, {:ok, "reading the repo"})
      full!(backend)
      assert_receive {:notes, _}, 5_000

      state =
        until!(backend, fn s ->
          s.agent_status.pending == %{} and Map.has_key?(s.agent_status.timers, c.sub.id)
        end)

      armed = state.agent_status.timers[c.sub.id]
      send(backend, {:timeout, make_ref(), {:agent_status_due, c.sub.id}})
      assert :sys.get_state(backend).agent_status.timers[c.sub.id] == armed
    end

    # cli75 W review (W-3): a lead is never summarised, so it gets no quiet
    # timer however fresh its last operation is.
    test "a lead with a fresh operation gets no quiet timer", c do
      node!(%{
        run_id: c.run.id,
        parent_id: c.lead.id,
        kind: "op",
        op_type: "read_file",
        title: "plan the review",
        status: "done",
        started_at: DateTime.add(DateTime.utc_now(), -6, :second),
        finished_at: DateTime.add(DateTime.utc_now(), -5, :second)
      })

      backend = backend!(c, {:ok, "reading the repo"})
      full!(backend)
      assert_receive {:notes, _}, 5_000
      state = until!(backend, &(&1.agent_status.pending == %{}))
      state = if state.refresh_pending, do: full!(backend), else: state

      assert Map.has_key?(state.agent_status.timers, c.sub.id)
      refute Map.has_key?(state.agent_status.timers, c.lead.id)
    end
  end

  # ---------------------------------------------------------------- helpers

  defp hold do
    receive do
      :never -> :ok
    end
  end

  defp op(id, type, status, started, finished),
    do: %{
      id: id,
      op_type: type,
      status: status,
      title: "read " <> id,
      detail: nil,
      started_at: started,
      finished_at: finished,
      inserted_at: started
    }

  defp node!(attrs) do
    {:ok, node} = Conversations.insert_node(attrs)
    node
  end

  defp backend!(c, answer) do
    test_pid = self()

    backend_with!(c, fn notes, _model ->
      send(test_pid, {:notes, notes})
      answer
    end)
  end

  defp backend_with!(c, summarize) do
    start_supervised!(
      {Backend,
       [
         mode: :persisted,
         repo: Repo,
         project_root: c.root,
         project_id: c.project.id,
         conversation_id: c.conv.id,
         source_epoch: Ecto.UUID.generate(),
         work: %{summarize: summarize}
       ]}
    )
  end

  # The armed refresh ran, then a full reload.
  defp full!(backend) do
    until!(backend, &(not &1.refresh_pending))
    send(backend, :refresh_projection)
    :sys.get_state(backend)
  end

  defp until!(backend, check, tries \\ 400) do
    state = :sys.get_state(backend)

    cond do
      check.(state) ->
        state

      tries > 0 ->
        receive do
        after
          5 -> until!(backend, check, tries - 1)
        end

      true ->
        flunk("the backend never reached the expected state")
    end
  end

  defp agents(backend, scope) do
    assert {:ok, %{"value" => workspace}} = query(backend, scope, "workspace")
    Map.new(workspace["agents"], &{&1["id"], &1})
  end

  defp query(backend, scope, slot, page_size \\ 200),
    do:
      GenServer.call(
        backend,
        {:service_request, "query-#{System.unique_integer([:positive])}", scope,
         %ServiceRequest{
           operation: :query,
           timeout_ms: 5000,
           params: %{
             "slot" => slot,
             "cursor" => nil,
             "direction" => "after",
             "page_size" => page_size,
             "byte_limit" => 1_048_576
           }
         }},
        30000
      )
end
