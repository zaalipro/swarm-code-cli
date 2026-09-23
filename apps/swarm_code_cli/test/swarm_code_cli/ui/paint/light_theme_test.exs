defmodule SwarmCodeCLI.UI.Paint.LightThemeTest do
  @moduledoc "pass71 V4 (R6): the Carbon light tokens as a paint-time palette."
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Demo.Conversation
  alias SwarmCodeCLI.UI.{Capabilities, Paint, Projector, Size, Theme}
  alias SwarmCodeCLI.UI.Paint.{Options, Plan}

  defp plan(theme, mode \\ :truecolor) do
    size = %Size{columns: 120, rows: 36}
    state = Conversation.state(:trouble, size, %Capabilities{size: size, color_mode: mode})
    {scene, _} = Projector.project(state)
    assert {:ok, plan} = Paint.build(scene, %Options{color_mode: mode, theme: theme})
    assert :ok = Plan.validate(plan)
    plan
  end

  defp colours(plan, key),
    do: plan.palette |> Tuple.to_list() |> Enum.map(&Map.fetch!(&1, key)) |> MapSet.new()

  test "SWARM_THEME wins, then the desktop's settings mode, then dark" do
    assert Theme.mode("light", "dark") == :light
    assert Theme.mode(" Dark ", "light") == :dark
    assert Theme.mode(nil, "light") == :light
    assert Theme.mode("", "light") == :light
    assert Theme.mode("sepia", nil) == :dark
    assert Theme.mode(nil, nil) == :dark
  end

  test "dark is the default and leaves the terminal's own background alone" do
    assert %Options{}.theme == :dark
    assert nil in colours(plan(:dark), :background)
  end

  test "light paints the page, the text and the cards in the Carbon light tokens" do
    light = plan(:light)
    backgrounds = colours(light, :background)
    foregrounds = colours(light, :foreground)

    refute nil in backgrounds
    refute nil in foregrounds
    # --bg, --bg-card, --text, --err
    assert {:rgb, 0xF4, 0xF3, 0xF1} in backgrounds
    assert {:rgb, 0xFF, 0xFF, 0xFF} in backgrounds
    assert {:rgb, 0x1A, 0x1A, 0x1A} in foregrounds
    assert {:rgb, 0xDC, 0x26, 0x26} in foregrounds
    # No dark text survives.
    refute {:rgb, 0xF3, 0xF2, 0xF0} in foregrounds
    # The accent is the same in both modes.
    assert {:rgb, 0xFF, 0x6A, 0x1A} in foregrounds

    # The cells are the same; only the palette changes.
    assert light.cells == plan(:dark).cells
  end

  test "256 colours map to light indices; monochrome is unchanged" do
    refute nil in colours(plan(:light, :ansi256), :background)
    assert plan(:light, :monochrome).palette == plan(:dark, :monochrome).palette
  end

  test "an unknown theme is refused" do
    size = %Size{columns: 80, rows: 24}
    state = Conversation.state(:empty, size, %Capabilities{size: size})
    {scene, _} = Projector.project(state)
    assert {:error, :invalid_options} = Paint.build(scene, %{%Options{} | theme: :sepia})
  end
end
