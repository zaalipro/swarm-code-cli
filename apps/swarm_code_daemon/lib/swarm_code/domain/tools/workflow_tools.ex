defmodule SwarmCode.Domain.Tools.WorkflowTools do
  @moduledoc """
  The five workflow tools of the root assistant (spec 09 §5.7). They are never
  offered to a lead, a sub-agent or a workflow worker.
  """

  alias SwarmCode.Domain.{Conversations, Workflows}
  alias SwarmCode.Domain.Workflows.Definition

  @doc false
  def project(ctx) do
    with id when is_binary(id) <- Map.get(ctx, :project_id) do
      SwarmCode.Domain.Projects.get(id)
    else
      _ -> nil
    end
  end

  @doc false
  def conversation(ctx) do
    with id when is_binary(id) <- Map.get(ctx, :conversation_id) do
      Conversations.get(id)
    else
      _ -> nil
    end
  end

  @doc false
  def describe(%Definition{} = definition) do
    meta = definition.meta

    args =
      definition
      |> Definition.arg_specs()
      |> Enum.map_join(", ", fn {key, spec} ->
        "#{key}: #{spec[:type] || :string}#{if spec[:required], do: "*", else: ""}"
      end)

    "  /#{definition.name} — #{meta[:description]} — phases: " <>
      "#{Enum.join(Definition.phase_titles(meta), " → ")} — budget #{meta[:budget] || "default"}" <>
      if(args == "", do: "", else: " — args: " <> args) <>
      case Definition.when_to_use(meta) do
        nil -> ""
        text -> "\n      use it when: " <> text
      end
  end

  @doc false
  def smoke_text(smoke) do
    phases =
      Enum.map_join(smoke.phases, ", ", fn p ->
        "#{p.title} (#{p.agents} agents#{if p.panels != [], do: ", panels " <> Enum.join(p.panels, "/"), else: ""})"
      end)

    """
    ok: #{smoke.ok?}
    ended: #{smoke.ended}#{if smoke.error, do: "\n error: " <> smoke.error, else: ""}
    phases: #{phases}
    agents: #{smoke.agents_total} · max fan-out: #{smoke.max_panel} · gates: #{smoke.gates}
    warnings:#{if smoke.warnings == [], do: " none", else: "\n- " <> Enum.join(smoke.warnings, "\n- ")}
    """
  end

  @doc false
  def json(smoke) do
    Jason.encode!(%{
      ok: smoke.ok?,
      ended: smoke.ended,
      error: smoke.error,
      phases: Enum.map(smoke.phases, &%{title: &1.title, agents: &1.agents, panels: &1.panels}),
      agents_total: smoke.agents_total,
      max_panel: smoke.max_panel,
      warnings: smoke.warnings
    })
  end

  @doc false
  def in_workflow?(ctx) do
    case Map.get(ctx, :run_id) do
      nil -> false
      run_id -> match?(%{kind: "workflow"}, safe_run(run_id))
    end
  end

  defp safe_run(run_id) do
    Conversations.get_run!(run_id)
  rescue
    _ -> nil
  end

  @doc false
  def workflows_for(ctx), do: Workflows.list(project(ctx))

  @doc "The project root the smoke check reads the real tree from (spec 11 §7.2)."
  def root(ctx) do
    case project(ctx) do
      %{root_path: root} when is_binary(root) -> root
      _ -> Map.get(ctx, :project_root)
    end
  end
end

defmodule SwarmCode.Domain.Tools.WorkflowList do
  @moduledoc "Lists the workflow definitions and the runs that are still going."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Tools.WorkflowTools
  alias SwarmCode.Domain.Workflows

  @impl true
  def name, do: "workflow_list"

  @impl true
  def description,
    do:
      "List the workflow definitions available here (built-in, project, user) and the workflow " <>
        "runs that are running or waiting."

  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}}

  @impl true
  def permission(_args), do: :read

  @impl true
  def title(_args), do: "workflow_list"

  @impl true
  def run(_args, ctx, _progress) do
    definitions = WorkflowTools.workflows_for(ctx)
    project = WorkflowTools.project(ctx)

    by_scope =
      for scope <- ["builtin", "project", "user"],
          group = Enum.filter(definitions, &(&1.scope == scope)),
          group != [],
          do: "#{scope}:\n" <> Enum.map_join(group, "\n", &WorkflowTools.describe/1)

    runs =
      Workflows.list_runs(:active)
      # spec 60 T36: only the caller's project's runs
      |> Enum.filter(fn %{conversation: conversation} ->
        project == nil or (conversation && conversation.project_id == project.id)
      end)
      |> Enum.map_join("\n", fn %{wf: wf, run: run} ->
        "  #{wf.display_name} — #{run.status}#{if wf.phase, do: " — " <> wf.phase, else: ""} — " <>
          "#{wf.agents_admitted}/#{wf.budget} agents"
      end)

    {:ok,
     Enum.join(by_scope, "\n\n") <>
       "\n\nActive runs:\n" <> if(runs == "", do: "  none", else: runs)}
  end
