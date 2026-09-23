defmodule SwarmCodeCLI.UI.Paint.Options do
  @moduledoc "Closed options for the renderer-neutral cell painter."
  # pass71 V4 (R6): `theme: :light` paints the Carbon light tokens (see
  # `Theme.light/1`); the default is the terminal's background with dark roles.
  defstruct color_mode: :truecolor, ascii?: false, glyph_tier: :measured, theme: :dark

  @type t :: %__MODULE__{
          color_mode: :truecolor | :ansi256 | :ansi16 | :monochrome,
          ascii?: boolean(),
          glyph_tier: :measured | :rich,
          theme: :dark | :light
        }

  def validate(
        %__MODULE__{color_mode: mode, ascii?: ascii, glyph_tier: tier, theme: theme} = options
      )
      when map_size(options) == 5 and mode in [:truecolor, :ansi256, :ansi16, :monochrome] and
             is_boolean(ascii) and tier in [:measured, :rich] and theme in [:dark, :light],
      do: :ok

  def validate(_), do: {:error, :invalid_options}
end
