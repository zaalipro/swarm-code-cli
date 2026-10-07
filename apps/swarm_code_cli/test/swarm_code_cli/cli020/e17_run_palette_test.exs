defmodule SwarmCodeCLI.Cli020.E17RunPaletteTest do
  # cli020 E17 (ux-live-21): a finished run in Switch run shows a status
  # glyph, not a full bar (✓ done, ✕ failed in the error colour, ■ stopped;
  # ASCII + x #), and its reason gets the bar's width.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCodeCLI.UI.Pass73Helpers, as: H
  alias SwarmCodeCLI.UI.Theme

  @reason "127.0.0.1 request failed after 5 attempts: HTTP 500"

  defp palette(ascii? \\ false) do
    runs = [
      %{H.run("a", :done, title: "Review the router") | created_sequence: 1},
      %{H.run("b", :failed, title: "hello there") | created_sequence: 2, error: @reason},
      %{H.run("c", :stopped, title: "worker report") | created_sequence: 3},
      %{H.run("d", :running, title: "live one") | created_sequence: 4, progress: 50}
    ]

    state = H.ready(runs, columns: 120, rows: 30)

    %{
      state
      | layers: [{:run_palette, "p"}],
        focus: "a",
        capabilities: %{state.capabilities | color_mode: :truecolor, ascii?: ascii?}
    }
  end

  defp line(text, title),
    do: text |> String.split("\n") |> Enum.find(&(&1 =~ "│" and &1 =~ title))

  test "terminal runs: a glyph, no bar; the live run keeps its bar" do
    text = screen_text(palette())
    bar = "▰▰▰▰"
    assert line(text, "Review the router") =~ "✓"
    refute line(text, "Review the router") =~ bar
    assert line(text, "hello there") =~ "✕"
    refute line(text, "hello there") =~ bar
    assert line(text, "worker report") =~ "■"
    assert line(text, "live one") =~ bar
  end

  test "the failure's reason has the bar's width" do
    # 18 cells said "failed · 127.0.0.…"; the bar's 14 more say more.
    assert line(screen_text(palette()), "hello there") =~ "failed · 127.0.0.1 request fail"
  end

  test "the failed glyph is in the error colour" do
    state = palette()
    {x, y} = locate(state, "✕")

    assert cell_style(plan(state), x, y).foreground ==
             Theme.style(:error, state.capabilities).foreground.value
  end

  test "ASCII: + x #" do
    text = screen_text(palette(true))
    assert line(text, "Review the router") =~ ~r/\+ /
    assert line(text, "hello there") =~ ~r/ x /
    assert line(text, "worker report") =~ ~r/# /
  end
end
