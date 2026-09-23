defmodule SwarmCode.Domain.Tools.WaitForMessage do
  @moduledoc "Block until a message arrives from another agent. # spec 72 C2"
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Engine.RunServer

  @impl true
  def name, do: "wait_for_message"

  @impl true
  def description,
    do:
      "Wait for a message from another agent. Blocks until a message " <>
        "arrives in your mailbox or the timeout expires. While waiting, " <>
        "your concurrency slot is released so other agents can run. " <>
        "Use this to coordinate with peers — e.g. wait for a scout's " <>
        "findings before proceeding."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "timeout_seconds" => %{
          "type" => "integer",
          "description" => "Maximum seconds to wait (1-300, default 60)"
        }
      }
    }
  end

  @impl true
  def permission(_args), do: :read

  @impl true
  def parallel?, do: false

  @impl true
  def title(_args), do: "waiting for message"

  @impl true
  def run(args, ctx, progress) do
    timeout = seconds(args["timeout_seconds"])
    progress.(nil, "waiting")

    case RunServer.wait_for_message(
           ctx.run_id,
           ctx[:agent_node_id],
           timeout * 1_000,
           ctx[:agent_node_id]
         ) do
      {:ok, message} ->
        progress.(100, "received")
        {:ok, "Message from #{message.from}:\n#{message.text}"}

      {:error, :timeout} ->
        {:ok, "No message received within #{timeout} seconds."}

      # spec 72 R6: the run is gone (or its state owner stopped mid-wait).
      {:error, _reason} ->
        {:error, "the run is no longer active"}
    end
  end

  # spec 73 T104: a float (`30.0`) reached GenServer.call and send_after and
  # ended the op as "crashed"; anything that is not a number is the default.
  defp seconds(n) when is_number(n), do: n |> trunc() |> max(1) |> min(300)
  defp seconds(_other), do: 60
end
