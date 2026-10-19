defmodule SwarmCodeCLI.Release.SignalsCloseTest do
  @moduledoc """
  pass76 cli-signals-ledger: a signal that reaches `ncode -p` while a run is
  live ends the one-shot with the signal's code, and the owned shutdown the
  session's close runs next leaves that run `stopped` in the database, with
  nothing still registered as running.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 120_000
  @moduletag :capture_log

  alias SwarmCode.Daemon.Shutdown
  alias SwarmCode.Domain.{Conversations, Engine}
  alias SwarmCode.Test.C020Backend, as: Fixture
  alias SwarmCodeCLI.Plain.OneShot
  alias SwarmCodeCLI.Release.Signals

  setup do
    world = Fixture.setup_world("signals-close")
    {:ok, conversation} = Conversations.create(world.project.id)
    on_exit(fn -> Engine.stop_all(conversation.id) end)
    {conversation, _provider, _server} = Fixture.provider!(world, conversation, fn _ -> :hang end)
    %{world: world, conversation: conversation}
  end

  # The stack `with_saved_session` and `Headless` build: backend, service
  # socket, daemon client, then the one-shot on top, owned by a task so a
  # signal can be sent to the process running it.
  defp start_one_shot(c) do
    epoch = Ecto.UUID.generate()
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    dir = Path.join("/tmp", "scl-signals-#{System.unique_integer([:positive])}")
    File.mkdir!(dir)
    File.chmod!(dir, 0o700)
    on_exit(fn -> File.rm_rf!(dir) end)
    socket = Path.join(dir, "s")

    backend = Fixture.start_backend(c.world, c.conversation, source_epoch: epoch)

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

    Task.async(fn ->
      OneShot.run(
        data_source: client,
        source_epoch: epoch,
        conversation_id: c.conversation.id,
        prompt: "Hello there",
        format: :json,
        output: output,
        error: error
      )
    end)
  end

  defp running?(c),
    do: Enum.any?(Conversations.list_runs(c.conversation.id), &(&1.status == "running"))

  for {signal, code} <- [sigterm: 143, sighup: 129] do
    test "#{signal} ends the one-shot with #{code} and the shutdown leaves the run stopped", c do
      one_shot = start_one_shot(c)
      assert Fixture.eventually(fn -> running?(c) and Engine.running_run_ids() != [] end)

      Signals.notify(one_shot.pid, unquote(signal))
      assert Task.await(one_shot, 30_000) == unquote(code)

      # What the session's close does next, with the shutdown's own deadlines.
      assert %{stopped: _} = Shutdown.run(teardown: false)

      assert Engine.running_run_ids() == []
      runs = Conversations.list_runs(c.conversation.id)
      assert runs != []
      assert Enum.all?(runs, &(&1.status == "stopped"))
    end
  end
end
