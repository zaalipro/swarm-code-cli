defmodule SwarmCodeCLI.UI.DataSource.DTO.Phase do
  @moduledoc """
  pass72 S: one phase of a workflow run as the workflow records it (its
  declared phases and the current one), with the agents that ran in it (`agent_count`: the page-size check reads
  any `agents` key as a list).
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    wire_defaults: [agent_count: 0, live: 0, done: 0],
    fields: [
      name: {:text, 120},
      state: {:enum, [:done, :running, :waiting, :paused, :failed, :queued]},
      agent_count: :count,
      live: :count,
      done: :count
    ],
    defaults: [name: "", state: :queued, agent_count: 0, live: 0, done: 0]
end
