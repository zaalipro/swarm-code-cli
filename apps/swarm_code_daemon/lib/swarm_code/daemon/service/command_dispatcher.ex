defmodule SwarmCode.Daemon.Service.CommandDispatcher do
  @moduledoc """
  Executes slash-command intents against the existing persisted Domain APIs.
  Never starts a Repo or bypasses its production gate. Selection/navigation
  results ask the presenter to act; they do not claim a selection was performed.
  """
  require Logger
  alias SwarmCode.Commands
  alias SwarmCode.Daemon.Service.SessionConfiguration

  alias SwarmCode.Domain.{
    Agents,
    AtomicFile,
    Conversations,
    Engine,
    Attachments,
    ProjectConfig,
    Projects,
    Providers,
    Repo,
    Research,
    Settings,
    Workflows
  }

  alias SwarmCode.Domain.Conversations.{Conversation, Export, Run}
  alias SwarmCode.Daemon.Service.Rewind
  import Ecto.Query, only: [from: 2]

  @approval_modes ["read_only", "auto", "full_access"]
  @allowed [:custom, :workflows, :efforts, :swarm_efforts, :attachments, :research_ids]
  @errors [
    :invalid_command,
    :unknown_command,
    :missing_argument,
    :invalid_argument,
    :unexpected_argument,
    :invalid_effort,
    :invalid_budget,
    :invalid_metadata,
    :invalid_options,
    :input_too_large,
    :expansion_too_large,
    :unknown_workflow,
    :not_configured,
    :database_busy,
    :not_found,
    :not_resumable,
    :not_running,
    :not_paused,
    :budget_too_low,
    :nothing_to_compact,
    :nothing_to_stop,
    :nothing_to_undo,
    :not_attachable,
    :conversation_not_found,
    :invalid_request,
    :ambiguous_run,
    :unknown_model,
    :ambiguous_conversation,
    :client_only
  ]
  # cli021 int (K3): the headless launcher's sentence (`Release.Headless`) for
  # a workflow that `ncode -p --approval auto|full` launches in an untrusted
  # project (the launcher refuses such a session up front; this is the
  # launch's own check).
  @untrusted_approval "--approval auto and full need a trusted project. " <>
                        "Run /trust in ncode first, or use --approval read-only."
  # A report is read in a dialog: bounded like the goal report.
  @report_bytes 60_000
  @review_prompt "Review the current uncommitted changes: call git_status and git_diff, then " <>
                   "report problems with file:line references ordered by severity, and suggest " <>
                   "concrete fixes. Do not modify files."

  @spec dispatch(term(), term(), keyword()) :: {:ok, map()} | {:error, atom()}
  def dispatch(conversation_id, text, opts \\ []) do
    cond do
      not valid_options?(opts) or not valid_text?(text, 262_144) or
          not valid_text?(conversation_id, 256) ->
        {:error, :invalid_request}

      true ->
        dispatch_known(conversation_id, text, opts)
    end
  end

  @doc false
  # cli020 lane C: runs a command map as `Commands.parse/2` returns it. The
  # tests of the actions E3's parser adds (/rename, /delete, /fork, /undo,
  # bare /effort) call this until that parser lands.
  @spec execute_parsed(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute_parsed(conversation_id, %{action: action} = command, opts \\ [])
      when is_binary(conversation_id) and is_atom(action) do
    case Conversations.get(conversation_id) do
      nil -> {:error, :conversation_not_found}
      conv -> conv |> execute(command, opts) |> normalize_result()
    end
  end

  defp dispatch_known(conversation_id, text, opts) do
    case Conversations.get(conversation_id) do
      nil ->
        {:error, :conversation_not_found}

      conv ->
        parser_opts = parser_opts(conv, opts)

        case Commands.parse(text, parser_opts) do
          {:ok, command} ->
            execute(
              conv,
              command,
              opts
              |> Keyword.put(:resolved_workflows, parser_opts[:workflows])
              |> Keyword.put(:resolved_custom, parser_opts[:custom])
            )
            |> normalize_result()

          {:error, %{type: type}} ->
            failure(type)
        end
    end
  end

  defp parser_opts(conv, opts) do
    [
      custom:
        Keyword.get_lazy(opts, :custom, fn -> SwarmCode.Domain.Commands.list(conv.project) end),
      workflows: Keyword.get_lazy(opts, :workflows, fn -> Workflows.list(conv.project) end),
      efforts: Keyword.get_lazy(opts, :efforts, fn -> efforts(conv, :chat) end),
      swarm_efforts: Keyword.get_lazy(opts, :swarm_efforts, fn -> efforts(conv, :swarm) end)
    ]
  end

  @doc """
  cli020 C17: the effort levels `/effort` (`:chat`) or `/swarm_effort`
  (`:swarm`) accept for `conv` (its effective model's, else the classic ones).
  The workspace carries them for the terminal's effort picker.
  """
  @spec efforts(map(), :chat | :swarm) :: [String.t()]
  def efforts(conv, kind) do
    levels =
      case Providers.effective_model(conv, kind) do
        {:ok, %{provider: provider, model: model}} -> Settings.efforts(provider, model)
        _ -> Settings.efforts()
      end

    Enum.map(levels, &elem(&1, 0))
  end

  @doc false
  @spec resumable_run([map()]) :: map() | nil
  def resumable_run(runs) when is_list(runs) do
    continued = continued_ids(runs)

    Enum.find(runs, fn run ->
      run.kind in ["chat", "swarm"] and run.status in ["stopped", "failed", "interrupted"] and
        is_nil(Map.get(run, :superseded_at)) and not MapSet.member?(continued, run.id)
    end)
  end

  @doc false
  # The ids of the runs that have a continuation `Conversations.Writes` would
  # refuse a second time: one that runs, waits or finished, or has a root node.
  # A continuation compensated to `failed` at its start (no root node) does not.
  @spec continued_ids([map()]) :: MapSet.t()
  def continued_ids(runs) do
    for run <- runs,
        is_binary(Map.get(run, :resumed_from_run_id)),
        run.status in ["running", "paused", "waiting_user", "done"] or
          not is_nil(Map.get(run, :root_node_id)),
        into: MapSet.new(),
        do: run.resumed_from_run_id
  end

  @doc false
  # The map `Workflows.launch/1` takes. cli021 P2: the session's
  # `ncode -p --approval` mode rides along (desktop pass 74 K3 makes the launch
  # carry it to the run; until then the key is ignored and a workflow run
  # decides in the project's mode).
  def workflow_launch_attrs(conv, definition, cmd, message_id, opts) do
    Map.merge(
      %{
        conversation: conv,
        project: conv.project,
        definition: definition,
        args: cmd.inputs,
        rest: cmd.input,
        created_by: "user",
        launch_message_id: message_id
      },
      Map.new(approval(opts))
    )
  end

  defp execute(conv, %{kind: :custom} = cmd, opts) do
    with {:ok, conv} <- custom_mode(conv, cmd.mode) do
      result =
        if cmd.action == :start_swarm,
          do: Engine.start_swarm(SessionConfiguration.overlay(conv), cmd.prompt, approval(opts)),
          else:
            Engine.start_chat_turn(
              SessionConfiguration.overlay(conv),
              cmd.prompt,
              attachments(opts),
              [research_ids: research_ids(opts)] ++ approval(opts)
            )

      started(conv, cmd.name, result)
    end
  end

  defp execute(conv, %{action: :start_swarm} = cmd, opts),
    do:
      started(
        conv,
        cmd.name,
        Engine.start_swarm(SessionConfiguration.overlay(conv), cmd.task, approval(opts))
      )

  defp execute(conv, %{action: :pursue_goal} = cmd, opts) do
    mode = if cmd.execution == :swarm, do: "swarm", else: "chat"
    message = if mode == "swarm", do: "/swarm /goal " <> cmd.text, else: "/goal " <> cmd.text

    with {:ok, conv} <- persist_mode(conv, :build),
         {:ok, goal} <- Conversations.add_goal(conv, cmd.text, mode) do
      conv = Conversations.get!(conv.id)

      args = [
        goal_id: goal.id,
        message: message,
        prompt: goal.text <> "\n\n" <> Engine.goal_framing()
      ]

      result =
        cond do
          mode == "swarm" ->
            Engine.start_swarm(
              SessionConfiguration.overlay(conv),
              goal.text,
              args ++ approval(opts)
            )

          approval(opts) == [] ->
            Engine.start_goal_turn(SessionConfiguration.overlay(conv), goal.text, args)

          # `start_goal_turn/3` does not forward `approval_mode:`; this is the
          # chat turn it starts, with the session's mode.
          true ->
            Engine.start_chat_turn(
              SessionConfiguration.overlay(conv),
              message,
              [],
              [prompt: args[:prompt], goal_id: goal.id] ++ approval(opts)
            )
        end

      case started(conv, cmd.name, result) do
        {:ok, result} -> {:ok, Map.put(result, :goal_id, goal.id)}
        error -> error
      end
    end
  end

  defp execute(conv, %{action: :show_goal} = cmd, _) do
    goal =
      case Conversations.newest_goal(conv.id) do
        nil ->
          nil

        row ->
          %{
            id: row.id,
            text: row.text,
            status: row.status,
            mode: row.mode,
            run_id: row.run_id
          }
      end

    result(conv, cmd.name, :select, %{subject: :goal, goal: goal})
  end

  defp execute(conv, %{action: :toggle_mode, mode: mode} = cmd, _) do
    mode =
      case mode do
        :plan -> if current_mode(conv) == :plan, do: :build, else: :plan
        :ultra -> if conv.ultra, do: :build, else: :ultra
      end

    set_mode(conv, cmd.name, mode)
  end

  defp execute(conv, %{action: :set_mode, mode: mode} = cmd, _),
    do: set_mode(conv, cmd.name, mode)

  defp execute(conv, %{action: :disable_workflow_authoring} = cmd, _) do
    fields = %{authoring_workflow: false}

    with {:ok, _} <- Conversations.update(conv, fields),
         do: result(conv, cmd.name, :updated, %{fields: fields})
  end

  defp execute(conv, %{action: :set_effort} = cmd, _) do
    field = if cmd.target == :chat, do: :effort, else: :swarm_effort
    fields = %{field => Atom.to_string(cmd.effort)}

    with {:ok, _} <- Conversations.update(conv, fields),
         do: result(conv, cmd.name, :updated, %{fields: fields, field: field, value: cmd.effort})
  end

  # cli021 P1 (desktop spec 70 D4): `/profile <name>` applies a profile of the
  # project's `.swarm_code/config.json` (its effort, swarm_effort, model and
  # swarm_model) to this conversation; bare, it lists the names. Every answer is
  # a sentence for the notice line, as on the desktop.
  defp execute(conv, %{action: :apply_profile} = cmd, _) do
    profiles = profiles(conv)
    names = profiles |> Map.keys() |> Enum.sort() |> Enum.join(", ")

    cond do
      profiles == %{} ->
        profile_said(conv, cmd, "No profiles defined — add them to .swarm_code/config.json")

      cmd.profile == nil ->
        profile_said(conv, cmd, "Available profiles: " <> names)

      not Map.has_key?(profiles, cmd.profile) ->
        profile_said(conv, cmd, ~s(Unknown profile "#{cmd.profile}" — available: #{names}))

      true ->
        apply_profile(conv, cmd, Map.fetch!(profiles, cmd.profile))
    end
  end

  # `/model` and `/swarm_model` take either `<provider_id>|<model>` or a bare
  # model id. A bare id that several providers list goes to the provider the
  # conversation already uses for that role, then the settings default, then
  # the first provider by name; an id nobody lists is refused rather than
  # stored, so the header never names a model no provider can serve.
  defp execute(conv, %{action: :set_model} = cmd, _) do
    case resolve_model(conv, cmd.target, cmd.model) do
      {:ok, provider_id, model} ->
        {id_field, model_field} =
          if cmd.target == :chat,
            do: {:chat_provider_id, :chat_model},
            else: {:swarm_provider_id, :swarm_model}

        fields = %{id_field => provider_id, model_field => model}

        # An explicit `/model` wins over the launcher's `--model` from here on
        # (the override lives only in memory, pass70 D3).
        with {:ok, _} <- Conversations.update(conv, fields) do
          SessionConfiguration.clear_override()

          result(conv, cmd.name, :updated, %{
            fields: fields,
            field: model_field,
            value: model
          })
        end

      :error ->
        {:error, :unknown_model}
    end
  end

  # pass73 T3/T8: `/plan <task>` plans this task now, as a run of its own
  # beside the live ones. The conversation keeps its mode: a run remembers the
  # mode it ran in (Spec 50 §4), so the planner's gate asks this run.
  defp execute(conv, %{action: :start_turn, mode: :plan} = cmd, opts) do
    started(
      conv,
      cmd.name,
      Engine.start_chat_turn(
        %{SessionConfiguration.overlay(conv) | mode: "plan"},
        cmd.task,
        attachments(opts),
        [research_ids: research_ids(opts)] ++ approval(opts)
      )
    )
  end

  # cli020 C7 (ux-live-9, Q7): `/consensus <task>` judges this one run and
  # leaves the conversation's mode as it was: the engine reads `consensus`
  # from the struct it is given, so the overlay sets in memory exactly what
  # `mode_fields(:consensus)` would persist. Bare `/consensus` stays sticky.
  defp execute(conv, %{action: :start_turn, mode: :consensus} = cmd, opts) do
    started(
      conv,
      cmd.name,
      Engine.start_chat_turn(
        %{
          SessionConfiguration.overlay(conv)
          | mode: "build",
            consensus: true,
            ultra: false,
            authoring_workflow: false
        },
        cmd.task,
        attachments(opts),
        [research_ids: research_ids(opts)] ++ approval(opts)
      )
    )
  end

  defp execute(conv, %{action: :author_workflow} = cmd, opts) do
    with {:ok, conv} <- persist_mode(conv, :workflow) do
      started(
        conv,
        cmd.name,
        Engine.start_chat_turn(
          SessionConfiguration.overlay(conv),
          "/create-workflow " <> cmd.prompt,
          attachments(opts),
          [prompt: cmd.prompt, command: :create_workflow, research_ids: research_ids(opts)] ++
            approval(opts)
        )
      )
    end
  end

  defp execute(conv, %{action: :review_changes} = cmd, opts),
    do:
      started(
        conv,
        cmd.name,
        Engine.start_chat_turn(
          SessionConfiguration.overlay(conv),
          @review_prompt,
          attachments(opts),
          [research_ids: research_ids(opts)] ++ approval(opts)
        )
      )

  defp execute(conv, %{action: :compact} = cmd, _),
    do:
      started(conv, cmd.name, Engine.start_compact(SessionConfiguration.overlay(conv), cmd.focus))

  defp execute(conv, %{action: :stop_all} = cmd, _) do
    active = Engine.running_runs(conv.id)

    if active == [] do
      {:error, :nothing_to_stop}
    else
      with :ok <- Engine.stop_all(conv.id),
           do: result(conv, cmd.name, :stopped, %{run_ids: Enum.take(active, 200)})
    end
  end

  # cli021 P3 (desktop spec 74 BUGS-56): the newest run that can still be
  # resumed; one that already has a continuation or that a rewind folded away
  # is not offered again.
  defp execute(conv, %{action: :resume_last} = cmd, _) do
    run = resumable_run(Conversations.list_runs(conv.id))
    if run, do: started(conv, cmd.name, Engine.resume_run(run)), else: {:error, :not_resumable}
  end

  # cli020 C16 (decision 4h): the turns the conversation can be rewound to
  # (`Rewind.turns/1`, as `rewind.turns` answers them).
  defp execute(conv, %{action: :select_rewind} = cmd, _) do
    items =
      Enum.map(Rewind.turns(conv.id), fn turn ->
        %{
          message_id: turn.message_id,
          run_id: turn.run_id,
          turn: turn.turn,
          prompt: clip(turn.prompt),
          file_count: turn.files
        }
      end)

    result(conv, cmd.name, :select, %{subject: :rewind, options: items})
  end

  # `/undo`: rewind the newest turn, its messages and its files.
  defp execute(conv, %{action: :undo_turn} = cmd, _) do
    case Rewind.newest(conv.id) do
      nil -> {:error, :nothing_to_undo}
      message_id -> result(conv, cmd.name, :undo, %{message_id: message_id})
    end
  end

  defp execute(conv, %{action: :open_workflows} = cmd, _),
    do: result(conv, cmd.name, :navigate, %{destination: :workflows})

  defp execute(conv, %{action: :select_research} = cmd, _) do
    items =
      Research.attachable()
      |> Enum.take(200)
      |> Enum.map(fn row ->
        %{id: row.id, title: clip(row.title || row.question), status: row.status}
      end)

    result(conv, cmd.name, :select, %{subject: :research, options: items})
  end

  defp execute(conv, %{action: :attach_research} = cmd, _) do
    case research(cmd.research) do
      nil ->
        {:error, :not_found}

      row ->
        if Research.attachable?(row),
          do:
            result(conv, cmd.name, :attached, %{
              research_id: row.id,
              attachment_target: :next_message
            }),
          else: {:error, :not_attachable}
    end
  end

  defp execute(conv, %{action: :attach_file} = cmd, opts) do
    path = Path.expand(cmd.path, conv.project.root_path)

    with {:ok, root} <- SwarmCode.Domain.Tools.Path.real_path(conv.project.root_path),
         true <- length(attachments(opts)) < Attachments.max_per_message(),
         {:ok, real} <- SwarmCode.Domain.Tools.Path.real_path(path),
         true <- SwarmCode.Domain.Tools.Path.confined?(root, real),
         mime when mime in ["image/png", "image/jpeg", "image/gif", "image/webp"] <-
           mime_for(real),
         {:ok, binary} <- read_image(root, real),
         {:ok, attachment} <-
           Attachments.store(Path.basename(real), mime, Base.encode64(binary)) do
      result(conv, cmd.name, :attachment_staged, %{attachment: Map.drop(attachment, ["path"])})
    else
      _ -> {:error, :invalid_argument}
    end
  end

  defp execute(conv, %{action: :launch_workflow} = cmd, opts) do
    definition =
      Enum.find(opts[:resolved_workflows], fn
        %SwarmCode.Domain.Workflows.Definition{name: name} -> name == cmd.workflow
        _ -> false
      end)

    with %SwarmCode.Domain.Workflows.Definition{} = definition <- definition,
         {:ok, _} <- Workflows.cast_args(definition.meta, cmd.inputs, cmd.input),
         # cli021 int (K3): the launch checks the session's `--approval` mode
         # too; checked here first, so a refusal writes no message or title.
         :ok <- Engine.check_approval_mode(conv.project, Keyword.get(opts, :approval_mode)),
         {:ok, conv} <- Conversations.set_title_from(conv, "/" <> cmd.workflow),
         {:ok, message} <-
           Conversations.create_message(%{
             conversation_id: conv.id,
             role: "user",
             content: String.trim("/" <> cmd.workflow <> " " <> cmd.arguments)
           }) do
      started(
        conv,
        cmd.name,
        Workflows.launch(workflow_launch_attrs(conv, definition, cmd, message.id, opts))
      )
    else
      nil -> {:error, :unknown_workflow}
      {:error, :untrusted_project} -> {:error, {:untrusted_project, @untrusted_approval}}
      {:error, :invalid_approval_mode} -> {:error, :invalid_options}
      {:error, _} -> {:error, :invalid_workflow_arguments}
      _ -> {:error, :invalid_metadata}
    end
  end

  defp execute(conv, %{action: :control_workflow} = cmd, _) do
    with {:ok, wf} <- workflow_run(conv, cmd.run),
         :ok <-
           Workflows.control(
             wf.run_id,
             cmd.control,
             if(cmd[:budget], do: [budget: cmd.budget], else: [])
           ) do
      result(conv, cmd.name, :updated, %{control: cmd.control, run_id: wf.run_id})
    end
  end

  defp execute(conv, %{action: :save_workflow} = cmd, _) do
    with {:ok, wf} <- workflow_run(conv, cmd.run),
         {:ok, _} <-
           Workflows.save_run_as(wf.run_id, conv.project, Atom.to_string(cmd.scope), cmd.workflow) do
      result(conv, cmd.name, :saved, %{
        workflow: cmd.workflow,
        scope: cmd.scope,
        run_id: wf.run_id
      })
    end
  end

  # pass70 C7: the session basics. `/new`, `/clear` and `/resume <which>`
  # answer `:conversation` — the persisted service switches to it; `/resume`
  # alone, `/diff` ask the client to navigate; the rest are reports.
  defp execute(conv, %{action: :new_conversation} = cmd, _) do
    with {:ok, new} <- Conversations.create(conv.project_id),
         do: result(conv, cmd.name, :conversation, %{conversation_id: new.id, created: true})
  end

  # cli020 C17: bare /effort and /worker_effort (E3's `:show_effort`) say the
  # current level and the ones accepted here (cli021 B2: the worker slot's
  # command is /worker_effort; /swarm_effort is its hidden alias).
  defp execute(conv, %{action: :show_effort} = cmd, _) do
    {words, field, command} =
      case Map.get(cmd, :target, :chat) do
        :swarm -> {"Worker effort", :swarm_effort, "/worker_effort"}
        _ -> {"Effort", :effort, "/effort"}
      end

    kind = if field == :swarm_effort, do: :swarm, else: :chat
    model = if kind == :swarm, do: "worker model", else: "chat model"
    current = Map.get(conv, field) || "default"
    levels = Enum.join(efforts(conv, kind), ", ")

    result(conv, cmd.name, :report, %{
      title: "Effort",
      text: "#{words}: #{current} (#{model}). Levels: #{levels}. #{command} <level> sets it."
    })
  end

  # cli020 C11 (tui-code-14): /rename <title>, /delete, /fork.
  defp execute(conv, %{action: :rename_conversation} = cmd, _) do
    title = cmd |> Map.get(:title, "") |> to_string() |> String.trim()

    if title != "" and String.length(title) <= 200 do
      with {:ok, renamed} <- Conversations.rename(conv, title),
           do: result(conv, cmd.name, :renamed, %{title: renamed.title})
    else
      {:error, :invalid_argument}
    end
  end

  # Refused while any run of it is live (stop it first); the answer is the
  # conversation the service switches to: the project's newest other one, or
  # a new one when none is left.
  defp execute(conv, %{action: :delete_conversation} = cmd, _) do
    if Engine.running_runs(conv.id) != [] do
      {:error, {:busy, "Stop the running work first, then delete this conversation."}}
    else
      with {:ok, _} <- Conversations.delete(conv) do
        case Enum.find(Conversations.list_for_project(conv.project_id), &(&1.id != conv.id)) do
          nil ->
            with {:ok, new} <- Conversations.create(conv.project_id),
                 do:
                   result(conv, cmd.name, :conversation, %{conversation_id: new.id, created: true})

          other ->
            result(conv, cmd.name, :conversation, %{conversation_id: other.id, created: false})
        end
      end
    end
  end

  # The whole conversation (every message `fork/2` copies) into a new one.
  defp execute(conv, %{action: :fork_conversation} = cmd, _) do
    newest =
      Repo.one(
        from(m in SwarmCode.Domain.Conversations.Message,
          where: m.conversation_id == ^conv.id,
          select: max(m.position)
        )
      ) || 0

    with {:ok, fork} <- Conversations.fork(conv, newest + 1),
         do: result(conv, cmd.name, :conversation, %{conversation_id: fork.id, created: true})
  end

  defp execute(conv, %{action: :select_conversation} = cmd, _),
    do: result(conv, cmd.name, :navigate, %{destination: :conversations})

  defp execute(conv, %{action: :open_conversation} = cmd, _) do
    with {:ok, target} <- find_conversation(conv, cmd.conversation),
         do: result(conv, cmd.name, :conversation, %{conversation_id: target, created: false})
  end

  defp execute(conv, %{action: :show_changes} = cmd, _),
    do: result(conv, cmd.name, :navigate, %{destination: :changes})

  defp execute(conv, %{action: :show_approval} = cmd, _) do
    project = Projects.get!(conv.project_id)
    families = Map.get(project, :auto_approve_prefixes) || []

    text =
      [
        "Approval mode: " <> mode_words(project.approval_mode),
        "Trusted: " <> if(Projects.trusted?(project), do: "yes", else: "no"),
        "",
        mode_meaning(project.approval_mode),
        if(families != [],
          do:
            "\nAlways allowed: " <>
              Enum.map_join(Enum.take(families, 50), ", ", &("`" <> &1 <> "`"))
        ),
        "\nChange it with /approval read-only, /approval auto or /approval full."
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    report(conv, cmd.name, "Approvals", text)
  end

  # cli020 fix S3: a mode picked by hand marks the project trusted, as the
  # desktop's `set_approval_mode` does, and the notice says so.
  defp execute(conv, %{action: :set_approval} = cmd, _) do
    mode = Atom.to_string(cmd.approval_mode)

    with {:ok, project, text} <-
           SwarmCode.Daemon.Service.ApprovalPick.pick(Projects.get!(conv.project_id), mode),
         do: result(conv, cmd.name, :project, %{project_id: project.id, text: text})
  end

  defp execute(conv, %{action: :trust_project} = cmd, _) do
    with {:ok, project} <- Projects.trust(Projects.get!(conv.project_id)),
         do:
           result(conv, cmd.name, :project, %{
             project_id: project.id,
             text: "Project trusted; approval mode " <> mode_words(project.approval_mode)
           })
  end

  defp execute(conv, %{action: :show_cost} = cmd, _) do
    rows =
      Repo.all(
        from(r in Run,
          where: r.conversation_id == ^conv.id,
          group_by: r.model,
          order_by: [desc: sum(r.cost_usd)],
          limit: 50,
          select:
            {r.model, count(r.id), sum(r.tokens_in), sum(r.tokens_out), sum(r.cost_usd),
             count(r.cost_usd)}
        )
      )

    # cli020 C18: a model none of whose runs has a price has no cost (nil), not $0.
    rows =
      Enum.map(rows, fn {model, n, i, o, c, priced} ->
        {model, n, i, o, if(priced > 0, do: c || 0.0)}
      end)

    {runs, tokens_in, tokens_out, cost} =
      Enum.reduce(rows, {0, 0, 0, 0.0}, fn {_, n, i, o, c}, {rn, ri, ro, rc} ->
        {rn + n, ri + (i || 0), ro + (o || 0), rc + (c || 0.0)}
      end)

    lines =
      Enum.map(rows, fn {model, n, i, o, c} ->
        "- #{model || "unknown model"}: #{n} run#{if n == 1, do: "", else: "s"}, " <>
          "#{tokens(i)} in, #{tokens(o)} out, #{if c, do: usd(c), else: "price unknown"}"
      end)

    text =
      Enum.join(
        [
          "#{usd(cost)} for #{runs} run#{if runs == 1, do: "", else: "s"}: " <>
            "#{tokens(tokens_in)} tokens in, #{tokens(tokens_out)} out."
          | if(lines == [], do: [], else: ["" | lines])
        ],
        "\n"
      )

    # cli020 C18 (ux-live-19): the same per-model rows for the terminal to
    # draw, then the total (`name: "Total"`); `--plain` keeps the text.
    model_rows =
      Enum.map(rows, fn {model, n, i, o, c} ->
        %{
          model: model && clip(model),
          runs: n,
          tokens_in: i || 0,
          tokens_out: o || 0,
          cost_usd: c
        }
      end)

    total = %{
      name: "Total",
      runs: runs,
      tokens_in: tokens_in,
      tokens_out: tokens_out,
      cost_usd: cost
    }

    with {:ok, answer} <- report(conv, cmd.name, "Cost of this conversation", text),
         do: {:ok, Map.merge(answer, %{subject: :cost, rows: model_rows ++ [total]})}
  end

  # cli020 C8 (tui-code-11): this project's conversations only, filtered in
  # SQL before the limit (another project's hits no longer fill every slot),
  # answered as rows the terminal draws as a picker (Enter resumes one).
  defp execute(conv, %{action: :search} = cmd, _) do
    rows =
      conv.project_id
      |> SwarmCode.Daemon.Service.MessageSearch.conversations(cmd.query, 50)
      |> Enum.map(fn hit ->
        %{
          conversation_id: hit.conversation_id,
          title: clip(hit.title),
          snippet: clip(hit.snippet),
          at: search_at(hit.updated_at)
        }
      end)

    result(conv, cmd.name, :select, %{subject: :search, query: clip(cmd.query), options: rows})
  end

  defp execute(conv, %{action: :export} = cmd, _) do
    with {:ok, root, path} <- export_target(conv, cmd.path),
         :ok <- AtomicFile.replace(root, path, Export.to_markdown(conv.id)) do
      report(conv, cmd.name, "Exported", "Wrote this conversation to\n" <> path)
    else
      {:error, reason} when reason in @errors -> {:error, reason}
      _ -> {:error, :invalid_argument}
    end
  end

  # cli020 C9 (ux-live-7): the agent definitions as rows (name, source,
  # model, description) the terminal draws; the text, for `--plain`, has no
  # Markdown.
  defp execute(conv, %{action: :list_agents} = cmd, _) do
    rows =
      Agents.list(conv.project.root_path)
      |> Enum.take(50)
      |> Enum.map(fn agent ->
        %{
          name: clip(agent.name),
          source: clip(to_string(agent.source)),
          model: if(agent.model, do: clip(agent.model)),
          description: if(agent.description, do: clip(agent.description))
        }
      end)

    text =
      case rows do
        [] ->
          "No agent definitions. Add markdown files to .swarm_code/agents/ in the project."

        _ ->
          Enum.map_join(rows, "\n", fn row ->
            "- #{row.name} (#{row.source})" <>
              if(row.model, do: " · " <> row.model, else: "") <>
              if(row.description, do: " — " <> row.description, else: "")
          end)
      end

    result(conv, cmd.name, :report, %{title: "Agents", text: text, subject: :agents, rows: rows})
  end

  defp execute(conv, %{action: :help} = cmd, opts) do
    entries =
      Commands.catalogue("/",
        custom: opts[:resolved_custom] || [],
        workflows: opts[:resolved_workflows] || []
      )

    text =
      Enum.map_join(entries, "\n", fn entry ->
        args = if entry.args in [nil, ""], do: "", else: " " <> entry.args
        "/#{entry.name}#{args} — #{entry.desc}"
      end)

    report(conv, cmd.name, "Commands", text)
  end

  # Leaving is the terminal's to do; a service cannot quit its client.
  defp execute(_conv, %{action: :quit}, _), do: {:error, :client_only}

  defp report(conv, command, title, text) do
    text = if byte_size(text) > @report_bytes, do: clip_bytes(text, @report_bytes), else: text
    result(conv, command, :report, %{title: title, text: text})
  end

  # Within the open project only: a full id, an id prefix (4+ characters) or
  # words of a title, newest first.
  defp find_conversation(conv, target) do
    needle = String.downcase(String.trim(target))

    candidates =
      Repo.all(
        from(c in Conversation,
          where: c.project_id == ^conv.project_id and is_nil(c.research_id),
          order_by: [desc: c.updated_at, desc: c.id],
          limit: 2_000,
          select: {c.id, c.title}
        )
      )

    by_id =
      Enum.filter(candidates, fn {id, _} ->
        id == needle or (byte_size(needle) >= 4 and String.starts_with?(id, needle))
      end)

    matches =
      if by_id != [],
        do: by_id,
        else:
          Enum.filter(candidates, fn {_, title} ->
            String.contains?(String.downcase(title || ""), needle)
          end)

    case matches do
      [{id, _}] -> {:ok, id}
      [] -> {:error, :not_found}
      [{id, title} | rest] -> exact_title(id, title, rest, needle)
    end
  end

  defp exact_title(id, title, rest, needle) do
    exact = Enum.filter([{id, title} | rest], fn {_, t} -> String.downcase(t || "") == needle end)

    case exact do
      [{id, _}] -> {:ok, id}
      _ -> {:error, :ambiguous_conversation}
    end
  end

  # No file named: `~/Downloads` (or the `:export_dir` setting) when there is
  # one, else the project root, as `<title>_<date>.md`, never over an existing
  # file. A named file is inside the project.
  defp export_target(conv, nil) do
    downloads =
      Application.get_env(:swarm_code_daemon, :export_dir) ||
        if home = System.user_home(), do: Path.join(home, "Downloads")

    root = if downloads && File.dir?(downloads), do: downloads, else: conv.project.root_path
    {:ok, root, unique(Path.join(root, export_name(conv)))}
  end

  defp export_target(conv, path) do
    root = conv.project.root_path
    expanded = Path.expand(path, root)
    expanded = if File.dir?(expanded), do: Path.join(expanded, export_name(conv)), else: expanded

    if SwarmCode.Domain.Tools.Path.confined?(root, Path.dirname(expanded)) and
         Path.extname(expanded) in [".md", ".markdown", ".txt"],
       do: {:ok, root, unique(expanded)},
       else: {:error, :invalid_argument}
  end

  defp export_name(conv) do
    slug =
      (conv.title || "untitled")
      |> String.downcase()
      |> String.replace(~r/[^\w]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 60)

    "#{if slug == "", do: "conversation", else: slug}_#{Date.to_iso8601(Date.utc_today())}.md"
  end

  defp unique(path, n \\ 1) do
    candidate =
      if n == 1,
        do: path,
        else: Path.rootname(path) <> "-#{n}" <> Path.extname(path)

    if File.exists?(candidate) and n < 100, do: unique(path, n + 1), else: candidate
  end

  defp mode_words("read_only"), do: "read-only"
  defp mode_words("full_access"), do: "full access"
  defp mode_words(mode), do: to_string(mode)

  defp mode_meaning("read_only"),
    do: "Agents read and search; every write and command waits for you."

  defp mode_meaning("auto"),
    do: "Agents edit files; commands that are not read-only wait for you."

  defp mode_meaning("full_access"),
    do: "Agents edit and run commands without asking; dangerous commands still wait."

  defp mode_meaning(_), do: ""

  defp tokens(nil), do: "0"

  defp tokens(n) when n >= 1_000_000,
    do: :erlang.float_to_binary(n / 1_000_000, decimals: 1) <> "M"

  defp tokens(n) when n >= 1_000, do: :erlang.float_to_binary(n / 1_000, decimals: 1) <> "k"
  defp tokens(n), do: Integer.to_string(n)

  defp usd(nil), do: "$0.00"
  defp usd(c) when c < 0.01 and c > 0, do: "<$0.01"
  defp usd(c), do: "$" <> :erlang.float_to_binary(c * 1.0, decimals: 2)

  defp clip_bytes(text, max) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn g, {acc, size} ->
      if size + byte_size(g) <= max - 3,
        do: {:cont, {[g | acc], size + byte_size(g)}},
        else: {:halt, {acc, size}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
    |> Kernel.<>("…")
  end

  defp profiles(%{project: %{root_path: root}}) when is_binary(root) do
    case ProjectConfig.load(root) do
      {:ok, %{profiles: profiles}} when is_map(profiles) -> profiles
      _ -> %{}
    end
  end

  defp profiles(_conv), do: %{}

  defp profile_said(conv, cmd, text),
    do: result(conv, cmd.name, :profile, %{text: text, applied: false})

  # The fields a profile names are applied one by one: a model no provider
  # lists, or an effort the (new) model does not offer, is skipped and said,
  # the rest still applies. Models first, so the efforts are checked against
  # the models the conversation will have.
  defp apply_profile(conv, cmd, profile) do
    {models, model_skips} =
      Enum.reduce([{:chat, "model"}, {:swarm, "swarm_model"}], {%{}, []}, fn {target, key}, acc ->
        profile_model(conv, target, key, profile[key], acc)
      end)

    planned = struct(conv, models)

    {efforts, effort_skips} =
      Enum.reduce(
        [{:chat, :effort, "effort"}, {:swarm, :swarm_effort, "swarm_effort"}],
        {%{}, []},
        fn
          {target, field, key}, acc ->
            profile_effort(planned, target, field, key, profile[key], acc)
        end
      )

    fields = Map.merge(models, efforts)

    with {:ok, _} <- if(fields == %{}, do: {:ok, conv}, else: Conversations.update(conv, fields)) do
      # An explicit model pick wins over the launcher's `--model` from here on.
      if models != %{}, do: SessionConfiguration.clear_override()
      skipped = Enum.reverse(effort_skips) ++ Enum.reverse(model_skips)
      said = "Switched to profile: #{cmd.profile}"

      said =
        if skipped == [], do: said, else: said <> " · skipped " <> Enum.join(skipped, ", ")

      result(conv, cmd.name, :profile, %{text: said, applied: true, fields: fields})
    end
  end

  defp profile_model(_conv, _target, _key, value, acc) when value in [nil, ""], do: acc

  defp profile_model(conv, target, key, value, {fields, skips}) when is_binary(value) do
    {id_field, model_field} =
      if target == :chat,
        do: {:chat_provider_id, :chat_model},
        else: {:swarm_provider_id, :swarm_model}

    case resolve_model(conv, target, value) do
      {:ok, provider_id, model} ->
        {Map.merge(fields, %{id_field => provider_id, model_field => model}), skips}

      :error ->
        {fields, ["#{key} #{value} (no provider lists it)" | skips]}
    end
  end

  defp profile_model(_conv, _target, _key, _value, acc), do: acc

  defp profile_effort(_conv, _target, _field, _key, value, acc) when value in [nil, ""], do: acc

  defp profile_effort(conv, target, field, key, value, {fields, skips}) when is_binary(value) do
    if value in efforts(conv, target),
      do: {Map.put(fields, field, value), skips},
      else: {fields, ["#{key} #{value} (not offered)" | skips]}
  end

  defp profile_effort(_conv, _target, _field, _key, _value, acc), do: acc

  defp resolve_model(conv, target, arg) do
    providers = Providers.list()
    lists? = fn provider, model -> model in (provider.models || []) end

    exact =
      case Providers.parse_option(arg) do
        {provider_id, model} ->
          case Enum.find(providers, &(&1.id == provider_id)) do
            %{} = provider -> if lists?.(provider, model), do: {provider, model}
            nil -> nil
          end

        nil ->
          nil
      end

    case exact do
      {provider, model} ->
        {:ok, provider.id, model}

      nil ->
        case Enum.filter(providers, &lists?.(&1, arg)) do
          [] -> :error
          [provider] -> {:ok, provider.id, arg}
          candidates -> {:ok, preferred_provider(conv, target, candidates).id, arg}
        end
    end
  end

  defp preferred_provider(conv, target, candidates) do
    settings = Settings.get_cached()

    {current, default} =
      if target == :chat,
        do: {conv.chat_provider_id, settings.default_chat_provider_id},
        else: {conv.swarm_provider_id, settings.default_swarm_provider_id}

    Enum.find(candidates, &(&1.id == current)) ||
      Enum.find(candidates, &(&1.id == default)) ||
      hd(candidates)
  end

  defp workflow_run(conv, handle) do
    direct =
      case Ecto.UUID.cast(handle) do
        {:ok, id} -> Workflows.get_run(id)
        :error -> nil
      end

    resolved = if direct, do: {:ok, direct}, else: Workflows.resolve_run(handle, conv.project_id)

    case resolved do
      {:ok, %{conversation_id: id} = wf} when id == conv.id -> {:ok, wf}
      {:error, {:ambiguous, _}} -> {:error, :ambiguous_run}
      _ -> {:error, :not_found}
    end
  end

  defp set_mode(conv, command, mode) do
    with {:ok, _} <- persist_mode(conv, mode),
         do: result(conv, command, :updated, %{mode: mode, fields: mode_fields(mode)})
  end

  defp persist_mode(conv, mode), do: Conversations.update(conv, mode_fields(mode))

  defp mode_fields(mode),
    do: %{
      mode: if(mode == :plan, do: "plan", else: "build"),
      ultra: mode == :ultra,
      consensus: mode == :consensus,
      authoring_workflow: mode == :workflow
    }

  defp current_mode(conv) do
    cond do
      conv.consensus -> :consensus
      conv.ultra -> :ultra
      conv.authoring_workflow -> :workflow
      conv.mode == "plan" -> :plan
      true -> :build
    end
  end

  defp custom_mode(conv, nil), do: {:ok, conv}

  defp custom_mode(conv, mode) when mode in [:build, :plan],
    do: Conversations.update(conv, %{mode: Atom.to_string(mode)})

  defp started(conv, command, {:ok, %{run_id: id}}), do: started(conv, command, {:ok, id})

  defp started(conv, command, {:ok, id}) when is_binary(id) do
    case Conversations.get_run(id) do
      %{conversation_id: conversation_id} when conversation_id == conv.id ->
        result(conv, command, :started, %{run_id: id})

      _ ->
        {:error, :operation_failed}
    end
  end

  defp started(_, _, {:error, reason}), do: failure(reason)
  defp started(_, _, _), do: {:error, :operation_failed}

  defp result(conv, command, type, fields),
    do: {:ok, Map.merge(%{type: type, command: command, conversation_id: conv.id}, fields)}

  defp normalize_result({:ok, _} = result), do: result
  defp normalize_result({:error, reason}), do: failure(reason)
  defp normalize_result(_), do: {:error, :operation_failed}
  defp failure(reason) when reason in @errors, do: {:error, reason}
  defp failure(:invalid_workflow_arguments), do: {:error, :invalid_workflow_arguments}
  # cli020: a refusal in words (C11 /delete of a live conversation).
  defp failure({:busy, words}) when is_binary(words), do: {:error, {:busy, words}}

  defp failure({:untrusted_project, words}) when is_binary(words),
    do: {:error, {:untrusted_project, words}}

  # pass73 T3/T8: an unexpected failure is still refused, but cli.log names its
  # shape (a tag, never a changeset's text) so the next report is diagnosable.
  defp failure(reason) do
    Logger.warning("SwarmCode daemon: a command failed: " <> failure_shape(reason))
    {:error, :operation_failed}
  end

  defp failure_shape(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_shape({tag, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp failure_shape({tag, _, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp failure_shape(_), do: "unrecognised"
  defp attachments(opts), do: Keyword.get(opts, :attachments, [])
  defp research_ids(opts), do: Keyword.get(opts, :research_ids, [])

  # cli020 B23 + F8: the session's `ncode -p --approval` mode, for the runs
  # this command starts (`Engine` `approval_mode:`); nothing otherwise.
  defp approval(opts) do
    case Keyword.get(opts, :approval_mode) do
      nil -> []
      mode -> [approval_mode: mode]
    end
  end

  defp research(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 and n <= 9_223_372_036_854_775_807 -> Research.get(n)
      _ -> nil
    end
  end

  defp search_at(%DateTime{} = at), do: DateTime.to_unix(at, :millisecond)
  defp search_at(%NaiveDateTime{} = at), do: search_at(DateTime.from_naive!(at, "Etc/UTC"))

  defp search_at(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _} ->
        search_at(at)

      _ ->
        case NaiveDateTime.from_iso8601(at) do
          {:ok, at} -> search_at(at)
          _ -> 0
        end
    end
  end

  defp search_at(_), do: 0

  defp clip(nil), do: ""
  defp clip(text), do: String.slice(text, 0, 256)

  defp mime_for(path) do
    case Path.extname(path) |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      _ -> "application/octet-stream"
    end
  end

  defp read_image(root, path) do
    with {:ok, %{type: :regular, size: size} = expected} <- File.lstat(path),
         true <- size <= Attachments.max_bytes(),
         {:ok, io} <- File.open(path, [:read, :binary, :raw]) do
      try do
        with {:ok, actual} <- :file.read_file_info(io),
             true <-
               elem(actual, 2) == :regular and elem(actual, 11) == expected.inode and
                 elem(actual, 9) == expected.major_device,
             true <- SwarmCode.Domain.Tools.Path.confined?(root, path),
             {:ok, data} <- :file.read(io, Attachments.max_bytes() + 1),
             true <- byte_size(data) <= Attachments.max_bytes() do
          {:ok, data}
        else
          _ -> {:error, :invalid_argument}
        end
      after
        File.close(io)
      end
    else
      _ -> {:error, :invalid_argument}
    end
  end

  defp valid_text?(text, limit),
    do: is_binary(text) and byte_size(text) <= limit and String.valid?(text)

  defp valid_options?(opts), do: valid_options?(opts, [])
  defp valid_options?([], _), do: true

  # cli020 fix S1: `ncode -p --approval <mode>` rides on the options of every
  # command a session dispatches (`approval/1` reads it). It is a mode, not a
  # list, so it has its own clause; anything else is refused.
  defp valid_options?([{:approval_mode, mode} | rest], seen) do
    :approval_mode not in seen and mode in @approval_modes and
      valid_options?(rest, [:approval_mode | seen])
  end

  defp valid_options?([{key, value} | rest], seen) when key in @allowed do
    key not in seen and
      bounded_list?(value, if(key in [:attachments, :research_ids], do: 64, else: 1_024)) and
      valid_options?(rest, [key | seen])
  end

  defp valid_options?(_, _), do: false
  defp bounded_list?([], _), do: true
  defp bounded_list?([_ | rest], count) when count > 0, do: bounded_list?(rest, count - 1)
  defp bounded_list?(_, _), do: false
end
