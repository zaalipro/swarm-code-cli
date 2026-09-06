defmodule SwarmCode.Daemon.ApplicationTest do
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Runtime.{Run, RunSupervisor}
  alias SwarmCode.LLM
  alias SwarmCode.LLM.{Request, Result}
  alias SwarmCode.Providers.Provider
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  test "application startup supports a real default-effort request without test-owned capability state" do
    server =
      HTTP.start(fn socket, request, _turn ->
        assert Jason.decode!(request.body)["reasoning_effort"] == "medium"
        answer(socket, "Ready.")
      end)

    on_exit(fn -> HTTP.stop(server) end)
    provider = provider(server)

    assert {:ok, %Result{text: "Ready."}} =
             LLM.stream(
               %Request{
                 provider: provider,
                 model: "fixture-model",
                 messages: [%{role: "user", content: "hello"}],
                 effort: "medium",
                 deadline_ms: 5_000
               },
               nil
             )
  end

  test "daemon-owned coding run continues after its submitting process detaches" do
    test_owner = self()

    server =
      HTTP.start(fn socket, _, _ ->
        send(test_owner, :provider_waiting)

        receive do
          :finish -> answer(socket, "Survived detach.")
        end
      end)

    on_exit(fn -> HTTP.stop(server) end)
    provider = provider(server)

    {submitter, monitor} =
      spawn_monitor(fn ->
        result =
          RunSupervisor.start_run(
            provider: provider,
            model: "fixture-model",
            project_root: System.tmp_dir!(),
            prompt: "Reply after detach",
            request_timeout_ms: 5_000
          )

        send(test_owner, {:admitted_run, result})
      end)

    assert_receive {:admitted_run, {:ok, run}}, 5_000
    on_exit(fn -> if Process.alive?(run), do: GenServer.stop(run) end)
    assert_receive {:DOWN, ^monitor, :process, ^submitter, :normal}
    assert_receive :provider_waiting, 5_000
    assert Process.alive?(run)
    send(server.pid, :finish)
    assert {:ok, %{status: :completed, text: "Survived detach."}} = Run.await(run)
  end

  defp provider(server) do
    {:ok, provider} =
      Provider.new(name: "application-fixture", base_url: server.url, api_key: "fixture-key")

    provider
  end

  defp answer(socket, text) do
    HTTP.stream(socket, [
      HTTP.sse(%{
        "choices" => [
          %{"index" => 0, "delta" => %{"content" => text}, "finish_reason" => "stop"}
        ]
      })
    ])
  end
end
