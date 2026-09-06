defmodule SwarmCodeCLI.UI.DataSource.DTO.WorkspaceSnapshot do
  @moduledoc "Bounded, closed WorkspaceSnapshot presentation facts."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      runs_page: {:dto, SwarmCodeCLI.UI.DataSource.DTO.PageInfo},
      interactions_page: {:dto, SwarmCodeCLI.UI.DataSource.DTO.PageInfo},
      conversation_id: {:optional, :id},
      runs: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.RunSummary}},
      transcript: {:dto, SwarmCodeCLI.UI.DataSource.DTO.TranscriptWindow},
      interactions: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.PendingInteraction}},
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
      runs_page: nil,
      interactions_page: nil,
      conversation_id: nil,
      runs: [],
      transcript: nil,
      interactions: [],
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
