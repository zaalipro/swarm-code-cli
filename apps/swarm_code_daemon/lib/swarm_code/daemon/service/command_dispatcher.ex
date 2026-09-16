defmodule SwarmCode.Daemon.Service.CommandDispatcher do
  @moduledoc """
  Executes slash-command intents against the existing persisted Domain APIs.
  Never starts a Repo or bypasses its production gate. Selection/navigation
  results ask the presenter to act; they do not claim a selection was performed.
  """
  alias SwarmCode.Commands

  alias SwarmCode.Domain.{
    Checkpoints,
    Conversations,
    Engine,
    Attachments,
    Providers,
    Research,
    Settings,
    Workflows
  }

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
    :not_attachable,
    :conversation_not_found,
    :invalid_request,
    :ambiguous_run,
    :unknown_model
  ]
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
              Keyword.put(opts, :resolved_workflows, parser_opts[:workflows])
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

  defp efforts(conv, kind) do
    levels =
      case Providers.effective_model(conv, kind) do
        {:ok, %{provider: provider, model: model}} -> Settings.efforts(provider, model)
        _ -> Settings.efforts()
      end

    Enum.map(levels, &elem(&1, 0))
  end

  defp execute(conv, %{kind: :custom} = cmd, opts) do
    with {:ok, conv} <- custom_mode(conv, cmd.mode) do
      result =
        if cmd.action == :start_swarm,
          do: Engine.start_swarm(conv, cmd.prompt),
          else:
            Engine.start_chat_turn(conv, cmd.prompt, attachments(opts),
              research_ids: research_ids(opts)
            )

      started(conv, cmd.name, result)
    end
  end

  defp execute(conv, %{action: :start_swarm} = cmd, _opts),
    do: started(conv, cmd.name, Engine.start_swarm(conv, cmd.task))

  defp execute(conv, %{action: :pursue_goal} = cmd, _opts) do
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
        if mode == "swarm",
          do: Engine.start_swarm(conv, goal.text, args),
          else: Engine.start_goal_turn(conv, goal.text, args)

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

        with {:ok, _} <- Conversations.update(conv, fields),
             do:
               result(conv, cmd.name, :updated, %{
                 fields: fields,
                 field: model_field,
                 value: model
               })

      :error ->
        {:error, :unknown_model}
    end
  end

  defp execute(conv, %{action: :start_turn, mode: :consensus} = cmd, opts) do
    with {:ok, conv} <- persist_mode(conv, :consensus) do
      started(
        conv,
        cmd.name,
        Engine.start_chat_turn(conv, cmd.task, attachments(opts),
          research_ids: research_ids(opts)
        )
      )
    end
  end

  defp execute(conv, %{action: :author_workflow} = cmd, opts) do
    with {:ok, conv} <- persist_mode(conv, :workflow) do
      started(
        conv,
        cmd.name,
        Engine.start_chat_turn(conv, "/create-workflow " <> cmd.prompt, attachments(opts),
          prompt: cmd.prompt,
          command: :create_workflow,
          research_ids: research_ids(opts)
        )
      )
    end
  end

  defp execute(conv, %{action: :review_changes} = cmd, opts),
    do:
      started(
        conv,
        cmd.name,
        Engine.start_chat_turn(conv, @review_prompt, attachments(opts),
          research_ids: research_ids(opts)
        )
      )

  defp execute(conv, %{action: :compact} = cmd, _),
    do: started(conv, cmd.name, Engine.start_compact(conv, cmd.focus))

  defp execute(conv, %{action: :stop_all} = cmd, _) do
    active = Engine.running_runs(conv.id)

    if active == [] do
      {:error, :nothing_to_stop}
    else
      with :ok <- Engine.stop_all(conv.id),
           do: result(conv, cmd.name, :stopped, %{run_ids: Enum.take(active, 200)})
    end
  end

  defp execute(conv, %{action: :resume_last} = cmd, _) do
    run =
      Enum.find(
        Conversations.list_runs(conv.id),
        &(&1.kind in ["chat", "swarm"] and &1.status in ["stopped", "failed", "interrupted"])
      )

    if run, do: started(conv, cmd.name, Engine.resume_run(run)), else: {:error, :not_resumable}
  end

  defp execute(conv, %{action: :select_rewind} = cmd, _) do
    items =
      conv.id
      |> Checkpoints.for_conversation()
      |> Enum.take(200)
      |> Enum.map(fn item ->
        %{
          run_id: item.run_id,
          turn: item.turn,
          prompt: clip(item.prompt),
          file_count: length(item.files)
        }
      end)

    result(conv, cmd.name, :select, %{subject: :rewind, options: items})
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

    with {:ok, root} <- SwarmCode.Tools.Path.real_path(conv.project.root_path),
         true <- length(attachments(opts)) < Attachments.max_per_message(),
         {:ok, real} <- SwarmCode.Tools.Path.real_path(path),
         true <- SwarmCode.Tools.Path.confined?(root, real),
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
        Workflows.launch(%{
          conversation: conv,
          project: conv.project,
          definition: definition,
          args: cmd.inputs,
          rest: cmd.input,
          created_by: "user",
          launch_message_id: message.id
        })
      )
    else
      nil -> {:error, :unknown_workflow}
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
  defp failure(_), do: {:error, :operation_failed}
  defp attachments(opts), do: Keyword.get(opts, :attachments, [])
  defp research_ids(opts), do: Keyword.get(opts, :research_ids, [])

  defp research(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 and n <= 9_223_372_036_854_775_807 -> Research.get(n)
      _ -> nil
    end
  end

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
             true <- SwarmCode.Tools.Path.confined?(root, path),
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
