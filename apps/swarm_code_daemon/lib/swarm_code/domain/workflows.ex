defmodule SwarmCode.Domain.Workflows do
  @moduledoc """
  Definitions (files), runs (rows) and the journal — the persistence and
  discovery half of workflows (spec 09 §1.2).
  """
  import Ecto.Query, warn: false, except: [update: 2, update: 3]

  require Logger

  alias SwarmCode.Domain.Conversations
  alias SwarmCode.Domain.Conversations.Message
  alias SwarmCode.Domain.Engine.{Events, ProjectContext, RunSupervisor}
  alias SwarmCode.Domain.Projects.Workspace
  alias SwarmCode.Domain.Repo
  alias SwarmCode.Domain.{Providers, Settings}
  alias SwarmCode.Domain.Workflows.{Args, Definition, JournalEntry, Run, Smoke}

  # spec 68 T28: one definition with \A/\z anchors (the security-critical form)
  @name_re ~r/\A[a-z][a-z0-9-]{1,40}\z/
  @arg_types [:string, :integer, :boolean, :list, :path, :enum]

  # ------------------------------------------------------------------ discovery

  @doc "Every definition visible in `project`, shadowed names removed."
  @spec list(map() | nil) :: [Definition.t()]
  def list(project \\ nil) do
    (builtins() ++
       scope_list(project_dir(project), "project") ++
       scope_list(user_dir(), "user"))
    |> Enum.reduce({[], MapSet.new()}, fn definition, {acc, seen} ->
      if MapSet.member?(seen, definition.name),
        do: {acc, seen},
        else: {[definition | acc], MapSet.put(seen, definition.name)}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  @doc "The definition `name` resolves to in `project`, or nil."
  @spec get(map() | nil, String.t()) :: Definition.t() | nil
  def get(project, name) do
    name = to_string(name)
    Enum.find(list(project), &(&1.name == name))
  end

  @doc "Every definition of every scope, including shadowed ones (Library warnings)."
  @spec list_all(map() | nil) :: [Definition.t()]
  def list_all(project \\ nil) do
    builtins() ++ project_list(project) ++ scope_list(user_dir(), "user")
  end

  @doc """
  Spec 64 §Data: the same listing over *every* project — what the Workflows
  page's Library shows under `All projects`, where a `project`-scope definition
  has to say which project it came from.
  """
  @spec list_all_projects([map()]) :: [Definition.t()]
  def list_all_projects(projects) when is_list(projects) do
    builtins() ++ Enum.flat_map(projects, &project_list/1) ++ scope_list(user_dir(), "user")
  end

  # A project's own definitions, tagged with the project they were read from.
  defp project_list(nil), do: []

  defp project_list(project) do
    project_dir(project)
    |> scope_list("project")
    |> Enum.map(&%{&1 | project_id: Map.get(project, :id)})
  end

  @doc "The built-in definitions, parsed once and cached in `:persistent_term`."
  @spec builtins() :: [Definition.t()]
  def builtins do
    case :persistent_term.get({__MODULE__, :builtins}, nil) do
      nil ->
        parsed = scope_list(builtin_dir(), "builtin")
        :persistent_term.put({__MODULE__, :builtins}, parsed)
        parsed

      parsed ->
        parsed
    end
  end

  @doc false
  def reset_builtins, do: :persistent_term.erase({__MODULE__, :builtins})

  def builtin_dir, do: Path.join(:code.priv_dir(:swarm_code_daemon), "workflows")

  def project_dir(nil), do: nil
  def project_dir(%{root_path: root}), do: Path.join([root, ".swarm_code", "workflows"])
  def project_dir(root) when is_binary(root), do: Path.join([root, ".swarm_code", "workflows"])

  def user_dir, do: Path.join(Workspace.global_dir(), "workflows")

  def scope_dir(project, "project"), do: project_dir(project)
  def scope_dir(_project, "user"), do: user_dir()
  def scope_dir(_project, "builtin"), do: builtin_dir()

  defp scope_list(nil, _scope), do: []

  defp scope_list(dir, scope) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".exs"))
        |> Enum.sort()
        |> Enum.map(fn file ->
          path = Path.join(dir, file)

          case parse(File.read!(path), scope, path) do
            {:ok, definition} -> definition
            {:error, problems} -> broken(path, scope, problems)
          end
        end)

      _ ->
        []
    end
  end

  defp broken(path, scope, problems) do
    %Definition{
      name: Path.basename(path, ".exs"),
      scope: scope,
      path: path,
      source: File.read!(path),
      meta: %{name: Path.basename(path, ".exs"), description: "(does not parse)"},
      problems: problems
    }
  end

  # ------------------------------------------------------------------ parsing

  @doc """
  Parses a definition: the first expression must be `meta = %{…}` with a literal
  map; everything after it is the program (spec 09 §2).
  """
  @spec parse(String.t(), String.t(), String.t() | nil) ::
          {:ok, Definition.t()} | {:error, [String.t()]}
  def parse(source, scope \\ "adhoc", path \\ nil) do
    case Code.string_to_quoted(source, file: path || "workflow.exs") do
      {:ok, ast} ->
        from_ast(ast, source, scope, path)

      {:error, {meta, message, token}} ->
        line = if is_list(meta), do: Keyword.get(meta, :line, 0), else: meta
        {:error, ["line #{line}: #{format_message(message)}#{token}"]}
    end
  end

  defp format_message({a, b}), do: to_string(a) <> to_string(b)
  defp format_message(message), do: to_string(message)

  defp from_ast(ast, source, scope, path) do
    expressions =
      case ast do
        {:__block__, _, list} -> list
        single -> [single]
      end

    case expressions do
      [{:=, _, [{:meta, _, ctx}, {:%{}, _, pairs}]} | rest] when is_atom(ctx) ->
        case literal_pairs(pairs) do
          {:ok, meta} ->
            meta = Map.put(meta, :__arg_order__, arg_order(pairs))
            problems = validate_meta(meta, path)

            definition = %Definition{
              name: meta[:name] || (path && Path.basename(path, ".exs")),
              scope: scope,
              path: path,
              source: source,
              meta: meta,
              ast: {:__block__, [], rest},
              problems: problems
            }

            if problems == [], do: {:ok, definition}, else: {:error, problems}

          :error ->
            {:error, ["meta must be a literal map"]}
        end

      _ ->
        {:error, ["the first expression must be `meta = %{…}` with a literal map"]}
    end
  end

  defp arg_order(pairs) do
    case Enum.find(pairs, fn {k, _v} -> k == :args end) do
      {:args, {:%{}, _, arg_pairs}} -> Enum.map(arg_pairs, fn {k, _v} -> k end)
      _ -> []
    end
  end

  defp literal_pairs(pairs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_atom(key) ->
        case literal(value) do
          {:ok, v} -> {:cont, {:ok, Map.put(acc, key, v)}}
          :error -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
  end

  defp literal({:%{}, _, pairs}), do: literal_pairs(pairs)

  defp literal(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case literal(item) do
        {:ok, v} -> {:cont, {:ok, acc ++ [v]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp literal({:-, _, [n]}) when is_number(n), do: {:ok, -n}

  defp literal({a, b}),
    do: with({:ok, x} <- literal(a), {:ok, y} <- literal(b), do: {:ok, {x, y}})

  defp literal(value) when is_atom(value) or is_number(value) or is_binary(value),
    do: {:ok, value}

  defp literal(_other), do: :error

  defp validate_meta(meta, path) do
    name = meta[:name]

    []
    |> add(not is_binary(name), "meta.name is required")
    |> add(
      is_binary(name) and not Regex.match?(@name_re, name),
      "meta.name must be lowercase letters, digits and hyphens (2-41 chars)"
    )
    |> add(
      is_binary(name) and is_binary(path) and Path.basename(path, ".exs") != name,
      "the file name must equal meta.name"
    )
    |> add(not is_binary(meta[:description]), "meta.description is required")
    |> add(
      is_binary(meta[:description]) and String.length(meta[:description]) > 200,
      "meta.description must be at most 200 characters"
    )
    |> add(
      not is_nil(meta[:phases]) and not valid_phases?(meta[:phases]),
      "meta.phases must be a list of strings or of %{title: \"…\", detail: \"…\"} maps"
    )
    |> add(
      not is_nil(meta[:when_to_use]) and
        not (is_binary(meta[:when_to_use]) and String.length(meta[:when_to_use]) <= 2048),
      "meta.when_to_use must be a string of at most 2048 characters"
    )
    |> add(
      not is_nil(meta[:budget]) and
        not (is_integer(meta[:budget]) and meta[:budget] in 1..1024),
      "meta.budget must be an integer between 1 and 1024"
    )
    |> add(
      not is_nil(meta[:max_live]) and
        not (is_integer(meta[:max_live]) and meta[:max_live] in 1..64),
      "meta.max_live must be an integer between 1 and 64"
    )
    |> Kernel.++(validate_args(meta[:args]))
  end

  # Spec 11 §R.1: `["Hunt", …]` or `[%{title: "Hunt", detail: "one agent per …"}]`.
  defp valid_phases?(phases) when is_list(phases) do
    Enum.all?(phases, fn
      phase when is_binary(phase) -> true
      %{title: title} -> is_binary(title)
      _other -> false
    end)
  end

  defp valid_phases?(_phases), do: false

  defp validate_args(nil), do: []

  defp validate_args(args) when is_map(args) do
    Enum.flat_map(args, fn {key, spec} ->
      cond do
        not is_map(spec) ->
          ["meta.args.#{key} must be a map"]

        spec[:type] && spec[:type] not in @arg_types ->
          [
            "meta.args.#{key}.type must be one of: " <>
              Enum.map_join(@arg_types, ", ", &to_string/1)
          ]

        spec[:type] == :enum and not is_list(spec[:values]) ->
          ["meta.args.#{key} is an enum and needs values: [\"…\"]"]

        spec[:type] != :enum and is_list(spec[:values]) ->
          ["meta.args.#{key}: values is only allowed for enum args"]

        true ->
          []
      end
    end)
  end

  defp validate_args(_other), do: ["meta.args must be a map"]

  defp add(problems, true, message), do: problems ++ [message]
  defp add(problems, _false, _message), do: problems

  @doc "Casts a raw args map against `meta.args`."
  defdelegate cast_args(meta, raw, rest \\ ""), to: Args, as: :cast

  # ------------------------------------------------------------------ files

  # Spec 13 §11 A-2: `workflow_save` / `workflow_delete` are auto-approved, so
  # the model-supplied name is the only thing between it and the file system —
  # `name: "../../x"` used to write anywhere. The name is a plain slug and the
  # final path must sit inside its scope directory.
  @name_error "workflow name must be lowercase letters, digits and dashes"

  @doc false
  def valid_name?(name), do: Regex.match?(@name_re, to_string(name))

  defp inside?(dir, path) do
    root = Path.expand(dir)
    full = Path.expand(path)
    full != root and String.starts_with?(full, root <> "/")
  end

  @doc "Writes a definition into the project or user scope."
  @spec save(map() | nil, String.t(), String.t(), String.t()) ::
          {:ok, Definition.t()} | {:error, term()}
  def save(project, scope, name, source) when scope in ["project", "user"] do
    name = to_string(name)

    cond do
      not valid_name?(name) ->
        {:error, @name_error}

      Enum.any?(builtins(), &(&1.name == name)) ->
        {:error, "#{name} is a built-in workflow — pick another name"}

      scope == "project" and is_nil(project) ->
        {:error, "no project to save into"}

      true ->
        dir = Workspace.ensure_dir!(scope_dir(project, scope))
        path = Path.join(dir, name <> ".exs")

        if not inside?(dir, path) do
          {:error, @name_error}
        else
          # Sakana requirement 2.4: saving runs the same allow-list validation as
          # `workflow_smoke_check`, so a definition that could never run safely
          # never reaches the disk.
          case parse(source, scope, path) do
            {:ok, definition} ->
              case SwarmCode.Domain.Workflows.Smoke.errors(definition) do
                [] ->
                  # Spec 32 §1: a half-written workflow is a workflow that will
                  # not parse, and the watcher would pick it up.
                  case SwarmCode.Domain.AtomicFile.replace(dir, path, source) do
                    :ok ->
                      Events.ui_broadcast({:workflows_changed})
                      {:ok, definition}

                    {:error, reason} ->
                      {:error,
                       "cannot write #{path}: #{SwarmCode.Domain.AtomicFile.format_error(reason)}"}
                  end

                problems ->
                  {:error, Enum.join(problems, "; ")}
              end

            {:error, problems} ->
              {:error, Enum.join(problems, "; ")}
          end
        end
    end
  end

  def save(_project, scope, _name, _source), do: {:error, "unknown scope #{scope}"}

  @doc "Deletes a project or user definition."
  def delete(project, scope, name) when scope in ["project", "user"] do
    name = to_string(name)
    dir = scope_dir(project, scope)
    path = dir && Path.join(dir, name <> ".exs")

    cond do
      not valid_name?(name) ->
        {:error, @name_error}

      is_nil(dir) or not inside?(dir, path) ->
        {:error, @name_error}

      true ->
        # spec 73 T107: the result of `File.rm/1` used to be discarded and the
        # deletion reported as done — a read-only file or volume came back on
        # the next listing with no error shown. A file already gone is `:ok`
        # (nothing changed, nothing to broadcast).
        case File.rm(path) do
          :ok ->
            Events.ui_broadcast({:workflows_changed})
            :ok

          {:error, :enoent} ->
            :ok

          {:error, reason} ->
            {:error, "cannot delete #{path}: #{:file.format_error(reason)}"}
        end
    end
  end

  def delete(_project, _scope, _name), do: {:error, "built-in workflows cannot be deleted"}

  @doc "The starter source `+ New workflow → Blank template` writes."
  @spec template(String.t()) :: String.t()
  def template(name \\ "my-workflow") do
    """
    meta = %{
      name: "#{name}",
      description: "What a run of this workflow does",
      phases: ["Plan", "Work", "Verify"],
      budget: 32,
      args: %{target: %{type: :string, required: true, doc: "What to work on"}}
    }

    phase("Plan")
    plan = agent("Make a short plan for: \#{args.target}. Reply with a numbered list of at most 5 concrete steps.", capability: :read_only)

    phase("Work")
    results = panel(1..3, fn i -> agent("Execute step \#{i} of this plan:\\n\#{plan}\\nReport what you did.", capability: :read_write) end)

    phase("Verify")
    check = agent("Verify this work was done correctly:\\n\#{Enum.join(Enum.filter(results, &present?/1), "\\n")}", capability: :read_only)
    complete(%{summary: check})
    """
  end

  @doc "Runs the smoke check of §4.4 / spec 11 §7.2."
  defdelegate smoke_check(definition_or_source, args \\ %{}, opts \\ []), to: Smoke, as: :check

  # ------------------------------------------------------------------ runs

  def get_run(run_id), do: Repo.get(Run, run_id)

  def get_run_by_display_name(name) do
    Repo.one(from(w in Run, where: w.display_name == ^name, limit: 1))
  end

  def insert_run(attrs), do: %Run{} |> Run.changeset(attrs) |> Repo.insert()

  @spec update_run(Run.t(), map()) ::
          {:ok, Run.t()} | {:error, Ecto.Changeset.t() | :database_busy}
  def update_run(%Run{} = run, attrs) do
    # spec 55 T6 (55a A3): retried, never raised.
    Repo.retry(:workflow_update_run, fn -> run |> Run.changeset(attrs) |> Repo.update() end)
  end

  @doc "`review-changes`, then `review-changes-2`, … across the whole database."
  @spec next_display_name(String.t()) :: String.t()
  def next_display_name(definition_name) do
    base = to_string(definition_name)

    taken =
      Repo.all(
        from(w in Run,
          where: w.display_name == ^base or like(w.display_name, ^(base <> "-%")),
          select: w.display_name
        )
      )
      |> MapSet.new()

    if MapSet.member?(taken, base) do
      Enum.find(2..10_000, &(not MapSet.member?(taken, "#{base}-#{&1}")))
      |> then(&"#{base}-#{&1}")
    else
      base
    end
  end

  @doc "Journal entries of a run, in order."
  def journal(run_id) do
    Repo.all(
      from(e in JournalEntry, where: e.run_id == ^run_id, order_by: [asc: :seq, asc: :slot])
    )
  end

  @spec insert_journal(map()) ::
          {:ok, JournalEntry.t()} | {:error, Ecto.Changeset.t() | :database_busy}
  def insert_journal(attrs) do
    # spec 55 T6 (55a A3)
    Repo.retry(:workflow_journal, fn ->
      %JournalEntry{} |> JournalEntry.changeset(attrs) |> Repo.insert()
    end)
  end

  @active ~w(running waiting_user paused interrupted)

  @doc "Runs for the dashboard: `%{run: run, wf: wf}` newest first."
  @spec list_runs(atom()) :: [map()]
  def list_runs(filter \\ :active) do
    query =
      from(w in Run,
        join: r in Conversations.Run,
        on: r.id == w.run_id,
        left_join: c in Conversations.Conversation,
        on: c.id == w.conversation_id,
        order_by: [desc: r.started_at],
        select: %{wf: w, run: r, conversation: c}
      )

    # spec 68 T29: raise on unknown filter instead of silently loading all rows
    query =
      case filter do
        :all -> query
        :active -> where(query, [w, r], r.status in ^@active)
        :waiting -> where(query, [w, r], r.status in ~w(waiting_user paused))
        :interrupted -> where(query, [w, r], r.status in ~w(interrupted))
        :done -> where(query, [w, r], r.status in ~w(done))
        :failed -> where(query, [w, r], r.status in ~w(failed stopped))
        other -> raise ArgumentError, "unknown workflow run filter: #{inspect(other)}"
      end

    Repo.all(query)
  end

  @doc """
  Spec 51 §5.9 (f): the runs parked on an unreachable provider — the one
  query the watchdog needs, instead of every waiting row with its logs.
  """
  @spec list_parked_infrastructure() :: [map()]
  def list_parked_infrastructure do
    Repo.all(
      from(w in Run,
        join: r in Conversations.Run,
        on: r.id == w.run_id,
        left_join: c in Conversations.Conversation,
        on: c.id == w.conversation_id,
        where: r.status == "paused" and w.pause_kind == "infrastructure",
        order_by: [desc: r.started_at],
        select: %{wf: w, run: r, conversation: c}
      )
    )
  end

  @doc "How many runs are running or waiting for the user (rail badge)."
  def active_count do
    Repo.one(
      from(w in Run,
        join: r in Conversations.Run,
        on: r.id == w.run_id,
        where: r.status in ["running", "waiting_user"],
        select: count(w.run_id)
      )
    ) || 0
  end

  @doc "The workflow rows of a conversation, keyed by run id."
  def for_conversation(conversation_id) do
    Repo.all(from(w in Run, where: w.conversation_id == ^conversation_id))
    |> Map.new(&{&1.run_id, &1})
  end

  # ------------------------------------------------------------------ launching

  @doc """
  Starts a run of `definition` (or of a one-off `source`) in `conversation`
  (spec 09 §5.1).
  """
  @spec launch(map()) :: {:ok, Run.t()} | {:error, term()}
  def launch(attrs) do
    settings = Settings.get()
    conversation = attrs.conversation
    project = attrs[:project] || SwarmCode.Domain.Projects.get!(conversation.project_id)

    with {:ok, definition} <- definition_for(attrs),
         {:ok, cast} <- cast_launch_args(definition, attrs) do
      declared =
        definition
        |> Definition.arg_specs()
        |> Map.new(fn {key, _spec} -> {Atom.to_string(key), key} end)
        |> Map.put("carry", :carry)

      args = merge_carry(cast, attrs[:carry], declared)
      display_name = next_display_name(definition.name || "adhoc")
      budget = attrs[:budget] || definition.meta[:budget] || settings.workflow_budget || 128

      max_live =
        attrs[:max_live] || definition.meta[:max_live] || settings.workflow_max_live || 16

      # spec 60 T55
      model = launch_model(attrs[:model], settings, conversation)

      prompt = "/" <> to_string(definition.name || "adhoc") <> " " <> args_text(args)

      # Spec 13 §11 A-4: the `runs` row used to be inserted (and broadcast)
      # before the workflow row, whose changeset rejects a model-supplied
      # budget / max_live out of range — the MatchError left an orphan run
      # spinning in the sidebar until the next restart. Validate first, then
      # create both rows in one transaction.
      with :ok <- validate_limits(budget, max_live),
           {:ok, {run, wf}} <-
             create_rows(conversation, prompt, model, %{
               run_id: nil,
               conversation_id: conversation.id,
               definition_name: definition.name,
               scope: definition.scope,
               display_name: display_name,
               source: definition.source,
               args: SwarmCode.Domain.Workflows.Runner.encodable(args),
               budget: budget,
               max_live: max_live,
               phases: Definition.phase_titles(definition.meta),
               phase_details: Definition.phase_details(definition.meta),
               created_by: attrs[:created_by] || "user",
               auto_continue: !!attrs[:auto_continue],
               launch_message_id: attrs[:launch_message_id]
             }) do
        # Spec 17 §2.6: the user message that launched this workflow points at
        # the run, so `launch_messages/3` never has to guess.
        link_launch_message(attrs[:launch_message_id], run)
        Conversations.broadcast_run_created(run)

        case start_run(run, wf, conversation, project, settings, definition, args, nil) do
          {:ok, _pid} ->
            broadcast(conversation.id, wf)
            {:ok, wf}

          {:error, reason} ->
            # Sakana task 6: both rows are committed by now, so a supervision
            # failure used to leave a run persisted as "running" with no process
            # behind it — the sidebar span forever.
            settle_start_failure(run, wf, reason)
            {:error, {:start_failed, reason}}
        end
      end
    end
  end

  defp link_launch_message(id, run) when is_binary(id) do
    case Conversations.get_message(id) do
      %{} = message -> Conversations.update_message(message, %{run_id: run.id})
      _ -> :ok
    end

    :ok
  end

  defp link_launch_message(_id, _run), do: :ok

  @doc false
  def validate_limits(budget, max_live) do
    cond do
      not is_integer(budget) or budget < 1 or budget > 1024 ->
        {:error, "budget must be a whole number between 1 and 1024"}

      not is_integer(max_live) or max_live < 1 or max_live > 64 ->
        {:error, "max_live must be a whole number between 1 and 64"}

      true ->
        :ok
    end
  end

  # Both rows or neither — and the `{:run_created, …}` broadcast only once the
  # transaction has committed, so the sidebar never sees a run that is gone.
  defp create_rows(conversation, prompt, model, wf_attrs) do
    result =
      Repo.transaction(fn ->
        {:ok, run} =
          Conversations.insert_run_row(%{
            conversation_id: conversation.id,
            kind: "workflow",
            prompt: String.trim(prompt),
            model: model && model.model,
            started_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
          })

        case insert_run(%{wf_attrs | run_id: run.id}) do
          {:ok, wf} -> {run, wf}
          {:error, changeset} -> Repo.rollback(changeset_message(changeset))
        end
      end)

    case result do
      {:ok, pair} -> {:ok, pair}
      {:error, reason} -> {:error, reason}
    end
  end

  defp changeset_message(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp definition_for(%{definition: %Definition{} = definition}), do: {:ok, definition}

  defp definition_for(%{source: source}) when is_binary(source) do
    # spec 60 T32: a one-off source (a model-authored `workflow_run`) passes the
    # same Smoke check a saved definition passes at save time.
    case parse(source, "adhoc", nil) do
      {:ok, definition} ->
        case Smoke.errors(definition) do
          [] -> {:ok, definition}
          problems -> {:error, {:invalid, problems}}
        end

      {:error, problems} ->
        {:error, {:invalid, problems}}
    end
  end

  defp definition_for(_attrs), do: {:error, :no_definition}

  defp cast_launch_args(definition, attrs) do
    raw = attrs[:args] || %{}

    case cast_args(definition.meta, raw, to_string(attrs[:rest] || "")) do
      {:ok, args} ->
        {:ok, args}

      {:error, problems} ->
        missing =
          for problem <- problems,
              [_, key] = Regex.run(~r/^(\w+) is required$/, problem) || [nil, nil],
              key,
              do: key

        if missing == [],
          do: {:error, {:bad_args, problems}},
          else: {:error, {:missing_args, missing}}
    end
  end

  defp args_text(args) do
    args
    |> Enum.reject(fn {_k, v} -> is_nil(v) or is_map(v) end)
    |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{value_text(v)}" end)
  end

  defp value_text(v) when is_list(v), do: Enum.map_join(v, ",", &value_text/1)
  defp value_text(v) when is_map(v), do: "…"
  defp value_text(v), do: to_string(v)

  # Spec 11 §R.7: results of an earlier run handed to this one. They are merged
  # into `args` (atom keys, so the script reads `args.carry`) and stored with
  # the run, so a resume replays with exactly the same input.
  defp merge_carry(args, carry, declared) when is_map(carry) and map_size(carry) > 0 do
    Enum.reduce(carry, args, fn {key, value}, acc ->
      Map.put(acc, safe_arg_key(key, declared), value)
    end)
  end

  defp merge_carry(args, _carry, _declared), do: args

  defp safe_arg_key(key, _declared) when is_atom(key), do: key
  defp safe_arg_key(key, declared) when is_binary(key), do: Map.get(declared, key, key)
  defp safe_arg_key(key, declared), do: safe_arg_key(to_string(key), declared)

  # Every persisted "running" row needs a live process behind it; when the start
  # fails, both rows settle terminally and the UI hears about it.
  @doc false
  def settle_start_failure(run, wf, reason) do
    reason = safe_reason(reason)

    # spec 73 T108: `update_run/2` answers `{:error, :database_busy}` once
    # `Repo.retry` gives up; a bare `{:ok, _} =` here raised MatchError inside
    # the very path meant to settle the run, leaving the row "running" with
    # no process behind it. The terminal write is best effort: logged, and
    # the broadcast still goes out.
    wf =
      best_effort(
        update_run(wf, %{
          pause_kind: "infrastructure",
          pause_message: "could not start this run: #{reason}"
        }),
        wf,
        "start failure of #{wf.display_name}"
      )

    run =
      best_effort(
        Conversations.update_run(run, %{status: "failed", finished_at: DateTime.utc_now()}),
        run,
        "failed status of #{wf.display_name}"
      )

    ensure_start_failure_message(run, "Workflow failed to start: #{reason}")

    broadcast(run.conversation_id, wf)
    :ok
  end

  defp ensure_start_failure_message(run, content) do
    exists? =
      Repo.exists?(
        from(m in Message,
          where:
            m.conversation_id == ^run.conversation_id and m.run_id == ^run.id and
              m.role == "assistant" and m.content == ^content
        )
      )

    unless exists? do
      {:ok, _message} =
        Conversations.create_message(%{
          conversation_id: run.conversation_id,
          run_id: run.id,
          role: "assistant",
          content: content
        })
    end

    :ok
  end

  # Resume already flipped the engine row to "running"; put back what it was.
  defp settle_resume_failure(run, wf, prior, reason) do
    raw_reason = reason
    reason = safe_reason(raw_reason)

    status =
      if prior in ["paused", "waiting_user", "interrupted", "stopped"], do: prior, else: nil

    if status do
      # spec 73 T108: best effort, as in `settle_start_failure/3`.
      wf =
        best_effort(
          update_run(wf, %{
            pause_kind: wf.pause_kind || "infrastructure",
            pause_message: wf.pause_message || "could not resume this run: #{reason}"
          }),
          wf,
          "resume failure of #{wf.display_name}"
        )

      # Re-read: the row was flipped to "running" by the resume, so a changeset
      # built from the stale struct would look like a no-op and never persist.
      best_effort(
        Conversations.update_run(Conversations.get_run!(run.id), %{
          status: status,
          finished_at: run.finished_at
        }),
        run,
        "#{status} status of #{wf.display_name}"
      )

      broadcast(run.conversation_id, wf)
      :ok
    else
      settle_start_failure(run, wf, raw_reason)
    end
  end

  defp safe_reason(reason), do: SwarmCode.Domain.LLM.HTTP.redact(inspect(reason))

  defp start_run(run, wf, conversation, project, settings, definition, args, answer) do
    start_supervised_run(%{
      run: run,
      conversation: conversation,
      project: project,
      project_context: ProjectContext.build(project, conversation),
      settings: settings,
      chat_model: resolve_model([], settings, conversation),
      swarm_model: nil,
      history: [],
      prompt: run.prompt,
      mode: "build",
      assistant_message: nil,
      workflow: %{
        wf: wf,
        ast: definition.ast,
        meta: definition.meta,
        args: args,
        answer: answer
      }
    })
  end

  # Tests force a start failure through this hook; production always goes to the
  # real supervisor.
  defp start_supervised_run(payload) do
    case Application.get_env(:swarm_code_daemon, :workflow_run_starter) do
      fun when is_function(fun, 1) -> fun.(payload)
      _ -> RunSupervisor.start_run(payload)
    end
  end

  # ------------------------------------------------------------------ control

  @doc "Pause, resume or stop a run (spec 09 §5.4)."
  @spec control(String.t(), :pause | :resume | :stop, keyword()) :: :ok | {:error, term()}
  def control(run_id, action, opts \\ [])

  def control(run_id, :pause, _opts) do
    case SwarmCode.Domain.Workflows.Runner.pause(run_id) do
      :ok ->
        :ok

      _ ->
        # spec 60 T37: only a run that is still going has anything to pause — the
        # fallback used to flip a finished row to paused and move its finished_at.
        # spec 73 T43: the run the guard fetched is the one set_status writes.
        with %Run{} = wf <- get_run(run_id),
             %{status: status} = run when status in ["running", "waiting_user"] <-
               Conversations.get_run(run_id) do
          set_status(wf, run, "paused", %{
            pause_kind: "manual",
            pause_message: "Paused by the user"
          })

          :ok
        else
          nil -> {:error, :not_found}
          _ -> {:error, :not_running}
        end
    end
  end

  def control(run_id, :stop, _opts) do
    SwarmCode.Domain.Engine.RunServer.stop(run_id)

    # spec 67 T12 (B17): `get_run!/1` for a `runs` row the retention sweep may
    # already have deleted raised `Ecto.NoResultsError` out of a control call
    # that has `{:error, :not_found}` in its contract.
    with %Run{} = wf <- get_run(run_id),
         %{status: status} = run when status not in ["done", "failed", "stopped"] <-
           Conversations.get_run(run_id) do
      set_status(wf, run, "stopped", %{})
    end

    :ok
  end

  def control(run_id, :resume, opts) do
    wf = get_run(run_id)
    # spec 67 T12 (B17): a missing `runs` row is `{:error, :not_found}` too, not
    # an `Ecto.NoResultsError` in the LiveView.
    run = wf && Conversations.get_run(run_id)

    cond do
      is_nil(wf) or is_nil(run) ->
        {:error, :not_found}

      run.status not in ["paused", "waiting_user", "interrupted", "stopped"] ->
        {:error, :not_paused}

      wf.pause_kind == "budget" and
          (not is_integer(opts[:budget]) or opts[:budget] <= wf.agents_admitted) ->
        {:error, :budget_too_low}

      true ->
        do_resume(wf, run, opts)
    end
  end

  defp do_resume(wf, run, opts) do
    settings = Settings.get()
    conversation = Conversations.get!(wf.conversation_id)
    project = SwarmCode.Domain.Projects.get!(conversation.project_id)
    prior = run.status
    was = run

    # Spec 51 §5.11: the budget is what the journal proves was admitted — a
    # pause mid-agent had charged a slot the journal never saw.
    {:ok, wf} =
      update_run(wf, %{
        budget: opts[:budget] || wf.budget,
        agents_admitted: admitted_from_journal(run.id),
        pause_kind: nil,
        pause_message: nil,
        gate_question: nil,
        gate_options: []
      })

    {:ok, run} =
      Conversations.update_run(run, %{status: "running", finished_at: nil, interrupted: false})

    case parse(wf.source, wf.scope || "adhoc", nil) do
      {:ok, definition} ->
        args = atomize_args(definition.meta, wf.args)
        answer = opts[:answer]

        case start_run(run, wf, conversation, project, settings, definition, args, answer) do
          {:ok, _pid} ->
            broadcast(conversation.id, wf)
            :ok

          {:error, reason} ->
            settle_resume_failure(was, wf, prior, reason)
            {:error, {:start_failed, reason}}
        end

      {:error, problems} ->
        settle_resume_failure(was, wf, prior, {:invalid, problems})
        {:error, {:invalid, problems}}
    end
  end

  @doc """
  Re-runs only the failed slots of a run (spec 11 §7.6): their journal entries
  are dropped, every committed result stays, and the run resumes — so the
  agents that did come back are not paid for twice.
  """
  @spec retry_failed(String.t()) :: :ok | {:error, term()}
  def retry_failed(run_id) do
    wf = get_run(run_id)
    # spec 68 T21: use get_run (not get_run!) to match control/3 :resume
    run = wf && Conversations.get_run(run_id)

    cond do
      is_nil(wf) or is_nil(run) ->
        {:error, :not_found}

      run.status == "running" ->
        {:error, :running}

      true ->
        all = journal(run_id)

        case Enum.filter(all, &failed_entry?/1) do
          [] ->
            {:error, :nothing_to_retry}

          entries ->
            # Spec 51 §5.11: the entries go and the resume recomputes the
            # admissions from what is left of the journal — no refund
            # arithmetic (spec 13 §11 A-12 did it by hand).
            Enum.each(entries, &Repo.delete/1)

            {:ok, _run} =
              Conversations.update_run(run, %{
                status: "paused",
                finished_at: nil,
                interrupted: false
              })

            control(run_id, :resume, [])
        end
    end
  end

  @doc """
  Spec 51 §5.11: the admissions the journal proves — one per committed `agent`
  entry outside a panel, and for each panel the count its `panel` entry
  recorded when the whole panel was charged at once.
  """
  @spec admitted_from_journal(String.t()) :: non_neg_integer()
  def admitted_from_journal(run_id) do
    all = journal(run_id)

    singles = Enum.count(all, &(&1.kind == "agent" and not panel_slot?(all, &1)))

    panels =
      all
      |> Enum.filter(&(&1.kind == "panel" and &1.slot == -1))
      |> Enum.map(fn entry ->
        case entry.result && Jason.decode(entry.result) do
          {:ok, %{"value" => count}} when is_integer(count) and count >= 0 -> count
          _other -> 0
        end
      end)
      |> Enum.sum()

    singles + panels
  end

  defp failed_entry?(%JournalEntry{kind: "agent", result: result}) when is_binary(result) do
    match?({:ok, %{"ok" => false}}, Jason.decode(result))
  end

  defp failed_entry?(_entry), do: false

  # A panel's slots share their `seq` with the `{seq, -1}` "panel" entry that
  # paid for all of them at once.
  defp panel_slot?(journal, %JournalEntry{seq: seq}) do
    Enum.any?(journal, &match?(%JournalEntry{seq: ^seq, slot: -1, kind: "panel"}, &1))
  end

  @doc "Turns the stored (JSON) args back into the map the script sees."
  def atomize_args(meta, args) when is_map(args) do
    declared = Map.get(meta, :args) || %{}

    Map.new(args, fn {k, v} ->
      cond do
        # spec 60 T37: `launch/1` merges the carry under `:carry`; a resume must
        # hand it back under the same key or `args[:carry]` reads nil after a gate.
        to_string(k) == "carry" ->
          {:carry, v}

        true ->
          case Enum.find(Map.keys(declared), &(to_string(&1) == to_string(k))) do
            nil -> {k, v}
            atom -> {atom, v}
          end
      end
    end)
  end

  def atomize_args(_meta, _args), do: %{}

  # spec 73 T43: both callers fetch the engine run with `get_run/1` in their
  # guards (the spec 67 T12 contract); re-fetching it here with `get_run!/1`
  # re-opened the raise window on a retention-swept row and cost a query.
  defp set_status(%Run{} = wf, %Conversations.Run{} = run, status, attrs) do
    # spec 73 T108: best effort, as in `settle_start_failure/3`.
    wf = best_effort(update_run(wf, attrs), wf, "#{status} of #{wf.display_name}")

    best_effort(
      Conversations.update_run(run, %{
        status: status,
        finished_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
      }),
      run,
      "#{status} status of #{wf.display_name}"
    )

    broadcast(wf.conversation_id, wf)
    :ok
  end

  # spec 73 T108: a settle write that did not land is logged, and the caller
  # carries on with the row it had — never a MatchError out of a settle path.
  defp best_effort({:ok, row}, _row, _what), do: row

  defp best_effort({:error, reason}, row, what) do
    Logger.warning("swarm_code workflows: #{what} was not persisted: #{inspect(reason)}")
    row
  end

  @doc """
  Finds a run by its display name, or by a definition name when exactly one
  active run of it exists (spec 09 §5.4).
  """
  @spec resolve_run(String.t(), String.t() | nil) ::
          {:ok, Run.t()} | {:error, :not_found | {:ambiguous, [String.t()]}}
  def resolve_run(handle, project_id \\ nil) do
    handle = to_string(handle) |> String.trim()

    case get_run_by_display_name(handle) do
      %Run{} = wf ->
        # spec 60 T36: the assistant's tools pass their project; a run of another
        # project is not theirs to see or control.
        if project_id == nil or
             match?(%{project_id: ^project_id}, Conversations.get(wf.conversation_id)),
           do: {:ok, wf},
           else: {:error, :not_found}

      nil ->
        candidates =
          list_runs(:active)
          |> Enum.filter(&(&1.wf.definition_name == handle))
          |> Enum.filter(
            &(project_id == nil or
                (&1.conversation && &1.conversation.project_id == project_id))
          )

        case candidates do
          [%{wf: wf}] -> {:ok, wf}
          [] -> {:error, :not_found}
          many -> {:error, {:ambiguous, Enum.map(many, & &1.wf.display_name)}}
        end
    end
  end

  @doc """
  Launches the same workflow again with the previous run's result handed to it
  as `args.carry` (spec 11 §R.7 — "Run again with these results…").
  """
  @spec run_again(String.t()) :: {:ok, Run.t()} | {:error, term()}
  def run_again(run_id) do
    with %Run{} = wf <- get_run(run_id),
         conversation when not is_nil(conversation) <- Conversations.get(wf.conversation_id),
         {:ok, definition} <- parse(wf.source, wf.scope || "adhoc", nil) do
      launch(%{
        conversation: conversation,
        project: SwarmCode.Domain.Projects.get(conversation.project_id),
        definition: definition,
        args: Map.new(wf.args || %{}, fn {k, v} -> {to_string(k), v} end),
        carry: %{"carry" => decode_result(wf.result)},
        created_by: "user"
      })
    else
      nil -> {:error, :not_found}
      {:error, problems} -> {:error, {:invalid, problems}}
    end
  end

  defp decode_result(nil), do: nil

  defp decode_result(json) do
    case Jason.decode(json) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  @doc "Saves the frozen script of a run as a new definition (spec 09 §5.6)."
  def save_run_as(run_id, project, scope, new_name) do
    wf = get_run(run_id)
    new_name = to_string(new_name)

    cond do
      is_nil(wf) ->
        {:error, :not_found}

      wf.scope == "builtin" ->
        {:error, "built-in workflows cannot be saved under a new name from a run"}

      not Regex.match?(@name_re, new_name) ->
        {:error, "the name must be lowercase letters, digits and hyphens"}

      Enum.any?(list_all(project), &(&1.name == new_name)) ->
        {:error, "#{new_name} already exists"}

      true ->
        save(project, scope, new_name, rename_source(wf.source, new_name))
    end
  end

  @doc false
  def rename_source(source, new_name) do
    String.replace(source, ~r/name:\s*"[^"]*"/, "name: \"#{new_name}\"", global: false)
  end

  # ------------------------------------------------------------------ models

  @doc """
  The model a workflow agent runs on: the `model:`/`provider:` opts, then the
  workflow default, then the swarm default, then the conversation's chat model.
  """
  @spec resolve_model(keyword(), map(), map() | nil) ::
          %{provider: term(), model: String.t()} | nil
  def resolve_model(opts, settings, conversation \\ nil) do
    by_name(opts[:model], opts[:provider]) ||
      by_id(settings.default_workflow_provider_id, settings.default_workflow_model) ||
      by_id(settings.default_swarm_provider_id, settings.default_swarm_model) ||
      conversation_model(conversation)
  end

  # spec 60 T55: the Workflows page's launch form posts `"<provider_id>|<model>"`;
  # an unknown or empty pick falls back to the defaults exactly as before.
  defp launch_model(pick, settings, conversation) do
    case String.split(to_string(pick || ""), "|", parts: 2) do
      [pid, m] when pid != "" and m != "" ->
        by_id(pid, m) || resolve_model([], settings, conversation)

      _ ->
        resolve_model([], settings, conversation)
    end
  end

  defp by_name(nil, _provider), do: nil

  defp by_name(model, provider_name) do
    # spec 55 T14 (55a A9)
    SwarmCode.Domain.Cache.fetch({:providers, :all}, &Providers.list/0)
    |> Enum.filter(fn p -> is_nil(provider_name) or p.name == to_string(provider_name) end)
    |> Enum.find_value(fn p ->
      if to_string(model) in (p.models || []), do: %{provider: p, model: to_string(model)}
    end)
  end

  defp by_id(provider_id, model) when is_binary(provider_id) and is_binary(model) do
    # spec 55 T14 (55a A9)
    case Providers.get_cached(provider_id) do
      nil -> nil
      provider -> %{provider: provider, model: model}
    end
  end

  defp by_id(_provider_id, _model), do: nil

  defp conversation_model(nil), do: nil

  defp conversation_model(conversation) do
    case Providers.effective_model(conversation, :chat) do
      {:ok, model} -> model
      _ -> nil
    end
  end

  @doc "The effort workflow agents use."
  def effort(opts, settings) do
    opts[:effort] || settings.default_workflow_effort || "medium"
  end

  # ------------------------------------------------------------------ pubsub

  @doc """
  Announces a workflow run **whose status moved** (spec 54 §1.4, 54a A5).

  `{:workflow_runs_changed}` costs every open window two counting queries
  (`active_count/0` + `Research.running_count/0`), so only a launch, a start
  failure, a resume and `set_status/3` may send it — verified: those are this
  function's only callers. A log line, a phase and a budget charge go through
  `Runner.update_wf/2`, which sends `{:workflow_updated, wf}` on the
  conversation topic and nothing else.
  """
  def broadcast(conversation_id, wf) do
    if conversation_id, do: Events.broadcast(conversation_id, {:workflow_updated, wf})
    Events.ui_broadcast({:workflow_runs_changed})
    :ok
  end
end
