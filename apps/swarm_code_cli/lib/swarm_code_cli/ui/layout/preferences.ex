defmodule SwarmCodeCLI.UI.Layout.Preferences do
  @moduledoc """
  Requested pane dimensions, preserved independently of temporary terminal clamps.

  `medium_dock` names what a medium terminal docks beside main. The navigator is
  gone, so the only pane left to dock is the inspector and the only other choice
  is `:none` — a named "dock nothing", not a reference to a pane that no longer
  exists. It defaults to `:none` because the inspector's 38-56 columns come out
  of main, which at 100 columns leaves main 57: the runs the navigator used to
  show are on the tab row and in Ctrl-G now, so main keeps the width by default
  and Ctrl-B docks the inspector when it is wanted.

  `navigator_width` is kept only so a persisted session round-trips unchanged;
  no pane reads it.
  """
  defstruct navigator_width: 26,
            inspector_width: 42,
            composer_height: 3,
            activity_height: 1,
            medium_dock: :none

  @type t :: %__MODULE__{
          navigator_width: integer(),
          inspector_width: integer(),
          composer_height: 1..8,
          activity_height: 0..2,
          medium_dock: :none | :inspector
        }

  def new(options \\ []), do: __MODULE__ |> struct!(options) |> validate!()

  def validate!(%__MODULE__{} = preferences) do
    if map_size(preferences) == 6 and is_integer(preferences.navigator_width) and
         is_integer(preferences.inspector_width) and preferences.composer_height in 1..8 and
         preferences.activity_height in 0..2 and
         preferences.medium_dock in [:none, :inspector],
       do: preferences,
       else: raise(ArgumentError, "invalid layout preferences")
  end

  def validate!(_), do: raise(ArgumentError, "invalid layout preferences")

  def nudge(%__MODULE__{} = preferences, pane, delta)
      when pane in [:navigator, :inspector] and delta in [-8, -2, 2, 8] do
    key = width_key(pane)
    preferences |> Map.update!(key, &(&1 + delta)) |> validate!()
  end

  def reset(preferences, :navigator), do: %{validate!(preferences) | navigator_width: 26}
  def reset(preferences, :inspector), do: %{validate!(preferences) | inspector_width: 42}

  def preset(preferences, pane, preset) when pane in [:navigator, :inspector] do
    Map.put(validate!(preferences), width_key(pane), preset_width(pane, preset))
  end

  defp width_key(:navigator), do: :navigator_width
  defp width_key(:inspector), do: :inspector_width
  defp preset_width(:navigator, :compact), do: 24
  defp preset_width(:navigator, :balanced), do: 28
  defp preset_width(:navigator, :wide), do: 32
  defp preset_width(:inspector, :compact), do: 38
  defp preset_width(:inspector, :balanced), do: 46
  defp preset_width(:inspector, :wide), do: 56
end
