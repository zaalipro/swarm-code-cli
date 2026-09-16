defmodule SwarmCodeCLI.UI.Keymap.Special do
  @moduledoc """
  The table entries whose action needs state.

  Module attributes cannot hold anonymous functions, so a binding whose action
  depends on the state (the next layer id, the selected run, whether the
  inspector is on screen at all) carries the symbolic `{:special, name}` and is
  resolved here.

  `run/4` returns `{:ok, action}` or `:ignore`. An `:ignore` is not the end of
  resolution: the caller falls through to typing, which is what lets the go-to
  popup own `g`/`G`/`t`/`T` inside a `:picker` context while the same letters
  still type into a switcher's query.
  """

  alias SwarmCodeCLI.UI.{Keymap, Layout, SlashPalette, State, Switcher}
  alias SwarmCodeCLI.UI.Keymap.Bindings
  alias SwarmCodeCLI.UI.Projector.RunsDashboard

  @type key :: {term(), [atom()]}

  @spec run(atom(), key(), map(), map()) :: {:ok, term()} | :ignore
  def run(name, key, state, table)

  # ---------------------------------------------------------------- layers

  def run(:command_palette, _key, state, _table) do
    if match?([{:switcher, _} | _], state.layers),
      do: ok(:close_top_layer),
      else: ok({:open_layer, Switcher.open(state, state.focus)})
  end

  # The sheet closes on the key that opened it, like every other layer here.
  def run(:help, _key, %{layers: [:help | _]}, _table), do: ok(:close_top_layer)
  def run(:help, _key, _state, _table), do: ok({:open_layer, :help})

  def run(:runs_dashboard, _key, state, _table),
    do: toggle_layer(state, :runs_dashboard)

  def run(:run_palette, _key, state, _table),
    do: toggle_layer(state, :run_palette)

  def run(:detach, _key, state, _table) do
    if Keymap.editor_context(state),
      do: ok(:editor_detach_notice),
      else: ok({:quit_requested, :detach})
  end

  # With vim on, Esc inside the composer walks the modes first: VISUAL to
  # NORMAL, INSERT to NORMAL, a pending operator cancelled, and only a bare
  # NORMAL hands focus back to main.
  def run(:escape, _key, %{keymap: :vim, focus: "composer", layers: []} = state, _table),
    do: Keymap.Vim.escape(state)

  # Esc steps out exactly one level and never navigates: the dashboard and the
  # palette drop their query first, then any layer closes, then the composer
  # hands focus back to main. `:back` lives on Alt-Left and Backspace.
  def run(:escape, _key, state, _table) do
    cond do
      filtering?(state) -> ok({:dashboard_filter, :clear})
      state.layers != [] -> ok(:close_top_layer)
      state.focus == "composer" -> ok({:focus_region, "main"})
      true -> :ignore
    end
  end

  # "q" closes the top layer and only quits when there is none. Inside a run
  # view it closes while the filter is empty and types once a query has been
  # started, because a filter could never usefully spell "query".
  def run(:close_or_quit, _key, state, _table) do
    cond do
      match?([{:runs_dashboard, _} | _], state.layers) and not filtering?(state) ->
        ok(:close_top_layer)

      Keymap.Context.of(state) == :picker ->
        :ignore

      state.layers != [] ->
        ok(:close_top_layer)

      true ->
        ok({:quit_requested, :detach})
    end
  end

  def run(:focus_next, _key, %{focus: "main", layers: []} = state, _table) do
    layout = Layout.calculate(state.size, state.preferences)

    if Map.has_key?(layout.rects, :composer),
      do: ok({:focus_region, "composer"}),
      else: ok({:focus_cycle, :next})
  end

  def run(:focus_next, _key, state, _table) do
    case SlashPalette.selected(state) do
      %{name: name} -> ok({:complete_command, name})
      nil -> ok({:focus_cycle, :next})
    end
  end

  def run(:layout_narrower, {_, mods}, state, _table),
    do: layout_adjust(state, {:nudge, -step(mods)})

  def run(:layout_wider, {_, mods}, state, _table),
    do: layout_adjust(state, {:nudge, step(mods)})

  def run(:layout_reset, _key, state, _table), do: layout_adjust(state, :reset)

  # ------------------------------------------------------------------ runs

  def run(:jump, _key, state, _table),
    do: ok({:open_layer, {:jump, elem(State.next_id(state, :layer), 0)}})

  def run(:jump_first, _key, state, _table), do: jump(state, {:move, :first})
  def run(:jump_last, _key, state, _table), do: jump(state, {:move, :last})
  def run(:jump_run_next, _key, state, _table), do: jump(state, {:run_tab, :next})
  def run(:jump_run_previous, _key, state, _table), do: jump(state, {:run_tab, :previous})

  def run(:inspector_tab_next, _key, state, _table), do: inspector_tab(state, :next)
  def run(:inspector_tab_previous, _key, state, _table), do: inspector_tab(state, :previous)

  def run(:stop_run, _key, state, table) do
    run_id = current_run(state)
    Keymap.find_target(state, table, &match?({:intent, {:run_control, :stop, ^run_id}}, &1))
  end

  def run(:pause_run, _key, state, table) do
    run_id = current_run(state)

    Keymap.find_target(
      state,
      table,
      &match?({:intent, {:run_control, op, ^run_id}} when op in [:pause, :continue], &1)
    )
  end

  def run(:mark_seen, _key, state, table),
    do: Keymap.find_target(state, table, &match?({:intent, {:mark_seen, _, _, _}}, &1))

  def run(:action_menu, _key, state, _table),
    do: ok({:open_layer, {:action_menu, elem(State.next_id(state, :layer), 0)}})

  def run(:run_inspector, _key, state, table) do
    run_id = current_run(state)

    Keymap.find_target(
      state,
      table,
      &match?({:local, {:open_layer, {:run_inspector, ^run_id, _}}}, &1)
    )
  end

  def run(:open_detail, _key, state, table) do
    run_id = current_run(state)
    Keymap.find_target(state, table, &match?({:local, {:open_detail, ^run_id, _}}, &1))
  end

  # ------------------------------------------------------- selection, scroll

  def run(:scroll_page_down, _key, state, _table), do: scroll(state, {:page, 1})
  def run(:scroll_page_up, _key, state, _table), do: scroll(state, {:page, -1})
  def run(:scroll_half_down, _key, state, _table), do: scroll(state, {:half_page, 1})
  def run(:scroll_half_up, _key, state, _table), do: scroll(state, {:half_page, -1})
  def run(:scroll_line_down, _key, state, _table), do: scroll(state, {:line, 1})
  def run(:scroll_line_up, _key, state, _table), do: scroll(state, {:line, -1})

  def run(:collapse, _key, state, _table), do: expansion(state, false)
  def run(:expand, _key, state, _table), do: expansion(state, true)

  def run(:toggle_expand, _key, state, _table) do
    case selected(state) do
      id when is_binary(id) -> ok({:expand, id, not MapSet.member?(state.expansions, id)})
      _ -> :ignore
    end
  end

  def run(:activate, _key, %{layers: [layer | _]} = state, table),
    do: Keymap.modal_activate(layer, state, table)

  def run(:activate, _key, %{focus: "composer"} = state, table),
    do: Keymap.find_target(state, table, &match?({:intent, {:dispatch, :send, _, _, _}}, &1))

  def run(:activate, _key, state, table), do: Keymap.content_activate(state, table)

  # Enter in the composer, under its own name so the surfaces can say "Send".
  def run(:send, key, state, table), do: run(:activate, key, state, table)

  def run(:queue, _key, state, table),
    do: Keymap.find_target(state, table, &match?({:intent, {:dispatch, :queue, _, _, _}}, &1))

  # --------------------------------------------------------------- pickers

  def run(:picker_page_down, _key, state, _table), do: page_focus(state, :page_down)
  def run(:picker_page_up, _key, state, _table), do: page_focus(state, :page_up)
  def run(:picker_first, _key, state, _table), do: page_focus(state, :home)
  def run(:picker_last, _key, state, _table), do: page_focus(state, :end)

  # --------------------------------------------------------------- dialogs

  def run(:dialog_page_down, _key, state, _table), do: dialog_page(state, :next, {:page, 1})
  def run(:dialog_page_up, _key, state, _table), do: dialog_page(state, :previous, {:page, -1})

  def run(:approve, _key, state, table), do: Keymap.approval_key("a", state, table)
  def run(:deny, _key, state, table), do: Keymap.approval_key("d", state, table)
  def run(:always_allow, _key, state, table), do: Keymap.approval_key("A", state, table)

  def run(:confirm_yes, _key, %{layers: [layer | _]} = state, table) do
    if confirmable?(layer),
      do: Keymap.modal_activate(layer, %{state | focus: "confirm"}, table),
      else: :ignore
  end

  def run(:confirm_no, _key, %{layers: [layer | _]}, _table),
    do: if(confirmable?(layer), do: ok(:close_top_layer), else: :ignore)

  def run(:question_option, {code, _mods}, %{layers: [{:question, id} | _]} = state, _table) do
    case state.read_model.interactions[id] do
      %{state: :pending, question: %{options: options}} ->
        case Enum.at(options, String.to_integer(code) - 1) do
          %{id: option} -> ok({:focus_region, option})
          _ -> :ignore
        end

      _ ->
        :ignore
    end
  end

  def run(:question_option, _key, _state, _table), do: :ignore

  def run(:select_option, _key, %{layers: [{:question, id} | _]} = state, table) do
    case state.read_model.interactions[id] do
      %{state: :pending, question: %{multiple: true}} ->
        Keymap.activate({:local, {:select_option, id, state.focus}}, state, table)

      _ ->
        :ignore
    end
  end

  def run(:select_option, _key, _state, _table), do: :ignore

  # ---------------------------------------------------------------- fields

  def run(name, _key, state, _table) when name in [:field_left, :field_right] do
    direction = if name == :field_right, do: 1, else: -1

    with %{layers: [{:feature_form, _, _} | _], focus: "field:" <> field} <- state,
         true <- SwarmCodeCLI.UI.FeatureForm.choice?(state, field) do
      ok({:feature_cycle, field, direction})
    else
      _ -> Keymap.edit(state, {:move, if(direction == 1, do: :right, else: :left)})
    end
  end

  # -------------------------------------------------------------- composer

  def run(:composer_newline, {:enter, _}, state, _table) do
    if state.capabilities.enhanced_keys == :supported,
      do: Keymap.edit(state, :newline),
      else: :ignore
  end

  def run(:composer_newline, _key, state, _table), do: Keymap.edit(state, :newline)

  def run(:composer_up, _key, state, _table), do: composer_line(state, :previous, :up)
  def run(:composer_down, _key, state, _table), do: composer_line(state, :next, :down)

  # ------------------------------------------------------------------- vim

  # The composer's NORMAL and VISUAL rows, and `i` from the transcript, read
  # `state.vim`; they live with the rest of the vim grammar.
  def run(name, key, state, table) do
    if Keymap.Vim.special?(name), do: Keymap.Vim.run(name, key, state, table), else: :ignore
  end

  # ----------------------------------------------------------------- guts

  defp toggle_layer(state, kind) do
    if match?([{^kind, _} | _], state.layers),
      do: ok(:close_top_layer),
      else: ok({:open_layer, {kind, elem(State.next_id(state, :layer), 0)}})
  end

  defp filtering?(state) do
    match?([{kind, _} | _] when kind in [:runs_dashboard, :run_palette], state.layers) and
      State.runs_filter(state) != ""
  end

  defp layout_adjust(state, adjustment) do
    # Only a pane the layout draws can be resized, and the navigator is gone.
    if state.focus == "inspector",
      do: ok({:layout_adjust, :inspector, adjustment}),
      else: :ignore
  end

  defp step(mods), do: if(:control in mods, do: 8, else: 2)

  # The go-to popup is a which-key list: its keys act only while it is open, and
  # fall through to the filter of any other picker.
  defp jump(%{layers: [{:jump, _} | _]}, action), do: ok(action)
  defp jump(_state, _action), do: :ignore

  # `[` and `]` move the inspector's tabs whenever the inspector is on screen,
  # docked by the layout or opened as a run_inspector overlay.
  defp inspector_tab(state, direction) do
    docked? =
      state.size
      |> Layout.calculate(state.preferences)
      |> Map.fetch!(:rects)
      |> Map.has_key?(:inspector)

    overlay? = Enum.any?(state.layers, &match?({:run_inspector, _, _}, &1))

    if docked? or overlay?, do: ok({:inspector_tab, direction}), else: :ignore
  end

  defp scroll(state, operation), do: ok({:scroll, state.focus, operation})

  defp expansion(state, expanded?) do
    case selected(state) do
      id when is_binary(id) -> ok({:expand, id, expanded?})
      _ -> :ignore
    end
  end

  defp selected(state), do: Map.get(state.selection, state.focus)

  defp current_run(state), do: Keymap.selected_run(state, selected(state))

  defp page_focus(%{layers: [{:runs_dashboard, _} | _]} = state, code) do
    case RunsDashboard.page_focus(state, code) do
      nil -> :ignore
      id -> ok({:focus_region, id})
    end
  end

  defp page_focus(_state, _code), do: :ignore

  # The library pages its own body rather than scrolling it, so PgUp/PgDn keep
  # meaning "the next page of this list" there.
  defp dialog_page(%{layers: [{:library, _} | _]}, direction, _operation),
    do: ok({:library_page, direction})

  defp dialog_page(_state, _direction, operation), do: ok({:scroll, "dialog", operation})

  defp confirmable?({:confirm_intent, _}), do: true
  defp confirmable?({:unsent_changes, _}), do: true
  defp confirmable?(_layer), do: false

  defp composer_line(state, direction, movement) do
    if SlashPalette.open?(state),
      do: ok({:move, direction}),
      else: Keymap.edit(state, {:move, movement})
  end

  defp ok(action), do: Keymap.result(action)

  @doc false
  @spec jump_action(binary()) :: term() | nil
  def jump_action(focus) do
    case Enum.find(Bindings.jump_rows(), fn {id, _, _} -> id == focus end) do
      {_, _, action} -> action
      nil -> nil
    end
  end
end
