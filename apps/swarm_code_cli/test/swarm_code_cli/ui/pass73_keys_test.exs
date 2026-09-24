defmodule SwarmCodeCLI.UI.Pass73KeysTest do
  @moduledoc """
  pass73-K: Enter on the slash palette (T4), the word "workflow" (T5) and
  the display commands /diff, /theme, /mouse (T1, T2, T9). Every key goes
  through `Keymap.resolve/3` and `Reducer.update/2`.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers

  alias SwarmCodeCLI.UI.{Input, Keymap, Reducer}

  defp enter(state), do: press(state, Input.key(:enter))

  describe "T4: Enter on the palette" do
    test "/com + Enter runs /compact at once" do
      {state, effects} = ready() |> type("/com") |> enter()
      assert [%{kind: {:dispatch, :send, "/compact", :main, []}}] = requests(effects)
      assert text(state) == "/compact"
    end

    test "/consens + Enter leaves /consensus and a space for the task" do
      {state, effects} = ready() |> type("/consens") |> enter()
      assert requests(effects) == []
      assert text(state) == "/consensus "
      assert state.slash_palette == nil
    end

    test "a required argument waits too; an exact name is sent as typed" do
      {state, effects} = ready() |> type("/swa") |> enter()
      assert requests(effects) == []
      assert text(state) == "/swarm "

      {_state, effects} = ready() |> type("/consensus") |> send()
      assert [%{kind: {:dispatch, :send, "/consensus", :main, []}}] = requests(effects)
    end

    test "the client's own commands complete and run on the client" do
      {state, effects} = ready() |> type("/hel") |> enter()
      assert requests(effects) == []
      assert [:help | _] = state.layers

      {state, _} = ready() |> type("/pan") |> enter()
      assert state.notice == {:command_feedback, "Panel is full: /panel full, compact or hidden."}
    end

    test "Down picks another command before Enter" do
      state = ready() |> type("/re")
      [_first, second | _] = SwarmCodeCLI.UI.SlashPalette.entries(state)
      state = press!(state, Input.key(:down))
      {state, _effects} = enter(state)

      if SwarmCodeCLI.UI.SlashPalette.runs_bare?(second),
        do: assert(text(state) in ["", "/" <> second.name]),
        else: assert(text(state) == "/" <> second.name <> " ")
    end
  end

  describe "T5: the word workflow" do
    test "Enter sends a message that names a workflow as /create-workflow" do
      {_state, effects} = ready() |> paste("Write a workflow that runs the tests") |> send()

      assert [
               %{
                 kind:
                   {:dispatch, :send, "/create-workflow Write a workflow that runs the tests",
                    :main, []}
               }
             ] = requests(effects)
    end

    test "Ctrl-S sends it as the plain message it is" do
      state = ready() |> paste("why did the workflow fail?")
      assert {:ok, :send_plain} = Keymap.resolve(ctrl("s"), state, %{})
      {_state, effects} = press(state, ctrl("s"))

      assert [%{kind: {:dispatch, :send, "why did the workflow fail?", :main, []}}] =
               requests(effects)
    end

    test "Ctrl-S on any other draft is Enter" do
      {_state, effects} = ready() |> paste("hello") |> press(ctrl("s"))
      assert [%{kind: {:dispatch, :send, "hello", :main, []}}] = requests(effects)

      {state, _} = ready() |> paste("/diff off") |> press(ctrl("s"))
      refute state.show_diffs
    end

    test "code, a slash command and a longer word are not routed" do
      for draft <- ["run `workflow` again", "/swarm review the workflow", "subworkflows"] do
        {_state, effects} = ready() |> paste(draft) |> send()
        assert [%{kind: {:dispatch, :send, ^draft, :main, []}}] = requests(effects)
      end
    end
  end

  describe "T1, T2, T9: /diff, /theme, /mouse" do
    test "/diff toggles, /diff on|off sets, and each change is saved and said" do
      {state, effects} = ready() |> paste("/diff") |> send()
      refute state.show_diffs
      assert {:save_preferences, %{show_diffs: false}} in effects
      assert state.notice == {:command_feedback, "Diffs hidden · /diff shows them"}
      assert text(state) == ""

      {state, effects} = state |> paste("/diff on") |> send()
      assert state.show_diffs
      assert {:save_preferences, %{show_diffs: true}} in effects

      {state, effects} = state |> paste("/diff on") |> send()
      assert state.show_diffs
      assert {:save_preferences, %{show_diffs: true}} in effects

      {state, effects} = state |> paste("/diff sideways") |> send()
      assert state.show_diffs
      assert effects == []
      assert state.notice == {:command_feedback, "Try /diff on or off."}
    end

    test "/theme flips live: the port owner repaints and the choice is saved" do
      {state, effects} = ready() |> paste("/theme") |> send()
      assert state.theme_mode == :light
      assert {:terminal_preferences, %{theme: :light}} in effects
      assert {:save_preferences, %{theme: :light}} in effects

      {state, effects} = state |> paste("/theme dark") |> send()
      assert state.theme_mode == :dark
      assert {:terminal_preferences, %{theme: :dark}} in effects
    end

    test "with SWARM_THEME set, the confirmation says it still wins at the next launch" do
      state = ready([], init: [theme_mode: :dark, theme_env: :dark])
      {state, _} = state |> paste("/theme light") |> send()
      assert state.theme_mode == :light

      assert state.notice ==
               {:command_feedback, "Light theme · SWARM_THEME=dark still wins at the next launch"}
    end

    test "/mouse off gives selection back, /mouse on turns the wheel on again" do
      state = ready()
      assert state.mouse?

      {state, effects} = state |> paste("/mouse off") |> send()
      refute state.mouse?
      assert {:terminal_preferences, %{mouse?: false}} in effects
      assert {:save_preferences, %{mouse?: false}} in effects
      assert {:command_feedback, "Wheel scrolling off" <> _} = state.notice

      {state, effects} = state |> paste("/mouse") |> send()
      assert state.mouse?
      assert {:terminal_preferences, %{mouse?: true}} in effects
    end

    test "the palette lists them with the client's words" do
      entries = SwarmCodeCLI.UI.SlashPalette.entries(type(ready(), "/"))
      diff = Enum.find(entries, &(&1.name == "diff"))
      assert diff.args == "[on|off]"
      assert diff.desc =~ "diffs"
      assert Enum.any?(entries, &(&1.name == "theme"))
      assert Enum.any?(entries, &(&1.name == "mouse"))
    end

    test "preferences read after start apply, except a theme SWARM_THEME set" do
      {state, effects} =
        Reducer.update(
          ready(),
          {:preferences_loaded, %{show_diffs: false, theme: :light, mouse?: false}}
        )

      refute state.show_diffs
      assert state.theme_mode == :light
      refute state.mouse?
      assert {:terminal_preferences, %{theme: :light}} in effects
      assert {:terminal_preferences, %{mouse?: false}} in effects

      pinned = ready([], init: [theme_env: :dark])
      {state, effects} = Reducer.update(pinned, {:preferences_loaded, %{theme: :light}})
      assert state.theme_mode == :dark
      assert effects == []
    end
  end
end
