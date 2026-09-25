defmodule SwarmCodeCLI.UI.Theme do
  @moduledoc """
  Carbon dark as renderer-neutral color values, text prefixes and layout cues.

  A role's text prefix (`FOCUS >`, `[INFO]`, `! WAITING`, the run-kind
  letters) is the colour's stand-in, so it is attached only in `:monochrome`,
  the mode `NO_COLOR` selects; in colour the colour says it and a prefix would
  say it twice (ux M6). Structural `cues` hold in every mode.
  `:reason_required` requires the projector to supply the disabled reason as
  SafeText beside the fixed [DISABLED] prefix. Status words and action availability
  remain projector data; status/1 never invents Retry or Resume permission.
  No colored underline or renderer escape sequences are represented here.

  The canvas is the terminal's own background (ux M11): `:canvas` carries no
  colour, and only surfaces that the design draws as cards fill their cells.
  """
  alias SwarmCodeCLI.UI.{Capabilities, SafeText, Scene}
  alias SwarmCodeCLI.UI.Scene.{Color, Style}
  @modes [:truecolor, :ansi256, :ansi16, :monochrome]
  @carbon_accent 0xFF6A1A
  @carbon_accent_tint 0x3E291D
  # xterm's default 16 colours, for the accent's 16-colour twin.
  @ansi16 [
    black: {0, 0, 0},
    red: {205, 0, 0},
    green: {0, 205, 0},
    yellow: {205, 205, 0},
    blue: {0, 0, 238},
    magenta: {205, 0, 205},
    cyan: {0, 205, 205},
    white: {229, 229, 229},
    bright_black: {127, 127, 127},
    bright_red: {255, 0, 0},
    bright_green: {0, 255, 0},
    bright_yellow: {255, 255, 0},
    bright_blue: {92, 92, 255},
    bright_magenta: {255, 0, 255},
    bright_cyan: {0, 255, 255},
    bright_white: {255, 255, 255}
  ]

  @type run_kind ::
          :assistant | :goal | :swarm | :workflow | :research | :consensus_judge | :ultra

  def roles, do: Style.roles()

  @spec style(Scene.style_role(), Capabilities.t()) :: Style.t()
  def style(role, %Capabilities{color_mode: mode}) when mode in @modes do
    style = role |> base_style(mode) |> Map.put(:role, role)
    if mode == :monochrome, do: style, else: %{style | prefix: nil}
  end

  defp base_style(:border, mode),
    do: %Style{foreground: color(mode, 0x2A2A2A, 236, :bright_black)} |> cue(:border, mode)

  defp base_style(:text_primary, mode),
    do: %Style{foreground: color(mode, 0xF3F2F0, 255, :bright_white)} |> cue(:text_primary, mode)

  defp base_style(:text_muted, mode),
    do: %Style{foreground: color(mode, 0x8C8B88, 245, :white)} |> cue(:text_muted, mode)

  defp base_style(:text_faint, mode),
    do: %Style{foreground: color(mode, 0x5E5D5A, 240, :bright_black)} |> cue(:text_faint, mode)

  # One step below faint: placeholders such as "no tools yet" that must read as
  # absence rather than as content.
  defp base_style(:text_ghost, mode),
    do: %Style{foreground: color(mode, 0x4B4A48, 239, :bright_black)} |> cue(:text_ghost, mode)

  defp base_style(:focus, mode),
    do: %Style{foreground: color(mode, 0xFF6A1A, 208, :bright_yellow)} |> cue(:focus, mode)

  defp base_style(:disabled, mode),
    do: %Style{foreground: color(mode, 0x5E5D5A, 240, :bright_black)} |> cue(:disabled, mode)

  defp base_style(:stale, mode),
    do: %Style{foreground: color(mode, 0xF5B400, 220, :bright_yellow)} |> cue(:stale, mode)

  defp base_style(:accent, mode),
    do: %Style{foreground: color(mode, 0xFF6A1A, 208, :bright_yellow)} |> cue(:accent, mode)

  defp base_style(:assistant, mode),
    do: %Style{foreground: color(mode, 0xFF6A1A, 208, :bright_yellow)} |> cue(:assistant, mode)

  defp base_style(:success, mode),
    do: %Style{foreground: color(mode, 0x3DDC5A, 41, :bright_green)} |> cue(:success, mode)

  defp base_style(:warning, mode),
    do: %Style{foreground: color(mode, 0xF5B400, 220, :bright_yellow)} |> cue(:warning, mode)

  defp base_style(:error, mode),
    do: %Style{foreground: color(mode, 0xFF4D4F, 203, :bright_red)} |> cue(:error, mode)

  defp base_style(:info, mode),
    do: %Style{foreground: color(mode, 0x4DA3FF, 75, :bright_blue)} |> cue(:info, mode)

  defp base_style(:workflow, mode),
    do: %Style{foreground: color(mode, 0x4DA3FF, 75, :bright_blue)} |> cue(:workflow, mode)

  defp base_style(:run_assistant, mode),
    do:
      %Style{foreground: color(mode, 0xFF6A1A, 208, :bright_yellow)} |> cue(:run_assistant, mode)

  defp base_style(:run_goal, mode),
    do: %Style{foreground: color(mode, 0xB08CFF, 141, :bright_magenta)} |> cue(:run_goal, mode)

  defp base_style(:run_swarm, mode),
    do: %Style{foreground: color(mode, 0x2FD0B8, 44, :bright_cyan)} |> cue(:run_swarm, mode)

  defp base_style(:run_workflow, mode),
    do: %Style{foreground: color(mode, 0x4DA3FF, 75, :bright_blue)} |> cue(:run_workflow, mode)

  defp base_style(:run_research, mode),
    do: %Style{foreground: color(mode, 0xFF9F45, 215, :yellow)} |> cue(:run_research, mode)

  defp base_style(:run_consensus_judge, mode),
    do:
      %Style{foreground: color(mode, 0xB8E356, 149, :bright_green)}
      |> cue(:run_consensus_judge, mode)

  defp base_style(:run_ultra, mode),
    do: %Style{foreground: color(mode, 0x9B5CFF, 135, :bright_magenta)} |> cue(:run_ultra, mode)

  defp base_style(:agent_lane_1, mode),
    do: %Style{foreground: color(mode, 0x2DD4BF, 44, :cyan)} |> cue(:agent_lane_1, mode)

  defp base_style(:agent_lane_2, mode),
    do: %Style{foreground: color(mode, 0xA78BFA, 141, :magenta)} |> cue(:agent_lane_2, mode)

  defp base_style(:agent_lane_3, mode),
    do: %Style{foreground: color(mode, 0xF59E0B, 214, :yellow)} |> cue(:agent_lane_3, mode)

  defp base_style(:agent_lane_4, mode),
    do: %Style{foreground: color(mode, 0xF472B6, 212, :magenta)} |> cue(:agent_lane_4, mode)

  defp base_style(:agent_lane_5, mode),
    do: %Style{foreground: color(mode, 0x38BDF8, 81, :cyan)} |> cue(:agent_lane_5, mode)

  defp base_style(:canvas, mode), do: %Style{} |> cue(:canvas, mode)

  defp base_style(:surface, mode),
    do: %Style{background: color(mode, 0x191919, 234, :black)} |> cue(:surface, mode)

  defp base_style(:card, mode),
    do: %Style{background: color(mode, 0x1E1E1E, 235, :bright_black)} |> cue(:card, mode)

  defp base_style(:ticks_track, mode),
    do: %Style{foreground: color(mode, 0x3C3C3B, 238, :bright_black)} |> cue(:ticks_track, mode)

  defp base_style(:border_soft, mode),
    do: %Style{foreground: color(mode, 0x2A2A2A, 236, :bright_black)} |> cue(:border_soft, mode)

  defp base_style(:popover, mode),
    do: %Style{background: color(mode, 0x1C1C1C, 234, :black)} |> cue(:popover, mode)

  defp base_style(:hover, mode),
    do: %Style{background: color(mode, 0x262626, 236, :bright_black)} |> cue(:hover, mode)

  defp base_style(:on_accent, mode),
    do:
      %Style{
        foreground: color(mode, 0x111111, 233, :black),
        background: color(mode, 0xFF6A1A, 208, :bright_yellow)
      }
      |> cue(:on_accent, mode)

  defp base_style(:on_warn, mode),
    do:
      %Style{
        foreground: color(mode, 0x111111, 233, :black),
        background: color(mode, 0xF5B400, 220, :bright_yellow)
      }
      |> cue(:on_warn, mode)

  defp base_style(:ultra_a, mode),
    do: %Style{foreground: color(mode, 0xFF5DB1, 205, :bright_magenta)} |> cue(:ultra_a, mode)

  defp base_style(:ultra_b, mode),
    do: %Style{foreground: color(mode, 0x9B5CFF, 135, :bright_magenta)} |> cue(:ultra_b, mode)

  defp base_style(:chip_accent, mode),
    do:
      %Style{
        foreground: color(mode, 0xFF6A1A, 208, :bright_yellow),
        background: color(mode, 0x3E291D, 236, :black)
      }
      |> cue(:chip_accent, mode)

  defp base_style(:chip_ok, mode),
    do:
      %Style{
        foreground: color(mode, 0x3DDC5A, 41, :bright_green),
        background: color(mode, 0x223926, 236, :black)
      }
      |> cue(:chip_ok, mode)

  defp base_style(:chip_warn, mode),
    do:
      %Style{
        foreground: color(mode, 0xF5B400, 220, :bright_yellow),
        background: color(mode, 0x3C331A, 236, :black)
      }
      |> cue(:chip_warn, mode)

  defp base_style(:chip_err, mode),
    do:
      %Style{
        foreground: color(mode, 0xFF4D4F, 203, :bright_red),
        background: color(mode, 0x3E2525, 236, :black)
      }
      |> cue(:chip_err, mode)

  defp base_style(:chip_info, mode),
    do:
      %Style{
        foreground: color(mode, 0x4DA3FF, 75, :bright_blue),
        background: color(mode, 0x25313E, 236, :black)
      }
      |> cue(:chip_info, mode)

  defp base_style(:ext_ts, mode),
    do: %Style{foreground: color(mode, 0x4DA3FF, 75, :bright_blue)} |> cue(:ext_ts, mode)

  defp base_style(:ext_ex, mode),
    do: %Style{foreground: color(mode, 0xA78BFA, 141, :magenta)} |> cue(:ext_ex, mode)

  defp base_style(:ext_js, mode),
    do: %Style{foreground: color(mode, 0xF5B400, 220, :bright_yellow)} |> cue(:ext_js, mode)

  defp base_style(:ext_md, mode),
    do: %Style{foreground: color(mode, 0x3DDC5A, 41, :bright_green)} |> cue(:ext_md, mode)

  defp base_style(:ext_css, mode),
    do: %Style{foreground: color(mode, 0xF472B6, 212, :magenta)} |> cue(:ext_css, mode)

  defp base_style(:ext_json, mode),
    do: %Style{foreground: color(mode, 0xFF9D5C, 215, :yellow)} |> cue(:ext_json, mode)

  defp base_style(:ext_html, mode),
    do: %Style{foreground: color(mode, 0xFF7A59, 209, :bright_red)} |> cue(:ext_html, mode)

  defp base_style(:ext_py, mode),
    do: %Style{foreground: color(mode, 0x38BDF8, 81, :cyan)} |> cue(:ext_py, mode)

  defp base_style(:ext_rs, mode),
    do: %Style{foreground: color(mode, 0xF97316, 208, :bright_yellow)} |> cue(:ext_rs, mode)

  defp base_style(:ext_go, mode),
    do: %Style{foreground: color(mode, 0x22D3EE, 44, :bright_cyan)} |> cue(:ext_go, mode)

  defp base_style(:selection, mode) when mode in [:ansi16, :monochrome],
    do: %Style{modifiers: [:reversed]} |> cue(:selection, mode)

  defp base_style(:selection, mode),
    do:
      %Style{
        foreground: color(mode, 0xF3F2F0, 255, :bright_white),
        background: color(mode, 0x262626, 236, :black)
      }
      |> cue(:selection, mode)

  defp base_style(:plain, mode), do: base_style(:text_primary, mode)

  defp base_style(:title, mode),
    do: base_style(:text_primary, mode) |> Map.put(:modifiers, [:bold])

  defp base_style(:heading, mode),
    do: base_style(:text_primary, mode) |> Map.put(:modifiers, [:bold])

  defp base_style(:body, mode), do: base_style(:text_primary, mode)
  defp base_style(:label, mode), do: base_style(:text_muted, mode)
  defp base_style(:value, mode), do: base_style(:text_primary, mode)
  # Code reads on its own surface: inline code is a chip on the hover fill and
  # a fenced block a card, in the desktop's `.prose-chat code` colours.
  defp base_style(:code, mode),
    do: %Style{
      foreground: color(mode, 0xF3F2F0, 255, :bright_white),
      background: color(mode, 0x262626, 236, :black)
    }

  defp base_style(:link, mode), do: base_style(:info, mode)

  defp base_style(:key, mode),
    do:
      %Style{foreground: color(mode, 0x4DA3FF, 75, :bright_blue)} |> Map.put(:modifiers, [:bold])

  defp base_style(:status, mode), do: base_style(:text_primary, mode)
  defp base_style(:selected, mode), do: base_style(:selection, mode)

  defp base_style(:emphasis, mode),
    do: base_style(:text_primary, mode) |> Map.put(:modifiers, [:bold])

  # ---------------------------------------------------------------- light

  # pass71 V4 (R6): Carbon light, from the desktop's
  # `html[data-theme="carbon"][data-mode="light"]` tokens, keyed by the dark
  # value each one replaces. A colour with no entry (the accent) is the same
  # in both modes.
  @light_rgb %{
    # text, muted, faint, ghost
    0xF3F2F0 => 0x1A1A1A,
    0x8C8B88 => 0x6B6A67,
    0x5E5D5A => 0x96948F,
    0x4B4A48 => 0xB5B3AE,
    # border, bar track, elevated, card, popover, hover
    0x2A2A2A => 0xE2E0DC,
    0x3C3C3B => 0xE2E0DC,
    0x191919 => 0xFAF9F7,
    0x1E1E1E => 0xFFFFFF,
    0x1C1C1C => 0xFFFFFF,
    0x262626 => 0xECEBE8,
    # on-accent text, ok, warn, err, info
    0x111111 => 0xFFFFFF,
    0x3DDC5A => 0x16A34A,
    0xF5B400 => 0xB98300,
    0xFF4D4F => 0xDC2626,
    0x4DA3FF => 0x2563EB,
    # lanes
    0x2DD4BF => 0x0F766E,
    0xA78BFA => 0x7C3AED,
    0xF59E0B => 0x92400E,
    0xF472B6 => 0xBE185D,
    0x38BDF8 => 0x0369A1,
    # run kinds and the rest of the dark accents, darkened to read on white
    0xB08CFF => 0x7C3AED,
    0x2FD0B8 => 0x0F766E,
    0xFF9F45 => 0xC2410C,
    0xB8E356 => 0x4D7C0F,
    0x9B5CFF => 0x7C3AED,
    0xFF5DB1 => 0xBE185D,
    0xFF9D5C => 0xC2410C,
    0xFF7A59 => 0xC2410C,
    0xF97316 => 0xC2410C,
    0x22D3EE => 0x0E7490,
    # chip surfaces: the soft tints on a white card
    0x3E291D => 0xFFE9DD,
    0x223926 => 0xE3F4E8,
    0x3C331A => 0xF7EDD5,
    0x3E2525 => 0xFBE3E3,
    0x25313E => 0xE1EAFB
  }
  @light_page 0xF4F3F1
  @light_text 0x1A1A1A

  # The xterm-256 indices the dark theme uses, and their light twins.
  @light_index %{
    255 => 234,
    245 => 242,
    240 => 246,
    239 => 249,
    236 => 254,
    238 => 253,
    234 => 255,
    235 => 231,
    233 => 231,
    41 => 28,
    220 => 136,
    203 => 160,
    75 => 26,
    44 => 30,
    141 => 92,
    214 => 94,
    212 => 162,
    81 => 25,
    149 => 64,
    135 => 92,
    205 => 162,
    215 => 166,
    209 => 166
  }
  @light_index_page 255
  @light_index_text 234

  @doc """
  pass71 V4: a painted palette entry in Carbon light. The terminal's own
  background and foreground become the light page and its text, so the light
  theme reads the same on a dark terminal. ANSI-16 and monochrome entries are
  unchanged: their colours are the terminal's own.
  """
  def light_entry(%{foreground: fg, background: bg} = entry, mode)
      when mode in [:truecolor, :ansi256] do
    %{entry | foreground: light(fg, :text, mode), background: light(bg, :page, mode)}
  end

  def light_entry(entry, _mode), do: entry

  @doc "The Carbon light twin of one dark palette value."
  def light(nil, :page, :truecolor), do: rgb(@light_page)
  def light(nil, :text, :truecolor), do: rgb(@light_text)
  def light(nil, :page, :ansi256), do: {:indexed, @light_index_page}
  def light(nil, :text, :ansi256), do: {:indexed, @light_index_text}

  def light({:rgb, r, g, b} = value, _slot, _mode) do
    hex = r * 65_536 + g * 256 + b

    case Map.fetch(@light_rgb, hex) do
      {:ok, twin} -> rgb(twin)
      :error -> light_accent_tint(hex, value)
    end
  end

  def light({:indexed, index} = value, _slot, _mode) do
    case Map.fetch(@light_index, index) do
      {:ok, twin} -> {:indexed, twin}
      :error -> value
    end
  end

  def light(value, _slot, _mode), do: value

  # pass74: the chip tint of a custom accent reads on a white card as the
  # Carbon tint does.
  defp light_accent_tint(hex, value) do
    case accent() do
      nil ->
        value

      accent ->
        if hex == tint(accent, 0x111111, 0.2), do: rgb(tint(accent, 0xFFFFFF, 0.15)), else: value
    end
  end

  defp rgb(hex), do: {:rgb, div(hex, 65_536), rem(div(hex, 256), 256), rem(hex, 256)}

  @doc """
  pass71 V4 (R6): which theme to paint. `SWARM_THEME` (`light` or `dark`)
  wins; otherwise the desktop's settings `mode`; otherwise dark. Pure: the
  caller reads the environment and the settings.
  """
  @spec mode(binary() | nil, term()) :: :dark | :light
  def mode(env, settings_mode), do: mode(env, nil, settings_mode)

  @doc """
  pass73 T2: the start precedence with the `/theme` choice persisted in
  cli.json: `SWARM_THEME` > cli.json `theme` > the desktop settings' `mode`
  > dark. Pure; unknown values fall through to the next source.
  """
  @spec mode(binary() | nil, term(), term()) :: :dark | :light
  def mode(env, preference, settings_mode) do
    normalize_mode(env) || normalize_mode(preference) || normalize_mode(settings_mode) || :dark
  end

  @doc """
  pass73 T2: the theme `SWARM_THEME` forces at every launch, or nil. A live
  `/theme` switch still applies; its confirmation says this one wins at the
  next launch (`switch_words/2`).
  """
  @spec env_mode(binary() | nil) :: :dark | :light | nil
  def env_mode(env), do: normalize_mode(env)

  @doc """
  pass73 T2: the one-line confirmation of a `/theme` switch to `mode`, naming
  the `SWARM_THEME` override when it will win at the next launch.
  """
  @spec switch_words(:dark | :light, binary() | nil) :: binary()
  def switch_words(mode, env) when mode in [:dark, :light] do
    base = "Theme: #{mode} · /theme switches back"

    case normalize_mode(env) do
      nil -> base
      ^mode -> base
      forced -> base <> " · SWARM_THEME=#{forced} still wins at the next launch"
    end
  end

  defp normalize_mode(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "light" -> :light
      "dark" -> :dark
      _ -> nil
    end
  end

  defp normalize_mode(value) when value in [:light, :dark], do: value
  defp normalize_mode(_), do: nil

  # pass74 (§3.8.4, `terminal.accent`): the accent roles — every colour that
  # is Carbon's #FF6A1A, and the chip tint made from it — follow the accent the
  # launch chose. Nil keeps Carbon exactly.
  defp color(mode, @carbon_accent, index, ansi) do
    case accent() do
      nil -> plain_color(mode, @carbon_accent, index, ansi)
      rgb -> accent_color(mode, rgb)
    end
  end

  defp color(mode, @carbon_accent_tint, index, ansi) do
    case accent() do
      nil -> plain_color(mode, @carbon_accent_tint, index, ansi)
      rgb -> plain_color(mode, tint(rgb, 0x111111, 0.2), index, ansi)
    end
  end

  defp color(mode, rgb, index, ansi), do: plain_color(mode, rgb, index, ansi)

  defp accent_color(mode, rgb) do
    twins = accent_twins(rgb)
    plain_color(mode, rgb, twins.ansi256, twins.ansi16)
  end

  defp plain_color(:truecolor, rgb, _index, _ansi),
    do: %Color{
      role: :default,
      value: {:rgb, div(rgb, 65_536), rem(div(rgb, 256), 256), rem(rgb, 256)}
    }

  defp plain_color(:ansi256, _rgb, index, _ansi),
    do: %Color{role: :default, value: {:indexed, index}}

  defp plain_color(:ansi16, _rgb, _index, ansi), do: %Color{role: :default, value: {:ansi, ansi}}
  defp plain_color(:monochrome, _rgb, _index, _ansi), do: nil

  # ---------------------------------------------------------------- accent

  @accent_key {__MODULE__, :accent}

  @doc """
  pass74 (§3.8.4): the launch's accent colour, `{r, g, b}` or nil for
  Carbon's own. Written once by the launcher before the port owner starts
  (a `:persistent_term`, process-wide for the launch).
  """
  @spec put_accent({0..255, 0..255, 0..255} | nil) :: :ok
  def put_accent(nil) do
    _ = :persistent_term.erase(@accent_key)
    :ok
  end

  def put_accent({r, g, b})
      when r in 0..255 and g in 0..255 and b in 0..255 do
    :persistent_term.put(@accent_key, r * 65_536 + g * 256 + b)
  end

  @doc "The accent in use as a 24-bit integer, or nil for Carbon's #FF6A1A."
  @spec accent() :: non_neg_integer() | nil
  def accent, do: :persistent_term.get(@accent_key, nil)

  @doc """
  The 256- and 16-colour twins of an accent colour (nearest by distance in
  RGB; the 256 twin is chosen from the colour cube and the grey ramp, whose
  values do not depend on the terminal's own palette).
  """
  @spec accent_twins(non_neg_integer() | {0..255, 0..255, 0..255}) :: %{
          rgb: non_neg_integer(),
          ansi256: 16..255,
          ansi16: atom()
        }
  def accent_twins({r, g, b}), do: accent_twins(r * 65_536 + g * 256 + b)

  def accent_twins(rgb) when is_integer(rgb) do
    triple = split(rgb)

    %{
      rgb: rgb,
      ansi256: Enum.min_by(16..255, &distance(triple, xterm256(&1))),
      ansi16: @ansi16 |> Enum.min_by(fn {_name, value} -> distance(triple, value) end) |> elem(0)
    }
  end

  @doc """
  The WCAG 2 contrast ratio of two 24-bit colours (1.0–21.0). The settings
  page shows it for an accent on the page colour of the current mode.
  """
  @spec contrast(non_neg_integer(), non_neg_integer()) :: float()
  def contrast(a, b) do
    {hi, lo} =
      Enum.min_max_by([luminance(a), luminance(b)], & &1) |> then(fn {l, h} -> {h, l} end)

    Float.round((hi + 0.05) / (lo + 0.05), 2)
  end

  @doc "The page colour contrast is measured against, per mode."
  @spec page_color(:dark | :light) :: non_neg_integer()
  def page_color(:light), do: @light_page
  def page_color(_dark), do: 0x111111

  defp luminance(rgb) do
    {r, g, b} = split(rgb)

    [r, g, b]
    |> Enum.map(fn channel ->
      c = channel / 255
      if c <= 0.03928, do: c / 12.92, else: :math.pow((c + 0.055) / 1.055, 2.4)
    end)
    |> then(fn [r, g, b] -> 0.2126 * r + 0.7152 * g + 0.0722 * b end)
  end

  defp tint(rgb, base, amount) do
    {r1, g1, b1} = split(rgb)
    {r2, g2, b2} = split(base)
    mix = fn a, b -> round(b + (a - b) * amount) end
    mix.(r1, r2) * 65_536 + mix.(g1, g2) * 256 + mix.(b1, b2)
  end

  defp split(rgb), do: {div(rgb, 65_536), rem(div(rgb, 256), 256), rem(rgb, 256)}

  defp distance({r1, g1, b1}, {r2, g2, b2}),
    do: (r1 - r2) * (r1 - r2) + (g1 - g2) * (g1 - g2) + (b1 - b2) * (b1 - b2)

  @cube [0, 95, 135, 175, 215, 255]

  defp xterm256(index) when index in 16..231 do
    n = index - 16
    {Enum.at(@cube, div(n, 36)), Enum.at(@cube, rem(div(n, 6), 6)), Enum.at(@cube, rem(n, 6))}
  end

  defp xterm256(index) when index in 232..255 do
    level = 8 + (index - 232) * 10
    {level, level, level}
  end

  defp cue(style, :focus, mode),
    do: %{
      style
      | prefix: SafeText.chrome(:focus_marker),
        modifiers: if(mode == :monochrome, do: [:reversed, :bold], else: [:bold])
    }

  defp cue(style, :selection, _mode), do: %{style | prefix: SafeText.chrome(:selection_marker)}

  defp cue(style, :disabled, _mode),
    do: %{style | prefix: SafeText.chrome(:disabled_marker), cues: [:reason_required]}

  defp cue(style, :stale, _mode),
    do: %{style | prefix: SafeText.chrome(:stale_marker), cues: [:border]}

  defp cue(style, :surface, _mode), do: %{style | cues: [:separator]}

  defp cue(style, role, _mode) when role in [:card, :border, :border_soft],
    do: %{style | cues: [:border]}

  defp cue(style, role, _mode) when role in [:text_muted, :text_faint, :text_ghost],
    do: %{style | cues: [:explicit_label]}

  defp cue(style, :accent, _mode), do: %{style | prefix: SafeText.chrome(:accent_marker)}
  defp cue(style, :assistant, _mode), do: %{style | prefix: SafeText.chrome(:run_assistant)}
  defp cue(style, :success, _mode), do: %{style | prefix: SafeText.chrome(:success_marker)}
  defp cue(style, :warning, _mode), do: %{style | prefix: SafeText.chrome(:warning_marker)}
  defp cue(style, :error, _mode), do: %{style | prefix: SafeText.chrome(:error_marker)}
  defp cue(style, :info, _mode), do: %{style | prefix: SafeText.chrome(:info_marker)}
  defp cue(style, :workflow, _mode), do: %{style | prefix: SafeText.chrome(:run_workflow)}
  defp cue(style, :run_assistant, _mode), do: %{style | prefix: SafeText.chrome(:run_assistant)}
  defp cue(style, :run_goal, _mode), do: %{style | prefix: SafeText.chrome(:run_goal)}
  defp cue(style, :run_swarm, _mode), do: %{style | prefix: SafeText.chrome(:run_swarm)}
  defp cue(style, :run_workflow, _mode), do: %{style | prefix: SafeText.chrome(:run_workflow)}
  defp cue(style, :run_research, _mode), do: %{style | prefix: SafeText.chrome(:run_research)}

  defp cue(style, :run_consensus_judge, _mode),
    do: %{style | prefix: SafeText.chrome(:run_consensus_judge)}

  defp cue(style, :run_ultra, _mode), do: %{style | prefix: SafeText.chrome(:run_ultra)}
  defp cue(style, :agent_lane_1, _mode), do: %{style | prefix: SafeText.chrome(:agent_lane_1)}
  defp cue(style, :agent_lane_2, _mode), do: %{style | prefix: SafeText.chrome(:agent_lane_2)}
  defp cue(style, :agent_lane_3, _mode), do: %{style | prefix: SafeText.chrome(:agent_lane_3)}
  defp cue(style, :agent_lane_4, _mode), do: %{style | prefix: SafeText.chrome(:agent_lane_4)}
  defp cue(style, :agent_lane_5, _mode), do: %{style | prefix: SafeText.chrome(:agent_lane_5)}
  defp cue(style, _role, _mode), do: style

  def run_kind(:assistant), do: {SafeText.chrome(:run_assistant), :run_assistant}
  def run_kind(:goal), do: {SafeText.chrome(:run_goal), :run_goal}
  def run_kind(:swarm), do: {SafeText.chrome(:run_swarm), :run_swarm}
  def run_kind(:workflow), do: {SafeText.chrome(:run_workflow), :run_workflow}
  def run_kind(:research), do: {SafeText.chrome(:run_research), :run_research}

  def run_kind(:consensus_judge),
    do: {SafeText.chrome(:run_consensus_judge), :run_consensus_judge}

  def run_kind(:ultra), do: {SafeText.chrome(:run_ultra), :run_ultra}

  @doc """
  The catalogue glyph token that marks a run kind.

  `run_kind/1` keeps the single-letter identity ("S", "G", "W") that rides along
  as a style prefix cue and is what a colourless terminal falls back to; this is
  the design's kind mark, drawn as row text. Every token below is registered in
  `UI.Projector.Support` ASCII glyph table, so a caller resolves it through
  `Support.glyph/2` and gets the ASCII twin when the terminal cannot draw it.
  `:ultra` has no mark of its own in the catalogue and borrows the effort dial:
  ultra is the maximum-effort kind.
  """
  @spec run_mark(run_kind()) :: SafeText.chrome()
  def run_mark(:assistant), do: :assistant_mark
  def run_mark(:goal), do: :glyph_selected
  def run_mark(:swarm), do: :kind_swarm_mark
  def run_mark(:workflow), do: :glyph_workflows
  def run_mark(:research), do: :search_mark
  def run_mark(:consensus_judge), do: :kind_consensus_mark
  def run_mark(:ultra), do: :effort_mark

  def agent_lane(1), do: {SafeText.chrome(:agent_lane_1), :agent_lane_1}
  def agent_lane(2), do: {SafeText.chrome(:agent_lane_2), :agent_lane_2}
  def agent_lane(3), do: {SafeText.chrome(:agent_lane_3), :agent_lane_3}
  def agent_lane(4), do: {SafeText.chrome(:agent_lane_4), :agent_lane_4}
  def agent_lane(5), do: {SafeText.chrome(:agent_lane_5), :agent_lane_5}

  @spec file_type(String.t()) :: Style.role()
  def file_type("ts"), do: :ext_ts
  def file_type("tsx"), do: :ext_ts
  def file_type("ex"), do: :ext_ex
  def file_type("exs"), do: :ext_ex
  def file_type("js"), do: :ext_js
  def file_type("jsx"), do: :ext_js
  def file_type("md"), do: :ext_md
  def file_type("mdx"), do: :ext_md
  def file_type("css"), do: :ext_css
  def file_type("scss"), do: :ext_css
  def file_type("json"), do: :ext_json
  def file_type("html"), do: :ext_html
  def file_type("heex"), do: :ext_html
  def file_type("py"), do: :ext_py
  def file_type("rs"), do: :ext_rs
  def file_type("go"), do: :ext_go
  def file_type(_), do: :text_muted

  def status(:connecting), do: {SafeText.chrome(:status_connecting), :info}
  def status(:empty), do: {SafeText.chrome(:status_empty), :text_muted}
  def status(:loading), do: {SafeText.chrome(:status_loading), :info}
  def status(:running), do: {SafeText.chrome(:status_running), :accent}
  def status(:streaming), do: {SafeText.chrome(:status_streaming), :accent}
  def status(:queued), do: {SafeText.chrome(:status_queued), :warning}
  def status(:waiting_question), do: {SafeText.chrome(:status_waiting_question), :warning}
  def status(:waiting_approval), do: {SafeText.chrome(:status_waiting_approval), :warning}
  def status(:paused), do: {SafeText.chrome(:status_paused), :warning}
  def status(:retrying), do: {SafeText.chrome(:status_retrying), :warning}
  def status(:done), do: {SafeText.chrome(:status_done), :success}
  def status(:failed), do: {SafeText.chrome(:status_failed), :error}
  def status(:stopped), do: {SafeText.chrome(:status_stopped), :text_muted}
  def status(:interrupted), do: {SafeText.chrome(:status_interrupted), :warning}
  def status(:stale), do: {SafeText.chrome(:status_stale), :stale}
  def status(:resyncing), do: {SafeText.chrome(:status_resyncing), :info}
  def status(:disconnected), do: {SafeText.chrome(:status_disconnected), :error}
  def status(:superseded), do: {SafeText.chrome(:status_superseded), :text_muted}
  def status(:mutation_pending), do: {SafeText.chrome(:status_mutation_pending), :info}
end
