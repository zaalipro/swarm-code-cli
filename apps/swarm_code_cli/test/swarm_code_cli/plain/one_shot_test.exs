defmodule SwarmCodeCLI.Plain.OneShotTest do
  @moduledoc """
  Pass 70 E4: `swarmcode -p`. One prompt goes out the way the composer sends
  it, the answer streams to stdout, what needs a person is denied or stopped
  and said on stderr, and the exit code says how the run ended.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Plain.OneShot
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Delta, DTO, Request, Watch}

  @epoch "one-shot-epoch"
  @conversation "22222222-2222-4222-8222-222222222222"
  @run "33333333-3333-4333-8333-333333333333"
  @root "44444444-4444-4444-8444-444444444444"
  @message "55555555-5555-4555-8555-555555555555"
  @interaction "66666666-6666-4666-8666-666666666666"

  # Answers every call at once and tells the test what was asked.
  defmodule Source do
    use GenServer
    def start_link(test), do: GenServer.start_link(__MODULE__, test)
    @impl true
    def init(test), do: {:ok, test}

    @impl true
    def handle_call({:bind, owner, ref}, _, test) do
      send(test, {:bound, owner})
      {:reply, {:ok, ref}, test}
    end

    def handle_call(message, _, test) do
      send(test, {:source, message})
      {:reply, :ok, test}
    end
  end

  setup do
    source = start_supervised!({Source, self()})
    {:ok, output} = StringIO.open("")
    {:ok, error} = StringIO.open("")
    %{source: source, output: output, error: error}
  end

  defp start(context, options \\ []) do
    parent = self()

    task =
      Task.async(fn ->
        OneShot.run(
          [
            data_source: context.source,
            source_epoch: @epoch,
            conversation_id: @conversation,
            prompt: "list the notes",
            output: context.output,
            error: context.error,
            clock: fn -> 1_000 end
          ] ++ options
        )
        |> tap(&send(parent, {:code, &1}))
      end)

    assert_receive {:bound, owner}
    assert_receive {:source, {:watch, %Watch{slot: :shell} = shell}}
    assert_receive {:source, {:watch, %Watch{slot: :workspace} = workspace}}
    assert workspace.scope.id == @conversation

    session = %{task: task, owner: owner, workspace: workspace, sequence: 0}

    ready(owner, shell, %DTO.ShellSnapshot{
      counts: %DTO.Counts{},
      connection: %DTO.Connection{source_epoch: @epoch}
    })

    ready(owner, workspace, %DTO.WorkspaceSnapshot{
      conversation_id: @conversation,
      allowed_actions: [:send, :queue],
      transcript: %DTO.TranscriptWindow{},
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    })

    assert_receive {:source, {:request, :command, %Request{} = dispatch}}
    assert {:dispatch, :send, "list the notes", :main, []} = dispatch.kind
    Map.put(session, :dispatch, dispatch)
  end

  defp ready(owner, watch, body) do
    send(
      owner,
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

  defp respond(session, %Request{} = request, body) do
    body =
      if Map.has_key?(body, :request_id), do: %{body | request_id: request.request_id}, else: body

    send(
      session.owner,
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

    session
  end

  defp accept(session),
    do: respond(session, session.dispatch, %DTO.Outcome{status: :accepted, identifiers: [@run]})

  defp delta(session, %Delta{} = delta) do
    sequence = session.sequence + 1
    watch = session.workspace
    delta = %{delta | sequence: sequence, revision: sequence}

    send(
      session.owner,
      {:swarm_code_ui_data, @epoch,
       %Delivery{
         kind: :delta,
         watch_ref: watch.watch_ref,
         request_id: nil,
         scope: watch.scope,
         generation: watch.generation,
         revision: sequence,
         sequence: sequence,
         body: delta
       }}
    )

    %{session | sequence: sequence}
  end

  defp run(state, extra \\ []),
    do:
      struct!(
        %DTO.RunSummary{
          id: @run,
          conversation_id: @conversation,
          state: state,
          title: "list the notes",
          allowed_actions: [:stop]
        },
        extra
      )

  defp run_update(session, state, extra \\ []) do
    body = run(state, extra)
    body = %{body | revision: session.sequence + 1}

    delta(session, %Delta{
      kind: :run_update,
      entity_id: @run,
      run_id: @run,
      conversation_id: @conversation,
      body: body
    })
  end

  defp message(text, extra \\ []),
    do:
      struct!(
        %DTO.TranscriptItem{
          id: @message,
          run_id: @run,
          conversation_id: @conversation,
          node_id: @root,
          role: :assistant,
          kind: :text,
          text: text,
          attempt_id: "attempt-1"
        },
        extra
      )

  defp stream(session, text) do
    delta(session, %Delta{
      kind: :stream_append,
      entity_id: @message,
      run_id: @run,
      conversation_id: @conversation,
      channel: :text,
      attempt_id: "attempt-1",
      text: text
    })
  end

  defp upsert(session, %DTO.TranscriptItem{} = item) do
    item = %{item | revision: session.sequence + 1}

    delta(session, %Delta{
      kind: :node_upsert,
      entity_id: item.id,
      run_id: item.run_id,
      conversation_id: @conversation,
      body: item
    })
  end

  # The run ended: the one-shot reads the conversation once more and the
  # test answers with the final snapshot.
  defp complete(session, runs, items) do
    assert_receive {:source,
                    {:request, :query, %Request{kind: {:query, :workspace, _, _, _, _}} = query}}

    respond(session, query, %DTO.WorkspaceSnapshot{
      conversation_id: @conversation,
      allowed_actions: [:send, :queue],
      runs: runs,
      transcript: %DTO.TranscriptWindow{items: items},
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    })
  end

  defp code(session) do
    assert_receive {:code, code}, 2_000
    Task.await(session.task)
    code
  end

  defp text(device), do: device |> StringIO.contents() |> elem(1)

  test "streams the answer to stdout and exits 0 when the run is done", context do
    session =
      start(context)
      |> accept()
      |> run_update(:streaming)
      |> upsert(message(""))
      |> stream("Two notes:")
      |> stream(" a.md and b.md")
      |> run_update(:done)

    complete(session, [run(:done)], [message("Two notes: a.md and b.md")])

    assert code(session) == 0
    assert text(context.output) == "Two notes: a.md and b.md\n"
    assert text(context.error) == ""
  end

  test "an answer longer than its preview is finished from its detail", context do
    session = start(context) |> accept() |> run_update(:done)
    ref = %DTO.DetailRef{id: "detail-1", total_bytes: 19}
    complete(session, [run(:done)], [message("first part", detail_ref: ref)])

    assert_receive {:source,
                    {:request, :query, %Request{kind: {:query_detail, "detail-1", 10, _}} = page}}

    respond(session, page, %DTO.DetailWindow{
      detail_ref: ref,
      offset: 10,
      text: " the rest",
      next_offset: nil
    })

    assert code(session) == 0
    assert text(context.output) == "first part the rest\n"
  end

  test "an approval nobody can give is denied and said; the run goes on", context do
    approval = %DTO.PendingInteraction{
      id: @interaction,
      run_id: @run,
      node_id: @root,
      conversation_id: @conversation,
      kind: :approval,
      expected_revision: 3,
      allowed_actions: [:approve, :deny],
      approval: %DTO.Approval{
        tool: "run_command",
        command: "rm -rf build",
        arguments_preview: "{}"
      }
    }

    session =
      start(context)
      |> accept()
      |> run_update(:waiting_approval)
      |> delta(%Delta{
        kind: :interaction_upsert,
        entity_id: @interaction,
        run_id: @run,
        conversation_id: @conversation,
        body: approval
      })

    assert_receive {:source, {:request, :command, %Request{} = deny}}
    assert deny.kind == {:resolve_approval, @run, @root, @interaction, 3, :deny}
    respond(session, deny, %DTO.Outcome{status: :accepted})

    session = session |> run_update(:done)
    complete(session, [run(:done)], [])

    assert code(session) == 0
    assert text(context.error) =~ "swarmcode: denied run_command rm -rf build"
  end

  test "an approval the service will not deny stops the run, said once", context do
    approval = %DTO.PendingInteraction{
      id: @interaction,
      run_id: @run,
      node_id: @root,
      conversation_id: @conversation,
      kind: :approval,
      expected_revision: 1,
      allowed_actions: [:approve, :deny],
      approval: %DTO.Approval{
        tool: "run_command",
        arguments_preview: ~s({"command":"ls -la notes"})
      }
    }

    session =
      start(context)
      |> accept()
      |> run_update(:waiting_approval)
      |> delta(%Delta{
        kind: :interaction_upsert,
        entity_id: @interaction,
        run_id: @run,
        conversation_id: @conversation,
        body: approval
      })

    assert_receive {:source,
                    {:request, :command,
                     %Request{kind: {:resolve_approval, _, _, _, _, :deny}} = deny}}

    respond(session, deny, %DTO.Outcome{
      status: :rejected,
      error: SwarmCodeCLI.UI.DataSource.AdmissionError.new(:not_allowed)
    })

    assert_receive {:source, {:request, :command, %Request{kind: {:run_control, :stop, @run}}}}

    session =
      session
      |> upsert(message("\n\n_(stopped)_"))
      |> run_update(:stopped)

    complete(session, [run(:stopped)], [message("\n\n_(stopped)_")])

    assert code(session) == 1
    assert text(context.output) == "_(stopped)_\n"
    error = text(context.error)
    assert error =~ "swarmcode: denied run_command ls -la notes: nobody is here to approve it."
    assert error =~ "the approval could not be denied, so the run was stopped."
    assert length(String.split(error, "stopped")) == 2
  end

  test "a question stops the run, says why and exits 1", context do
    question = %DTO.PendingInteraction{
      id: @interaction,
      run_id: @run,
      node_id: @root,
      conversation_id: @conversation,
      kind: :question,
      expected_revision: 1,
      allowed_actions: [:answer_question],
      question: %DTO.Question{
        prompt: "Which folder?",
        options: [%DTO.QuestionOption{id: "notes", label: "notes/"}]
      }
    }

    session =
      start(context)
      |> accept()
      |> run_update(:waiting_question)
      |> delta(%Delta{
        kind: :interaction_upsert,
        entity_id: @interaction,
        run_id: @run,
        conversation_id: @conversation,
        body: question
      })

    assert_receive {:source, {:request, :command, %Request{kind: {:run_control, :stop, @run}}}}
    session = run_update(session, :stopped)
    complete(session, [run(:stopped)], [])

    assert code(session) == 1
    assert text(context.error) =~ ~s(the run asked "Which folder?")
    assert text(context.error) =~ "was stopped"
  end

  test "a failed run exits 1 with its error", context do
    session = start(context) |> accept() |> run_update(:failed, error: "provider said no")
    complete(session, [run(:failed, error: "provider said no")], [])

    assert code(session) == 1
    assert text(context.error) =~ "swarmcode: the run failed: provider said no"
  end

  test "a refused prompt exits 1 and says why", context do
    session = start(context)

    respond(session, session.dispatch, %DTO.Outcome{
      status: :rejected,
      error: SwarmCodeCLI.UI.DataSource.AdmissionError.new(:not_allowed)
    })

    assert code(session) == 1
    assert text(context.error) =~ "the prompt was not sent: request is not allowed."
  end

  test "--json prints one object at the end and nothing while streaming", context do
    session =
      start(context, format: :json)
      |> accept()
      |> upsert(message(""))
      |> stream("Hello")
      |> run_update(:done)

    complete(session, [run(:done)], [message("Hello")])
    assert code(session) == 0

    assert %{
             "conversation_id" => @conversation,
             "run_id" => @run,
             "state" => "done",
             "text" => "Hello",
             "exit_code" => 0,
             "denied" => []
           } = Jason.decode!(text(context.output))
  end

  test "control characters from the model never reach the terminal", context do
    session = start(context) |> accept() |> run_update(:done)
    complete(session, [run(:done)], [message("safe\e[2Jtext\r")])

    assert code(session) == 0
    assert text(context.output) == "safe[2Jtext\n"
  end
end
