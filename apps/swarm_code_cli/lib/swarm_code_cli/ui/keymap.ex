defmodule SwarmCodeCLI.UI.Keymap do
  @moduledoc "Single-action input resolution: modal, field, composer, content, global."
  alias SwarmCodeCLI.UI.{Action, Input, Layout, Question, State, Switcher}

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

  defp key(:escape, [], :press, %{layers: [_ | _]}, _), do: result(:close_top_layer)
  defp key(:escape, [], :press, %{focus: "composer"}, _), do: result({:focus_region, "main"})
  defp key(:escape, [], :press, _, _), do: result(:back)

  defp key("c", [:control], :press, state, _) do
    if editor_context(state),
      do: result(:editor_detach_notice),
      else: result({:quit_requested, :detach})
  end

  defp key(:tab, [], phase, _, _) when phase in [:press, :repeat],
    do: result({:focus_cycle, :next})

  defp key(code, mods, phase, _, _)
       when phase in [:press, :repeat] and
              ((code == :tab and mods == [:shift]) or (code == :back_tab and mods == [])),
       do: result({:focus_cycle, :previous})

  defp key(code, mods, phase, %{layers: [_ | _]} = state, table),
    do: modal(code, mods, phase, state, table)

  defp key(code, mods, phase, %{focus: "composer"} = state, table) do
    cond do
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

      match?({:jump, _}, layer) and code == "g" and mods == [] and phase == :press ->
        result({:move, :first})

      field != nil and state.focus == "query" and code in [:left, :right, :home, :end] ->
        editor_key(code, mods, phase, state, table)

      match?({:approval, _}, layer) and code in [:page_up, :page_down, :home, :end] and mods == [] ->
        operation =
          case code do
            :home -> :first
            :end -> :last
            :page_up -> {:page, -1}
            :page_down -> {:page, 1}
          end

        result({:scroll, "dialog", operation})

      code in [:up, :down, :left, :right] and mods == [] ->
        result({:focus_cycle, if(code in [:up, :left], do: :previous, else: :next)})

      code == :enter and mods == [] and phase == :press ->
        modal_activate(layer, state, table)

      code == "b" and mods == [] and phase == :press and is_nil(field) ->
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

      %{question: %{multiple: true}} when state.focus != "submit" ->
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

  defp modal_activate({kind, _}, state, table) when kind in [:switcher, :action_menu] do
    entries = Switcher.visible(state, table)

    entry =
      Enum.find(entries, &(&1.id == state.focus)) ||
        if(state.focus == "query", do: List.first(entries))

    if entry, do: activate(entry.target, state, table), else: :ignore
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

  defp global("b", [:control], :press, _, _), do: result({:toggle_dock, :navigator})
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
    dock =
      case state.focus do
        "navigator" -> :navigator
        "inspector" -> :inspector
        _ -> nil
      end

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
