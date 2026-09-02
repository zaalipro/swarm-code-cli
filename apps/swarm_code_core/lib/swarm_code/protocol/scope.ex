defmodule SwarmCode.Protocol.Scope do
  @moduledoc "A typed subscription scope carried by a protocol message."

  @enforce_keys [:kind, :id, :generation]
  defstruct @enforce_keys

  @type kind :: :global | :project | :conversation | :run | :research | :workflow | :schedule
  @type t :: %__MODULE__{kind: kind(), id: binary() | nil, generation: non_neg_integer()}
end
