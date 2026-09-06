defmodule SwarmCodeCLI.UI.DataSource.FakeTest do
  use ExUnit.Case, async: false
  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Delivery, Fake, Request, Watch}
  alias Fake.{Script, Source}

  defp setup_client do
    {:ok, script} =
      Script.decode(
        File.read!(Path.expand("../../../fixtures/fake/three_run_script.json", __DIR__))
      )

    source = start_supervised!({Source, script: script, source_epoch: "epoch"})
    client = start_supervised!({Fake, source: source, source_epoch: "epoch", client_id: "client"})
    {source, client}
  end

  defp watch(scope \\ %Scope{kind: :global, id: nil, generation: 0}) do
    %Watch{
      watch_ref: "watch",
      slot: :workspace,
      scope: scope,
      generation: scope.generation,
      page_size: 200,
      byte_limit: 1_048_576
    }
  end

  defp resync(watch) do
    %Request{
      request_id: "resync",
      kind: {:resync_watch, watch.watch_ref},
      origin: {:watch, watch.watch_ref},
      scope: watch.scope,
      generation: watch.generation,
      deadline: Script.clock_ms() + 10_000,
      expected_response: :watch_snapshot
    }
  end

  test "one-shot binding gates admission and close preserves canonical source" do
    {source, client} = setup_client()
    assert {:error, %AdmissionError{code: :not_bound}} = Fake.watch(client, watch())
    assert {:ok, "binding"} = Fake.bind_owner(client, self(), "binding")
    assert {:error, :already_bound} = Fake.bind_owner(client, self(), "binding")
    assert :ok = Fake.watch(client, watch())
    assert_receive {:swarm_code_ui_data, "epoch", %Delivery{kind: :watch_ready, body: body}}
    assert body.through_sequence == 0
    assert :ok = Fake.close(client)
    assert :ok = Fake.close(client)
    assert_receive {:swarm_code_ui_data, "epoch", %Delivery{kind: :closed}}
    assert {:error, %AdmissionError{code: :closed}} = Fake.watch(client, watch())
    assert :ok = Source.advance(source, "a1-a2-b1-step-1")
    assert map_size(Source.snapshot(source).runs) == 3
  end

  test "scoped watch projects contiguous sequences across unrelated canonical events" do
    {source, client} = setup_client()
    Fake.bind_owner(client, self(), "binding")
    w = watch(%Scope{kind: :run, id: Script.id(:a1), generation: 0})
    assert :ok = Fake.watch(client, w)
    assert_receive {:swarm_code_ui_data, "epoch", %Delivery{kind: :watch_ready}}
    Source.advance(source, "a1-a2-b1-step-1")
    Source.advance(source, "a1-b1-step-2")
    :sys.get_state(client)
    deltas = drain_deltas([])
    assert length(deltas) > 3
    assert Enum.map(deltas, & &1.sequence) == Enum.to_list(1..length(deltas))
    assert Enum.all?(deltas, &(&1.sequence == &1.body.sequence))
    refute_receive {:swarm_code_ui_data, _, %Delivery{kind: :resyncing}}, 0
  end

  test "gap waits for exact typed resync and resets snapshot watermark" do
    {source, client} = setup_client()
    Fake.bind_owner(client, self(), "binding")
    w = watch()
    Fake.watch(client, w)
    assert_receive {:swarm_code_ui_data, "epoch", %Delivery{kind: :watch_ready}}
    Source.advance(source, "sequence-gap")
    assert_receive {:swarm_code_ui_data, "epoch", %Delivery{kind: :resyncing}}
    refute_receive {:swarm_code_ui_data, _, %Delivery{kind: :watch_ready}}, 0
    req = resync(w)
    assert {:ok, ^req} = Request.validate(req)
    assert :ok = Fake.query(client, req)
    assert_receive {:swarm_code_ui_data, "epoch", %Delivery{kind: :watch_ready, body: body}}
    assert body.through_sequence == Source.snapshot(source).sequence
    assert {:error, %AdmissionError{code: :request_conflict}} = Fake.query(client, req)
  end

  defmodule HeldSource do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, %{source: opts[:source], test: opts[:test], client: nil, held: []}}

    def handle_call({:attach, id, pid}, _, s) do
      result = Source.attach(s.source, id, self())
      {:reply, result, %{s | client: pid}}
    end

    def handle_call(:release, _, s) do
      Enum.each(Enum.reverse(s.held), &send(s.client, &1))
      {:reply, :ok, %{s | held: []}}
    end

    def handle_call(message, _, s), do: {:reply, GenServer.call(s.source, message), s}

    def handle_cast({:detach, id, pid}, %{client: pid} = s) do
      GenServer.cast(s.source, {:detach, id, self()})
      {:noreply, s}
    end

    def handle_cast({:unwatch, id, ref, pid}, %{client: pid} = s) do
      GenServer.cast(s.source, {:unwatch, id, ref, self()})
      {:noreply, s}
    end

    def handle_cast(message, s) do
      GenServer.cast(s.source, message)
      {:noreply, s}
    end

    def handle_info({:fake_source, _, %Delivery{}} = msg, s) do
      send(s.test, {:held, msg})
      {:noreply, %{s | held: [msg | s.held]}}
    end

    def handle_info(msg, s) do
      send(s.client, msg)
      {:noreply, s}
    end
  end

  test "delayed ready buffers deltas then cancellation rejects held response" do
    {source, original} = setup_client()
    Fake.close(original)
    proxy = start_supervised!({HeldSource, source: source, test: self()})

    client =
      start_supervised!(
        Supervisor.child_spec(
          {Fake, source: proxy, source_epoch: "epoch", client_id: "held-client"},
          id: :held_client
        )
      )

    Fake.bind_owner(client, self(), "binding")
    Fake.watch(client, watch())
    assert_receive {:held, {:fake_source, _, %Delivery{kind: :watch_ready}}}
    Source.advance(source, "a1-a2-b1-step-1")
    :sys.get_state(proxy)
    :sys.get_state(client)
    refute_receive {:swarm_code_ui_data, _, _}, 0
    GenServer.call(proxy, :release)

    assert_receive {:swarm_code_ui_data, _,
                    %Delivery{kind: :watch_ready, body: %{through_sequence: 0}}}

    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :delta, sequence: 1}}
    drain_deltas([])

    req = %{
      resync(watch())
      | request_id: "query",
        kind: {:query, :transcript, nil, :after, 200, 1_048_576},
        origin: {:query, :transcript},
        expected_response: :transcript_window
    }

    assert :ok = Fake.query(client, req)
    assert_receive {:held, {:fake_source, _, %Delivery{kind: :response}}}
    assert :ok = Fake.cancel(client, req.request_id)
    GenServer.call(proxy, :release)
    :sys.get_state(client)
    refute_receive {:swarm_code_ui_data, _, %Delivery{kind: :response}}, 0
  end

  test "admitted response retains a deadline until delivery" do
    {source, original} = setup_client()
    Fake.close(original)
    proxy = start_supervised!({HeldSource, source: source, test: self()})

    client =
      start_supervised!(
        Supervisor.child_spec(
          {Fake, source: proxy, source_epoch: "epoch", client_id: "held-client"},
          id: :held_client
        )
      )

    Fake.bind_owner(client, self(), "binding")

    req = %{
      resync(watch())
      | request_id: "query",
        kind: {:query, :transcript, nil, :after, 200, 1_048_576},
        origin: {:query, :transcript},
        expected_response: :transcript_window
    }

    assert :ok = Fake.query(client, req)
    assert_receive {:held, {:fake_source, _, %Delivery{kind: :response}}}
    state = :sys.get_state(client)
    assert map_size(state.workers) == 1
    [token] = Map.keys(state.workers)
    send(client, {:expired, token})
    :sys.get_state(client)
    GenServer.call(proxy, :release)
    :sys.get_state(client)

    assert_receive {:swarm_code_ui_data, _,
                    %Delivery{
                      kind: :response,
                      request_id: "query",
                      body: %{state: :error, error: %AdmissionError{code: :deadline_expired}}
                    } = failure}

    assert {:ok, ^failure} = Delivery.validate(failure)
    refute_receive {:swarm_code_ui_data, _, %Delivery{kind: :response}}, 0
    assert :sys.get_state(client).requests == %{}
  end

  test "owner death detaches the client and a fresh client sees continuing canonical facts" do
    {source, client} = setup_client()

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, "binding"} = Fake.bind_owner(client, owner, "binding")
    Fake.watch(client, watch())
    ref = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}
    state = :sys.get_state(client)
    assert state.phase == :closed
    assert state.workers == %{}
    assert state.watches == %{}
    assert :ok = Source.advance(source, "a1-a2-b1-step-1")

    next =
      start_supervised!(
        Supervisor.child_spec({Fake, source: source, source_epoch: "epoch", client_id: "fresh"},
          id: :fresh
        )
      )

    Fake.bind_owner(next, self(), "fresh-binding")
    Fake.watch(next, watch())
    assert_receive {:swarm_code_ui_data, "epoch", %Delivery{kind: :watch_ready, body: body}}
    assert body.through_sequence == Source.snapshot(source).sequence
  end

  test "unwatch retires its reference and drops delayed readiness" do
    {source, original} = setup_client()
    Fake.close(original)
    proxy = start_supervised!({HeldSource, source: source, test: self()})

    client =
      start_supervised!(
        Supervisor.child_spec(
          {Fake, source: proxy, source_epoch: "epoch", client_id: "held-client"},
          id: :held_client
        )
      )

    Fake.bind_owner(client, self(), "binding")
    assert :ok = Fake.watch(client, watch())
    assert_receive {:held, _}
    assert :ok = Fake.unwatch(client, "watch")
    GenServer.call(proxy, :release)
    :sys.get_state(client)
    refute_receive {:swarm_code_ui_data, _, _}, 0
    assert :sys.get_state(client).workers == %{}
    assert {:error, %AdmissionError{code: :duplicate_watch}} = Fake.watch(client, watch())
  end

  test "wrong epoch fails the single binding closed" do
    {source, original} = setup_client()
    Fake.close(original)

    client =
      start_supervised!(
        Supervisor.child_spec({Fake, source: source, source_epoch: "other", client_id: "other"},
          id: :other
        )
      )

    assert {:error, :binding_failed} = Fake.bind_owner(client, self(), "binding")
    assert {:error, :closed} = Fake.bind_owner(client, self(), "again")
    refute_receive {:swarm_code_ui_data, _, _}, 0
  end

  test "query detail variant validates exact origin, range, and response" do
    req = %{
      resync(watch())
      | kind: {:query_detail, "detail", 0, 4096},
        origin: {:query, :detail},
        expected_response: :detail_window
    }

    assert {:ok, ^req} = Request.validate(req)

    assert {:error, :invalid_request} =
             Request.validate(%{req | kind: {:query_detail, "detail", -1, 4096}})

    assert {:error, :invalid_request} =
             Request.validate(%{req | kind: {:query_detail, "detail", 0, 65_537}})

    assert {:error, :invalid_request} = Request.validate(%{req | origin: {:query, :transcript}})

    assert {:error, :invalid_request} =
             Request.validate(%{req | expected_response: :transcript_window})
  end

  test "pre-ready count overflow requests an internal snapshot and rejects the old page" do
    {source, original} = setup_client()
    Fake.close(original)
    proxy = start_supervised!({HeldSource, source: source, test: self()})

    client =
      start_supervised!(
        Supervisor.child_spec(
          {Fake, source: proxy, source_epoch: "epoch", client_id: "held-client"},
          id: :held_client
        )
      )

    Fake.bind_owner(client, self(), "binding")
    Fake.watch(client, watch())

    assert_receive {:held,
                    {:fake_source, _, %Delivery{kind: :watch_ready, body: %{through_sequence: 0}}}}

    Enum.each(1..43, fn n ->
      operation = if rem(n, 2) == 1, do: :pause, else: :continue

      req = %{
        resync(watch())
        | request_id: "command-#{n}",
          kind: {:run_control, operation, Script.id(:a1)},
          origin: {:run, Script.id(:a1)},
          expected_response: :outcome
      }

      assert :ok = Source.request(source, "held-client", req)
    end)

    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :resyncing}}

    assert_receive {:held, {:fake_source, _, %Delivery{kind: :watch_ready, body: replacement}}},
                   1000

    assert replacement.through_sequence >= 129
    state = :sys.get_state(client)
    assert state.watches["watch"].buffer == []
    assert state.watches["watch"].bytes == 0
    GenServer.call(proxy, :release)
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :watch_ready, body: installed}}
    assert installed.through_sequence == replacement.through_sequence
    refute_receive {:swarm_code_ui_data, _, %Delivery{kind: :watch_ready}}, 0
  end

  test "stale correlation fields and duplicate canonical deltas cannot enter the owner stream" do
    {source, client} = setup_client()
    Fake.bind_owner(client, self(), "binding")
    Fake.watch(client, watch())
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :watch_ready} = ready}
    send(client, {:fake_source, "other-client", ready})
    send(client, {:fake_source, "client", %{ready | generation: 1}})
    send(client, {:fake_source, "client", %{ready | watch_ref: "unknown"}})
    send(client, {:fake_source, "client", ready})
    Source.advance(source, "a1-a2-b1-step-1")
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :delta} = first}
    :sys.get_state(client)
    drain_deltas([])
    send(client, {:fake_source, "client", [first.body]})
    :sys.get_state(client)
    refute_receive {:swarm_code_ui_data, _, _}, 0
    Fake.close(client)
    assert :ok = Source.attach(source, "client", self())
  end

  test "deltas arriving during resync are replayed after its snapshot" do
    {source, original} = setup_client()
    Fake.close(original)
    proxy = start_supervised!({HeldSource, source: source, test: self()})

    client =
      start_supervised!(
        Supervisor.child_spec(
          {Fake, source: proxy, source_epoch: "epoch", client_id: "held-client"},
          id: :held_client
        )
      )

    Fake.bind_owner(client, self(), "binding")
    Fake.watch(client, watch())
    assert_receive {:held, _}
    GenServer.call(proxy, :release)
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :watch_ready}}
    Source.advance(source, "sequence-gap")
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :resyncing}}
    assert :ok = Fake.query(client, resync(watch()))
    assert_receive {:held, {:fake_source, _, %Delivery{kind: :watch_ready, body: body}}}
    Source.advance(source, "a1-a2-b1-step-1")
    :sys.get_state(proxy)
    :sys.get_state(client)
    refute_receive {:swarm_code_ui_data, _, %Delivery{kind: :delta}}, 0
    GenServer.call(proxy, :release)
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :watch_ready}}
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :delta, sequence: sequence}}
    assert sequence == body.through_sequence + 1
  end

  test "source exposes canonical workspace permissions and bounded detail queries" do
    {source, client} = setup_client()
    Fake.bind_owner(client, self(), "binding")
    scope = %Scope{kind: :conversation, id: Script.id(:a), generation: 0}
    Fake.watch(client, watch(scope))
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :watch_ready, body: body}}
    assert body.allowed_actions == [:send, :queue, :mark_seen]
    assert body.revision == Script.conversation_revision(Source.snapshot(source), scope.id)

    req = %{
      resync(watch(scope))
      | request_id: "detail",
        kind: {:query_detail, "missing", 0, 4096},
        origin: {:query, :detail},
        expected_response: :detail_window
    }

    assert :ok = Fake.query(client, req)

    assert_receive {:swarm_code_ui_data, _,
                    %Delivery{
                      kind: :response,
                      request_id: "detail",
                      body: %{state: :error, error: %AdmissionError{code: :invalid_origin}}
                    }}
  end

  test "large canonical compose text can be fetched through an admitted detail query" do
    {source, client} = setup_client()
    Fake.bind_owner(client, self(), "binding")
    scope = %Scope{kind: :conversation, id: Script.id(:a), generation: 0}

    req = %{
      resync(watch(scope))
      | request_id: "compose",
        kind: {:dispatch, :send, String.duplicate("😀", 16_385), :main, []},
        origin: {:draft, {scope.id, :main}},
        expected_response: :outcome
    }

    assert :ok = Fake.command(client, req)

    assert_receive {:swarm_code_ui_data, _,
                    %Delivery{kind: :response, body: %{identifiers: [_, item_id | _]}}}

    detail = Source.snapshot(source).transcript[item_id].detail_ref

    query = %{
      req
      | request_id: "detail",
        kind: {:query_detail, detail.id, 0, 8193},
        origin: {:query, :detail},
        expected_response: :detail_window
    }

    assert :ok = Fake.query(client, query)

    assert_receive {:swarm_code_ui_data, _,
                    %Delivery{kind: :response, request_id: "detail", body: page} = delivery}

    assert {:ok, ^delivery} = Delivery.validate(delivery)
    assert page.detail_ref == detail
    assert page.offset == 0
    assert byte_size(page.text) == 8192
    assert page.next_offset == 8192
  end

  test "each admitted query deadline returns its validated expected error page" do
    {source, original} = setup_client()
    Fake.close(original)
    proxy = start_supervised!({HeldSource, source: source, test: self()})

    client =
      start_supervised!(
        Supervisor.child_spec(
          {Fake, source: proxy, source_epoch: "epoch", client_id: "held-client"},
          id: :held_client
        )
      )

    Fake.bind_owner(client, self(), "binding")

    for slot <- [:shell, :workspace, :activity, :inspector, :pending] do
      w = watch(%Scope{kind: :run, id: Script.id(:a1), generation: 0})

      req = %{
        resync(w)
        | request_id: "query-#{slot}",
          kind: {:query, slot, nil, :after, 200, 1_048_576},
          origin: {:query, slot},
          expected_response: Request.query_response(slot)
      }

      assert :ok = Fake.query(client, req)
      assert_receive {:held, {:fake_source, _, %Delivery{kind: :response}}}
      [token] = Map.keys(:sys.get_state(client).workers)
      send(client, {:expired, token})

      assert_receive {:swarm_code_ui_data, _,
                      %Delivery{kind: :response, body: %{state: :error}} = failure}

      assert failure.request_id == req.request_id
      assert {:ok, ^failure} = Delivery.validate(failure)
      assert :sys.get_state(client).requests == %{}
    end
  end

  test "blocking source admission stays cancellable and close settles every worker" do
    {source, client} = setup_client()
    Fake.bind_owner(client, self(), "binding")
    :sys.suspend(source)
    :erlang.trace(client, true, [:receive])
    task = Task.async(fn -> Fake.watch(client, watch()) end)
    assert_receive {:trace, ^client, :receive, {:"$gen_call", _, {:watch, _}}}
    :erlang.trace(client, false, [:receive])
    state = :sys.get_state(client)
    [job] = Map.values(state.workers)
    monitor = Process.monitor(job.pid)
    assert :ok = Fake.close(client)
    assert :ok = Task.await(task)
    assert_receive {:DOWN, ^monitor, :process, _, _}
    assert :sys.get_state(client).workers == %{}
    :sys.resume(source)
    Source.snapshot(source)
    refute_receive {:swarm_code_ui_data, _, %Delivery{kind: :watch_ready}}, 0
  end

  test "malformed owner and unbound cancellation fail without killing the adapter" do
    {_, client} = setup_client()
    assert {:error, :binding_failed} = Fake.bind_owner(client, {:malformed}, "binding")
    assert {:error, %AdmissionError{code: :not_bound}} = Fake.cancel(client, "request")
    assert {:ok, "binding"} = Fake.bind_owner(client, self(), "binding")
  end

  test "embedded shell epoch cannot replace the bound source epoch" do
    {source, original} = setup_client()
    Fake.close(original)
    proxy = start_supervised!({HeldSource, source: source, test: self()})

    client =
      start_supervised!(
        Supervisor.child_spec(
          {Fake, source: proxy, source_epoch: "epoch", client_id: "held-client"},
          id: :held_client
        )
      )

    Fake.bind_owner(client, self(), "binding")
    Fake.watch(client, %{watch() | slot: :shell})
    assert_receive {:held, {:fake_source, id, %Delivery{kind: :watch_ready} = ready}}

    invalid = %{
      ready
      | body: %{ready.body | connection: %{ready.body.connection | source_epoch: "old"}}
    }

    send(client, {:fake_source, id, invalid})
    :sys.get_state(client)
    refute_receive {:swarm_code_ui_data, _, _}, 0
    GenServer.call(proxy, :release)
    assert_receive {:swarm_code_ui_data, "epoch", %Delivery{kind: :watch_ready}}
  end

  test "pre-ready byte overflow recovers before the event-count limit" do
    {source, original} = setup_client()
    Fake.close(original)
    proxy = start_supervised!({HeldSource, source: source, test: self()})

    client =
      start_supervised!(
        Supervisor.child_spec(
          {Fake, source: proxy, source_epoch: "epoch", client_id: "held-client"},
          id: :held_client
        )
      )

    Fake.bind_owner(client, self(), "binding")
    w = %{watch(%Scope{kind: :conversation, id: Script.id(:a), generation: 0}) | page_size: 1}
    Fake.watch(client, w)
    assert_receive {:held, {:fake_source, _, %Delivery{kind: :watch_ready}}}

    Enum.each(1..16, fn n ->
      req = %{
        resync(w)
        | request_id: "large-#{n}",
          kind: {:dispatch, :send, String.duplicate("x", 65_536), :main, []},
          origin: {:draft, {w.scope.id, :main}},
          expected_response: :outcome
      }

      assert :ok = Source.request(source, "held-client", req)
    end)

    assert Source.snapshot(source).sequence < 128
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :resyncing}}
    assert_receive {:held, {:fake_source, _, %Delivery{kind: :watch_ready, body: body}}}, 1000
    assert body.through_sequence > 0
    GenServer.call(proxy, :release)
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :watch_ready, body: installed}}
    assert installed.through_sequence == body.through_sequence
  end

  test "a second gap while resync is in flight cannot install its obsolete snapshot" do
    {source, original} = setup_client()
    Fake.close(original)
    proxy = start_supervised!({HeldSource, source: source, test: self()})

    client =
      start_supervised!(
        Supervisor.child_spec(
          {Fake, source: proxy, source_epoch: "epoch", client_id: "held-client"},
          id: :held_client
        )
      )

    Fake.bind_owner(client, self(), "binding")
    Fake.watch(client, watch())
    assert_receive {:held, _}
    GenServer.call(proxy, :release)
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :watch_ready}}
    # Advance the canonical source while snapshots are held by the relay.
    :sys.suspend(proxy)
    Source.advance(source, "a1-a2-b1-step-1")
    Source.advance(source, "sequence-gap")
    :sys.resume(proxy)
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :resyncing}}
    drain_deltas([])
    Fake.query(client, resync(watch()))
    assert_receive {:held, {:fake_source, _, %Delivery{kind: :watch_ready} = replacement}}
    # snapshot_required itself is a canonical fact, so repeat it at a new cursor
    # to exercise a source replacement indication while the snapshot is held.
    delta = %SwarmCodeCLI.UI.DataSource.Delta{
      kind: :snapshot_required,
      sequence: replacement.body.through_sequence + 2,
      revision: replacement.revision + 1
    }

    send(client, {:fake_source, "held-client", [delta]})
    :sys.get_state(client)
    GenServer.call(proxy, :release)
    :sys.get_state(client)
    refute_receive {:swarm_code_ui_data, _, %Delivery{kind: :watch_ready}}, 0
  end

  test "source pagination follows creation order when request IDs sort backwards" do
    {source, client} = setup_client()
    Fake.bind_owner(client, self(), "binding")
    w = watch(%Scope{kind: :conversation, id: Script.id(:a), generation: 0})

    ids =
      for id <- ["zzz", "aaa"] do
        req = %{
          resync(w)
          | request_id: id,
            kind: {:dispatch, :send, id, :main, []},
            origin: {:draft, {w.scope.id, :main}},
            expected_response: :outcome
        }

        assert :ok = Fake.command(client, req)

        assert_receive {:swarm_code_ui_data, _,
                        %Delivery{kind: :response, body: %{identifiers: [run_id, item_id | _]}}}

        {run_id, item_id}
      end

    Fake.watch(client, w)
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :watch_ready, body: page}}
    assert Enum.take(Enum.map(page.transcript.items, & &1.id), -2) == Enum.map(ids, &elem(&1, 1))
    assert Enum.take(Enum.map(page.runs, & &1.id), -2) == Enum.map(ids, &elem(&1, 0))
    assert Source.snapshot(source).sequence > 0
  end

  test "duplicate client binding never detaches the already bound owner" do
    {source, client} = setup_client()
    Fake.bind_owner(client, self(), "binding")

    other =
      start_supervised!(
        Supervisor.child_spec({Fake, source: source, source_epoch: "epoch", client_id: "client"},
          id: :duplicate
        )
      )

    assert {:error, :binding_failed} = Fake.bind_owner(other, self(), "other")
    assert :ok = Fake.watch(client, watch())
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :watch_ready}}
    Source.advance(source, "a1-a2-b1-step-1")
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :delta}}
  end

  defmodule BindingSource do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    def init(opts),
      do: {:ok, %{source: opts[:source], test: opts[:test], client: nil, metadata: nil}}

    def handle_call({:attach, id, pid}, _, s) do
      result = Source.attach(s.source, id, self())
      {:reply, result, %{s | client: pid}}
    end

    def handle_call(:metadata, from, s) do
      metadata = Source.metadata(s.source)
      send(s.test, :binding_waiting)
      {:noreply, %{s | metadata: {from, metadata}}}
    end

    def handle_call(:release_binding, _, s) do
      {from, metadata} = s.metadata
      GenServer.reply(from, metadata)
      {:reply, :ok, s}
    end

    def handle_call(message, _, s), do: {:reply, GenServer.call(s.source, message), s}
    def handle_cast(_, s), do: {:noreply, s}

    def handle_info(message, s) do
      send(s.client, message)
      {:noreply, s}
    end
  end

  test "canonical traffic during binding advances the cursor without leaking before acknowledgement" do
    {source, original} = setup_client()
    Fake.close(original)
    proxy = start_supervised!({BindingSource, source: source, test: self()})

    client =
      start_supervised!(
        Supervisor.child_spec(
          {Fake, source: proxy, source_epoch: "epoch", client_id: "binding-client"},
          id: :binding_client
        )
      )

    owner = self()
    binding = Task.async(fn -> Fake.bind_owner(client, owner, "binding") end)
    assert_receive :binding_waiting
    Source.advance(source, "a1-a2-b1-step-1")
    :sys.get_state(proxy)
    :sys.get_state(client)
    refute_receive {:swarm_code_ui_data, _, _}, 0
    GenServer.call(proxy, :release_binding)
    assert {:ok, "binding"} = Task.await(binding)
    Fake.watch(client, watch())
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :watch_ready}}
    Source.advance(source, "a1-b1-step-2")
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :delta}}
    refute_receive {:swarm_code_ui_data, _, %Delivery{kind: :resyncing}}, 0
  end

  test "snapshot body cannot smuggle another conversation through a matching envelope" do
    {source, original} = setup_client()
    Fake.close(original)
    proxy = start_supervised!({HeldSource, source: source, test: self()})

    client =
      start_supervised!(
        Supervisor.child_spec(
          {Fake, source: proxy, source_epoch: "epoch", client_id: "held-client"},
          id: :held_client
        )
      )

    Fake.bind_owner(client, self(), "binding")
    w = watch(%Scope{kind: :conversation, id: Script.id(:a), generation: 0})
    Fake.watch(client, w)
    assert_receive {:held, {:fake_source, id, %Delivery{kind: :watch_ready} = ready}}

    send(
      client,
      {:fake_source, id, %{ready | body: %{ready.body | conversation_id: Script.id(:b)}}}
    )

    :sys.get_state(client)
    refute_receive {:swarm_code_ui_data, _, _}, 0
    GenServer.call(proxy, :release)
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :watch_ready}}
  end

  for settlement <- [:cancel, :timeout] do
    test "resync retry after #{settlement} rejects the old snapshot and replays later facts" do
      resync_retry(unquote(settlement))
    end
  end

  defp resync_retry(settlement) do
    {source, original} = setup_client()
    Fake.close(original)
    proxy = start_supervised!({HeldSource, source: source, test: self()})

    client =
      start_supervised!(
        Supervisor.child_spec(
          {Fake, source: proxy, source_epoch: "epoch", client_id: "held-client"},
          id: :held_client
        )
      )

    Fake.bind_owner(client, self(), "binding")
    Fake.watch(client, watch())
    assert_receive {:held, {:fake_source, _, %Delivery{kind: :watch_ready}}}
    GenServer.call(proxy, :release)
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :watch_ready}}

    Source.advance(source, "sequence-gap")
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :resyncing}}
    first = %{resync(watch()) | request_id: "resync-1"}
    assert :ok = Fake.query(client, first)
    assert_receive {:held, {:fake_source, _, %Delivery{kind: :watch_ready, body: obsolete}}}

    case settlement do
      :cancel ->
        assert :ok = Fake.cancel(client, first.request_id)

      :timeout ->
        [token] = Map.keys(:sys.get_state(client).workers)
        send(client, {:expired, token})

        assert_receive {:swarm_code_ui_data, _,
                        %Delivery{kind: :error, body: %AdmissionError{code: :deadline_expired}}}
    end

    Source.advance(source, "a1-a2-b1-step-1")
    :sys.get_state(proxy)
    :sys.get_state(client)
    second = %{first | request_id: "resync-2"}
    assert :ok = Fake.query(client, second)
    assert_receive {:held, {:fake_source, _, %Delivery{kind: :watch_ready, body: replacement}}}
    assert replacement.through_sequence > obsolete.through_sequence

    Source.advance(source, "a1-b1-step-2")
    :sys.get_state(proxy)
    :sys.get_state(client)
    GenServer.call(proxy, :release)
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :watch_ready, body: installed}}
    assert installed.through_sequence == replacement.through_sequence
    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :delta, sequence: sequence}}
    assert sequence == replacement.through_sequence + 1
    refute_receive {:swarm_code_ui_data, _, %Delivery{kind: :watch_ready}}, 0
  end

  test "command admits locally while source is suspended and cancelled work emits no late outcome" do
    {source, client} = setup_client()
    Fake.bind_owner(client, self(), "binding")

    req = %{
      resync(watch())
      | request_id: "pause",
        kind: {:run_control, :pause, Script.id(:a1)},
        origin: {:run, Script.id(:a1)},
        expected_response: :outcome
    }

    :sys.suspend(source)
    task = Task.async(fn -> Fake.command(client, req) end)

    try do
      assert {:ok, :ok} = Task.yield(task, 500)
      assert :sys.get_state(client).requests["pause"] == req
      refute_receive {:swarm_code_ui_data, _, %Delivery{kind: :response}}, 0
    after
      :sys.resume(source)
    end

    assert_receive {:swarm_code_ui_data, _,
                    %Delivery{kind: :response, request_id: "pause", body: %{status: :accepted}}}

    :sys.suspend(source)
    cancelled = %{req | request_id: "cancelled", kind: {:run_control, :continue, Script.id(:a1)}}
    task = Task.async(fn -> Fake.command(client, cancelled) end)

    try do
      assert {:ok, :ok} = Task.yield(task, 500)
      assert :ok = Fake.cancel(client, cancelled.request_id)
      assert :sys.get_state(client).requests == %{}
    after
      :sys.resume(source)
    end

    Source.snapshot(source)
    :sys.get_state(client)

    refute_receive {:swarm_code_ui_data, _, %Delivery{kind: :response, request_id: "cancelled"}},
                   0
  end

  test "known remote command denials are asynchronously correlated rejected outcomes" do
    {_, client} = setup_client()
    Fake.bind_owner(client, self(), "binding")

    req = %{
      resync(watch())
      | request_id: "denied",
        kind: {:run_control, :continue, Script.id(:a1)},
        origin: {:run, Script.id(:a1)},
        expected_response: :outcome
    }

    assert :ok = Fake.command(client, req)

    assert_receive {:swarm_code_ui_data, _,
                    %Delivery{
                      kind: :response,
                      request_id: "denied",
                      body: %{status: :rejected, error: %AdmissionError{code: :not_allowed}}
                    } = delivery}

    assert {:ok, ^delivery} = Delivery.validate(delivery)
  end

  test "watch and query acknowledge local admission while source is suspended" do
    {source, client} = setup_client()
    Fake.bind_owner(client, self(), "binding")

    req = %{
      resync(watch())
      | kind: {:query, :transcript, nil, :after, 200, 1_048_576},
        origin: {:query, :transcript},
        expected_response: :transcript_window
    }

    :sys.suspend(source)
    task = Task.async(fn -> {Fake.watch(client, watch()), Fake.query(client, req)} end)

    try do
      assert {:ok, {:ok, :ok}} = Task.yield(task, 500)
      state = :sys.get_state(client)
      assert map_size(state.workers) == 2
      assert map_size(state.requests) == 1
      assert :ok = Fake.close(client)
      assert :sys.get_state(client).workers == %{}
    after
      :sys.resume(source)
    end

    assert_receive {:swarm_code_ui_data, _, %Delivery{kind: :closed}}
    Source.snapshot(source)
    :sys.get_state(client)

    refute_receive {:swarm_code_ui_data, _, %Delivery{kind: :response}}, 0
    refute_receive {:swarm_code_ui_data, _, %Delivery{kind: :watch_ready}}, 0
  end

  test "remote stale revision emits a correlated conflict outcome" do
    {source, client} = setup_client()
    Fake.bind_owner(client, self(), "binding")
    Source.advance(source, "catalogue-retry")
    id = Script.id(:failed_retry)

    req = %{
      resync(watch())
      | request_id: "stale",
        kind: {:retry_run, id, 999},
        origin: {:run_revision, id, 999},
        expected_response: :outcome
    }

    assert :ok = Fake.command(client, req)

    assert_receive {:swarm_code_ui_data, _,
                    %Delivery{
                      kind: :response,
                      request_id: "stale",
                      body: %{
                        status: :revision_conflict,
                        error: %AdmissionError{code: :stale_revision}
                      }
                    } = delivery}

    assert {:ok, ^delivery} = Delivery.validate(delivery)
  end

  test "remote watch admission failure arrives as a typed watch error" do
    {_, client} = setup_client()
    Fake.bind_owner(client, self(), "binding")
    assert :ok = Fake.watch(client, %{watch() | byte_limit: 1})

    assert_receive {:swarm_code_ui_data, _,
                    %Delivery{
                      kind: :error,
                      watch_ref: "watch",
                      body: %AdmissionError{code: :capacity_exceeded}
                    } = delivery}

    assert {:ok, ^delivery} = Delivery.validate(delivery)
    assert :sys.get_state(client).watches == %{}
  end

  test "source death settles an admitted command as interrupted exactly once" do
    {source, client} = setup_client()
    Fake.bind_owner(client, self(), "binding")
    :sys.suspend(source)

    req = %{
      resync(watch())
      | request_id: "interrupted",
        kind: {:run_control, :pause, Script.id(:a1)},
        origin: {:run, Script.id(:a1)},
        expected_response: :outcome
    }

    assert :ok = Fake.command(client, req)
    Process.exit(source, :kill)

    assert_receive {:swarm_code_ui_data, _,
                    %Delivery{
                      kind: :response,
                      request_id: "interrupted",
                      body: %{
                        status: :interrupted,
                        error: %AdmissionError{code: :source_unavailable}
                      }
                    } = delivery}

    assert {:ok, ^delivery} = Delivery.validate(delivery)
    assert :sys.get_state(client).phase == :closed
    refute_receive {:swarm_code_ui_data, _, %Delivery{kind: :response}}, 0
  end

  defp drain_deltas(acc) do
    receive do
      {:swarm_code_ui_data, _, %Delivery{kind: :delta} = delta} -> drain_deltas(acc ++ [delta])
    after
      0 -> acc
    end
  end
end
