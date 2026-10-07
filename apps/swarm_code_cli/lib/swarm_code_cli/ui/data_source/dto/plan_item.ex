defmodule SwarmCodeCLI.UI.DataSource.DTO.PlanItem do
  @moduledoc """
  cli020 C23 (competitors-14): one step of a run's live plan (the lead's
  newest `update_plan`): its text and status.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [text: {:text, 200}, status: {:enum, [:pending, :in_progress, :done]}],
    defaults: [text: "", status: :pending]
end
