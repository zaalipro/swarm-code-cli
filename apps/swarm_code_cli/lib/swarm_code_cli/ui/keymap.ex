defmodule SwarmCodeCLI.UI.Keymap do
  @moduledoc "Single-action input resolution: modal, field, composer, content, global."
  alias SwarmCodeCLI.UI.{Action, Input, Layout, Question, SlashPalette, State, Switcher}
  alias SwarmCodeCLI.UI.Projector.RunsDashboard

  def resolve(input, state, table) when is_map(table) do
    case Input.validate(input) do
      {:ok, input} -> route(input, state, table)
      _ -> :ignore
    end
  end

  def resolve(_, _, _), do: :ignore

  def activate(target, state, table) do
    if Enum.any?(table, fn {_, current} -> current == target end) do
      case target do
        {:intent, {:dispatch, :send, "/workflows", :main, []}}
        when state.banner == :live_banner ->
          result({:open_layer, {:library, :workflows}})

        {:intent, {:dispatch, :send, text, :main, []}}
        when state.banner == :live_banner and
               text in ["/deep_research", "/deep_research "] ->
          result({:open_layer, {:library, :research}})

        {:local, action} ->
          result(action)

        {:intent, intent} ->
          if destructive?(intent) and not match?([{:confirm_intent, ^intent} | _], state.layers),
            do: result({:open_layer, {:confirm_intent, intent}}),
            else: result({:invoke, intent, elem(State.next_id(state, :request), 0)})

        _ ->
          :ignore
      end
    else
      :ignore
    end
  end

  defp route({:key, :release, _, _}, _, _), do: :ignore
  defp route({:text_fragment, :release, _, _}, _, _), do: :ignore
  defp route({:mouse, _, _, _, _, _}, _, _), do: :ignore

  defp route(:focus_gained, state, _),
    do: result({:terminal_focus, :gained, state.terminal_generation})

  defp route(:focus_lost, state, _),
    do: result({:terminal_focus, :lost, state.terminal_generation})

  defp route({:resize, size}, _, _), do: result({:resize, size})
  defp route({:rejected, reason}, _, _), do: result({:input_rejected, reason})
  defp route({:paste, text}, state, _), do: edit(state, {:paste, text})

  defp route({:key, phase, code, mods}, state, table),
    do: key(code, Enum.sort(mods), phase, state, table)

  defp route({:text_fragment, phase, text, mods}, state, table),
    do: key(text, Enum.sort(mods), phase, state, table)

  # Esc unwinds the dashboard one step at a time: it drops the filter query
  # first and only closes the layer once there is nothing left to clear.
  defp key(:escape, [], :press, %{layers: [{:runs_dashboard, _} | _]} = state, _) do
    if State.runs_filter(state) == "",
      do: result(:close_top_layer),
      else: result({:dashboard_filter, :clear})
  end

  defp key(:escape, [], :press, %{layers: [_ | _]}, _), do: result(:close_top_layer)
  defp key(:escape, [], :press, %{focus: "composer"}, _), do: result({:focus_region, "main"})
  defp key(:escape, [], :press, _, _), do: result(:back)

  defp key(:tab, [], phase, %{focus: "main", layers: []} = state, _)
       when phase in [:press, :repeat] do
    layout = Layout.calculate(state.size, state.preferences)

    if Map.has_key?(layout.rects, :composer),
      do: result({:focus_region, "composer"}),
      else: result({:focus_cycle, :next})
  end

  defp key("c", [:control], :press, state, _) do
    if editor_context(state),
      do: result(:editor_detach_notice),
      else: result({:quit_requested, :detach})
  end

  defp key(:tab, [], phase, state, _) when phase in [:press, :repeat] do
    case SlashPalette.selected(state) do
      %{name: name} -> result({:complete_command, name})
      nil -> result({:focus_cycle, :next})
    end
  end

  defp key(code, mods, phase, _, _)
       when phase in [:press, :repeat] and
              ((code == :tab and mods == [:shift]) or (code == :back_tab and mods == [])),
       do: result({:focus_cycle, :previous})

  defp key(code, mods, phase, %{layers: [_ | _]} = state, table),
    do: modal(code, mods, phase, state, table)

  defp key(code, mods, phase, %{focus: "composer"} = state, table) do
    cond do
      code in [:up, :down] and mods == [] and phase in [:press, :repeat] and
          SlashPalette.open?(state) ->
        result({:move, if(code == :down, do: :next, else: :previous)})

      code == :enter and mods == [] and phase == :press ->
        find_target(state, table, &match?({:intent, {:dispatch, :send, _, _, _}}, &1))

      code == :enter and mods == [:alt] and phase == :press ->
        queue(state, table)

      code == :up and mods == [:control] ->
        result({:composer_height, {:nudge, 1}})

      code == :down and mods == [:control] ->
        result({:composer_height, {:nudge, -1}})

      true ->
        editor_key(code, mods, phase, state, table)
    end
  end

  defp key(code, mods, phase, state, table), do: content(code, mods, phase, state, table)

  defp modal(code, mods, phase, state, table) do
    layer = hd(state.layers)
    field = Switcher.field_key(layer)

    cond do
      match?({:unsent_changes, _}, layer) and
          Layout.calculate(state.size, state.preferences).class == :too_small ->
        tiny_exit(code, mods, phase, state)

      # Ctrl-G toggles the dashboard shut, and inside it the bare letters that
      # close a dialog ("q", which would otherwise quit the session, and the
      # generic "b" back key) close rather than quitting. They only do so while
      # the filter is empty: once a query is being typed they are letters, or a
      # filter could never spell "query" or "boundary".
      match?({:runs_dashboard, _}, layer) and phase == :press and
          dashboard_close?(code, mods, state) ->
        result(:close_top_layer)

      match?({:runs_dashboard, _}, layer) and phase in [:press, :repeat] and
        code == :backspace and mods == [] ->
        result({:dashboard_filter, :backspace})

      # The dashboard windows its runs, so it needs the paging keys the
      # scrolling navigator used to answer. Moving the focus moves the window,
      # which is what keeps the focused row inside the action table.
      match?({:runs_dashboard, _}, layer) and phase in [:press, :repeat] and
        code in [:page_up, :page_down, :home, :end] and mods == [] ->
        case RunsDashboard.page_focus(state, code) do
          nil -> :ignore
          id -> result({:focus_region, id})
        end

      # Letter keys arrive as text fragments, so a printable fragment with no
      # command modifier is typing into the filter rather than a binding.
      match?({:runs_dashboard, _}, layer) and phase in [:press, :repeat] and
        is_binary(code) and mods in [[], [:shift]] and
          not dashboard_close?(code, mods, state) ->
        result({:dashboard_filter, {:append, code}})

      # Ctrl-R toggles the palette shut. Every other printable keystroke types
      # into its filter, so unlike the dashboard the palette has no bare-letter
      # close key: Esc and Ctrl-R close it, "q" and "b" are query characters.
      match?({:run_palette, _}, layer) and phase == :press and code == "r" and
          mods == [:control] ->
        result(:close_top_layer)

      match?({:run_palette, _}, layer) and phase in [:press, :repeat] and
        code == :backspace and mods == [] ->
        result({:dashboard_filter, :backspace})

      # Letter keys arrive as text fragments, so a printable fragment with no
      # command modifier is typing into the filter rather than a binding.
      match?({:run_palette, _}, layer) and phase in [:press, :repeat] and
        is_binary(code) and mods in [[], [:shift]] ->
        result({:dashboard_filter, {:append, code}})

      match?({:jump, _}, layer) and code == "g" and mods == [] and phase == :press ->
        result({:move, :first})

      field != nil and state.focus == "query" and code in [:left, :right, :home, :end] ->
        editor_key(code, mods, phase, state, table)

      (match?({:approval, _}, layer) or match?({:command_report, _}, layer)) and
        code in [:page_up, :page_down, :home, :end] and mods == [] ->
        operation =
          case code do
            :home -> :first
            :end -> :last
            :page_up -> {:page, -1}
            :page_down -> {:page, 1}
          end

        result({:scroll, "dialog", operation})

      match?({:research_form, _}, layer) and state.focus == "question" and
          code in [:left, :right, :home, :end] ->
        editor_key(code, mods, phase, state, table)

      match?({:feature_form, _, _}, layer) and String.starts_with?(state.focus, "field:") and
        code in [:left, :right] and mods == [] and phase == :press ->
        key = String.replace_prefix(state.focus, "field:", "")

        if SwarmCodeCLI.UI.FeatureForm.choice?(state, key),
          do: result({:feature_cycle, key, if(code == :right, do: 1, else: -1)}),
          else: editor_key(code, mods, phase, state, table)

      code in [:up, :down, :left, :right] and mods == [] ->
        result({:focus_cycle, if(code in [:up, :left], do: :previous, else: :next)})

      code == :enter and mods == [] and phase == :press ->
        modal_activate(layer, state, table)

      match?({:library, _}, layer) and code in [:page_up, :page_down] and mods == [] and
          phase == :press ->
        result({:library_page, if(code == :page_up, do: :previous, else: :next)})

      code == "b" and mods == [] and phase == :press and is_nil(field) and
        not match?({:research_form, _}, layer) and not match?({:feature_form, _, _}, layer) ->
        result(:close_top_layer)

      field != nil and state.focus not in ["cancel", "confirm"] ->
        editor_key(code, mods, phase, state, table)

      editor_context(state) != nil ->
        editor_key(code, mods, phase, state, table)

      match?({:question, _}, layer) ->
        question_key(code, mods, phase, state, table)

      match?({:approval, _}, layer) ->
        approval_key(code, mods, phase, state, table)

      true ->
        :ignore
    end
  end

  # The dashboard's close letters while its filter is empty. Ctrl-G always
  # closes; "q" and "b" are typing once a query has been started.
  defp dashboard_close?(code, mods, state) do
    (code == "g" and mods == [:control]) or
      (code in ["q", "b"] and mods == [] and State.runs_filter(state) == "")
  end

  defp tiny_exit("X", modifiers, :press, %{
         layers: [{:unsent_changes, kind} | _],
         exit_pending: kind
       })
       when modifiers in [[], [:shift]] do
    if kind == :plain,
      do: result({:presenter_handoff_confirmed, :plain}),
      else: result({:quit_confirmed, :detach})
  end

  defp tiny_exit(_, _, _, _), do: :ignore

  defp modal_activate(_, %{focus: focus}, _) when focus in ["cancel", "close"],
    do: result(:close_top_layer)

  defp modal_activate({:unsent_changes, kind}, %{focus: "confirm"} = state, table) do
    target =
      if kind == :plain,
        do: {:presenter_handoff_confirmed, :plain},
        else: {:quit_confirmed, :detach}

    activate({:local, target}, state, table)
  end

  defp modal_activate({:confirm_intent, intent}, %{focus: "confirm"} = state, table),
    do: activate({:intent, intent}, state, table)

  defp modal_activate({:question, id}, state, table) do
    case Map.get(state.read_model.interactions, id) do
      nil ->
        :ignore

      %{question: %{multiple: true}} when state.focus not in ["submit", "other"] ->
        activate({:local, {:select_option, id, state.focus}}, state, table)

      item ->
        case Question.answer_intent(state, item, state.focus) do
          :ignore -> :ignore
          intent -> activate({:intent, intent}, state, table)
        end
    end
  end

  defp modal_activate({:approval, _}, state, table),
    do: approval_key(state.focus, [], :press, state, table)

  defp modal_activate({:library, _}, %{focus: focus} = state, _) do
    case SwarmCodeCLI.UI.Library.activation(state, focus) do
      nil -> :ignore
      action -> result(action)
    end
  end

  defp modal_activate({:research_form, _}, %{focus: "start"}, _), do: result(:research_start)

  defp modal_activate({:research_form, _}, %{focus: focus}, _)
       when focus in ["low", "medium", "high", "ultra"],
       do: result({:research_depth, String.to_atom(focus)})

  defp modal_activate({:research_form, _}, _, _), do: :ignore

  defp modal_activate({:feature_form, _, _}, %{focus: "submit"}, _), do: result(:feature_submit)

  defp modal_activate({:feature_form, _, _}, %{focus: "field:" <> key} = state, _),
    do:
      if(SwarmCodeCLI.UI.FeatureForm.choice?(state, key),
        do: result({:feature_cycle, key, 1}),
        else: :ignore
      )

  defp modal_activate({:feature_form, _, _}, _, _), do: :ignore

  defp modal_activate({kind, _}, state, table) when kind in [:switcher, :action_menu] do
    entries = Switcher.visible(state, table)

    entry =
      Enum.find(entries, &(&1.id == state.focus)) ||
        if(state.focus == "query", do: List.first(entries))

    if entry, do: activate(entry.target, state, table), else: :ignore
  end

  defp modal_activate({kind, _}, state, table)
       when kind in [:runs_dashboard, :run_palette] do
    if Map.has_key?(state.read_model.runs, state.focus),
      do: activate({:local, {:navigate, {:run, state.focus}}}, state, table),
      else: :ignore
  end

  defp modal_activate({:run_inspector, run_id, _}, state, table) do
    agent_id = state.focus
    find_target(state, table, &match?({:intent, {:stop_agent, ^run_id, ^agent_id, _}}, &1))
  end

  defp modal_activate({:detail, _, _}, state, table) do
    direction =
      case state.focus do
        "next" -> :next
        "previous" -> :previous
        _ -> nil
      end

    if direction, do: activate({:local, {:detail_page, direction}}, state, table), else: :ignore
  end

  defp modal_activate(_, _, _), do: :ignore

  defp question_key(code, [], :press, state, table) do
    {:question, id} = hd(state.layers)

    case state.read_model.interactions[id] do
      %{state: :pending, question: %{options: options, multiple: multiple}} ->
        cond do
          code in ~w(1 2 3 4 5 6 7 8 9) ->
            option = Enum.at(options, String.to_integer(code) - 1)
            if option, do: result({:focus_region, option.id}), else: :ignore

          code == " " and multiple ->
            activate({:local, {:select_option, id, state.focus}}, state, table)

          true ->
            :ignore
        end

      _ ->
        :ignore
    end
  end

  defp question_key(_, _, _, _, _), do: :ignore

  defp approval_key("approval_details", [], :press, state, table) do
    {:approval, id} = hd(state.layers)

    case Map.get(state.read_model.interactions, id) do
      %{run_id: run, approval: %{arguments_detail_ref: %{id: ref}}} ->
        find_target(state, table, &(&1 == {:local, {:open_detail, run, ref}}))

      _ ->
        :ignore
    end
  end

  defp approval_key(code, [], :press, state, table) do
    decision =
      case code do
        value when value in ["a", "approve"] -> :approve
        value when value in ["d", "deny"] -> :deny
        value when value in ["A", "always_allow"] -> :always_allow
        _ -> nil
      end

    {:approval, id} = hd(state.layers)

    find_target(state, table, fn target ->
      match?({:intent, {:resolve_approval, _, _, ^id, _, ^decision}}, target)
    end)
  end

  defp approval_key(_, _, _, _, _), do: :ignore

  defp editor_key(code, mods, phase, state, table) do
    operation =
      cond do
        code == "o" and mods == [:control] ->
          :newline

        code == :enter and mods == [:shift] and state.capabilities.enhanced_keys == :supported ->
          :newline

        code == :backspace and mods == [] ->
          :delete_backward

        code == :delete and mods == [] ->
          :delete_forward

        code == :backspace and mods == [:alt] ->
          :delete_word_backward

        code == :delete and mods == [:alt] ->
          :delete_word_forward

        code == "a" and mods == [:control] ->
          :select_all

        code == "z" and mods == [:control] ->
          :undo

        code == "z" and mods == [:control, :shift] ->
          :redo

        code in [:left, :right, :up, :down, :home, :end] ->
          movement(code, mods)

        is_binary(code) and mods in [[], [:shift]] ->
          {:insert, code}

        true ->
          nil
      end

    cond do
      operation -> edit(state, operation)
      state.layers != [] -> :ignore
      true -> global(code, mods, phase, state, table)
    end
  end

  defp movement(code, mods) do
    base = Enum.reject(mods, &(&1 == :shift))

    movement =
      case {code, base} do
        {:left, [:alt]} -> :word_left
        {:right, [:alt]} -> :word_right
        {:home, [:control]} -> :buffer_start
        {:end, [:control]} -> :buffer_end
        {:home, []} -> :line_start
        {:end, []} -> :line_end
        {code, []} when code in [:left, :right, :up, :down] -> code
        _ -> nil
      end

    if movement, do: {if(:shift in mods, do: :extend_selection, else: :move), movement}
  end

  defp editor_context(%{layers: [layer | _]} = state) do
    cond do
      state.focus in ["cancel", "confirm"] ->
        nil

      Switcher.field_key(layer) ->
        {:field_editor, Switcher.field_key(layer)}

      match?({:question, _}, layer) and state.focus == "other" ->
        {:question, id} = layer

        case state.read_model.interactions[id] do
          %{state: :pending, expected_revision: revision} ->
            {:field_editor, {:question_other, id, revision}}

          _ ->
            nil
        end

      match?({:research_form, _}, layer) and state.focus == "question" ->
        {:research_form, owner} = layer

        if state.library.command_id == nil,
          do: {:field_editor, {:research_question, owner}},
          else: nil

      match?({:feature_form, _, _}, layer) and String.starts_with?(state.focus, "field:") ->
        case state.feature_form do
          %{command_id: nil, owner: owner} ->
            {:field_editor,
             {:feature_field, owner, String.replace_prefix(state.focus, "field:", "")}}

          _ ->
            nil
        end

      true ->
        nil
    end
  end

  defp editor_context(%{focus: "composer"} = state) do
    case State.current_draft_key(state) do
      nil -> nil
      key -> {:editor, key}
    end
  end

  defp editor_context(_), do: nil

  defp edit(state, operation) do
    case editor_context(state) do
      {kind, key} -> result({kind, key, operation})
      _ -> :ignore
    end
  end

  defp content(code, [], phase, state, table) do
    selected = Map.get(state.selection, state.focus)
    run_id = selected_run(state, selected)

    cond do
      code in [:down, "j"] ->
        result({:move, :next})

      code in [:up, "k"] ->
        result({:move, :previous})

      code in [:home] ->
        result({:move, :first})

      code == "G" ->
        result({:move, :last})

      code in [:page_up, :page_down] ->
        result({:scroll, state.focus, {:page, if(code == :page_up, do: -1, else: 1)}})

      code == :end ->
        result({:scroll, state.focus, :follow})

      code in ["h", "l"] and is_binary(selected) ->
        result({:expand, selected, code == "l"})

      code == :enter and phase == :press ->
        content_activate(state, table, selected)

      code == "o" and phase == :press ->
        find_target(state, table, &match?({:local, {:open_detail, ^run_id, _}}, &1))

      code in ["i", "t"] and phase == :press ->
        find_target(
          state,
          table,
          &match?({:local, {:open_layer, {:run_inspector, ^run_id, _}}}, &1)
        )

      code == "x" and phase == :press ->
        find_target(state, table, &match?({:intent, {:run_control, :stop, ^run_id}}, &1))

      code == "p" and phase == :press ->
        find_target(
          state,
          table,
          &match?({:intent, {:run_control, op, ^run_id}} when op in [:pause, :continue], &1)
        )

      code == "m" and phase == :press ->
        find_target(state, table, &match?({:intent, {:mark_seen, _, _, _}}, &1))

      code == "a" and phase == :press ->
        result({:open_layer, {:action_menu, elem(State.next_id(state, :layer), 0)}})

      code == "/" and phase == :press ->
        result({:open_layer, {:region_filter, state.focus}})

      true ->
        global(code, [], phase, state, table)
    end
  end

  defp content(code, mods, phase, state, table), do: global(code, mods, phase, state, table)

  defp selected_run(state, selected) do
    cond do
      Map.has_key?(state.read_model.runs, selected) -> selected
      state.read_model.transcript[selected] -> state.read_model.transcript[selected].run_id
      state.read_model.activity[selected] -> state.read_model.activity[selected].run_id
      state.read_model.agents[selected] -> state.read_model.agents[selected].run_id
      match?({:run, _}, state.destination) -> elem(state.destination, 1)
      true -> nil
    end
  end

  defp content_activate(state, table, selected) do
    activity = state.read_model.activity[selected]

    cond do
      activity && activity.interaction ->
        activate(
          {:local, {:open_layer, {activity.interaction.kind, activity.interaction.id}}},
          state,
          table
        )

      activity ->
        activate({:local, {:navigate, {:run, activity.run_id}}}, state, table)

      Map.has_key?(state.read_model.runs, selected) ->
        activate({:local, {:navigate, {:run, selected}}}, state, table)

      true ->
        find_target(state, table, &match?({:local, {:expand, ^selected, _}}, &1))
    end
  end

  defp global(_, _, phase, _, _) when phase != :press, do: :ignore

  defp global("k", [:control], :press, state, _),
    do: result({:open_layer, Switcher.open(state, state.focus)})

  defp global("g", [:control], :press, state, _),
    do: result({:open_layer, {:runs_dashboard, elem(State.next_id(state, :layer), 0)}})

  defp global("r", [:control], :press, state, _),
    do: result({:open_layer, {:run_palette, elem(State.next_id(state, :layer), 0)}})

  # The navigator is gone; Ctrl-B toggles the one pane there is left to toggle.
  defp global("b", [:control], :press, _, _), do: result({:toggle_dock, :inspector})
  defp global("i", [:alt], :press, _, _), do: result({:toggle_dock, :inspector})
  defp global("?", [], :press, _, _), do: result({:open_layer, :help})
  defp global("q", [], :press, _, _), do: result({:quit_requested, :detach})
  defp global("P", [], :press, _, _), do: result({:presenter_handoff_requested, :plain})

  defp global("g", [], :press, state, _),
    do: result({:open_layer, {:jump, elem(State.next_id(state, :layer), 0)}})

  defp global(code, [:alt], :press, _, _) when code in ~w(1 2 3 4) do
    result(
      {:set_tab, Enum.at([:thread, :agents, :timeline, :changes], String.to_integer(code) - 1)}
    )
  end

  defp global(code, mods, :press, state, _)
       when code in ["H", "L", "h", "l", "0"] and
              mods in [[:alt, :shift], [:alt, :control, :shift]] do
    # Only a pane the layout draws can be resized, and the navigator is not one.
    dock = if state.focus == "inspector", do: :inspector

    amount = if :control in mods, do: 8, else: 2

    adjustment =
      if code == "0",
        do: :reset,
        else: {:nudge, if(code in ["H", "h"], do: -amount, else: amount)}

    if dock, do: result({:layout_adjust, dock, adjustment}), else: :ignore
  end

  defp global(_, _, _, _, _), do: :ignore

  defp queue(state, table),
    do: find_target(state, table, &match?({:intent, {:dispatch, :queue, _, _, _}}, &1))

  defp find_target(state, table, predicate) do
    table
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.find(fn {_, target} -> predicate.(target) end)
    |> case do
      nil -> :ignore
      {_, target} -> activate(target, state, table)
    end
  end

  defp destructive?({:run_control, :stop, _}), do: true
  defp destructive?({:stop_agent, _, _, _}), do: true
  defp destructive?(_), do: false

  defp result(action) do
    case Action.validate(action) do
      {:ok, _} = ok -> ok
      _ -> :ignore
    end
  end
end
