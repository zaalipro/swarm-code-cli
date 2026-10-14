defmodule SwarmCodeCLI.UI.DataSource.DTO.HomeConversation do
  @moduledoc """
  orbit: one bead of an orbit. `updated_at` is unix milliseconds; `live_kind` is the
  presentation kind of the newest running run while `live` is true.
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      id: :id,
      title: {:text, 256},
      updated_at: :count,
      live: :boolean,
      live_kind:
        {:optional, {:enum, [:chat, :goal, :swarm, :workflow, :research, :consensus, :ultra]}},
      waiting: :count,
      unread: :boolean
    ],
    defaults: [
      id: nil,
      title: "",
      updated_at: 0,
      live: false,
      live_kind: nil,
      waiting: 0,
      unread: false
    ]
end
