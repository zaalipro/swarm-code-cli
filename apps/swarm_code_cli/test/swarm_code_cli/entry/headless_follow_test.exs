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
    epoch = Ecto.UUID.generate()
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    dir = Path.join("/tmp", "scl-follow-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    socket = Path.join(dir, "s")

    backend =
      Fixture.start_backend(c.world, c.conversation, [source_epoch: epoch] ++ backend_options)

    start_supervised!(
      {SwarmCode.Daemon.Service,
       socket_path: socket, nonce: nonce, source_epoch: epoch, backend: backend}
    )

    client =
      start_supervised!(
        {SwarmCodeCLI.UI.DataSource.Daemon,
         socket_path: socket, nonce: nonce, source_epoch: epoch}
      )

    {:ok, output} = StringIO.open("")
    {:ok, error} = StringIO.open("")

    code =
      OneShot.run(
        data_source: client,
        source_epoch: epoch,
        conversation_id: c.conversation.id,
        prompt: @ask,
        format: format,
        output: output,
        error: error,
        server_alive?: &SwarmCode.Daemon.Service.RunProcesses.alive?/1
      )

    {code, summary(format, output), error |> StringIO.contents() |> elem(1)}
  end

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
  defp workflow_provider(c, continuation) do
    provider(c, {"workflow_run", %{"source" => @workflow, "budget" => 1}}, fn socket, text ->
      cond do
        String.contains?(text, "finished]") -> continuation.(socket)
        String.contains?(text, "SWARM-TASK-MARK") -> lead_fails(socket)
        true -> lead_answers(socket)
      end
    end)
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
end
