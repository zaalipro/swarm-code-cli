defmodule SwarmCodeCLI.UI.BindingsTest do
  @moduledoc """
  The invariants that make one binding table trustworthy as the single source of
  truth: nothing collides, everything it claims actually resolves, and every row
  carries the words the status bar and the help sheet will read off it.
  """
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Input, Keymap, Size, Vim, WatchState}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Keymap.Bindings

  @size %Size{columns: 120, rows: 40}

  # A binding whose resolution depends on which layer is on top is exercised
  # against the layer it is for. Everything else in that context uses the
  # representative one.
  @picker_layers %{
    jump_top: {:jump, "jump-layer"},
    jump_bottom: {:jump, "jump-layer"},
    jump_next_run: {:jump, "jump-layer"},
    jump_previous_run: {:jump, "jump-layer"},
    picker_page_down: {:runs_dashboard, "dashboard"},
    picker_page_up: {:runs_dashboard, "dashboard"},
    picker_first: {:runs_dashboard, "dashboard"},
    picker_last: {:runs_dashboard, "dashboard"}
  }

  @dialog_layers %{
    approve_run: {:approval, "approval-1"},
    deny: {:approval, "approval-1"},
    deny_stop: {:approval, "approval-1"},
    always_allow: {:approval, "approval-1"},
    confirm_yes: {:confirm_intent, {:run_control, :stop, "run-1"}},
    confirm_no: {:confirm_intent, {:run_control, :stop, "run-1"}},
    question_option: {:question, "question-1"},
    select_option: {:question, "question-1"},
    dialog_page_down: {:approval, "approval-1"},
    dialog_page_up: {:approval, "approval-1"}
  }

  describe "the table is unambiguous" do
    test "no two bindings share a {context, key} pair" do
      pairs =
        for binding <- Bindings.all(),
            key <- binding.keys,
            context <- contexts_of(binding, key),
            do: {{context, key}, binding.id}

      duplicates =
        pairs
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.filter(fn {_, ids} -> length(Enum.uniq(ids)) > 1 end)

      assert duplicates == [],
             "colliding bindings: " <> inspect(duplicates)

      # The flattened table keeps exactly one entry per pair, so its size is the
      # count of distinct pairs: a silent overwrite would shrink it.
      assert map_size(Bindings.table()) == length(Enum.uniq_by(pairs, &elem(&1, 0)))
    end

    test "every binding id is unique and every context it names is real" do
      ids = Enum.map(Bindings.all(), & &1.id)
      assert ids == Enum.uniq(ids)

      for binding <- Bindings.all(), context <- binding.contexts do
        assert context == :global or context in Bindings.contexts(),
               "#{binding.id} names the unknown context #{inspect(context)}"
      end
    end

    test "a bare printable global never reaches a context where it would be typing" do
      for binding <- Bindings.all(),
          :global in binding.contexts,
          {code, mods} <- binding.keys,
          is_binary(code) and mods == [],
          context <- Bindings.typing_contexts() do
        refute Bindings.lookup(context, code, mods) == binding,
               "#{binding.id} steals #{inspect(code)} from typing in #{context}"
      end
    end

    test "every key is in the shape the resolver looks up: sorted mods, no lone shift" do
      for binding <- Bindings.all(), {code, mods} <- binding.keys do
        assert mods == Enum.sort(mods), "#{binding.id} has unsorted modifiers"

        assert is_binary(code) or is_atom(code) or match?({:function, _}, code)

        if is_binary(code),
          do:
            refute(mods == [:shift],
              message: "#{binding.id} keeps a lone :shift on a text fragment"
            )
      end
    end
  end

  describe "every binding resolves to what it declares" do
    test "from a representative state of each of its contexts" do
      # A binding that declines in a context (its special returns :ignore, as
      # "q" does inside a searchable picker) must leave the keystroke to typing
      # and to nothing else: it may never resolve to some other binding.
      failures =
        for binding <- Bindings.all(),
            key <- binding.keys,
            context <- contexts_of(binding, key),
            declared = declared(binding, key, context),
            resolved = resolve(binding, key, context),
            not agrees?(declared, resolved),
            do: {binding.id, context, key, declared, resolved}

      assert failures == [],
             Enum.map_join(failures, "\n", fn {id, context, key, declared, resolved} ->
               "#{id} in #{context} on #{inspect(key)}: table says #{inspect(declared)}, resolver says #{inspect(resolved)}"
             end)
    end

    test "the bindings that decline in a context are exactly the documented ones" do
      declining =
        for binding <- Bindings.all(),
            key <- binding.keys,
            context <- contexts_of(binding, key),
            declared(binding, key, context) == :ignore,
            uniq: true,
            do: {binding.id, context}

      # Every one of these is a decision, not an accident:
      #   "q" types in a picker that has a query box;
      #   Shift-Enter needs a terminal that reports it, which none here does;
      #   Enter in the research question box is not a control;
      #   the resize chords need the inspector focused, the only dock left;
      #   "3".."9" with only two options on the question;
      #   vim's x and X on the fixture's empty draft line have nothing to
      #   delete (x at a line end would otherwise join lines);
      #   the overlay's x stops its agent only when the projector keeps a stop
      #   action for it, and the fixture's table has none.
      assert Enum.sort(declining) ==
               Enum.sort(
                 [
                   {:activate, :field},
                   {:close_or_quit, :picker},
                   {:composer_newline, :composer},
                   {:composer_newline, :field},
                   {:composer_newline, :overlay},
                   {:overlay_stop_agent, :overlay},
                   {:question_option, :dialog},
                   {:vim_delete_char, :composer_normal},
                   {:vim_delete_char_back, :composer_normal}
                 ] ++
                   for(
                     id <- [:layout_narrower, :layout_wider, :layout_reset],
                     context <- Bindings.contexts() -- [:inspector],
                     do: {id, context}
                   )
               )
    end
  end

  describe "the table is readable" do
    test "every binding has a non-empty label and a non-empty help line" do
      for binding <- Bindings.all() do
        assert is_binary(binding.label) and String.trim(binding.label) != "",
               "#{binding.id} has no label"

        assert is_binary(binding.help) and String.trim(binding.help) != "",
               "#{binding.id} has no help line"

        # The status bar draws labels in a row it must not overflow.
        assert String.length(binding.label) <= 14,
               "#{binding.id}'s label is #{String.length(binding.label)} cells"

        # The help sheet gives each binding one line.
        refute String.contains?(binding.help, "\n"), "#{binding.id}'s help is multi-line"
        assert binding.group in Bindings.groups(), "#{binding.id} is in no rendered group"

        # One weight for every context, or a weight per context; a context a
        # keyword list does not name is simply never hinted.
        assert (is_integer(binding.hint) and binding.hint >= 0) or
                 (is_list(binding.hint) and
                    Enum.all?(binding.hint, fn {context, weight} ->
                      context in Bindings.contexts() and is_integer(weight) and weight > 0
                    end)),
               "#{binding.id} has a malformed hint"
      end
    end

    test "every context has at least one binding the status bar can hint" do
      for context <- Bindings.contexts() do
        hinted = Enum.filter(Bindings.for_context(context), &(&1.hint > 0))

        refute hinted == [], "#{context} has no hint > 0 binding"
      end
    end

    # The help sheet groups the vim rows under their own heading, and a vim row
    # that leaked into the plain composer would turn a typed letter into a
    # command for everyone.
    test "the vim rows are the only :vim group and never reach the plain composer" do
      vim_rows = Enum.filter(Bindings.all(), &(&1.group == :vim))

      refute vim_rows == []

      for binding <- vim_rows do
        assert Enum.all?(binding.contexts, &(&1 in [:composer_normal, :composer_visual])),
               "#{binding.id} is a vim row declared outside the vim contexts"
      end

      for binding <- Bindings.for_context(:composer) do
        refute binding.group == :vim, "#{binding.id} reaches the plain composer"
      end

      # Every NORMAL-only command is reachable as a bare key, so a vim user's
      # hands never need a modifier for the grammar they know.
      for binding <- Bindings.for_context(:composer_normal), binding.group == :vim do
        assert Enum.any?(binding.keys, fn {code, mods} ->
                 is_binary(code) and mods in [[], [:control]]
               end),
               "#{binding.id} has no bare or Ctrl key"
      end
    end
  end

  describe "helpers" do
    test "keys_for and fetch read the same table the resolver does" do
      assert Bindings.keys_for(:move_next) == [{"j", []}, {:down, []}]
      assert Bindings.keys_for(:not_a_binding) == []
      assert Bindings.fetch(:move_next).action == {:move, :next}
      assert Bindings.fetch(:not_a_binding) == nil
      assert Bindings.lookup(:main, "j", []).id == :move_next
      assert Bindings.lookup(:composer, "j", []) == nil
    end

    test "for_context lists everything reachable there and nothing else" do
      main = Enum.map(Bindings.for_context(:main), & &1.id)

      assert :move_next in main
      assert :help in main
      assert :jump_prefix in main
      refute :jump_top in main
      refute :picker_next in main
      refute :composer_line_start in main
    end
  end

  # ------------------------------------------------------------------ helpers

  @doc false
  def __contexts_of__(binding, key), do: contexts_of(binding, key)
  @doc false
  def __declared__(binding, key, context), do: declared(binding, key, context)

  defp contexts_of(binding, {code, mods}) do
    typing? = is_binary(code) and mods == []

    binding.contexts
    |> Enum.flat_map(fn
      :global when typing? -> Bindings.contexts() -- Bindings.typing_contexts()
      :global -> Bindings.contexts()
      context -> [context]
    end)
    |> Enum.uniq()
  end

  defp resolve(binding, {code, mods}, context) do
    input =
      if is_binary(code),
        do: Input.text_fragment(:press, code, mods),
        else: Input.key(:press, code, mods)

    Keymap.resolve(input, state_for(binding, context), table())
  end

  # The resolver agrees with the table when it returns the declared action, or —
  # for a binding that declined — when it fell through to typing.
  # pass72: hint mode takes every key; one no binding there uses ends it.
  defp agrees?(:ignore, {:ok, {:hint, :cancel}}), do: true
  defp agrees?(:ignore, resolved), do: resolved == :ignore or typing?(resolved)
  defp agrees?(declared, resolved), do: declared == resolved

  defp typing?({:ok, {:editor, _, {:insert, _}}}), do: true
  defp typing?({:ok, {:editor, _, {:move, _}}}), do: true
  defp typing?({:ok, {:field_editor, _, {:insert, _}}}), do: true
  defp typing?({:ok, {:field_editor, _, {:move, _}}}), do: true
  defp typing?({:ok, {:dashboard_filter, {:append, _}}}), do: true
  defp typing?(_resolved), do: false

  # What the table claims this key does, spelled as the resolver's own result.
  defp declared(binding, key, context) do
    case binding.action do
      {:special, name} ->
        SwarmCodeCLI.UI.Keymap.Special.run(name, key, state_for(binding, context), table())

      {:editor_op, operation} ->
        Keymap.edit(state_for(binding, context), operation)

      action ->
        Keymap.result(action)
    end
  end

  # Every target any special may look for, so a `find_target` binding has
  # something authorized to find.
  defp table do
    %{
      "stop" => {:intent, {:run_control, :stop, "fixture-run"}},
      "pause" => {:intent, {:run_control, :pause, "fixture-run"}},
      "mark" => {:intent, {:mark_seen, :run, "fixture-run", 4}},
      "inspect" => {:local, {:open_layer, {:run_inspector, "fixture-run", :overview}}},
      "detail" => {:local, {:open_detail, "fixture-run", "002"}},
      "send" => {:intent, {:dispatch, :send, "hello", :main, []}},
      "queue" => {:intent, {:dispatch, :queue, "hello", :main, []}},
      "approve" =>
        {:intent, {:resolve_approval, "fixture-run", "node-a", "approval-1", 3, :approve}},
      "deny" => {:intent, {:resolve_approval, "fixture-run", "node-a", "approval-1", 3, :deny}},
      "always" =>
        {:intent, {:resolve_approval, "fixture-run", "node-a", "approval-1", 3, :always_allow}},
      "confirm" => {:intent, {:run_control, :stop, "run-1"}},
      "select" => {:local, {:select_option, "question-1", "opt-a"}},
      "jump_top" => {:local, {:move, :first}},
      "jump_bottom" => {:local, {:move, :last}},
      "jump_next_run" => {:local, {:run_tab, :next}},
      "jump_previous_run" => {:local, {:run_tab, :previous}},
      "expand_main" => {:local, {:expand, "002", true}},
      "expand_inspector" => {:local, {:expand, "agent-1", true}},
      "activity" => {:local, {:navigate, :activity}},
      "detail_page" => {:local, {:detail_page, :next}}
    }
  end

  defp state_for(binding, :picker),
    do: %{base(:picker) | layers: [Map.get(@picker_layers, binding.id, {:switcher, "switcher"})]}

  defp state_for(binding, :dialog) do
    layer = Map.get(@dialog_layers, binding.id, {:detail, "fixture-run", "002"})

    focus =
      case layer do
        {:approval, _} -> "approve"
        {:question, _} -> "opt-a"
        {:detail, _, _} -> "next"
        _ -> "cancel"
      end

    %{base(:dialog) | layers: [layer], focus: focus}
  end

  defp state_for(_binding, context), do: base(context)

  # A representative shell plus the interactions the dialog contexts need. The
  # fixture supplies the runs, transcript and draft; the rest is hand built
  # because no fixture carries a pending approval.
  defp base(context) do
    state = Fixtures.representative(:swarm, @size, %Capabilities{size: @size})

    interactions = %{
      # `allowed_decisions` is the wire field of pass 70 (owner C); put
      # rather than built so this compiles before and after it lands.
      "approval-1" =>
        Map.put(
          %DTO.PendingInteraction{
            id: "approval-1",
            kind: :approval,
            run_id: "fixture-run",
            node_id: "node-a",
            expected_revision: 3,
            allowed_actions: [:approve, :deny, :always_allow],
            approval: %DTO.Approval{tool: "edit", permission: :write, arguments_preview: "a.ex"}
          },
          :allowed_decisions,
          [:approve, :approve_run, :always_prefix, :deny, :deny_stop]
        ),
      "question-1" => %DTO.PendingInteraction{
        id: "question-1",
        run_id: "fixture-run",
        node_id: "node-b",
        expected_revision: 4,
        allowed_actions: [:answer_question],
        question: %DTO.Question{
          multiple: true,
          options: [%DTO.QuestionOption{id: "opt-a"}, %DTO.QuestionOption{id: "opt-b"}]
        }
      }
    }

    state = %{
      state
      | read_model: %{state.read_model | interactions: interactions},
        watches: Map.new([:shell, :workspace, :activity, :inspector], &{&1, %WatchState{}}),
        preferences: %{state.preferences | medium_dock: :inspector},
        selection: %{"main" => "002", "inspector" => "agent-1"},
        keymap: :default,
        vim: %Vim{}
    }

    case context do
      :composer -> %{state | focus: "composer"}
      :composer_normal -> %{state | focus: "composer", keymap: :vim, vim: %Vim{mode: :normal}}
      :composer_visual -> %{state | focus: "composer", keymap: :vim, vim: %Vim{mode: :visual}}
      :main -> %{state | focus: "main"}
      :inspector -> %{state | focus: "inspector"}
      :picker -> %{state | focus: "query"}
      :dialog -> %{state | focus: "dialog"}
      :field -> field(state)
      :hint -> %{state | focus: "composer", hint: SwarmCodeCLI.UI.Reducer.Hint.open(state)}
      :overlay -> overlay(state)
    end
  end

  # pass72: the agent overlay on the fixture swarm's lead, with the fixture's
  # approval waiting on it, focused on its activity.
  defp overlay(state) do
    %{
      state
      | focus: "composer",
        overlay: %{
          run_id: "fixture-run",
          node_id: "node-a",
          draft_key: {"fixture-conversation", {:agent, "node-a"}},
          focus: :activity,
          raw_ops?: false,
          page: 0,
          cursor: 0,
          expanded: MapSet.new(),
          restore: %{scroll: nil, focus: "composer", draft: :none}
        }
    }
  end

  # The research form's question box is the simplest real field editor: one
  # layer, one focus, a live `Editor` behind it.
  defp field(state) do
    %{
      state
      | layers: [{:research_form, "owner-1"}],
        focus: "question",
        library: %{command_id: nil, request_id: nil, message: nil, feature: :research, body: nil}
    }
  end
end
