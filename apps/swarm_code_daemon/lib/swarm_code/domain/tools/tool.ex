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

  @doc """
  spec 66 T20: may two calls of this tool (or this tool and any other) run at
  the same time? Default **true** — today's behaviour, every call in a batch as
  its own concurrent `Operation`. A tool that returns `false` is run one at a
  time, in the order the model emitted the calls, because two `edit_file`s of
  one path in one response used to race through `AtomicFile.replace/3` and one
  of them silently won.
  """
  @callback parallel?() :: boolean()

  @optional_callbacks parallel?: 0
end
