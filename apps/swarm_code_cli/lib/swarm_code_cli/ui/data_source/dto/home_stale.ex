defmodule SwarmCodeCLI.UI.DataSource.DTO.HomeStale do
  @moduledoc """
  orbit: the body of the shell watch's `home_stale` delta, an invalidation and not
  a payload: Home re-queries `home.overview` when `revision` is newer than the one
  it holds. It is the backend's home revision, which is not the delta's own
  watch revision (see `Codec.body_revision?/2`).
  """
  use SwarmCodeCLI.UI.DataSource.DTO.Schema,
    fields: [revision: :revision],
    defaults: [revision: 0]
end
