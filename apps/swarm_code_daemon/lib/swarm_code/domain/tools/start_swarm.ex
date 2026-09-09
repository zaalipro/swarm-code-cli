defmodule SwarmCode.Domain.Tools.StartSwarm do
  @moduledoc """
  The assistant's own way to fan a task out over sub-agents (spec 12 §1).

  A plain request that mentions sub-agents, a swarm, parallel agents or
  "N agents" must produce a **swarm** run, never a workflow — workflows are the
  user's call (`/create-workflow`, `/workflow`, Ultra). This tool starts that
  swarm in the same conversation and hands the turn back to the assistant, which
  says in one or two sentences what the swarm will do.
  """
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Tools.WorkflowTools

  @impl true
  def name, do: "start_swarm"

  @impl true
  # Spec 54 §5 (54c M2): a description is a contract about functionality, not a
  # trigger-phrase list with a prohibition about a different tool. What it
  # actually omitted is that the call returns immediately and that a second
  # concurrent swarm is an error.
  def description,
    do:
      "Start a swarm of sub-agents on a task in this conversation, for work the user asked " <>
        "several agents to do in parallel. A Lead agent decomposes the task, spawns one " <>
        "sub-agent per part up to the concurrency limit, integrates the results and reports " <>
        "back; the swarm is a separate run of this conversation and shows up in the Agents " <>
        "pane. It returns as soon as the run is launched, with the run's name — not the " <>
        "swarm's result, which lands in the conversation when the run finishes. One swarm per " <>
        "conversation at a time: it is an error while another is still running."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "task" => %{
          "type" => "string",
          "description" => "The precise task the swarm's Lead gets, in one paragraph."
        },
        "agents" => %{
          "type" => "integer",
          "description" => "How many sub-agents the user asked for (optional hint)."
        }
      },
      "required" => ["task"]
    }
  end

  # Like spawn_agent: starting the swarm asks for nothing — every operation the
  # sub-agents perform is gated on its own.
  @impl true
  def permission(_args), do: :read

  @impl true
  def title(args), do: "start_swarm " <> String.slice(to_string(args["task"] || ""), 0, 60)

  @impl true
  def run(args, ctx, _progress) do
    task = args["task"] |> to_string() |> String.trim()
    conversation = WorkflowTools.conversation(ctx)

    cond do
      task == "" ->
        {:error, "give the swarm a task"}

      WorkflowTools.in_workflow?(ctx) ->
        {:error, "workflows do not start swarms"}

      is_nil(conversation) ->
        {:error, "no conversation to start a swarm in"}

      true ->
        launch(task, agents(args), conversation, ctx[:run_id])
    end
  end

  defp launch(task, agents, conversation, caller_run_id) do
    # Spec 51 §5.9 (d): `max_concurrent_agents` is per run — a second swarm in
    # the conversation would double the fan-out, not share it.
    if swarm_running?(conversation.id) do
      {:error, "a swarm is already running in this conversation — wait for it or stop it"}
    else
      do_launch(task, agents, conversation, caller_run_id)
    end
  end

  defp swarm_running?(conversation_id) do
    Enum.any?(SwarmCode.Domain.Engine.running_runs(conversation_id), fn run_id ->
      match?(%{kind: "swarm"}, SwarmCode.Domain.Conversations.get_run(run_id))
    end)
  end

  defp do_launch(task, agents, conversation, caller_run_id) do
    label = SwarmCode.Domain.Engine.sanitize_label("", task)
    max_agents = agents || SwarmCode.Domain.Settings.get_cached().max_concurrent_agents

    opts = [
      label: label,
      store_user: false,
      prompt: prompt(task, agents),
      # Spec 17 §2.6: this swarm has no user message of its own — it belongs to
      # the run whose agent asked for it.
      launched_by_run_id: caller_run_id
    ]

    case SwarmCode.Domain.Engine.start_swarm(conversation, task, opts) do
      {:ok, _run_id} ->
        {:ok, "Swarm started (#{label}), #{max_agents} sub-agents max — watch the Agents pane."}

      {:error, :not_configured} ->
        {:error, "no chat model is configured for this conversation"}

      {:error, reason} ->
        {:error, "could not start the swarm: " <> inspect(reason)}
    end
  end

  defp prompt(task, nil), do: task

  defp prompt(task, agents),
    do:
      task <>
        "\n\nDecompose this into about #{agents} independent sub-tasks and spawn one " <>
        "sub-agent per part."

  defp agents(args) do
    case args["agents"] do
      n when is_integer(n) and n > 0 and n <= 64 -> n
      n when is_binary(n) -> agents(%{"agents" => Integer.parse(n) |> elem_or_nil()})
      _ -> nil
    end
  end

  defp elem_or_nil({n, _rest}), do: n
  defp elem_or_nil(_), do: nil
end
