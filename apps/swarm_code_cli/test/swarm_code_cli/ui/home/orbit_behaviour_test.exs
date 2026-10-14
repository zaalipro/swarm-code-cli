defmodule SwarmCodeCLI.UI.Home.OrbitBehaviourTest do
  @moduledoc """
  orbit U9: what the keys do on Home, through the reducer: Enter (D10), opening a
  row, Esc, the list's search, the map, Alt-1..9, copying a command for another
  project, Ctrl-N (D19), Ctrl-C (D21), and the layers that may open over Home.
  """
  use ExUnit.Case, async: true

  import SwarmCodeCLI.OrbitHelpers

  alias SwarmCodeCLI.Cli020EHelpers, as: H
  alias SwarmCodeCLI.UI.{Drafts, Editor, Home, Input, Keymap, Reducer, SlashPalette, State}
  alias SwarmCodeCLI.UI.DataSource.DTO

  @new_id "9f9f9f9f-0000-4000-8000-000000000001"

  # Home open, the shell and the overview answered (Appendix C), the project's
  # conversations listed: four, the first the one in view.
  defp ready(options \\ []) do
    {state, _} = start(Keyword.take(options, [:size, :capabilities]))
    {state, effects} = step(state, :boot)
    [request] = queries(effects, :home_overview)
    {state, _} = answer_overview(state, request, Keyword.get(options, :overview, & &1))
    put_conversations(state, Keyword.get(options, :conversations, Enum.map(1..4, &summary/1)))
  end

  # Appendix C with nothing waiting anywhere: the fixture has an approval
  # waiting in the conversation in view.
  defp quiet(wire) do
    wire
    |> Map.put("waiting_total", 0)
    |> Map.update!("projects", fn projects ->
      for project <- projects do
        project
        |> Map.put("waiting", 0)
        |> Map.update!("conversations", fn conversations ->
          for conversation <- conversations, do: Map.put(conversation, "waiting", 0)
        end)
      end
    end)
  end

  # `quiet/1` with one conversation of the current project waiting.
  defp waiting_at(n) do
    id = summary(n).id

    fn wire ->
      wire = quiet(wire)

      update_in(wire["projects"], fn [here | rest] ->
        here =
          here
          |> Map.put("waiting", 1)
          |> Map.update!("conversations", fn conversations ->
            for conversation <- conversations do
              if conversation["id"] == id,
                do: Map.put(conversation, "waiting", 1),
                else: conversation
            end
          end)

        [here | rest]
      end)
    end
  end

  defp key_press(state, input) do
    case Keymap.resolve(input, state, %{}) do
      {:ok, action} -> Reducer.update(state, action)
      :ignore -> {state, []}
    end
  end

  # `type/2` of the helpers returns the reducer's pair; the tests pipe states.
  defp typed(state, text), do: state |> type(text) |> elem(0)

  defp draft(state, key), do: Editor.text(Drafts.fetch(state.drafts, key).editor)
  defp focus(state, verb), do: state |> step({:home, verb}) |> elem(0)

  describe "Enter in the composer (D10)" do
    test "text over an empty conversation is sent there: no new conversation, one dispatch, Home closed" do
      state =
        ready(conversations: [summary(1, run_count: 0, last_prompt: nil)])
        |> workspace_ready()
        |> typed("fix the flaky test")

      {state, effects} = step(state, {:home, :enter})
      assert state.home == nil
      assert commands(effects, :conversation_new) == []

      assert [%{kind: {:dispatch, :send, "fix the flaky test", :main, []}}] =
               commands(effects, :dispatch)

      assert home_draft(state) == ""
    end

    test "text over a conversation that has history makes a new one first" do
      state = ready() |> workspace_ready() |> typed("fix the flaky test")
      {state, effects} = step(state, {:home, :enter})

      assert [_new] = commands(effects, :conversation_new)
      assert commands(effects, :dispatch) == []
      assert state.home.pending_send == "fix the flaky test"
      assert home_draft(state) == ""

      # a second Enter while the first is out does nothing
      {again, more} = step(state, {:home, :enter})
      assert more == []
      assert again.home.pending_send == "fix the flaky test"
    end

    test "the text follows the new conversation: kept for its workspace, then sent" do
      state = ready() |> workspace_ready() |> typed("fix the flaky test")
      {state, _} = step(state, {:home, :enter})

      {state, _} = step(state, {:navigate, {:conversation, @new_id}})
      assert state.home == nil
      assert state.deferred_send == {{@new_id, :main}, "fix the flaky test"}
      assert draft(state, {@new_id, :main}) == "fix the flaky test"

      {state, effects} = workspace_delivered(state)
      assert state.deferred_send == nil

      assert [%{kind: {:dispatch, :send, "fix the flaky test", :main, []}}] =
               commands(effects, :dispatch)
    end

    test "a refused conversation.new gives the text back to Home's draft" do
      state = ready() |> workspace_ready() |> typed("fix the flaky test")
      {state, effects} = step(state, {:home, :enter})
      [request] = commands(effects, :conversation_new)

      refused = %{state | requests: Map.delete(state.requests, request.request_id)}
      {state, _} = step(refused, :boot)
      assert state.home.pending_send == nil
      assert home_draft(state) == "fix the flaky test"
    end

    test "a draft in the conversation underneath makes it not empty" do
      state =
        ready(conversations: [summary(1, run_count: 0, last_prompt: nil)])
        |> workspace_ready()

      {state, _} = step(state, {:editor, {conversation_id(), :main}, {:insert, "my own words"}})
      state = typed(state, "fix the flaky test")
      {state, effects} = step(state, {:home, :enter})
      assert [_new] = commands(effects, :conversation_new)
      assert draft(state, {conversation_id(), :main}) == "my own words"
    end

    test "an empty draft opens the selected row" do
      state = ready() |> focus(:down)
      {_, effects} = step(state, {:home, :enter})
      assert [%{kind: {:conversation_open, id}}] = commands(effects, :conversation_open)
      assert id == summary(2).id
    end

    test "on the conversation in view an empty Enter just closes Home" do
      {state, effects} = step(ready(), {:home, :enter})
      assert state.home == nil
      assert commands(effects, :conversation_open) == []
    end
  end

  describe "slash commands typed in Home" do
    test "/trust runs from Home and Home stays" do
      state = ready() |> workspace_ready() |> typed("/trust")
      {state, effects} = step(state, {:home, :enter})
      assert state.home != nil
      assert [_] = commands(effects, :project_update)
      assert home_draft(state) == ""
    end

    test "/rewind closes Home first, runs against the conversation, and the draft there survives" do
      state = ready() |> workspace_ready()
      {state, _} = step(state, {:editor, {conversation_id(), :main}, {:insert, "my own words"}})
      state = typed(state, "/rewind")
      {state, _effects} = step(state, {:home, :enter})
      assert state.home == nil
      assert home_draft(state) == ""
      assert draft(state, {conversation_id(), :main}) == "my own words"
    end

    test "/home typed in Home only clears the draft" do
      state = ready() |> typed("/home")
      {state, _} = step(state, {:home, :enter})
      assert %Home{} = state.home
      assert home_draft(state) == ""
    end
  end

  describe "the slash list" do
    test "opens on a `/` draft, ↑/↓ move it, Tab completes the highlighted row" do
      state = ready() |> typed("/t")
      assert SlashPalette.open?(state)
      [first, second | _] = SlashPalette.entries(state)
      assert SlashPalette.selected(state).name == first.name

      {state, _} = step(state, {:home, :down})
      assert SlashPalette.selected(state).name == second.name
      assert state.home.selected == 0

      {state, _} = step(state, {:home, :focus_next})
      assert state.home.focus == :composer
      assert home_draft(state) == "/" <> second.name <> " "
    end

    test "is drawn over the bottom of the list, above the composer" do
      state = ready() |> typed("/t")
      rows = H.screen(state)
      [first | _] = SlashPalette.entries(state)
      assert Enum.any?(Enum.slice(rows, 24, 9), &(&1 =~ "/" <> first.name))
      assert Enum.at(rows, 33) =~ "› /t"
      assert Enum.at(rows, 35) =~ "Tab complete"
    end

    test "Enter on a half-typed command completes or runs it, and never sends the half" do
      state = ready() |> workspace_ready() |> typed("/tru")
      {state, effects} = step(state, {:home, :enter})
      assert commands(effects, :conversation_new) == []
      assert commands(effects, :dispatch) == []
      refute home_draft(state) == "/tru"
      assert String.starts_with?(home_draft(state), "/trust") or effects != []
    end

    test "a command with arguments for the conversation in view closes Home first" do
      state = ready() |> workspace_ready() |> typed("/rewind 3")
      {state, effects} = step(state, {:home, :enter})
      assert state.home == nil
      assert commands(effects, :conversation_new) == []
    end

    test "a bare /effort is drawn and runs for the conversation in view" do
      state = ready() |> workspace_ready() |> typed("/effort")
      assert H.screen(state) |> Enum.at(34) =~ "run /effort"
      {state, _} = step(state, {:home, :enter})
      assert state.home == nil
    end

    test "where the list does not fit, the hint line says what the keys do" do
      state = ready(size: {60, 16}) |> typed("/t")
      assert SlashPalette.open?(state)
      assert H.screen(state) |> Enum.at(14) =~ "Tab complete"
    end
  end

  describe "Esc" do
    test "from the composer leaves Home with the draft kept; Alt-O brings it back" do
      state = ready() |> typed("keep me")
      {state, _} = step(state, {:home, :escape})
      assert state.home == nil
      {state, _} = step(state, :open_home)
      assert home_draft(state) == "keep me"
    end

    test "from the list keeps the filter and goes back to the composer" do
      state = ready() |> focus(:focus_next)
      {state, _} = step(state, {:field_editor, Home.filter_key(), {:insert, "rate"}})
      {state, _} = step(state, {:home, :escape})
      assert state.home.focus == :composer
      assert state.home.filter == "rate"
    end
  end

  describe "Tab" do
    test "walks composer, list, map and round, and back with Shift-Tab" do
      state = ready()
      walk = fn state, verb -> Enum.scan(1..3, state, fn _, acc -> focus(acc, verb) end) end
      assert Enum.map(walk.(state, :focus_next), & &1.home.focus) == [:list, :map, :composer]

      assert Enum.map(walk.(state, :focus_previous), & &1.home.focus) ==
               [:map, :list, :composer]
    end

    test "the first Tab from the composer lands on the list, in a first run too: the hints say `list` (UI-U-6)" do
      assert focus(ready(), :focus_next).home.focus == :list
      first = ready(conversations: [summary(1, run_count: 0, last_prompt: nil)])
      assert Home.View.first_run?(first)
      assert focus(first, :focus_next).home.focus == :list
    end

    test "skips the map where none is drawn (the minimal class)" do
      state = ready(size: {60, 16})
      walk = Enum.scan(1..3, state, fn _, acc -> focus(acc, :focus_next) end)
      assert Enum.map(walk, & &1.home.focus) == [:list, :composer, :list]
    end
  end

  describe "the list's search" do
    test "typing asks once; more typing while it is out asks once more after the reply; stale replies drop" do
      state = ready() |> focus(:focus_next)
      {state, effects} = step(state, {:field_editor, Home.filter_key(), {:insert, "rate"}})
      assert [first] = queries(effects, :conversation_search)
      assert first.kind == {:conversation_search, "rate", 50, 262_144}

      {state, effects} = step(state, {:field_editor, Home.filter_key(), {:insert, "-limit"}})
      assert queries(effects, :conversation_search) == []
      assert state.home.search_dirty?

      hit = summary(7, title: "rate-limit chip wiring")
      body = %DTO.ConversationList{items: [hit], request_id: first.request_id, state: :idle}
      {state, effects} = respond(state, first, body)
      assert [second] = queries(effects, :conversation_search)
      assert second.kind == {:conversation_search, "rate-limit", 50, 262_144}
      assert state.home.search.query == "rate"

      # the first request's id is spent: a second answer for it is dropped
      {late, effects} = respond(state, first, %{body | items: []})
      assert effects == []
      assert late.home.search == state.home.search

      newest = %DTO.ConversationList{items: [hit], request_id: second.request_id, state: :idle}
      {state, _} = respond(state, second, newest)
      assert state.home.search.query == "rate-limit"
      assert Enum.map(Home.rows(state), & &1.title) == ["rate-limit chip wiring"]

      {state, _} = step(state, {:home, :escape})
      assert state.home.focus == :composer
      assert state.home.filter == "rate-limit"
    end
  end

  describe "the map and another project's conversations" do
    test "Enter on another project's bead copies the command that opens it there" do
      state = ready() |> focus(:focus_next) |> focus(:focus_next) |> focus(:right)
      assert state.home.focus == :map and state.home.orbit == 1
      {state, effects} = step(state, {:home, :enter})

      assert {:copy, "ncode ~/dev/llmotions -r 7c1e9a2b"} in effects

      assert state.notice ==
               {:command_feedback,
                "Copied: ncode ~/dev/llmotions -r 7c1e9a2b — run it in a new terminal tab."}

      assert state.home != nil
    end

    test "y copies for this project's bead too; Enter there opens it" do
      state = ready() |> focus(:focus_next) |> focus(:focus_next) |> focus(:down)
      assert state.home.bead == 1

      {_, effects} = step(state, {:home, :copy})
      assert {:copy, "ncode ~/dev/swarm-code-cli -r 1a2b3c4d"} in effects

      {_, effects} = step(state, {:home, :enter})
      assert [%{kind: {:conversation_open, id}}] = commands(effects, :conversation_open)
      assert id == summary(2).id
    end

    test "the orbit and the bead stay on what exists" do
      state = ready() |> focus(:focus_next) |> focus(:focus_next)
      state = Enum.reduce(1..5, state, fn _, acc -> focus(acc, :right) end)
      assert state.home.orbit == 1
      state = Enum.reduce(1..5, state, fn _, acc -> focus(acc, :down) end)
      assert state.home.bead == 0
      state = Enum.reduce(1..5, state, fn _, acc -> focus(acc, :left) end)
      assert state.home.orbit == 0
    end
  end

  describe "Alt-1..9" do
    test "Alt-3 opens row 3" do
      {_, effects} = step(ready(), {:home, {:open_row, 3}})
      assert [%{kind: {:conversation_open, id}}] = commands(effects, :conversation_open)
      assert id == summary(3).id
    end

    test "Alt-1 on the conversation in view closes Home; a row that is not there does nothing" do
      {state, effects} = step(ready(), {:home, {:open_row, 1}})
      assert state.home == nil and effects == []
      {state, effects} = step(ready(), {:home, {:open_row, 9}})
      assert state.home != nil and effects == []
    end

    test "in a first run Alt-n copies the nth conversation elsewhere" do
      state = ready(conversations: [summary(1, run_count: 0, last_prompt: nil)])
      assert Home.View.first_run?(state)
      {_, effects} = step(state, {:home, {:open_row, 1}})
      assert {:copy, "ncode ~/dev/llmotions -r 7c1e9a2b"} in effects
      {_, effects} = step(state, {:home, {:open_row, 2}})
      assert effects == []
    end
  end

  describe "Ctrl-N" do
    test "goes to the first conversation here that waits" do
      waiting = [summary(1), summary(2), summary(3, waiting: 1), summary(4)]
      state = ready(conversations: waiting, overview: &quiet/1)
      {_, effects} = step(state, {:home, :next_need})
      assert [%{kind: {:conversation_open, id}}] = commands(effects, :conversation_open)
      assert id == summary(3).id
    end

    test "finds what the overview says waits in this project, though the list was taken before (UI-U-1)" do
      # the list (taken when Home opened) says nothing waits; a push refreshed the
      # overview, and the dot and the header read "1 needs you · Ctrl-N go"
      state = ready(overview: waiting_at(2))
      assert Enum.all?(state.conversations.items, &(&1.waiting == 0))

      {_, effects} = step(state, {:home, :next_need})
      assert [%{kind: {:conversation_open, id}}] = commands(effects, :conversation_open)
      assert id == summary(2).id
    end

    test "the conversation in view that waits closes Home and opens its card, even one put aside (UI-U-1)" do
      state =
        ready(overview: &quiet/1)
        |> workspace_ready(
          runs: [run("r", :waiting_approval)],
          interactions: [approval("a1")]
        )

      assert state.home != nil and state.layers == []
      {opened, _} = step(state, {:home, :next_need})
      assert opened.home == nil
      assert [{:approval, "a1"} | _] = opened.layers

      # an Esc'd card does not come back by itself; Ctrl-N brings it back
      aside = %{state | dismissed_interactions: [{"a1", 5}]}
      {closed, _} = step(aside, {:home, :escape})
      assert closed.home == nil and closed.layers == []

      {again, _} = step(aside, {:home, :next_need})
      assert again.home == nil
      assert [{:approval, "a1"} | _] = again.layers
    end

    test "every overview that refreshes Home asks the conversation list again (UI-U-1)" do
      state = ready()
      {state, effects} = stale(state, 9)
      assert [_] = queries(effects, :home_overview)

      assert [%{kind: {:conversation_list, nil, 50, 262_144}}] =
               queries(effects, :conversation_list)

      # a second push while both are out asks neither again
      {_, effects} = stale(state, 10)
      assert queries(effects, :conversation_list) == []
    end

    test "opens the conversation in view when that is the one that waits" do
      waiting = [summary(1, waiting: 1), summary(2)]
      {state, _} = step(ready(conversations: waiting), {:home, :next_need})
      assert state.home == nil
    end

    test "copies the command of one elsewhere when none here waits" do
      state = ready(overview: &quiet/1)

      overview =
        update_in(state.home.overview.projects, fn [here, there] ->
          [here, %{there | conversations: [%{hd(there.conversations) | waiting: 1}]}]
        end)

      {state, effects} =
        step(
          %{state | home: %{state.home | overview: overview.home.overview}},
          {:home, :next_need}
        )

      assert {:copy, "ncode ~/dev/llmotions -r 7c1e9a2b"} in effects
      assert state.home != nil
    end

    test "says so when nothing waits" do
      {state, effects} = step(ready(overview: &quiet/1), {:home, :next_need})
      assert effects == []
      assert state.notice == {:command_feedback, "Nothing waits for you."}
      assert state.home != nil
    end
  end

  describe "Ctrl-C" do
    test "clears the search, then the draft, then arms the quit, and a second press quits" do
      state = ready() |> focus(:focus_next)
      {state, _} = step(state, {:field_editor, Home.filter_key(), {:insert, "rate"}})
      assert state.home.filter == "rate"

      {state, _} = step(state, {:home, :interrupt})
      assert state.home.filter == ""
      assert state.quit_armed == nil

      state = state |> focus(:escape) |> typed("half a thought")
      {state, _} = step(state, {:home, :interrupt})
      assert home_draft(state) == ""
      assert state.quit_armed == nil

      {state, effects} = step(state, {:home, :interrupt})
      assert state.quit_armed != nil
      assert Enum.any?(effects, &match?({:start_timer, _, _, _}, &1))
      assert state.home != nil

      {state, effects} = step(state, {:home, :interrupt})
      assert state.lifecycle == :closing
      assert {:detach, 0} in effects
    end

    test "never stops the turn of the conversation underneath" do
      state = ready() |> workspace_ready(runs: [run("r", :streaming)])
      {state, effects} = step(state, {:home, :interrupt})
      assert commands(effects, :run_control) == []
      assert state.quit_armed != nil
    end
  end

  describe "layers and approvals over Home" do
    test "a pending approval does not open over Home, and opens as Home closes" do
      state =
        ready()
        |> workspace_ready(
          runs: [run("r", :waiting_approval)],
          interactions: [approval("a1")]
        )

      assert state.home != nil
      assert state.layers == []

      {state, _} = step(state, {:home, :escape})
      assert state.home == nil
      assert [{:approval, "a1"} | _] = state.layers
    end

    test "an approval opens when a destination change is what closes Home" do
      state =
        ready()
        |> workspace_ready(
          runs: [run("r", :waiting_approval)],
          interactions: [approval("a1")]
        )

      assert state.layers == []
      {state, _} = step(state, {:navigate, {:run, "r"}})
      assert state.home == nil
      assert [{:approval, "a1"} | _] = state.layers
    end

    test "help opens over Home and Home keeps its place" do
      state = ready() |> focus(:focus_next)
      {state, _} = key_press(state, Input.key({:function, 1}))
      assert state.layers == [:help]
      assert state.home.focus == :list
    end

    test "a runs-dashboard pick that changes the destination closes Home" do
      state = ready()
      {state, _} = key_press(state, Input.text_fragment(:press, "g", [:control]))
      assert [{:runs_dashboard, _} | _] = state.layers
      assert state.home != nil

      {state, _} = step(state, {:navigate, {:conversation, @new_id}})
      assert state.home == nil
    end
  end

  describe "the wheel" do
    test "moves the list's selection" do
      state = ready()
      {state, _} = step(state, {:scroll, "main", {:line, 3}})
      assert state.home.selected == 1
      {state, _} = step(state, {:scroll, "main", {:line, -3}})
      assert state.home.selected == 0
    end
  end

  describe "a draft of several lines" do
    test "keeps the arrows for the caret until it reaches the edge" do
      key = {"orbit-epoch", :home}
      state = ready() |> typed("one")
      {state, _} = step(state, {:editor, key, :newline})
      state = typed(state, "two")
      assert draft(state, key) == "one\ntwo"

      {up, _} = step(state, {:home, :up})
      assert up.home.selected == 0
      assert Editor.cursor(Drafts.fetch(up.drafts, key).editor) < 4

      {down, _} = step(up, {:home, :down})
      assert down.home.selected == 0

      {edge, _} = step(down, {:home, :down})
      assert edge.home.selected == 1
    end
  end

  describe "orbit int fixes" do
    test "conversation-scoped remote commands close Home and run on the conversation in view (UI-U-2)" do
      for text <-
            ~w(/stop /compact /fork /export /cost /resume-run) ++
              ["/rename Auth fix", "/model gpt-x", "/worker_model gpt-x", "/export notes.md"] do
        state = ready() |> workspace_ready() |> typed(text)
        {state, effects} = step(state, {:home, :enter})
        assert state.home == nil, "#{text} left Home open"
        assert commands(effects, :conversation_new) == [], "#{text} made a new conversation"
        assert [%{kind: {:dispatch, :send, ^text, :main, []}}] = commands(effects, :dispatch)
      end
    end

    test "work-starting text and commands still take the new-conversation path (D10)" do
      for text <- ["fix the flaky test", "/swarm audit the daemon", "/plan the refactor"] do
        state = ready() |> workspace_ready() |> typed(text)
        {state, effects} = step(state, {:home, :enter})
        assert [_new] = commands(effects, :conversation_new), "#{text} did not make one"
        assert state.home.pending_send == text
      end
    end

    test "a command bound to the conversation keeps that draft's collapsed pastes whole (UI-U-3)" do
      key = {conversation_id(), :main}
      pasted = Enum.map_join(1..60, "\n", &"line #{&1}")

      state = ready() |> workspace_ready()
      {state, _} = step(state, {:editor, key, {:insert, "explain "}})
      {state, _} = step(state, {:editor, key, {:paste, pasted}})
      before = Drafts.fetch(state.drafts, key)
      assert before.pastes == %{1 => pasted}
      assert draft(state, key) =~ "[Pasted text #1 · 60 lines]"

      state = typed(state, "/diff")
      {state, _} = step(state, {:home, :enter})
      assert state.home == nil

      after_draft = Drafts.fetch(state.drafts, key)
      assert after_draft.pastes == %{1 => pasted}
      assert Editor.text(after_draft.editor) == Editor.text(before.editor)
      assert home_draft(state) == ""
    end

    test "Alt-n with the map on another project copies its command instead of asking to open it (UI-U-4)" do
      state = ready() |> focus(:focus_next) |> focus(:focus_next) |> focus(:right)
      assert state.home.focus == :map and state.home.orbit == 1

      {state, effects} = step(state, {:home, {:open_row, 1}})
      assert {:copy, "ncode ~/dev/llmotions -r 7c1e9a2b"} in effects
      assert commands(effects, :conversation_open) == []
      assert state.home != nil
    end

    test "on this project's map the lit row and the bead Enter opens are the same conversation (UI-U-5)" do
      # the list also holds a conversation the overview does not (a scheduled task's),
      # newest first, so the overview's bead n is not the list's row n
      listed = [summary(5) | Enum.map(1..4, &summary/1)]
      state = ready(conversations: listed) |> focus(:focus_next) |> focus(:focus_next)
      assert state.home.focus == :map and state.home.bead == 0

      lit = fn state ->
        state |> Home.View.visible_list() |> Map.fetch!(:rows) |> Enum.find(& &1.selected?)
      end

      assert lit.(state).summary.id == summary(1).id

      state = focus(state, :down)
      assert state.home.bead == 1
      assert lit.(state).summary.id == summary(2).id

      {_, effects} = step(state, {:home, :enter})
      assert [%{kind: {:conversation_open, id}}] = commands(effects, :conversation_open)
      assert id == summary(2).id
    end

    test "picking the conversation Home sits on from the switcher closes Home (UI-U-7)" do
      state = ready()
      {state, _} = step(state, {:open_conversation, conversation_id()})
      assert state.home == nil
      assert state.destination == {:conversation, conversation_id()}
    end

    test "Alt-O right after a send that waits for the workspace neither drops nor fires it (UI-U-8)" do
      state = ready() |> workspace_ready() |> typed("fix the flaky test")
      {state, _} = step(state, {:home, :enter})
      {state, _} = step(state, {:navigate, {:conversation, @new_id}})
      assert state.home == nil
      assert state.deferred_send == {{@new_id, :main}, "fix the flaky test"}

      {state, _} = step(state, :open_home)
      assert state.home != nil
      assert state.deferred_send == {{@new_id, :main}, "fix the flaky test"}
      refute match?({:command_feedback, "Not sent" <> _}, state.notice)

      # the workspace loads under Home: the text is sent from the conversation's
      # draft, and Home stays open over it
      {state, effects} = workspace_delivered(state)
      assert state.deferred_send == nil
      assert state.home != nil

      assert [%{kind: {:dispatch, :send, "fix the flaky test", :main, []}}] =
               commands(effects, :dispatch)

      assert home_draft(state) == ""
    end

    test "a notice Home's own step set fades, and the deferred one is gone once it sent (SMOKE-F2)" do
      state = ready() |> workspace_ready() |> typed("fix the flaky test")
      {state, _} = step(state, {:home, :enter})
      {state, _} = step(state, {:navigate, {:conversation, @new_id}})

      words = "Sends once the conversation has loaded."
      assert state.notice == {:command_feedback, words}
      assert is_integer(state.notice_at)
      assert State.shown_notice(state) == {:command_feedback, words}
      assert State.shown_notice(%{state | now: state.now + 7_000}) == nil

      {state, _} = workspace_delivered(state)
      assert state.notice == nil
    end

    test "a smaller terminal leaves no orbit selected that is not drawn (UI-U-9)" do
      many = fn wire ->
        update_in(wire["projects"], fn [here, there] ->
          extra =
            for n <- 1..4 do
              %{
                there
                | "id" => "7c1e9a2b-0000-4000-8000-0000000001#{n}0",
                  "name" => "orbit-#{n}",
                  "conversations" => []
              }
            end

          [here, there | extra]
        end)
      end

      state = ready(size: {160, 44}, overview: many)
      assert length(Home.View.map_projects(state)) == 6

      state = state |> focus(:focus_next) |> focus(:focus_next)
      state = Enum.reduce(1..5, state, fn _, acc -> focus(acc, :right) end)
      assert state.home.orbit == 5

      {state, _} = step(state, {:resize, %SwarmCodeCLI.UI.Size{columns: 120, rows: 36}})
      assert length(Home.View.map_projects(state)) == 4
      assert state.home.orbit == 3
      assert state.home.focus == :map
      assert %{project: %{name: "orbit-2"}} = Home.View.map_target(state)

      {state, effects} = step(state, {:resize, %SwarmCodeCLI.UI.Size{columns: 60, rows: 16}})
      assert Home.View.map_projects(state) == []
      assert state.home.focus == :composer
      assert commands(effects, :conversation_open) == []
    end
  end
end
