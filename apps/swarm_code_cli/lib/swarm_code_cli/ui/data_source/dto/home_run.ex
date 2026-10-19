defmodule SwarmCodeCLI.UI.DataSource.DTO.HomeRun do
  @moduledoc """
  orbit: one live run of this VM's engine, a bar of the mark. `progress` is the
  root node's progress (0..100) or nil; `started_at` is unix milliseconds.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      id: :id,
      project_id: :id,
      conversation_id: :id,
      kind: {:enum, [:chat, :goal, :swarm, :workflow, :research, :consensus, :ultra]},
      progress: {:optional, :progress},
      started_at: :count
    ],
    defaults: [
      id: nil,
      project_id: nil,
      conversation_id: nil,
      kind: :chat,
      progress: nil,
      started_at: 0
    ]
end
