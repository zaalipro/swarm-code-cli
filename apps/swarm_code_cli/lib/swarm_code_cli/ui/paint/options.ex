defmodule SwarmCodeCLI.UI.Paint.Options do
  @moduledoc "Closed options for the renderer-neutral cell painter."
  defstruct color_mode: :truecolor, ascii?: false, glyph_tier: :measured

  @type t :: %__MODULE__{
          color_mode: :truecolor | :ansi256 | :ansi16 | :monochrome,
          ascii?: boolean(),
          glyph_tier: :measured | :rich
        }

  def validate(%__MODULE__{color_mode: mode, ascii?: ascii, glyph_tier: tier} = options)
      when map_size(options) == 4 and mode in [:truecolor, :ansi256, :ansi16, :monochrome] and
             is_boolean(ascii) and tier in [:measured, :rich],
      do: :ok

  def validate(_), do: {:error, :invalid_options}
end
