defmodule SwarmCodeCLI.UI.DataSource.DTO.Outcome do
  @moduledoc "Bounded, closed Outcome presentation facts."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      status:
        {:enum,
         [
           :accepted,
           :needs_input,
           :rejected,
           :deadline_exceeded,
           :interrupted,
           :revision_conflict,
           :outcome_unknown
         ]},
      request_id: :id,
      identifiers: {:list, :id},
      interaction: {:optional, {:dto, SwarmCodeCLI.UI.DataSource.DTO.PendingInteraction}},
      feedback: {:optional, {:dto, SwarmCodeCLI.UI.DataSource.DTO.Feedback}},
      error: {:optional, :error},
      corrective_action: {:enum, [:none, :retry, :refresh, :answer]}
    ],
    wire_defaults: [feedback: nil],
    defaults: [
      status: :rejected,
      request_id: nil,
      identifiers: [],
      interaction: nil,
      feedback: nil,
      error: nil,
      corrective_action: :none
    ]

  def decode_status("accepted"), do: {:ok, :accepted}
  def decode_status("needs_input"), do: {:ok, :needs_input}
  def decode_status("rejected"), do: {:ok, :rejected}
  def decode_status("deadline_exceeded"), do: {:ok, :deadline_exceeded}
  def decode_status("interrupted"), do: {:ok, :interrupted}
  def decode_status("revision_conflict"), do: {:ok, :revision_conflict}
  def decode_status("outcome_unknown"), do: {:ok, :outcome_unknown}
  def decode_status(_), do: :error
end
