defmodule SwarmCodeCLI.UI.Renderer.Error do
  @enforce_keys [:code, :message]
  defstruct [:code, :message]

  @type code ::
          :invalid_scene
          | :unsupported
          | :initialization_failed
          | :event_failed
          | :draw_failed
          | :ambiguous_width_unsupported
  @type t :: %__MODULE__{code: code(), message: binary()}
  def invalid_scene, do: %__MODULE__{code: :invalid_scene, message: "invalid scene"}
  def unsupported, do: %__MODULE__{code: :unsupported, message: "renderer operation unsupported"}

  def initialization_failed,
    do: %__MODULE__{code: :initialization_failed, message: "renderer initialization failed"}

  def event_failed,
    do: %__MODULE__{code: :event_failed, message: "renderer event normalization failed"}

  def draw_failed, do: %__MODULE__{code: :draw_failed, message: "renderer draw failed"}

  def ambiguous_width_unsupported,
    do: %__MODULE__{code: :ambiguous_width_unsupported, message: "ambiguous width unsupported"}
end
