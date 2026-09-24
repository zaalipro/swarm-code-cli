defmodule SwarmCodeCLI.UI.Projector.Panel.Glyph do
  @moduledoc """
  The side panel's glyphs (pass72 P3, P4, R9, R12), each in three tiers:

    * `:rich` — the D2 mockups' glyphs, drawn only at the rich glyph tier,
      where the ambiguous-width policy is narrow and every one is one cell;
    * `:measured` — a twin that is one cell under both ambiguous-width
      policies (`Width.cells/2`), for every other colour terminal;
    * `:ascii` — the ASCII twin (R9: `* ~ . ! v x o =`).

  Run marks are not here: they come from `Theme.run_mark/1` through
  `Support.glyph/2` (R8). `test/.../panel_glyph_test.exs` measures every
  entry under both policies.
  """

  @table %{
    # agent states (R9)
    working: {"●", "⦁", "*"},
    thinking: {"◐", "◒", "~"},
    waiting: {"◌", "◌", "."},
    needs_you: {"!", "!", "!"},
    done: {"✓", "✓", "v"},
    failed: {"✗", "✗", "x"},
    stopped: {"✗", "✗", "x"},
    queued: {"○", "⚬", "o"},
    paused: {"⏸", "⏸", "="},
    # the pulse lane (P4, R7); heights carry the meaning in ASCII
    lane_think: {"▂", "▪", "_"},
    lane_tools: {"▅", "▮", "="},
    lane_write: {"█", "▐", "#"},
    lane_you: {"▒", "░", "%"},
    lane_idle: {"·", "⋅", "."},
    lane_fail: {"✗", "✗", "x"},
    # the two-level tree (R16)
    tee: {"├", "⊢", "|"},
    pipe: {"│", "⎜", "|"},
    elbow: {"╰", "⎣", "`"},
    # the in-chat bar (R4) and the gauges for known ratios (R5)
    in_chat: {"▌", "▐", "|"},
    gauge_on: {"▰", "▰", "#"},
    gauge_off: {"▱", "▱", "-"},
    finding: {"»", "»", ">"},
    rule: {"─", "⎯", "-"},
    open_quote: {"“", "\"", "\""},
    close_quote: {"”", "\"", "\""},
    next: {"›", "›", ">"},
    minus: {"−", "−", "-"},
    times: {"×", "x", "x"},
    dot_on: {"●", "⦁", "*"},
    dot_off: {"○", "⚬", "o"},
    deeper: {"↳", "↳", ">"}
  }

  @doc "Every token with its three forms, for the width tests and the gallery."
  def table, do: @table

  @doc "The token's glyph for the state's capabilities."
  def get(token, %{capabilities: caps}), do: get(token, tier(caps))

  def get(token, tier) when tier in [:rich, :measured, :ascii] do
    {rich, measured, ascii} = Map.fetch!(@table, token)

    case tier do
      :rich -> rich
      :measured -> measured
      :ascii -> ascii
    end
  end

  @doc "The tier the capabilities draw at."
  def tier(%{ascii?: true}), do: :ascii
  def tier(%{glyph_tier: :rich, ambiguous_width: :narrow}), do: :rich
  def tier(_caps), do: :measured
end
