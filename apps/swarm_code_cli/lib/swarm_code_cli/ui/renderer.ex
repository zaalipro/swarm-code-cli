defmodule SwarmCodeCLI.UI.Renderer do
  alias SwarmCodeCLI.UI.{Capabilities, Input, Scene}
  alias SwarmCodeCLI.UI.Renderer.{Error, Options}
  @callback init(Options.t()) :: {:ok, term(), Capabilities.t()} | {:error, Error.t()}
  @callback normalize_event(term(), term()) ::
              {:ok, Input.t(), term()} | {:ignore, term()} | {:error, Error.t(), term()}
  @callback draw(Scene.t(), term()) :: {:ok, term()} | {:error, Error.t(), term()}
  @callback shutdown(term()) :: :ok
end
