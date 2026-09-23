defmodule SwarmCodeCLI.UI.DataSource.DTO.ConversationSummary do
  @moduledoc """
  pass70 C1: one row of the conversation switcher and the resume picker.

  `updated_at`/`created_at` are unix milliseconds; `run_count` counts the
  conversation's runs, `live` is true while one of them runs, `waiting` counts
  the requests that wait for a person, `unread` says a run finished after the
  conversation was last seen, `current` marks the one the session has open.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      id: :id,
      title: {:text, 256},
      created_at: :count,
      updated_at: :count,
      run_count: :count,
      live: :boolean,
      waiting: :count,
      unread: :boolean,
      current: :boolean
    ],
    defaults: [
      id: nil,
      title: "",
      created_at: 0,
      updated_at: 0,
      run_count: 0,
      live: false,
      waiting: 0,
      unread: false,
      current: false
    ]
end
