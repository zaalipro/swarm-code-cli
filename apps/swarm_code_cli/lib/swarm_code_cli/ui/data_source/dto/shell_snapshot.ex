defmodule SwarmCodeCLI.UI.DataSource.DTO.ShellSnapshot do
  @moduledoc "Bounded, closed ShellSnapshot presentation facts."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    wire_defaults: [rate_limits: [], vitals: nil],
    fields: [
      # pass70 C1: every provider's last rate-limit window (`rate_limit` deltas).
      rate_limits: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.RateLimit}},
      # cli021 C2: the side panel's vitals at the time of the snapshot.
      vitals: {:optional, {:dto, SwarmCodeCLI.UI.DataSource.DTO.Vitals}},
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
      rate_limits: [],
      vitals: nil,
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
