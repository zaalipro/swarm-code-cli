defmodule SwarmCode.Domain.Tools.SpawnAgent do
  @moduledoc "Delegate a sub-task to a new sub-agent."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.{Agents, Engine.RunServer}

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
              "When omitted, uses the agent definition's model or the run's swarm model."
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
  def title(args), do: "agent " <> (args["name"] || "")

  @impl true
  def run(args, ctx, progress) do
    name = String.slice(to_string(args["name"]), 0, 24)
    background? = args["background"] == true
    progress.(nil, "starting")

    # spec 72 A3: resolve agent definition and validate effort
    with :ok <- depth_ok(ctx),
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
        output_schema: args["output_schema"]
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
    {:error, "invalid effort '#{value}' — use one of low, medium, high, xhigh, max"}
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
