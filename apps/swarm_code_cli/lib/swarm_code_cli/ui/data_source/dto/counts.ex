defmodule SwarmCodeCLI.UI.DataSource.DTO.Counts do
  @moduledoc "Bounded, closed Counts presentation facts."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      running: :revision,
      waiting: :revision,
      paused: :revision,
      failed: :revision,
      done: :revision,
      unseen: :revision
    ],
    defaults: [
      running: 0,
      waiting: 0,
      paused: 0,
      failed: 0,
      done: 0,
      unseen: 0
    ]
end
