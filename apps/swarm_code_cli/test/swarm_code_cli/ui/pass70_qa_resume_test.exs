defmodule SwarmCodeCLI.UI.Pass70QaResumeTest do
  @moduledoc """
  pass70 Q10, found driving the release: /resume opened a palette titled
  "Search: #" whose conversation rows were buried under every run of the open
  conversation ("Run: …" × 7), with no word on when each conversation last
  moved, and a footer that said "item 1 of 8".
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Editor, Switcher}

  defp query(text), do: elem(Editor.apply(Editor.new(), {:insert, text}), 1)

  test "the resume list is conversations (and researches), not runs" do
    entries = [
      struct(Switcher.Entry, id: "c", kind: :conversation, label: "Fix login · 3 runs"),
      struct(Switcher.Entry, id: "r", kind: :run, label: "Run: Fix login"),
      struct(Switcher.Entry, id: "d", kind: :research, label: "Research: OTP")
    ]

    assert Enum.map(Switcher.rank(query("#"), entries), & &1.id) |> Enum.sort() == ["c", "d"]
  end

  test "a conversation says when it last moved" do
    now = 1_800_000_000_000
    assert Switcher.ago(now - 20_000, now) == "just now"
    assert Switcher.ago(now - 5 * 60_000, now) == "5 min ago"
    assert Switcher.ago(now - 3 * 3_600_000, now) == "3 h ago"
    assert Switcher.ago(now - 3 * 86_400_000, now) == "3 d ago"
    assert Switcher.ago(0, now) == nil
  end
end
