defmodule SwarmCodeCLI.UI.SessionRuntimeTest do
  use ExUnit.Case, async: false
  alias SwarmCodeCLI.UI.{SessionRuntime, SceneSlot, Init, Size, Capabilities, Editor, Drafts}
  alias SwarmCodeCLI.UI.DataSource.Fake
  alias Fake.{Script, Source}

  defp setup_runtime do
    {:ok, script} =
      Script.decode(File.read!(Path.expand("../../fixtures/fake/three_run_script.json", __DIR__)))

    source = start_supervised!({Source, script: script, source_epoch: "epoch"})

    client =
      start_supervised!(
        {Fake, source: source, source_epoch: "epoch", client_id: "runtime-client"}
      )

    size = %Size{columns: 160, rows: 50}
    caps = %Capabilities{size: size}

    init = %Init{
      size: size,
      capabilities: caps,
      source_epoch: "epoch",
      destination: {:conversation, Script.id(:a)},
      now: Script.clock_ms()
    }

    runtime =
      start_supervised!({SessionRuntime, init: init, data_source: client, frame_ms: 60_000})

    {source, client, runtime, caps}
  end

  defp ready(runtime, attempts \\ 200)
  defp ready(_, 0), do: flunk("runtime did not bind")

  defp ready(runtime, n) do
    if SessionRuntime.status(runtime).phase == :running, do: :ok, else: ready(runtime, n - 1)
  end

  defp paint(runtime) do
    %{draw: {:timer, id}} = SessionRuntime.status(runtime)
    send(runtime, {:frame, id})
    assert_receive {:draw, token, revision}
    {token, revision}
  end

  test "two-phase binding gates watches; protected slot exposes only the exact latest revision" do
    {source, _, runtime, caps} = setup_runtime()
    assert SessionRuntime.status(runtime).phase == :binding
    assert Enum.all?(:sys.get_state(source).clients, fn {_, client} -> client.watches == %{} end)
    assert {:ok, tid} = SessionRuntime.register_terminal(runtime, self(), 0, caps)
    ready(runtime)
    assert :ets.info(tid, :protection) == :protected
    assert_raise ArgumentError, fn -> :ets.insert(tid, {:scene, :bad}) end
    {token, revision} = paint(runtime)
    assert {:ok, scene} = SceneSlot.fetch(tid, revision)
    assert scene.revision == revision
    assert {:error, :stale_revision} = SceneSlot.fetch(tid, revision + 1)
    send(runtime, {:draw_result, token, revision, :ok})
    assert SessionRuntime.status(runtime).phase == :running
  end

  test "100 edits are applied while paints coalesce and an in-flight update survives stale acknowledgments" do
    {_, _, runtime, caps} = setup_runtime()
    {:ok, tid} = SessionRuntime.register_terminal(runtime, self(), 0, caps)
    ready(runtime)

    for _ <- 1..100,
        do: SessionRuntime.action(runtime, {:editor, {Script.id(:a), :main}, {:insert, "x"}})

    draft = Drafts.fetch(SessionRuntime.snapshot(runtime).drafts, {Script.id(:a), :main})
    assert Editor.text(draft.editor) == String.duplicate("x", 100)
    assert SessionRuntime.status(runtime).timer_count == 1
    {token, revision} = paint(runtime)
    SessionRuntime.action(runtime, {:editor, {Script.id(:a), :main}, {:insert, "y"}})
    assert {:error, :stale_revision} = SceneSlot.fetch(tid, revision)
    send(runtime, {:draw_result, "wrong", revision, :ok})
    assert match?({:in_flight, ^token, ^revision, 0}, SessionRuntime.status(runtime).draw)
    send(runtime, {:draw_result, token, revision, :ok})
    assert match?({:timer, _}, SessionRuntime.status(runtime).draw)
    {_, newer} = paint(runtime)
    assert newer > revision
  end

  test "dirty detach rejects direct close, Cancel preserves drafts, explicit Confirm paints before client closure" do
    {source, client, runtime, caps} = setup_runtime()
    {:ok, tid} = SessionRuntime.register_terminal(runtime, self(), 0, caps)
    ready(runtime)

    SessionRuntime.action(
      runtime,
      {:editor, {Script.id(:a), :main}, {:insert, "private runtime draft"}}
    )

    draft = SessionRuntime.snapshot(runtime).drafts
    assert {:error, :confirmation_required} = SessionRuntime.close(runtime, {:confirmed, :detach})
    SessionRuntime.input(runtime, {:text_fragment, :press, "q", []})
    assert SessionRuntime.snapshot(runtime).focus == "cancel"
    SessionRuntime.input(runtime, {:key, :press, :enter, []})
    assert SessionRuntime.snapshot(runtime).drafts == draft
    assert SessionRuntime.status(runtime).phase == :running
    refute inspect(:sys.get_status(runtime)) =~ "private runtime draft"
    SessionRuntime.input(runtime, {:text_fragment, :press, "q", []})
    SessionRuntime.input(runtime, {:key, :press, :tab, []})
    SessionRuntime.input(runtime, {:key, :press, :enter, []})
    assert_receive {:draw, token, revision}
    assert {:ok, scene} = SceneSlot.fetch(tid, revision)

    assert SwarmCodeCLI.UI.SafeText.value(hd(hd(scene.regions).blocks).text) ==
             "Closing SwarmCode."

    monitor = Process.monitor(runtime)
    send(runtime, {:draw_result, token, revision, :ok})
    assert_receive {:terminal_control, :shutdown, shutdown_token}
    send(runtime, {:terminal_shutdown, shutdown_token, :ok})
    assert_receive {:DOWN, ^monitor, :process, ^runtime, :normal}
    assert :ets.info(tid) == :undefined
    assert :sys.get_state(client).phase == :closed
    assert :ok = Source.advance(source, "a1-a2-b1-step-1")
    assert Source.snapshot(source).commands == %{}
  end

  test "generation changes invalidate draws and stale capability/focus events cannot roll back state" do
    {_, _, runtime, caps} = setup_runtime()
    {:ok, _} = SessionRuntime.register_terminal(runtime, self(), 0, caps)
    ready(runtime)
    {token, revision} = paint(runtime)
    newer = %{caps | size: %Size{columns: 80, rows: 24}, reduced_motion?: true}
    SessionRuntime.action(runtime, {:terminal_capabilities, 1, newer})
    next = SessionRuntime.status(runtime).draw
    send(runtime, {:draw_result, token, revision, :ok})
    assert SessionRuntime.status(runtime).draw == next
    SessionRuntime.action(runtime, {:terminal_capabilities, 0, caps})
    SessionRuntime.action(runtime, {:terminal_focus, :lost, 0})
    assert SessionRuntime.snapshot(runtime).terminal_focus == :gained
    SessionRuntime.action(runtime, {:terminal_focus, :lost, 1})
    assert SessionRuntime.snapshot(runtime).terminal_focus == :lost
    assert SessionRuntime.snapshot(runtime).size == newer.size
    assert SessionRuntime.status(runtime).timer_count == 0
  end

  test "duplicate terminal registration rolls back client, scene and terminal" do
    {_, client, runtime, caps} = setup_runtime()
    {:ok, tid} = SessionRuntime.register_terminal(runtime, self(), 0, caps)
    ready(runtime)
    monitor = Process.monitor(runtime)

    assert {:error, :duplicate_terminal} =
             SessionRuntime.register_terminal(runtime, self(), 0, caps)

    assert_receive {:terminal_control, :shutdown, token}
    send(runtime, {:terminal_shutdown, token, :ok})
    assert_receive {:DOWN, ^monitor, :process, ^runtime, :normal}
    assert :ets.info(tid) == :undefined
    assert :sys.get_state(client).phase == :closed
  end

  test "draw failure closes a dirty client without issuing a domain command" do
    {source, client, runtime, caps} = setup_runtime()
    {:ok, _} = SessionRuntime.register_terminal(runtime, self(), 0, caps)
    ready(runtime)
    SessionRuntime.action(runtime, {:editor, {Script.id(:a), :main}, {:insert, "draft"}})
    {token, revision} = paint(runtime)
    monitor = Process.monitor(runtime)
    send(runtime, {:draw_result, token, revision, {:error, :draw_failed}})
    assert_receive {:terminal_control, :shutdown, shutdown}
    send(runtime, {:terminal_shutdown, shutdown, :ok})
    assert_receive {:DOWN, ^monitor, :process, ^runtime, :normal}
    assert :sys.get_state(client).phase == :closed
    assert Source.snapshot(source).commands == %{}
  end

  test "plain handoff Cancel emits nothing and explicit Confirm emits only the fixed instruction" do
    {_, _, runtime, caps} = setup_runtime()
    {:ok, _} = SessionRuntime.register_terminal(runtime, self(), 0, caps)
    ready(runtime)
    SessionRuntime.action(runtime, {:draft_target, {Script.id(:a), :main}, :main})
    SessionRuntime.input(runtime, {:text_fragment, :press, "P", []})
    assert SessionRuntime.snapshot(runtime).focus == "cancel"
    SessionRuntime.input(runtime, {:key, :press, :enter, []})
    assert SessionRuntime.status(runtime).phase == :running
    refute_receive {:plain_instruction, _}, 0
    SessionRuntime.input(runtime, {:text_fragment, :press, "P", []})
    SessionRuntime.input(runtime, {:key, :press, :tab, []})
    SessionRuntime.input(runtime, {:key, :press, :enter, []})
    assert_receive {:draw, token, revision}
    send(runtime, {:draw_result, token, revision, :ok})
    assert_receive {:terminal_control, :shutdown, shutdown}
    refute_receive {:plain_instruction, _}, 0
    monitor = Process.monitor(runtime)
    send(runtime, {:terminal_shutdown, shutdown, :ok})
    assert_receive {:plain_instruction, "Rerun with --plain"}
    assert_receive {:DOWN, ^monitor, :process, ^runtime, :normal}
  end

  test "all local query admission failures remain valid typed correlated responses" do
    {_, client, _, _} = setup_runtime()
    SwarmCodeCLI.UI.DataSource.Fake.close(client)
    alias SwarmCodeCLI.UI.DataSource.{Request, Delivery}

    context = %{
      data_source: client,
      owner: self(),
      source_epoch: "epoch",
      local: fn _ -> flunk("unexpected local effect") end
    }

    for kind <- [:shell, :workspace, :transcript, :activity, :inspector, :pending] do
      request = %Request{
        request_id: Atom.to_string(kind),
        kind: {:query, kind, nil, :after, 10, 1024},
        origin: {:query, kind},
        scope: %SwarmCode.Protocol.Scope{kind: :global, id: nil, generation: 0},
        generation: 0,
        deadline: Script.clock_ms() + 1000,
        expected_response: Request.query_response(kind)
      }

      assert :ok = SwarmCodeCLI.UI.EffectRunner.run({:query, request}, context)
      assert_receive {:swarm_code_ui_data, "epoch", delivery}
      assert {:ok, _} = Delivery.validate(delivery)
      assert delivery.request_id == request.request_id
      assert delivery.body.error.code == :closed
    end
  end

  test "terminal-first binding admits neither watches nor draws until the delayed source acknowledgment" do
    {source, _client, _runtime, caps} = setup_runtime()
    # A second source makes the ordering explicit without wall-clock waits.
    stop_supervised(SessionRuntime)
    stop_supervised(Fake)
    :sys.suspend(source)
    on_exit(fn -> if Process.alive?(source), do: :sys.resume(source) end)

    client =
      start_supervised!({Fake, source: source, source_epoch: "epoch", client_id: "delayed"})

    size = caps.size
    init = %Init{size: size, capabilities: caps, source_epoch: "epoch", now: Script.clock_ms()}

    runtime =
      start_supervised!({SessionRuntime, init: init, data_source: client, frame_ms: 60_000})

    {:ok, _} = SessionRuntime.register_terminal(runtime, self(), 0, caps)
    assert SessionRuntime.status(runtime).phase == :binding
    assert :sys.get_state(client).watches == %{}
    refute_receive {:draw, _, _}, 0
    :sys.resume(source)
    ready(runtime)
    assert map_size(:sys.get_state(client).watches) == 2
  end

  for {columns, rows} <- [{1, 1}, {10, 3}, {49, 13}] do
    test "dirty tiny exit #{columns}x#{rows} requires uppercase X and Escape preserves state" do
      {_, _, runtime, caps} = setup_runtime()
      {:ok, _} = SessionRuntime.register_terminal(runtime, self(), 0, caps)
      ready(runtime)
      SessionRuntime.action(runtime, {:draft_target, {Script.id(:a), :main}, :main})

      SessionRuntime.input(
        runtime,
        {:resize, %Size{columns: unquote(columns), rows: unquote(rows)}}
      )

      saved = SessionRuntime.snapshot(runtime).drafts
      SessionRuntime.input(runtime, {:text_fragment, :press, "q", []})
      SessionRuntime.input(runtime, {:key, :press, :enter, []})
      assert SessionRuntime.snapshot(runtime).exit_pending == :detach
      SessionRuntime.input(runtime, {:key, :press, :escape, []})
      assert SessionRuntime.snapshot(runtime).drafts == saved
      assert SessionRuntime.status(runtime).phase == :running
      SessionRuntime.input(runtime, {:text_fragment, :press, "q", []})
      SessionRuntime.input(runtime, {:text_fragment, :repeat, "X", []})
      assert SessionRuntime.status(runtime).phase == :running
      SessionRuntime.input(runtime, {:text_fragment, :press, "X", []})
      assert_receive {:draw, token, revision}
      send(runtime, {:draw_result, token, revision, :ok})
      assert_receive {:terminal_control, :shutdown, shutdown}
      send(runtime, {:terminal_shutdown, shutdown, :ok})
    end
  end

  test "resync local admission failure settles its watch with a typed error" do
    {_, client, _, _} = setup_runtime()
    Fake.close(client)
    alias SwarmCodeCLI.UI.DataSource.{Request, Delivery}

    request = %Request{
      request_id: "resync",
      kind: {:resync_watch, "watch"},
      origin: {:watch, "watch"},
      scope: %SwarmCode.Protocol.Scope{kind: :global, id: nil, generation: 2},
      generation: 2,
      deadline: Script.clock_ms() + 1000,
      expected_response: :watch_snapshot
    }

    context = %{data_source: client, owner: self(), source_epoch: "epoch", local: fn _ -> :ok end}
    assert :ok = SwarmCodeCLI.UI.EffectRunner.run({:query, request}, context)

    assert_receive {:swarm_code_ui_data, "epoch",
                    %Delivery{kind: :error, watch_ref: "watch", request_id: nil} = delivery}

    assert {:ok, _} = Delivery.validate(delivery)
  end

  test "100 ordered semantic deltas are all applied without replacing the pending frame" do
    {_, _, runtime, caps} = setup_runtime()
    {:ok, _} = SessionRuntime.register_terminal(runtime, self(), 0, caps)
    ready(runtime)

    state =
      Enum.reduce_while(1..1000, nil, fn _, _ ->
        state = SessionRuntime.snapshot(runtime)
        if state.watches.workspace.status == :ready, do: {:halt, state}, else: {:cont, nil}
      end)

    assert state != nil
    watch = state.watches.workspace
    item = state.read_model.transcript["message-A-1"]
    frame = SessionRuntime.status(runtime).draw
    alias SwarmCodeCLI.UI.DataSource.{Delivery, Delta}

    for n <- 1..100 do
      delta = %Delta{
        kind: :stream_append,
        entity_id: item.id,
        run_id: item.run_id,
        conversation_id: item.conversation_id,
        attempt_id: item.attempt_id,
        channel: :text,
        text: "[#{n}]",
        revision: max(watch.revision, item.revision) + n,
        sequence: watch.sequence + n
      }

      delivery = %Delivery{
        kind: :delta,
        watch_ref: watch.watch_ref,
        request_id: nil,
        scope: watch.scope,
        generation: watch.generation,
        revision: delta.revision,
        sequence: delta.sequence,
        body: delta
      }

      assert {:ok, _} = Delivery.validate(delivery)
      send(runtime, {:swarm_code_ui_data, "epoch", delivery})
    end

    next = SessionRuntime.snapshot(runtime)

    assert SwarmCodeCLI.UI.ReadModel.transcript_item(next.read_model, item.id).text ==
             item.text <> Enum.map_join(1..100, &"[#{&1}]")

    assert next.watches.workspace.sequence == watch.sequence + 100
    assert SessionRuntime.status(runtime).draw == frame
  end

  test "confirmed detach waits for the in-flight paint before attempting its one final scene" do
    {_, _, runtime, caps} = setup_runtime()
    {:ok, _} = SessionRuntime.register_terminal(runtime, self(), 0, caps)
    ready(runtime)
    {old_token, old_revision} = paint(runtime)
    # The script's runs are live, so q asks first; y stops them and quits.
    SessionRuntime.input(runtime, {:text_fragment, :press, "q", []})
    assert SessionRuntime.status(runtime).phase == :running
    assert SessionRuntime.snapshot(runtime).quit_live_runs > 0
    SessionRuntime.input(runtime, {:text_fragment, :press, "y", []})
    assert SessionRuntime.status(runtime).phase == :closing
    refute_receive {:draw, _, _}, 0
    send(runtime, {:draw_result, old_token, old_revision, :ok})
    assert_receive {:draw, final_token, final_revision}
    assert final_revision > old_revision
    send(runtime, {:draw_result, old_token, old_revision, :ok})
    refute_receive {:terminal_control, :shutdown, _}, 0
    send(runtime, {:draw_result, final_token, final_revision, :ok})
    assert_receive {:terminal_control, :shutdown, shutdown}
    send(runtime, {:terminal_shutdown, shutdown, :ok})
  end

  test "the renderer stable handle forwards the plain instruction after restore" do
    {_, _, runtime, caps} = setup_runtime()

    renderer =
      start_supervised!(
        {SwarmCodeCLI.Test.RendererFake, runtime: runtime, capabilities: caps, observer: self()}
      )

    ready(runtime)
    SessionRuntime.input(runtime, {:text_fragment, :press, "P", []})
    SessionRuntime.input(runtime, {:text_fragment, :press, "y", []})
    assert_receive {:renderer_draw, ^renderer, _, _, :ok}
    SwarmCodeCLI.Test.RendererFake.settle(renderer)
    assert_receive {:renderer_shutdown, ^renderer}
    assert_receive {:plain_instruction, "Rerun with --plain"}
  end

  test "suspension cancels a pending frame and resumption schedules the current scene" do
    {_, _, runtime, caps} = setup_runtime()
    {:ok, _} = SessionRuntime.register_terminal(runtime, self(), 0, caps)
    ready(runtime)
    {:timer, frame} = SessionRuntime.status(runtime).draw
    SessionRuntime.action(runtime, {:terminal_lifecycle, :suspend_requested, 0, :keyboard})
    assert_receive {:terminal_control, :suspend, 0}
    assert SessionRuntime.status(runtime).draw == :idle
    send(runtime, {:frame, frame})
    refute_receive {:draw, _, _}, 0
    SessionRuntime.action(runtime, {:terminal_lifecycle, :suspended, 0, :runtime})
    SessionRuntime.action(runtime, {:terminal_lifecycle, :resumed, 0, :runtime})
    assert_receive {:terminal_control, :resume, 0}
    assert match?({:timer, _}, SessionRuntime.status(runtime).draw)
  end

  test "queued semantic input after reducer-confirmed exit is frozen before the owned effect settles" do
    {_, _, runtime, caps} = setup_runtime()
    {:ok, _} = SessionRuntime.register_terminal(runtime, self(), 0, caps)
    ready(runtime)
    a = {Script.id(:a), :main}
    :sys.suspend(runtime)
    first = make_ref()
    second = make_ref()
    third = make_ref()
    send(runtime, {:"$gen_call", {self(), first}, {:action, {:quit_requested, :detach}}})
    # The script's runs are live: the quit asks, and y confirms it.
    send(
      runtime,
      {:"$gen_call", {self(), make_ref()}, {:input, {:text_fragment, :press, "y", []}}}
    )

    send(
      runtime,
      {:"$gen_call", {self(), second}, {:action, {:editor, a, {:insert, "late draft"}}}}
    )

    send(runtime, {:"$gen_call", {self(), third}, :snapshot})
    :sys.resume(runtime)
    assert_receive {^first, :ok}
    assert_receive {^second, :ok}
    assert_receive {^third, snapshot}
    assert Editor.text(Drafts.fetch(snapshot.drafts, a).editor) == ""
  end
end
