defmodule SwarmCodeCLI.UI.WatchState do
  @moduledoc "One of four watch slots, with immutable generation and sequence correlation."
  defstruct [
    :watch_ref,
    :scope,
    :source_epoch,
    :resync_request_id,
    # pass73 G2 (QA Q2-05): why the client asked for the resync in flight
    # (`:gap`, `:snapshot_required`, `:overflow`, `:unbounded`, `:retry`),
    # for the session's cli.log line.
    :resync_reason,
    :retry,
    generation: 0,
    revision: -1,
    sequence: 0,
    status: :closed
  ]

  @type t :: %__MODULE__{}
end
