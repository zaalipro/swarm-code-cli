defmodule SwarmCodeCLI.UI.KeymapTest do
  use ExUnit.Case, async: true
  alias SwarmCodeCLI.UI.{Capabilities, Input, Keymap, Reducer, Size, State}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Keymap.Context

  def state,
    do: %State{
      size: %Size{columns: 120, rows: 40},
      capabilities: %Capabilities{size: %Size{columns: 120, rows: 40}},
      destination: {:conversation, "c"},
      focus: "composer"
    }

  defp main, do: %{state() | focus: "main"}

  defp letter(text, mods \\ []), do: Input.text_fragment(:press, text, mods)

  defp with_runs(state, ids) do
    runs =
      Map.new(ids, fn id ->
        {id, %DTO.RunSummary{id: id, conversation_id: "c-" <> id, title: id, kind: :chat}}
      end)

    %{
      state
      | read_model: %{state.read_model | runs: runs, order: %{shell: ids}},
        watches:
          Map.new(
            [:shell, :workspace, :activity, :inspector],
            &{&1, %SwarmCodeCLI.UI.WatchState{}}
          )
    }
  end

  # ------------------------------------------------------------------ contexts

  describe "contexts" do
    test "every state names exactly one context, and a picker beats its own field" do
      assert Context.of(state()) == :composer
      assert Context.of(main()) == :main
      assert Context.of(%{main() | focus: "inspector"}) == :inspector
      assert Context.of(%{main() | layers: [:help]}) == :dialog
      assert Context.of(%{main() | layers: [{:switcher, "s"}], focus: "query"}) == :picker
      assert Context.of(%{main() | layers: [{:jump, "j"}], focus: "jump_top"}) == :picker
      assert Context.of(%{main() | layers: [{:runs_dashboard, "d"}]}) == :picker

      # A question's "other" box is a field even though the layer is a dialog.
      question = question_state()
      assert Context.of(%{question | focus: "cancel"}) == :dialog
      assert Context.of(%{question | focus: "other"}) == :field
    end

    test "the vim modes only exist while the vim keymap is on" do
      composer = state()
      assert Context.of(%{composer | vim: %SwarmCodeCLI.UI.Vim{mode: :normal}}) == :composer

      vim = %{composer | keymap: :vim}
      assert Context.of(vim) == :composer
      assert Context.of(%{vim | vim: %SwarmCodeCLI.UI.Vim{mode: :normal}}) == :composer_normal
      assert Context.of(%{vim | vim: %SwarmCodeCLI.UI.Vim{mode: :visual}}) == :composer_visual
    end
  end

  # -------------------------------------------------------------------- escape

  describe "Esc" do
    test "never yields :back and never navigates, from any context" do
      states = [
        state(),
        main(),
        %{main() | focus: "inspector"},
        %{main() | layers: [:help]},
        %{main() | layers: [{:switcher, "s"}], focus: "query"},
        %{main() | layers: [{:jump, "j"}], focus: "jump_top"},
        question_state()
      ]

      for current <- states do
        refute Keymap.resolve(Input.key(:escape), current, %{}) == {:ok, :back}
      end
    end

    test "steps out one level: filter, then layer, then composer" do
      dashboard = %{main() | layers: [{:runs_dashboard, "d"}]}
      assert Keymap.resolve(Input.key(:escape), dashboard, %{}) == {:ok, :close_top_layer}

      typed = State.put_runs_filter(dashboard, "auth")
      assert Keymap.resolve(Input.key(:escape), typed, %{}) == {:ok, {:dashboard_filter, :clear}}

      assert Keymap.resolve(Input.key(:escape), %{main() | layers: [:help, :help]}, %{}) ==
               {:ok, :close_top_layer}

      assert Keymap.resolve(Input.key(:escape), state(), %{}) == {:ok, {:focus_region, "main"}}
      assert Keymap.resolve(Input.key(:escape), main(), %{}) == :ignore
    end

    test "Alt-Left and Backspace carry :back, and only in main or the inspector" do
      for current <- [main(), %{main() | focus: "inspector"}],
          input <- [Input.key(:left, [:alt]), Input.key(:backspace)] do
        assert Keymap.resolve(input, current, %{}) == {:ok, :back}
      end

      # In the composer Backspace deletes; in a dialog it is unbound.
      assert {:ok, {:editor, _, :delete_backward}} =
               Keymap.resolve(Input.key(:backspace), state(), %{})

      assert Keymap.resolve(Input.key(:backspace), %{main() | layers: [:help]}, %{}) == :ignore
    end
  end

  # ------------------------------------------------------------- close vs quit

  describe "q" do
    test "closes the top layer and only quits when there is none" do
      assert Keymap.resolve(letter("q"), main(), %{}) == {:ok, {:quit_requested, :detach}}

      for layer <- [:help, {:detail, "r", "ref"}, {:run_inspector, "r", :agents}] do
        assert Keymap.resolve(letter("q"), %{main() | layers: [layer]}, %{}) ==
                 {:ok, :close_top_layer}
      end
    end

    test "types rather than closes wherever a text field would take it" do
      assert {:ok, {:editor, _, {:insert, "q"}}} = Keymap.resolve(letter("q"), state(), %{})

      switcher = %{main() | layers: [{:switcher, "s"}], focus: "query"}

      assert {:ok, {:field_editor, _, {:insert, "q"}}} =
               Keymap.resolve(letter("q"), switcher, %{})

      palette = %{main() | layers: [{:run_palette, "p"}]}

      assert Keymap.resolve(letter("q"), palette, %{}) ==
               {:ok, {:dashboard_filter, {:append, "q"}}}
    end

    test "closes the dashboard while its filter is empty and types once it is not" do
      dashboard = %{main() | layers: [{:runs_dashboard, "d"}]}
      assert Keymap.resolve(letter("q"), dashboard, %{}) == {:ok, :close_top_layer}

      typed = State.put_runs_filter(dashboard, "auth")

      assert Keymap.resolve(letter("q"), typed, %{}) ==
               {:ok, {:dashboard_filter, {:append, "q"}}}
    end

    test "b closes nothing any more" do
      for current <- [%{main() | layers: [:help]}, %{main() | layers: [{:runs_dashboard, "d"}]}] do
        refute Keymap.resolve(letter("b"), current, %{}) == {:ok, :close_top_layer}
      end
    end
  end

  # ---------------------------------------------------------------- the layers

  describe "layer chords" do
    test "Ctrl-P, Ctrl-G and Ctrl-R each toggle their own layer shut" do
      for {mods_key, kind} <- [{"p", :switcher}, {"g", :runs_dashboard}, {"r", :run_palette}] do
        assert {:ok, {:open_layer, {^kind, _}}} =
                 Keymap.resolve(letter(mods_key, [:control]), main(), %{})

        open = %{main() | layers: [{kind, "layer"}]}
        assert Keymap.resolve(letter(mods_key, [:control]), open, %{}) == {:ok, :close_top_layer}
      end
    end

    test "Ctrl chords reach through a modal's text field; bare letters do not" do
      modal = %{state() | layers: [{:switcher, "s"}], focus: "query"}

      # Ctrl-B is a global chord: it toggles the dock from every context.
      assert Keymap.resolve(letter("b", [:control]), modal, %{}) ==
               {:ok, {:toggle_dock, :inspector}}

      # "?" is a printable key, so inside a field it is typing, not help.
      assert {:ok, {:field_editor, _, {:insert, "?"}}} = Keymap.resolve(letter("?"), modal, %{})
      assert Keymap.resolve(Input.key({:function, 1}), modal, %{}) == {:ok, {:open_layer, :help}}
      assert Keymap.resolve(letter("?"), main(), %{}) == {:ok, {:open_layer, :help}}
    end

    test "Ctrl-C detaches outside an editor and warns inside one" do
      assert Keymap.resolve(letter("c", [:control]), state(), %{}) ==
               {:ok, :editor_detach_notice}

      assert Keymap.resolve(letter("c", [:control]), main(), %{}) ==
               {:ok, {:quit_requested, :detach}}
    end
  end

  # ---------------------------------------------------------------------- runs

  describe "runs" do
    test "g opens the which-key popup and its second key acts" do
      assert {:ok, {:open_layer, {:jump, _}}} = Keymap.resolve(letter("g"), main(), %{})

      jump = %{main() | layers: [{:jump, "j"}], focus: "jump_top"}
      assert Keymap.resolve(letter("g"), jump, %{}) == {:ok, {:move, :first}}
      assert Keymap.resolve(letter("G"), jump, %{}) == {:ok, {:move, :last}}
      assert Keymap.resolve(letter("t"), jump, %{}) == {:ok, {:run_tab, :next}}
      assert Keymap.resolve(letter("T"), jump, %{}) == {:ok, {:run_tab, :previous}}
    end

    test "the popup's keys type into every other picker's filter" do
      palette = %{main() | layers: [{:run_palette, "p"}]}

      for text <- ["g", "G", "t", "T"] do
        assert Keymap.resolve(letter(text), palette, %{}) ==
                 {:ok, {:dashboard_filter, {:append, text}}}
      end
    end

    test "Alt-1..4 pick a run tab, and no longer set inspector tabs" do
      for {text, position} <- [{"1", 1}, {"2", 2}, {"3", 3}, {"4", 4}] do
        assert Keymap.resolve(letter(text, [:alt]), main(), %{}) == {:ok, {:run_tab, position}}
      end
    end

    test "[ and ] move inspector tabs whenever the inspector is on screen" do
      # 120x40 is :medium, which docks the inspector only when asked to.
      undocked = main()
      assert Keymap.resolve(letter("]"), undocked, %{}) == :ignore

      docked = %{
        undocked
        | preferences: %{undocked.preferences | medium_dock: :inspector}
      }

      assert Keymap.resolve(letter("]"), docked, %{}) == {:ok, {:inspector_tab, :next}}
      assert Keymap.resolve(letter("["), docked, %{}) == {:ok, {:inspector_tab, :previous}}

      overlay = %{undocked | layers: [{:run_inspector, "r", :agents}]}
      assert Keymap.resolve(letter("]"), overlay, %{}) == {:ok, {:inspector_tab, :next}}
    end

    test "i focuses the composer and t opens the inspector overlay" do
      assert Keymap.resolve(letter("i"), main(), %{}) == {:ok, {:focus_region, "composer"}}

      state = %{with_runs(main(), ["r"]) | selection: %{"main" => "r"}}
      table = %{"t" => {:local, {:open_layer, {:run_inspector, "r", :overview}}}}

      assert {:ok, {:open_layer, {:run_inspector, "r", :overview}}} =
               Keymap.resolve(letter("t"), state, table)
    end

    test "run controls still target the selected run instead of another authorized run" do
      state = %{with_runs(main(), ["selected", "other"]) | selection: %{"main" => "selected"}}

      table = %{
        "a" => {:intent, {:run_control, :pause, "other"}},
        "z" => {:intent, {:run_control, :pause, "selected"}}
      }

      assert {:ok, {:invoke, {:run_control, :pause, "selected"}, _}} =
               Keymap.resolve(letter("p"), state, table)
    end
  end

  # ------------------------------------------------------- selection and scroll

  describe "selection and scrolling" do
    test "j/k and the arrows move; G and End are the same key" do
      assert Keymap.resolve(letter("j"), main(), %{}) == {:ok, {:move, :next}}
      assert Keymap.resolve(Input.key(:down), main(), %{}) == {:ok, {:move, :next}}
      assert Keymap.resolve(letter("k"), main(), %{}) == {:ok, {:move, :previous}}
      assert Keymap.resolve(Input.key(:up), main(), %{}) == {:ok, {:move, :previous}}
      assert Keymap.resolve(Input.key(:home), main(), %{}) == {:ok, {:move, :first}}

      assert Keymap.resolve(letter("G"), main(), %{}) ==
               Keymap.resolve(Input.key(:end), main(), %{})

      assert Keymap.resolve(letter("G"), main(), %{}) == {:ok, {:move, :last}}
    end

    test "Ctrl-D/U are half pages and Ctrl-E/Y are lines, in the focused region" do
      inspector = %{main() | focus: "inspector"}

      assert Keymap.resolve(letter("d", [:control]), main(), %{}) ==
               {:ok, {:scroll, "main", {:half_page, 1}}}

      assert Keymap.resolve(letter("u", [:control]), main(), %{}) ==
               {:ok, {:scroll, "main", {:half_page, -1}}}

      assert Keymap.resolve(letter("e", [:control]), inspector, %{}) ==
               {:ok, {:scroll, "inspector", {:line, 1}}}

      assert Keymap.resolve(letter("y", [:control]), inspector, %{}) ==
               {:ok, {:scroll, "inspector", {:line, -1}}}

      assert Keymap.resolve(Input.key(:page_down), main(), %{}) ==
               {:ok, {:scroll, "main", {:page, 1}}}
    end

    test "h/l collapse and expand, and Space toggles what is selected" do
      state = %{main() | selection: %{"main" => "item"}}
      assert Keymap.resolve(letter("h"), state, %{}) == {:ok, {:expand, "item", false}}
      assert Keymap.resolve(letter("l"), state, %{}) == {:ok, {:expand, "item", true}}
      assert Keymap.resolve(letter(" "), state, %{}) == {:ok, {:expand, "item", true}}

      expanded = %{state | expansions: MapSet.new(["item"])}
      assert Keymap.resolve(letter(" "), expanded, %{}) == {:ok, {:expand, "item", false}}
    end
  end

  # ------------------------------------------------------------------- pickers

  describe "pickers" do
    test "arrows, Ctrl-N and Tab move; Ctrl-P is the palette; letters filter" do
      picker = %{main() | layers: [{:run_palette, "p"}]}

      assert Keymap.resolve(Input.key(:down), picker, %{}) == {:ok, {:focus_cycle, :next}}
      assert Keymap.resolve(Input.key(:up), picker, %{}) == {:ok, {:focus_cycle, :previous}}
      assert Keymap.resolve(letter("n", [:control]), picker, %{}) == {:ok, {:focus_cycle, :next}}

      # Ctrl-P is the command palette everywhere, so a picker cannot use it for
      # "previous"; the arrow is the only spelling.
      assert {:ok, {:open_layer, {:switcher, _}}} =
               Keymap.resolve(letter("p", [:control]), picker, %{})

      assert Keymap.resolve(Input.key(:tab), picker, %{}) == {:ok, {:focus_cycle, :next}}

      assert Keymap.resolve(Input.key(:tab, [:shift]), picker, %{}) ==
               {:ok, {:focus_cycle, :previous}}

      assert Keymap.resolve(letter("n"), picker, %{}) ==
               {:ok, {:dashboard_filter, {:append, "n"}}}
    end

    test "a held letter keeps typing rather than firing a press-only binding" do
      dashboard = %{main() | layers: [{:runs_dashboard, "d"}]}

      assert Keymap.resolve(Input.text_fragment(:repeat, "q", []), dashboard, %{}) ==
               {:ok, {:dashboard_filter, {:append, "q"}}}
    end
  end

  # ------------------------------------------------------------------- dialogs

  describe "dialogs" do
    test "j/k and the arrows cycle focus, and G/End scroll the body" do
      dialog = %{main() | layers: [:help], focus: "dialog"}

      assert Keymap.resolve(letter("j"), dialog, %{}) == {:ok, {:focus_cycle, :next}}
      assert Keymap.resolve(letter("k"), dialog, %{}) == {:ok, {:focus_cycle, :previous}}
      assert Keymap.resolve(Input.key(:down), dialog, %{}) == {:ok, {:focus_cycle, :next}}
      assert Keymap.resolve(Input.key(:left), dialog, %{}) == {:ok, {:focus_cycle, :previous}}
      assert Keymap.resolve(letter("G"), dialog, %{}) == {:ok, {:scroll, "dialog", :last}}
      assert Keymap.resolve(Input.key(:end), dialog, %{}) == {:ok, {:scroll, "dialog", :last}}

      assert Keymap.resolve(letter("d", [:control]), dialog, %{}) ==
               {:ok, {:scroll, "dialog", {:half_page, 1}}}
    end

    test "y and n confirm and cancel on confirm_intent and unsent_changes only" do
      intent = {:run_control, :stop, "r"}
      table = %{"confirm" => {:intent, intent}}
      confirm = %{main() | layers: [{:confirm_intent, intent}], focus: "cancel"}

      assert {:ok, {:invoke, ^intent, _}} = Keymap.resolve(letter("y"), confirm, table)
      assert Keymap.resolve(letter("n"), confirm, table) == {:ok, :close_top_layer}

      unsent = %{main() | layers: [{:unsent_changes, :detach}], focus: "cancel"}
      unsent_table = %{"confirm" => {:local, {:quit_confirmed, :detach}}}

      assert Keymap.resolve(letter("y"), unsent, unsent_table) ==
               {:ok, {:quit_confirmed, :detach}}

      assert Keymap.resolve(letter("n"), unsent, unsent_table) == {:ok, :close_top_layer}

      # Any other dialog leaves y and n alone.
      assert Keymap.resolve(letter("y"), %{main() | layers: [:help]}, %{}) == :ignore
    end

    test "1-9 pick a question option and Space ticks a multiple choice" do
      state = question_state()
      assert Keymap.resolve(letter("1"), state, %{}) == {:ok, {:focus_region, "opt-a"}}
      assert Keymap.resolve(letter("2"), state, %{}) == {:ok, {:focus_region, "opt-b"}}
      assert Keymap.resolve(letter("3"), state, %{}) == :ignore

      focused = %{state | focus: "opt-a"}
      table = %{"opt-a" => {:local, {:select_option, "q", "opt-a"}}}

      assert Keymap.resolve(letter(" "), focused, table) ==
               {:ok, {:select_option, "q", "opt-a"}}
    end

    test "modal Cancel wins over the composer and bare Enter never confirms a stop" do
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

    test "stop run and stop agent need independent authorized confirmation" do
      state = main()
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

    test "detail pager activates only displayed page actions" do
      state = %{state() | layers: [{:detail, "r", "ref"}], focus: "next"}
      table = %{"next" => {:local, {:detail_page, :next}}}
      assert {:ok, {:detail_page, :next}} = Keymap.resolve(Input.key(:enter), state, table)
      assert :ignore = Keymap.resolve(Input.key(:enter), state, %{})
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
  end

  # ------------------------------------------------------------------ composer

  describe "composer" do
    test "paste and committed repeats edit only the active editor; release is inert" do
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

    test "Enter activates only an authorized current target; newline is capability gated" do
      state = state()
      intent = {:dispatch, :send, "hello", :main, []}
      table = %{"opaque" => {:intent, intent}}
      assert {:ok, {:invoke, ^intent, id}} = Keymap.resolve(Input.key(:enter), state, table)
      assert id == elem(State.next_id(state, :request), 0)
      assert :ignore = Keymap.resolve(Input.key(:enter), state, %{})

      for phase <- [:repeat, :release],
          do: assert(:ignore == Keymap.resolve(Input.key(phase, :enter, []), state, table))

      assert {:ok, {:editor, _, :newline}} =
               Keymap.resolve(letter("o", [:control]), state, table)

      assert :ignore = Keymap.resolve(Input.key(:enter, [:shift]), state, table)
      enhanced = %{state | capabilities: %{state.capabilities | enhanced_keys: :supported}}

      assert {:ok, {:editor, _, :newline}} =
               Keymap.resolve(Input.key(:enter, [:shift]), enhanced, table)
    end

    test "readline: Ctrl-A is line start, not select all; Ctrl-E, Ctrl-W and Ctrl-U join it" do
      state = state()

      assert Keymap.resolve(letter("a", [:control]), state, %{}) ==
               {:ok, {:editor, {"c", :main}, {:move, :line_start}}}

      refute Keymap.resolve(letter("a", [:control]), state, %{}) ==
               {:ok, {:editor, {"c", :main}, :select_all}}

      assert Keymap.resolve(letter("e", [:control]), state, %{}) ==
               {:ok, {:editor, {"c", :main}, {:move, :line_end}}}

      assert Keymap.resolve(letter("w", [:control]), state, %{}) ==
               {:ok, {:editor, {"c", :main}, :delete_word_backward}}

      # Ctrl-U is the clear-draft idiom. The resolver validates the operation
      # before returning it, so this asserts the vocabulary as well as the key.
      assert Keymap.resolve(letter("u", [:control]), state, %{}) ==
               {:ok, {:editor, {"c", :main}, {:delete, :line_start}}}
    end

    test "Tab from the conversation transcript goes directly to the composer" do
      for columns <- [80, 120, 170] do
        size = %Size{columns: columns, rows: 40}
        current = %{state() | focus: "main", size: size, capabilities: %Capabilities{size: size}}

        assert {:ok, {:focus_region, "composer"}} = Keymap.resolve(Input.key(:tab), current, %{})
      end
    end

    test "queue shortcut equals the slash queue catalogue target" do
      state = state()
      intent = {:dispatch, :queue, "hello", :main, []}
      table = %{"queue" => {:intent, intent}}

      assert Keymap.resolve(Input.key(:enter, [:alt]), state, table) ==
               Keymap.activate({:intent, intent}, state, table)
    end

    test "query Left edits the cursor while Down traverses modal choices" do
      state = %{state() | layers: [{:switcher, "s"}], focus: "query"}

      assert {:ok, {:field_editor, {:layer_query, "s", :switcher}, {:move, :left}}} =
               Keymap.resolve(Input.key(:left), state, %{})

      assert {:ok, {:focus_cycle, :next}} = Keymap.resolve(Input.key(:down), state, %{})
    end
  end

  # ------------------------------------------------------------- the g popup

  describe "the go-to popup" do
    test "renders four which-key rows that carry their own actions" do
      alias SwarmCodeCLI.UI.{Fixtures, Projector, Scene}
      size = %Size{columns: 120, rows: 40}
      shell = %{Fixtures.representative(:chat, size, %Capabilities{size: size}) | focus: "main"}

      {:ok, open} = Keymap.resolve(letter("g"), shell, %{})
      {jump, _} = Reducer.update(shell, open)

      assert match?([{:jump, _}], jump.layers)
      assert jump.focus == "jump_top"

      assert Reducer.focus_graph(jump) ==
               ["jump_top", "jump_bottom", "jump_next_run", "jump_previous_run", "cancel"]

      {scene, table} = Projector.project(jump)
      assert Scene.validate(scene) == :ok
      assert scene.overlay.id == "dialog"

      # Each row's action is in the interaction table, so Enter on a row does
      # exactly what its letter does.
      for action <- [{:move, :first}, {:move, :last}, {:run_tab, :next}, {:run_tab, :previous}] do
        assert {:local, action} in Map.values(table)
      end

      assert Keymap.resolve(Input.key(:enter), jump, table) == {:ok, {:move, :first}}
    end
  end

  # ----------------------------------------------------------------- unbound

  test "/ is unbound in main: its layer filtered nothing it could show" do
    assert Keymap.resolve(letter("/"), main(), %{}) == :ignore
    assert Keymap.resolve(letter("/"), %{main() | focus: "inspector"}, %{}) == :ignore

    # It is still typing wherever typing is what a key means.
    assert {:ok, {:editor, _, {:insert, "/"}}} = Keymap.resolve(letter("/"), state(), %{})
  end

  # -------------------------------------------------------------- tiny screens

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

      assert :ignore = Keymap.resolve(letter("x"), state, table)

      assert :ignore =
               Keymap.resolve(letter("X"), %{state | exit_pending: nil}, table)

      for focus <- ["cancel", "confirm"],
          do: assert(:ignore == Keymap.resolve(Input.key(:enter), %{state | focus: focus}, table))

      assert {:ok, :close_top_layer} = Keymap.resolve(Input.key(:escape), state, table)
    end
  end

  # -------------------------------------------------------------- the reducer

  describe "through the reducer" do
    test "q never quits while any layer is open" do
      state = %{main() | layers: [:help]}
      {:ok, action} = Keymap.resolve(letter("q"), state, %{})
      {next, effects} = Reducer.update(state, action)

      assert next.layers == []
      assert effects == []
      refute next.lifecycle == :closing
    end

    test "g then t cycles the stable run order and comes back round" do
      state = with_runs(%{main() | destination: {:run, "a"}}, ["a", "b", "c"])

      {:ok, open} = Keymap.resolve(letter("g"), state, %{})
      {state, _} = Reducer.update(state, open)
      assert match?([{:jump, _}], state.layers)

      {:ok, next} = Keymap.resolve(letter("t"), state, %{})
      assert next == {:run_tab, :next}

      {state, _} = Reducer.update(state, next)
      assert state.destination == {:run, "b"}
      assert state.layers == []

      {state, _} = Reducer.update(state, {:run_tab, :next})
      assert state.destination == {:run, "c"}

      {state, _} = Reducer.update(state, {:run_tab, :next})
      assert state.destination == {:run, "a"}

      {state, _} = Reducer.update(state, {:run_tab, :previous})
      assert state.destination == {:run, "c"}
    end

    test "Alt-1..4 index the drawn order, which puts the active run first" do
      state = with_runs(%{main() | destination: {:run, "c"}}, ["a", "b", "c"])

      {state, _} = Reducer.update(state, {:run_tab, 1})
      assert state.destination == {:run, "c"}

      {state, _} = Reducer.update(state, {:run_tab, 2})
      assert state.destination == {:run, "a"}
    end

    test "[ and ] rotate the inspector's four tabs, overlay included" do
      state = %{main() | tabs: %{inspector: :thread}}

      {state, _} = Reducer.update(state, {:inspector_tab, :next})
      assert state.tabs.inspector == :agents

      {state, _} = Reducer.update(state, {:inspector_tab, :previous})
      assert state.tabs.inspector == :thread

      {state, _} = Reducer.update(state, {:inspector_tab, :previous})
      assert state.tabs.inspector == :changes

      overlay = %{state | layers: [{:run_inspector, "r", :changes}]}
      {overlay, _} = Reducer.update(overlay, {:inspector_tab, :next})
      assert overlay.tabs.inspector == :thread
      assert overlay.layers == [{:run_inspector, "r", :overview}]
    end

    test "the keymap preference lives on the state and starts at :default" do
      assert main().keymap == :default
      assert main().vim == %SwarmCodeCLI.UI.Vim{mode: :insert, pending: nil, count: nil}

      {vim, _} = Reducer.update(main(), {:set_keymap, :vim})
      assert vim.keymap == :vim
      assert vim.vim.mode == :insert

      {back, _} = Reducer.update(vim, {:set_keymap, :default})
      assert back.keymap == :default
    end
  end

  defp question_state do
    interaction = %DTO.PendingInteraction{
      id: "q",
      run_id: "r",
      node_id: "n",
      expected_revision: 7,
      allowed_actions: [:answer_question],
      question: %DTO.Question{
        multiple: true,
        options: [%DTO.QuestionOption{id: "opt-a"}, %DTO.QuestionOption{id: "opt-b"}]
      }
    }

    state = main()

    %{
      state
      | layers: [{:question, "q"}],
        focus: "cancel",
        read_model: %{state.read_model | interactions: %{"q" => interaction}}
    }
  end
end
