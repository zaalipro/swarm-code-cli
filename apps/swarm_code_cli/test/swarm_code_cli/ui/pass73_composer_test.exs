defmodule SwarmCodeCLI.UI.Pass73ComposerTest do
  @moduledoc "pass73: `Composer.enter_action/1` and `esc_action/1` say what the keys do now."
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.Composer

  test "an empty composer: Enter does nothing, Esc does nothing while idle" do
    state = ready()
    assert Composer.enter_action(state) == :none
    assert Composer.esc_action(state) == :none
    assert Composer.enter_action(type(state, "   ")) == :none
  end

  test "a plain message sends while idle, and while only a swarm runs" do
    assert Composer.enter_action(type(ready(), "hello")) == :send

    swarm = run("s", :running, kind: :swarm)
    assert Composer.enter_action(type(ready([swarm]), "hello")) == :send
  end

  # pass73 finisher (S's request K2): the daemon steers every registered
  # chat run, a paused or not yet started one included, so the hint says so.
  test "a plain message steers the live chat turn, paused or not started yet too" do
    for run_state <- [:running, :streaming, :waiting_approval, :waiting_question, :retrying] do
      state = ready([run("t", run_state)]) |> type("also check the tests")
      assert Composer.enter_action(state) == :steer, inspect(run_state)
    end

    for run_state <- [:queued, :paused] do
      state = ready([run("t", run_state)]) |> type("later")
      assert Composer.enter_action(state) == :steer, inspect(run_state)
    end

    # A finished turn is not the turn.
    assert Composer.enter_action(ready([run("t", :done)]) |> type("next")) == :send
  end

  test "a message that names a workflow runs /create-workflow, even while a turn runs" do
    assert Composer.enter_action(type(ready(), "write a workflow for releases")) == :run_command

    assert Composer.enter_action(ready([run("t", :running)]) |> type("a workflow")) ==
             :run_command

    assert Composer.enter_action(type(ready(), "explain `workflow`")) == :send
  end

  test "slash commands run; conversation-level ones wait for the running turn" do
    assert Composer.enter_action(type(ready(), "/compact ")) == :run_command
    assert Composer.enter_action(ready([run("t", :running)]) |> type("/compact ")) == :queue

    assert Composer.enter_action(ready([run("t", :running)]) |> type("/swarm review it")) ==
             :run_command
  end

  test "the palette: a prefix completes or runs, an exact name runs" do
    # /compact takes only an optional focus: Enter runs it.
    assert Composer.enter_action(type(ready(), "/com")) == :run_command
    # /consensus [task]: the task is its point, so Enter waits for it.
    assert Composer.enter_action(type(ready(), "/consens")) == :complete
    # A required argument waits too.
    assert Composer.enter_action(type(ready(), "/swa")) == :complete
    # An exact name is sent as typed.
    assert Composer.enter_action(type(ready(), "/consensus")) == :run_command
  end

  test "layers and select mode own Enter" do
    state = type(ready(), "hello")
    assert Composer.enter_action(%{state | layers: [:help]}) == :none
    assert Composer.enter_action(%{state | focus: "main"}) == :none
    assert Composer.esc_action(%{state | layers: [:help]}) == :close_layer
  end

  test "Esc names the turn it stops" do
    turn = run("t", :streaming, title: "Workflow author")
    assert {:stop, %{id: "t"}} = Composer.esc_action(ready([turn]))
    assert Composer.esc_action(ready([run("t", :streaming, actions: [])])) == :none
  end

  test "command names and after-turn commands" do
    assert Composer.command_name("/Compact now") == "compact"
    assert Composer.command_name("hello") == nil
    assert Composer.after_turn_command?("/compact")
    refute Composer.after_turn_command?("/swarm x")
  end
end
