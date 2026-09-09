defmodule SwarmCodeCLI.UI.KeymapTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Keymap, Input, State, Size, Capabilities}

  def state,
    do: %State{
      size: %Size{columns: 120, rows: 40},
      capabilities: %Capabilities{size: %Size{columns: 120, rows: 40}},
      destination: {:conversation, "c"},
      focus: "composer"
    }

  test "paste and committed repeats edit only the active editor; release and mouse are inert" do
    state = state()

    assert {:ok, {:editor, {"c", :main}, {:paste, "hello\n"}}} =
             Keymap.resolve(Input.paste("hello\n"), state, %{})

    state = %{state | layers: [{:switcher, "switch"}], focus: "query"}

    assert {:ok, {:field_editor, {:layer_query, "switch", :switcher}, {:paste, "hello\n"}}} =
             Keymap.resolve(Input.paste("hello\n"), state, %{})

    assert {:ok, {:field_editor, _, {:insert, "x"}}} =
             Keymap.resolve(Input.text_fragment(:repeat, "x", []), state, %{})

    assert :ignore = Keymap.resolve(Input.text_fragment(:release, "x", []), state, %{})
    assert :ignore = Keymap.resolve({:mouse, :press, :left, 1, 2, []}, state, %{})
  end

  test "Enter activates only an authorized current target on press; newline is capability gated" do
    state = state()
    intent = {:dispatch, :send, "hello", :main, []}
    table = %{"opaque" => {:intent, intent}}
    assert {:ok, {:invoke, ^intent, id}} = Keymap.resolve(Input.key(:enter), state, table)
    assert id == elem(State.next_id(state, :request), 0)
    assert :ignore = Keymap.resolve(Input.key(:enter), state, %{})

    for phase <- [:repeat, :release],
        do: assert(:ignore == Keymap.resolve(Input.key(phase, :enter, []), state, table))

    assert {:ok, {:editor, _, :newline}} =
             Keymap.resolve(Input.text_fragment(:press, "o", [:control]), state, table)

    assert :ignore = Keymap.resolve(Input.key(:enter, [:shift]), state, table)
    enhanced = %{state | capabilities: %{state.capabilities | enhanced_keys: :supported}}

    assert {:ok, {:editor, _, :newline}} =
             Keymap.resolve(Input.key(:enter, [:shift]), enhanced, table)
  end

  test "Tab from the conversation transcript goes directly to the composer" do
    for columns <- [80, 120, 170] do
      size = %Size{columns: columns, rows: 40}
      current = %{state() | focus: "main", size: size, capabilities: %Capabilities{size: size}}

      assert {:ok, {:focus_region, "composer"}} =
               Keymap.resolve(Input.key(:tab), current, %{})
    end
  end

  test "single Escape, editor interrupt notice and generation-correlated focus" do
    state = state()

    assert {:ok, :editor_detach_notice} =
             Keymap.resolve(Input.text_fragment(:press, "c", [:control]), state, %{})

    assert {:ok, {:quit_requested, :detach}} =
             Keymap.resolve(
               Input.text_fragment(:press, "c", [:control]),
               %{state | focus: "main"},
               %{}
             )

    assert {:ok, :close_top_layer} =
             Keymap.resolve(Input.key(:escape), %{state | layers: [:help, :help]}, %{})

    assert {:ok, {:terminal_focus, :lost, 9}} =
             Keymap.resolve(:focus_lost, %{state | terminal_generation: 9}, %{})
  end

  test "modal Cancel wins over composer and bare Enter never confirms destructive action" do
    state = %{state() | layers: [{:unsent_changes, :detach}], focus: "cancel"}

    table = %{
      "cancel" => {:local, :close_top_layer},
      "confirm" => {:local, {:quit_confirmed, :detach}}
    }

    assert {:ok, :close_top_layer} = Keymap.resolve(Input.key(:enter), state, table)

    assert {:ok, {:quit_confirmed, :detach}} =
             Keymap.resolve(Input.key(:enter), %{state | focus: "confirm"}, table)

    assert :ignore =
             Keymap.resolve(Input.key(:repeat, :enter, []), %{state | focus: "confirm"}, table)
  end

  test "stop run and stop agent need independent authorized confirmation; repeat cannot open it" do
    state = %{state() | focus: "main"}
    run = {:run_control, :stop, "r"}
    agent = {:stop_agent, "r", "a", 7}
    table = %{"run" => {:intent, run}, "agent" => {:intent, agent}}

    assert {:ok, {:open_layer, {:confirm_intent, ^run}}} =
             Keymap.activate({:intent, run}, state, table)

    assert {:ok, {:open_layer, {:confirm_intent, ^agent}}} =
             Keymap.activate({:intent, agent}, state, table)

    assert :ignore = Keymap.activate({:intent, agent}, state, %{"run" => {:intent, run}})
    modal = %{state | layers: [{:confirm_intent, agent}], focus: "cancel"}
    assert {:ok, :close_top_layer} = Keymap.resolve(Input.key(:enter), modal, table)

    assert {:ok, {:invoke, ^agent, _}} =
             Keymap.resolve(Input.key(:enter), %{modal | focus: "confirm"}, table)

    assert :ignore = Keymap.resolve(Input.text_fragment(:repeat, "x", []), state, table)
  end

  test "queue shortcut equals slash queue catalogue target and modal fields block globals" do
    state = state()
    intent = {:dispatch, :queue, "hello", :main, []}
    table = %{"queue" => {:intent, intent}}

    assert Keymap.resolve(Input.key(:enter, [:alt]), state, table) ==
             Keymap.activate({:intent, intent}, state, table)

    modal = %{state | layers: [{:switcher, "s"}], focus: "query"}
    assert :ignore = Keymap.resolve(Input.text_fragment(:press, "b", [:control]), modal, table)

    assert {:ok, {:field_editor, _, {:insert, "q"}}} =
             Keymap.resolve(Input.text_fragment(:press, "q", []), modal, table)
  end

  test "detail pager activates only displayed page actions" do
    state = %{state() | layers: [{:detail, "r", "ref"}], focus: "next"}
    table = %{"next" => {:local, {:detail_page, :next}}}
    assert {:ok, {:detail_page, :next}} = Keymap.resolve(Input.key(:enter), state, table)
    assert :ignore = Keymap.resolve(Input.key(:enter), state, %{})
  end

  test "query Left edits cursor while Down traverses modal choices" do
    state = %{state() | layers: [{:switcher, "s"}], focus: "query"}

    assert {:ok, {:field_editor, {:layer_query, "s", :switcher}, {:move, :left}}} =
             Keymap.resolve(Input.key(:left), state, %{})

    assert {:ok, {:focus_cycle, :next}} = Keymap.resolve(Input.key(:down), state, %{})
  end

  test "run controls target the selected run instead of another authorized run" do
    alias SwarmCodeCLI.UI.DataSource.DTO
    state = %{state() | focus: "main", selection: %{"main" => "selected"}}

    state = %{
      state
      | read_model: %{
          state.read_model
          | runs: %{
              "selected" => %DTO.RunSummary{id: "selected"},
              "other" => %DTO.RunSummary{id: "other"}
            }
        }
    }

    table = %{
      "a" => {:intent, {:run_control, :pause, "other"}},
      "z" => {:intent, {:run_control, :pause, "selected"}}
    }

    assert {:ok, {:invoke, {:run_control, :pause, "selected"}, _}} =
             Keymap.resolve(Input.text_fragment(:press, "p", []), state, table)
  end

  test "narrow Inspector Enter opens confirmation for the exact focused agent" do
    alias SwarmCodeCLI.UI.{Fixtures, Projector}
    size = %Size{columns: 72, rows: 20}
    state = Fixtures.representative(:swarm, size, %Capabilities{size: size})
    state = %{state | layers: [{:run_inspector, "fixture-run", :agents}], focus: "agent-1"}
    {_, table} = Projector.project(state)
    intent = {:stop_agent, "fixture-run", "agent-1", 1}
    assert {:intent, intent} in Map.values(table)

    assert {:ok, {:open_layer, {:confirm_intent, ^intent}}} =
             Keymap.resolve(Input.key(:enter), state, table)

    assert :ignore = Keymap.resolve(Input.key(:repeat, :enter, []), state, table)
    assert :ignore = Keymap.resolve(Input.key(:enter), state, %{})
    other = Map.reject(table, fn {_, target} -> target == {:intent, intent} end)
    assert :ignore = Keymap.resolve(Input.key(:enter), state, other)
  end

  test "tiny unsent confirmation accepts only explicit X press for its pending exit kind" do
    alias SwarmCodeCLI.UI.Projector

    for {columns, rows} <- [{1, 1}, {10, 3}, {49, 13}], kind <- [:detach, :plain] do
      size = %Size{columns: columns, rows: rows}

      state = %{
        state()
        | size: size,
          capabilities: %Capabilities{size: size},
          layers: [{:unsent_changes, kind}],
          exit_pending: kind,
          focus: "cancel"
      }

      {_, table} = Projector.project(state)
      assert table == %{}

      action =
        if kind == :detach,
          do: {:quit_confirmed, :detach},
          else: {:presenter_handoff_confirmed, :plain}

      for modifiers <- [[], [:shift]],
          do:
            assert(
              {:ok, action} ==
                Keymap.resolve(Input.text_fragment(:press, "X", modifiers), state, table)
            )

      for phase <- [:repeat, :release],
          do: assert(:ignore == Keymap.resolve(Input.text_fragment(phase, "X", []), state, table))

      assert :ignore = Keymap.resolve(Input.text_fragment(:press, "x", []), state, table)

      assert :ignore =
               Keymap.resolve(
                 Input.text_fragment(:press, "X", []),
                 %{state | exit_pending: nil},
                 table
               )

      for focus <- ["cancel", "confirm"],
          do: assert(:ignore == Keymap.resolve(Input.key(:enter), %{state | focus: focus}, table))

      assert {:ok, :close_top_layer} = Keymap.resolve(Input.key(:escape), state, table)
    end
  end
end
