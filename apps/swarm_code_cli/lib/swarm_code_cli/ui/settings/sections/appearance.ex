defmodule SwarmCodeCLI.UI.Settings.Sections.Appearance do
  @moduledoc """
  pass74 U3-9 (spec §2.14, F10): Appearance — this terminal. The theme
  (follow the desktop's mode, dark, light; live, as `/theme`; `SWARM_THEME`
  wins while set and the row says so), the next-launch rows (colours,
  glyphs, ambiguous width, reduced motion, the accent with its twins and its
  contrast on the page), a preview block — the same transcript rows in the
  candidate theme and accent (the theme row's open editor is the candidate;
  the real palette changes only after the commit) — the ASCII twins of the
  glyphs, and a link to the desktop app's own theme.
  """

  use SwarmCodeCLI.UI.Settings.Section, id: :appearance

  alias SwarmCodeCLI.UI.Settings.{Glyphs, Row, Rows}
  alias SwarmCodeCLI.UI.Settings.Editors.Color

  @impl true
  def loads(_ctx), do: [{:values, [:desktop]}]

  @impl true
  def rows(ctx) do
    rows =
      ctx
      |> Rows.registry(:appearance)
      |> Enum.map(&decorate(&1, ctx))

    {before, rest} = Enum.split_while(rows, &(&1.key != "terminal.desktop_theme_link"))
    before ++ preview(ctx) ++ desktop_link(rest, ctx)
  end

  @impl true
  def act(_ctx, %Row{key: "terminal.desktop_theme_link"}, verb)
      when verb in [:open, :enter, :goto, :open_row],
      do: [{:section, :desktop}]

  def act(_ctx, _row, _verb), do: :default

  # ------------------------------------------------------------------ rows

  defp decorate(%Row{key: "terminal.theme"} = row, ctx) do
    case env(ctx, "terminal.theme") do
      %{var: var, value: value} = override when not is_map_key(override, :ignored) ->
        stored = pref(ctx, "theme") || theme_value(ctx) || "follow"

        # The layer draws the same words from the launch's provenance; say it once.
        if Enum.any?(row.lines, &wins_line?/1),
          do: row,
          else: %Row{
            row
            | lines:
                row.lines ++
                  [[{"#{var}=#{value} wins while set · cli.json: #{stored}", :text_muted}]]
          }

      _ ->
        case {theme_value(ctx), desktop_mode(ctx)} do
          {"follow", mode} when is_binary(mode) ->
            %Row{row | lines: row.lines ++ [[{"follows the desktop app: #{mode}", :text_faint}]]}

          _ ->
            row
        end
    end
  end

  defp decorate(%Row{key: "terminal.accent"} = row, ctx) do
    value = pref(ctx, "accent")
    segments = Color.value_segments(value, ctx)

    lines =
      case SwarmCodeCLI.Release.TerminalPreferences.parse_accent(value || "#FF6A1A") do
        {:ok, hex, rgb} -> ctx |> then(&Color.facts(hex, rgb, &1)) |> Enum.drop(1)
        :error -> []
      end

    %Row{
      row
      | value: segments,
        lines: row.lines ++ lines,
        editor: row.editor || {Color, %{}}
    }
  end

  defp decorate(%Row{key: "terminal.colors"} = row, ctx),
    do: auto_hint(row, "auto: #{color_words(caps(ctx, :color_mode))}")

  defp decorate(%Row{key: "terminal.glyphs"} = row, ctx) do
    tier =
      if caps(ctx, :ascii?) == true,
        do: "ascii",
        else: to_string(caps(ctx, :glyph_tier) || "measured")

    row = auto_hint(row, "auto: #{tier}")

    if pref(ctx, "glyphs") == "rich" and pref(ctx, "ambiguous_width") == "wide",
      do: %Row{
        row
        | lines:
            row.lines ++ [[{"! rich glyphs under wide ambiguous width may misalign", :warning}]]
      },
      else: row
  end

  defp decorate(row, _ctx), do: row

  defp wins_line?(segments) when is_list(segments),
    do: Enum.any?(segments, &(is_tuple(&1) and wins_text?(elem(&1, 0))))

  defp wins_line?(_line), do: false

  defp wins_text?(text) when is_binary(text), do: String.contains?(text, "wins while set")
  defp wins_text?(_text), do: false

  defp auto_hint(row, words),
    do: %Row{row | lines: row.lines ++ [[{"this launch: #{words}", :text_faint}]]}

  defp color_words(:truecolor), do: "truecolor"
  defp color_words(:ansi256), do: "256"
  defp color_words(:ansi16), do: "16"
  defp color_words(:monochrome), do: "none"
  defp color_words(_), do: "unknown"

  # --------------------------------------------------------------- preview

  # Two boxes and their gap fit the 80 cells a 160-column page gives a row
  # (QA F-14: at 38 the light box lost its right edge there).
  @box 37

  @doc """
  The preview block (F10): the same transcript rows in a dark and a light
  box side by side, then the ASCII twins of the glyphs. The screen itself
  previews a theme on ←→ (the Enum editor's candidate repaints the page).
  """
  def preview(ctx) do
    tier = tier(ctx)
    ok = Glyphs.get(:ok, tier)
    bar = Glyphs.get(:focus_bar, tier)

    lines = [
      [{"✳ ", :run_assistant}, {"Assistant  ", :title}, {"deepseek-v4-pro", :text_muted}],
      [
        {"  #{ok} ", :success},
        {"read  ", :text_muted},
        {"README.md", :text_primary},
        {"        9ms", :text_faint}
      ],
      [
        {"  #{ok} ", :success},
        {"edit  ", :text_muted},
        {"README.md", :text_primary},
        {"    +1 −0", :success}
      ],
      [{"! ", :warning}, {"deps-agent wants to run", :text_primary}],
      [
        {"   y  ", :key},
        {"once   ", :text_faint},
        {"Y  ", :key},
        {"run   ", :text_faint},
        {"d  ", :key},
        {"deny", :text_faint}
      ],
      [
        {bar, :focus},
        {"focus   ", :text_primary},
        {"s  ", :key},
        {"hint  ", :text_faint},
        {"Enter ", :key},
        {"key", :text_faint}
      ],
      [{"engine data ", :text_primary}, {"text_muted ", :text_muted}, {"faint", :text_faint}],
      [{glyph_line(tier), :text_primary}],
      []
    ]

    boxes =
      [pair([border("┌─ dark ", "┐"), border("┌─ light ", "┐")])] ++
        Enum.map(lines, &pair([boxed(&1), boxed(&1)])) ++
        [pair([border("└", "┘"), border("└", "┘")])]

    [
      Row.heading("preview · the same rows in both themes", [
        {"the screen itself previews on ←→", :text_faint}
      ])
    ] ++
      (boxes
       |> Enum.with_index()
       |> Enum.map(fn {segments, n} -> Row.info("preview-#{n}", segments) end)) ++
      [
        Row.info("preview-ascii", [
          {"ASCII twins  ", :text_muted},
          {"* S C * # /   * ~ . ! v x o   #-", :text_primary},
          {"   (Glyphs: ASCII, or SWARM_ASCII=1)", :text_faint}
        ])
      ]
  end

  defp glyph_line(:ascii), do: "* S C * # /  * ~ . ! v x o #-"
  defp glyph_line(_tier), do: "✳ ⋔ ⚖ ◉ ⧉ ⌕  ● ◐ ◌ ! ✓ ✗ ○ ▰▱"

  defp border(left, right) do
    fill = @box + 2 - String.length(left) - String.length(right)
    [{left <> String.duplicate("─", max(fill, 0)) <> right, :text_ghost}]
  end

  defp boxed(segments) do
    width = segments |> Enum.map(&String.length(elem(&1, 0))) |> Enum.sum()
    pad = max(@box - 2 - width, 0)
    [{"│ ", :text_ghost}] ++ segments ++ [{String.duplicate(" ", pad) <> " │", :text_ghost}]
  end

  defp pair([left, right]), do: left ++ [{" ", :text_ghost}] ++ right

  defp desktop_link(rest, ctx) do
    theme = desktop_value(ctx, "desktop.theme") || "carbon"
    mode = desktop_mode(ctx) || "dark"

    Enum.flat_map(rest, fn
      %Row{key: "terminal.desktop_theme_link"} = row ->
        [
          Row.heading("the desktop app's own theme"),
          %Row{
            row
            | value: [
                {"#{String.capitalize(theme)} · #{mode} · the terminal keeps its own dark and light",
                 :text_muted}
              ],
              tag: [{"g More › Desktop app", :text_faint}],
              keys: [{"Enter", :enter, "open Desktop app"}, {"g", :goto, "go to Desktop app"}]
          }
        ]

      row ->
        [row]
    end)
  end

  # ---------------------------------------------------------------- helpers

  defp desktop_mode(ctx), do: desktop_value(ctx, "desktop.mode")

  defp theme_value(ctx), do: desktop_value(ctx, "terminal.theme")

  defp desktop_value(ctx, key) do
    case ctx.data |> Map.get(:values, %{}) |> Map.get(key) do
      nil -> nil
      value -> Map.get(value, :value)
    end
  end

  defp env(ctx, key),
    do: ctx.launch_facts |> Kernel.||(%{}) |> Map.get(:env_overrides, %{}) |> Map.get(key)

  defp pref(ctx, name), do: Map.get(ctx.prefs || %{}, name)

  defp caps(ctx, field), do: ctx.caps && Map.get(ctx.caps, field)

  defp tier(ctx) do
    cond do
      caps(ctx, :ascii?) == true -> :ascii
      true -> caps(ctx, :glyph_tier) || :measured
    end
  end
end
