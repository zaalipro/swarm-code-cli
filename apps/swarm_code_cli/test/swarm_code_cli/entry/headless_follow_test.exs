defmodule SwarmCodeCLI.Release.HeadlessFollowTest do
  @moduledoc """
  `ncode -p` end to end on a loopback provider: the chat run calls
  `start_swarm` (or `workflow_run`), which returns as soon as the run is
  launched, so the chat run finishes first. The one-shot still waits for the
  launched run, reports it, and exits 1 if it failed. A workflow that parks as
  paused ends the wait with how to continue. A workflow that finishes starts a
  chat turn with its result (the default `continue`); that turn, and what it
  launches in turn, is followed too.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000
  @moduletag :capture_log

  alias SwarmCode.Daemon.Service.RunProcesses
  alias SwarmCode.Domain.{Conversations, Engine, Projects, Workflows}
  alias SwarmCode.Test.C020Backend, as: Fixture
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP
  alias SwarmCodeCLI.Plain.OneShot

  @ask "CHAT-ASK use 4 agents to review the notes"
  @mark "LAUNCHED-TASK-MARK"

  @workflow ~S"""
  meta = %{name: "follow-flow", description: "Fixture"}
  agent("LAUNCHED-TASK-MARK do the work", capability: :read)
  complete("workflow result")
  """

  setup do
    world = Fixture.setup_world("follow")
    {:ok, project} = Projects.trust(world.project)
    world = %{world | project: project}
    {:ok, conversation} = Conversations.create(project.id)
    on_exit(fn -> Engine.stop_all(conversation.id) end)
    %{world: world, conversation: conversation}
  end

  # The chat run calls `tool`, then says it launched; whatever answers the
  # launched run's own requests is `launched`.
  defp provider(c, tool, launched) do
    server =
      HTTP.start(fn socket, request, _turn ->
        last = request.body |> Jason.decode!() |> Map.fetch!("messages") |> List.last()
        text = Jason.encode!(last)

        cond do
          last["role"] == "tool" ->
            sse(socket, %{"content" => "Launched."}, "stop")

          String.contains?(text, "CHAT-ASK") ->
            tool_call(socket, tool)

          is_function(launched, 2) ->
            launched.(socket, text)

          true ->
            launched.(socket)
        end
      end)

    on_exit(fn -> HTTP.stop(server) end)

    {:ok, provider} =
      SwarmCode.Domain.Providers.create(%{
        name: "follow-#{System.unique_integer([:positive])}",
        kind: "openai_compatible",
        base_url: server.url <> "/v1",
        models: ["fixture"],
        default_model: "fixture"
      })

    {:ok, conversation} =
      Conversations.update(c.conversation, %{chat_provider_id: provider.id, chat_model: "fixture"})

    %{c | conversation: conversation}
  end

  defp tool_call(socket, {name, args}) do
    call = %{
      "tool_calls" => [
        %{
          "index" => 0,
          "id" => "call-1",
          "type" => "function",
          "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
        }
      ]
    }

    sse(socket, call, "tool_calls")
  end

  defp sse(socket, delta, finish) do
    HTTP.stream(socket, [
      HTTP.sse(%{"choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish}]})
    ])
  end

  # Slow enough that the chat run is done before the launched run is.
  defp lead_answers(socket) do
    Process.sleep(500)
    sse(socket, %{"content" => "launched report"}, "stop")
  end

  defp lead_fails(socket) do
    Process.sleep(500)

    :gen_tcp.send(
      socket,
      "HTTP/1.1 400 Bad Request\r\ncontent-type: application/json\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}"
    )
  end

  defp hang(_socket), do: receive(do: (:never_sent -> :ok))

  # The stack `with_saved_session` and `Headless` build: backend, service
  # socket, daemon client, then the one-shot on top.
  defp one_shot(c, backend_options \\ [], format \\ :json) do
    c |> start_one_shot(backend_options, format) |> finish_one_shot()
  end

  # The one-shot runs in a task so a test can look at it while a launch is held.
  defp start_one_shot(c, backend_options, format, one_shot_options \\ []) do
    epoch = Ecto.UUID.generate()
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    dir = Path.join("/tmp", "scl-follow-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    socket = Path.join(dir, "s")

    backend =
      Fixture.start_backend(c.world, c.conversation, [source_epoch: epoch] ++ backend_options)

    # A unique id per stack: a test may run two one-shots on one conversation.
    stack = System.unique_integer([:positive])

    start_supervised!(
      Supervisor.child_spec(
        {SwarmCode.Daemon.Service,
         socket_path: socket, nonce: nonce, source_epoch: epoch, backend: backend},
        id: {:service, stack}
      )
    )

    client =
      start_supervised!(
        Supervisor.child_spec(
          {SwarmCodeCLI.UI.DataSource.Daemon,
           socket_path: socket, nonce: nonce, source_epoch: epoch},
          id: {:client, stack}
        )
      )

    {:ok, output} = StringIO.open("")
    {:ok, error} = StringIO.open("")

    task =
      Task.async(fn ->
        OneShot.run(
          Keyword.merge(
            [
              data_source: client,
              source_epoch: epoch,
              conversation_id: c.conversation.id,
              prompt: @ask,
              format: format,
              output: output,
              error: error,
              launch_pending?: &RunProcesses.pending?/1
            ],
            one_shot_options
          )
        )
      end)

    %{task: task, format: format, output: output, error: error}
  end

  defp finish_one_shot(%{task: task, format: format, output: output, error: error}) do
    code = Task.await(task, 60_000)
    {code, summary(format, output), error |> StringIO.contents() |> elem(1)}
  end

  # Whether the one-shot is still running, without waiting for it.
  defp running?(%{task: task}), do: Task.yield(task, 300) == nil

  # `--json` prints one object; stream-json prints records and ends with the
  # summary object; text prints the answer and no object.
  defp summary(:json, output),
    do: output |> StringIO.contents() |> elem(1) |> String.trim() |> Jason.decode!()

  defp summary(:stream_json, output) do
    lines = output |> StringIO.contents() |> elem(1) |> String.split("\n", trim: true)
    summary = lines |> List.last() |> Jason.decode!()
    assert summary["type"] == "summary"
    assert Enum.all?(Enum.drop(lines, -1), &(&1 |> Jason.decode!() |> Map.has_key?("stream")))
    Map.delete(summary, "type")
  end

  defp summary(:text, output), do: output |> StringIO.contents() |> elem(1)

  test "the swarm a chat run launched is waited for, reported, and exits 0", c do
    c = provider(c, {"start_swarm", %{"task" => @mark, "agents" => 4}}, &lead_answers/1)
    {code, json, stderr} = one_shot(c)

    assert code == 0
    assert %{"exit_code" => 0, "state" => "done", "reason" => nil, "runs" => [chat, swarm]} = json
    assert chat["launched"] == false and chat["state"] == "done"
    assert swarm["kind"] == "swarm" and swarm["state"] == "done" and swarm["launched"] == true
    assert swarm["parent_run_id"] == chat["id"]
    assert stderr =~ ~s(ncode: the swarm ")
    assert stderr =~ "finished."

    # Nothing was cut short: every run of the conversation ended done.
    assert Enum.all?(Conversations.list_runs(c.conversation.id), &(&1.status == "done"))
  end

  test "a swarm that fails fails the session", c do
    c = provider(c, {"start_swarm", %{"task" => @mark}}, &lead_fails/1)
    {code, json, stderr} = one_shot(c)

    assert code == 1

    assert %{
             "exit_code" => 1,
             "state" => "failed",
             "reason" => "run_failed",
             "runs" => [chat, swarm]
           } = json

    assert chat["state"] == "done"
    assert swarm["state"] == "failed"
    assert stderr =~ ~s(the swarm ")
    assert stderr =~ "failed"
  end

  # A workflow that finishes with the default `continue` hands its result to
  # the assistant in a fresh chat turn, started by the workflow's own process
  # after its row reads done. What answers that turn is `continuation`.
  #
  # With `compactor:` the conversation asks for an automatic compaction while the
  # workflow runs (what a long original turn does), so the continuation begins
  # with a compaction run, answered by the function.
  defp workflow_provider(c, continuation, options \\ []) do
    compactor = options[:compactor]
    conversation_id = c.conversation.id

    provider(c, {"workflow_run", %{"source" => @workflow, "budget" => 1}}, fn socket, text ->
      cond do
        String.contains?(text, "Compact this conversation") ->
          compactor.(socket)

        String.contains?(text, "finished]") ->
          continuation.(socket)

        String.contains?(text, "SWARM-TASK-MARK") ->
          lead_fails(socket)

        true ->
          if compactor, do: Conversations.mark_compact_due(conversation_id)
          lead_answers(socket)
      end
    end)
  end

  # The compaction run answers once the test sends it `:release`; the test is
  # told when it is held.
  defp held_compactor(test) do
    fn socket ->
      send(test, {:compactor_held, self()})
      receive(do: (:release -> :ok))
      sse(socket, %{"content" => "## Goal\nreview the notes"}, "stop")
    end
  end

  defp compactor_answers(socket), do: sse(socket, %{"content" => "## Goal\nsummary"}, "stop")

  defp runs_of(c, kind),
    do: Enum.filter(Conversations.list_runs(c.conversation.id), &(&1.kind == kind))

  # The registry keeps a run's entry until its process is gone: wait for the
  # process itself, so what is left pending afterwards is not the server.
  defp await_server_gone(run_id) do
    for {pid, _value} <- Registry.lookup(SwarmCode.Domain.Registry, {:run, run_id}) do
      monitor = Process.monitor(pid)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 10_000
    end

    refute RunProcesses.alive?(run_id)
  end

  # What a closed `ncode -p` leaves behind: the run's processes are gone, its row still says
  # paused. The tree (the run's supervisor under `RunSupervisor`) is killed, and a status its
  # shutdown wrote is put back.
  defp leave_paused(run_id) do
    for {pid, _value} <- Registry.lookup(SwarmCode.Domain.Registry, {:run, run_id}) do
      [tree | _] = Process.info(pid, :dictionary) |> elem(1) |> Keyword.fetch!(:"$ancestors")
      monitor = Process.monitor(pid)
      Process.exit(tree, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 10_000
    end

    refute RunProcesses.alive?(run_id)
    {:ok, _} = Conversations.update_run(Conversations.get_run(run_id), %{status: "paused"})
  end

  defp continuation_answers(socket), do: sse(socket, %{"content" => "the report"}, "stop")

  defp run_states(c), do: Enum.map(Conversations.list_runs(c.conversation.id), & &1.status)

  test "a workflow's automatic continuation is followed and reported", c do
    c = workflow_provider(c, &continuation_answers/1)
    {code, json, stderr} = one_shot(c, approval_mode: "full_access")

    assert code == 0
    assert %{"exit_code" => 0, "state" => "done", "reason" => nil, "runs" => runs} = json
    assert [chat, flow, report] = runs
    assert chat["launched"] == false and flow["kind"] == "workflow"
    assert report["kind"] == "chat" and report["state"] == "done" and report["launched"] == true
    assert report["parent_run_id"] == flow["id"]
    assert json["text"] =~ "the report"
    assert stderr =~ ~s(ncode: the workflow ")
    assert stderr =~ ~s(ncode: the chat "[workflow follow-flow finished]" finished.)

    # Nothing was left to the session's close: every run had ended.
    assert run_states(c) == ["done", "done", "done"]
  end

  test "stream-json names the automatic continuation in its summary", c do
    c = workflow_provider(c, &continuation_answers/1)
    {code, json, _stderr} = one_shot(c, [approval_mode: "full_access"], :stream_json)

    assert code == 0
    assert %{"runs" => [_chat, _flow, %{"kind" => "chat", "launched" => true}]} = json
  end

  test "a failing automatic continuation fails the session and is named", c do
    c = workflow_provider(c, &lead_fails/1)
    {code, json, stderr} = one_shot(c, approval_mode: "full_access")

    assert code == 1

    assert %{
             "exit_code" => 1,
             "state" => "failed",
             "reason" => "run_failed",
             "error" => error,
             "runs" => [_chat, flow, report]
           } = json

    assert flow["state"] == "done"
    assert report["kind"] == "chat" and report["state"] == "failed"
    assert error =~ ~s(the chat "[workflow follow-flow finished]" failed)
    assert stderr =~ ~s(ncode: the workflow ")
    assert stderr =~ ~s(the chat "[workflow follow-flow finished]" failed)
    assert Enum.sort(run_states(c)) == ["done", "done", "failed"]
  end

  test "what the automatic continuation launches is followed too", c do
    c =
      workflow_provider(c, fn socket ->
        tool_call(socket, {"start_swarm", %{"task" => "SWARM-TASK-MARK"}})
      end)

    {code, json, _stderr} = one_shot(c, approval_mode: "full_access")

    assert code == 1
    assert %{"state" => "failed", "reason" => "run_failed", "runs" => runs} = json
    assert [_chat, flow, report, swarm] = runs
    assert report["parent_run_id"] == flow["id"]
    assert swarm["kind"] == "swarm" and swarm["parent_run_id"] == report["id"]
    assert swarm["state"] == "failed"
    assert Enum.sort(run_states(c)) == ["done", "done", "done", "failed"]
  end

  test "a workflow that parks as paused ends the wait and says how to continue", c do
    c = provider(c, {"workflow_run", %{"source" => @workflow, "budget" => 1}}, &hang/1)

    # Parked by hand, the way the provider being down would park it.
    pauser =
      Task.async(fn ->
        run =
          Enum.find_value(1..400, fn _ ->
            Process.sleep(25)

            Enum.find(
              Conversations.list_runs(c.conversation.id),
              &(&1.kind == "workflow" and &1.status == "running")
            )
          end)

        Workflows.control(run.id, :pause)
      end)

    {code, json, stderr} = one_shot(c, approval_mode: "full_access")
    assert Task.await(pauser, 30_000) == :ok

    assert code == 1

    assert %{
             "exit_code" => 1,
             "state" => "paused",
             "reason" => "paused_workflow",
             "runs" => [chat, flow]
           } = json

    assert chat["state"] == "done"
    assert flow["kind"] == "workflow" and flow["state"] == "paused"
    assert flow["parent_run_id"] == chat["id"]
    assert stderr =~ ~s(the workflow ")
    assert stderr =~ "Paused by the user"
    assert stderr =~ "paused"
    assert stderr =~ "ncode --resume #{c.conversation.id}"
    assert stderr =~ "/resume-run"
    Engine.stop_all(c.conversation.id)
  end

  # Review 1019 RC-6: `ncode -p "/workflow resume <run>"` launches work, so it waits for it.
  # Before the run is left paused, a request of the workflow's agent (if one is made at all
  # before the pause) is held. After it, the first request, made by the resumed runner, is held
  # until the test releases it; the continuation answers.
  test "a resumed workflow is waited for, not reported as a finished command", c do
    test = self()
    {:ok, phase} = Agent.start_link(fn -> :first end)
    {:ok, requests} = Agent.start_link(fn -> 0 end)

    resumed = fn socket ->
      case Agent.get(phase, & &1) do
        :first ->
          # The fixture serves one request at a time: held until the test has left the
          # run paused.
          send(test, {:first_request, self()})
          receive(do: (:release -> :ok))

        :resumed ->
          case Agent.get_and_update(requests, &{&1, &1 + 1}) do
            0 ->
              send(test, {:resumed_request, self()})
              receive(do: (:release -> :ok))
              sse(socket, %{"content" => "resumed report"}, "stop")

            _continuation ->
              continuation_answers(socket)
          end
      end
    end

    c = provider(c, {"workflow_run", %{"source" => @workflow, "budget" => 1}}, resumed)

    pauser =
      Task.async(fn ->
        run =
          Enum.find_value(1..400, fn _ ->
            Process.sleep(25)

            Enum.find(
              Conversations.list_runs(c.conversation.id),
              &(&1.kind == "workflow" and &1.status == "running")
            )
          end)

        Workflows.control(run.id, :pause)
      end)

    {1, %{"state" => "paused", "runs" => [_chat, %{"id" => flow_id}]}, _stderr} =
      one_shot(c, approval_mode: "full_access")

    assert Task.await(pauser, 30_000) == :ok
    # The paused run's processes belonged to the first session, which a real
    # `ncode -p` left with its VM; a resume starts them anew.
    leave_paused(flow_id)
    Agent.update(phase, fn _ -> :resumed end)

    # The agent's first request is made only if the pause came after it.
    receive do
      {:first_request, first} -> send(first, :release)
    after
      500 -> :ok
    end

    second =
      start_one_shot(c, [approval_mode: "full_access"], :json,
        prompt: "/workflow resume #{flow_id}"
      )

    assert_receive {:resumed_request, handler}, 30_000
    assert running?(second)

    send(handler, :release)
    {code, json, _stderr} = finish_one_shot(second)

    assert code == 0
    assert %{"state" => "done", "runs" => runs} = json
    assert Enum.any?(runs, &(&1["id"] == flow_id and &1["state"] == "done"))
    assert Conversations.get_run(flow_id).status == "done"
    Engine.stop_all(c.conversation.id)
  end

  # The original chat asked for a compaction while the workflow ran, so the
  # workflow's continuation is not a chat turn at once: it is a compaction run
  # (created by the workflow's process, which records the workflow as its
  # launcher) and a chain task that starts the turn when the compaction ends.
  # The workflow's process is gone long before either is done.
  describe "a continuation that begins with an automatic compaction" do
    # Runs `-p` to the point where the compaction is held and checks that the
    # session has not concluded; returns once it has been let go and ended.
    defp through_held_compaction(c, continuation, format) do
      test = self()
      c = workflow_provider(c, continuation, compactor: held_compactor(test))
      running = start_one_shot(c, [approval_mode: "full_access"], format)

      assert_receive {:compactor_held, compactor}, 60_000

      [flow] = runs_of(c, "workflow")
      [compaction] = runs_of(c, "compact")
      assert flow.status == "done"
      assert compaction.status == "running" and compaction.launched_by_run_id == flow.id
      assert Enum.all?(runs_of(c, "chat"), &(&1.launched_by_run_id == nil))

      # The workflow's process is gone; the turn it handed on is in the chain
      # task, and the daemon answers for it in the workflow's name.
      await_server_gone(flow.id)
      assert RunProcesses.chained?(flow.id) and RunProcesses.pending?(flow.id)
      assert running?(running)

      # Let the compaction end but keep the chain task from starting its turn:
      # every row the session can read says done, no server of the workflow or
      # the compaction lives, and the turn exists nowhere but in that task.
      chain = chain_task(flow.id)
      :erlang.suspend_process(chain)

      try do
        send(compactor, :release)
        await_server_gone(compaction.id)
        assert Conversations.get_run(compaction.id).status == "done"
        assert length(runs_of(c, "chat")) == 1
        assert RunProcesses.pending?(flow.id)
        assert running?(running)
      after
        :erlang.resume_process(chain)
      end

      {c, flow, finish_one_shot(running)}
    end

    defp chain_task(owner_id) do
      [pid] =
        Registry.select(SwarmCode.Domain.Registry, [
          {{{:chain, :_, :_}, :"$1", owner_id}, [], [:"$1"]}
        ])

      pid
    end

    defp launched_by(runs, flow) do
      runs |> Enum.filter(&(&1["parent_run_id"] == flow.id)) |> Enum.sort_by(& &1["title"])
    end

    test "is waited for while the compaction is held, then followed to its end", c do
      {c, flow, {code, json, stderr}} =
        through_held_compaction(c, &continuation_answers/1, :json)

      assert code == 0
      assert %{"exit_code" => 0, "state" => "done", "reason" => nil, "runs" => runs} = json
      assert [compaction, report] = launched_by(runs, flow)
      assert compaction["title"] == "/compact" and compaction["state"] == "done"
      assert report["title"] == "[workflow follow-flow finished]" and report["state"] == "done"
      assert Enum.all?([compaction, report], &(&1["launched"] and &1["kind"] == "chat"))
      assert length(runs) == 4
      assert json["text"] =~ "the report"
      assert stderr =~ ~s(ncode: the chat "/compact" finished.)
      assert stderr =~ ~s(ncode: the chat "[workflow follow-flow finished]" finished.)

      # Nothing was left to the session's close.
      assert run_states(c) |> Enum.sort() == ["done", "done", "done", "done"]
    end

    # The window this closes is the few milliseconds between the compaction's
    # end and the chained turn's row: the workflow's process is long gone and
    # every row the session has read says done.
    test "a compaction that ends at once leaves no gap before the turn", c do
      c = workflow_provider(c, &continuation_answers/1, compactor: &compactor_answers/1)
      {code, json, _stderr} = one_shot(c, approval_mode: "full_access")

      assert code == 0
      assert %{"exit_code" => 0, "reason" => nil, "runs" => runs} = json

      assert [%{"title" => "/compact"}, %{"title" => "[workflow follow-flow finished]"}] =
               runs |> Enum.drop(2) |> Enum.sort_by(& &1["title"])

      assert json["text"] =~ "the report"
      assert run_states(c) == ["done", "done", "done", "done"]
    end

    test "a failing continuation fails the session, in the human summary too", c do
      {c, _flow, {code, text, stderr}} = through_held_compaction(c, &lead_fails/1, :text)

      assert code == 1
      refute text =~ "the report"
      assert stderr =~ ~s(ncode: the chat "/compact" finished.)
      assert stderr =~ ~s(ncode: the chat "[workflow follow-flow finished]" failed)
      assert run_states(c) |> Enum.sort() == ["done", "done", "done", "failed"]
    end

    test "what the continuation launches is followed too, in stream-json", c do
      swarm = fn socket -> tool_call(socket, {"start_swarm", %{"task" => "SWARM-TASK-MARK"}}) end
      {c, flow, {code, json, _stderr}} = through_held_compaction(c, swarm, :stream_json)

      assert code == 1
      assert %{"state" => "failed", "reason" => "run_failed", "runs" => runs} = json
      assert [_compaction, report] = launched_by(runs, flow)
      assert [%{"kind" => "swarm", "state" => "failed"}] = launched_by(runs, %{id: report["id"]})
      assert run_states(c) |> Enum.sort() == ["done", "done", "done", "done", "failed"]
    end
  end

  # A trusted `user_prompt_submit` hook runs before the continuation's row
  # exists, in the workflow's own process, and may take as long as its timeout
  # (up to 30 s). The row of the workflow is done all that time.
  describe "a continuation held in a hook before its turn exists" do
    # The hook blocks on two FIFOs: it tells the test it is in (a write nobody
    # reads until the test does) and waits to be let go (a read nobody writes
    # until the test does). No clock decides when either happens.
    defp hold_continuation_hook(c) do
      entered = Path.join(c.world.path, "hook-entered")
      release = Path.join(c.world.path, "hook-release")
      for fifo <- [entered, release], do: {_, 0} = System.cmd("mkfifo", [fifo])

      command =
        "case \"$NCODE_PROMPT\" in *\"finished]\"*) echo in > '#{entered}'; " <>
          "cat '#{release}' > /dev/null;; esac"

      config = %{
        "hooks" => %{"user_prompt_submit" => [%{"command" => command, "timeout_ms" => 30_000}]}
      }

      dir = Path.join(c.world.root, ".swarm_code")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "config.json"), Jason.encode!(config))
      %{entered: entered, release: release}
    end

    defp await_hook_entered(barrier) do
      task = Task.async(fn -> System.cmd("cat", [barrier.entered]) end)
      assert {"in\n", 0} = Task.await(task, 30_000)
    end

    defp release_hook(barrier) do
      task = Task.async(fn -> System.cmd("sh", ["-c", "echo go > '#{barrier.release}'"]) end)
      assert {"", 0} = Task.await(task, 30_000)
    end

    # Holds the hook while the one-shot asks about the launch far more often
    # than any wait budget of a few rechecks could have allowed, then lets it go.
    defp through_held_hook(c, continuation) do
      test = self()
      barrier = hold_continuation_hook(c)
      c = workflow_provider(c, continuation)

      asking = fn id ->
        send(test, {:asked, id})
        RunProcesses.pending?(id)
      end

      running =
        start_one_shot(c, [approval_mode: "full_access"], :json,
          launch_pending?: asking,
          recheck_ms: 1
        )

      await_hook_entered(barrier)

      [flow] = runs_of(c, "workflow")
      assert flow.status == "done"
      assert RunProcesses.alive?(flow.id)
      assert length(runs_of(c, "chat")) == 1

      for _ <- 1..60, do: assert_receive({:asked, _}, 10_000)
      assert running?(running)

      release_hook(barrier)
      {c, finish_one_shot(running)}
    end

    test "is waited for past any wait budget, then followed to its end", c do
      {c, {code, json, stderr}} = through_held_hook(c, &continuation_answers/1)

      assert code == 0
      assert %{"exit_code" => 0, "reason" => nil, "runs" => [_chat, flow, report]} = json
      assert report["kind"] == "chat" and report["state"] == "done" and report["launched"]
      assert report["parent_run_id"] == flow["id"]
      assert json["text"] =~ "the report"
      assert stderr =~ ~s(ncode: the chat "[workflow follow-flow finished]" finished.)
      assert run_states(c) == ["done", "done", "done"]
    end

    test "a continuation that fails after the hold is not reported as success", c do
      {c, {code, json, stderr}} = through_held_hook(c, &lead_fails/1)

      assert code == 1
      assert %{"state" => "failed", "reason" => "run_failed", "runs" => [_, _, report]} = json
      assert report["state"] == "failed"
      assert stderr =~ ~s(the chat "[workflow follow-flow finished]" failed)
      assert Enum.sort(run_states(c)) == ["done", "done", "failed"]
    end
  end
end
