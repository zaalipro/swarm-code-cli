defmodule SwarmCodeCLI.Cli020.E7HelpSheetTest do
  # cli020 E7 (ux-live-8): the help column is the dialog's text width minus
  # the rows' left padding, long help wraps under the help column (no
  # one-letter `…` row, no blank row after each entry), quit and stop come
  # first, Alt-only chords are not listed, and the sheet lists the commands.
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Cli020EHelpers

  alias SwarmCodeCLI.UI.{Layout, Width}
  alias SwarmCodeCLI.UI.Keymap.Bindings
  alias SwarmCodeCLI.UI.Projector.Dialog

  defp help(size, focus \\ "main") do
    state = fixture(:chat, size, color_mode: :truecolor)

    %{
      state
      | focus: "dialog",
        layers: [:help],
        layer_contexts: [%{focus: focus, hidden_focus: nil}]
    }
  end

  defp body(state) do
    d = Dialog.project(state, Layout.classify(state.size))
    {d, d.rect.width - 2 - 2}
  end

  for size <- [{80, 24}, {120, 40}, {170, 40}] do
    test "every line fits the text width at #{inspect(size)}" do
      state = help(unquote(size))
      {d, text_width} = body(state)
      geometry = Dialog.help_geometry(state, d.rect)
      assert geometry.text_width == text_width

      used = geometry.columns * geometry.column + (geometry.columns - 1) * 2
      # One column is the whole text width; two split it (an odd cell spare).
      if geometry.columns == 1,
        do: assert(used == geometry.text_width),
        else: assert(used in (geometry.text_width - 1)..geometry.text_width)

      for line <- Dialog.help_lines(state, geometry.text_width),
          do: assert(Width.cells(line, :narrow) <= text_width, inspect(line))
    end
  end

  test "long help wraps under the help column; no one-letter remainder, no blank rows" do
    state = help({80, 24}, "composer")
    {d, _} = body(state)
    geometry = Dialog.help_geometry(state, d.rect)
    lines = Dialog.help_lines(state, geometry.text_width)

    refute Enum.any?(lines, &Regex.match?(~r/^\s*\S…\s*$/u, &1))
    keys = Enum.take_while(lines, &(&1 != ""))
    refute Enum.any?(keys, &(String.trim(&1) == ""))

    # A continuation row starts with blanks up to the help column.
    assert Enum.any?(lines, &Regex.match?(~r/^ {6,}\S/, &1))
    text = Enum.join(lines, "\n")
    assert text =~ "scroll the transcript half a"
  end

  test "quit and stop come first" do
    state = help({120, 40})
    [heading, first, second | _] = Dialog.help_lines(state, 114)
    assert heading == "Session"
    assert first =~ "Ctrl-C"
    assert second =~ "Esc"
  end

  test "Alt-only chords are not listed" do
    state = help({170, 40})
    text = Enum.join(Dialog.help_lines(state, 164), "\n")

    alt_only =
      for b <- Bindings.for_context(:main),
          keys = Bindings.keys_in_context(b, :main),
          keys != [] and Enum.all?(keys, fn {_code, mods} -> :alt in mods end),
          do: b

    assert alt_only != [], "the table has Alt-only rows to drop"
    refute text =~ ~r/(^|\s{2})Alt-\S+\s{2,}/m
  end

  test "/help lists the commands" do
    text = help({170, 40}) |> Dialog.help_lines(164) |> Enum.join("\n")
    assert text =~ "Commands"
    assert text =~ ~r/\/rename <title>\s+Rename this conversation/
    assert text =~ ~r/\/quit\s+Leave ncode/
  end
end
