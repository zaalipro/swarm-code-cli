defmodule SwarmCodeCLI.UI.Home.OrbitKeymapTest do
  @moduledoc """
  orbit U8: Home's keys. Each row of `HomeBindings` resolves to its action in the
  contexts it names, the shell's grammar does not leak into Home, and the
  composer and the list type where the map binds letters.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.OrbitHelpers, only: [start: 1]

  alias SwarmCodeCLI.UI.{Home, Input, Keymap}
  alias SwarmCodeCLI.UI.Keymap.{Bindings, Context, Docs, HomeBindings}

  defp home(focus) do
    {state, _} = start([])
    %{state | home: %Home{state.home | focus: focus}}
  end

  defp shell_state do
    {state, _} = start(home?: false)
    %{state | focus: "composer"}
  end

  defp key(state, code, mods \\ []),
    do: Keymap.resolve(Input.key(:press, code, mods), state, %{})

  defp text(state, text, mods \\ []),
    do: Keymap.resolve(Input.text_fragment(:press, text, mods), state, %{})

  @foci [:composer, :list, :map]

  describe "contexts" do
    test "Home's focus picks the context" do
      assert Context.of(home(:composer)) == :home_composer
      assert Context.of(home(:list)) == :home_list
      assert Context.of(home(:map)) == :home_map
    end

    test "the three are real contexts, titled in the docs, and the composer and list type" do
      assert Bindings.home_contexts() == [:home_composer, :home_list, :home_map]
      assert Enum.all?(Bindings.home_contexts(), &(&1 in Bindings.contexts()))
      assert (Bindings.typing_contexts() -- [:home_composer, :home_list]) |> length() > 0
      assert :home_composer in Bindings.typing_contexts()
      assert :home_list in Bindings.typing_contexts()
      refute :home_map in Bindings.typing_contexts()
      assert Docs.title(:home_composer) == "Home: the composer"
      assert Docs.title(:home_list) == "Home: the resume list and its search"
      assert Docs.title(:home_map) == "Home: the project map"
      assert Docs.group_title(:home) == "Home"
    end
  end

  describe "the keys of every context" do
    for focus <- @foci do
      test "Enter, Esc, Tab, Shift-Tab, up and down in #{focus}" do
        state = home(unquote(focus))
        assert key(state, :enter) == {:ok, {:home, :enter}}
        assert key(state, :escape) == {:ok, {:home, :escape}}
        assert key(state, :tab) == {:ok, {:home, :focus_next}}
        assert key(state, :tab, [:shift]) == {:ok, {:home, :focus_previous}}
        assert key(state, :back_tab) == {:ok, {:home, :focus_previous}}
        assert key(state, :up) == {:ok, {:home, :up}}
        assert key(state, :down) == {:ok, {:home, :down}}
      end

      test "Alt-1 and Alt-9 open rows 1 and 9 in #{focus}" do
        state = home(unquote(focus))
        assert text(state, "1", [:alt]) == {:ok, {:home, {:open_row, 1}}}
        assert text(state, "9", [:alt]) == {:ok, {:home, {:open_row, 9}}}
        assert text(state, "5", [:alt]) == {:ok, {:home, {:open_row, 5}}}
      end

      test "Ctrl-N and Ctrl-C are Home's own in #{focus}" do
        state = home(unquote(focus))
        assert text(state, "n", [:control]) == {:ok, {:home, :next_need}}
        assert text(state, "c", [:control]) == {:ok, {:home, :interrupt}}
      end

      test "F1, Ctrl-P, Ctrl-G and F2 are the shell's in #{focus}" do
        state = home(unquote(focus))
        shell = shell_state()

        assert key(state, {:function, 1}) == key(shell, {:function, 1})
        assert {:ok, _} = key(state, {:function, 1})
        assert text(state, "p", [:control]) == text(shell, "p", [:control])
        assert {:ok, _} = text(state, "p", [:control])
        assert text(state, "g", [:control]) == text(shell, "g", [:control])
        assert {:ok, _} = text(state, "g", [:control])
        assert key(state, {:function, 2}) == key(shell, {:function, 2})
        assert {:ok, {:settings_open, nil}} = key(state, {:function, 2})
      end

      test "Ctrl-B and Ctrl-F do nothing on Home in #{focus}" do
        state = home(unquote(focus))
        assert text(state, "b", [:control]) == :ignore
        assert text(state, "f", [:control]) == :ignore
        assert text(state, "t", [:control]) == :ignore
        assert text(state, "l", [:control]) in [:ignore, {:ok, :redraw_screen}]
      end
    end

    test "left and right move the orbit on the map and the caret elsewhere" do
      map = home(:map)
      assert key(map, :left) == {:ok, {:home, :left}}
      assert key(map, :right) == {:ok, {:home, :right}}

      assert {:ok, {:editor, {"orbit-epoch", :home}, {:move, :left}}} =
               key(home(:composer), :left)

      assert {:ok, {:field_editor, {:home, :filter}, {:move, :right}}} =
               key(home(:list), :right)
    end

    test "y copies on the map and types in the composer and the list" do
      assert text(home(:map), "y") == {:ok, {:home, :copy}}

      assert text(home(:composer), "y") ==
               {:ok, {:editor, {"orbit-epoch", :home}, {:insert, "y"}}}

      assert text(home(:list), "y") == {:ok, {:field_editor, {:home, :filter}, {:insert, "y"}}}
    end

    test "a question mark types in the composer and the list, and opens help on the map" do
      assert text(home(:composer), "?") ==
               {:ok, {:editor, {"orbit-epoch", :home}, {:insert, "?"}}}

      assert text(home(:list), "?") == {:ok, {:field_editor, {:home, :filter}, {:insert, "?"}}}
      assert text(home(:map), "?") == {:ok, {:open_layer, :help}}
    end

    test "digits and letters type in the composer and the list, and are not bound on the map" do
      for char <- ["a", "q", "3", "n", "j"] do
        assert {:ok, {:editor, {"orbit-epoch", :home}, {:insert, ^char}}} =
                 text(home(:composer), char)

        assert {:ok, {:field_editor, {:home, :filter}, {:insert, ^char}}} =
                 text(home(:list), char)

        assert text(home(:map), char) == :ignore
      end
    end

    test "backspace edits the draft or the filter" do
      assert key(home(:composer), :backspace) ==
               {:ok, {:editor, {"orbit-epoch", :home}, :delete_backward}}

      assert key(home(:list), :backspace) ==
               {:ok, {:field_editor, {:home, :filter}, :delete_backward}}

      assert key(home(:map), :backspace) == :ignore
    end

    test "the composer keeps its editing keys and its newline" do
      state = home(:composer)

      assert {:ok, {:editor, {"orbit-epoch", :home}, {:move, :line_start}}} =
               text(state, "a", [:control])

      assert {:ok, {:editor, {"orbit-epoch", :home}, {:move, :line_end}}} =
               text(state, "e", [:control])

      assert {:ok, {:editor, {"orbit-epoch", :home}, _}} = text(state, "w", [:control])
    end
  end

  describe "outside Home" do
    test "Alt-O opens Home from the composer, the transcript and the inspector" do
      for focus <- ["composer", "main", "inspector"] do
        state = %{shell_state() | focus: focus}
        assert text(state, "o", [:alt]) == {:ok, :open_home}
      end
    end

    test "Alt-1 stays the first run tab" do
      assert text(shell_state(), "1", [:alt]) == {:ok, {:run_tab, 1}}
    end

    test "Alt-O does nothing on Home itself (it is already open)" do
      for focus <- @foci, do: assert(text(home(focus), "o", [:alt]) == :ignore)
    end

    test "/home is a client command, typed or in the palette" do
      assert Keymap.local_command("/home") == :home
      assert Keymap.local_command("  /home  ") == :home
      assert Keymap.local_command("/homework") == nil

      size = %SwarmCodeCLI.UI.Size{columns: 70, rows: 30}

      state = %SwarmCodeCLI.UI.State{
        size: size,
        capabilities: %SwarmCodeCLI.UI.Capabilities{size: size},
        destination: {:conversation, "c"},
        focus: "composer"
      }

      {:ok, editor} = SwarmCodeCLI.UI.Editor.apply(SwarmCodeCLI.UI.Editor.new(), {:paste, "/ho"})
      draft = SwarmCodeCLI.UI.Drafts.fetch(state.drafts, {"c", :main})

      state = %{
        state
        | drafts: SwarmCodeCLI.UI.Drafts.put(state.drafts, %{draft | editor: editor})
      }

      assert [%{name: "home"} | _] = SwarmCodeCLI.UI.SlashPalette.entries(state)
    end
  end

  describe "the status row's hints follow the table" do
    test "every hint names bindings that reach its context" do
      for context <- Bindings.home_contexts(), {ids, words} <- HomeBindings.hints(context) do
        assert is_binary(words)
        ids = if ids == :digits, do: HomeBindings.open_row_ids(), else: ids

        for id <- ids do
          binding = Bindings.all() |> Enum.find(&(&1.id == id))
          assert binding, "#{id} is not a binding"

          assert Bindings.key_in_context(binding, context) != nil,
                 "#{id} has no key in #{context}"
        end
      end
    end
  end
end
