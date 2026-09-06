defmodule SwarmCodeCLI.UI.DataSource.DTO.ShellSnapshot do
  @moduledoc "Bounded, closed ShellSnapshot presentation facts."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      runs: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.RunSummary}},
      connection: {:dto, SwarmCodeCLI.UI.DataSource.DTO.Connection},
      counts: {:dto, SwarmCodeCLI.UI.DataSource.DTO.Counts},
      state: {:enum, [:idle, :loading_before, :loading_after, :error, :closed, :resyncing]},
      before_cursor: {:optional, :id},
      after_cursor: {:optional, :id},
      request_id: {:optional, :id},
      error: {:optional, :error},
      presence: {:enum, [:covered, :off_window, :removed]},
      covered_ids: {:list, :id},
      through_sequence: :revision
    ],
    defaults: [
      runs: [],
      connection: nil,
      counts: nil,
      state: :idle,
      before_cursor: nil,
      after_cursor: nil,
      request_id: nil,
      error: nil,
      presence: :covered,
      covered_ids: [],
      through_sequence: 0
    ]
end
