defmodule SwarmCode.Domain.Tools.AgentResult do
  @moduledoc "Retrieve the full result of a finished sub-agent. # spec 72 C4"
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Engine.RunServer

  @impl true
  def name, do: "agent_result"

  @impl true
  def description,
    do:
      "Get the full, untruncated result of a finished sub-agent. " <>
        "Use this when spawn_agent returned a truncated preview " <>
        "(indicated by the '…[output truncated]' trailer)."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "agent_id" => %{
          "type" => "string",
          "description" => "The agent's node ID from the truncation trailer"
        }
      },
      "required" => ["agent_id"]
    }
  end

  @impl true
  def permission(_args), do: :read

  @impl true
  def parallel?, do: true

  @impl true
  def title(_args), do: "agent result"

  @impl true
  def run(args, ctx, progress) do
    agent_id = args["agent_id"]
    progress.(nil, "fetching")

    # spec 73 T17: the node row's `result` is capped at 20 000 characters by
    # the RunServer (`normalize/1`), so reading it here returned a silently cut
    # text under a description that promises the full one. The agent's own
    # settled result is uncapped; `Tools.run/4` marks anything over
    # `Tools.max_output/0` with the truncation marker, as for every tool.
    case RunServer.agent_result(ctx.run_id, to_string(agent_id)) do
      {:done, {:ok, result}} ->
        progress.(100, "fetched")
        {:ok, result}

      {:done, {:error, error}} ->
        {:ok, "Agent failed: #{error}"}

      :unknown ->
        {:error, "No agent with ID #{agent_id} in this run"}

      :running ->
        {:error, "Agent #{agent_id} has not finished yet"}

      {:error, :not_running} ->
        {:error, "Run is no longer active"}
    end
  end
end
