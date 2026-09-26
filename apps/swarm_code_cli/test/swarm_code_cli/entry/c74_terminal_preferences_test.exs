defmodule SwarmCodeCLI.Release.C74TerminalPreferencesTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Release.TerminalPreferences, as: TP
  alias SwarmCodeCLI.UI.Capabilities

  defp cli(values), do: %{values: values, status: :ok}

  describe "theme" do
    # env × cli.json × desktop mode → theme, theme_env
    for {env, file, desktop, theme, theme_env} <- [
          {%{}, %{}, nil, :dark, nil},
          {%{}, %{}, "light", :light, nil},
          {%{}, %{"theme" => "dark"}, "light", :dark, nil},
          {%{}, %{"theme" => "light"}, "dark", :light, nil},
          {%{"SWARM_THEME" => "light"}, %{"theme" => "dark"}, "dark", :light, :light},
          {%{"SWARM_THEME" => " DARK "}, %{"theme" => "light"}, "light", :dark, :dark},
          {%{"SWARM_THEME" => "blue"}, %{"theme" => "light"}, "dark", :light, nil},
          {%{"SWARM_THEME" => ""}, %{}, "light", :light, nil}
        ] do
      test "#{inspect(env)} #{inspect(file)} desktop=#{inspect(desktop)}" do
        result =
          TP.launch(
            unquote(Macro.escape(env)),
            cli(unquote(Macro.escape(file))),
            unquote(desktop)
          )

        assert result.theme == unquote(theme)
        assert result.theme_env == unquote(theme_env)
      end
    end

    test "an unknown SWARM_THEME is an ignored layer, never the winner" do
      result = TP.launch(%{"SWARM_THEME" => "blue"}, cli(%{}), "light")

      assert %{var: "SWARM_THEME", value: "blue", ignored: true, note: _} =
               result.env_overrides["terminal.theme"]
    end

    test "a valid SWARM_THEME is an env override" do
      result = TP.launch(%{"SWARM_THEME" => "dark"}, cli(%{}), nil)
      assert result.env_overrides["terminal.theme"] == %{var: "SWARM_THEME", value: "dark"}
    end
  end

  describe "colours" do
    for {env, file, mode} <- [
          {%{"NO_COLOR" => "1", "COLORTERM" => "truecolor"}, %{}, :monochrome},
          {%{"NO_COLOR" => "", "COLORTERM" => "truecolor"}, %{}, :truecolor},
          {%{"NO_COLOR" => "", "TERM" => "xterm-256color"}, %{}, :ansi256},
          {%{"TERM" => "xterm"}, %{}, :ansi16},
          {%{"COLORTERM" => "24bit"}, %{"colors" => "auto"}, :truecolor},
          {%{"COLORTERM" => "truecolor"}, %{"colors" => "256"}, :ansi256},
          {%{"COLORTERM" => "truecolor"}, %{"colors" => "16"}, :ansi16},
          {%{"COLORTERM" => "truecolor"}, %{"colors" => "none"}, :monochrome},
          {%{"TERM" => "xterm"}, %{"colors" => "truecolor"}, :truecolor},
          {%{"NO_COLOR" => "yes"}, %{"colors" => "truecolor"}, :monochrome}
        ] do
      test "#{inspect(env)} #{inspect(file)} → #{mode}" do
        result = TP.launch(unquote(Macro.escape(env)), cli(unquote(Macro.escape(file))), nil)
        assert result.color_mode == unquote(mode)
      end
    end

    test "NO_COLOR= (empty) is colour, D21, and no override" do
      result = TP.launch(%{"NO_COLOR" => ""}, cli(%{}), nil)
      refute Map.has_key?(result.env_overrides, "terminal.colors")
    end

    test "NO_COLOR non-empty names the override" do
      result = TP.launch(%{"NO_COLOR" => "1"}, cli(%{}), nil)
      assert result.env_overrides["terminal.colors"] == %{var: "NO_COLOR", value: "1"}
    end
  end

  describe "glyphs" do
    @rich_env %{"COLORTERM" => "truecolor", "TERM" => "xterm-ghostty"}

    test "auto probes the terminal" do
      assert %{ascii?: false, glyph_tier: :rich} = TP.launch(@rich_env, cli(%{}), nil)
      assert %{glyph_tier: :measured} = TP.launch(%{"TERM" => "xterm"}, cli(%{}), nil)
    end

    test "SWARM_ASCII wins over the file" do
      result =
        TP.launch(Map.put(@rich_env, "SWARM_ASCII", "yes"), cli(%{"glyphs" => "rich"}), nil)

      assert %{ascii?: true, glyph_tier: :measured} = result
      assert result.env_overrides["terminal.glyphs"].var == "SWARM_ASCII"
    end

    test "SWARM_ASCII=0 is no override" do
      result = TP.launch(Map.put(@rich_env, "SWARM_ASCII", "0"), cli(%{}), nil)
      assert %{ascii?: false, glyph_tier: :rich} = result
      refute Map.has_key?(result.env_overrides, "terminal.glyphs")
    end

    test "the file forces a tier" do
      assert %{ascii?: true} = TP.launch(@rich_env, cli(%{"glyphs" => "ascii"}), nil)

      assert %{glyph_tier: :measured, ascii?: false} =
               TP.launch(@rich_env, cli(%{"glyphs" => "measured"}), nil)

      assert %{glyph_tier: :rich} =
               TP.launch(%{"TERM" => "xterm"}, cli(%{"glyphs" => "rich"}), nil)
    end

    test "forcing rich under wide ambiguous width warns" do
      result = TP.launch(@rich_env, cli(%{"glyphs" => "rich", "ambiguous_width" => "wide"}), nil)
      assert result.ambiguous_width == :wide
      assert result.glyph_tier == :rich
      assert [_] = result.warnings
    end

    test "Capabilities.glyph_tier/5" do
      assert Capabilities.glyph_tier(:truecolor, :narrow, true, "xterm-kitty", "rich") ==
               :measured

      assert Capabilities.glyph_tier(:ansi16, :wide, false, nil, "rich") == :rich

      assert Capabilities.glyph_tier(:truecolor, :narrow, false, "xterm-kitty", "measured") ==
               :measured

      assert Capabilities.glyph_tier(:truecolor, :narrow, false, "xterm-kitty", "auto") == :rich
    end
  end

  describe "mouse, keymap, companion" do
    for {env, file, mouse?} <- [
          {%{}, %{}, true},
          {%{}, %{"mouse" => false}, false},
          {%{"SWARM_MOUSE" => "1"}, %{"mouse" => false}, true},
          {%{"SWARM_MOUSE" => "off"}, %{"mouse" => true}, false},
          {%{"SWARM_MOUSE" => "maybe"}, %{"mouse" => false}, false}
        ] do
      test "mouse #{inspect(env)} #{inspect(file)}" do
        result = TP.launch(unquote(Macro.escape(env)), cli(unquote(Macro.escape(file))), nil)
        assert result.mouse? == unquote(mouse?)
      end
    end

    test "SWARM_KEYMAP=vim wins; emacs is ignored (the file's value is used)" do
      assert %{keymap: :vim} = TP.launch(%{"SWARM_KEYMAP" => "vim"}, cli(%{}), nil)
      assert %{keymap: :vim} = TP.launch(%{}, cli(%{"keymap" => "vim"}), nil)

      result = TP.launch(%{"SWARM_KEYMAP" => "emacs"}, cli(%{"keymap" => "standard"}), nil)
      assert result.keymap == :default
      assert %{ignored: true, var: "SWARM_KEYMAP"} = result.env_overrides["terminal.keymap"]

      result = TP.launch(%{"SWARM_KEYMAP" => "emacs"}, cli(%{"keymap" => "vim"}), nil)
      assert result.keymap == :vim
    end

    test "SWARM_COMPANION=0 wins over the file; other values do not" do
      assert %{companion?: false} = TP.launch(%{"SWARM_COMPANION" => "0"}, cli(%{}), nil)
      assert %{companion?: false} = TP.launch(%{}, cli(%{"companion" => false}), nil)

      assert %{companion?: false} =
               TP.launch(%{"SWARM_COMPANION" => "1"}, cli(%{"companion" => false}), nil)

      assert %{companion?: true} = TP.launch(%{}, cli(%{}), nil)
    end
  end

  describe "startup conversation" do
    test "the file, then SWARM_CONVERSATION, then flags" do
      assert %{startup_conversation: :latest} = TP.launch(%{}, cli(%{}), nil)

      assert %{startup_conversation: :ask} =
               TP.launch(%{}, cli(%{"startup_conversation" => "ask"}), nil)

      result =
        TP.launch(%{"SWARM_CONVERSATION" => "new"}, cli(%{"startup_conversation" => "ask"}), nil)

      assert result.startup_conversation == :new
      assert result.env_overrides["terminal.startup_conversation"].var == "SWARM_CONVERSATION"

      result = TP.launch(%{}, cli(%{"startup_conversation" => "new"}), nil, %{"--continue" => ""})
      assert result.startup_conversation == :latest
      assert result.flag_overrides["terminal.startup_conversation"].flag == "--continue"
    end

    test "a conversation id is an ignored layer" do
      id = "8d0f1c2e-1234-4abc-9def-0123456789ab"
      result = TP.launch(%{"SWARM_CONVERSATION" => id}, cli(%{}), nil)
      assert result.startup_conversation == :latest

      assert %{ignored: true, note: "this launch opened one named conversation"} =
               result.env_overrides["terminal.startup_conversation"]

      result = TP.launch(%{}, cli(%{}), nil, %{"--resume" => id})
      assert %{ignored: true} = result.flag_overrides["terminal.startup_conversation"]
    end
  end

  describe "values the file carries" do
    test "reduced motion, ambiguous width, accent, prefs" do
      values = %{"reduced_motion" => true, "ambiguous_width" => "wide", "accent" => "#2DD4BF"}
      result = TP.launch(%{}, cli(values), nil)
      assert result.reduced_motion?
      assert result.ambiguous_width == :wide
      assert result.accent == {0x2D, 0xD4, 0xBF}
      assert result.prefs == values
    end

    test "no file" do
      result = TP.launch(%{}, nil, nil)
      assert result.prefs == %{}
      assert result.accent == nil
      assert result.env_overrides == %{}
    end

    test "the editor's environment is the layer under the file" do
      result = TP.launch(%{"EDITOR" => "nano", "VISUAL" => "hx"}, cli(%{}), nil)
      assert result.env_overrides["terminal.editor"] == %{var: "VISUAL", value: "hx"}
    end

    test "parse_accent" do
      assert {:ok, "#FF6A1A", {255, 106, 26}} = TP.parse_accent("ff6a1a")
      assert {:ok, "#AABBCC", _} = TP.parse_accent("#abc")
      assert {:ok, "#2DD4BF", _} = TP.parse_accent(" #2dd4bf ")
      assert :error = TP.parse_accent("#12345")
      assert :error = TP.parse_accent("orange")
      assert :error = TP.parse_accent(nil)
    end
  end
end
