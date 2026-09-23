defmodule SwarmCodeCLI.Demo.Conversation do
  @moduledoc """
  Synthetic conversations shaped like what the persisted daemon sends: the
  assistant message is created before the model steps and the tool calls that
  feed it, every model step is a `:thinking` item whose text is what that step
  said, and the answer is the whole message. No source, daemon, filesystem or
  provider is involved; the text is invented for layout review and tests.

  Scenes:

    * `:first_reply` — one finished chat turn: a sentence, three tool calls, then a
      markdown answer with headings, a list, a table and an elixir code block.
    * `:approval` — the first turn plus a second one waiting on a shell command.
    * `:approval_edit` — the first turn plus a second one waiting on a file change
      long enough to grow the approval card into main.
    * `:swarm` — a lead with three workers, one waiting on a command.
    * `:long` — five runs, an 80-line reply and a 21-call run.
    * `:failed_workflow` — ten runs ending in a failed 14-agent workflow, the shape
      of the conversation that crashed the run palette.
    * `:empty` — a conversation with no runs yet.
  """
  alias SwarmCodeCLI.UI.{Capabilities, Draft, Drafts, Editor, ReadModel, Size, State}
  alias SwarmCodeCLI.UI.DataSource.DTO

  # 2026-09-03T12:00:00Z; every stamp below is an offset from it.
  @clock 1_788_436_800_000
  @conversation "demo-conversation"
  @model "deepseek-v4.1-flash"

  @type scene ::
          :first_reply | :approval | :approval_edit | :swarm | :long | :failed_workflow | :empty

  @spec clock() :: pos_integer()
  def clock, do: @clock

  @spec state(scene(), Size.t(), Capabilities.t()) :: State.t()
  def state(scene, %Size{} = size, %Capabilities{} = capabilities) do
    capabilities = %{capabilities | size: size}
    {runs, items, agents, interactions} = build(scene)

    order = items |> Enum.sort_by(&{&1.created_sequence, &1.id}) |> Enum.map(& &1.id)

    model = %ReadModel{
      runs: Map.new(runs, &{&1.id, &1}),
      transcript: Map.new(items, &{&1.id, &1}),
      agents: Map.new(agents, &{&1.id, &1}),
      interactions: Map.new(interactions, &{&1.id, &1}),
      order: %{
        shell: runs |> Enum.sort_by(& &1.created_sequence, :desc) |> Enum.map(& &1.id),
        workspace: order
      },
      snapshots: %{workspace: workspace(runs)}
    }

    editor = Editor.new(ambiguous_width: capabilities.ambiguous_width)
    draft = Draft.new({@conversation, :main}, editor)
    drafts = Drafts.new(ambiguous_width: capabilities.ambiguous_width) |> Drafts.put(draft)

    %State{
      size: size,
      capabilities: capabilities,
      source_epoch: "demo-epoch",
      destination: {:conversation, @conversation},
      read_model: model,
      drafts: drafts,
      focus: "composer",
      revision: 1,
      now: @clock
    }
  end

  defp workspace(runs) do
    %DTO.WorkspaceSnapshot{
      conversation_id: @conversation,
      project: "ailogic",
      mode: :build,
      chat_model: @model,
      swarm_model: @model,
      chat_provider: "llmotions",
      approval_mode: :auto,
      trusted: true,
      context_used: 19_400,
      context_window: 128_000,
      cost_usd: runs |> Enum.map(&(&1.cost_usd || 0)) |> Enum.sum(),
      allowed_actions: [:send, :queue, :mark_seen],
      runs: runs,
      models: [
        %DTO.ModelOption{provider_id: "p1", provider: "llmotions", model: @model},
        %DTO.ModelOption{provider_id: "p1", provider: "llmotions", model: "deepseek-v4-pro"},
        %DTO.ModelOption{provider_id: "p2", provider: "anthropic", model: "claude-opus-5"}
      ]
    }
  end

  # --- scenes -----------------------------------------------------------------

  defp build(:empty), do: {[], [], [], []}

  defp build(:first_reply) do
    {run, items} = first_reply(1, -600_000)
    {[run], items, [], []}
  end

  defp build(:approval) do
    {first, first_items} = first_reply(1, -600_000)
    {second, second_items, interaction} = waiting_turn(2, -60_000)
    {[first, second], first_items ++ second_items, [], [interaction]}
  end

  defp build(:approval_edit) do
    {first, first_items} = first_reply(1, -600_000)
    {second, second_items, interaction} = waiting_edit(2, -60_000)
    {[first, second], first_items ++ second_items, [], [interaction]}
  end

  defp build(:swarm) do
    {first, first_items} = first_reply(1, -900_000)
    {run, items, agents, interaction} = swarm(2, -120_000)
    {[first, run], first_items ++ items, agents, [interaction]}
  end

  defp build(:long) do
    {runs, items} =
      Enum.reduce(1..5, {[], []}, fn n, {runs, items} ->
        start = -3_600_000 + n * 600_000

        {run, run_items} =
          case rem(n, 3) do
            0 -> busy_turn(n, start, 21)
            1 -> long_reply(n, start, 80)
            _ -> first_reply(n, start)
          end

        {runs ++ [run], items ++ run_items}
      end)

    {runs, items, [], []}
  end

  defp build(:failed_workflow) do
    {runs, items} =
      Enum.reduce(1..9, {[], []}, fn n, {runs, items} ->
        start = -86_400_000 + n * 3_600_000

        {run, run_items} =
          if rem(n, 2) == 0, do: long_reply(n, start, 40), else: first_reply(n, start)

        {runs ++ [run], items ++ run_items}
      end)

    {workflow, workflow_items, agents} = failed_workflow(10, -3_000_000, 14)
    {runs ++ [workflow], items ++ workflow_items, agents, []}
  end

  # --- turns ------------------------------------------------------------------

  @first_prompt "Read mix.exs and list the files under lib/ then answer in markdown: a 3-item bullet list of the key deps, and one short elixir code block showing how the app starts. Be brief."

  @first_step "I'll read the requested files first."

  @first_answer """
  ## Dependencies

  1. **Phoenix 1.7** with `phoenix_live_view` for the web layer and realtime UI
  2. **Ecto SQL** over `postgrex`, with _Oban_ for background jobs
  3. **Finch** as the shared HTTP client, plus `cloak` for encrypted fields

  `lib/` holds two trees: `lib/ailogic/` (accounts, tickets, knowledge, automations) and `lib/ailogic_web/` (endpoint, router, live views).

  ## Startup

  ```elixir
  def start(_type, _args) do
    children = [
      Ailogic.Repo,
      {Phoenix.PubSub, name: Ailogic.PubSub},
      # Serve requests last, once the repo is up.
      AilogicWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Ailogic.Supervisor)
  end
  ```

  | Tree | Modules | Role |
  |---|---:|---|
  | `lib/ailogic/` | 84 | contexts and schemas |
  | `lib/ailogic_web/` | 37 | endpoint, router, live views |

  > The app boots the repo before the endpoint, so migrations must run first.
  """

  defp first_reply(n, start) do
    run = run(n, :chat, "Read mix.exs and list the files under lib/", :done, start, 17_400)
    user = user(run, 0, start, @first_prompt)

    answer =
      message(run, 1, start + 200, @first_step <> "\n\n" <> String.trim(@first_answer),
        tokens_in: 18_210,
        tokens_out: 940
      )

    items = [
      user,
      answer,
      step(run, 2, start + 400, @first_step, 2_100),
      tool(run, 3, start + 2_600, "read_file", "read mix.exs", "mix.exs (94 lines)", 6,
        files: ["mix.exs"],
        text: "defmodule Ailogic.MixProject do\n  use Mix.Project\n"
      ),
      tool(run, 4, start + 2_700, "list_dir", "list lib", "ailogic/ ailogic_web/ ailogic.ex", 14,
        files: ["lib"],
        text: "ailogic/\nailogic_web/\nailogic.ex\nailogic_web.ex\n"
      ),
      step(run, 5, start + 2_800, "", 1_400),
      tool(
        run,
        6,
        start + 4_300,
        "read_file",
        "read lib/ailogic/application.ex",
        "lib/ailogic/application.ex (64 lines)",
        3,
        files: ["lib/ailogic/application.ex"]
      )
    ]

    {run, items}
  end

  defp waiting_turn(n, start) do
    prompt =
      "Create notes/hello.md containing two short lines greeting the team, then run the shell command: ls -la notes"

    run =
      run(n, :chat, "Create notes/hello.md then list notes", :waiting_approval, start, nil,
        needs: 1,
        changes: 1
      )

    sentence = "I'll create the file, then list the directory."

    items = [
      user(run, 0, start, prompt),
      message(run, 1, start + 200, sentence, state: :waiting_approval),
      step(run, 2, start + 400, sentence, 1_800),
      tool(run, 3, start + 2_300, "write_file", "write notes/hello.md", "+2 lines", 21,
        files: ["notes/hello.md"]
      ),
      tool(run, 4, start + 2_500, "run_command", "run: ls -la notes", "awaiting approval", nil,
        status: :waiting_approval
      )
    ]

    interaction = %DTO.PendingInteraction{
      id: "demo-approval-#{n}",
      run_id: run.id,
      node_id: node_id(run, 4),
      conversation_id: @conversation,
      kind: :approval,
      expected_revision: 3,
      state: :pending,
      approval: %DTO.Approval{
        tool: "run_command",
        permission: :execute,
        arguments_preview: ~s({"command":"ls -la notes","workdir":"."}),
        command: "ls -la notes",
        cwd: ".",
        reason: "Show the new file beside the other notes",
        command_family: "ls",
        classification: :safe,
        agent_name: "assistant",
        allowed_decisions: [:approve, :approve_run, :always_prefix, :deny, :deny_stop]
      },
      allowed_actions: [:approve, :always_allow, :deny],
      urgency: :high,
      created_at: @clock + start + 2_500
    }

    {run, items, interaction}
  end

  # A turn waiting on a file change long enough to grow the card into main.
  defp waiting_edit(n, start) do
    prompt = "Rename the ticket guard to authorize/2 and keep the old name as a deprecated alias"

    run =
      run(n, :chat, "Rename the ticket guard", :waiting_approval, start, nil, needs: 1)

    sentence = "I'll rename the guard and keep a deprecated alias."

    items = [
      user(run, 0, start, prompt),
      message(run, 1, start + 200, sentence, state: :waiting_approval),
      step(run, 2, start + 400, sentence, 2_100),
      tool(run, 3, start + 2_600, "read_file", "read lib/tickets/guard.ex", "48 lines", 9,
        files: ["lib/tickets/guard.ex"]
      ),
      tool(
        run,
        4,
        start + 2_800,
        "edit_file",
        "edit lib/tickets/guard.ex",
        "awaiting approval",
        nil,
        status: :waiting_approval
      )
    ]

    old = "  def check(actor, ticket) do\n    Policy.allowed?(actor, :transition, ticket)\n  end"

    new =
      "  def authorize(actor, ticket) do\n    Policy.allowed?(actor, :transition, ticket)\n  end\n\n" <>
        "  @deprecated \"Use authorize/2\"\n  def check(actor, ticket), do: authorize(actor, ticket)"

    arguments =
      Jason.encode!(%{"path" => "lib/tickets/guard.ex", "old_string" => old, "new_string" => new})

    interaction = %DTO.PendingInteraction{
      id: "demo-approval-#{n}",
      run_id: run.id,
      node_id: node_id(run, 4),
      conversation_id: @conversation,
      kind: :approval,
      expected_revision: 2,
      state: :pending,
      approval: %DTO.Approval{
        tool: "edit_file",
        permission: :write,
        arguments_preview: arguments,
        reason: "Rename without breaking the two callers in lib/tickets",
        classification: :normal,
        agent_name: "assistant",
        allowed_decisions: [:approve, :approve_run, :deny, :deny_stop]
      },
      allowed_actions: [:approve, :deny],
      urgency: :high,
      created_at: @clock + start + 2_800
    }

    {run, items, interaction}
  end

  defp long_reply(n, start, lines) do
    run = run(n, :chat, "Explain the ticket lifecycle end to end", :done, start, 42_000)

    body =
      Enum.map_join(1..lines, "\n", fn i ->
        cond do
          rem(i, 20) == 1 -> "\n## Stage #{div(i, 20) + 1}\n"
          rem(i, 7) == 0 -> "- step #{i}: the `Tickets.transition/2` guard checks the actor"
          true -> "Line #{i} of the walkthrough explains one more state of a ticket and why."
        end
      end)

    items = [
      user(run, 0, start, "Explain the ticket lifecycle end to end, with every state."),
      message(run, 1, start + 200, body, tokens_in: 22_000, tokens_out: 3_100),
      step(run, 2, start + 400, "", 900),
      tool(run, 3, start + 1_300, "grep", ~s(grep "transition"), "lib/ test/ · 41 hits", 400)
    ]

    {run, items}
  end

  defp busy_turn(n, start, calls) do
    run = run(n, :chat, "Audit every context for missing indexes", :done, start, 96_000)

    tools =
      Enum.map(1..calls, fn i ->
        tool(
          run,
          2 + i,
          start + 1_000 + i * 500,
          "read_file",
          "read lib/ailogic/context_#{i}.ex",
          "lib/ailogic/context_#{i}.ex (#{100 + i} lines)",
          2 + i,
          files: ["lib/ailogic/context_#{i}.ex"]
        )
      end)

    items =
      [
        user(run, 0, start, "Audit every context for missing indexes."),
        message(run, 1, start + 200, "No context is missing an index on a foreign key.",
          tokens_in: 40_000,
          tokens_out: 800
        ),
        step(run, 2, start + 400, "", 600)
      ] ++ tools

    {run, items}
  end

  defp swarm(n, start) do
    run =
      run(n, :swarm, "Summarise each directory in parallel", :running, start, nil,
        agents_total: 4,
        agents_running: 2,
        needs: 1,
        changes: 0
      )

    lead = agent(run, 1, "lead", :lead, :running, "planning", start, nil)

    workers = [
      agent(run, 2, "worker-a-accounts", :worker, :done, "done", start + 5_000, start + 21_000),
      agent(
        run,
        3,
        "worker-b-live",
        :worker,
        :waiting_approval,
        "run_command",
        start + 5_000,
        nil
      ),
      agent(run, 4, "merge", :worker, :queued, "queued", nil, nil)
    ]

    items = [
      user(
        run,
        0,
        start,
        "/swarm summarise lib/ailogic/accounts and lib/ailogic_web/live in parallel"
      ),
      message(
        run,
        1,
        start + 200,
        "Two workers are summarising the directories; merge waits for both.",
        state: :streaming,
        agent_id: lead.id
      ),
      step(run, 2, start + 400, "", 3_000, agent_id: lead.id),
      tool(run, 3, start + 6_000, "list_dir", "list lib/ailogic/accounts", "3 files", 8,
        agent_id: "agent-#{n}-2"
      ),
      tool(run, 4, start + 7_000, "read_file", "read lib/ailogic/accounts/user.ex", "88 lines", 4,
        agent_id: "agent-#{n}-2"
      ),
      worker_report(
        run,
        5,
        start + 21_000,
        "agent-#{n}-2",
        "Two Ecto schemas plus one email helper; the user schema owns roles."
      ),
      tool(
        run,
        6,
        start + 9_000,
        "run_command",
        "run: find lib/ailogic_web/live -name '*.ex' | wc -l",
        "awaiting approval",
        nil,
        agent_id: "agent-#{n}-3",
        status: :waiting_approval
      )
    ]

    interaction = %DTO.PendingInteraction{
      id: "demo-approval-#{n}",
      run_id: run.id,
      node_id: node_id(run, 6),
      conversation_id: @conversation,
      kind: :approval,
      expected_revision: 2,
      approval: %DTO.Approval{
        tool: "run_command",
        permission: :execute,
        arguments_preview: ~s({"command":"find lib/ailogic_web/live -name '*.ex' | wc -l"})
      },
      allowed_actions: [:approve, :always_allow, :deny],
      urgency: :high,
      created_at: @clock + start + 9_000
    }

    {run, items, [lead | workers], interaction}
  end

  defp failed_workflow(n, start, count) do
    run =
      run(n, :workflow, "/design-coloring", :failed, start, 480_000,
        agents_total: count,
        agents_running: 0,
        error: "phase apply-fixes failed: 3 agents failed"
      )

    agents =
      for i <- 1..count do
        state = if rem(i, 5) == 0, do: :failed, else: :done
        role = if i == 1, do: :lead, else: :worker
        agent(run, i, "apply-fixes-#{i}", role, state, "done", start + i * 1_000, start + 400_000)
      end

    items =
      [user(run, 0, start, "/design-coloring the whole dashboard")] ++
        Enum.flat_map(1..count, fn i ->
          agent_id = "agent-#{n}-#{i}"

          [
            step(run, i * 3, start + i * 2_000, "", 2_000, agent_id: agent_id),
            tool(
              run,
              i * 3 + 1,
              start + i * 2_000 + 500,
              "edit_file",
              "edit assets/css/app.css",
              "edited assets/css/app.css: 1 replacement",
              12,
              agent_id: agent_id,
              files: ["assets/css/app.css"],
              status: if(rem(i, 5) == 0, do: :failed, else: :done)
            ),
            worker_report(
              run,
              i * 3 + 2,
              start + 300_000 + i,
              agent_id,
              "Recoloured #{i} selectors."
            )
          ]
        end)

    {run, items, agents}
  end

  # --- facts --------------------------------------------------------------------

  defp run(n, kind, title, state, start, duration, extra \\ []) do
    started = @clock + start

    struct!(
      %DTO.RunSummary{
        id: "demo-run-#{n}",
        conversation_id: @conversation,
        kind: kind,
        title: title,
        revision: 3,
        state: state,
        allowed_actions: allowed(state),
        created_sequence: n,
        started_at: started,
        finished_at: if(duration, do: started + duration),
        tokens_in: 18_210,
        tokens_out: 940,
        cost_usd: 0.0123,
        model: @model
      },
      extra
    )
  end

  defp allowed(state) when state in [:running, :streaming, :waiting_approval],
    do: [:pause, :stop, :send, :steer]

  defp allowed(:failed), do: [:retry]
  defp allowed(_), do: []

  defp agent(run, i, name, role, state, step, started, finished) do
    %DTO.AgentSummary{
      id: "agent-#{run.created_sequence}-#{i}",
      run_id: run.id,
      revision: 1,
      state: state,
      allowed_actions: [],
      name: name,
      role: role,
      title: name,
      step: step,
      progress: if(state == :done, do: 100, else: 40),
      tokens_in: 4_000 + i * 100,
      tokens_out: 300 + i * 10,
      started_at: started && @clock + started,
      finished_at: finished && @clock + finished,
      parent_id: if(role == :lead, do: nil, else: "agent-#{run.created_sequence}-1"),
      depth: if(role == :lead, do: 0, else: 1)
    }
  end

  defp node_id(run, seq), do: "#{run.id}-node-#{seq}"

  defp item(run, seq, at, fields) do
    struct!(
      %DTO.TranscriptItem{
        id: "#{run.id}-item-#{String.pad_leading(Integer.to_string(seq), 3, "0")}",
        run_id: run.id,
        conversation_id: @conversation,
        node_id: node_id(run, seq),
        revision: 1,
        role: :assistant,
        state: :done,
        text: "",
        reasoning: "",
        attempt_id: "demo-attempt",
        created_sequence: run.created_sequence * 1_000 + seq,
        at: @clock + at
      },
      fields
    )
  end

  defp user(run, seq, at, text), do: item(run, seq, at, role: :user, text: text)

  defp message(run, seq, at, text, extra) do
    state = Keyword.get(extra, :state, :done)
    fields = Keyword.drop(extra, [:state])
    item(run, seq, at, [role: :assistant, kind: :text, text: text, state: state] ++ fields)
  end

  defp step(run, seq, at, text, duration, extra \\ []) do
    item(
      run,
      seq,
      at,
      [
        role: :assistant,
        kind: :thinking,
        text: text,
        reasoning: "Looking at what the request needs before calling any tool.",
        tool: %DTO.ToolCall{
          name: "llm",
          status: :done,
          started_at: @clock + at,
          finished_at: @clock + at + duration,
          duration_ms: duration
        }
      ] ++ extra
    )
  end

  defp worker_report(run, seq, at, agent_id, text),
    do: item(run, seq, at, role: :assistant, kind: :text, text: text, agent_id: agent_id)

  defp tool(run, seq, at, name, title, detail, duration, extra \\ []) do
    status = Keyword.get(extra, :status, :done)
    files = Keyword.get(extra, :files, [])
    text = Keyword.get(extra, :text, "")
    fields = Keyword.drop(extra, [:status, :files, :text])

    item(
      run,
      seq,
      at,
      [
        role: :tool,
        kind: :tool,
        state: status,
        text: text,
        tool: %DTO.ToolCall{
          name: name,
          title: title,
          detail: detail,
          status: status,
          started_at: @clock + at,
          finished_at: if(duration, do: @clock + at + duration),
          duration_ms: duration,
          result_bytes: byte_size(text),
          files: files
        }
      ] ++ fields
    )
  end
end
