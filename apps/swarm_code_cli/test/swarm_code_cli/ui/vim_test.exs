defmodule SwarmCodeCLI.UI.VimTest do
  @moduledoc """
  The vim keymap driven the way a terminal drives it: real inputs through
  `Keymap.resolve/3`, every resulting action through `Reducer.update/2`, and
  assertions on the draft's text, caret and mode afterwards. A test here that
  only looked at the action tuple would not know whether `dw` deleted a word.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Capabilities, Drafts, Editor, Init, Input, Keymap, Reducer, Size, State}
  alias SwarmCodeCLI.UI.Keymap.Context

  @size %Size{columns: 120, rows: 40}
  @send {:dispatch, :send, "hello", :main, []}
  @table %{"send" => {:intent, @send}}

  describe "entering and leaving the modes" do
    test "i from the transcript focuses the composer in INSERT; Esc walks back out" do
      state = boot()
      assert state.focus == "main"

      state = press(state, "i")
      assert state.focus == "composer"
      assert state.vim.mode == :insert
      assert Context.of(state) == :composer

      state = press(state, {:key, :escape})
      assert state.focus == "composer"
      assert state.vim.mode == :normal
      assert Context.of(state) == :composer_normal

      state = press(state, {:key, :escape})
      assert state.focus == "main"
      assert Context.of(state) == :main
    end

    test "Tab into the composer keeps the mode; i from the transcript resets it to INSERT" do
      state = boot() |> press("i") |> press({:key, :escape})
      assert state.vim.mode == :normal

      state = press(state, {:key, :escape}) |> press({:key, :tab})
      assert state.focus == "composer"
      assert state.vim.mode == :normal

      state = press(state, {:key, :escape}) |> press("i")
      assert state.focus == "composer"
      assert state.vim.mode == :insert
    end

    test "Esc from INSERT steps the caret one left, except at the start of a line" do
      state = boot() |> press("i") |> type("hello")
      assert cursor(state) == 5

      state = press(state, {:key, :escape})
      assert state.vim.mode == :normal
      assert cursor(state) == 4

      state = state |> press("0") |> press("i") |> press({:key, :escape})
      assert cursor(state) == 0
    end

    test "Esc in NORMAL cancels a pending operator and its count before it leaves" do
      state = boot() |> press("i") |> type("hello") |> press({:key, :escape})
      state = state |> press("2") |> press("d")
      assert state.vim == %SwarmCodeCLI.UI.Vim{mode: :normal, pending: "d", count: 2}

      state = press(state, {:key, :escape})
      assert state.vim == %SwarmCodeCLI.UI.Vim{mode: :normal}
      assert state.focus == "composer"
      assert text(state) == "hello"
    end

    test "with the default keymap i only focuses the composer and letters type" do
      state = boot(:default) |> press("i")
      assert state.focus == "composer"
      assert Context.of(state) == :composer

      state = type(state, "x")
      assert text(state) == "x"

      state = press(state, {:key, :escape})
      assert state.focus == "main"
    end

    test "an unknown NORMAL key is ignored and never types" do
      state = boot() |> press("i") |> type("hello") |> press({:key, :escape})
      assert :ignore = Keymap.resolve(Input.text_fragment(:press, "z", []), state, @table)
      assert text(press(state, "z")) == "hello"
    end
  end

  describe "operators, motions and the register" do
    test "i hello world Esc 0 dw p u" do
      state = boot() |> press("i") |> type("hello world") |> press({:key, :escape})
      assert cursor(state) == 10

      state = press(state, "0")
      assert cursor(state) == 0

      state = press(state, "d")
      assert state.vim.pending == "d"

      state = press(state, "w")
      assert text(state) == "world"
      assert state.vim.pending == nil
      assert Editor.register(draft(state)) == {"hello ", :charwise}

      state = press(state, "p")
      assert text(state) == "whello orld"

      state = press(state, "u")
      assert text(state) == "world"
    end

    test "a count multiplies a motion: 3j in a four-line draft" do
      state = boot() |> press("i") |> lines(["a", "b", "c", "d"]) |> press({:key, :escape})

      state = state |> press("g") |> press("g")
      assert cursor(state) == 0

      state = state |> press("3") |> press("j")
      assert cursor(state) == 6
      assert state.vim.count == nil
    end

    test "d3w and 3dw both delete three words" do
      state = boot() |> press("i") |> type("one two three four five") |> press({:key, :escape})
      state = state |> press("0") |> press("d") |> press("3") |> press("w")
      assert text(state) == "four five"

      state = press(state, "u")
      assert text(state) == "one two three four five"

      state = state |> press("3") |> press("d") |> press("w")
      assert text(state) == "four five"
    end

    test "cc clears the line and enters INSERT" do
      state = boot() |> press("i") |> type("hello") |> press({:key, :escape})
      state = state |> press("c") |> press("c")
      assert text(state) == ""
      assert state.vim.mode == :insert

      state = type(state, "bye")
      assert text(state) == "bye"
    end

    test "A appends at the end of the line" do
      state = boot() |> press("i") |> type("hello") |> press({:key, :escape})
      assert cursor(state) == 4

      state = state |> press("A") |> type("!")
      assert text(state) == "hello!"
      assert state.vim.mode == :insert
    end

    test "o opens a line below and O a line above" do
      state = boot() |> press("i") |> type("hello") |> press({:key, :escape})

      state = state |> press("o") |> type("x")
      assert text(state) == "hello\nx"

      state = state |> press({:key, :escape}) |> press("O") |> type("y")
      assert text(state) == "hello\ny\nx"
    end

    test "v e d deletes the selected word and returns to NORMAL" do
      state = boot() |> press("i") |> type("hello world") |> press({:key, :escape})
      state = state |> press("0") |> press("v")
      assert state.vim.mode == :visual

      state = press(state, "e")
      assert Editor.selected_text(draft(state)) == "hello"

      state = press(state, "d")
      assert text(state) == " world"
      assert state.vim.mode == :normal
      assert Editor.selection(draft(state)) == nil
    end

    test "Esc from VISUAL drops the selection without moving the caret" do
      state = boot() |> press("i") |> type("hello") |> press({:key, :escape})
      state = state |> press("0") |> press("v") |> press("e")
      assert Editor.selected_text(draft(state)) == "hello"

      state = press(state, {:key, :escape})
      assert state.vim.mode == :normal
      assert Editor.selection(draft(state)) == nil
      assert cursor(state) == 5
      assert text(state) == "hello"
    end

    test "yy then p puts the line below" do
      state = boot() |> press("i") |> type("hello") |> press({:key, :escape})
      state = state |> press("y") |> press("y")
      assert Editor.register(draft(state)) == {"hello\n", :linewise}
      assert text(state) == "hello"

      state = press(state, "p")
      assert text(state) == "hello\nhello"
    end

    test "x deletes under the caret; u undoes; Ctrl-R redoes" do
      state = boot() |> press("i") |> type("hello") |> press({:key, :escape})

      state = press(state, "x")
      assert text(state) == "hell"

      state = press(state, "u")
      assert text(state) == "hello"

      state = press(state, {:ctrl, "r"})
      assert text(state) == "hell"
    end

    test "Enter in NORMAL and in INSERT both resolve to the send target" do
      state = boot() |> press("i") |> type("hello")
      assert {:ok, {:invoke, @send, _}} = Keymap.resolve(Input.key(:enter), state, @table)

      state = press(state, {:key, :escape})
      assert {:ok, {:invoke, @send, _}} = Keymap.resolve(Input.key(:enter), state, @table)
    end
  end

  describe "switching the keymap" do
    test "the command palette offers the toggle and it resets the vim state" do
      state = boot(:default)
      assert Enum.any?(SwarmCodeCLI.UI.Switcher.catalogue(state), &(&1.label == "Vim mode: off"))

      {state, _} = Reducer.update(state, {:set_keymap, :vim})
      assert state.keymap == :vim
      assert Enum.any?(SwarmCodeCLI.UI.Switcher.catalogue(state), &(&1.label == "Vim mode: on"))

      state = state |> press("i") |> press({:key, :escape}) |> press("d")
      {state, _} = Reducer.update(state, {:set_keymap, :default})
      assert state.vim == %SwarmCodeCLI.UI.Vim{}
      assert Context.of(state) == :composer
    end

    test "SWARM_KEYMAP=vim is the only spelling that turns vim on at boot" do
      assert Init.keymap_from_env("vim") == :vim
      assert Init.keymap_from_env(" VIM\n") == :vim
      assert Init.keymap_from_env("emacs") == :default
      assert Init.keymap_from_env("") == :default
      assert Init.keymap_from_env(nil) == :default
    end
  end

  # ------------------------------------------------------------------ helpers

  defp boot(keymap \\ :vim) do
    {state, _effects} =
      Reducer.init(%Init{
        size: @size,
        capabilities: %Capabilities{size: @size},
        source_epoch: "vim-test",
        destination: {:conversation, "c"},
        focus: "main",
        keymap: keymap
      })

    state
  end

  # One keystroke, resolved and reduced exactly as the runtime does it. A key
  # the grammar ignores leaves the state alone, which is itself an assertion.
  defp press(state, {:key, code}), do: feed(state, Input.key(code))
  defp press(state, {:key, code, mods}), do: feed(state, Input.key(code, mods))

  defp press(state, {:ctrl, letter}),
    do: feed(state, Input.text_fragment(:press, letter, [:control]))

  defp press(state, letter) when is_binary(letter),
    do: feed(state, Input.text_fragment(:press, letter, []))

  defp feed(state, input) do
    case Keymap.resolve(input, state, @table) do
      {:ok, action} ->
        {next, _effects} = Reducer.update(state, action)
        next

      :ignore ->
        state
    end
  end

  defp type(state, text), do: Enum.reduce(String.graphemes(text), state, &press(&2, &1))

  # Lines typed in INSERT, separated by Ctrl-O, the composer's newline.
  defp lines(state, lines) do
    lines
    |> Enum.map(&{:line, &1})
    |> Enum.intersperse(:newline)
    |> Enum.reduce(state, fn
      {:line, line}, state -> type(state, line)
      :newline, state -> press(state, {:ctrl, "o"})
    end)
  end

  defp draft(state), do: Drafts.fetch(state.drafts, State.current_draft_key(state)).editor
  defp text(state), do: Editor.text(draft(state))
  defp cursor(state), do: Editor.cursor(draft(state))
end
