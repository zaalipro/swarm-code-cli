defmodule SwarmCodeCLI.Demo.FiniteScript do
  @moduledoc "Fixed synthetic driver synchronized by serialized session deliveries and canonical barriers."
  use GenServer
  alias SwarmCodeCLI.Demo.FiniteInput
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Delta, DTO}
  alias SwarmCodeCLI.UI.DataSource.Fake.{Source, Script}
  @type step :: tuple()

  def steps(:complete) do
    [
      {:barrier, "a1-a2-b1-step-1"},
      {:navigate, :conversation, Script.id(:b), "go conversation " <> Script.id(:b)},
      {:barrier, "a1-b1-step-2"},
      {:navigate, :conversation, Script.id(:a), "go conversation " <> Script.id(:a)},
      {:command, :answer, "answer " <> Script.id(:q1) <> "@7 option-2"},
      {:barrier, "catalogue-retry"},
      {:barrier, "catalogue-agent-stop"},
      {:command, :retry, "retry " <> Script.id(:failed_retry) <> "@41"},
      {:navigate, :run, Script.id(:a1), "inspect " <> Script.id(:a1) <> " agents"},
      {:command, :stop_agent,
       "stop-agent " <> Script.id(:a1) <> " " <> Script.id(:agent_stop) <> "@51"},
      {:navigate, :conversation, Script.id(:a), "back"},
      {:detach, "detach"}
    ]
  end

  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  def event(server, event), do: GenServer.cast(server, {:event, event})

  @impl true
  def init(options) do
    {:ok,
     %{
       source: Keyword.fetch!(options, :source),
       input: Keyword.fetch!(options, :input),
       coordinator: Keyword.fetch!(options, :coordinator),
       correlation: Keyword.fetch!(options, :correlation),
       remaining: steps(:complete),
       waiting: :ready,
       before: nil,
       command: nil,
       request_id: nil,
       accepted?: false,
       counted?: false,
       invariants: [],
       phase: :running
     }}
  end

  @impl true
  def handle_cast({:event, event}, state) do
    try do
      {:noreply, accept(state, event)}
    rescue
      _ -> {:noreply, failed(state)}
    catch
      _, _ -> {:noreply, failed(state)}
    end
  end

  defp accept(%{phase: :complete} = state, _), do: state
  defp accept(%{phase: :failed} = state, _), do: state
  defp accept(%{waiting: :ready} = state, :ready), do: advance(state)

  defp accept(
         %{waiting: {:watch, kind, id}} = state,
         {:delivery, %Delivery{kind: :watch_ready, scope: %{kind: kind, id: id}}}
       ),
       do: advance(state)

  defp accept(
         %{waiting: {:counts, revision}} = state,
         {:delivery,
          %Delivery{kind: :delta, body: %Delta{kind: :counts_update, revision: revision}}}
       ),
       do: advance(state)

  defp accept(%{waiting: :command, request_id: nil} = state, {:command, request}),
    do: %{state | request_id: request.request_id}

  defp accept(
         %{waiting: :command, request_id: id} = state,
         {:delivery,
          %Delivery{kind: :response, request_id: id, body: %DTO.Outcome{status: :accepted}}}
       ),
       do: settle(%{state | accepted?: true})

  defp accept(
         %{waiting: :command} = state,
         {:delivery,
          %Delivery{kind: :delta, body: %Delta{kind: :counts_update, revision: revision}}}
       ) do
    if revision == state.before.revision + 1, do: settle(%{state | counted?: true}), else: state
  end

  defp accept(%{waiting: :detach} = state, {:closed, :detach}) do
    true = Source.snapshot(state.source) == state.before
    :ok = FiniteInput.eof(state.input)
    invariants = state.invariants ++ [:detach_preserved]
    send(state.coordinator, {:finite_script, state.correlation, self(), {:complete, invariants}})
    %{state | phase: :complete, invariants: invariants}
  end

  defp accept(state, {:closed, _}), do: failed(state)
  defp accept(state, {:delivery, %Delivery{kind: :error}}), do: failed(state)

  defp accept(state, {:delivery, %Delivery{body: %DTO.Outcome{status: status}}})
       when status != :accepted,
       do: failed(state)

  defp accept(state, _), do: state

  defp advance(%{remaining: [step | rest]} = state) do
    state = %{state | remaining: rest}

    case step do
      {:barrier, name} ->
        :ok = Source.advance(state.source, name)
        revision = Source.snapshot(state.source).revision
        %{state | waiting: {:counts, revision}}

      {:navigate, kind, id, line} ->
        :ok = FiniteInput.release_line(state.input, line <> "\n")
        %{state | waiting: {:watch, kind, id}}

      {:command, kind, line} ->
        before = Source.snapshot(state.source)
        :ok = FiniteInput.release_line(state.input, line <> "\n")

        %{
          state
          | waiting: :command,
            command: kind,
            before: before,
            request_id: nil,
            accepted?: false,
            counted?: false
        }

      {:detach, line} ->
        before = Source.snapshot(state.source)
        :ok = FiniteInput.release_line(state.input, line <> "\n")
        %{state | waiting: :detach, before: before}
    end
  end

  defp settle(%{accepted?: true, counted?: true} = state) do
    after_state = Source.snapshot(state.source)
    invariant = invariant!(state.command, state.before, after_state)
    advance(%{state | invariants: state.invariants ++ [invariant]})
  end

  defp settle(state), do: state

  defp invariant!(:answer, before, after_state) do
    run = Script.id(:a2)
    true = Map.delete(before.runs, run) == Map.delete(after_state.runs, run)
    true = before.agents == after_state.agents
    true = before.transcript == after_state.transcript
    true = after_state.interactions[Script.id(:q1)].state == :resolved
    true = after_state.runs[run].state == :running
    :answer_isolated
  end

  defp invariant!(:retry, before, after_state) do
    run = Script.id(:failed_retry)
    true = Map.delete(before.runs, run) == Map.delete(after_state.runs, run)
    true = before.agents == after_state.agents
    true = before.transcript == after_state.transcript
    true = after_state.runs[run].state == :retrying
    true = after_state.runs[run].revision == 42
    :retry_isolated
  end

  defp invariant!(:stop_agent, before, after_state) do
    agent = Script.id(:agent_stop)
    true = before.runs == after_state.runs
    true = Map.delete(before.agents, agent) == Map.delete(after_state.agents, agent)
    true = before.transcript == after_state.transcript
    true = after_state.agents[agent].state == :stopped
    true = after_state.agents[agent].revision == 52
    :agent_stop_isolated
  end

  defp failed(state) do
    send(state.coordinator, {:finite_script, state.correlation, self(), :failed})
    %{state | phase: :failed}
  end

  @impl true
  def format_status(status),
    do: %{
      status
      | state: %{phase: status.state.phase},
        message: :redacted,
        reason: :redacted,
        log: []
    }
end
