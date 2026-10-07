defmodule SwarmCodeCLI.Test.OneShotHarness do
  @moduledoc """
  cli020 lane B: drives `Plain.OneShot` against a source that answers every
  call at once and tells the test what was asked (the helpers of
  `plain/one_shot_test.exs`, shared by the lane's new one-shot tests).
  """
  import ExUnit.Assertions

  alias SwarmCodeCLI.Plain.OneShot
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Delta, DTO, Request, Watch}

  @epoch "one-shot-epoch"
  @conversation "22222222-2222-4222-8222-222222222222"
  @run "33333333-3333-4333-8333-333333333333"
  @root "44444444-4444-4444-8444-444444444444"
  @message "55555555-5555-4555-8555-555555555555"

  def epoch, do: @epoch
  def conversation, do: @conversation
  def run_id, do: @run
  def root, do: @root
  def message_id, do: @message

  defmodule Source do
    @moduledoc false
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

  @doc "Starts a one-shot and answers its two watches; returns the session map."
  def start(context, options \\ [], workspace_extra \\ []) do
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

    assert_receive {:bound, owner}, 5_000
    assert_receive {:source, {:watch, %Watch{slot: :shell} = shell}}, 5_000
    assert_receive {:source, {:watch, %Watch{slot: :workspace} = workspace}}, 5_000

    session = %{task: task, owner: owner, workspace: workspace, sequence: 0}

    ready(owner, shell, %DTO.ShellSnapshot{
      counts: %DTO.Counts{},
      connection: %DTO.Connection{source_epoch: @epoch}
    })

    ready(
      owner,
      workspace,
      struct!(
        %DTO.WorkspaceSnapshot{
          conversation_id: @conversation,
          allowed_actions: [:send, :queue],
          transcript: %DTO.TranscriptWindow{},
          runs_page: %DTO.PageInfo{},
          interactions_page: %DTO.PageInfo{}
        },
        workspace_extra
      )
    )

    assert_receive {:source, {:request, :command, %Request{} = dispatch}}, 5_000
    Map.put(session, :dispatch, dispatch)
  end

  def ready(owner, watch, body) do
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

  def respond(session, %Request{} = request, body) do
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

  def accept(session),
    do: respond(session, session.dispatch, %DTO.Outcome{status: :accepted, identifiers: [@run]})

  def delta(session, %Delta{} = delta) do
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

  def run(state, extra \\ []),
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

  def run_update(session, state, extra \\ []) do
    body = %{run(state, extra) | revision: session.sequence + 1}

    delta(session, %Delta{
      kind: :run_update,
      entity_id: @run,
      run_id: @run,
      conversation_id: @conversation,
      body: body
    })
  end

  def message(text, extra \\ []),
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

  def upsert(session, %DTO.TranscriptItem{} = item) do
    item = %{item | revision: session.sequence + 1}

    delta(session, %Delta{
      kind: :node_upsert,
      entity_id: item.id,
      run_id: item.run_id,
      conversation_id: @conversation,
      body: item
    })
  end

  def interaction(session, %DTO.PendingInteraction{} = item) do
    delta(session, %Delta{
      kind: :interaction_upsert,
      entity_id: item.id,
      run_id: item.run_id,
      conversation_id: @conversation,
      body: item
    })
  end

  @doc "Answers the one-shot's completion query with the final snapshot."
  def complete(session, runs, items) do
    assert_receive {:source,
                    {:request, :query, %Request{kind: {:query, :workspace, _, _, _, _}} = query}},
                   5_000

    respond(session, query, %DTO.WorkspaceSnapshot{
      conversation_id: @conversation,
      allowed_actions: [:send, :queue],
      runs: runs,
      transcript: %DTO.TranscriptWindow{items: items},
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    })
  end

  def code(session) do
    assert_receive {:code, code}, 5_000
    Task.await(session.task)
    code
  end

  def text(device), do: device |> StringIO.contents() |> elem(1)
end
