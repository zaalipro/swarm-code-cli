defmodule SwarmCode.Domain.Tools.Tool do
  @moduledoc "Behaviour every tool implements."

  @callback name() :: String.t()
  @callback description() :: String.t()
  @callback parameters() :: map()
  @callback permission(args :: map()) :: :read | :write | :execute
  @callback title(args :: map()) :: String.t()
  @callback run(
              args :: map(),
              ctx :: map(),
              progress :: (0..100 | nil, String.t() -> :ok)
            ) :: {:ok, String.t()} | {:error, String.t()}
end
