defmodule SwarmCodeCLI.UI.Settings.Editors.Color do
  @moduledoc """
  pass74 (spec §2.14 `terminal.accent`, §3.7.8, §4.5): the colour editor.
  Typing a hex colour (`#FF6A1A`, `FF6A1A`, `#F60`, any case); Enter stores
  it upper-case as `#RRGGBB`; an empty text stores nothing (Carbon's own
  accent). While typing, the lines under the row show the 256- and 16-colour
  twins the terminal would draw and the WCAG contrast on the page colour of
  the current mode: below 4.5:1 warns and never blocks.

  The swatch `██` is drawn in the accent role when the colour is the one this
  launch uses; any other colour applies at the next launch, so its swatch is
  the ASCII twin `[#RRGGBB]` (a terminal row can only be painted with the
  palette of the running session).
  """

  @behaviour SwarmCodeCLI.UI.Settings.Editor

  alias SwarmCodeCLI.Release.TerminalPreferences
  alias SwarmCodeCLI.UI.Theme

  @max_bytes 16
  @carbon 0xFF6A1A

  @impl true
  def init(row, opts, ctx) do
    text =
      case Map.get(opts || %{}, :value) || current(row, ctx) do
        value when is_binary(value) -> value
        _ -> ""
      end

    {:ok, %{text: text, original: text, message: nil}}
  end

  @impl true
  def handle(state, {:text, text}, _ctx) do
    text = state.text <> String.replace(text, ~r/[\r\n\s]/u, "")
    {:cont, %{state | text: binary_part(text, 0, min(byte_size(text), @max_bytes)), message: nil}}
  end

  def handle(state, {:paste, text}, ctx), do: handle(%{state | text: ""}, {:text, text}, ctx)

  def handle(state, {:key, :backspace}, _ctx),
    do: {:cont, %{state | text: String.slice(state.text, 0..-2//1), message: nil}}

  def handle(state, {:key, {:ctrl, "u"}}, _ctx), do: {:cont, %{state | text: "", message: nil}}
  def handle(state, {:key, :escape}, _ctx), do: {:cancel, state}

  def handle(state, {:key, :enter}, _ctx) do
    case String.trim(state.text) do
      "" ->
        {:commit, nil, state}

      text ->
        case TerminalPreferences.parse_accent(text) do
          {:ok, hex, _rgb} -> {:commit, hex, %{state | text: hex}}
          :error -> {:cont, %{state | message: "a colour such as #FF6A1A"}}
        end
    end
  end

  def handle(state, _event, _ctx), do: {:cont, state}

  @impl true
  def display(state, ctx) do
    value = [{state.text, :code}]

    lines =
      case TerminalPreferences.parse_accent(state.text) do
        {:ok, hex, rgb} -> facts(hex, rgb, ctx)
        :error when state.text == "" -> [[{"empty: Carbon's #FF6A1A", :text_faint}]]
        :error -> []
      end

    lines =
      if state.message, do: [[{"✗ " <> state.message, :error}] | lines], else: lines

    %{
      value: value,
      lines: lines,
      popover: nil,
      context: :settings_edit,
      footer: [
        {"Enter", "keep"},
        {"Esc", "put #{shown(state.original)} back"},
        {"Ctrl-U", "clear"}
      ]
    }
  end

  @doc """
  The value column of a colour row (§4.5): a swatch and the hex, or the
  Carbon default when nothing is stored.
  """
  @spec value_segments(String.t() | nil, map() | nil) :: [{String.t(), atom()}]
  def value_segments(value, ctx) do
    case TerminalPreferences.parse_accent(value) do
      {:ok, hex, rgb} -> swatch(hex, rgb, ctx) ++ [{" " <> hex, :text_primary}]
      :error -> swatch("#FF6A1A", {255, 106, 26}, ctx) ++ [{" #FF6A1A · Carbon", :text_muted}]
    end
  end

  @doc """
  The facts lines under a colour: the twins and the contrast on the page.
  """
  @spec facts(String.t(), {byte(), byte(), byte()}, map() | nil) :: [[{String.t(), atom()}]]
  def facts(hex, rgb, ctx) do
    twins = Theme.accent_twins(rgb)
    int = to_int(rgb)
    ratio = Theme.contrast(int, Theme.page_color(mode(ctx)))
    words = :erlang.float_to_binary(ratio, decimals: 1)

    contrast =
      if ratio >= 4.5,
        do: [{"✓ ", :success}, {"contrast #{words} : 1 on the page", :text_muted}],
        else: [{"! ", :warning}, {"#{words} : 1 · hard to read on the page", :warning}]

    next =
      if launched?(int),
        do: [],
        else: [[{"applies at the next launch", :info}]]

    [
      swatch(hex, rgb, ctx) ++
        [
          {" #{hex}  ", :text_primary},
          {"256: #{twins.ansi256} · 16: #{ansi_words(twins.ansi16)}", :text_faint}
        ],
      contrast
    ] ++ next
  end

  defp swatch(hex, rgb, ctx) do
    ascii? = ctx |> Kernel.||(%{}) |> Map.get(:caps) |> Kernel.||(%{}) |> Map.get(:ascii?)

    cond do
      ascii? == true -> [{"[#{hex}]", :text_muted}]
      launched?(to_int(rgb)) -> [{"██", :accent}]
      true -> [{"[#{hex}]", :text_muted}]
    end
  end

  defp launched?(int), do: int == (Theme.accent() || @carbon)

  defp ansi_words(atom), do: atom |> Atom.to_string() |> String.replace("_", " ")

  defp to_int({r, g, b}), do: r * 65_536 + g * 256 + b

  defp mode(ctx) do
    view = ctx |> Kernel.||(%{}) |> Map.get(:state_view) |> Kernel.||(%{})
    if Map.get(view, :theme_mode) == :light, do: :light, else: :dark
  end

  defp current(row, ctx) do
    prefs = ctx |> Kernel.||(%{}) |> Map.get(:prefs) |> Kernel.||(%{})

    case Map.get(prefs, "accent") do
      value when is_binary(value) -> value
      _ -> row |> Kernel.||(%{}) |> Map.get(:target)
    end
  end

  defp shown(""), do: "Carbon's"
  defp shown(text), do: text
end
