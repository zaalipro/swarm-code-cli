defmodule SwarmCodeCLI.UI.Pass73Qa2RuntimeTest do
  @moduledoc """
  pass73 G2 (QA #2 Q2-05): the status row said "reconnecting" at about
  10:25 and cli.log said nothing: only the resyncs the daemon asks for were
  logged. A resync the client asks for (here a sequence gap) is logged with
  its slot and reason. (That the chat keeps following across the fresh
  snapshot is pinned in `Pass73Qa2Test`.)
  """
  use ExUnit.Case, async: false

  alias SwarmCodeCLI.UI.{Capabilities, Init, SessionRuntime, Size}
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Delta, Fake}
  alias Fake.{Script, Source}

  defp setup_runtime do
    {:ok, script} =
      Script.decode(File.read!(Path.expand("../../fixtures/fake/three_run_script.json", __DIR__)))

    source = start_supervised!({Source, script: script, source_epoch: "epoch"})

    client =
      start_supervised!(
        {Fake, source: source, source_epoch: "epoch", client_id: "qa2-runtime-client"}
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

    {:ok, _} = SessionRuntime.register_terminal(runtime, self(), 0, caps)
    runtime
  end

  defp workspace_ready(runtime, attempts \\ 2_000)
  defp workspace_ready(_runtime, 0), do: flunk("the workspace watch never became ready")

  defp workspace_ready(runtime, n) do
    state = SessionRuntime.snapshot(runtime)

    if SessionRuntime.status(runtime).phase == :running and
         state.watches.workspace.status == :ready,
       do: state,
       else: workspace_ready(runtime, n - 1)
  end

  test "a resync the client asks for is logged with its slot and reason" do
    runtime = setup_runtime()
    state = workspace_ready(runtime)
    watch = state.watches.workspace
    item = state.read_model.transcript["message-A-1"]

    # One delta skipped: the next one arrives two past the watermark.
    delta = %Delta{
      kind: :stream_append,
      entity_id: item.id,
      run_id: item.run_id,
      conversation_id: item.conversation_id,
      attempt_id: item.attempt_id,
      channel: :text,
      text: "[gap]",
      revision: max(watch.revision, item.revision) + 2,
      sequence: watch.sequence + 2
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

    log =
      ExUnit.CaptureLog.capture_log([level: :info], fn ->
        send(runtime, {:swarm_code_ui_data, "epoch", delivery})
        resyncing = SessionRuntime.snapshot(runtime)
        assert resyncing.watches.workspace.resync_reason == :gap
      end)

    assert log =~
             "SwarmCode: asked the daemon for a fresh workspace snapshot " <>
               "(a delta arrived out of order)"
  end
end
