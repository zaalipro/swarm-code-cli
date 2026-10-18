defmodule SwarmCodeCLI.UI.DataSource.DTO.Elsewhere do
  @moduledoc """
  pass76: what the session's other conversations hold, the body of the shell
  watch's `elsewhere` delta and the optional `elsewhere` of its snapshot.

  A quit stops every live run of the session and an approval or question can
  wait in any conversation, while the read model holds the shown conversation
  only. `live` counts the live runs outside the shown conversation; `waiting`
  lists the approvals and questions waiting there (the newest 32).
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      live: :count,
      waiting: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.ElsewhereWait}, 32}
    ],
    defaults: [
      live: 0,
      waiting: []
    ]
end
