defmodule SwarmCode.Domain.Tools.SpawnAgent do
  @moduledoc "Delegate a sub-task to a new sub-agent."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.{Agents, Engine.RunServer}
  alias SwarmCode.Domain.Tools.AgentTitle

  @impl true
  def name, do: "spawn_agent"

  @impl true
  # Spec 54 §5 (54c H9): the call blocks until the sub-agent finishes
  # (`RunServer.await_agent/3`), which the old "runs in parallel" contradicted.
  # spec 72 A3: the description lists available pre-defined agents so the model
  # can pick one by name.
  def description do
    base =
      "Delegate one self-contained sub-task to a new sub-agent and return its final report. " <>
        "The sub-agent starts with no history of this conversation, so its task has to carry " <>
        "the scope, the files it owns and what finishing looks like. Several spawn_agent " <>
        "calls in the same response start together, up to the run's concurrency limit, and " <>
        "the rest queue; this call does not return until that sub-agent has finished, so " <>
        "issue the independent ones in one response rather than one per turn."

    # spec 72 A3: bundled only in the static description (project root
    # unavailable here); the full list is in the tool call context.
    agents = Agents.list(nil)

    if agents == [] do
      base
    else
      names = Enum.map_join(agents, ", ", & &1.name)

      base <>
        " Available pre-defined agents: #{names}." <>
        " An agent's tool allow-list restricts work tools only;" <>
        " orchestration tools (inbox, message_agent, ask_user, etc.) are always available."
    end
  end

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "description" => "short agent name, max 24 chars"},
        # pass75 (CLI): the display name the side panel shows instead of name.
        "title" => %{
          "type" => "string",
          "description" =>
            "a display name in sentence case, 1-3 words, e.g. \"Build check\"; the panel shows it instead of name"
        },
        "task" => %{
          "type" => "string",
          "description" => "precise task, files it owns, expected output"
        },
        "context" => %{"type" => "string", "description" => "extra context from the lead"},
        # spec 72 A3: pre-defined agent, model and effort overrides
        "agent" => %{
          "type" => "string",
          "description" =>
            "Name of a pre-defined agent. When set, the agent's tools, model, " <>
              "effort, max_turns and system prompt are loaded from its definition. " <>
              "The task and context parameters still apply on top."
        },
        "model" => %{
          "type" => "string",
          "description" =>
            "Override the model for this sub-agent (e.g. 'claude-sonnet-4-20250514'). " <>
              "When omitted, uses the agent definition's model or the run's worker model."
        },
        "effort" => %{
          "type" => "string",
          "description" =>
            "Override the effort level for this sub-agent " <>
              "(low, medium, high, xhigh, max). When omitted, uses the agent " <>
              "definition's effort or the run's effort."
        },
        # spec 70 C6: background sub-agents
        "background" => %{
          "type" => "boolean",
          "description" =>
            "Start the sub-agent and return immediately without waiting for " <>
              "its result. You will be notified automatically when it " <>
              "finishes — do not poll or duplicate its work."
        },
        # spec 72 C5: structured output schema for sub-agents.
        "output_schema" => %{
          "type" => "object",
          "description" =>
            "JSON Schema the sub-agent must answer with via structured_output. " <>
              "When set, the sub-agent gets the structured_output tool and must " <>
              "call it with data matching this schema."
        }
      },
      "required" => ["name", "task"]
    }
  end

  @impl true
  def permission(_args), do: :read

  @impl true
  def title(args), do: "agent " <> SwarmCode.Domain.Tools.arg_text(args["name"] || "")

  @impl true
  def run(args, ctx, progress) do
    name = String.slice(SwarmCode.Domain.Tools.arg_text(args["name"] || ""), 0, 24)
    background? = args["background"] == true
    progress.(nil, "starting")

    # spec 72 A3: resolve agent definition and validate effort
    # spec 74 BUGS-12: the model's argument types are checked here, in the op
    # process — a map `task` crashed the RunServer (`task <> "…"` in
    # `Prompts.sub_agent_user/2`) and a shorthand schema crashed it later in
    # `Schema.to_json_schema/1`, after the lead had been told "started". The
    # RunSup is one_for_all, so the whole run died.
    with :ok <- depth_ok(ctx),
         :ok <- validate_args(args),
         {:ok, agent_def} <- resolve_agent(args, ctx),
         :ok <- validate_effort(args["effort"]) do
      attrs = %{
        parent_id: ctx.node_id,
        name: name,
        task: args["task"],
        context: args["context"],
        depth: ctx.depth + 1,
        agent_def: agent_def,
        model_override: args["model"],
        effort_override: args["effort"],
        # spec 72 C5: structured output schema for sub-agents.
        output_schema: args["output_schema"],
        # pass75 (CLI): the Lead's display name for the agent.
        title: AgentTitle.clean(args["title"], name)
      }

      case RunServer.start_agent(ctx.run_id, attrs) do
        {:ok, agent_id} ->
          if background? do
            # spec 70 C6: register the background agent and return immediately.
            # spec 73 T56 / T103 (F1): the clock is the RunServer's own timer,
            # armed by this registration and cancelled with the agent — the
            # tool used to spawn a second, unowned watchdog beside it.
            RunServer.register_background(ctx.run_id, agent_id, ctx[:agent_node_id])

            progress.(100, "started in background")

            {:ok,
             "Agent #{name} started in the background. " <>
               "You will be notified automatically when it finishes. " <>
               "Do not poll or duplicate its work."}
          else
            progress.(nil, "running")
            await(name, ctx, agent_id)
          end

        error ->
          error
      end
    end
  end

  @valid_efforts ~w(low medium high xhigh max)

  defp validate_effort(nil), do: :ok

  defp validate_effort(value) when value in @valid_efforts, do: :ok

  defp validate_effort(value) do
    {:error,
     "invalid effort '#{SwarmCode.Domain.Tools.arg_text(value)}' — use one of low, medium, high, " <>
       "xhigh, max"}
  end

  # spec 74 BUGS-12
  defp validate_args(args) do
    cond do
      not (is_binary(args["task"]) and String.trim(args["task"]) != "") ->
        {:error, "task must be a non-empty string"}

      not (is_nil(args["context"]) or is_binary(args["context"])) ->
        {:error, "context must be a string"}

      not (is_nil(args["model"]) or is_binary(args["model"])) ->
        {:error, "model must be a string"}

      true ->
        case schema_problem(args["output_schema"], "output_schema") do
          nil -> :ok
          problem -> {:error, problem <> " — see the JSON-schema subset in the tool description"}
        end
    end
  end

  @schema_types ~w(object array string integer number boolean null)

  @doc false
  # A total check of the JSON-schema subset `Workflows.Schema.to_json_schema/1`
  # and `validate/2` understand: nil when `schema` is usable, else what is
  # wrong with it. Every `properties` value and `items` is a schema map, `type`
  # is a known name, `required` is a list of strings and `enum` a list of
  # scalars.
  @spec schema_problem(term(), String.t()) :: String.t() | nil
  def schema_problem(nil, _path), do: nil

  def schema_problem(schema, path) when is_map(schema) do
    get = fn key, atom -> Map.get(schema, key, Map.get(schema, atom)) end

    type_problem(get.("type", :type), path) ||
      properties_problem(get.("properties", :properties), path) ||
      items_problem(get.("items", :items), path) ||
      required_problem(get.("required", :required), path) ||
      enum_problem(get.("enum", :enum), path)
  end

  def schema_problem(_schema, path), do: "#{path} must be an object (a JSON schema)"

  defp type_problem(nil, _path), do: nil

  defp type_problem(type, path) when is_binary(type) or (is_atom(type) and not is_nil(type)) do
    if to_string(type) in @schema_types,
      do: nil,
      else: "#{path}.type must be one of " <> Enum.join(@schema_types, ", ")
  end

  defp type_problem(_type, path), do: "#{path}.type must be a string"

  defp properties_problem(nil, _path), do: nil

  defp properties_problem(props, path) when is_map(props) do
    Enum.find_value(props, fn {key, sub} ->
      sub_path = "#{path}.properties.#{SwarmCode.Domain.Tools.arg_text(key)}"

      if is_map(sub),
        do: schema_problem(sub, sub_path),
        else: "#{sub_path} must be a schema object"
    end)
  end

  defp properties_problem(_props, path), do: "#{path}.properties must be an object"

  defp items_problem(nil, _path), do: nil
  defp items_problem(items, path) when is_map(items), do: schema_problem(items, path <> ".items")
  defp items_problem(_items, path), do: "#{path}.items must be a schema object"

  defp required_problem(nil, _path), do: nil

  defp required_problem(keys, path) do
    if is_list(keys) and Enum.all?(keys, &(is_binary(&1) or is_atom(&1))),
      do: nil,
      else: "#{path}.required must be a list of property names"
  end

  defp enum_problem(nil, _path), do: nil

  defp enum_problem(values, path) do
    if is_list(values) and
         Enum.all?(values, &(is_binary(&1) or is_number(&1) or is_boolean(&1) or is_atom(&1))),
       do: nil,
       else: "#{path}.enum must be a list of strings or numbers"
  end

  # spec 72 A3: resolve agent definition from args["agent"] if present.
  defp resolve_agent(%{"agent" => agent_name}, ctx)
       when is_binary(agent_name) and agent_name != "" do
    project_root = ctx[:project_root]

    case Agents.resolve(agent_name, project_root) do
      nil ->
        available =
          Agents.list(project_root)
          |> Enum.map_join(", ", & &1.name)

        {:error, "unknown agent '#{agent_name}' — available: #{available}"}

      def_ ->
        {:ok, def_}
    end
  end

  defp resolve_agent(_args, _ctx), do: {:ok, nil}

  # spec 67 T11 (G39): the depth limit used to be enforced by *removing* the
  # tool, so a lead that had used it once and then hit the limit simply found it
  # gone and had nothing to reason about. A refusal the model can read is worth
  # more than a silent absence — and a spawn over the cap
  # (`@max_agents_per_run`) comes back the same way, as a tool error rather than
  # a MatchError that kills the op.
  defp depth_ok(ctx) do
    max_depth = get_in(ctx, [:settings, Access.key(:max_agent_depth)]) || 2

    if ctx.depth + 1 > max_depth do
      {:error,
       "Agent depth limit reached (max_agent_depth = #{max_depth}). Solve the task yourself."}
    else
      :ok
    end
  end

  defp await(name, ctx, agent_id) do
    # spec 67 T29 (G38): a wall clock, kept *outside* the call. The timeout form
    # of `RunServer.await_agent/3` passes `awaiting: nil`, and that would undo
    # spec 51 §5.1 — a parent that waits must give its slot up or a queued child
    # never starts. So the await stays `:infinity` with its `awaiting:`, and a
    # watchdog process stops the child when the clock runs out; the stop settles
    # the await through the RunServer's own path, milliseconds later.
    seconds = timeout_s(ctx)
    watchdog = watchdog(ctx.run_id, agent_id, seconds)

    # Spec 51 §5.1: this agent waits and does no work — its slot goes to the
    # queue (the child, usually).
    result = RunServer.await_agent(ctx.run_id, agent_id, awaiting: ctx[:agent_node_id])
    timed_out? = cancel(watchdog, agent_id)

    case result do
      {:ok, text} ->
        # spec 72 B3: include the stop reason when it is not :done;
        # spec 72 C4: the parent gets a capped preview, agent_result the rest.
        reason_label = node_stop_reason_label(ctx.run_id, agent_id)
        suffix = if reason_label, do: " (#{reason_label})", else: ""
        {:ok, "Agent #{name} finished#{suffix}:\n" <> preview(text, agent_id)}

      {:error, _reason} when timed_out? ->
        {:error,
         "Agent #{name} exceeded #{seconds} s and was stopped; " <> partial_work(ctx, agent_id)}

      # Spec 51 §5.9 (a): "Agent … was stopped by the user" arrives here now.
      {:error, "Agent " <> _ = msg} ->
        {:error, msg}

      {:error, reason} ->
        {:error, "Agent #{name} failed: #{reason}"}
    end
  end

  @doc false
  @spec timeout_s(map()) :: non_neg_integer()
  def timeout_s(ctx) do
    case get_in(ctx, [:settings, Access.key(:sub_agent_timeout_s)]) do
      n when is_integer(n) and n > 0 -> n
      n when is_integer(n) -> 0
      _none -> 1_800
    end
  end

  defp watchdog(_run_id, _agent_id, 0), do: nil

  defp watchdog(run_id, agent_id, seconds) do
    caller = self()

    spawn(fn ->
      ref = Process.monitor(caller)

      receive do
        {:DOWN, ^ref, :process, ^caller, _reason} -> :ok
        {:cancel, ^agent_id} -> :ok
      after
        seconds * 1_000 ->
          # The message goes first: the stop settles the await, and the op
          # process must already know why it came back.
          send(caller, {:sub_agent_timeout, agent_id})
          # spec 72 B7: use stop_agent_timeout so the node gets :spawn_timeout.
          RunServer.stop_agent_timeout(run_id, agent_id)
      end
    end)
  end

  defp cancel(nil, agent_id), do: fired?(agent_id)

  defp cancel(watchdog, agent_id) do
    send(watchdog, {:cancel, agent_id})
    fired?(agent_id)
  end

  defp fired?(agent_id) do
    receive do
      {:sub_agent_timeout, ^agent_id} -> true
    after
      0 -> false
    end
  end

  # An isolated sub-agent's branch exists from the moment its worktree is
  # created, so the lead can look at what it managed before the clock ran out. A
  # stopped agent's worktree is never committed, so the branch is what is on
  # disk plus whatever it did commit itself.
  defp partial_work(ctx, agent_id) do
    case branch_of(ctx.run_id, agent_id) do
      branch when is_binary(branch) -> "its partial work is on branch #{branch}"
      _none -> "it was not isolated, so its partial work is in the project working tree"
    end
  end

  # spec 72 B3: the node's error_kind, mapped to a label. spec 72 R7: read
  # from the state owner — the row is written up to a flush later, so the
  # DB read this used to be missed "(turn limit)" whenever it lost the race.
  defp node_stop_reason_label(run_id, agent_id) do
    run_id
    |> RunServer.node_error_kind(agent_id)
    |> SwarmCode.Domain.LLM.Error.stop_reason_label()
  end

  # spec 73 T100: one field, not the whole state.
  defp branch_of(run_id, agent_id) do
    case RunServer.node_field(run_id, agent_id, :branch) do
      branch when is_binary(branch) -> branch
      _none_or_gone -> nil
    end
  end

  # spec 72 C4: cap the result the parent's context window sees at 5000 chars.
  @preview_cap 5_000

  @doc false
  def preview_cap, do: @preview_cap

  @doc false
  def preview_bg(text, agent_id), do: preview(text, agent_id)

  # spec 73 T17: characters, not bytes — a 4 000-character report with
  # accents or emoji used to wear the trailer although nothing was dropped.
  defp preview(text, agent_id) do
    if String.length(text) > @preview_cap do
      String.slice(text, 0, @preview_cap) <>
        "\n\n…[output truncated at #{@preview_cap} chars; " <>
        "call agent_result with agent_id \"#{agent_id}\" for the full result]"
    else
      text
    end
  end
end
