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

  @doc """
  cli020 E31: the locked fixture of the Markdown row cache's bench and its
  golden test: the chat fixture with `n` (200) messages, user and assistant
  in turn, every assistant answer Markdown with a heading, a list, a code
  block, a table and a quote. Deterministic: the same text for the same `n`.
  """
  @spec long_conversation(Size.t(), Capabilities.t(), pos_integer()) :: State.t()
  def long_conversation(%Size{} = size, %Capabilities{} = capabilities, n \\ 200)
      when is_integer(n) and n > 0 do
    state = representative(:chat, size, capabilities)
    run = %{Map.fetch!(state.read_model.runs, "fixture-run") | state: :done}

    items =
      for i <- 1..n do
        id = "m" <> String.pad_leading(Integer.to_string(i), 3, "0")
        at = @clock_ms - (n - i + 1) * 30_000

        if rem(i, 2) == 1,
          do:
            item(id, run, :user, :done, "Question #{div(i + 1, 2)}: how does step #{i} work?",
              at: at
            ),
          else:
            item(id, run, :assistant, :done, long_answer(i),
              at: at,
              tokens_in: 900,
              tokens_out: 240
            )
      end

    model = %{
      state.read_model
      | runs: %{run.id => run},
        transcript: Map.new(items, &{&1.id, &1}),
        order: %{state.read_model.order | workspace: Enum.map(items, & &1.id)}
    }

    %{state | read_model: model}
  end

  defp long_answer(i) do
    """
    ## Step #{i}: the router

    The request reaches **`Router.call/2`** first; step #{i} adds a *plug* and a check.

    - read `lib/app/router_#{i}.ex` and its tests
    - add the `:browser` pipeline once, not twice
    - [ ] run `mix test test/app/router_#{i}_test.exs`

    ```elixir
    defmodule App.Router#{i} do
      use Phoenix.Router
      pipeline :browser, do: plug(:accepts, ["html"])
      get "/step/#{i}", PageController, :show
    end
    ```

    | file | lines | change |
    | --- | ---: | --- |
    | router_#{i}.ex | #{10 + i} | +#{rem(i, 7) + 1} −#{rem(i, 3)} |
    | page_#{i}.ex | #{20 + i} | +1 |

    > Note: nothing is written until you approve step #{i}.
    """
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

    # The third field is the agent's task. Its node title is its slug, the
    # daemon's default when the Lead gives no AI title (pass 75: a title
    # that differs from the slug is drawn as the agent's name).
    for {{name, role, _task, step, progress, tokens_in, tokens_out, stat}, i} <-
          Enum.with_index(lanes, 1) do
      %DTO.AgentSummary{
        id: "agent-#{i}",
        run_id: run.id,
        revision: i,
        state: if(i == 5, do: :waiting_question, else: :running),
        allowed_actions: [:stop_agent],
        name: name,
        role: role,
        title: name,
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

  # ------------------------------------------------------------------ Home
  #
  # orbit: the designer's mock for Home (D.html, gen_D.py), as service data. The
  # clock is `@clock_ms`, so the ages are the frame's: 2 min, 6 min, 52 min, 3 h...

  @home_project "0b6f5b3e-1c2d-4e5f-8a9b-0c1d2e3f4a5b"
  @home_projects [
    {"0b6f5b3e-1c2d-4e5f-8a9b-0c1d2e3f4a5b", "swarm-code-cli", "/Users/dev/dev/swarm-code-cli"},
    {"5e3a8c11-2f4d-4b6a-9c7e-1d2f3a4b5c6d", "swarm-code", "/Users/dev/dev/swarm-code"},
    {"7c1e9a2b-0000-4000-8000-000000000003", "llmotions", "/Users/dev/dev/llmotions"},
    {"a1090000-0000-4000-8000-0000000000a1", "ailogic", "/Users/dev/dev/ailogic"}
  ]

  # {title, minutes since it moved, state, runs, minutes since it began, last prompt}
  @home_cli [
    {"rate-limit chip wiring", 2, :wait, 4, 4320,
     "wire the rate-limit chip into the status row and the side-panel strip"},
    {"MCP fixture isolation", 6, :live, 7, 2900,
     "isolate the MCP fixtures per test so the stdio servers stop leaking"},
    {"paste width regression", 52, :idle, 3, 1500, "why does a pasted wide line break the box"},
    {"reaper ownership for kill_async", 180, :unread, 5, 3000,
     "who should own the reaper that kills the async tree"},
    {"workflow host file reads", 300, :idle, 2, 2000, "route host file reads through the guard"},
    {"dashboard launch brief", 1560, :idle, 1, 1700, "brief the dashboard launch screen"},
    {"settings strata hues", 2880, :idle, 6, 9000, "tune the strata hues of the settings rail"},
    {"history search ranking", 5760, :idle, 2, 7000, "rank history search by recency"},
    {"side panel lane colours", 8640, :idle, 9, 12_000, "give each lane its own colour"}
  ]
  @home_desk [
    {"pass 76 review notes", 40},
    {"ego lite smoke", 190},
    {"tray menu order", 1500},
    {"storage cleanup", 3000},
    {"themes backfill", 7000},
    {"icon picker", 17_000}
  ]
  @home_llm [
    {"competitor pricing scan", 12, :live, 2, 14,
     "scan five competitors' pricing pages and chart their tiers against ours"},
    {"landing hero copy", 3100, :idle, 4, 6000, "rewrite the landing hero"},
    {"pricing table refactor", 13_000, :idle, 1, 13_100, "split the pricing table"}
  ]
  @home_ail [{"fake provider script", 13_500}, {"seed data reset", 29_000}]

  defp home_conversation_id(project, n) do
    prefix = project |> String.slice(0, 8)
    prefix <> "-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")
  end

  @doc """
  Home's overview as the designer's mock (D-main-dark): four projects, three live
  runs, $38.40 of $60 this month, one approval waiting and a scheduled task.
  `now` is unix milliseconds (the fake source's clock by default).
  """
  @spec home_overview(integer()) :: DTO.HomeOverview.t()
  def home_overview(now \\ @clock_ms) do
    ago = &(now - &1 * 60_000)
    {cli_id, cli_name, cli_root} = Enum.at(@home_projects, 0)

    cli_conversations =
      for {{title, m, state, _runs, _born, _lp}, n} <- Enum.with_index(@home_cli, 1) do
        %DTO.HomeConversation{
          id: home_conversation_id(cli_id, n),
          title: title,
          updated_at: ago.(m),
          live: state == :live,
          live_kind: if(state == :live, do: :swarm),
          waiting: if(state == :wait, do: 1, else: 0),
          unread: state == :unread
        }
      end

    plain = fn {id, _name, _root}, rows ->
      for {{title, m}, n} <- Enum.with_index(rows, 1) do
        %DTO.HomeConversation{id: home_conversation_id(id, n), title: title, updated_at: ago.(m)}
      end
    end

    llm = Enum.at(@home_projects, 2)

    llm_conversations =
      for {{title, m, state, _runs, _born, _lp}, n} <- Enum.with_index(@home_llm, 1) do
        %DTO.HomeConversation{
          id: home_conversation_id(elem(llm, 0), n),
          title: title,
          updated_at: ago.(m),
          live: state == :live,
          live_kind: if(state == :live, do: :research)
        }
      end

    project = fn {id, name, root} = entry, conversations, live, current? ->
      _ = entry

      %DTO.HomeProject{
        id: id,
        name: name,
        root_path: root,
        current: current?,
        last_opened_at: if(current?, do: now),
        conversation_count: length(conversations),
        live: live,
        waiting: if(current?, do: 1, else: 0),
        conversations: conversations
      }
    end

    desk = Enum.at(@home_projects, 1)
    ail = Enum.at(@home_projects, 3)

    %DTO.HomeOverview{
      request_id: nil,
      state: :ready,
      revision: 3,
      project_id: cli_id,
      projects: [
        project.({cli_id, cli_name, cli_root}, cli_conversations, 1, true),
        project.(desk, plain.(desk, @home_desk), 0, false),
        project.(llm, llm_conversations, 1, false),
        project.(ail, plain.(ail, @home_ail), 0, false)
      ],
      live_runs: [
        %DTO.HomeRun{
          id: "9d000000-0000-4000-8000-000000000001",
          project_id: cli_id,
          conversation_id: home_conversation_id(cli_id, 2),
          kind: :swarm,
          progress: 60,
          started_at: ago.(2900)
        },
        %DTO.HomeRun{
          id: "9d000000-0000-4000-8000-000000000002",
          project_id: elem(llm, 0),
          conversation_id: home_conversation_id(elem(llm, 0), 1),
          kind: :research,
          progress: 25,
          started_at: ago.(14)
        },
        %DTO.HomeRun{
          id: "9d000000-0000-4000-8000-000000000003",
          project_id: cli_id,
          conversation_id: home_conversation_id(cli_id, 1),
          kind: :chat,
          progress: nil,
          started_at: ago.(4320)
        }
      ],
      live_overflow: 0,
      waiting_total: 1,
      month: %DTO.HomeMonth{spend_usd: 38.4, budget_usd: 60.0},
      next_scheduled: %DTO.HomeScheduled{
        id: "5c000000-0000-4000-8000-000000000001",
        name: "nightly deps audit",
        project_id: cli_id,
        project_name: cli_name,
        next_run_at: now + 14 * 60_000
      }
    }
  end

  @doc """
  The conversation list of the mock's own project, as the resume list shows it
  (`conversation.list`): nine rows, the first current, newest first.
  """
  @spec home_list(integer()) :: DTO.ConversationList.t()
  def home_list(now \\ @clock_ms) do
    items =
      for {{title, m, state, runs, born, lp}, n} <- Enum.with_index(@home_cli, 1) do
        %DTO.ConversationSummary{
          id: home_conversation_id(@home_project, n),
          title: title,
          created_at: now - born * 60_000,
          updated_at: now - m * 60_000,
          run_count: runs,
          live: state == :live,
          waiting: if(state == :wait, do: 1, else: 0),
          unread: state == :unread,
          current: n == 1,
          last_prompt: lp
        }
      end

    %DTO.ConversationList{
      project: "swarm-code-cli",
      current_id: home_conversation_id(@home_project, 1),
      items: items,
      request_id: nil,
      presence: :covered,
      covered_ids: Enum.map(items, & &1.id),
      through_sequence: 0
    }
  end

  @doc """
  A state with Home open as the designer's mock: the nine conversations of
  swarm-code-cli underneath, the overview loaded, `auto` approvals, opus 5.5 at
  xhigh, branch main with 3 changed files. `opts`: `home:` fields to set on the
  `%Home{}`, `overview:` (a `%HomeOverview{}` or nil), `list:` (a
  `%ConversationList{}` or nil), `workspace:` fields for the workspace snapshot.
  """
  @spec home_state(Size.t(), Capabilities.t(), keyword()) :: State.t()
  def home_state(%Size{} = size, %Capabilities{} = capabilities, opts \\ []) do
    capabilities = %{capabilities | size: size}
    overview = Keyword.get(opts, :overview, home_overview())
    list = Keyword.get(opts, :list, home_list())
    conversation = home_conversation_id(@home_project, 1)

    workspace =
      struct!(
        %DTO.WorkspaceSnapshot{},
        Keyword.merge(
          [
            project: "swarm-code-cli",
            approval_mode: :auto,
            trusted: true,
            chat_model: "opus 5.5",
            effort: "xhigh",
            effort_effective: "xhigh",
            git_branch: "main",
            git_dirty: 3
          ],
          Keyword.get(opts, :workspace, [])
        )
      )

    editor = Editor.new(ambiguous_width: capabilities.ambiguous_width)

    drafts =
      Drafts.new(ambiguous_width: capabilities.ambiguous_width)
      |> Drafts.put(Draft.new({conversation, :main}, editor))
      |> Drafts.put(Draft.new({"fixture-epoch", :home}, editor))

    home =
      struct!(
        %SwarmCodeCLI.UI.Home{generation: 1, overview: overview},
        Keyword.get(opts, :home, [])
      )

    %State{
      size: size,
      capabilities: capabilities,
      source_epoch: "fixture-epoch",
      destination: {:conversation, conversation},
      read_model: %ReadModel{
        snapshots: %{
          workspace: workspace,
          shell: %DTO.ShellSnapshot{
            rate_limits: [
              %DTO.RateLimit{
                provider_id: "a0000000-0000-4000-8000-000000000001",
                provider: "Anthropic",
                scope: "5 h window",
                used_percent: 41.0
              },
              %DTO.RateLimit{
                provider_id: "a0000000-0000-4000-8000-000000000002",
                provider: "OpenAI",
                scope: "daily",
                used_percent: 12.0
              }
            ]
          }
        }
      },
      drafts: drafts,
      focus: "composer",
      revision: 1,
      now: @clock_ms,
      home: home,
      conversations: list,
      launch_facts: %{
        cli_version: "0.2.2",
        project_root: "/Users/dev/dev/swarm-code-cli",
        home: "/Users/dev"
      }
    }
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
