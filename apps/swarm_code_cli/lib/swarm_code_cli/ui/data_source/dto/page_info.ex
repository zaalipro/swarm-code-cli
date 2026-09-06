defmodule SwarmCodeCLI.UI.DataSource.DTO.PageInfo do
  @moduledoc "Bounded, closed PageInfo presentation facts."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
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
