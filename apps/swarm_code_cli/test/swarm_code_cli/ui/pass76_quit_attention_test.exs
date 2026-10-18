defmodule SwarmCodeCLI.UI.Pass76QuitAttentionTest do
  @moduledoc """
  pass76 cli-quit-attention: a quit stops the runs of every conversation, so the
  confirmation counts them all and says how many are in other conversations;
  and an approval or question that appears in any conversation of the session
  rings (bell, OSC 9 or the OS notification) once per the 2 s throttle, naming
  the conversation. Both read the daemon's `elsewhere` fact from the shell
  watch; the reducer and projector stay pure.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers
  import SwarmCodeCLI.Cli020EHelpers, only: [screen_text: 1]

  alias SwarmCodeCLI.UI.{Reducer, SafeText}
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Delta, DTO}

  defp wait(id, conversation, title, kind \\ :approval),
    do: %DTO.ElsewhereWait{
      id: id,
      run_id: "run-" <> id,
      conversation_id: conversation,
      kind: kind,
      title: title
    }

  # The daemon's `elsewhere` fact as a shell-watch delta.
  defp elsewhere(state, live, waits, revision \\ 1) do
    watch = state.watches.shell
    sequence = watch.sequence + 1

    Reducer.update(
      state,
      {:data,
       %Delivery{
         kind: :delta,
         watch_ref: watch.watch_ref,
         request_id: nil,
         scope: watch.scope,
         generation: watch.generation,
         revision: revision,
         sequence: sequence,
         body: %Delta{
           kind: :elsewhere,
           body: %DTO.Elsewhere{live: live, waiting: waits},
           revision: revision,
           sequence: sequence
         }
       }}
    )
  end

  defp quit(state), do: state |> press!(ctrl("c")) |> press(ctrl("c"))
  defp ask(state), do: state |> quit() |> elem(0)

  describe "the quit confirmation" do
    test "counts the runs of every conversation and says how many are elsewhere" do
      state = ready([run("r", :running, actions: [])]) |> elsewhere(2, []) |> elem(0)

      state = ask(state)

      assert [{:unsent_changes, :detach} | _] = state.layers
      assert state.quit_live_runs == 3
      assert state.quit_live_elsewhere == 2
      assert state.lifecycle == :running

      text = screen_text(state)
      assert text =~ "Stop 3 live runs and quit?"
      assert text =~ "2 are in other conversations."
      assert text =~ "They stop when ncode quits."
    end

    test "runs that are all in other conversations still ask, and say so" do
      state = ready([run("r", :done, actions: [])]) |> elsewhere(1, []) |> elem(0)

      state = ask(state)

      assert {state.quit_live_runs, state.quit_live_elsewhere} == {1, 1}
      text = screen_text(state)
      assert text =~ "Stop 1 live run and quit?"
      assert text =~ "It is in another conversation."

      state = ready([]) |> elsewhere(3, []) |> elem(0)
      state = ask(state)
      assert screen_text(state) =~ "All of them are in other conversations."
    end

    test "one run elsewhere beside the one in view is worded as one" do
      state = ready([run("r", :running, actions: [])]) |> elsewhere(1, []) |> elem(0)
      state = ask(state)
      assert screen_text(state) =~ "1 is in another conversation."
    end

    test "with nothing live anywhere the quit asks nothing" do
      state = ready([run("r", :done, actions: [])]) |> elsewhere(0, []) |> elem(0)

      {state, effects} = quit(state)

      assert state.lifecycle == :closing
      assert state.quit_live_elsewhere == 0
      assert {:detach, 0} in effects
    end

    test "a state that never heard the fact counts only the runs in view" do
      state = ready([run("r", :running, actions: []), run("s", :paused, actions: [])])
      assert Reducer.live_elsewhere_count(state) == 0
      assert Reducer.live_run_count(state) == 2

      state = ask(state)
      assert {state.quit_live_runs, state.quit_live_elsewhere} == {2, 0}
      refute screen_text(state) =~ "other conversation"
    end

    test "a presenter hand-off to the plain screen asks about them too" do
      state = ready([]) |> elsewhere(2, []) |> elem(0)
      {state, []} = Reducer.update(state, {:presenter_handoff_requested, :plain})
      assert [{:unsent_changes, :plain} | _] = state.layers
      assert state.quit_live_runs == 2
    end
  end

  describe "attention for the conversations not in view" do
    defp opts,
      do: [
        init: [
          launch_facts: %{project_root: "/tmp/work/demo"},
          capabilities: %SwarmCodeCLI.UI.Capabilities{
            size: %SwarmCodeCLI.UI.Size{columns: 150, rows: 40},
            full_screen?: true
          }
        ]
      ]

    defp focus(state, focus),
      do: elem(Reducer.update(state, {:terminal_focus, focus, state.terminal_generation}), 0)

    defp at(state, now), do: %{state | now: now}

    defp bells(effects), do: for({:bell, kind} <- effects, do: kind)
    defp words(effects), do: for({:notify_os, text} <- effects, do: SafeText.value(text))
    defp titles(effects), do: for({:terminal_title, text} <- effects, do: SafeText.value(text))

    # A session whose terminal is unfocused and whose shell watch already told
    # it that nothing waits elsewhere.
    defp baseline(extra \\ []) do
      state = ready([run("r", :running)], Keyword.merge(opts(), extra)) |> focus(:lost)
      {state, _} = elsewhere(at(state, 10_000), 1, [])
      state
    end

    test "a new approval in another conversation rings once and names it" do
      {state, effects} = elsewhere(baseline(), 1, [wait("a1", "o", "Refactor parser")], 2)

      assert bells(effects) == [:needs_you]
      assert words(effects) == ["ncode: demo needs you (approval in Refactor parser)"]
      assert state.last_bell_at == 10_000
    end

    test "a question says question" do
      {_state, effects} =
        elsewhere(baseline(), 1, [wait("q1", "o", "Docs pass", :question)], 2)

      assert words(effects) == ["ncode: demo needs you (question in Docs pass)"]
    end

    test "the same wait again, and waits that went, ring nothing" do
      waits = [wait("a1", "o", "Refactor parser")]
      {state, first} = elsewhere(baseline(), 1, waits, 2)
      assert bells(first) == [:needs_you]

      {state, again} = elsewhere(at(state, 20_000), 2, waits, 3)
      assert bells(again) == []

      {_state, gone} = elsewhere(at(state, 30_000), 0, [], 4)
      assert bells(gone) == []
    end

    test "a burst bells once per 2 s, like the conversation in view" do
      one = wait("a1", "o", "Refactor parser")
      two = wait("a2", "p", "Docs pass")
      three = wait("a3", "q", "Release notes")

      {state, first} = elsewhere(baseline(), 1, [one], 2)
      {state, second} = elsewhere(at(state, 10_500), 2, [one, two], 3)
      {_state, third} = elsewhere(at(state, 12_100), 3, [one, two, three], 4)

      assert bells(first) == [:needs_you]
      assert bells(second) == []
      assert bells(third) == [:needs_you]
      assert words(third) == ["ncode: demo needs you (approval in Release notes)"]
    end

    test "waits in several conversations at once are counted, not listed" do
      waits = [wait("a1", "o", "Refactor parser"), wait("q1", "p", "Docs pass", :question)]
      {_state, effects} = elsewhere(baseline(), 2, waits, 2)

      assert bells(effects) == [:needs_you]
      assert words(effects) == ["ncode: demo needs you (approval in 2 conversations)"]
    end

    test "a title is made safe and cut; a blank one reads another conversation" do
      long = String.duplicate("long title ", 12)
      {_state, effects} = elsewhere(baseline(), 1, [wait("a1", "o", long)], 2)
      [said] = words(effects)
      assert said =~ ~r/^ncode: demo needs you \(approval in long title long title.*…\)$/

      {_state, effects} = elsewhere(baseline(), 1, [wait("a1", "o", "   ")], 2)
      assert words(effects) == ["ncode: demo needs you (approval in another conversation)"]
    end

    test "the focus and notify rules are unchanged" do
      waits = [wait("a1", "o", "Refactor parser")]

      focused = baseline() |> focus(:gained)
      assert bells(elsewhere(focused, 1, waits, 2) |> elem(1)) == []

      off = baseline(init: Keyword.fetch!(opts(), :init) ++ [notify: :off])
      assert bells(elsewhere(off, 1, waits, 2) |> elem(1)) == []
    end

    test "the first fact held is a baseline, not news" do
      state = ready([run("r", :running)], opts()) |> focus(:lost) |> at(10_000)
      {state, effects} = elsewhere(state, 1, [wait("a1", "o", "Refactor parser")])

      assert bells(effects) == []
      assert state.last_bell_at == nil
    end

    test "an approval in the conversation in view is the in-view rule's" do
      {_state, effects} = elsewhere(baseline(), 1, [wait("a1", "c", "This one")], 2)
      assert bells(effects) == []
    end

    test "the window title is the conversation in view's alone" do
      {state, effects} = elsewhere(baseline(), 1, [wait("a1", "o", "Refactor parser")], 2)
      assert titles(effects) == []
      assert state.terminal_title == "ncode · demo · working"
    end
  end
end
