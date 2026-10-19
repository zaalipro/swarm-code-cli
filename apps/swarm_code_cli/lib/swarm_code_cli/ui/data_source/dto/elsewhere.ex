defmodule SwarmCodeCLI.UI.DataSource.DTO.Elsewhere do
  @moduledoc """
  pass76: what the session's live runs and other conversations hold, the body
  of the shell watch's `elsewhere` delta and the optional `elsewhere` of its
  snapshot.

  A quit stops every live run of the session and an approval or question can
  wait in any conversation. The read model is a cache of what its watches
  loaded (it keeps a closed inspector's rows, and its runs page is the newest
  200), so it cannot say what is live: the daemon reads its run registry.
  `total` counts every live run of the session, `live` those outside the shown
  conversation (so `live <= total`), and `waiting` lists the approvals and
  questions waiting there (the newest 32).
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [
      total: :count,
      live: :count,
      waiting: {:list, {:dto, SwarmCodeCLI.UI.DataSource.DTO.ElsewhereWait}, 32}
    ],
    defaults: [
      total: 0,
      live: 0,
      waiting: []
    ]
end
