defmodule SwarmCode.Domain.Workflows.Error do
  @moduledoc "Raised when the workflow API is used outside a run or against its rules."
  defexception [:message]
end
