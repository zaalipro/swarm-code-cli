defmodule SwarmCodeCLI.Cli020.E8SlashListTest do
  # cli020 E8 (ux-live-18): the `/` list's descriptions start in one column
  # and are elided with `…`; its top rule says `8 of N · ↑↓`.
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Test.Pass73Scenes
  alias SwarmCodeCLI.UI.{SafeText, SlashPalette, Width}
  alias SwarmCodeCLI.UI.Projector.Composer

  defp rows(width, draft \\ "/") do
    state = Pass73Scenes.screenshot_11(width, 30) |> Pass73Scenes.put_draft(draft)
    state = %{state | layers: []}
    assert SlashPalette.open?(state)
    blocks = Composer.slash_popup(state, width)
    {state, Enum.map(blocks, fn b -> Enum.map_join(b.spans, "", &SafeText.value(&1.text)) end)}
  end

  test "at 80 columns: one description column, elided with …, nothing past the edge" do
    {state, [rule | lines]} = rows(80)
    total = length(SlashPalette.entries(state))
    assert rule =~ "#{length(lines)} of #{total} · ↑↓"

    for line <- [rule | lines], do: assert(Width.cells(line, :narrow) <= 80, line)

    starts =
      for line <- lines do
        [_, sig, gap] = Regex.run(~r/^(.*?\S)(\s{3,})\S/u, line)
        String.length(sig) + String.length(gap)
      end

    assert length(Enum.uniq(starts)) == 1, inspect(lines, pretty: true)
    assert Enum.any?(lines, &String.contains?(&1, "…"))
  end

  test "no rule while every match is shown" do
    {_state, lines} = rows(120, "/quit")
    refute Enum.any?(lines, &(&1 =~ ~r/\d+ of \d+/))
  end
end
