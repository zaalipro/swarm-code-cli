defmodule SwarmCode.Domain.Tools.SpawnAgent do
  @moduledoc "Delegate a sub-task to a new sub-agent."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Engine.RunServer

  @impl true
  def name, do: "spawn_agent"

  @impl true
  # Spec 54 §5 (54c H9): the call blocks until the sub-agent finishes
  # (`RunServer.await_agent/3`), which the old "runs in parallel" contradicted.
  def description,
    do:
      "Delegate one self-contained sub-task to a new sub-agent and return its final report. " <>
        "The sub-agent starts with no history of this conversation, so its task has to carry " <>
        "the scope, the files it owns and what finishing looks like. Several spawn_agent " <>
        "calls in the same response start together, up to the run's concurrency limit, and " <>
        "the rest queue; this call does not return until that sub-agent has finished, so " <>
        "issue the independent ones in one response rather than one per turn."

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
        "context" => %{"type" => "string", "description" => "extra context from the lead"}
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
    progress.(nil, "starting")

    {:ok, agent_id} =
      RunServer.start_agent(ctx.run_id, %{
        parent_id: ctx.node_id,
        name: name,
        task: args["task"],
        context: args["context"],
        depth: ctx.depth + 1
      })

    progress.(nil, "running")

    # Spec 51 §5.1: this agent waits and does no work — its slot goes to the
    # queue (the child, usually).
    case RunServer.await_agent(ctx.run_id, agent_id, awaiting: ctx[:agent_node_id]) do
      {:ok, text} ->
        {:ok, "Agent #{name} finished:\n" <> text}

      # Spec 51 §5.9 (a): "Agent … was stopped by the user" arrives here now.
      {:error, "Agent " <> _ = msg} ->
        {:error, msg}

      {:error, reason} ->
        {:error, "Agent #{name} failed: #{reason}"}
    end
  end
end
