defmodule SwarmCodeCLI.UI.DataSource.DTO.HomeScheduled do
  @moduledoc """
  orbit: the next scheduled task. A project-less task has nil `project_id` and
  `project_name`; `next_run_at` is unix milliseconds.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      id: :id,
      name: {:text, 200},
      project_id: {:optional, :id},
      project_name: {:optional, {:text, 200}},
      next_run_at: :count
    ],
    defaults: [id: nil, name: "", project_id: nil, project_name: nil, next_run_at: 0]
end
