defmodule SwarmCodeCLI.UI.Renderer.Options do
  alias SwarmCodeCLI.UI.Size
  defstruct size: %Size{columns: 80, rows: 24}, ambiguous_width: :narrow, color_mode: :monochrome

  @type t :: %__MODULE__{
          size: Size.t(),
          ambiguous_width: :narrow | :wide,
          color_mode: :truecolor | :ansi256 | :ansi16 | :monochrome
        }
end
