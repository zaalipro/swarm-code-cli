defmodule SwarmCodeCLI.Plain.ClockTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Demo.FiniteInput
  alias SwarmCodeCLI.Plain.{Options, Session}
  alias SwarmCodeCLI.Test.OneShotHarness, as: H
  alias SwarmCodeCLI.UI.DataSource.{Delivery, DTO, Request, Watch}
  alias SwarmCodeCLI.UI.DataSource.Daemon.Codec

  @wall 1_790_000_000_000
  @nonce "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
  @wire "66666666-6666-4666-8666-666666666666"
  @detail "77777777-7777-4777-8777-777777777777"

  setup do
    clock =
      start_supervised!({Agent, fn -> %{system: @wall, monotonic: -5_000, reads: 0} end})

    tick = fn kind -> Agent.get(clock, &Map.fetch!(&1, kind)) end

    wall = fn ->
      Agent.get_and_update(clock, fn state ->
        {state.system, %{state | reads: state.reads + 1}}
      end)
    end

    source = start_supervised!({H.Source, self()})
    input = start_supervised!(FiniteInput)
    {:ok, output} = StringIO.open("")

    options = [
      options: %Options{},
      data_source: source,
      input: input,
      output: output,
      error: output,
      source_epoch: H.epoch(),
      conversation_id: H.conversation(),
      observer: self(),
      eof: :wait,
      now: 1_000,
      clock: wall
    ]

    session = start_supervised!({Session, options})
    assert_receive {:bound, ^session}
    assert_receive {:source, {:watch, %Watch{slot: :shell} = shell}}

    H.ready(session, shell, %DTO.ShellSnapshot{
      counts: %DTO.Counts{},
      connection: %DTO.Connection{source_epoch: H.epoch()}
    })

    assert_receive {:source, {:watch, %Watch{slot: :workspace} = workspace}}
    snapshot = workspace_snapshot()
    assert {:ok, _} = DTO.RunSummary.validate(hd(snapshot.runs))
    assert {:ok, _} = DTO.TranscriptItem.validate(hd(snapshot.transcript.items))
    assert {:ok, _} = DTO.TranscriptWindow.validate(snapshot.transcript)
    assert {:ok, _} = DTO.WorkspaceSnapshot.validate(snapshot)
    H.ready(session, workspace, snapshot)
    assert_receive {:plain_session, ^session, :ready}, 2_000

    %{
      clock: clock,
      tick: tick,
      session: session,
      input: input,
      workspace: workspace,
      snapshot: snapshot,
      options: options,
      output: output
    }
  end

  test "all owner paths read wall time once after elapsed time and wall corrections", context do
    Agent.update(context.clock, &%{&1 | system: @wall + 31_000, monotonic: 26_000})

    for wall <- [@wall + 31_000, @wall + 3_631_000, @wall - 3_569_000] do
      Agent.update(context.clock, &%{&1 | system: wall})
      assert context.tick.(:monotonic) == 26_000

      for {line, kind} <- [
            {"send -- fresh", :dispatch},
            {"queue -- fresh", :dispatch},
            {"send -- /help", :dispatch},
            {"steer #{H.run_id()} #{H.root()} -- fresh", :steer},
            {"pause #{H.run_id()}", :run_control},
            {"detail #{@detail}", :query_detail}
          ] do
        mode = if kind == :query_detail, do: :query, else: :command
        before = context.tick.(:reads)
        assert :ok = FiniteInput.release_line(context.input, line <> "\n")
        assert_receive {:source, {:request, ^mode, %Request{} = request}}, 2_000
        assert elem(request.kind, 0) == kind
        assert_deadline(context, request, wall, before)

        body =
          if kind == :query_detail,
            do: %DTO.DetailWindow{
              detail_ref: %DTO.DetailRef{id: @detail, total_bytes: 1},
              offset: 0,
              text: "x"
            },
            else: %DTO.Outcome{status: :accepted}

        H.respond(%{owner: context.session}, request, body)
        await_response(context.session, request.request_id)
        assert Session.snapshot(context.session).phase == :ready
      end

      before = context.tick.(:reads)
      deliver(context, :resyncing)
      assert_receive {:source, {:request, :query, %Request{} = resync}}, 2_000
      assert resync.kind == {:resync_watch, context.workspace.watch_ref}
      assert_deadline(context, resync, wall, before)
      assert Session.snapshot(context.session).phase == :awaiting_ready
      H.ready(context.session, context.workspace, context.snapshot)
      assert Session.snapshot(context.session).phase == :ready
    end

    # Exercise completion through EOF's actual owner phase, not a private helper.
    before = context.tick.(:reads)
    assert :ok = FiniteInput.eof(context.input)
    assert_receive {:source, {:request, :query, %Request{} = completion}}, 2_000
    assert completion.kind == {:query, :workspace, nil, :before, 200, 1_048_576}
    assert_deadline(context, completion, @wall - 3_569_000, before)
    assert Session.snapshot(context.session).phase == :awaiting_outcome
    H.respond(%{owner: context.session}, completion, %{context.snapshot | runs: []})
    assert_receive {:plain_session, _, {:closed, :eof}}, 2_000
    assert Session.snapshot(context.session).phase == :closed
    assert elem(StringIO.contents(context.output), 1) =~ "DETACHED"
  end

  test "invalid clock option retains the plain session startup refusal", context do
    for clock <- [nil, 1_000, fn _ -> @wall end] do
      assert {:stop, :invalid_plain_session} =
               Session.init(Keyword.put(context.options, :clock, clock))
    end
  end

  defp assert_deadline(context, request, wall, before) do
    assert request.deadline == wall + 30_000
    assert context.tick.(:reads) == before + 1
    assert Session.snapshot(context.session).now == 1_000
    assert {:ok, message} = Codec.request(request, @wire, @nonce, wall)
    assert message.body["timeout_ms"] == 30_000
  end

  defp workspace_snapshot do
    %DTO.WorkspaceSnapshot{
      conversation_id: H.conversation(),
      allowed_actions: [:send, :queue],
      runs: [H.run(:running, allowed_actions: [:pause, :stop, :steer])],
      transcript: %DTO.TranscriptWindow{
        items: [
          H.message("",
            allowed_actions: [:steer],
            detail_ref: %DTO.DetailRef{id: @detail, total_bytes: 1}
          )
        ]
      },
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    }
  end

  defp deliver(context, kind) do
    watch = context.workspace

    send(
      context.session,
      {:swarm_code_ui_data, H.epoch(),
       %Delivery{
         kind: kind,
         watch_ref: watch.watch_ref,
         scope: watch.scope,
         generation: watch.generation,
         body: nil,
         request_id: nil,
         revision: nil,
         sequence: nil
       }}
    )
  end

  defp await_response(session, id) do
    receive do
      {:plain_session, ^session, {:delivery, %{request_id: ^id}}} -> :ok
      {:plain_session, ^session, _} -> await_response(session, id)
    after
      2_000 -> flunk("missing response #{id}")
    end
  end
end
