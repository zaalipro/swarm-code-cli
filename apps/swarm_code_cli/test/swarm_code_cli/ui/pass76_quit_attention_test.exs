defmodule SwarmCodeCLI.UI.Pass76QuitAttentionTest do
  @moduledoc """
  pass76 cli-quit-attention: a quit stops the runs of every conversation, so the
  confirmation counts them all and says how many are in other conversations;
  and an approval or question that appears in any conversation of the session
  rings (bell, OSC 9 or the OS notification) once per the 2 s throttle, naming
  the conversations. Both read the daemon's `elsewhere` fact from the shell
  watch; the reducer and projector stay pure. The count is the fact's alone:
  the read model's run rows are a cache (a closed inspector's rows stay, the
  runs page is the newest 200) and prove nothing about what is live.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.Pass73Helpers
  import SwarmCodeCLI.Cli020EHelpers, only: [screen_text: 1]

  alias SwarmCodeCLI.UI.{ReadModel, Reducer, SafeText}
  alias SwarmCodeCLI.UI.Reducer.Attention
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Delta, DTO}

  defp wait(id, conversation, title, kind \\ :approval, since \\ 1),
    do: %DTO.ElsewhereWait{
      id: id,
      run_id: "run-" <> id,
      conversation_id: conversation,
      kind: kind,
      title: title,
      since: since
    }

  # The daemon's `elsewhere` fact as a shell-watch delta: `live` runs outside
  # the shown conversation, `total` in the whole session (default: `live`,
  # nothing running in the shown conversation).
  defp elsewhere(state, live, waits, revision \\ 1, total \\ nil) do
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
           body: %DTO.Elsewhere{total: total || live, live: live, waiting: waits},
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
      state = ready([run("r", :running, actions: [])]) |> elsewhere(2, [], 1, 3) |> elem(0)

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
      state = ready([run("r", :running, actions: [])]) |> elsewhere(1, [], 1, 2) |> elem(0)
      state = ask(state)
      assert screen_text(state) =~ "Stop 2 live runs and quit?"
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

  describe "the count is the daemon's, not the cached run rows'" do
    # What closing an inspector leaves behind: `ReadModel` keeps the coverage
    # of a slot until its watch is replaced, so the run row of another
    # conversation stays in the cache after the switch.
    defp retained(state, id, run_state) do
      row = %{run(id, run_state, actions: []) | conversation_id: "o"}
      detail = struct!(DTO.RunDetailSnapshot, run: row)
      %{state | read_model: ReadModel.snapshot(state.read_model, :inspector, detail)}
    end

    test "a closed inspector's retained run is counted once, not twice" do
      state = ready([run("shown", :done, actions: [])]) |> retained("bg", :running)

      assert %{conversation_id: "o", state: :running} = state.read_model.runs["bg"]
      # The premise: the cache alone would count it (and the fact counts it too).
      assert Reducer.live_run_count(state) == 1

      state = state |> elsewhere(1, [], 1, 1) |> elem(0) |> ask()

      assert {state.quit_live_runs, state.quit_live_elsewhere} == {1, 1}
      text = screen_text(state)
      assert text =~ "Stop 1 live run and quit?"
      assert text =~ "It is in another conversation."
    end

    test "the retained run finishing off screen leaves nothing to confirm" do
      state = ready([run("shown", :done, actions: [])]) |> retained("bg", :running)
      state = state |> elsewhere(1, [], 1, 1) |> elem(0)

      # Nothing watches that run any more, so its row stays `running` while
      # the daemon's registry no longer has it.
      state = state |> elsewhere(0, [], 2, 0) |> elem(0)
      assert %{state: :running} = state.read_model.runs["bg"]
      assert {Reducer.live_run_count(state), Reducer.live_elsewhere_count(state)} == {0, 0}

      {state, effects} = quit(state)

      assert state.lifecycle == :closing
      assert {:detach, 0} in effects
      assert state.quit_live_runs == 0
    end

    test "a live run behind 200 finished rows is counted" do
      finished = for n <- 1..200, do: run("done-#{n}", :done, actions: [])
      state = ready(finished)

      # The runs page is the newest 200; the old live run is not among them.
      assert Enum.count(state.read_model.runs) == 200
      assert Reducer.live_run_count(state) == 0

      state = state |> elsewhere(0, [], 1, 1) |> elem(0) |> ask()

      assert {state.quit_live_runs, state.quit_live_elsewhere} == {1, 0}
      text = screen_text(state)
      assert text =~ "Stop 1 live run and quit?"
      refute text =~ "other conversation"
    end

    test "the total does not move when the shown conversation does" do
      state = ready([run("r", :running, actions: [])]) |> elsewhere(0, [], 1, 1) |> elem(0)
      assert Reducer.live_run_count(state) == 1

      # The shell watch re-snapshots with the run now outside the shown one.
      state = state |> elsewhere(1, [], 2, 1) |> elem(0)
      assert {Reducer.live_run_count(state), Reducer.live_elsewhere_count(state)} == {1, 1}
    end

    test "the rows of the cache are never added to the fact" do
      state =
        ready([run("r", :running, actions: []), run("s", :paused, actions: [])])
        |> elsewhere(2, [], 1, 5)
        |> elem(0)

      assert {Reducer.live_run_count(state), Reducer.live_elsewhere_count(state)} == {5, 2}
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

    defp elsewhere_model(state, waits) do
      %{
        state.read_model
        | elsewhere: %DTO.Elsewhere{total: length(waits), live: length(waits), waiting: waits}
      }
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
      one = wait("a1", "o", "Refactor parser", :approval, 1)
      two = wait("a2", "p", "Docs pass", :approval, 2)
      three = wait("a3", "q", "Release notes", :approval, 3)

      {state, first} = elsewhere(baseline(), 1, [one], 2)
      {state, second} = elsewhere(at(state, 10_500), 2, [one, two], 3)
      {_state, third} = elsewhere(at(state, 12_100), 3, [one, two, three], 4)

      assert bells(first) == [:needs_you]
      assert bells(second) == []
      assert bells(third) == [:needs_you]
      assert words(third) == ["ncode: demo needs you (approval in Release notes)"]
    end

    test "waits in several conversations at once are named, two at most" do
      waits = [
        wait("a1", "o", "Refactor parser", :approval, 1),
        wait("q1", "p", "Docs pass", :question, 2)
      ]

      {_state, effects} = elsewhere(baseline(), 2, waits, 2)

      assert bells(effects) == [:needs_you]

      assert words(effects) == [
               "ncode: demo needs you (approval in Refactor parser and Docs pass)"
             ]

      three = waits ++ [wait("a3", "q", "Release notes", :approval, 3)]
      {_state, effects} = elsewhere(baseline(), 3, three, 2)

      assert words(effects) == [
               "ncode: demo needs you (approval in Refactor parser, Docs pass +1 more)"
             ]

      many = for n <- 1..30, do: wait("w#{n}", "conv-#{n}", "Conversation #{n}", :question, n)
      {_state, effects} = elsewhere(baseline(), 30, many, 2)
      [said] = words(effects)

      assert said == "ncode: demo needs you (question in Conversation 1, Conversation 2 +28 more)"
      assert bells(effects) == [:needs_you]
    end

    test "two waits of one conversation name it once" do
      waits = [
        wait("a1", "o", "Refactor parser", :approval, 1),
        wait("a2", "o", "Refactor parser", :approval, 2)
      ]

      {_state, effects} = elsewhere(baseline(), 1, waits, 2)
      assert words(effects) == ["ncode: demo needs you (approval in Refactor parser)"]
    end

    test "long titles in a burst stay within the names' own bound" do
      long = String.duplicate("long title ", 12)
      waits = for n <- 1..3, do: wait("a#{n}", "c#{n}", long, :approval, n)

      {_state, effects} = elsewhere(baseline(), 3, waits, 2)
      [said] = words(effects)

      assert said =~ ~r/\Ancode: demo needs you \(approval in .+…, .+… \+1 more\)\z/
      assert String.length(said) < 140
    end

    test "a burst and the conversation in view say so in one bell" do
      state = baseline()

      in_view = %{
        state
        | read_model: elsewhere_model(state, [wait("a1", "o", "Refactor parser")])
      }

      pending = %{state: :pending, kind: :approval, conversation_id: "c"}

      next = %{
        in_view
        | read_model: %{in_view.read_model | interactions: %{"i1" => pending}},
          now: 12_500
      }

      {_next, effects} = Attention.after_update(state, next, [])
      assert bells(effects) == [:needs_you]

      assert words(effects) == [
               "ncode: demo needs you (approval in this conversation and Refactor parser)"
             ]
    end

    test "a title is made safe and cut; a blank one reads another conversation" do
      long = String.duplicate("long title ", 12)
      {_state, effects} = elsewhere(baseline(), 1, [wait("a1", "o", long)], 2)
      [said] = words(effects)
      assert said =~ ~r/^ncode: demo needs you \(approval in long title long title.*…\)$/

      {_state, effects} = elsewhere(baseline(), 1, [wait("a1", "o", "   ")], 2)
      assert words(effects) == ["ncode: demo needs you (approval in another conversation)"]
    end

    test "a wait that left the newest 32 and came back is not news" do
      old = wait("old", "o", "Refactor parser", :approval, 1)
      newer = for n <- 2..33, do: wait("n#{n}", "p", "Docs pass", :approval, n)
      assert length(newer) == 32

      {state, first} = elsewhere(baseline(), 1, [old], 2)
      assert bells(first) == [:needs_you]

      # 32 newer waits push it out of the daemon's window of the newest 32.
      {state, pushed} = elsewhere(at(state, 13_000), 32, newer, 3)
      assert bells(pushed) == [:needs_you]

      # One of the newer ones clears after the throttle: the old one is in
      # the window again, still the same request.
      remaining = List.delete_at(newer, 10)
      {state, back} = elsewhere(at(state, 16_000), 32, [old | remaining], 4)
      assert bells(back) == []
      assert words(back) == []

      # A request that really is new still rings.
      fresh = wait("fresh", "q", "Release notes", :question, 34)
      {_state, news} = elsewhere(at(state, 19_000), 32, remaining ++ [fresh], 5)
      assert words(news) == ["ncode: demo needs you (question in Release notes)"]
    end

    test "the mark holds when the old wait comes back inside the throttle too" do
      old = wait("old", "o", "Refactor parser", :approval, 1)
      newer = for n <- 2..33, do: wait("n#{n}", "p", "Docs pass", :approval, n)

      {state, _} = elsewhere(baseline(), 1, [old], 2)
      {state, _} = elsewhere(at(state, 13_000), 32, newer, 3)

      window = [old | List.delete_at(newer, 10)]
      {state, back} = elsewhere(at(state, 13_100), 32, window, 4)
      assert bells(back) == []
      assert state.elsewhere_mark == {33, "run-n33", "n33"}

      {_state, later} = elsewhere(at(state, 30_000), 32, window, 5)
      assert bells(later) == []
    end

    test "a wait seen while the terminal had focus is not news when focus is lost" do
      waits = [wait("a1", "o", "Refactor parser")]

      focused = baseline() |> focus(:gained)
      {state, effects} = elsewhere(focused, 1, waits, 2)
      assert bells(effects) == []

      state = state |> focus(:lost)
      {_state, effects} = elsewhere(at(state, 20_000), 1, waits, 3)
      assert bells(effects) == []
    end

    test "with no wait left the next one is news, whatever its clock says" do
      {state, first} =
        elsewhere(baseline(), 1, [wait("a1", "o", "Refactor parser", :approval, 90)], 2)

      assert bells(first) == [:needs_you]

      {state, gone} = elsewhere(at(state, 20_000), 0, [], 3)
      assert bells(gone) == []
      assert state.elsewhere_mark == nil

      {_state, again} =
        elsewhere(at(state, 30_000), 1, [wait("a2", "p", "Docs pass", :approval, 5)], 4)

      assert words(again) == ["ncode: demo needs you (approval in Docs pass)"]
    end

    test "the state kept for novelty is one mark, not the waits" do
      newer = for n <- 1..32, do: wait("n#{n}", "p", "Docs pass", :approval, n)
      {state, _} = elsewhere(baseline(), 32, newer, 2)

      assert state.elsewhere_mark == {32, "run-n32", "n32"}
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
