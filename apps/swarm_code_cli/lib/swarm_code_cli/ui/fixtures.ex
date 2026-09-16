defmodule SwarmCodeCLI.UI.Fixtures do
  @moduledoc """
  Synthetic, fixed visual evidence. No Source, daemon, filesystem, credentials,
  providers or domain execution is involved. Consensus and research text shows
  representative layout only, not functional orchestration or research.
  """
  alias SwarmCodeCLI.UI.{Capabilities, Draft, Drafts, Editor, ReadModel, Size, State}
  alias SwarmCodeCLI.UI.DataSource.DTO

  # 2026-09-03T12:00:00Z, the fake source's clock; items sit a few minutes before it.
  @clock_ms 1_788_436_800_000

  @spec representative(:chat | :swarm | :consensus | :research, Size.t(), Capabilities.t()) ::
          State.t()
  def representative(kind, %Size{} = size, %Capabilities{} = capabilities)
      when kind in [:chat, :swarm, :consensus, :research] do
    capabilities = %{capabilities | size: size}

    run =
      struct!(
        %DTO.RunSummary{
          id: "fixture-run",
          conversation_id: "fixture-conversation",
          kind: kind,
          title: title(kind),
          revision: 4,
          state: :streaming,
          allowed_actions: [:pause, :stop, :send],
          progress: 42,
          started_at: @clock_ms - 300_000,
          consensus: kind == :consensus
        },
        run_facts(kind)
      )

    user =
      item("001", run, :user, :done, "Review this synthetic project and explain the next step.",
        at: @clock_ms - 240_000
      )

    # On the swarm scene the lead's streaming summary is the newest turn: the
    # tool calls, thought and error that fed it come first in the transcript.
    assistant =
      item("002", run, :assistant, :streaming, prose(kind),
        agent_id: if(kind == :swarm, do: "agent-1", else: nil),
        at: if(kind == :swarm, do: @clock_ms - 120_000, else: @clock_ms - 200_000),
        tokens_in: 2_410,
        tokens_out: 188
      )

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

    agents = if kind == :swarm, do: hive_agents(run), else: []
    changes = if kind == :swarm, do: hive_changes(run), else: []
    verdicts = if kind == :consensus, do: [verdict(run)], else: []
    before = if kind == :swarm, do: hive_items(run), else: []
    transcript = [user] ++ before ++ [assistant] ++ extra

    model = %ReadModel{
      runs: %{run.id => run},
      transcript: Map.new(transcript, &{&1.id, &1}),
      agents: Map.new(agents, &{&1.id, &1}),
      changes: Map.new(changes, &{&1.id, &1}),
      verdicts: Map.new(verdicts, &{&1.id, &1}),
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

  defp item(id, run, role, state, text, extra \\ []),
    do:
      struct!(
        %DTO.TranscriptItem{
          id: id,
          run_id: run.id,
          conversation_id: run.conversation_id,
          node_id: "node-" <> id,
          revision: 1,
          role: role,
          state: state,
          text: text,
          at: @clock_ms - 180_000,
          attempt_id: "attempt-fixture"
        },
        extra
      )

  defp run_facts(:chat),
    do: [tokens_in: 3_420, tokens_out: 612, cost_usd: 0.021, model: "deepseek-v4-pro"]

  defp run_facts(:swarm),
    do: [
      tokens_in: 18_640,
      tokens_out: 4_210,
      cost_usd: 0.184,
      model: "kimi-k2-thinking",
      agents_total: 5,
      agents_running: 4,
      needs: 1,
      changes: 3
    ]

  defp run_facts(:consensus),
    do: [
      tokens_in: 24_900,
      tokens_out: 6_030,
      cost_usd: 0.247,
      model: "kimi-k2-thinking",
      agents_total: 3,
      agents_running: 0
    ]

  defp run_facts(:research),
    do: [tokens_in: 7_880, tokens_out: 1_030, cost_usd: 0.062, model: "deepseek-v4-pro"]

  # Tool one-liners, a thought and an error for the swarm scene, after the
  # streaming assistant turn so every transcript item kind has evidence.
  defp hive_items(run) do
    [
      item("005", run, :tool, :done, "lib/swarm_code/repo.ex:12\nlib/swarm_code/repo.ex:48",
        kind: :tool,
        agent_id: "agent-2",
        at: @clock_ms - 170_000,
        tokens_in: 812,
        tokens_out: 64,
        tool: %DTO.ToolCall{
          name: "grep",
          title: "grep \"Repo\\.\"",
          detail: "lib/ test/ · 41 hits",
          status: :done,
          started_at: @clock_ms - 170_000,
          finished_at: @clock_ms - 169_600,
          duration_ms: 400,
          result_bytes: 3_812,
          files: []
        }
      ),
      item("006", run, :tool, :done, "defmodule SwarmCode.SessionTest do",
        kind: :tool,
        agent_id: "agent-3",
        at: @clock_ms - 160_000,
        tokens_in: 1_790,
        tokens_out: 51,
        tool: %DTO.ToolCall{
          name: "read_file",
          title: "read test/session_test.exs",
          detail: "218 lines",
          status: :done,
          started_at: @clock_ms - 160_000,
          finished_at: @clock_ms - 159_880,
          duration_ms: 120,
          result_bytes: 7_144,
          files: ["test/session_test.exs"]
        }
      ),
      item("007", run, :assistant, :done, "",
        kind: :thinking,
        agent_id: "agent-1",
        at: @clock_ms - 150_000,
        tokens_in: 2_240,
        tokens_out: 210,
        reasoning:
          "The refresh path and the session tests disagree about expiry; builder-4 should change the repository before the tests."
      ),
      item("008", run, :tool, :running, "",
        kind: :tool,
        agent_id: "agent-4",
        at: @clock_ms - 140_000,
        tokens_in: 3_020,
        tokens_out: 388,
        tool: %DTO.ToolCall{
          name: "edit_file",
          title: "edit lib/swarm_code/repo.ex",
          detail: "+42 −7",
          status: :running,
          started_at: @clock_ms - 140_000,
          finished_at: nil,
          duration_ms: nil,
          result_bytes: 0,
          files: ["lib/swarm_code/repo.ex"]
        }
      ),
      item(
        "009",
        run,
        :system,
        :failed,
        "run_command failed: mix test exited with status 1 (2 failures).",
        kind: :error,
        agent_id: "agent-4",
        at: @clock_ms - 130_000
      )
    ]
  end

  defp hive_agents(run) do
    lanes = [
      {"lead", :lead, "Coordinate the authentication review", "planning", 35, 6_120, 1_480, nil},
      {"scout-1", :sub, "Map the auth call sites", "grep \"Repo\\.\"", 70, 3_210, 640, nil},
      {"scout-2", :sub, "Read the session tests", "read test/session_test.exs", 55, 2_980, 512,
       nil},
      {"builder-4", :worker, "Harden the token refresh path", "edit lib/swarm_code/repo.ex", 40,
       5_340, 1_320, "+42 −7"},
      {"judge", :judge, "Judge · round 1", "waiting for you", 0, 990, 258, nil}
    ]

    for {{name, role, title, step, progress, tokens_in, tokens_out, stat}, i} <-
          Enum.with_index(lanes, 1) do
      %DTO.AgentSummary{
        id: "agent-#{i}",
        run_id: run.id,
        revision: i,
        state: if(i == 5, do: :waiting_question, else: :running),
        allowed_actions: [:stop_agent],
        name: name,
        role: role,
        title: title,
        step: step,
        progress: progress,
        tokens_in: tokens_in,
        tokens_out: tokens_out,
        cost_usd: Float.round((tokens_in + tokens_out * 4) / 100_000, 3),
        started_at: @clock_ms - 290_000 + i * 5_000,
        parent_id: if(i == 1, do: nil, else: "agent-1"),
        depth: if(i == 1, do: 0, else: 1),
        changes_stat: stat
      }
    end
  end

  defp hive_changes(run) do
    [
      {"change-1", "agent-4", "lib/swarm_code/repo.ex", true, 145_000},
      {"change-2", "agent-4", "test/swarm_code/repo_test.exs", true, 135_000},
      {"change-3", "agent-1", "docs/architecture.md", false, 125_000}
    ]
    |> Enum.map(fn {id, agent, path, restorable, ago} ->
      %DTO.Change{
        id: id,
        run_id: run.id,
        agent_id: agent,
        path: path,
        restorable: restorable,
        at: @clock_ms - ago,
        revision: 1
      }
    end)
  end

  defp verdict(run) do
    %DTO.Verdict{
      id: "judge-1",
      run_id: run.id,
      round: 1,
      status: :done,
      checks: [
        %DTO.VerdictCheck{key: "tests_pass", ok: true, note: "142 tests, 0 failures"},
        %DTO.VerdictCheck{key: "no_regressions", ok: true, note: "auth paths unchanged"},
        %DTO.VerdictCheck{key: "docs_updated", ok: false, note: "architecture.md still draft"},
        %DTO.VerdictCheck{key: "style", ok: nil, note: "not evaluated"}
      ],
      summary: "Two of three proposals meet the bar; the docs change needs another pass.",
      revision: 1
    }
  end

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
