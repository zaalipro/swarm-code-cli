defmodule SwarmCodeCLI.UI.PageState do
  @moduledoc "A correlated visible page sentinel; failures remain retryable."
  defstruct status: :idle,
            request_id: nil,
            direction: nil,
            before_cursor: nil,
            after_cursor: nil,
            error: nil

  @type t :: %__MODULE__{}
  def from_snapshot(body),
    do: %__MODULE__{
      status: Map.get(body, :state, :idle),
      before_cursor: Map.get(body, :before_cursor),
      after_cursor: Map.get(body, :after_cursor),
      error: Map.get(body, :error)
    }
end
