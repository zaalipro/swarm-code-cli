defmodule SwarmCodeCLI.UI.DataSource.DTO.RunDetailSnapshot do
  @moduledoc "Bounded, closed RunDetailSnapshot presentation facts."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      run: {:optional, {:dto, SwarmCodeCLI.UI.DataSource.DTO.RunSummary}},
      agents: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.AgentSummary}},
      transcript: {:dto, SwarmCodeCLI.UI.DataSource.DTO.TranscriptWindow},
      tab: {:enum, [:thread, :agents, :timeline, :changes]},
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
      run: nil,
      agents: [],
      transcript: nil,
      tab: :thread,
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
