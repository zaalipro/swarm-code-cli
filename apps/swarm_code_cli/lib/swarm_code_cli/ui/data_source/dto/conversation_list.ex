defmodule SwarmCodeCLI.UI.DataSource.DTO.ConversationList do
  @moduledoc """
  pass70 C1: a keyset page of the project's conversations, newest first
  (`conversation_list`). `current_id` is the conversation the session has
  open; `project` is the project's display name.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      project: {:optional, {:text, 200}},
      current_id: {:optional, :id},
      items: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.ConversationSummary}},
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
      project: nil,
      current_id: nil,
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
