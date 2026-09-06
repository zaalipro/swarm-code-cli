defmodule SwarmCodeCLI.UI.Paint.StyleTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Capabilities, SafeText, Theme}
  alias SwarmCodeCLI.UI.Scene.{Color, Style}
  alias SwarmCodeCLI.UI.Paint.Style, as: PaintStyle

  @base %{foreground: {:ansi, :green}, background: {:ansi, :black}, modifiers: [:italic]}

  test "plain inherits; roles precede explicit values; modifier order is canonical" do
    assert {:ok, @base} = PaintStyle.resolve(%Style{}, @base, :truecolor)

    style = %Style{
      role: :heading,
      foreground: %Color{role: :default, value: {:rgb, 1, 2, 3}},
      modifiers: [:dim, :italic]
    }

    assert {:ok,
            %{
              foreground: {:rgb, 1, 2, 3},
              background: {:ansi, :black},
              modifiers: [:bold, :dim, :italic]
            }} = PaintStyle.resolve(style, @base, :truecolor)

    assert {:ok, %{foreground: nil}} =
             PaintStyle.resolve(%Style{foreground: %Color{role: :default}}, @base, :truecolor)
  end

  test "every role resolves through Theme in each supported mode" do
    for mode <- [:truecolor, :ansi256, :ansi16, :monochrome], role <- Style.roles() -- [:plain] do
      theme =
        Theme.style(role, %Capabilities{
          color_mode: mode,
          size: %SwarmCodeCLI.UI.Size{columns: 80, rows: 24}
        })

      assert {:ok, entry} =
               PaintStyle.resolve(
                 %Style{role: role},
                 %{foreground: nil, background: nil, modifiers: []},
                 mode
               )

      assert entry.foreground == if(theme.foreground, do: theme.foreground.value)
      assert entry.background == if(theme.background, do: theme.background.value)
      assert Enum.sort(entry.modifiers) == Enum.sort(theme.modifiers)
    end
  end

  test "representable colors remain exact and unsupported colors reject" do
    for {value, supported} <- [
          {{:rgb, 1, 2, 3}, [:truecolor]},
          {{:indexed, 42}, [:truecolor, :ansi256]},
          {{:ansi, :red}, [:truecolor, :ansi256, :ansi16]}
        ],
        mode <- [:truecolor, :ansi256, :ansi16, :monochrome] do
      result =
        PaintStyle.resolve(
          %Style{foreground: %Color{role: :default, value: value}},
          %{foreground: nil, background: nil, modifiers: []},
          mode
        )

      if mode in supported,
        do: assert(match?({:ok, %{foreground: ^value}}, result)),
        else: assert(result == {:error, :invalid_style})
    end
  end

  test "closed style and palette validation; prefixes never enter palette" do
    assert {:ok, @base} =
             PaintStyle.resolve(%Style{prefix: SafeText.chrome(:focus_marker)}, @base, :truecolor)

    for bad <- [
          %Style{role: :bad},
          %Style{modifiers: [:blink]},
          %Style{prefix: "raw"},
          %Style{cues: [:bad]},
          Map.put(%Style{}, :extra, true),
          nil
        ] do
      assert {:error, :invalid_style} = PaintStyle.resolve(bad, @base, :truecolor)
    end

    for bad <- [
          Map.put(@base, :extra, 1),
          %{@base | modifiers: [:italic, :italic]},
          %{@base | foreground: {:rgb, -1, 2, 3}}
        ] do
      assert {:error, :invalid_style} = PaintStyle.resolve(%Style{}, bad, :truecolor)
    end
  end
end
