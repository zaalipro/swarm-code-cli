defmodule SwarmCode.Daemon.Service.Pass73SessionFlowTest do
  @moduledoc """
  pass73 T11 end to end: the terminal's own transport (`DataSource.Daemon`)
  over the real service socket to the persisted backend. The owner's scenario:
  several live runs stream, the terminal is slow (its delivery queue is full),
  the workspace watch overflows on the backend, and the terminal then
  consumes the deltas it already had. Their acks name a watch the daemon had
  dropped; the daemon closed the connection without a word and the session
  died with "the daemon connection closed". It must resync instead.
  """
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Projects, Repo}
  alias SwarmCode.Domain.Engine.Events
  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.UI.DataSource
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Request, Watch}

  setup_all do
    path = Path.join(System.tmp_dir!(), "p73f-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
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

    %{path: path}
  end

  setup c do
    Cache.clear()
    root = Path.join(c.path, "project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create(%{name: "Flow", root_path: root})
    {:ok, conv} = Conversations.create(project.id)
    epoch = Ecto.UUID.generate()

    backend =
      start_supervised!(
        {Backend,
         mode: :persisted,
         repo: Repo,
         project_root: root,
         project_id: project.id,
         conversation_id: conv.id,
         source_epoch: epoch}
      )

    socket_path = Path.join(c.path, "f#{System.unique_integer([:positive])}.sock")
    nonce = String.duplicate("F", 43)

    start_supervised!(
      {SwarmCode.Daemon.Service,
       socket_path: socket_path, nonce: nonce, source_epoch: epoch, backend: backend}
    )

    {:ok, client} =
      DataSource.Daemon.start_link(socket_path: socket_path, nonce: nonce, source_epoch: epoch)

    assert {:ok, "flow"} = DataSource.bind_owner(client, self(), "flow")
    %{client: client, conv: conv, epoch: epoch, backend: backend}
  end

  test "a watch that overflows while the terminal is behind resyncs instead of closing", c do
    scope = %Scope{kind: :conversation, id: c.conv.id, generation: 0}

    assert :ok =
             DataSource.watch(c.client, %Watch{
               watch_ref: "workspace",
               slot: :workspace,
               scope: scope,
               generation: 0,
               page_size: 20,
               byte_limit: 262_144
             })

    assert_receive {:swarm_code_ui_data, _, ready, %Delivery{kind: :watch_ready}}, 5_000
    assert :ok = DataSource.consume(c.client, ready, :applied)

    # A few deltas reach the terminal and wait there, unconsumed.
    runs(c.conv.id, 1..3)
    held = [next_delivery(:delta) | quiet_deltas([])]

    # The terminal falls behind: its queue fills with answers it has not read.
    for n <- 1..(32 - length(held)),
        do: assert(:ok = DataSource.query(c.client, query(scope, "held-#{n}")))

    assert eventually(fn -> :sys.get_state(c.client).delivery_count >= 32 end)

    # The live runs keep going: the workspace watch overflows on the backend
    # (it drops the watch once 128 deltas wait for credit).
    runs(c.conv.id, 4..260)
    assert eventually(fn -> map_size(:sys.get_state(c.backend).watches) == 0 end, 800)

    # The terminal catches up: first the deltas it already had (their acks
    # name the watch the daemon has just dropped), then everything else.
    Enum.each(held, fn {receipt, _} ->
      assert :ok = DataSource.consume(c.client, receipt, :applied)
    end)

    kinds = drain(c.client, [])
    assert :resyncing in kinds
    assert List.last(Enum.filter(kinds, &(&1 in [:watch_ready, :resyncing]))) == :watch_ready
    refute_received {:swarm_code_ui_closed, _, _}

    # The session is still there.
    assert :ok = DataSource.query(c.client, query(scope, "after"))
    assert {receipt, %Delivery{request_id: "after"}} = next_delivery(:response)
    assert :ok = DataSource.consume(c.client, receipt, :applied)
    assert :sys.get_state(c.client).phase == :bound
  end

  defp runs(conversation_id, range) do
    for i <- range do
      {:ok, run} =
        Conversations.create_run(%{
          conversation_id: conversation_id,
          kind: "chat",
          prompt: "Live run #{i}",
          status: "running",
          started_at: DateTime.utc_now()
        })

      Events.broadcast(conversation_id, {:run_updated, run})
    end
  end

  defp quiet_deltas(acc) do
    receive do
      {:swarm_code_ui_data, _, receipt, %Delivery{kind: :delta} = delivery} ->
        quiet_deltas([{receipt, delivery} | acc])
    after
      300 -> Enum.reverse(acc)
    end
  end

  defp next_delivery(kind) do
    assert_receive {:swarm_code_ui_data, _, receipt, %Delivery{kind: ^kind} = delivery}, 5_000
    {receipt, delivery}
  end

  # Consume every delivery until the source is quiet for a while.
  defp drain(client, kinds) do
    receive do
      {:swarm_code_ui_data, _, receipt, %Delivery{kind: kind}} ->
        assert :ok = DataSource.consume(client, receipt, :applied)
        drain(client, [kind | kinds])

      {:swarm_code_ui_closed, _, _} ->
        flunk("the data source closed; kinds so far: #{inspect(Enum.reverse(kinds))}")
    after
      1_500 -> Enum.reverse(kinds)
    end
  end

  defp query(scope, id),
    do: %Request{
      request_id: id,
      kind: {:query, :transcript, nil, :after, 20, 65_536},
      scope: scope,
      generation: 0,
      origin: {:query, :transcript},
      deadline: System.system_time(:millisecond) + 20_000,
      expected_response: :transcript_window
    }

  defp eventually(fun, tries \\ 200) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        receive do
        after
          25 -> eventually(fun, tries - 1)
        end
    end
  end
end
