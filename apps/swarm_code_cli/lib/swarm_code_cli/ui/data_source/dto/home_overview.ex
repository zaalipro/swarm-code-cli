defmodule SwarmCodeCLI.UI.DataSource.DTO.HomeOverview do
  @moduledoc """
  orbit: Home's cross-project overview (`home.overview`). `projects` starts with
  this session's project; `live_runs` are the oldest five running runs of this VM,
  `live_overflow` the rest; `revision` the backend's home revision it reflects.

  The lists are bounded here as on the wire: at most 8 projects and 5 live runs.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      request_id: {:optional, :id},
      state: {:enum, [:ready, :error]},
      error: {:optional, :error},
      revision: :revision,
      project_id: {:optional, :id},
      projects: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.HomeProject}, 8},
      live_runs: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.HomeRun}, 5},
      live_overflow: :count,
      waiting_total: :count,
      month: {:optional, {:dto, SwarmCodeCLI.UI.DataSource.DTO.HomeMonth}},
      next_scheduled: {:optional, {:dto, SwarmCodeCLI.UI.DataSource.DTO.HomeScheduled}}
    ],
    defaults: [
      request_id: nil,
      state: :ready,
      error: nil,
      revision: 0,
      project_id: nil,
      projects: [],
      live_runs: [],
      live_overflow: 0,
      waiting_total: 0,
      month: nil,
      next_scheduled: nil
    ]
end
