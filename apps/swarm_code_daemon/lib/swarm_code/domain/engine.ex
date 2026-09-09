defmodule SwarmCode.Domain.Engine do
  @moduledoc "Entry points used by the UI: start chat turns and swarms, stop runs/agents, resolve approvals."

  require Logger
  alias SwarmCode.Domain.{Conversations, Providers, Repo, Settings}
  alias SwarmCode.Domain.Engine.{ProjectContext, Prompts, RunServer, RunSupervisor}

  # Spec 50 §2.4: commands whose turn is defined by the command itself, so a
  # judge would have nothing to judge — the workflow author's turn produces a
  # workflow, a compaction produces a summary. Spec 50 §2.3 moves the mode pill
  # when the chip appears; this is what makes the *run* right even when the pill
  # did not move (a queued message, a scheduled task, a direct engine call).
  @unjudged [:create_workflow, :compact]

  @doc """
  The framing a goal run adds to the goal itself (spec 07 §15).
  """
  def goal_framing,
    do: "Pursue this goal until it is achieved; report progress; stop when done."

  @doc "The framing an approved plan's implementation run reads (spec 50 §7.4)."
  @spec implement_prompt(String.t()) :: String.t()
  def implement_prompt(plan) do
    """
    Carry out this approved plan. It was produced in plan mode and the user has approved it.

    #{plan}

    Rules:
    - Follow the plan's steps in order; do not re-plan and do not ask whether to start.
    - If a step turns out to be wrong or impossible, say so in one line, do the right thing instead, and carry on.
    - Verify your work the way the plan says (tests, a build, a command) before you report.
    - Finish with what changed, file by file, and how you verified it.
    """
  end

  @doc """
  Starts the turn `/goal <text>` produces: the stored user message is
  `/goal <text>` (so the transcript shows the `◎ goal` chip) while the model is
  asked to pursue it (spec 07 §15).
  """
  @spec start_goal_turn(SwarmCode.Domain.Conversations.Conversation.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, :not_configured | {:start_failed, term()}}
  def start_goal_turn(conversation, goal, opts \\ []) do
    # The stored message is the user's text with its command markers; the
    # framing lives only in the prompt the model reads (spec 10 §7.3).
    message = opts[:message] || "/goal " <> goal

    start_chat_turn(conversation, message, [],
      prompt: opts[:prompt] || goal <> "\n\n" <> goal_framing(),
      goal_id: opts[:goal_id],
      # Spec 17 §2.2: a goal resumed from the side chat is a follow-up of the
      # sub-session that resumed it.
      reply_to_run_id: opts[:reply_to_run_id]
    )
  end

  @spec start_chat_turn(
          SwarmCode.Domain.Conversations.Conversation.t(),
          String.t(),
          [map()],
          keyword()
        ) ::
          {:ok, String.t()}
          | {:error,
             :not_configured
             | :database_busy
             | {:invalid_message, Ecto.Changeset.t()}
             | {:start_failed, term()}}
  def start_chat_turn(conversation, text, attachments \\ [], opts \\ []) do
    # Spec 25 §3.3: the attached reports go into the *model's* context, never
    # into the stored message — the transcript keeps what the user typed.
    research_ids = List.wrap(opts[:research_ids])

    # A running chat turn never blocks a new one: the UI steers the running agent
    # (see `steer/2`) and only falls back here when that agent has already finished.
    #
    # Spec 50 §2.4: a mode-bearing command owns its turn.
    # Spec 51 §5.7: a resumed run brings its own config (`opts[:consensus]`)
    # and is judged whatever the pill says now.
    judged? =
      (opts[:consensus] != nil or conversation.consensus == true) and
        opts[:command] not in @unjudged

    # Spec 51 §1.2: every write that can come back `{:error, :database_busy}` is
    # a `with` clause — a contended write is a flash for the user, never a crash
    # of the LiveView and never a user message without a run.
    #
    # Spec 54 §1.1 (54a A1): the run row and the two message/run pairings were
    # bang matches, and each of them raised `Database busy` into the LiveView
    # under load (one lost goal launch in 54a's fast scenario came from the
    # assistant pairing). They are `with` clauses on a retried write now.
    #
    # spec 55 T7 (55a A5): one transaction per turn start.
    with {:ok, chat} <- Providers.effective_model(conversation, :chat),
         {:ok, conversation} <- Conversations.set_title_from(conversation, text),
         # Spec 17 §2.6: the message that launched this run points at it, so the
         # pairing never has to guess from timestamps.
         {:ok, %{user: _user_message, assistant: assistant, run: run}} <-
           SwarmCode.Domain.Conversations.Writes.create_turn(
             conversation.id,
             user_attrs(conversation, text, attachments, research_ids, opts),
             %{conversation_id: conversation.id, role: "assistant", content: ""},
             chat_run_attrs(conversation, text, chat, judged?, opts)
           ) do
      link_goal(opts[:goal_id], run)
      if opts[:goal_id], do: label_run(run, chat)

      # `opts[:prompt]` is what the model reads instead of the stored message —
      # a goal run shows `/goal ship it` and asks for `ship it` + the framing.
      # Spec 17 §2.2: `:context` is the block a side-chat follow-up puts in
      # front of the turn (the goal and its latest report, or the summary of
      # the workflow that just finished). The *stored* message stays the
      # user's own text.
      prompt =
        opts[:context]
        |> with_context(opts[:prompt] || text)
        |> then(&with_context(SwarmCode.Domain.Research.context_block(research_ids), &1))

      # Spec 50 §1.2: `list_history_window/2` is `list_messages_window/2` with a
      # floor — it never reaches back past the newest `/compact` summary.
      history =
        Conversations.list_history_window(conversation.id, 8 * 120_000)
        |> Prompts.history_to_messages()
        |> replace_last_user(prompt)

      project = SwarmCode.Domain.Projects.get!(conversation.project_id)

      start_run(%{
        run: run,
        conversation: conversation,
        project: project,
        project_context: ProjectContext.build(project, conversation),
        settings: Settings.get_cached(),
        chat_model: chat,
        swarm_model: swarm_model(conversation),
        history: history,
        prompt: prompt,
        mode: conversation.mode || "build",
        # Spec 12 §5: the command the user invoked gates the tool list and the
        # system prompt of this turn.
        command: opts[:command],
        # Spec 37 §4.1: nil unless consensus is on for this conversation.
        # Spec 50 §2.4: and never for a command that defines its own turn.
        consensus:
          if(judged?,
            do: opts[:consensus] || consensus_config(conversation, opts[:prompt] || text)
          ),
        # Spec 45 §5.2: the rounds the resumed run had already been through,
        # so the RunServer counts on from there.
        consensus_rounds: opts[:consensus_rounds],
        # Spec 51 §5.6: and the last verdict per stage, for the next judge.
        consensus_verdicts: opts[:consensus_verdicts],
        assistant_message: assistant
      })
    else
      {:error, :database_busy} = busy -> busy
      {:error, :not_configured} = error -> error
      {:error, %Ecto.Changeset{} = changeset} -> {:error, {:invalid_message, changeset}}
      # spec 55 T7: `create_turn/4` already wraps a message changeset.
      {:error, {:invalid_message, _}} = error -> error
    end
  end

  # Spec 54 §1.1: the run row of a chat turn. spec 55 T7: the attrs only — the
  # write is `Writes.create_turn/4`'s one transaction.
  defp chat_run_attrs(conversation, text, chat, judged?, opts) do
    %{
      conversation_id: conversation.id,
      kind: "chat",
      prompt: text,
      model: chat.model,
      goal_id: opts[:goal_id],
      # Spec 13 §4: a label is present from the first render — the model's
      # label replaces this one when (and if) it arrives.
      label: opts[:goal_id] && fallback_label(text),
      # Spec 37 §6.4: the card says this turn was judged. Spec 40 §2.2:
      # and with what. Spec 50 §2.4: never for a `/create-workflow` or
      # `/compact` turn, whatever the pill said a moment ago.
      consensus: judged?,
      consensus_config:
        if(judged?,
          do:
            (opts[:consensus] || consensus_config(conversation, opts[:prompt] || text))
            |> SwarmCode.Domain.Engine.Consensus.persistable()
        ),
      # Spec 45 §5.2: a resumed turn names the run it continues.
      resumed_from_run_id: opts[:resume_of],
      # Spec 50 §4: the run remembers the mode it ran in; the conversation's
      # flag is free to change afterwards, and §7's gate asks the run.
      mode: conversation.mode || "build",
      # Spec 50 §7: the planner run this one implements.
      implements_run_id: opts[:implements_run_id],
      started_at: now()
    }
  end

  # Spec 51 §1.2: `nil` when the caller stores no user message — a
  # model-launched swarm (the `start_swarm` tool, spec 12 §1) or a run resumed
  # from a card writes none; the assistant's own message introduces it.
  # spec 55 T7: the attrs map only; `Writes.create_turn/4` inserts it.
  defp user_attrs(conversation, text, attachments, research_ids, opts) do
    if Keyword.get(opts, :store_user, true) do
      %{
        conversation_id: conversation.id,
        role: "user",
        content: text,
        attachments: attachments,
        research_ids: research_ids,
        # Spec 13 §3.3: a follow-up sent from the side chat continues that
        # run's thread, so its message says which run it answers.
        reply_to_run_id: opts[:reply_to_run_id]
      }
    else
      nil
    end
  end

  @doc """
  Compacts the conversation (spec 50 §1): a one-agent, tool-less run on the chat
  model that reads the history the next turn would have read and replaces it
  with a structured summary. The summary is stored as a message with role
  `compact`; from then on `Conversations.list_history_window/2` starts there.
  Nothing is deleted — the older messages stay in the database and in the
  transcript, only the model's window moves.

  `focus` is the free text after `/compact` and steers the summary; it may be "".
  """
  @spec start_compact(SwarmCode.Domain.Conversations.Conversation.t(), String.t()) ::
          {:ok, String.t()}
          | {:error,
             :not_configured
             | :nothing_to_compact
             | :database_busy
             | {:invalid_message, Ecto.Changeset.t()}
             | {:start_failed, term()}}
  def start_compact(conversation, focus \\ "") do
    focus = String.trim(to_string(focus))
    message = String.trim("/compact " <> focus)

    # Spec 51 §6.6: read exactly what the compactor may send. The old window was
    # `8 × budget` bytes — twice what `Context.trim/1` lets through — so
    # `drop_oldest/2` cut whole exchanges from the front *before* the compactor
    # saw them, and the summary that became the floor for every later read was
    # written from a truncated history without saying so.
    #
    # spec 55 T18 (55a A12): the window is the chat model's own budget.
    chat_model =
      case Providers.effective_model(conversation, :chat) do
        {:ok, c} -> c.model
        _ -> nil
      end

    rows = Conversations.list_history_window(conversation.id, compact_window_bytes(chat_model))
    # Counted before this turn's own two rows exist.
    omitted = Conversations.count_history_since_floor(conversation.id) - length(rows)

    # spec 55 T7 (55a A5): one transaction per turn start.
    with {:ok, chat} <- Providers.effective_model(conversation, :chat),
         history when history != [] <- Prompts.history_to_messages(rows),
         {:ok, %{user: _user, assistant: summary, run: run}} <-
           SwarmCode.Domain.Conversations.Writes.create_turn(
             conversation.id,
             %{conversation_id: conversation.id, role: "user", content: message},
             %{conversation_id: conversation.id, role: "compact", content: ""},
             %{
               conversation_id: conversation.id,
               kind: "compact",
               prompt: message,
               model: chat.model,
               # Spec 50 §4 (merge): a compactor is never a planner — it reads the
               # history and writes one summary — so the run says `build` outright
               # rather than leaving the column nil for `Run.agent_name/1` to guess.
               mode: "build",
               started_at: now()
             }
           ) do
      prompt = Prompts.compact(focus, omitted: omitted)
      project = SwarmCode.Domain.Projects.get!(conversation.project_id)

      start_run(%{
        run: run,
        conversation: conversation,
        project: project,
        project_context: ProjectContext.build(project, conversation),
        settings: Settings.get_cached(),
        chat_model: chat,
        swarm_model: swarm_model(conversation),
        history: history ++ [%{role: "user", content: prompt}],
        prompt: prompt,
        mode: "build",
        command: :compact,
        assistant_message: summary
      })
    else
      [] -> {:error, :nothing_to_compact}
      {:error, :not_configured} -> {:error, :not_configured}
      {:error, :database_busy} = busy -> busy
      {:error, %Ecto.Changeset{} = changeset} -> {:error, {:invalid_message, changeset}}
      # spec 55 T7: `create_turn/4` already wraps a message changeset.
      {:error, {:invalid_message, _}} = error -> error
    end
  end

  # Spec 51 §6.6: four bytes to the token, less the room the system prompt and
  # `Prompts.compact/2` take out of the same budget. Not raised past the trim
  # budget: the chat model behind an OpenAI-compatible gateway may have a 128 k
  # context, and a bigger window would only 400.
  @compact_margin 40_000
  # spec 55 T18 (55a A12): the window follows the model's own budget.
  defp compact_window_bytes(model),
    do: 4 * SwarmCode.Domain.Engine.Context.budget(model) - @compact_margin

  # Spec 37 §4.1: the judge needs the user's request, so the config carries it.
  defp consensus_config(conversation, request) do
    case SwarmCode.Domain.Engine.Consensus.config(conversation) do
      nil -> nil
      config -> Map.put(config, :request, request)
    end
  end

  defp with_context(context, prompt) when is_binary(context) and context != "",
    do: context <> "\n\n" <> prompt

  defp with_context(_context, prompt), do: prompt

  defp replace_last_user(history, prompt) do
    case Enum.reverse(history) do
      [%{role: "user"} = last | rest] ->
        Enum.reverse([%{last | content: prompt} | rest])

      _ ->
        history
    end
  end

  @doc """
  Steers the running chat run of `conversation_id`: persists `text` as a user
  message and hands it to the running root agent, which appends it to its message
  list before its next LLM call.

  Returns `{:error, :not_running}` when nothing is running (or the root agent has
  already finished) — the caller then starts a normal turn instead.
  """
  @spec steer(String.t(), String.t(), [map()], keyword()) ::
          :ok | {:error, :not_running | :database_busy}
  def steer(conversation_id, text, attachments \\ [], opts \\ []) do
    images = SwarmCode.Domain.Attachments.images(attachments)

    # Spec 12 §3: a reply mark steers exactly ONE run; without it the caller
    # still means "the chat run of this conversation".
    with [run_id | _] <- steer_targets(conversation_id, opts[:run_id]),
         :ok <- RunServer.steer(run_id, text, images, node_id: opts[:node_id]),
         conversation when not is_nil(conversation) <- Conversations.get(conversation_id),
         {:ok, _} <-
           Conversations.create_message(%{
             conversation_id: conversation_id,
             role: "user",
             content: text,
             attachments: attachments,
             # Spec 17 §2.2: a steer belongs to the run it steers, so the pane and
             # the side chat both show it against that run.
             run_id: run_id,
             reply_to_run_id: opts[:run_id] || run_id
           }) do
      Conversations.touch(conversation)
      :ok
    else
      # Spec 51 §1.2: the steer reached the agent; only the transcript row is missing.
      {:error, :database_busy} = busy -> busy
      _ -> {:error, :not_running}
    end
  end

  defp steer_targets(conversation_id, nil), do: chat_run_ids(conversation_id)

  defp steer_targets(conversation_id, run_id) do
    if run_id in running_runs(conversation_id), do: [run_id], else: []
  end

  @doc """
  Starts a swarm run. `opts` accepts `:message` (what the transcript stores —
  by default `/swarm <task>`), `:prompt` (what the Lead reads — by default the
  task) and `:goal_id` (spec 10 §7 + §16).
  """
  @spec start_swarm(SwarmCode.Domain.Conversations.Conversation.t(), String.t(), keyword()) ::
          {:ok, String.t()}
          | {:error,
             :not_configured
             | :database_busy
             | {:invalid_message, Ecto.Changeset.t()}
             | {:start_failed, term()}}
  def start_swarm(conversation, task, opts \\ []) do
    # A model-launched swarm (the `start_swarm` tool, spec 12 §1) writes no
    # user message: the assistant's own message introduces it (`store_user: false`).
    prompt = opts[:prompt] || task

    # Spec 54 §1.1 (54a A1): the same two bang matches `start_chat_turn/4`
    # had. Two of 54a's three lost launches in the slow scenario were a swarm
    # whose `INSERT INTO runs` came back `Database busy`.
    #
    # spec 55 T7 (55a A5): one transaction per turn start.
    with {:ok, chat} <- Providers.effective_model(conversation, :chat),
         {:ok, conversation} <- Conversations.set_title_from(conversation, task),
         {:ok, %{run: run}} <-
           SwarmCode.Domain.Conversations.Writes.create_turn(
             conversation.id,
             user_attrs(conversation, opts[:message] || "/swarm " <> task, [], [], opts),
             nil,
             swarm_run_attrs(conversation, prompt, chat, opts)
           ) do
      link_goal(opts[:goal_id], run)

      # A caller that already knows the label (start_swarm) does not pay for one.
      if is_nil(opts[:label]), do: label_run(run, chat)

      project = SwarmCode.Domain.Projects.get!(conversation.project_id)

      start_run(%{
        run: run,
        conversation: conversation,
        project: project,
        project_context: ProjectContext.build(project, conversation),
        settings: Settings.get_cached(),
        chat_model: chat,
        swarm_model: swarm_model(conversation),
        history: [],
        prompt: prompt,
        mode: conversation.mode || "build",
        command: :swarm,
        assistant_message: nil
      })
    else
      {:error, :not_configured} = error -> error
      {:error, :database_busy} = busy -> busy
      {:error, %Ecto.Changeset{} = changeset} -> {:error, {:invalid_message, changeset}}
      # spec 55 T7: `create_turn/4` already wraps a message changeset.
      {:error, {:invalid_message, _}} = error -> error
    end
  end

  # Spec 54 §1.1: the run row of a swarm. spec 55 T7: the attrs only — the
  # write is `Writes.create_turn/4`'s one transaction.
  defp swarm_run_attrs(conversation, prompt, chat, opts) do
    %{
      conversation_id: conversation.id,
      kind: "swarm",
      prompt: prompt,
      model: chat.model,
      goal_id: opts[:goal_id],
      # Spec 13 §4: never nil — the Lead card must have something to show
      # from the very first patch (the AI label replaces it later).
      label: opts[:label] || fallback_label(prompt),
      # Spec 17 §2.6: a swarm the model started through `start_swarm`
      # names the run it came from instead of claiming a user message.
      launched_by_run_id: opts[:launched_by_run_id],
      # Spec 45 §5.2: a resumed swarm names the run it continues.
      resumed_from_run_id: opts[:resume_of],
      # Spec 50 §4: the run remembers the mode it ran in.
      mode: conversation.mode || "build",
      # Spec 50 §7: the planner run this one implements.
      implements_run_id: opts[:implements_run_id],
      started_at: now()
    }
  end

  # A goal remembers the run that pursues it right now (spec 10 §16).
  defp link_goal(nil, _run), do: :ok

  defp link_goal(goal_id, run) do
    case Conversations.get_goal(goal_id) do
      nil -> :ok
      goal -> Conversations.set_goal_run(goal, run.id)
    end

    :ok
  end

  @label_prompt "Give a 2-4 word lowercase label for this task, no punctuation, no quotes: "

  @doc """
  Asks the conversation's chat model for a short label for a swarm or goal run
  (spec 10 §13) in a detached Task and stores it on the run.
  """
  @spec label_run(SwarmCode.Domain.Conversations.Run.t(), map()) :: :ok
  def label_run(run, chat_model) do
    if Application.get_env(:swarm_code_daemon, :label_runs, true),
      do: do_label_run(run, chat_model)

    :ok
  end

  defp do_label_run(run, chat_model) do
    Task.Supervisor.start_child(SwarmCode.Domain.TaskSupervisor, fn ->
      case ask_for_label(run, chat_model) do
        nil ->
          :ok

        label ->
          # Spec 13 §11 A-3: the struct this Task captured is the one from
          # creation (running, no tokens). Broadcasting it would resurrect a
          # run that has long finished — reload it first.
          # Spec 54 §1.5 (54a C6): a run that finished before its label came
          # back is settled — nothing is left to relabel, and the write used to
          # be a bang match that took this Task down on `Database busy`
          # (observed once in 54a's fast scenario). Retried, never raised.
          case Conversations.get_run(run.id) do
            nil ->
              :ok

            %{status: status} when status in ["done", "failed", "stopped"] ->
              :ok

            fresh ->
              Conversations.with_busy_retry(fn ->
                Conversations.update_run(fresh, %{label: label})
              end)

              # Spec 13 §4: the RunServer caches the `runs` row and re-broadcasts
              # it on every flush — tell it, or its next token update puts the
              # fallback label back on the card.
              SwarmCode.Domain.Engine.RunServer.set_label(run.id, label)
          end
      end
    end)

    :ok
  end

  defp ask_for_label(run, %{provider: provider, model: model}) do
    request = %SwarmCode.Domain.LLM.Request{
      provider: provider,
      model: model,
      system: "You label tasks in 2-4 lowercase words.",
      messages: [
        %{role: "user", content: @label_prompt <> String.slice(run.prompt || "", 0, 500)}
      ],
      # Spec 53b §6: `max_tokens` caps thinking *plus* the answer on every
      # current Claude model, and a request that carries no `thinking` field
      # thinks by default from Claude Opus 5 on — so the old ceiling of 16
      # truncated before a word of the label was written. The label is still
      # 2-4 words; `sanitize_label/2` trims whatever comes back.
      max_tokens: 2048,
      # Only the OpenAI-compatible path still reads this — `temperature` is a
      # 400 on the current Anthropic wire and `LLM.Anthropic.put_sampling/2`
      # keeps it off (§1).
      temperature: 0.0,
      # …and only the Anthropic path takes an effort here: `low` is the cheap
      # rung and it replaces the API's `high` default, which is what a request
      # with no `output_config` gets. Sending `reasoning_effort` to an
      # OpenAI-compatible server for a label would be a change of behaviour.
      effort: label_effort(provider)
    }

    case SwarmCode.Domain.LLM.stream(request, fn _ -> :ok end) do
      {:ok, %{text: text}} ->
        sanitize_label(text, run.prompt)

      other ->
        # Spec 13 §4: a label request that fails used to fail in silence, which
        # is why a Lead card could stay unlabelled forever. Spec 53b §6: and
        # then it failed in silence about *why*, which is how a wire shape the
        # model rejects can go unnoticed for a whole pass.
        Logger.warning("swarm_code label request failed: " <> label_reason(other))

        sanitize_label("", run.prompt)
    end
  rescue
    _error ->
      Logger.warning("swarm_code label request raised")

      nil
  catch
    kind, _reason ->
      Logger.warning("swarm_code label request exited (#{kind})")

      nil
  end

  defp ask_for_label(_run, _model), do: nil

  defp label_effort(%{kind: "anthropic"}), do: "low"
  defp label_effort(_provider), do: nil

  defp label_reason({:error, message}), do: String.slice(to_string(message), 0, 300)
  defp label_reason(other), do: inspect(other, limit: 5) |> String.slice(0, 300)

  @doc false
  # First line, no quotes, no trailing period, ≤ 32 chars; falls back to the
  # first four words of the prompt.
  def sanitize_label(text, fallback_prompt) do
    cleaned =
      text
      |> to_string()
      |> String.split("\n", parts: 2)
      |> List.first()
      |> to_string()
      |> String.trim()
      |> String.trim("\"")
      |> String.trim("'")
      |> String.trim_trailing(".")
      |> String.trim()
      |> String.slice(0, 32)
      |> String.downcase()

    if cleaned == "", do: fallback_label(fallback_prompt), else: cleaned
  end

  defp fallback_label(prompt) do
    case prompt |> to_string() |> String.split(~r/\s+/, trim: true) |> Enum.take(4) do
      [] -> nil
      words -> words |> Enum.join(" ") |> String.slice(0, 32) |> String.downcase()
    end
  end

  @doc """
  Starts a run's supervision tree, compensating and logging if it will not boot.

  Public because a deep research (spec 24 §3.1) starts its run the same way and
  wants the same `:engine_run_starter` test hook and the same compensation.
  """
  @spec start_run(map()) :: {:ok, String.t()} | {:error, {:start_failed, term()}}
  def start_run(args) do
    starter =
      Application.get_env(:swarm_code_daemon, :engine_run_starter, &RunSupervisor.start_run/1)

    result =
      try do
        starter.(args)
      rescue
        error -> {:error, error}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, _pid} ->
        Conversations.touch(args.conversation)
        {:ok, args.run.id}

      {:error, reason} ->
        safe_reason = SwarmCode.Domain.LLM.HTTP.redact(inspect(reason))
        Logger.error("swarm_code could not start run #{args.run.id}: #{safe_reason}")
        compensate_start_failure(args, safe_reason)
        {:error, {:start_failed, reason}}
    end
  end

  defp compensate_start_failure(args, reason) do
    content = start_failure_message(args.run.kind, reason)

    case Repo.transaction(fn ->
           run = Conversations.get_run(args.run.id) || args.run

           {:ok, _} =
             rollback_on_error(
               Conversations.update_run(run, %{status: "failed", finished_at: DateTime.utc_now()})
             )

           case args[:assistant_message] do
             %{} = message ->
               {:ok, _} =
                 rollback_on_error(Conversations.update_message(message, %{content: content}))

             nil ->
               existing =
                 args.conversation.id
                 |> Conversations.list_messages()
                 |> Enum.find(&(&1.run_id == run.id and &1.role == "assistant"))

               unless existing do
                 {:ok, _} =
                   rollback_on_error(
                     Conversations.create_message(%{
                       conversation_id: args.conversation.id,
                       role: "assistant",
                       content: content,
                       run_id: run.id
                     })
                   )
               end
           end

           case Conversations.get_goal(run.goal_id) do
             %{status: "active"} = goal ->
               {:ok, _} = rollback_on_error(Conversations.update_goal(goal, %{status: "paused"}))

             _ ->
               :ok
           end

           :ok
         end) do
      {:ok, :ok} ->
        :ok

      {:error, error} ->
        Logger.error(
          "swarm_code could not compensate failed run #{args.run.id}: #{inspect(error)}"
        )

        :ok
    end
  end

  defp rollback_on_error({:ok, value}), do: {:ok, value}
  defp rollback_on_error({:error, reason}), do: Repo.rollback(reason)

  # Spec 51 §1.2 (R9): every `Run` kind and a catch-all — a `/compact` turn or a
  # research whose supervisor would not boot used to crash the caller here,
  # outside `start_run/1`'s `try`, so the compensation never ran.
  defp start_failure_message(kind, reason) do
    reason = reason |> to_string() |> String.slice(0, 200)

    case kind do
      "chat" -> "Could not start the assistant: " <> reason
      "compact" -> "Could not compact the conversation: " <> reason
      "swarm" -> "Swarm failed to start: " <> reason
      "workflow" -> "Workflow failed to start: " <> reason
      "research" -> "Research failed to start: " <> reason
      _other -> "Run failed to start: " <> reason
    end
  end

  defp swarm_model(conversation) do
    case Providers.effective_model(conversation, :swarm) do
      {:ok, model} -> model
      _ -> nil
    end
  end

  @spec stop_run(String.t()) :: :ok
  def stop_run(run_id) do
    RunServer.stop(run_id)
    :ok
  end

  @doc """
  Spec 45 §5.2: pauses a run of any kind. A chat/goal/swarm/consensus run holds
  every agent before its next think step (nothing is killed); a workflow run
  goes through `Workflows.control/3`.
  """
  @spec pause_run(String.t()) :: :ok | {:error, term()}
  def pause_run(run_id) do
    case Conversations.get_run(run_id) do
      %{kind: "workflow"} -> SwarmCode.Domain.Workflows.control(run_id, :pause, [])
      _other -> RunServer.pause(run_id)
    end
  end

  @doc "Spec 45 §5.2: the held agents of a paused run take their next step."
  @spec continue_run(String.t()) :: :ok | {:error, term()}
  def continue_run(run_id) do
    case Conversations.get_run(run_id) do
      %{kind: "workflow"} -> SwarmCode.Domain.Workflows.control(run_id, :resume, [])
      _other -> RunServer.continue(run_id)
    end
  end

  @resumable ~w(stopped failed interrupted)

  @doc """
  Spec 45 §5.2: a run that is stopped, failed or interrupted gets a NEW run
  that continues from the persisted state — `resumed_from_run_id` links them,
  a consensus run carries its rounds on (`R1 R2 | R3`), a swarm tells the new
  Lead what the old workers finished. Workflows resume their own journal;
  a research cannot be resumed.
  """
  @spec resume_run(SwarmCode.Domain.Conversations.Run.t() | String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def resume_run(run_id) when is_binary(run_id) do
    case Conversations.get_run(run_id) do
      nil -> {:error, :not_found}
      run -> resume_run(run)
    end
  end

  def resume_run(%{status: status} = run) when status in @resumable do
    if Map.get(run, :interrupted), do: Conversations.clear_interrupted(run)

    case run.kind do
      "chat" -> resume_chat(run)
      "swarm" -> resume_swarm(run)
      "workflow" -> resume_workflow(run)
      _other -> {:error, :unsupported}
    end
  end

  def resume_run(%{}), do: {:error, :not_resumable}

  defp resume_chat(run) do
    conv = Conversations.get!(run.conversation_id)
    nodes = Conversations.list_nodes(run.id)

    start_chat_turn(conv, "/resume", [],
      prompt: resume_prompt(run, nodes),
      resume_of: run.id,
      goal_id: run.goal_id,
      consensus_rounds: consensus_rounds_seed(run, nodes),
      consensus_verdicts: consensus_verdicts_seed(run, nodes),
      consensus: resume_config(run)
    )
  end

  # Spec 51 §5.7: the resumed run's own config — the stored checks, rounds and
  # mode with the judge and implementer rows re-resolved to live model maps,
  # judged against the user's original request.
  defp resume_config(%{consensus: true} = run) do
    config = SwarmCode.Domain.Engine.Consensus.config_of(run)
    conversation = Conversations.get!(run.conversation_id)

    config
    |> Map.put(:request, get_in(run.consensus_config || %{}, ["request"]) || run.prompt)
    |> Map.put(:judge, live_model(config.judge) || fallback_judge(conversation))
    |> Map.put(:implementer, live_model(config.implementer))
  end

  defp resume_config(_run), do: nil

  defp live_model(%{"provider_id" => id, "model" => model}) when is_binary(id) do
    case Providers.get(id) do
      nil -> nil
      provider -> %{provider: provider, model: model}
    end
  end

  defp live_model(_none), do: nil

  defp fallback_judge(conversation) do
    case Providers.effective_model(conversation, :judge) do
      {:ok, model} -> model
      _other -> nil
    end
  end

  # Spec 51 §5.6: the last decoded verdict of each stage, over the chain.
  defp consensus_verdicts_seed(%{consensus: true} = run, nodes) do
    SwarmCode.Domain.Engine.Consensus.rounds(run, Map.new(nodes, &{&1.id, &1}))
    |> Enum.reduce(%{}, fn round, acc ->
      if is_map(round.verdict),
        do: Map.put(acc, round.stage, Map.put(round.verdict, "round", round.index)),
        else: acc
    end)
  end

  defp consensus_verdicts_seed(_run, _nodes), do: nil

  defp resume_swarm(run) do
    conv = Conversations.get!(run.conversation_id)
    nodes = Conversations.list_nodes(run.id)

    start_swarm(conv, run.prompt || "",
      message: "/resume",
      prompt: resume_prompt(run, nodes),
      resume_of: run.id,
      goal_id: run.goal_id,
      launched_by_run_id: run.launched_by_run_id
    )
  end

  defp resume_workflow(run) do
    case SwarmCode.Domain.Workflows.control(run.id, :resume, []) do
      :ok -> {:ok, run.id}
      other -> other
    end
  end

  # Spec 51 §5.2: the old attempt's branches, so the new Lead integrates them
  # instead of redoing the work (the note used to sit at the end of a 400-char
  # slice that had already cut it off).
  defp branch_note(%{branch: branch, integrated: false} = n)
       when is_binary(branch) and branch != "",
       do: " [changes on branch #{branch} (#{n.changes_stat}); integrate with integrate_agent]"

  defp branch_note(_node), do: ""

  @doc """
  The prompt the resumed run reads (spec 45 §5.2): what was done before the
  interruption, and — for a consensus run — where the rounds stood, so the
  planner carries on from the latest verdict instead of starting over.
  """
  @spec resume_prompt(map(), [map()]) :: String.t()
  def resume_prompt(%{kind: "swarm"} = run, nodes) do
    reports =
      for n <- nodes,
          n.kind == "agent",
          n.status == "done",
          is_binary(n.result) and n.result != "",
          do: "#{n.name}: #{String.slice(n.result, 0, 400)}" <> branch_note(n)

    to_string(run.prompt) <>
      "\n\nALREADY DONE by the previous attempt (worker reports):\n" <>
      if(reports == [], do: "(nothing finished)", else: Enum.join(reports, "\n")) <>
      "\nContinue; do not redo finished work."
  end

  def resume_prompt(run, nodes) do
    titles =
      nodes
      |> Enum.filter(&(&1.kind == "op" and &1.status == "done" and &1.op_type != "llm"))
      |> Enum.sort_by(& &1.position)
      |> Enum.take(20)
      |> Enum.map(& &1.title)

    base =
      if titles == [],
        do: "Continue the interrupted turn. Pick up where you left off.",
        else:
          "Continue the interrupted turn. Ops completed before the interruption: " <>
            Enum.join(titles, ", ") <> ". Pick up where you left off."

    case consensus_state_block(run, nodes) do
      nil -> base
      block -> base <> "\n\n" <> block
    end
  end

  # The rounds the resumed run (and the chain before it) had been through, per
  # stage — the RunServer's counter starts there (spec 45 §5.2).
  defp consensus_rounds_seed(%{consensus: true} = run, nodes) do
    rounds = SwarmCode.Domain.Engine.Consensus.rounds(run, Map.new(nodes, &{&1.id, &1}))

    %{
      "plan" => Enum.count(rounds, &(&1.stage == "plan")),
      "changes" => Enum.count(rounds, &(&1.stage == "changes"))
    }
  end

  defp consensus_rounds_seed(_run, _nodes), do: nil

  defp consensus_state_block(%{consensus: true} = run, nodes) do
    config = SwarmCode.Domain.Engine.Consensus.config_of(run)
    rounds = SwarmCode.Domain.Engine.Consensus.rounds(run, Map.new(nodes, &{&1.id, &1}))

    case List.last(rounds) do
      nil ->
        "CONSENSUS STATE: no plan was submitted yet. " <>
          "Continue from there: call submit_plan with your plan."

      latest ->
        verdict = latest.verdict
        approved? = verdict != nil and verdict["verdict"] == "approve"

        word =
          cond do
            is_nil(verdict) -> "none"
            approved? -> "APPROVED"
            true -> "REVISE"
          end

        findings =
          (verdict && verdict["findings"])
          |> List.wrap()
          |> Enum.with_index(1)
          |> Enum.map(fn {f, i} ->
            "#{i}. [#{f["severity"]}] #{f["concern"]} Requested change: #{f["requested_change"]}"
          end)

        next =
          cond do
            approved? and Map.get(config, :implementer) ->
              "write the spec now (call write_spec with the complete spec) and hand it to the implementer"

            approved? and config.mode == "plan" ->
              "present the final plan as your answer; do not implement"

            approved? ->
              "implement the plan"

            is_nil(verdict) ->
              "call submit_plan with your plan"

            true ->
              "address the findings and call submit_plan again"
          end

        # Spec 51 §5.7: the count is per stage, the stage is named, and the
        # rounds being used up is said so the planner does not try a round
        # the RunServer will refuse.
        stage = latest.stage
        n = Enum.count(rounds, &(&1.stage == stage))

        exhausted =
          if n >= config.rounds,
            do:
              " The rounds are used up: proceed with your best plan; state which findings " <>
                "you reject and why.",
            else: ""

        "CONSENSUS STATE: round #{n} of #{config.rounds} was reached (stage #{stage})." <>
          exhausted <>
          " Latest plan:\n" <>
          String.slice(to_string(latest.plan), 0, 6_000) <>
          "\nLatest verdict: #{word} — #{(verdict && verdict["summary"]) || "the judge did not answer"}" <>
          "\nFindings:\n" <>
          if(findings == [], do: "(none)", else: Enum.join(findings, "\n")) <>
          "\nContinue from there: #{next}."
    end
  end

  defp consensus_state_block(_run, _nodes), do: nil

  @spec stop_all(String.t()) :: :ok
  def stop_all(conversation_id) do
    conversation_id |> running_runs() |> Enum.each(&stop_run/1)
  end

  @doc "Stops every run of every conversation (the quit path, spec 11 §11)."
  @spec stop_all() :: :ok
  def stop_all do
    Enum.each(running_run_ids(), &stop_run/1)
  end

  @spec stop_agent(String.t(), String.t()) :: :ok
  def stop_agent(run_id, node_id) do
    RunServer.stop_agent(run_id, node_id)
    :ok
  end

  @doc "Answers the questions an `ask_user` call is waiting on (spec 10 §1)."
  @spec answer(String.t(), String.t(), [map()]) :: :ok
  def answer(run_id, node_id, answers), do: RunServer.answer(run_id, node_id, answers)

  @spec resolve_approval(String.t(), String.t(), :approve | :deny | :always) :: :ok
  def resolve_approval(run_id, node_id, decision) when decision in [:approve, :deny, :always] do
    RunServer.resolve_approval(run_id, node_id, decision)
  end

  @doc "Ids of the runs of this conversation that are currently running."
  @spec running_runs(String.t()) :: [String.t()]
  def running_runs(conversation_id) do
    Registry.select(SwarmCode.Domain.Registry, [
      {{{:run, :"$1"}, :_, {:"$2", :_}}, [{:==, :"$2", conversation_id}], [:"$1"]}
    ])
  end

  @doc "Ids of every running run (all conversations)."
  @spec running_run_ids() :: [String.t()]
  def running_run_ids do
    Registry.select(SwarmCode.Domain.Registry, [{{{:run, :"$1"}, :_, :_}, [], [:"$1"]}])
  end

  @spec chat_running?(String.t()) :: boolean()
  def chat_running?(conversation_id), do: chat_run_ids(conversation_id) != []

  @doc "Ids of the running chat runs of this conversation."
  @spec chat_run_ids(String.t()) :: [String.t()]
  def chat_run_ids(conversation_id) do
    Registry.select(SwarmCode.Domain.Registry, [
      {{{:run, :"$1"}, :_, {:"$2", :"$3"}}, [{:==, :"$2", conversation_id}, {:==, :"$3", "chat"}],
       [:"$1"]}
    ])
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:microsecond)
end
