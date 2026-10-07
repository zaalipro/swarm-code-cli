defmodule SwarmCodeCLI.Plain.SessionEofTest do
  @moduledoc """
  cli020 B6 (bugs-8, bugs-9) and the `--plain` half of B3: at stdin EOF the
  plain session waits until the conversation's queue is empty and no chat run
  is live; a refused send, and with `fail_on_denied` a denied approval, make
  the summary the launcher turns into exit 1.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Demo.FiniteInput
  alias SwarmCodeCLI.Plain.{Options, Session}
  alias SwarmCodeCLI.Test.OneShotHarness, as: H
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Delivery, Delta, DTO, Request, Watch}

  @epoch H.epoch()
  @conversation H.conversation()
  @run1 "33333333-3333-4333-8333-333333333331"
  @run2 "33333333-3333-4333-8333-333333333332"

  setup do
    source = start_supervised!({H.Source, self()})
    input = start_supervised!(FiniteInput)
    {:ok, output} = StringIO.open("")
    {:ok, error} = StringIO.open("")

    session =
      start_supervised!(
        {Session,
         options: %Options{},
         data_source: source,
         input: input,
         output: output,
         error: error,
         source_epoch: @epoch,
         observer: self(),
         conversation_id: @conversation,
         eof: :wait,
         now: 1_000}
      )

    assert_receive {:bound, ^session}, 2_000
    assert_receive {:source, {:watch, %Watch{slot: :shell} = shell}}, 2_000

    ready(session, shell, %DTO.ShellSnapshot{
      counts: %DTO.Counts{},
      connection: %DTO.Connection{source_epoch: @epoch}
    })

    assert_receive {:source, {:watch, %Watch{slot: :workspace} = workspace}}, 2_000
    ready(session, workspace, workspace_snapshot([], []))
    assert_receive {:plain_session, ^session, :ready}, 2_000
    %{session: session, input: input, workspace: workspace, sequence: 0}
  end

  defp workspace_snapshot(runs, queued) do
    %DTO.WorkspaceSnapshot{
      conversation_id: @conversation,
      allowed_actions: [:send, :queue],
      runs: runs,
      queued: length(queued),
      queued_texts: queued,
      transcript: %DTO.TranscriptWindow{},
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    }
  end

  defp ready(session, watch, body) do
    send(
      session,
      {:swarm_code_ui_data, @epoch,
       %Delivery{
         kind: :watch_ready,
         watch_ref: watch.watch_ref,
         request_id: nil,
         scope: watch.scope,
         generation: watch.generation,
         revision: 0,
         sequence: nil,
         body: body
       }}
    )
  end

  defp respond(context, %Request{} = request, body) do
    body =
      if Map.has_key?(body, :request_id), do: %{body | request_id: request.request_id}, else: body

    send(
      context.session,
      {:swarm_code_ui_data, @epoch,
       %Delivery{
         kind: :response,
         request_id: request.request_id,
         watch_ref: nil,
         scope: request.scope,
         generation: request.generation,
         revision: nil,
         sequence: nil,
         body: body
       }}
    )
  end

  defp run(id, state),
    do: %DTO.RunSummary{
      id: id,
      conversation_id: @conversation,
      state: state,
      kind: :chat,
      title: "t",
      allowed_actions: [:stop]
    }

  defp run_update(context, id, state) do
    sequence = context.sequence + 1
    watch = context.workspace
    body = %{run(id, state) | revision: sequence}

    send(
      context.session,
      {:swarm_code_ui_data, @epoch,
       %Delivery{
         kind: :delta,
         watch_ref: watch.watch_ref,
         request_id: nil,
         scope: watch.scope,
         generation: watch.generation,
         revision: sequence,
         sequence: sequence,
         body: %Delta{
           kind: :run_update,
           entity_id: id,
           run_id: id,
           conversation_id: @conversation,
           body: body,
           sequence: sequence,
           revision: sequence
         }
       }}
    )

    %{context | sequence: sequence}
  end

  defp send_line(context, line) do
    :ok = FiniteInput.release_line(context.input, line)
    assert_receive {:source, {:request, :command, %Request{} = request}}, 2_000
    request
  end

  defp completion_query do
    assert_receive {:source,
                    {:request, :query, %Request{kind: {:query, :workspace, _, _, _, _}} = query}},
                   2_000

    query
  end

  test "a queued prompt at EOF still runs before the session closes", context do
    send_request = send_line(context, "send -- first\n")
    respond(context, send_request, %DTO.Outcome{status: :accepted, identifiers: [@run1]})
    queue_request = send_line(context, "queue -- second\n")
    respond(context, queue_request, %DTO.Outcome{status: :accepted, identifiers: []})
    :ok = FiniteInput.eof(context.input)

    respond(context, completion_query(), workspace_snapshot([run(@run1, :running)], ["second"]))
    context = run_update(context, @run1, :done)

    respond(
      context,
      completion_query(),
      workspace_snapshot([run(@run1, :done), run(@run2, :running)], [])
    )

    assert :sys.get_state(context.session).phase == :waiting_completion
    refute_received {:plain_session, _, {:closed, _}}
    context = run_update(context, @run2, :done)

    respond(
      context,
      completion_query(),
      workspace_snapshot([run(@run1, :done), run(@run2, :done)], [])
    )

    session = context.session
    assert_receive {:plain_session, ^session, {:summary, %{refused: 0, denied: 0}}}, 2_000
    assert_receive {:plain_session, ^session, {:closed, :eof}}, 2_000
  end

  test "a refused send is counted for the exit code", context do
    request = send_line(context, "send -- nope\n")

    respond(context, request, %DTO.Outcome{
      status: :rejected,
      error: AdmissionError.new(:not_allowed)
    })

    :ok = FiniteInput.eof(context.input)
    respond(context, completion_query(), workspace_snapshot([], []))

    session = context.session
    assert_receive {:plain_session, ^session, {:summary, %{refused: 1}}}, 2_000
    assert_receive {:plain_session, ^session, {:closed, :eof}}, 2_000
  end

  test "Headless turns the summary into the exit code" do
    alias SwarmCodeCLI.Release.Headless
    assert Headless.plain_exit(:eof, %{refused: 0, denied: 0}, false) == 0
    assert Headless.plain_exit(:eof, %{refused: 1, denied: 0}, false) == 1
    assert Headless.plain_exit(:eof, %{refused: 0, denied: 2}, false) == 0
    assert Headless.plain_exit(:eof, %{refused: 0, denied: 2}, true) == 1
  end
end