end

defmodule SwarmCode.Domain.Tools.WorkflowSmokeCheck do
  @moduledoc "Checks a workflow source against canned host results before it is saved."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Tools.WorkflowTools
  alias SwarmCode.Domain.Workflows

  @impl true
  def name, do: "workflow_smoke_check"

  @impl true
  # Spec 54 §5 (54c M3): `workflow_save` enforces the check itself, so ordering
  # the model about here was a behavioural instruction in a rival tool's
  # contract. What it needs instead is that the check is free and what "0
  # agents" means.
  def description,
    do:
      "Check a workflow definition without spending any agents: it must parse, its meta must " <>
        "be valid, and the path the given args select must run to completion against canned " <>
        "agent results. The read-only host helpers run against the real project, so a work " <>
        "list that comes back empty (\"0 agents\") means the discovery is wrong, not that the " <>
        "check failed. Returns the phases, the agent count and the first error, if any."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "source" => %{"type" => "string", "description" => "The whole workflow script"},
        "args" => %{"type" => "object", "description" => "Representative args for one path"}
      },
      "required" => ["source"]
    }
  end

  @impl true
  def permission(_args), do: :read

  @impl true
  def title(_args), do: "workflow_smoke_check"

  @impl true
  def run(args, ctx, _progress) do
    opts = [root: WorkflowTools.root(ctx)]

    case Workflows.smoke_check(to_string(args["source"]), args["args"] || %{}, opts) do
      {:ok, smoke} ->
        {:ok, WorkflowTools.smoke_text(smoke) <> "\n" <> WorkflowTools.json(smoke)}

      {:error, problems} ->
        {:error, "the definition does not check out:\n- " <> Enum.join(problems, "\n- ")}
    end
  end
end

defmodule SwarmCode.Domain.Tools.WorkflowSave do
  @moduledoc "Saves a smoke-checked workflow definition into the project or user scope."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Tools.WorkflowTools
  alias SwarmCode.Domain.Workflows

  @impl true
  def name, do: "workflow_save"

  @impl true
  def description,
    do:
      "Save a workflow definition so it can be launched by name. The tool runs the smoke " <>
        "check itself and refuses to save a definition that does not pass."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "description" => "lowercase letters, digits, hyphens"},
        "scope" => %{"type" => "string", "enum" => ["project", "user"]},
        "source" => %{"type" => "string", "description" => "The whole workflow script"}
      },
      "required" => ["name", "scope", "source"]
    }
  end

  @impl true
  def permission(_args), do: :write

  @impl true
  def title(args), do: "workflow_save " <> to_string(args["name"] || "")

  @impl true
  def run(args, ctx, _progress) do
    source = to_string(args["source"])

    with {:ok, smoke} <- Workflows.smoke_check(source, %{}, root: WorkflowTools.root(ctx)),
         true <- smoke.ok? or {:not_ok, smoke},
         {:ok, definition} <-
           Workflows.save(
             WorkflowTools.project(ctx),
             to_string(args["scope"]),
             to_string(args["name"]),
             source
           ) do
      clear_authoring(ctx)

      {:ok,
       "Saved /#{definition.name} (#{definition.scope}). Launch it with " <>
         "workflow_run or /#{definition.name}."}
    else
      {:not_ok, smoke} ->
        {:error, "the smoke check did not pass:\n" <> WorkflowTools.smoke_text(smoke)}

      {:error, problems} when is_list(problems) ->
        {:error, "the definition does not check out:\n- " <> Enum.join(problems, "\n- ")}

      {:error, reason} ->
        {:error, to_string(reason)}
    end
  end

  defp clear_authoring(ctx) do
    case WorkflowTools.conversation(ctx) do
      nil ->
        :ok

      conversation ->
        SwarmCode.Domain.Conversations.update(conversation, %{authoring_workflow: false})
    end
  end
end

