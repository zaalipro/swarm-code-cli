defmodule SwarmCodeCLI.UI.DataSource.DTO.HomeProject do
  @moduledoc """
  orbit: one orbit of Home. `conversations` are the project's newest (at most 24,
  newest first); `conversation_count` counts them all (research and scheduled
  conversations excluded); `live` and `waiting` count the project's live runs and
  the requests that wait for a person. `last_opened_at` is unix milliseconds.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      id: :id,
      name: {:text, 200},
      root_path: {:text, 4096},
      current: :boolean,
      last_opened_at: {:optional, :count},
      conversation_count: :count,
      live: :count,
      waiting: :count,
      conversations: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.HomeConversation}, 24}
    ],
    defaults: [
      id: nil,
      name: "",
      root_path: "",
      current: false,
      last_opened_at: nil,
      conversation_count: 0,
      live: 0,
      waiting: 0,
      conversations: []
    ]
end
