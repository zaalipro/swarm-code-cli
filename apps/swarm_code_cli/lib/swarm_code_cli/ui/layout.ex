defmodule SwarmCodeCLI.UI.Layout do
  @moduledoc """
  Pure responsive shell geometry. Requested pane sizes never become effective
  sizes in saved preferences. Rectangles include each pane's content/chrome;
  one empty column separates docks. The projector supplies labels and content.

  This module does not decide domain permission. `mutations_visible?` is only
  the terminal-size gate; the projector must also check each DTO's actions.
  """
  alias SwarmCodeCLI.UI.Size
  alias SwarmCodeCLI.UI.Layout.Preferences
  alias SwarmCodeCLI.UI.Scene.Rect
  defstruct [:class, :size, :preferences, rects: %{}, mutations_visible?: false]
  @type class :: :xl | :wide | :medium | :narrow | :small | :compressed_small | :too_small
  @type t :: %__MODULE__{
          class: class(),
          size: Size.t(),
          preferences: Preferences.t(),
          rects: %{atom() => Rect.t()},
          mutations_visible?: boolean()
        }

  @spec classify(Size.t()) :: class()
  def classify(size) do
    %Size{columns: c, rows: r} = Size.validate!(size)

    cond do
      c >= 170 and r >= 34 -> :xl
      c >= 150 and r >= 30 -> :wide
      c >= 100 and r >= 24 -> :medium
      c >= 72 and r >= 20 -> :narrow
      c >= 50 and r >= 16 -> :small
      c >= 50 and r >= 14 -> :compressed_small
      true -> :too_small
    end
  end

  @spec calculate(Size.t(), Preferences.t()) :: t()
  def calculate(size, preferences \\ %Preferences{}) do
    class = classify(size)
    preferences = Preferences.validate!(preferences)

    %__MODULE__{
      class: class,
      size: size,
      preferences: preferences,
      rects: rectangles(class, size, preferences),
      mutations_visible?: class not in [:compressed_small, :too_small]
    }
  end

  defp rectangles(:too_small, size, _preferences),
    do: %{main: rect(0, 0, size.columns, size.rows)}

  defp rectangles(class, size, preferences) do
    c = size.columns
    r = size.rows
    {x, width, panes} = docks(class, c, r - 2, preferences)

    composer =
      case class do
        :compressed_small -> 0
        :small -> 1
        _ -> preferences.composer_height
      end

    activity =
      if class in [:small, :compressed_small],
        do: min(preferences.activity_height, 1),
        else: preferences.activity_height

    main_height = r - 2 - composer - activity

    panes
    |> Map.merge(%{
      title: rect(0, 0, c, 1),
      status: rect(0, r - 1, c, 1),
      main: rect(x, 1, width, main_height)
    })
    |> maybe_rect(:activity, x, 1 + main_height, width, activity)
    |> maybe_rect(:composer, x, r - 1 - composer, width, composer)
  end

  defp docks(class, c, height, preferences) when class in [:xl, :wide] do
    nav = clamp(preferences.navigator_width, 24, 32)
    inspector = clamp(preferences.inspector_width, 38, min(56, c - nav - 2 - 50))

    {nav + 1, c - nav - inspector - 2,
     %{navigator: rect(0, 1, nav, height), inspector: rect(c - inspector, 1, inspector, height)}}
  end

  defp docks(:medium, c, height, %Preferences{medium_dock: :navigator} = preferences) do
    nav = clamp(preferences.navigator_width, 24, min(32, c - 1 - 50))
    {nav + 1, c - nav - 1, %{navigator: rect(0, 1, nav, height)}}
  end

  defp docks(:medium, c, height, %Preferences{medium_dock: :inspector} = preferences) do
    inspector = clamp(preferences.inspector_width, 38, min(56, c - 1 - 50))
    {0, c - inspector - 1, %{inspector: rect(c - inspector, 1, inspector, height)}}
  end

  defp docks(_class, c, _height, _preferences), do: {0, c, %{}}

  defp maybe_rect(rects, _name, _x, _y, _width, 0), do: rects

  defp maybe_rect(rects, name, x, y, width, height),
    do: Map.put(rects, name, rect(x, y, width, height))

  defp rect(x, y, width, height), do: %Rect{x: x, y: y, width: width, height: height}
  defp clamp(value, low, high), do: min(max(value, low), high)
end
