defmodule SwarmCodeCLI.UI.DataSource.DTO.PendingInteractionWindow do
  @moduledoc "Bounded, closed PendingInteractionWindow presentation facts."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      items: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.PendingInteraction}},
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
      items: [],
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
