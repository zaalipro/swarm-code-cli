defmodule SwarmCodeCLI.UI.Paint.Style do
  @moduledoc "Pure Theme inheritance and exact renderer-neutral palette values."
  alias SwarmCodeCLI.UI.{Capabilities, SafeText, Theme}
  alias SwarmCodeCLI.UI.Scene.{Color, Style}
  @modes [:truecolor, :ansi256, :ansi16, :monochrome]
  @type entry :: %{foreground: Color.value(), background: Color.value(), modifiers: [atom()]}

  @spec resolve(Style.t(), entry(), atom()) :: {:ok, entry()} | {:error, :invalid_style}
  def resolve(%Style{} = style, inherited, mode) when mode in @modes do
    if scene_style?(style) and entry?(inherited, mode) do
      themed =
        if style.role == :plain,
          do: %Style{},
          else: Theme.style(style.role, %Capabilities{size: nil, color_mode: mode})

      entry = %{
        foreground: value(style.foreground, value(themed.foreground, inherited.foreground)),
        background: value(style.background, value(themed.background, inherited.background)),
        modifiers: canonical(inherited.modifiers ++ themed.modifiers ++ style.modifiers)
      }

      if entry?(entry, mode), do: {:ok, entry}, else: {:error, :invalid_style}
    else
      {:error, :invalid_style}
    end
  rescue
    _ -> {:error, :invalid_style}
  end

  def resolve(_, _, _), do: {:error, :invalid_style}

  @doc false
  def entry?(entry, mode \\ :truecolor)

  def entry?(%{foreground: fg, background: bg, modifiers: modifiers} = entry, mode)
      when mode in @modes do
    not is_struct(entry) and map_size(entry) == 3 and color?(fg, mode) and color?(bg, mode) and
      closed_list?(modifiers, Style.modifiers()) and Enum.uniq(modifiers) == modifiers
  end

  def entry?(_, _), do: false

  defp scene_style?(style) do
    map_size(style) == 7 and style.role in Style.roles() and scene_color?(style.foreground) and
      scene_color?(style.background) and closed_list?(style.modifiers, Style.modifiers()) and
      closed_list?(style.cues, Style.cues()) and prefix?(style.prefix)
  end

  defp prefix?(nil), do: true
  defp prefix?(%SafeText{} = prefix), do: is_binary(SafeText.value(prefix))
  defp prefix?(_), do: false
  defp scene_color?(nil), do: true
  defp scene_color?(color), do: Color.valid?(color)
  defp value(nil, inherited), do: inherited
  defp value(%Color{value: value}, _), do: value
  defp canonical(modifiers), do: Enum.filter(Style.modifiers(), &(&1 in modifiers))

  defp closed_list?(list, allowed), do: closed_list?(list, allowed, length(allowed))
  defp closed_list?([], _allowed, _remaining), do: true

  defp closed_list?([value | rest], allowed, remaining) when remaining > 0,
    do: value in allowed and closed_list?(rest, allowed, remaining - 1)

  defp closed_list?(_, _, _), do: false

  defp color?(value, mode) do
    Color.valid?(%Color{role: :default, value: value}) and
      case value do
        nil -> true
        {:rgb, _, _, _} -> mode == :truecolor
        {:indexed, _} -> mode in [:truecolor, :ansi256]
        {:ansi, _} -> mode in [:truecolor, :ansi256, :ansi16]
        _ -> false
      end
  end
end
