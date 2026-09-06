defmodule SwarmCodeCLI.UI.Scene.Block.RunCard do
  alias SwarmCodeCLI.UI.SafeText
  alias SwarmCodeCLI.UI.Scene.Block
  @enforce_keys [:id, :title, :status]
  defstruct [:id, :title, :status, body: []]

  @type status ::
          :queued
          | :running
          | :streaming
          | :paused
          | :waiting_question
          | :waiting_approval
          | :retrying
          | :done
          | :failed
          | :stopped
          | :interrupted
          | :superseded
  @type t :: %__MODULE__{id: binary(), title: SafeText.t(), status: status(), body: [Block.t()]}
end
