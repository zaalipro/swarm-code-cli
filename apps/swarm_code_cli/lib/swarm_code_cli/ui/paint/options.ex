defmodule SwarmCodeCLI.UI.Paint.Options do
  @moduledoc "Closed options for the renderer-neutral cell painter."
  # pass71 V4 (R6): `theme: :light` paints the Carbon light tokens (see
  # `Theme.light/1`); the default is the terminal's background with dark roles.
  # cli020 E27: `palette` is one of the desktop's themes (`Theme.palettes/0`).
  defstruct color_mode: :truecolor,
            ascii?: false,
            glyph_tier: :measured,
            theme: :dark,
            palette: :carbon

  @type t :: %__MODULE__{
          color_mode: :truecolor | :ansi256 | :ansi16 | :monochrome,
          ascii?: boolean(),
          glyph_tier: :measured | :rich,
          theme: :dark | :light,
          palette: atom()
        }

  def validate(
        %__MODULE__{
          color_mode: mode,
          ascii?: ascii,
          glyph_tier: tier,
          theme: theme,
          palette: palette
        } = options
      )
      when map_size(options) == 6 and mode in [:truecolor, :ansi256, :ansi16, :monochrome] and
             is_boolean(ascii) and tier in [:measured, :rich] and theme in [:dark, :light] and
             palette in [:carbon, :aurora, :dusk, :ember, :fjord, :graphite, :obsidian, :paper],
      do: :ok

  def validate(_), do: {:error, :invalid_options}
end
