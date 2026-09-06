defmodule SwarmCodeCLI.UI.WatchState do
  @moduledoc "One of four watch slots, with immutable generation and sequence correlation."
  defstruct [
    :watch_ref,
    :scope,
    :source_epoch,
    :resync_request_id,
    :retry,
    generation: 0,
    revision: -1,
    sequence: 0,
    status: :closed
  ]

  @type t :: %__MODULE__{}
end
