defmodule SwarmCodeCLI.UI.ComposerFirstTest do
  @moduledoc """
  Pass 70 E1/E2: the composer keeps the caret. Letters always type, Esc stops
  a streaming turn or closes the top layer, Ctrl-C is a ladder, Ctrl-T is
  select mode, and approvals open over the conversation with their own keys.
  Every key goes through `Keymap.resolve/3` and `Reducer.update/2`, as it does
  in the session.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Capabilities, Drafts, Editor, Init, Input, Keymap, Reducer, Size}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Delivery, Delta}

  @key {"c", :main}

  # ------------------------------------------------------------------ fixtures

  defp run(id, state, opts \\ []) do
    %DTO.RunSummary{
      id: id,
      conversation_id: Keyword.get(opts, :conversation, "c"),
      state: state,
      revision: 3,
      kind: :chat,
      started_at: Keyword.get(opts, :started_at, 1),
      allowed_actions: Keyword.get(opts, :actions, [:stop, :pause])
    }
  end

  defp approval(id, opts \\ []) do
    item = %DTO.PendingInteraction{
      id: id,
      kind: :approval,
      run_id: Keyword.get(opts, :run, "r"),
      node_id: "op-1",
      conversation_id: Keyword.get(opts, :conversation, "c"),
      expected_revision: Keyword.get(opts, :revision, 5),
      created_at: Keyword.get(opts, :created_at, 1),
      allowed_actions: [:approve, :deny, :always_allow],
      approval: %DTO.Approval{
        tool: "run_command",
        permission: :execute,
        arguments_preview: "ls -la notes"
      }
    }

    item
  end

  # `allowed_decisions` is owner C's pass-70 wire field; until it is a DTO
  # field the reducer reads it with Map.get, so it is put on the read model
  # directly rather than sent through a validated delivery.
  defp with_decisions(state, id, decisions) do
    item = Map.put(state.read_model.interactions[id], :allowed_decisions, decisions)

    %{
      state
      | read_model: %{
          state.read_model
          | interactions: Map.put(state.read_model.interactions, id, item)
        }
    }
  end

  defp initial(runs, interactions \\ [], transcript \\ []) do
    size = %Size{columns: 150, rows: 40}

    {state, _} =
      Reducer.init(%Init{
        size: size,
        capabilities: %Capabilities{size: size},
        source_epoch: "e",
        destination: {:conversation, "c"},
        focus: "composer"
      })

    watch = state.watches.workspace

    body = %DTO.WorkspaceSnapshot{
      conversation_id: "c",
      allowed_actions: [:send, :queue],
      runs: runs,
      interactions: interactions,
      transcript: %DTO.TranscriptWindow{items: transcript},
      runs_page: %DTO.PageInfo{},
      interactions_page: %DTO.PageInfo{}
    }

    delivery = %Delivery{
      kind: :watch_ready,
      watch_ref: watch.watch_ref,
      request_id: nil,
      scope: watch.scope,
      generation: watch.generation,
      revision: 0,
      sequence: nil,
      body: body
    }

    {state, effects} = Reducer.update(state, {:data, delivery})
    {state, effects}
  end

  defp ready(runs, interactions \\ [], transcript \\ []) do
    {state, _} = initial(runs, interactions, transcript)
    state
  end

  defp press(state, input) do
    case Keymap.resolve(input, state, %{}) do
      {:ok, action} -> Reducer.update(state, action)
      :ignore -> {state, []}
    end
  end

  defp press!(state, input), do: elem(press(state, input), 0)
  defp letter(text, mods \\ []), do: Input.text_fragment(:press, text, mods)
  defp ctrl(text), do: letter(text, [:control])
  defp text(state), do: Editor.text(Drafts.fetch(state.drafts, @key).editor)

  defp type(state, text),
    do: text |> String.graphemes() |> Enum.reduce(state, &press!(&2, letter(&1)))

  defp commands(effects), do: for({:command, request} <- effects, do: request.kind)

  defp timer(effects),
    do:
      Enum.find_value(effects, fn
        {:start_timer, id, _, _} -> id
        _ -> nil
      end)

  defp delta(state, kind, body) do
    watch = state.watches.workspace
    run_id = if kind == :run_update, do: body.id, else: body.run_id

    %Delivery{
      kind: :delta,
      watch_ref: watch.watch_ref,
      request_id: nil,
      scope: watch.scope,
      generation: watch.generation,
      revision: 1,
      sequence: watch.sequence + 1,
      body: %Delta{
        kind: kind,
        entity_id: body.id,
        run_id: run_id,
        conversation_id: body.conversation_id,
        body: body,
        revision: 1,
        sequence: watch.sequence + 1
      }
    }
  end

  # ---------------------------------------------------------------- Esc

  describe "Esc" do
    test "stops a streaming turn and keeps the caret and the draft in the composer" do
      state = ready([run("r", :streaming)]) |> type("keep me")
      {next, effects} = press(state, Input.key(:escape))

      assert [{:run_control, :stop, "r"}] = commands(effects)
      assert next.focus == "composer"
      assert text(next) == "keep me"
    end

    test "does nothing at all when no turn is generating" do
      for idle <- [run("r", :done), run("r", :waiting_approval), run("r", :running, actions: [])] do
        state = ready([idle])
        assert {^state, []} = press(state, Input.key(:escape))
      end
    end

    test "a run another run launched is not the turn" do
      child = %{run("child", :running) | parent_run_id: "parent"}
      state = ready([run("parent", :done), child])
      assert {_, []} = press(state, Input.key(:escape))
    end

    test "typing after Esc types: please is a word, not four commands" do
      state = ready([run("r", :done)])
      state = press!(state, Input.key(:escape)) |> type("please")
      assert text(state) == "please"
      assert state.focus == "composer"
      assert state.layers == []
    end
  end

  # ------------------------------------------------------------- Ctrl-C

  describe "the Ctrl-C ladder" do
    test "first press clears the draft (undoably) and arms; second press quits" do
      state = ready([]) |> type("hello")
      {state, effects} = press(state, ctrl("c"))
      assert text(state) == ""
      assert is_binary(state.quit_armed)
      assert timer(effects) == state.quit_armed

      state = press!(state, ctrl("z"))
      assert text(state) == "hello"

      state = press!(state, ctrl("c"))
      {state, effects} = press(state, ctrl("c"))
      assert state.lifecycle == :closing
      assert {:detach, 0} in effects
    end

    test "with an empty draft it stops the turn, and the window closes after its timer" do
      state = ready([run("r", :waiting_approval)])
      {state, effects} = press(state, ctrl("c"))
      assert [{:run_control, :stop, "r"}] = commands(effects)
      armed = state.quit_armed

      {state, []} = Reducer.update(state, {:timer_fired, armed})
      assert state.quit_armed == nil

      # A fresh first press again: it does not quit.
      {state, _} = press(state, ctrl("c"))
      assert state.lifecycle == :running
    end

    test "quitting with live runs asks, and a third press confirms" do
      state = ready([run("r", :running, actions: []), run("s", :paused, actions: [])])
      state = press!(state, ctrl("c")) |> press!(ctrl("c"))

      assert [{:unsent_changes, :detach} | _] = state.layers
      assert state.quit_live_runs == 2
      assert state.lifecycle == :running

      {state, effects} = press(state, ctrl("c"))
      assert state.lifecycle == :closing
      assert {:detach, 0} in effects
    end

    test "a layer closes first" do
      state = ready([]) |> press!(Input.key({:function, 1}))
      assert state.layers == [:help]
      state = press!(state, ctrl("c"))
      assert state.layers == []
      assert state.lifecycle == :running
    end
  end

  # --------------------------------------------------------- select mode

  describe "select mode" do
    test "Ctrl-T selects the newest row; an unused letter types; Esc and Ctrl-T come back" do
      items = [
        %DTO.TranscriptItem{
          id: "t1",
          run_id: "r",
          conversation_id: "c",
          node_id: "n1",
          attempt_id: "at",
          text: "one"
        },
        %DTO.TranscriptItem{
          id: "t2",
          run_id: "r",
          conversation_id: "c",
          node_id: "n2",
          attempt_id: "at",
          text: "two"
        }
      ]

      state = ready([run("r", :done)], [], items)
      selected = press!(state, ctrl("t"))
      assert selected.focus == "main"
      assert selected.selection["main"] == "t2"

      typed = press!(selected, letter("z"))
      assert typed.focus == "composer"
      assert text(typed) == "z"

      assert press!(selected, Input.key(:escape)).focus == "composer"
      assert press!(selected, ctrl("t")).focus == "composer"
    end

    test "y copies the selected row through the runtime" do
      items = [
        %DTO.TranscriptItem{
          id: "t1",
          run_id: "r",
          conversation_id: "c",
          node_id: "n1",
          attempt_id: "at",
          text: "copy me\nplease"
        }
      ]

      state = ready([run("r", :done)], [], items) |> press!(ctrl("t"))
      assert {_, [{:copy, "copy me\nplease"}]} = press(state, letter("y"))
    end

    test "q quits only from select mode; in the composer it is a letter" do
      state = ready([])
      assert text(press!(state, letter("q"))) == "q"

      {quit, effects} = state |> press!(ctrl("t")) |> press(letter("q"))
      assert quit.lifecycle == :closing
      assert {:detach, 0} in effects
    end
  end

  # ------------------------------------------------------------ scrolling

  test "PgUp/PgDn and Ctrl-U/D on an empty draft scroll the transcript from the composer" do
    state = ready([])

    for {input, operation} <- [
          {Input.key(:page_up), {:page, -1}},
          {Input.key(:page_down), {:page, 1}},
          {ctrl("u"), {:half_page, -1}},
          {ctrl("d"), {:half_page, 1}}
        ] do
      assert Keymap.resolve(input, state, %{}) == {:ok, {:scroll, "main", operation}}
    end

    assert {:ok, {:editor, @key, :newline}} = Keymap.resolve(ctrl("j"), state, %{})
  end

  test "Tab queues the draft behind a running turn and otherwise stays put" do
    idle = ready([]) |> type("next")
    assert Keymap.resolve(Input.key(:tab), idle, %{}) == :ignore

    busy = ready([run("r", :streaming)]) |> type("next")
    {_, effects} = press(busy, Input.key(:tab))
    assert [{:dispatch, :queue, "next", :main, []}] = commands(effects)
  end

  # ------------------------------------------------------------ approvals

  describe "approvals" do
    test "a pending approval opens over the conversation without navigating" do
      {state, effects} = initial([run("r", :waiting_approval)], [approval("a1")])
      assert [{:approval, "a1"} | _] = state.layers
      assert state.destination == {:conversation, "c"}
      assert state.auto_opened == "a1"
      assert timer(effects) == state.interaction_grace
    end

    test "keys typed before the user pauses keep typing into the draft" do
      {state, _} = initial([run("r", :waiting_approval)], [approval("a1")])
      state = type(state, "yes do it")
      assert text(state) == "yes do it"
      assert [{:approval, "a1"} | _] = state.layers

      {state, []} = Reducer.update(state, {:timer_fired, state.interaction_grace})
      {_, effects} = press(state, letter("y"))
      assert [{:resolve_approval, "r", "op-1", "a1", 5, :approve}] = commands(effects)
    end

    test "y Y A d D map to the decisions the approval offers" do
      decisions = [:approve, :approve_run, :always_prefix, :deny, :deny_stop]

      {state, _} = initial([run("r", :waiting_approval)], [approval("a1")])
      state = %{with_decisions(state, "a1", decisions) | interaction_grace: nil}

      for {key, decision} <- [
            {"y", :approve},
            {"Y", :approve_run},
            {"A", :always_prefix},
            {"d", :deny},
            {"D", :deny_stop}
          ] do
        {_, effects} = press(state, letter(key))
        assert [{:resolve_approval, "r", "op-1", "a1", 5, ^decision}] = commands(effects)
      end
    end

    test "an older source without allowed_decisions keeps approve, deny and always" do
      {state, _} = initial([run("r", :waiting_approval)], [approval("a1")])
      state = %{state | interaction_grace: nil}

      {_, effects} = press(state, letter("A"))
      assert [{:resolve_approval, _, _, _, _, :always_allow}] = commands(effects)
      assert {_, []} = press(state, letter("Y"))
      assert {_, []} = press(state, letter("D"))
    end

    test "Esc puts it aside until Ctrl-N; a settled one closes by itself" do
      {state, _} = initial([run("r", :waiting_approval)], [approval("a1")])
      state = press!(state, Input.key(:escape))
      assert state.layers == []
      assert state.focus == "composer"

      # Data that changes nothing about it does not bring it back.
      {state, _} =
        Reducer.update(state, {:data, delta(state, :run_update, run("r", :waiting_approval))})

      assert state.layers == []

      state = press!(state, ctrl("n"))
      assert [{:approval, "a1"} | _] = state.layers
      assert state.auto_opened == nil

      settled = %{approval("a1") | state: :resolved, allowed_actions: []}
      {state, _} = Reducer.update(state, {:data, delta(state, :interaction_upsert, settled)})
      assert state.layers == []
    end

    test "n on an approval walks to the next one waiting" do
      {state, _} =
        initial(
          [run("r", :waiting_approval)],
          [approval("a1"), approval("a2", created_at: 2)]
        )

      state = %{state | interaction_grace: nil}
      assert [{:approval, "a1"} | _] = state.layers
      state = press!(state, letter("n"))
      assert [{:approval, "a2"} | _] = state.layers
    end

    test "an interaction of another conversation does not open by itself" do
      {state, _} =
        initial([run("r", :waiting_approval)], [approval("a1", conversation: "elsewhere")])

      assert state.layers == []
    end
  end

  # ------------------------------------------------------- prompt history

  describe "prompt history" do
    test "Up on an empty draft recalls sent prompts, newest first; Down comes back" do
      user = %DTO.TranscriptItem{
        id: "u1",
        run_id: "r",
        conversation_id: "c",
        node_id: "n",
        attempt_id: "at",
        role: :user,
        state: :done,
        text: "from the transcript"
      }

      state = ready([run("r", :done)], [], [user]) |> type("fresh")
      intent = {:dispatch, :send, "fresh", :main, []}
      {state, [{:command, request}]} = Reducer.update(state, {:invoke, intent, "sent-1"})

      response = %Delivery{
        kind: :response,
        request_id: "sent-1",
        watch_ref: nil,
        scope: request.scope,
        generation: request.generation,
        revision: nil,
        sequence: nil,
        body: %DTO.Outcome{request_id: "sent-1", status: :accepted}
      }

      {state, _} = Reducer.update(state, {:data, response})
      assert text(state) == ""

      state = press!(state, Input.key(:up))
      assert text(state) == "fresh"
      state = press!(state, Input.key(:up))
      assert text(state) == "from the transcript"
      state = press!(state, Input.key(:up))
      assert text(state) == "from the transcript"
      state = press!(state, Input.key(:down)) |> press!(Input.key(:down))
      assert text(state) == ""
      assert state.history_cursor == nil
    end

    test "editing a recalled prompt makes it the draft again" do
      user = %DTO.TranscriptItem{
        id: "u1",
        run_id: "r",
        conversation_id: "c",
        node_id: "n",
        attempt_id: "at",
        role: :user,
        state: :done,
        text: "abc"
      }

      state = ready([run("r", :done)], [], [user]) |> press!(Input.key(:up)) |> type("d")
      assert text(state) == "abcd"
      assert state.history_cursor == nil
      # Up now moves the caret on a one-line draft rather than replacing it.
      assert text(press!(state, Input.key(:up))) == "abcd"
    end
  end

  # ------------------------------------------------ client slash commands

  describe "slash commands the session answers itself" do
    defp send_draft(state, text) do
      state = type(state, text)
      intent = {:dispatch, :send, text, :main, []}
      {:ok, action} = Keymap.activate({:intent, intent}, state, %{"send" => {:intent, intent}})
      Reducer.update(state, action)
    end

    test "/help opens the sheet and clears the draft" do
      {state, _} = send_draft(ready([]), "/help")
      assert [:help | _] = state.layers
      assert text(state) == ""
    end

    test "/quit quits like q in select mode" do
      {state, effects} = send_draft(ready([]), "/quit")
      assert state.lifecycle == :closing
      assert {:detach, 0} in effects
    end

    test "/queue sends its message as a queued follow-up" do
      {state, effects} = send_draft(ready([run("r", :streaming)]), "/queue then run the tests")
      assert [{:dispatch, :queue, "then run the tests", :main, []}] = commands(effects)
      assert text(state) == "then run the tests"
    end

    test "every other slash command still goes to the daemon" do
      state = type(ready([]), "/stop")
      intent = {:dispatch, :send, "/stop", :main, []}

      assert {:ok, {:invoke, ^intent, _}} =
               Keymap.activate({:intent, intent}, state, %{"send" => {:intent, intent}})
    end
  end
end
