defmodule SwarmCodeCLI.UI.Scene.Block.Notice do
  defstruct severity: :info, text: nil, action_id: nil
  @type t :: %__MODULE__{}
end
