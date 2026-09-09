defmodule SwarmCodeCLI.UI.DataSource.DTO.LibrarySnapshot do
  @moduledoc "Closed feature-library response shared by terminal feature pages."
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      feature:
        {:enum,
         [
           :workflows,
           :research,
           :schedules,
           :settings,
           :usage,
           :changes,
           :checkpoints,
           :mcp,
           :memory
         ]},
      title: :text,
      description: :text,
      items: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.LibraryItem}},
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
      feature: :workflows,
      title: "",
      description: "",
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
