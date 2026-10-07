defmodule SwarmCodeCLI.UI.Cli020.D7ShellTest do
  @moduledoc """
  cli020 D7 (competitors-9, decision 4c): `!cmd` in the composer runs a
  shell command through `shell.run` (lane C15); Ctrl-S sends it plain.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.Test.Cli020State

  alias SwarmCodeCLI.Test.Cli020State
  alias SwarmCodeCLI.UI.{Composer, Input}

  @c Cli020State.conversation()

  test "enter_action is :shell for !cmd and shell? says so" do
    state = ready() |> type("!ls -la")
    assert Composer.enter_action(state) == :shell
    assert Composer.shell?(state)
    assert Composer.shell_command(state) == "ls -la"
    refute Composer.shell?(ready() |> type(" !ls"))
    refute Composer.enter_action(ready() |> type(" !ls")) == :shell
  end

  test "Enter on !ls sends shell.run without the ! and clears the draft into history" do
    state = ready() |> type("!ls")
    {state, effects} = enter(state)

    assert commands(effects) == [{:shell_run, @c, "ls"}]
    assert text(state) == ""
    assert hd(state.prompt_history[@c]) == "!ls"
  end

  test "! alone says what to type" do
    {state, effects} = ready() |> type("! ") |> enter()
    assert commands(effects) == []
    assert state.notice == {:command_feedback, "Type a command after !"}
  end

  test "Ctrl-S sends a ! draft as a plain message" do
    {_state, effects} =
      ready() |> type("!ls") |> press(Input.text_fragment(:press, "s", [:control]))

    assert [{:dispatch, :send, "!ls", :main, []}] = commands(effects)
  end

  test "Esc while the shell command runs stops it before any turn" do
    {state, _} = ready() |> type("!sleep 5") |> enter()
    {_state, effects} = press(state, Input.key(:escape))

    assert commands(effects) == [{:shell_stop, @c}]
  end
end
