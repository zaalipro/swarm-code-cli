defmodule SwarmCodeCLI.UI.Scene.Color do
  @roles [
    :default,
    :muted,
    :accent,
    :success,
    :warning,
    :danger,
    :info,
    :focus,
    :border,
    :background
  ]
  @enforce_keys [:role]
  defstruct [:role, :value]

  @type role ::
          :default
          | :muted
          | :accent
          | :success
          | :warning
          | :danger
          | :info
          | :focus
          | :border
          | :background
  @type ansi ::
          :black
          | :red
          | :green
          | :yellow
          | :blue
          | :magenta
          | :cyan
          | :white
          | :bright_black
          | :bright_red
          | :bright_green
          | :bright_yellow
          | :bright_blue
          | :bright_magenta
          | :bright_cyan
          | :bright_white
  @type value :: {:rgb, 0..255, 0..255, 0..255} | {:indexed, 0..255} | {:ansi, ansi()} | nil
  @type t :: %__MODULE__{role: role(), value: value()}
  @ansi [
    :black,
    :red,
    :green,
    :yellow,
    :blue,
    :magenta,
    :cyan,
    :white,
    :bright_black,
    :bright_red,
    :bright_green,
    :bright_yellow,
    :bright_blue,
    :bright_magenta,
    :bright_cyan,
    :bright_white
  ]
  def valid?(%__MODULE__{role: role, value: value} = color),
    do: map_size(color) == 3 and role in @roles and valid_value?(value)

  def valid?(_), do: false
  defp valid_value?(nil), do: true
  defp valid_value?({:rgb, r, g, b}), do: Enum.all?([r, g, b], &(is_integer(&1) and &1 in 0..255))
  defp valid_value?({:indexed, index}), do: is_integer(index) and index in 0..255
  defp valid_value?({:ansi, color}), do: color in @ansi
  defp valid_value?(_), do: false
  def roles, do: @roles
end
