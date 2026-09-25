defmodule SwarmCodeCLI.UI.Settings.Glyphs do
  @moduledoc """
  Every glyph the settings layer draws, with its rich, measured and ASCII
  twins (spec §4.11, T§15.2), in one compile-time table so no owner edits
  `Theme` for them. `get/2` reads the table; `for_caps/2` picks the twin the
  terminal can draw: the ASCII one under `SWARM_ASCII=1` (`ascii?`), and also
  wherever a glyph would not keep one cell per character under the
  terminal's ambiguous-width policy (box drawing and `●` are ambiguous).
  """

  alias SwarmCodeCLI.UI.Width

  # id => {rich, measured, ascii}
  @table %{
    focus_bar: {"▌", "▌", ">"},
    caret: {"▏", "▏", "|"},
    changed: {"•", "•", "*"},
    attention: {"!", "!", "!"},
    crumb: {"›", "›", ">"},
    dot: {"·", "·", "-"},
    ok: {"✓", "✓", "v"},
    fail: {"✗", "✗", "x"},
    check_on: {"[✓]", "[✓]", "[v]"},
    check_off: {"[ ]", "[ ]", "[ ]"},
    secret: {"●●●●●●●●", "●●●●●●●●", "********"},
    running: {"◷", "◷", "~"},
    left_right: {"←→", "←→", "Left/Right"},
    up_down: {"↑↓", "↑↓", "Up/Down"},
    left: {"←", "←", "Left"},
    right: {"→", "→", "Right"},
    up: {"↑", "↑", "Up"},
    down: {"↓", "↓", "Down"},
    action: {"▸", "▸", ">"},
    rule_h: {"─", "─", "-"},
    rule_v: {"│", "│", "|"},
    corner_tl: {"┌", "┌", "+"},
    corner_tr: {"┐", "┐", "+"},
    corner_bl: {"└", "└", "+"},
    corner_br: {"┘", "┘", "+"},
    tee_l: {"│", "│", "|"},
    tee_r: {"│", "│", "|"},
    gauge_on: {"▰", "▰", "#"},
    gauge_off: {"▱", "▱", "."},
    swatch: {"██", "▮▮", ""},
    ellipsis: {"…", "…", "..."},
    step_left: {"‹", "‹", "<"},
    step_right: {"›", "›", ">"},
    dropdown: {"▾", "▾", "v"},
    link: {"→", "→", "->"},
    minus: {"−", "−", "-"},
    times: {"×", "×", "x"},
    quote_open: {"“", "“", "\""},
    quote_close: {"”", "”", "\""}
  }

  @doc "Every glyph id."
  @spec ids() :: [atom()]
  def ids, do: Map.keys(@table)

  @doc "The glyph `id` at `tier` (`:rich | :measured | :ascii`)."
  @spec get(atom(), :rich | :measured | :ascii) :: String.t()
  def get(id, tier) do
    {rich, measured, ascii} = Map.fetch!(@table, id)

    case tier do
      :rich -> rich
      :measured -> measured
      :ascii -> ascii
    end
  end

  @doc "The tier the capabilities ask for."
  @spec tier(map()) :: :rich | :measured | :ascii
  def tier(%{ascii?: true}), do: :ascii
  def tier(%{glyph_tier: :rich}), do: :rich
  def tier(_caps), do: :measured

  @doc """
  The glyph `id` the terminal can draw: its tier's twin, or the ASCII one
  when that twin would not be one cell per character under the ambiguous-width
  policy.
  """
  @spec for_caps(atom(), map()) :: String.t()
  def for_caps(id, caps) do
    case tier(caps) do
      :ascii ->
        get(id, :ascii)

      tier ->
        glyph = get(id, tier)
        policy = Map.get(caps, :ambiguous_width, :narrow)

        if Width.cells(glyph, policy) == String.length(glyph),
          do: glyph,
          else: get(id, :ascii)
    end
  end

  @ascii_words [
    {"›", ">"},
    {"·", "-"},
    {"…", "..."},
    {"‹", "<"},
    {"“", "\""},
    {"”", "\""},
    {"−", "-"},
    {"—", "-"},
    {"–", "-"},
    {"×", "x"},
    {"→", "->"},
    {"←", "<-"},
    {"↑", "Up"},
    {"↓", "Down"},
    {"▸", ">"},
    {"•", "*"},
    {"✓", "v"},
    {"✗", "x"},
    {"◷", "~"},
    {"●", "*"},
    {"▌", ">"},
    {"▏", "|"},
    {"─", "-"},
    {"│", "|"},
    {"▾", "v"},
    {"▰", "#"},
    {"▱", "."},
    {"’", "'"},
    {"‘", "'"}
  ]

  @doc """
  A text with every settings glyph and punctuation mark in its ASCII twin, for
  the ASCII tier (the projector runs every drawn string through it there).
  """
  @spec asciify(String.t()) :: String.t()
  def asciify(text) when is_binary(text) do
    text =
      Enum.reduce(@ascii_words, text, fn {from, to}, acc -> String.replace(acc, from, to) end)

    if ascii_only?(text),
      do: text,
      else:
        text
        |> String.to_charlist()
        |> Enum.map(&if(&1 < 128, do: &1, else: ??))
        |> List.to_string()
  end

  defp ascii_only?(text), do: text |> :binary.bin_to_list() |> Enum.all?(&(&1 < 128))
end
