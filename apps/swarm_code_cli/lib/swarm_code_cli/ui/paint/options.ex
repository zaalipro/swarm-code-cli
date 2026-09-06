defmodule SwarmCodeCLI.UI.Paint.Options do
  @moduledoc "Closed options for the renderer-neutral cell painter."
  defstruct color_mode: :truecolor, ascii?: false

  @type t :: %__MODULE__{
          color_mode: :truecolor | :ansi256 | :ansi16 | :monochrome,
          ascii?: boolean()
        }

  def validate(%__MODULE__{color_mode: mode, ascii?: ascii} = options)
      when map_size(options) == 3 and mode in [:truecolor, :ansi256, :ansi16, :monochrome] and
             is_boolean(ascii),
      do: :ok

  def validate(_), do: {:error, :invalid_options}
end
