defmodule SwarmCodeCLI.UI.Fixtures do
  @moduledoc """
  Synthetic, fixed visual evidence. No Source, daemon, filesystem, credentials,
  providers or domain execution is involved. Consensus and research text shows
  representative layout only, not functional orchestration or research.
  """
  alias SwarmCodeCLI.UI.{Capabilities, Draft, Drafts, Editor, ReadModel, Size, State}
  alias SwarmCodeCLI.UI.DataSource.DTO

  @spec representative(:chat | :swarm | :consensus | :research, Size.t(), Capabilities.t()) ::
          State.t()
  def representative(kind, %Size{} = size, %Capabilities{} = capabilities)
      when kind in [:chat, :swarm, :consensus, :research] do
    capabilities = %{capabilities | size: size}

    run = %DTO.RunSummary{
      id: "fixture-run",
      conversation_id: "fixture-conversation",
      kind: kind,
      title: title(kind),
      revision: 4,
      state: :streaming,
      allowed_actions: [:pause, :stop, :send],
      progress: 42
    }

    user =
      item("001", run, :user, :done, "Review this synthetic project and explain the next step.")

    assistant = item("002", run, :assistant, :streaming, prose(kind))

    extra =
      case kind do
        :consensus ->
          [
            item("003", run, :tool, :done, "Docket 01 · 3 proposals / 2 reviews / judge pending"),
            item(
              "004",
              run,
              :tool,
              :done,
              "Ledger: proposal A retained · B revised · C withdrawn (static)"
            )
          ]

        :research ->
          [
            item(
              "003",
              run,
              :tool,
              :done,
              "Research: Ultra (4x10) · Static representative evidence"
            ),
            item(
              "004",
              run,
              :tool,
              :done,
              "[1] Synthetic source · [2] Fixture notes · evidence awaiting review"
            )
          ]

        _ ->
          []
      end

    agents =
      if kind == :swarm,
        do:
          for(
            i <- 1..5,
            do: %DTO.AgentSummary{
              id: "agent-#{i}",
              run_id: run.id,
              revision: i,
              state: if(i == 5, do: :waiting_question, else: :running),
              allowed_actions: [:stop_agent]
            }
          ),
        else: []

    transcript = [user, assistant] ++ extra

    model = %ReadModel{
      runs: %{run.id => run},
      transcript: Map.new(transcript, &{&1.id, &1}),
      agents: Map.new(agents, &{&1.id, &1}),
      order: %{shell: [run.id], workspace: Enum.map(transcript, & &1.id)}
    }

    editor = Editor.new(ambiguous_width: capabilities.ambiguous_width)
    draft = Draft.new({run.conversation_id, :main}, editor)
    drafts = Drafts.new(ambiguous_width: capabilities.ambiguous_width) |> Drafts.put(draft)

    %State{
      size: size,
      capabilities: capabilities,
      source_epoch: "fixture-epoch",
      destination: {:run, run.id},
      read_model: model,
      drafts: drafts,
      focus: "composer",
      revision: 1
    }
  end

  def catalogue(size, capabilities) do
    base = representative(:chat, size, capabilities)

    states = [
      :queued,
      :running,
      :streaming,
      :waiting_question,
      :waiting_approval,
      :paused,
      :retrying,
      :done,
      :failed,
      :stopped,
      :interrupted,
      :superseded
    ]

    Enum.map(states, fn status ->
      run = base.read_model.runs["fixture-run"]

      permissions =
        case status do
          :failed -> [:retry]
          :interrupted -> [:resume]
          :superseded -> []
          _ -> run.allowed_actions
        end

      put_in(base.read_model.runs[run.id], %{run | state: status, allowed_actions: permissions})
    end)
  end

  defp item(id, run, role, state, text),
    do: %DTO.TranscriptItem{
      id: id,
      run_id: run.id,
      conversation_id: run.conversation_id,
      node_id: "node-" <> id,
      revision: 1,
      role: role,
      state: state,
      text: text,
      attempt_id: "attempt-fixture"
    }

  @doc """
  Returns a representative state augmented with a ShellSnapshot containing
  non-zero counts and a connected Connection. The base representative/3 state
  is unchanged; this function only adds the :shell snapshot slot.
  """
  @spec representative_with_shell(
          :chat | :swarm | :consensus | :research,
          Size.t(),
          Capabilities.t()
        ) ::
          State.t()
  def representative_with_shell(kind, size, capabilities) do
    state = representative(kind, size, capabilities)

    shell = %DTO.ShellSnapshot{
      counts: %DTO.Counts{
        running: 2,
        waiting: 1,
        paused: 0,
        failed: 1,
        done: 3,
        unseen: 0
      },
      connection: %DTO.Connection{state: :connected, source_epoch: "fixture-epoch"}
    }

    put_in(state.read_model.snapshots[:shell], shell)
  end

  defp title(:chat), do: "Streaming conversation"
  defp title(:swarm), do: "Swarm · independent agent lanes"
  defp title(:consensus), do: "Consensus · docket and ledger"
  defp title(:research), do: "Research · report and sources"

  defp prose(:chat),
    do:
      "The workspace is ready. I am comparing the synthetic changes and explaining each decision as it arrives."

  defp prose(:swarm),
    do:
      "Five numbered lanes share a bounded view. Each agent keeps its own revisioned stop permission."

  defp prose(:consensus),
    do:
      "Static consensus evidence: proposals, reviews, and a judge decision remain distinguishable in the docket."

  defp prose(:research),
    do:
      "Static research report: evidence, sources, and open questions remain readable without claiming research execution."
end
