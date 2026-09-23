defmodule SwarmCode.Domain.Tools.MessageAgent do
  @moduledoc """
  Say something to a sub-agent that is already running (spec 67 T29 / G38).

  A lead could start a child and wait for its report, and that was the whole
  vocabulary: a correction it thought of while the child worked had to wait for
  the report and then be spent on a second child. Codex has `send_input`
  (`core/src/tools/handlers/multi_agents/`); this is the same message down the
  path the user's own steer already uses, so the child reads it between steps
  with no new machinery in the RunServer.
  """
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Engine.RunServer

  @impl true
  def name, do: "message_agent"

  @impl true
  def description,
    do:
      "Send a message to a sub-agent you started that is still running. It reads it before " <>
        "its next step, exactly as it would read a message from the user. Use it to correct " <>
        "the scope, hand over a fact you have just learnt or ask it to stop going down a " <>
        "path — not to collect its result, which spawn_agent returns. The call returns as " <>
        "soon as the message is delivered; it does not wait for a reply. " <>
        "Use agent_name \"*\" to broadcast the message to all live agents."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "agent_name" => %{
          "type" => "string",
          "description" => "The name you gave the sub-agent in spawn_agent"
        },
        "message" => %{
          "type" => "string",
          "description" => "What to tell it, in full — it has none of this conversation"
        }
      },
      "required" => ["agent_name", "message"]
    }
  end

  @impl true
  def permission(_args), do: :read

  # Two messages to one agent in a single response must arrive in the order the
  # lead wrote them (spec 66 T20).
  @impl true
  def parallel?, do: false

  @impl true
  def title(args), do: "message " <> String.slice(to_string(args["agent_name"] || ""), 0, 40)

  @impl true
  def run(args, ctx, progress) do
    name = String.trim(to_string(args["agent_name"] || ""))
    message = to_string(args["message"] || "")

    cond do
      name == "" ->
        {:error, "message_agent needs agent_name — the name you gave the sub-agent"}

      String.trim(message) == "" ->
        {:error, "message_agent needs a message"}

      true ->
        deliver(name, message, ctx, progress)
    end
  end

  # spec 72 C3: broadcast to all live agents in the run.
  defp deliver("*", message, ctx, progress) do
    progress.(nil, "broadcasting")

    # spec 73 T104: a run that is gone answers, instead of a MatchError.
    case RunServer.broadcast(ctx.run_id, ctx[:agent_node_id], message) do
      :ok ->
        progress.(100, "broadcast sent")
        {:ok, "Message broadcast to all live agents."}

      {:error, _not_running} ->
        {:error, "this run is no longer active"}
    end
  end

  defp deliver(name, message, ctx, progress) do
    progress.(nil, "delivering")

    # spec 73 T58 (F2): the live agents by name — one narrow read, instead of
    # the whole state (every node, result, mailbox and baseline) copied out of
    # the state owner for one lookup.
    case RunServer.live_agent_names(ctx.run_id) do
      live when is_list(live) ->
        # spec 73 T9: the mailbox, not `steer` — a `wait_for_message` waiter
        # wakes on it and the message is read once.
        with {:ok, node_id, found} <- target(live, name, ctx),
             :ok <- RunServer.deliver_message(ctx.run_id, ctx[:agent_node_id], node_id, message) do
          progress.(100, "delivered")

          {:ok,
           "Message delivered to #{found}. It reads it before its next step; its report " <>
             "still comes back from the spawn_agent call that started it."}
        end

      {:error, :not_running} ->
        {:error, "this run is no longer running"}
    end
  end

  defp target(live, name, ctx) do
    wanted = String.downcase(name)
    self_id = ctx[:agent_node_id]

    case Enum.find(live, fn {id, found} -> id != self_id and String.downcase(found) == wanted end) do
      {id, found} -> {:ok, id, found}
      nil -> {:error, unknown(live, name, self_id)}
    end
  end

  defp unknown(live, name, self_id) do
    running = for {id, found} <- live, id != self_id, do: found

    case Enum.sort(running) do
      [] -> "no agent called #{name} is running — you have no sub-agent to message"
      names -> "no agent called #{name} is running. Running now: #{Enum.join(names, ", ")}"
    end
  end
end
