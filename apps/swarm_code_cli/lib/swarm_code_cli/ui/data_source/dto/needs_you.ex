defmodule SwarmCodeCLI.UI.DataSource.DTO.NeedsYou do
  @moduledoc """
  pass72 S: one request waiting on the user, for the panel's needs-you band.

  `text` is the literal request (the command, the edited path, the question or
  the workflow gate's question), `reason` why it asks (the approval's
  justification or the read-only/auto explanation), `node_id` the node that
  waits (an approval's op node, a question's node) and `agent_id` the agent it
  belongs to. Oldest first on the run summary.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    wire_defaults: [
      agent_id: nil,
      node_id: nil,
      agent_name: "",
      reason: "",
      requested_at: 0,
      tool: nil
    ],
    fields: [
      agent_id: {:optional, :id},
      node_id: {:optional, :id},
      agent_name: {:text, 200},
      kind: {:enum, [:approval, :question, :gate]},
      text: {:text, 1024},
      reason: {:text, 512},
      requested_at: :count,
      # pass72 G19 (QA Q19): the approval's tool, so the panel says "wants to
      # use workflow control" rather than "wants to run a command".
      tool: {:optional, {:text, 64}}
    ],
    defaults: [
      agent_id: nil,
      node_id: nil,
      agent_name: "",
      kind: :approval,
      text: "",
      reason: "",
      requested_at: 0,
      tool: nil
    ]

  alias SwarmCodeCLI.UI.DataSource.DTO

  @doc """
  The band entry of a pending interaction, as the daemon derives it (the fake
  data source uses it for parity): an approval's literal command (else its
  tool), its reason, its agent; a question's prompt. `agent_name` names the
  agent when the approval card does not.
  """
  def from_interaction(%DTO.PendingInteraction{} = i, agent_id \\ nil, agent_name \\ "") do
    case i do
      %{kind: :approval, approval: %DTO.Approval{} = a} ->
        %__MODULE__{
          agent_id: a.agent_id || agent_id,
          node_id: i.node_id,
          agent_name: clip(a.agent_name || agent_name || "", 200),
          kind: :approval,
          text: clip(a.command || a.tool, 1024),
          reason: clip(a.reason || "", 512),
          requested_at: a.requested_at || i.created_at,
          tool: a.tool && clip(a.tool, 64)
        }

      %{kind: :question, question: %DTO.Question{} = q} ->
        %__MODULE__{
          agent_id: agent_id,
          node_id: i.node_id,
          agent_name: clip(agent_name || "", 200),
          kind: :question,
          text: clip(q.prompt, 1024),
          requested_at: i.created_at
        }

      _ ->
        nil
    end
  end

  defp clip(text, max) when is_binary(text) and byte_size(text) <= max, do: text

  defp clip(text, max) when is_binary(text) do
    cut =
      text
      |> String.codepoints()
      |> Enum.reduce_while({[], 0}, fn cp, {acc, size} ->
        if size + byte_size(cp) <= max - 3,
          do: {:cont, {[cp | acc], size + byte_size(cp)}},
          else: {:halt, {acc, size}}
      end)
      |> elem(0)
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    cut <> "…"
  end

  defp clip(_, _), do: ""
end
