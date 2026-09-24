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

  # Row 0 is the title and tab row, one row for both (ux M5): every other pane
  # starts at row 1 and the vertical budget the docks, main, activity and
  # composer share is two rows short of the terminal (title, status). At 80x24
  # that leaves main 18 rows.
  @chrome_rows 2
  @body_top 1

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

  # pass72 P6: the side panel docks from this many columns; below it the
  # panel is the one-row strip under the title.
  @panel_columns 120

  @type panel_mode :: :full | :compact | :hidden

  @doc "The column count from which the side panel docks beside main (P6)."
  def panel_columns, do: @panel_columns

  @doc """
  The layout of the state's own terminal, panel mode included (pass72 P6):
  `calculate(state.size, state.preferences, state.panel_mode)` with the panel
  mode read through a default, so a state without the field lays out as full.
  """
  @spec for_state(map()) :: t()
  def for_state(state),
    do: calculate(state.size, state.preferences, Map.get(state, :panel_mode, :full))

  @doc """
  The geometry of `size`. `panel` is the side panel's mode (pass72 P6): from
  120 columns `:full` and `:compact` dock the panel on the right and `:hidden`
  gives main the whole width; under 120 columns the panel is a one-row strip
  (`:tabline`) under the title unless it is `:hidden`.
  """
  @spec calculate(Size.t(), Preferences.t(), panel_mode()) :: t()
  def calculate(size, preferences \\ %Preferences{}, panel \\ :full) do
    class = classify(size)
    preferences = Preferences.validate!(preferences)
    panel = if panel in [:full, :compact, :hidden], do: panel, else: :full

    %__MODULE__{
      class: class,
      size: size,
      preferences: preferences,
      rects: rectangles(class, size, preferences, panel),
      mutations_visible?: class not in [:compressed_small, :too_small]
    }
  end

  defp rectangles(:too_small, size, _preferences, _panel),
    do: %{main: rect(0, 0, size.columns, size.rows)}

  defp rectangles(class, size, preferences, panel) do
    c = size.columns
    r = size.rows
    strip = strip_rows(class, c, panel)
    {x, width, panes} = docks(c, r - @chrome_rows, panel, preferences)
    panes = if strip > 0, do: Map.put(panes, :tabline, rect(0, @body_top, c, strip)), else: panes
    body_top = @body_top + strip

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

    main_height = r - @chrome_rows - strip - composer - activity
    {read_x, read_width} = measure(x, width)

    panes
    |> Map.merge(%{
      title: rect(0, 0, c, 1),
      status: rect(0, r - 1, c, 1),
      main: rect(read_x, body_top, read_width, main_height)
    })
    |> maybe_rect(:activity, read_x, body_top + main_height, read_width, activity)
    |> maybe_rect(:composer, read_x, r - 1 - composer, read_width, composer)
  end

  # The conversation is flush left and takes the whole band the docks leave it:
  # text starts at column 2 and a tool call's one-liner has the width it needs.
  # The old centred 96-cell reading measure put fifteen blank columns to the
  # left of every turn on a wide terminal, which read as a broken layout, not
  # as typography; prose is wrapped by the transcript itself.
  defp measure(x, width), do: {x, width}

  # pass72 P6: from 120 columns the panel docks on the right unless it is
  # hidden; `medium_dock` no longer decides anything (it is kept so a saved
  # session round-trips). Under 120 columns the panel is the strip.
  defp docks(c, height, panel, preferences) when c >= @panel_columns and panel != :hidden,
    do: inspector_dock(c, height, preferences)

  defp docks(c, _height, _panel, _preferences), do: {0, c, %{}}

  # The strip is one row under the title (R17, D10), below 120 columns, at
  # every class that still has a composer.
  defp strip_rows(class, c, panel)
       when c < @panel_columns and panel != :hidden and class not in [:compressed_small],
       do: 1

  defp strip_rows(_class, _c, _panel), do: 0

  # R13: a 46-column panel by default (44 content columns and one blank each
  # side); a nudged width is honoured within 38..56.
  defp inspector_dock(c, height, preferences) do
    inspector = clamp(preferences.inspector_width, 38, min(56, c - 1 - 50))
    {0, c - inspector - 1, %{inspector: rect(c - inspector, @body_top, inspector, height)}}
  end

  defp maybe_rect(rects, _name, _x, _y, _width, 0), do: rects

  defp maybe_rect(rects, name, x, y, width, height),
    do: Map.put(rects, name, rect(x, y, width, height))

  defp clamp(value, low, high), do: min(max(value, low), high)
  defp rect(x, y, width, height), do: %Rect{x: x, y: y, width: width, height: height}
end