defmodule SwarmCode.Domain.Tools.WorkflowRun do
  @moduledoc "Launches a workflow run in the background."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Tools.WorkflowTools
  alias SwarmCode.Domain.Workflows

  @impl true
  def name, do: "workflow_run"

  @impl true
  def description,
    do:
      "Launch a workflow run in the background. Give either the name of a saved workflow or a " <>
        "one-off source together with a budget. The run does not block: you are re-invoked " <>
        "with its result when it finishes."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "description" => "A saved workflow name"},
        "source" => %{"type" => "string", "description" => "A one-off workflow script"},
        "args" => %{"type" => "object", "description" => "The run's args"},
        "carry" => %{
          "type" => "object",
          "description" =>
            "Results of an earlier run handed to this one; the script reads them as args.<key>"
        },
        "budget" => %{"type" => "integer", "description" => "Agent budget (required with source)"},
        "continue" => %{"type" => "boolean", "description" => "Re-invoke you with the result"}
      }
    }
  end

  @impl true
  def permission(_args), do: :execute

  @impl true
  def title(args), do: "workflow_run " <> to_string(args["name"] || "(one-off)")

  @impl true
  def run(args, ctx, _progress) do
    conversation = WorkflowTools.conversation(ctx)

    cond do
      WorkflowTools.in_workflow?(ctx) ->
        {:error, "workflows do not launch workflows"}

      is_nil(conversation) ->
        {:error, "no conversation to launch into"}

      true ->
        launch(args, ctx, conversation)
    end
  end

  defp launch(args, ctx, conversation) do
    project = WorkflowTools.project(ctx)

    base = %{
      conversation: conversation,
      project: project,
      args: args["args"] || %{},
      carry: args["carry"] || %{},
      budget: args["budget"],
      created_by: "model",
      auto_continue: Map.get(args, "continue", true)
    }

    attrs =
      cond do
        is_binary(args["name"]) and args["name"] != "" ->
          case Workflows.get(project, args["name"]) do
            nil -> nil
            definition -> Map.put(base, :definition, definition)
          end

        is_binary(args["source"]) ->
          Map.put(base, :source, args["source"])

        true ->
          :missing
      end

    case attrs do
      nil ->
        {:error, "no workflow named #{args["name"]} — call workflow_list first"}

      :missing ->
        {:error, "give either name or source"}

      attrs ->
        case Workflows.launch(attrs) do
          {:ok, wf} ->
            {:ok,
             "Started #{wf.display_name}. It runs in the background; you will be re-invoked " <>
               "with the result."}

          {:error, {:missing_args, keys}} ->
            {:error, "missing required args: " <> Enum.join(keys, ", ")}

          {:error, {:bad_args, problems}} ->
            {:error, Enum.join(problems, "; ")}

          {:error, {:invalid, problems}} ->
            {:error, "the definition does not check out: " <> Enum.join(problems, "; ")}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
    end
  end
end

defmodule SwarmCode.Domain.Tools.WorkflowControl do
  @moduledoc "Pauses, resumes or stops a workflow run by display name."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Tools.WorkflowTools
  alias SwarmCode.Domain.Workflows

  @impl true
  def name, do: "workflow_control"

  @impl true
  def description, do: "Pause, resume or stop a workflow run by its display name."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "run" => %{"type" => "string", "description" => "The run's display name"},
        "action" => %{"type" => "string", "enum" => ["pause", "resume", "stop"]},
        "budget" => %{"type" => "integer", "description" => "A higher agent budget on resume"}
      },
      "required" => ["run", "action"]
    }
  end

  # Sakana task 19: pause/resume/stop mutate live work, so this is `:execute`,
  # not `:read` — read-only projects deny it and plan mode never sees it. The
  # UI controls are user events and call `Workflows.control/3` directly.
  @impl true
  def permission(_args), do: :execute

  @impl true
  def title(args), do: "workflow_control #{args["action"]} #{args["run"]}"

  @impl true
  def run(args, ctx, _progress) do
    action = to_string(args["action"])
    # spec 60 T36: a run of another project resolves as unknown
    project = WorkflowTools.project(ctx)

    with true <- action in ["pause", "resume", "stop"] or {:bad, action},
         {:ok, wf} <- Workflows.resolve_run(to_string(args["run"]), project && project.id) do
      opts = if args["budget"], do: [budget: args["budget"]], else: []

      case Workflows.control(wf.run_id, String.to_existing_atom(action), opts) do
        :ok -> {:ok, "#{wf.display_name}: #{action}"}
        {:error, :budget_too_low} -> {:error, "resume needs a budget above #{wf.agents_admitted}"}
        {:error, reason} -> {:error, inspect(reason)}
      end
    else
      {:bad, action} -> {:error, "unknown action #{action}"}
      {:error, {:ambiguous, names}} -> {:error, "which run? " <> Enum.join(names, ", ")}
      {:error, :not_found} -> {:error, "no run named #{args["run"]}"}
    end
  end
end
