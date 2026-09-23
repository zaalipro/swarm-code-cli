defmodule SwarmCode.Domain.Tools.Inbox do
  @moduledoc "Drain pending messages from the agent's mailbox. # spec 72 C1"
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Engine.RunServer

  @impl true
  def name, do: "inbox"

  @impl true
  def description,
    do:
      "Check your mailbox for messages from other agents. Returns all " <>
        "pending messages and clears the mailbox. Each message has the " <>
        "sender's name and the text. Returns 'no messages' if empty."

  @impl true
  def parameters, do: %{"type" => "object", "properties" => %{}}

  @impl true
  def permission(_args), do: :read

  @impl true
  def parallel?, do: true

  @impl true
  def title(_args), do: "check inbox"

  @impl true
  def run(_args, ctx, progress) do
    progress.(nil, "checking")

    # spec 73 T104: a run that is gone answers, instead of Enum.map_join on
    # `{:error, :not_running}`.
    case RunServer.drain_inbox(ctx.run_id, ctx[:agent_node_id]) do
      {:error, _not_running} ->
        {:error, "the run is no longer active"}

      [] ->
        {:ok, "No messages in your inbox."}

      messages ->
        text =
          Enum.map_join(messages, "\n\n", fn m ->
            "From #{m.from}:\n#{m.text}"
          end)

        progress.(100, "#{length(messages)} message(s)")
        {:ok, "#{length(messages)} message(s):\n\n#{text}"}
    end
  end
end
