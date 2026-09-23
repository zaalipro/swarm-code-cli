defmodule SwarmCodeCLI.UI.DataSource.DTO.Approval do
  @moduledoc """
  The actual tool operation awaiting a scoped user decision.

  pass70 C1: the card's facts. `command`/`cwd` for a shell command, the
  model's `reason` (its `justification`), the `command_family` that
  `:always_prefix` remembers on the project (nil = nothing safe to remember),
  the service's `classification` of the command, the asking agent, and the
  closed `allowed_decisions` the service will accept for this request.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    wire_defaults: [
      command: nil,
      cwd: nil,
      reason: nil,
      command_family: nil,
      classification: "unknown",
      agent_id: nil,
      agent_name: nil,
      requested_at: nil,
      allowed_decisions: []
    ],
    fields: [
      tool: :text,
      permission: {:enum, [:read, :write, :execute]},
      arguments_preview: :text,
      arguments_detail_ref: {:optional, {:dto, SwarmCodeCLI.UI.DataSource.DTO.DetailRef}},
      command: {:optional, {:text, 4096}},
      cwd: {:optional, {:text, 1024}},
      reason: {:optional, {:text, 1024}},
      command_family: {:optional, {:text, 200}},
      classification: {:enum, [:safe, :normal, :dangerous, :unknown]},
      agent_id: {:optional, :id},
      agent_name: {:optional, {:text, 200}},
      requested_at: {:optional, :count},
      allowed_decisions:
        {:list, {:enum, [:approve, :approve_run, :always_prefix, :deny, :deny_stop]}}
    ],
    defaults: [
      tool: "",
      permission: :write,
      arguments_preview: "",
      arguments_detail_ref: nil,
      command: nil,
      cwd: nil,
      reason: nil,
      command_family: nil,
      classification: :unknown,
      agent_id: nil,
      agent_name: nil,
      requested_at: nil,
      allowed_decisions: []
    ]

  @decisions [:approve, :approve_run, :always_prefix, :deny, :deny_stop]

  @doc "Every decision an approval may offer, in the order a card lists them."
  def decisions, do: @decisions
end
