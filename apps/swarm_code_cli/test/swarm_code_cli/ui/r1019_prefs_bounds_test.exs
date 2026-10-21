defmodule SwarmCodeCLI.UI.R1019PrefsBoundsTest do
  @moduledoc """
  C-ARCH-12: the terminal preferences' bounds and defaults are the settings
  registry's. For each numeric key `apply_prefs` takes the minimum and the
  maximum and keeps the old value for min-1 and max+1.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Settings.Registry
  alias SwarmCodeCLI.UI.Init.Preferences
  alias SwarmCodeCLI.UI.Reducer.TerminalPrefs

  # json name, registry key, State field, and how the field holds a value.
  @cases [
    {"paste_collapse_lines", "terminal.paste_collapse_lines", :paste_collapse_lines, 1},
    {"wheel_lines", "terminal.wheel_lines", :wheel_lines, 1},
    {"notice_seconds", "terminal.notice_seconds", :notice_ms, 1_000}
  ]

  defp state(field, old), do: Map.put(%{prefs: %{}}, field, old)

  for {json, key, field, factor} <- @cases do
    test "#{json}: min and max apply, min-1 and max+1 keep the old value" do
      range = Registry.range(unquote(key))
      assert %Range{first: first, last: last} = range
      old = unquote(factor) * div(first + last, 2)
      field = unquote(field)

      for ok <- [first, last] do
        assert Map.fetch!(
                 TerminalPrefs.apply_prefs(state(field, old), %{unquote(json) => ok}),
                 field
               ) == ok * unquote(factor)
      end

      for bad <- [first - 1, last + 1, "3", nil, 1.5] do
        assert Map.fetch!(
                 TerminalPrefs.apply_prefs(state(field, old), %{unquote(json) => bad}),
                 field
               ) == old
      end
    end
  end

  test "exit_transcript: the file layer takes min and max and refuses min-1 and max+1" do
    range = Registry.range("terminal.exit_transcript")
    defaults = Preferences.defaults()
    assert defaults.exit_transcript == Registry.default("terminal.exit_transcript")

    for ok <- [range.first, range.last],
        do: assert(Preferences.valid?(%{exit_transcript: ok}))

    for bad <- [range.first - 1, range.last + 1],
        do: refute(Preferences.valid?(%{exit_transcript: bad}))
  end

  test "the file layer's ranges and defaults are the registry's for all four keys" do
    defaults = Preferences.defaults()

    for {field, key} <- [
          paste_collapse_lines: "terminal.paste_collapse_lines",
          wheel_lines: "terminal.wheel_lines",
          notice_seconds: "terminal.notice_seconds",
          exit_transcript: "terminal.exit_transcript"
        ] do
      range = Registry.range(key)
      assert Map.fetch!(defaults, field) == Registry.default(key)
      assert Preferences.valid?(%{field => range.first})
      assert Preferences.valid?(%{field => range.last})
      refute Preferences.valid?(%{field => range.first - 1})
      refute Preferences.valid?(%{field => range.last + 1})
    end
  end

  test "Registry.range/1 is nil for a key without both bounds" do
    assert Registry.range("terminal.title") == nil
    assert Registry.range("no.such.key") == nil
  end
end
