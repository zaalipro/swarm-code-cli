defmodule SwarmCode.Domain.FeatureCatalog do
  @moduledoc """
  Validated service access to persisted Domain features. No Repo is opened here.
  Query projections contain no Ecto structs, credentials, or executable terms.
  Commands delegate to the same contexts as the original application.
  """
  alias SwarmCode.Domain.{
    Checkpoints,
    Conversations,
    Git,
    MCP,
    Memory,
    Projects,
    Research,
    Scheduled,
    Settings,
    Workflows
  }

  alias SwarmCode.Protocol.Scope

  @features [
    :workflows,
    :research,
    :schedules,
    :settings,
    :usage,
    :changes,
    :checkpoints,
    :mcp,
    :memory
  ]
  @schedule_fields ~w(id name prompt kind project_id mode schedule_kind run_at time_of_day weekdays day_of_month cron timezone color enabled catch_up provider_id model effort workflow_name workflow_args)a
  @settings_fields SwarmCode.Domain.Settings.Setting.__schema__(:fields) --
                     [:id, :inserted_at, :updated_at, :tavily_api_key, :storage_last_cleanup_at]
  @type result :: {:ok, map() | list()} | {:error, atom()}
  @type feature ::
          :workflows
          | :research
          | :schedules
          | :settings
          | :usage
          | :changes
          | :checkpoints
          | :mcp

  @spec query(feature(), Scope.t(), keyword()) :: result()
  def query(feature, scope, opts \\ [])

  def query(feature, scope, opts) when is_binary(feature),
    do: query(feature_atom(feature), scope, opts)

  def query(feature, scope, opts) when feature in @features and is_map(scope) and is_list(opts) do
    with {:ok, opts} <- query_options(opts),
         :ok <- feature_scope(feature, scope),
         {:ok, context} <- scope_context(scope),
         {:ok, rows} <- query_rows(feature, context, opts),
         {:ok, rows} <- select_id(rows, opts[:id]),
         {:ok, offset} <- offset(opts[:cursor]) do
      limit = opts[:limit]
      remaining = Enum.drop(rows, offset)
      page = Enum.take(remaining, limit)
      # Bound each field by bytes; return only rows that fit the aggregate page.
      items = fit_items(page, opts[:byte_limit] - 512)
      next = if length(remaining) > length(items), do: Integer.to_string(offset + length(items))

      {:ok,
       %{
         title: title(feature),
         description: description(feature),
         items: items,
         next_cursor: next
       }}
    end
  rescue
    _ in [Ecto.Query.CastError, Ecto.NoResultsError] ->
      {:error, :invalid_id}

    _ ->
      {:error, :feature_unavailable}
  catch
    :exit, _ -> {:error, :feature_unavailable}
  end

  def query(_, _, _), do: {:error, :invalid_options}

  @spec list_workflows(binary() | nil) :: result()
  def list_workflows(project_id \\ nil) do
    with {:ok, project} <- optional_project(project_id) do
      {:ok, Workflows.list(project) |> Enum.take(200) |> Enum.map(&definition/1)}
    end
  end

  @spec workflow_detail(binary() | nil, binary()) :: result()
  def workflow_detail(project_id, name) do
    with {:ok, project} <- optional_project(project_id),
         :ok <- text(name, 80),
         {:ok, wf} <- found(Workflows.get(project, name)) do
      {:ok, definition(wf)}
    end
  end

  @spec start_workflow(map()) :: result()
  def start_workflow(attrs) do
    with {:ok, a} <- attributes(attrs, ~w(conversation_id name args budget max_live model)a),
         {:ok, conv} <- fetch_uuid(a[:conversation_id], &Conversations.get/1),
         :ok <- text(a[:name], 80),
         {:ok, wf} <- found(Workflows.get(conv.project, a.name)),
         :ok <- optional_integer(a[:budget], 1, 1024),
         :ok <- optional_integer(a[:max_live], 1, 64),
         :ok <- optional_text(a[:model], 256),
         true <- is_map(Map.get(a, :args, %{})),
         {:ok, args} <-
           Workflows.Args.cast(
             wf.meta,
             Map.new(Map.get(a, :args, %{}), fn {key, value} -> {to_string(key), value} end)
           ) do
      Workflows.launch(%{
        conversation: conv,
        project: conv.project,
        definition: wf,
        args: args,
        budget: a[:budget],
        max_live: a[:max_live],
        model: a[:model],
        created_by: "user"
      })
      |> mapped(&workflow/1)
    else
      false -> {:error, :invalid_options}
      error -> error
    end
  end

  @spec control_workflow(binary(), :pause | :resume | :stop, keyword()) :: result()
  def control_workflow(id, action, opts \\ [])

  def control_workflow(id, action, opts) when action in [:pause, :resume, :stop] do
    with {:ok, _} <- fetch_uuid(id, &Workflows.get_run/1),
         {:ok, opts} <- keyword_options(opts, [:answer, :budget]),
         :ok <- optional_integer(opts[:budget], 1, 1024),
         :ok <- Workflows.control(id, action, opts) do
      {:ok, %{run_id: id, action: action}}
    else
      error -> error_result(error)
    end
  end

  def control_workflow(_, _, _), do: {:error, :invalid_options}

  @spec list_research(keyword()) :: result()
  def list_research(opts \\ []) do
    with {:ok, o} <- keyword_options(opts, [:project_id, :status, :level, :limit]),
         :ok <- optional_integer(o[:limit] || o[:page_size], 1, 200),
         :ok <- optional_text(o[:status], 40),
         :ok <- optional_text(o[:level], 40),
         {:ok, _} <- optional_project(o[:project_id]) do
      {:ok, Research.list(Keyword.put_new(o, :limit, 200)) |> Enum.map(&research/1)}
    end
  end

  @spec research_detail(pos_integer() | binary()) :: result()
  def research_detail(id) do
    with {:ok, row} <- fetch_research(id) do
      result =
        case Research.read_result(row) do
          {:ok, value} -> clip(value, 32_000)
          _ -> nil
        end

      report = read_file(row.report_path || Research.report_path(row), 32_000)
      sources = row.sources |> List.wrap() |> Enum.take(128) |> plain()

      {:ok, research(row) |> Map.merge(%{result: result, report: report, sources: sources})}
    end
  end

  @spec start_research(map()) :: result()
  def start_research(attrs) do
    with {:ok, a} <- attributes(attrs, ~w(question level project_id provider_id model effort)a),
         :ok <- text(a[:question], 4000),
         {:ok, _} <- optional_project(a[:project_id]),
         :ok <- optional_provider(a[:provider_id]),
         :ok <- optional_text(a[:model], 256),
         :ok <- optional_text(a[:effort], 64) do
      # Research.create requires homogeneous string keys, including its default level.
      Research.launch(Map.new(a, fn {k, v} -> {Atom.to_string(k), v} end)) |> mapped(&research/1)
    end
  end

  @spec control_research(pos_integer() | binary(), :stop | :retry | :report | :pin) :: result()
  def control_research(id, action) when action in [:stop, :retry, :report, :pin] do
    with {:ok, row} <- fetch_research(id) do
      case action do
        :stop -> Research.stop(row.id) |> acknowledged(%{id: row.id, action: :stop})
        :retry -> Research.retry(row.id) |> mapped(&research/1)
        :report -> Research.build_report(row.id) |> acknowledged(%{id: row.id, action: :report})
        :pin -> Research.toggle_pin(row.id) |> mapped(&research/1)
      end
    end
  end

  def control_research(_, _), do: {:error, :invalid_options}

  @spec list_schedules() :: result()
  def list_schedules, do: {:ok, Scheduled.list() |> Enum.take(200) |> Enum.map(&schedule/1)}

  @spec schedule_detail(binary()) :: result()
  def schedule_detail(id) do
    with {:ok, task} <- fetch_uuid(id, &Scheduled.get/1), do: {:ok, schedule(task)}
  end

  @spec save_schedule(map()) :: result()
  def save_schedule(attrs) do
    with {:ok, a} <- attributes(attrs, @schedule_fields),
         {:ok, existing} <- optional_task(a[:id]),
         {:ok, _} <-
           fetch_uuid(a[:project_id] || (existing && existing.project_id), &Projects.get/1),
         :ok <- optional_provider(a[:provider_id]) do
      clean = Map.delete(a, :id)
      result = if existing, do: Scheduled.update(existing, clean), else: Scheduled.create(clean)
      mapped(result, &schedule/1)
    end
  end

  @spec delete_schedule(binary()) :: result()
  def delete_schedule(id) do
    with {:ok, task} <- fetch_uuid(id, &Scheduled.get/1),
         do: Scheduled.delete(task) |> mapped(fn _ -> %{id: id} end)
  end

  @spec toggle_schedule(binary()) :: result()
  def toggle_schedule(id) do
    with {:ok, task} <- fetch_uuid(id, &Scheduled.get/1),
         do: Scheduled.toggle(task) |> mapped(&schedule/1)
  end

  @spec run_schedule_now(binary()) :: result()
  def run_schedule_now(id) do
    with {:ok, task} <- fetch_uuid(id, &Scheduled.get/1),
         do:
           Scheduled.run_now(task)
           |> mapped(
             &project_fields(
               &1,
               ~w(id task_id run_id status scheduled_for started_at finished_at error)a
             )
           )
  end

  @spec settings() :: result()
  def settings, do: {:ok, project_fields(Settings.get(), @settings_fields)}

  @spec update_settings(map()) :: result()
  def update_settings(attrs) do
    with {:ok, a} <- attributes(attrs, @settings_fields),
         :ok <- settings_providers(a) do
      Settings.update(a) |> mapped(&project_fields(&1, @settings_fields))
    end
  end

  @spec usage(keyword()) :: result()
  def usage(opts \\ []) do
    with {:ok, o} <- keyword_options(opts, [:days, :limit]),
         :ok <- optional_integer(o[:days], 1, 3650),
         :ok <- optional_integer(o[:limit], 1, 200) do
      {:ok,
       %{
         summary: plain(Conversations.usage_summary(o)),
         rows: plain(Conversations.usage_rows(Keyword.put_new(o, :limit, 200)))
       }}
    end
  end

  @spec git_status(binary()) :: result()
  def git_status(root) do
    with :ok <- git_root(root) do
      {:ok,
       %{
         branch: Git.current_branch(root),
         head: Git.head(root),
         files: plain(Enum.take(Git.status(root), 200))
       }}
    end
  end

  @spec git_diff(binary(), keyword()) :: {:ok, binary()} | {:error, atom()}
  def git_diff(root, opts \\ []) do
    with :ok <- git_root(root),
         {:ok, opts} <- keyword_options(opts, [:staged, :base, :paths]),
         :ok <- diff_options(opts) do
      {:ok, clip(Git.diff(root, opts), 32_000)}
    end
  end

  @spec checkpoints(binary()) :: result()
  def checkpoints(id) do
    with {:ok, _} <- fetch_uuid(id, &Conversations.get/1) do
      {:ok, Checkpoints.for_conversation(id) |> Enum.take(200) |> plain()}
    end
  end

  @spec restore_checkpoint(binary(), binary()) :: result()
  def restore_checkpoint(conversation_id, checkpoint_id) do
    with :ok <- uuid(conversation_id), :ok <- uuid(checkpoint_id) do
      Checkpoints.restore_one(conversation_id, checkpoint_id) |> mapped(&%{path: &1})
    end
  end

  @spec restore_checkpoint_run(binary(), binary()) :: result()
  def restore_checkpoint_run(conversation_id, run_id) do
    with :ok <- uuid(conversation_id), :ok <- uuid(run_id) do
      Checkpoints.restore_run(conversation_id, run_id) |> mapped(&%{restored: &1})
    end
  end

  # Query projections are deliberately explicit; never serialize entire schemas.
  defp query_rows(:workflows, ctx, _opts) do
    definitions =
      Enum.map(Workflows.list(ctx.project), fn w ->
        item(
          w.name,
          w.name,
          w.meta[:description],
          if(w.problems == [], do: "available", else: "invalid"),
          definition(w),
          [:start],
          if(w.problems == [], do: workflow_form(w), else: nil)
        )
      end)

    runs =
      Workflows.list_runs(:all)
      |> Enum.filter(&member_conversation?(ctx, &1.wf.conversation_id))
      |> Enum.map(fn r ->
        item(r.wf.run_id, r.wf.display_name, r.wf.definition_name, r.run.status, workflow(r.wf), [
          :pause,
          :resume,
          :stop
        ])
      end)

    {:ok, definitions ++ runs}
  end

  defp query_rows(:research, ctx, _opts) do
    rows = Research.list(if(ctx.project, do: [project_id: ctx.project.id], else: []))
    rows = if ctx.research_id, do: Enum.filter(rows, &(&1.id == ctx.research_id)), else: rows

    {:ok,
     Enum.map(rows, fn r ->
       data =
         case research_detail(r.id) do
           {:ok, detail} -> detail
           _ -> research(r)
         end

       item(
         r.id,
         r.title || r.question,
         r.level,
         r.status,
         data,
         if(r.status in ["queued", "running"], do: [:stop], else: [:retry, :report])
       )
     end)}
  end

  defp query_rows(:schedules, ctx, _opts) do
    rows =
      Scheduled.list()
      |> Enum.filter(&(is_nil(ctx.project) or &1.project_id == ctx.project.id))
      |> Enum.filter(&(is_nil(ctx.schedule_id) or &1.id == ctx.schedule_id))

    fresh =
      if is_nil(ctx.schedule_id) and is_nil(ctx.conversation),
        do: [item("new", "New scheduled task", "", "create", %{}, [], schedule_form(%{}))],
        else: []

    {:ok,
     fresh ++
       Enum.map(rows, fn t ->
         item(
           t.id,
           t.name,
           t.kind,
           if(t.enabled, do: "enabled", else: "disabled"),
           schedule(t),
           [:toggle, :run_now, :delete],
           schedule_form(t)
         )
       end)}
  end

  defp query_rows(:settings, _ctx, _opts) do
    {:ok, s} = settings()

    groups =
      s
      |> Enum.to_list()
      |> Enum.chunk_every(20)
      |> Enum.with_index()
      |> Enum.map(fn {entries, i} ->
        data = Map.new(entries)

        item(
          "settings-#{i + 1}",
          "Settings #{i + 1}",
          "Application defaults",
          "available",
          data,
          [:update],
          settings_form(data)
        )
      end)

    {:ok, groups}
  end

  defp query_rows(:usage, %{project: nil, conversation: nil}, _opts) do
    {:ok, u} = usage()

    {:ok,
     [
       item("summary", "Usage summary", "Last 30 days", "available", u.summary, [])
       | Enum.map(u.rows, &item(&1.id, &1[:label] || &1.kind, &1.model, &1.status, &1, []))
     ]}
  end

  defp query_rows(:usage, ctx, _opts) do
    conversations =
      if ctx.conversation,
        do: [ctx.conversation],
        else: Conversations.list_for_project(ctx.project.id)

    runs = Enum.flat_map(conversations, &Conversations.list_runs(&1.id))

    {:ok,
     Enum.map(
       runs,
       &item(
         &1.id,
         &1.label || &1.kind,
         &1.model,
         &1.status,
         project_fields(
           &1,
           ~w(id kind model status tokens_in tokens_out cost_usd started_at finished_at)a
         ),
         []
       )
     )}
  end

  defp query_rows(:changes, %{project: nil}, _), do: {:error, :invalid_scope}

  defp query_rows(:changes, ctx, opts) do
    with :ok <- git_root(ctx.project.root_path) do
      {:ok,
       Enum.map(Git.status(ctx.project.root_path), fn f ->
         detail =
           if opts[:id] == f.path, do: Git.diff(ctx.project.root_path, paths: [f.path]), else: f

         item(f.path, f.path, Git.current_branch(ctx.project.root_path), "changed", detail, [
           :diff
         ])
       end)}
    end
  end

  defp query_rows(:checkpoints, %{conversation: nil}, _), do: {:error, :invalid_scope}

  defp query_rows(:checkpoints, ctx, _) do
    rows = Checkpoints.for_conversation(ctx.conversation.id) |> Enum.flat_map(& &1.files)

    {:ok,
     Enum.map(rows, fn c ->
       item(
         c.id,
         Path.basename(c.path),
         c.path,
         if(c.restorable, do: "restorable", else: "unavailable"),
         project_fields(c, ~w(id run_id path existed restorable inserted_at)a),
         [:restore]
       )
     end)}
  end

  defp query_rows(:mcp, ctx, _) do
    rows =
      MCP.list()
      |> Enum.filter(
        &(is_nil(&1.project_id) or (ctx.project && &1.project_id == ctx.project.id) or
            is_nil(ctx.project))
      )

    {:ok,
     Enum.map(rows, fn s ->
       item(
         s.id,
         s.name,
         s.transport,
         if(s.enabled, do: "enabled", else: "disabled"),
         project_fields(s, ~w(id name transport enabled project_id)a),
         [:toggle, :delete],
         mcp_form(s)
       )
     end)}
  end

  defp query_rows(:memory, ctx, _) do
    rows =
      case ctx.project do
        nil ->
          [memory_item("global", "Global memory", Memory.read(:global, nil), :global)]

        project ->
          [
            memory_item("global", "Global memory", Memory.read(:global, nil), :global),
            memory_item(
              project.id,
              "Project memory",
              Memory.read(:project, project.root_path),
              :project
            )
          ]
      end

    {:ok, rows}
  end

  defp feature_scope(:research, %{kind: :research}), do: :ok
  defp feature_scope(:schedules, %{kind: :schedule}), do: :ok

  defp feature_scope(_, %{kind: kind}) when kind in [:research, :schedule],
    do: {:error, :invalid_scope}

  defp feature_scope(_, _), do: :ok

  defp empty_context, do: %{project: nil, conversation: nil, research_id: nil, schedule_id: nil}
  defp scope_context(%{kind: :global, id: nil}), do: {:ok, empty_context()}

  defp scope_context(%{kind: :project, id: id}) do
    with {:ok, p} <- fetch_uuid(id, &Projects.get/1), do: {:ok, %{empty_context() | project: p}}
  end

  defp scope_context(%{kind: :conversation, id: id}) do
    with {:ok, c} <- fetch_uuid(id, &Conversations.get/1),
         do: {:ok, %{empty_context() | conversation: c, project: c.project}}
  end

  defp scope_context(%{kind: kind, id: id}) when kind in [:run, :workflow] do
    with {:ok, r} <- fetch_uuid(id, &Conversations.get_run/1),
         do: scope_context(%{kind: :conversation, id: r.conversation_id})
  end

  defp scope_context(%{kind: :research, id: id}) do
    with {:ok, r} <- fetch_research(id),
         {:ok, p} <- optional_project(r.project_id),
         do: {:ok, %{empty_context() | project: p, research_id: r.id}}
  end

  defp scope_context(%{kind: :schedule, id: id}) do
    with {:ok, t} <- fetch_uuid(id, &Scheduled.get/1),
         {:ok, p} <- optional_project(t.project_id),
         do: {:ok, %{empty_context() | project: p, schedule_id: t.id}}
  end

  defp scope_context(_), do: {:error, :invalid_scope}
  defp member_conversation?(%{conversation: %{id: id}}, candidate), do: id == candidate
  defp member_conversation?(%{project: nil}, _), do: true

  defp member_conversation?(ctx, id) do
    case Conversations.get(id) do
      %{project_id: p} -> p == ctx.project.id
      _ -> false
    end
  end

  defp query_options(opts) do
    with {:ok, o} <- keyword_options(opts, [:id, :cursor, :limit, :page_size, :byte_limit]),
         :ok <- optional_integer(o[:limit] || o[:page_size], 1, 200),
         :ok <- optional_integer(o[:byte_limit], 4096, 1_048_576),
         :ok <- optional_text(o[:id], 4096),
         :ok <- optional_text(o[:cursor], 20) do
      {:ok,
       o |> Keyword.put_new(:limit, o[:page_size] || 50) |> Keyword.put_new(:byte_limit, 65_536)}
    end
  end

  defp feature_atom(value)
       when value in ~w(workflows research schedules settings usage changes checkpoints mcp memory),
       do: String.to_existing_atom(value)

  defp feature_atom(_), do: :unsupported

  defp keyword_options(opts, keys) do
    if Keyword.keyword?(opts) and Enum.all?(Keyword.keys(opts), &(&1 in keys)),
      do: {:ok, opts},
      else: {:error, :invalid_options}
  end

  defp attributes(attrs, allowed)
       when is_map(attrs) and map_size(attrs) > 0 and map_size(attrs) <= 128 do
    keys = Map.new(allowed, &{Atom.to_string(&1), &1})

    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      atom = if is_atom(key) and key in allowed, do: key, else: Map.get(keys, key)

      if atom && not Map.has_key?(acc, atom) && input_value?(value, 0),
        do: {:cont, {:ok, Map.put(acc, atom, value)}},
        else: {:halt, {:error, :invalid_options}}
    end)
  end

  defp attributes(_, _), do: {:error, :invalid_options}
  defp input_value?(_, depth) when depth > 6, do: false
  defp input_value?(v, _) when is_binary(v), do: byte_size(v) <= 32_000 and String.valid?(v)
  defp input_value?(v, _) when is_number(v) or is_boolean(v) or is_nil(v), do: true

  defp input_value?(v, depth) when is_list(v),
    do: length(v) <= 128 and Enum.all?(v, &input_value?(&1, depth + 1))

  defp input_value?(v, depth) when is_map(v) and not is_struct(v),
    do:
      map_size(v) <= 128 and
        Enum.all?(v, fn {k, x} -> (is_atom(k) or is_binary(k)) and input_value?(x, depth + 1) end)

  defp input_value?(_, _), do: false
  defp fetch_uuid(id, fun), do: with(:ok <- uuid(id), do: found(fun.(id)))

  defp uuid(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> :ok
      _ -> {:error, :invalid_id}
    end
  end

  defp uuid(_), do: {:error, :invalid_id}
  defp found(nil), do: {:error, :not_found}
  defp found(row), do: {:ok, row}
  defp optional_project(nil), do: {:ok, nil}
  defp optional_project(id), do: fetch_uuid(id, &Projects.get/1)
  defp optional_task(nil), do: {:ok, nil}
  defp optional_task(id), do: fetch_uuid(id, &Scheduled.get/1)
  defp optional_provider(nil), do: :ok

  defp optional_provider(id) do
    with {:ok, _} <- fetch_uuid(id, &SwarmCode.Domain.Providers.get/1), do: :ok
  end

  defp settings_providers(attrs) do
    Enum.reduce_while(attrs, :ok, fn {key, value}, :ok ->
      result =
        if String.ends_with?(Atom.to_string(key), "provider_id"),
          do: optional_provider(value),
          else: :ok

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp fetch_research(id) do
    with {:ok, id} <- positive_id(id), do: found(Research.get(id))
  end

  defp positive_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp positive_id(id) when is_binary(id) and byte_size(id) <= 18 do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, :invalid_id}
    end
  end

  defp positive_id(_), do: {:error, :invalid_id}

  defp text(v, max) when is_binary(v),
    do:
      if(byte_size(v) <= max and String.valid?(v) and String.trim(v) != "",
        do: :ok,
        else: {:error, :invalid_options}
      )

  defp text(_, _), do: {:error, :invalid_options}
  defp optional_text(nil, _), do: :ok
  defp optional_text(v, max), do: text(v, max)
  defp optional_integer(nil, _, _), do: :ok
  defp optional_integer(v, min, max) when is_integer(v) and v >= min and v <= max, do: :ok
  defp optional_integer(_, _, _), do: {:error, :invalid_options}
  defp offset(nil), do: {:ok, 0}

  defp offset(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 and n <= 1_000_000 -> {:ok, n}
      _ -> {:error, :invalid_options}
    end
  end

  defp select_id(rows, nil), do: {:ok, rows}

  defp select_id(rows, id) do
    case Enum.filter(rows, &(to_string(&1.id) == id)) do
      [] -> {:error, :not_found}
      selected -> {:ok, selected}
    end
  end

  defp git_root(root) when is_binary(root) do
    if File.dir?(root) and Git.repo?(root), do: :ok, else: {:error, :not_a_repository}
  end

  defp git_root(_), do: {:error, :invalid_scope}

  defp diff_options(opts) do
    valid_paths =
      is_nil(opts[:paths]) or
        (is_list(opts[:paths]) and length(opts[:paths]) <= 200 and
           Enum.all?(
             opts[:paths],
             &(is_binary(&1) and byte_size(&1) <= 4096 and not String.contains?(&1, <<0>>))
           ))

    valid_base =
      is_nil(opts[:base]) or
        (is_binary(opts[:base]) and match?({:ok, _}, Git.validate_revision(opts[:base])))

    if valid_paths and valid_base and opts[:staged] in [nil, true, false],
      do: :ok,
      else: {:error, :invalid_options}
  end

  defp mapped({:ok, value}, fun), do: {:ok, fun.(value)}
  defp mapped(error, _), do: error_result(error)
  defp acknowledged(:ok, result), do: {:ok, result}
  defp acknowledged(error, _), do: error_result(error)
  defp error_result({:error, %Ecto.Changeset{}}), do: {:error, :invalid_options}

  defp error_result({:error, reason})
       when reason in [
              :not_found,
              :database_busy,
              :not_configured,
              :not_running,
              :not_paused,
              :budget_too_low,
              :busy,
              :no_result
            ],
       do: {:error, reason}

  defp error_result(_), do: {:error, :operation_failed}

  defp definition(w),
    do: %{name: w.name, scope: w.scope, meta: plain(w.meta), problems: plain(w.problems)}

  defp workflow(w),
    do:
      project_fields(
        w,
        ~w(run_id conversation_id definition_name display_name scope budget max_live agents_admitted phase pause_kind pause_message result error)a
      )

  defp research(r),
    do:
      project_fields(
        r,
        ~w(id question title level status summary step steps_total fanout tokens_in tokens_out cost_usd error run_id conversation_id project_id started_at finished_at design_state)a
      )

  defp schedule(t), do: project_fields(t, @schedule_fields ++ ~w(next_run_at last_run_at)a)
  defp project_fields(row, keys), do: row |> Map.take(keys) |> plain()
  defp plain(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp plain(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp plain(%_{}), do: nil

  defp plain(map) when is_map(map),
    do: Map.new(Enum.take(map, 128), fn {k, v} -> {k, plain(v)} end)

  defp plain(list) when is_list(list), do: Enum.take(list, 200) |> Enum.map(&plain/1)
  defp plain(value) when is_binary(value), do: clip(value, 32_000)
  defp plain(value) when is_atom(value) or is_number(value), do: value
  defp plain(_), do: nil

  defp item(id, name, subtitle, status, detail, actions, form \\ nil) do
    detail = if is_binary(detail), do: detail, else: Jason.encode!(plain(detail), pretty: true)

    %{
      id: to_string(id),
      title: clip(to_string(name || id), 256),
      subtitle: clip(to_string(subtitle || ""), 512),
      status: to_string(status),
      detail: clip(detail, 16_000),
      actions: actions,
      form: form
    }
  end

  defp field(
         key,
         label,
         kind \\ "text",
         value \\ "",
         required \\ false,
         choices \\ [],
         hint \\ ""
       ),
       do: %{
         "key" => key,
         "label" => label,
         "kind" => kind,
         "value" => form_value(value),
         "required" => required,
         "choices" => choices,
         "hint" => hint
       }

  defp form_value(nil), do: ""
  defp form_value(value) when is_binary(value), do: value
  defp form_value(value) when is_map(value) or is_list(value), do: Jason.encode!(plain(value))
  defp form_value(value), do: to_string(value)

  defp read_file(path, limit) do
    case File.read(path) do
      {:ok, text} when is_binary(text) -> clip(text, limit)
      _ -> nil
    end
  end

  defp workflow_form(w) do
    specs = SwarmCode.Domain.Workflows.Definition.arg_specs(w)

    fields =
      Enum.map(specs, fn {key, spec} ->
        {kind, hint} =
          case spec[:type] do
            :integer -> {"integer", "Whole number"}
            :boolean -> {"boolean", "true or false"}
            :list -> {"json", "JSON array"}
            :enum -> {"choice", "Choose a value with left/right"}
            _ -> {"text", ""}
          end

        field(
          "arg:" <> to_string(key),
          to_string(key),
          kind,
          Map.get(spec, :default, ""),
          spec[:required] || false,
          Enum.map(spec[:values] || spec[:enum] || [], &to_string/1),
          spec[:doc] || hint
        )
      end)

    extras = [
      field("budget", "Agent budget", "integer"),
      field("max_live", "Concurrent agents", "integer"),
      field("model", "Model override")
    ]

    if length(fields) <= 32 do
      %{
        "title" => "Start " <> w.name,
        "submit_label" => "Start",
        "action" => "start",
        "fields" => fields ++ Enum.take(extras, 32 - length(fields))
      }
    end
  end

  defp schedule_form(t),
    do: %{
      "title" => "Edit schedule",
      "submit_label" => "Save",
      "action" => "save",
      "fields" =>
        Enum.map(
          ~w(name prompt kind mode schedule_kind run_at time_of_day weekdays day_of_month cron timezone enabled catch_up workflow_name workflow_args provider_id model effort color)a,
          fn k ->
            schedule_field(k, t)
          end
        )
    }

  defp schedule_field(k, task) do
    {kind, choices, hint} =
      case k do
        :kind -> {"choice", ~w(chat swarm workflow), "What runs"}
        :mode -> {"choice", ~w(build plan), "Execution mode"}
        :schedule_kind -> {"choice", ~w(once daily weekly monthly cron), "Recurrence"}
        :weekdays -> {"json", [], "JSON array of weekday numbers 1..7"}
        :workflow_args -> {"json", [], "JSON object"}
        :day_of_month -> {"integer", [], "1..31"}
        :enabled -> {"boolean", [], ""}
        :catch_up -> {"boolean", [], ""}
        :effort -> {"choice", ~w(low medium high max), "Reasoning effort"}
        _ -> {"text", [], ""}
      end

    field(
      to_string(k),
      k |> to_string() |> String.replace("_", " ") |> String.capitalize(),
      kind,
      Map.get(task, k, ""),
      k in [:name, :prompt],
      choices,
      hint
    )
  end

  defp settings_form(s),
    do: %{
      "title" => "Settings",
      "submit_label" => "Update",
      "action" => "update",
      "fields" =>
        Enum.take(Map.keys(s), 20)
        |> Enum.map(fn k ->
          settings_field(k, Map.get(s, k))
        end)
    }

  defp settings_field(k, value) do
    {kind, choices} =
      case k do
        k when k in [:theme] ->
          {"choice", ~w(carbon obsidian graphite aurora ember fjord dusk paper)}

        k when k in [:mode] ->
          {"choice", ~w(dark light)}

        k
        when k in [
               :default_effort,
               :default_swarm_effort,
               :default_scheduled_effort,
               :default_workflow_effort
             ] ->
          {"choice", ~w(none minimal low medium high max)}

        k when k in [:research_level] ->
          {"choice", ~w(low medium high ultra)}

        k when k in [:research_reader] ->
          {"choice", ~w(web_fetch jina firecrawl)}

        k when k in [:research_auto_design] ->
          {"choice", ~w(deep all never)}

        k when k in [:consensus_layout] ->
          {"choice", ~w(stacked side)}

        k when k in [:bench_layout] ->
          {"choice", ~w(scales rail spine scorecard)}

        _ when is_boolean(value) ->
          {"boolean", []}

        _ when is_integer(value) ->
          {"integer", []}

        _ when is_float(value) ->
          {"number", []}

        _ when is_map(value) or is_list(value) ->
          {"json", []}

        _ ->
          {"text", []}
      end

    field(
      to_string(k),
      k |> to_string() |> String.replace("_", " ") |> String.capitalize(),
      kind,
      value,
      false,
      choices
    )
  end

  defp mcp_form(s) do
    %{
      "title" => "Configure MCP server",
      "submit_label" => "Save",
      "action" => "save",
      "fields" => [
        field("name", "Name", "text", s.name, true),
        field("transport", "Transport", "choice", s.transport, true, ~w(stdio http)),
        field("command", "Command", "text", s.command, false, [], "stdio command"),
        field("args", "Arguments", "json", s.args || [], false, [], "JSON array"),
        field("url", "URL", "text", s.url, false, [], "http transport"),
        field("enabled", "Enabled", "boolean", s.enabled, false)
      ]
    }
  end

  defp memory_item(id, title, content, scope) do
    item(
      id,
      title,
      if(scope == :project, do: "Project-scoped", else: "Global-scoped"),
      if(String.trim(content) == "", do: "empty", else: "available"),
      %{"scope" => Atom.to_string(scope), "content" => content},
      [:update, :clear],
      if(byte_size(content) <= 16_384 and String.valid?(content), do: memory_form(content))
    )
  end

  defp memory_form(content) do
    %{
      "title" => "Edit memory",
      "submit_label" => "Save",
      "action" => "update",
      "fields" => [field("content", "Memory", "text", content, false, [], "Markdown")]
    }
  end

  defp fit_items(items, budget) do
    Enum.reduce_while(items, {[], budget}, fn i, {acc, bytes} ->
      i = %{i | detail: clip(i.detail, max(min(bytes - 1800, 16_000), 0))}
      size = byte_size(Jason.encode!(i))
      if size <= bytes, do: {:cont, {[i | acc], bytes - size}}, else: {:halt, {acc, bytes}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp clip(text, bytes) when byte_size(text) <= bytes, do: text

  defp clip(text, bytes) do
    prefix = binary_part(text, 0, bytes)
    if String.valid?(prefix), do: :binary.copy(prefix), else: clip(text, bytes - 1)
  end

  defp title(feature), do: feature |> Atom.to_string() |> String.capitalize()
  defp description(:workflows), do: "Workflow definitions and persisted runs"
  defp description(:research), do: "Deep research runs"
  defp description(:schedules), do: "Scheduled tasks"
  defp description(:settings), do: "Application defaults"
  defp description(:usage), do: "Recorded token usage and cost"
  defp description(:changes), do: "Project Git changes"
  defp description(:checkpoints), do: "Conversation file checkpoints"
  defp description(:mcp), do: "MCP server metadata"
  defp description(:memory), do: "Project and global memory files"
end
