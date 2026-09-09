defmodule SwarmCodeCLI.Plain.LiveSessionTest do
  use ExUnit.Case, async: false
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP
  alias SwarmCodeCLI.Plain.{Options, Session}

  test "piped EOF waits for a real provider and prints the final answer before closing" do
    parent = self()

    server =
      HTTP.start(fn socket, _, _ ->
        send(parent, {:provider_waiting, self()})

        receive do
          :finish ->
            HTTP.stream(socket, [
              HTTP.sse(%{
                "choices" => [
                  %{"delta" => %{"content" => "Finished from pipe."}, "finish_reason" => "stop"}
                ]
              })
            ])
        end
      end)

    on_exit(fn -> HTTP.stop(server) end)
    root = Path.join("/tmp", "scl-plain-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, provider} =
      SwarmCode.Providers.Provider.new(name: "fixture", base_url: server.url <> "/v1")

    epoch = Ecto.UUID.generate()
    conversation = Ecto.UUID.generate()
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    backend =
      start_supervised!(
        {SwarmCode.Daemon.Service.LiveBackend,
         mode: :transient,
         provider: provider,
         model: "fixture",
         project_root: root,
         project_id: Ecto.UUID.generate(),
         conversation_id: conversation,
         source_epoch: epoch}
      )

    socket = Path.join(root, "s")

    start_supervised!(
      {SwarmCode.Daemon.Service,
       socket_path: socket, nonce: nonce, source_epoch: epoch, backend: backend}
    )

    client =
      start_supervised!(
        {SwarmCodeCLI.UI.DataSource.Daemon,
         socket_path: socket, nonce: nonce, source_epoch: epoch}
      )

    {:ok, input} = StringIO.open("send -- Finish this task\n")
    {:ok, output} = StringIO.open("")

    session =
      start_supervised!(
        {Session,
         data_source: client,
         source_epoch: epoch,
         conversation_id: conversation,
         now: System.system_time(:millisecond),
         input: input,
         output: output,
         error: output,
         options: %Options{banner: :plain, detached_runs?: false},
         eof: :wait,
         observer: self()}
      )

    assert_receive {:provider_waiting, provider_pid}, 5_000
    refute_receive {:plain_session, ^session, {:closed, _}}, 200
    send(provider_pid, :finish)
    assert_receive {:plain_session, ^session, {:closed, :eof}}, 5_000
    assert elem(StringIO.contents(output), 1) =~ "Finished from pipe."
    refute elem(StringIO.contents(output), 1) =~ "FAKE DEMO"
  end
end
