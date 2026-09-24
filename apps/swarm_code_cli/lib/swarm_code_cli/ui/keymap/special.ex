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
  alias SwarmCodeCLI.UI.Reducer.PathCompletion
  alias SwarmCodeCLI.UI.Projector.RunsDashboard

  @type key :: {term(), [atom()]}

  @spec run(atom(), key(), map(), map()) :: {:ok, term()} | :ignore
  def run(name, key, state, table)

  # ---------------------------------------------------------------- layers

  # Ctrl-P opens the palette and never toggles it shut: a second press while it
  # is up puts the caret back in its query, so what is typed next lands there
  # and never in the composer behind it (rel F6).
  def run(:command_palette, _key, state, _table) do
    if match?([{:switcher, _} | _], state.layers),
      do: ok({:focus_region, "query"}),
      else: ok({:open_layer, Switcher.open(state, state.focus)})
  end

  # The sheet closes on the key that opened it, like every other layer here.
  def run(:help, _key, %{layers: [:help | _]}, _table), do: ok(:close_top_layer)
  def run(:help, _key, _state, _table), do: ok({:open_layer, :help})

  def run(:runs_dashboard, _key, state, _table),
    do: toggle_layer(state, :runs_dashboard)

  def run(:run_palette, _key, state, _table),
    do: toggle_layer(state, :run_palette)

  # The Ctrl-C ladder lives in the reducer: it knows the draft, the turn in
  # view and whether the second-press quit is armed.
  def run(:interrupt, _key, _state, _table), do: ok({:interrupt, :ctrl_c})

  # With vim on, Esc inside the composer walks the modes first: VISUAL to
  # NORMAL, INSERT to NORMAL, a pending operator cancelled, and a bare NORMAL
  # stops a streaming turn like the plain composer's Esc.
  def run(:escape, _key, %{keymap: :vim, focus: "composer", layers: []} = state, _table),
    do: Keymap.Vim.escape(state)

  # Esc steps out exactly one level and never navigates or leaves the
  # composer: the dashboard and the palette drop their query first, then any
  # layer closes, select mode hands back to the composer, and in the composer
  # it stops a streaming turn (the reducer does nothing when none streams).
  # `:back` lives on Alt-Left and Backspace.
  def run(:escape, _key, state, _table) do
    cond do
      filtering?(state) -> ok({:dashboard_filter, :clear})
      PathCompletion.open?(state) -> ok(:dismiss_completion)
      state.layers != [] -> ok(:close_top_layer)
      state.focus in ["main", "inspector"] -> ok({:focus_region, "composer"})
      true -> ok({:interrupt, :escape})
    end
  end

  # Ctrl-T enters select mode from the composer and leaves it from the
  # transcript or the inspector.
  def run(:select_mode, _key, _state, _table), do: ok(:select_mode)

  # Ctrl-X: the draft goes to $VISUAL/$EDITOR and comes back when it exits.
  def run(:external_editor, _key, state, _table) do
    case State.current_draft_key(state) do
      nil -> :ignore
      key -> ok({:external_editor, key})
    end
  end

  def run(:copy_selected, _key, _state, _table), do: ok(:copy_selection)

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

  # Tab never takes the caret out of the composer: it completes a slash
  # command, queues the draft while a turn runs (the non-Alt queue path), and
  # otherwise does nothing.
  def run(:focus_next, _key, %{focus: "composer", layers: []} = state, table) do
    case {PathCompletion.selected(state), SlashPalette.selected(state)} do
      {%{id: path}, _} -> ok({:complete_path, path})
      {nil, %{name: name}} -> ok({:complete_command, name})
      _ -> if Keymap.live_turn(state), do: run(:queue, nil, state, table), else: :ignore
    end
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

    # pass71 F2: the selected item's own detail when it has one.
    case Keymap.text_target(state, Map.get(state.selection, state.focus)) do
      {:local, {:open_detail, ^run_id, _}} = own ->
        case Keymap.find_target(state, table, &(&1 == own)) do
          :ignore ->
            Keymap.find_target(state, table, &match?({:local, {:open_detail, ^run_id, _}}, &1))

          resolved ->
            resolved
        end

      _ ->
        Keymap.find_target(state, table, &match?({:local, {:open_detail, ^run_id, _}}, &1))
    end
  end

  # ------------------------------------------------------- selection, scroll

  def run(:scroll_page_down, _key, state, _table), do: scroll(state, {:page, 1})
  def run(:scroll_page_up, _key, state, _table), do: scroll(state, {:page, -1})

  # On an empty draft there is nothing for Ctrl-U to delete or Ctrl-D to act
  # on, so they scroll the transcript the way they do in select mode.
  def run(:composer_half_up, _key, state, _table) do
    if Keymap.draft_text(state) == "",
      do: ok({:scroll, "main", {:half_page, -1}}),
      else: Keymap.edit(state, {:delete, :line_start})
  end

  def run(:composer_half_down, _key, state, _table) do
    if Keymap.draft_text(state) == "",
      do: ok({:scroll, "main", {:half_page, 1}}),
      else: :ignore
  end

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

  # Enter before the workspace has loaded has no Send target yet; it is kept
  # as one deferred send the reducer replays once the watch is ready (R2).
  def run(:activate, _key, %{focus: "composer"} = state, table) do
    case Keymap.find_target(state, table, &match?({:intent, {:dispatch, :send, _, _, _}}, &1)) do
      :ignore -> if Keymap.deferrable_send?(state), do: ok(:defer_send), else: :ignore
      resolved -> resolved
    end
  end

  def run(:activate, _key, state, table), do: Keymap.content_activate(state, table)

  # Enter in the composer, under its own name so the surfaces can say "Send".
  def run(:send, key, state, table), do: run(:activate, key, state, table)

  # The drawn Queue target when there is one; otherwise the draft as it
  # stands, which the reducer authorizes exactly like the drawn one.
  def run(:queue, _key, state, table) do
    case Keymap.find_target(
           state,
           table,
           &match?({:intent, {:dispatch, :queue, _, _, _}}, &1)
         ) do
      :ignore -> Keymap.draft_dispatch(state, :queue)
      resolved -> resolved
    end
  end

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
  def run(:deny_stop, _key, state, table), do: Keymap.approval_key("D", state, table)
  def run(:approve_run, _key, state, table), do: Keymap.approval_key("Y", state, table)
  def run(:always_allow, _key, state, table), do: Keymap.approval_key("A", state, table)

  def run(:confirm_yes, _key, %{layers: [{:approval, _} | _]} = state, table),
    do: Keymap.approval_key("y", state, table)

  def run(:confirm_yes, _key, %{layers: [layer | _]} = state, table) do
    if confirmable?(layer),
      do: Keymap.modal_activate(layer, %{state | focus: "confirm"}, table),
      else: :ignore
  end

  # "n" on an approval or a question is "the next one waiting": this one
  # stays pending and comes back round.
  def run(:confirm_no, key, %{layers: [{kind, _} | _]} = state, table)
      when kind in [:approval, :question],
      do: run(:next_need, key, state, table)

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

  # ------------------------------------------------------- waiting on you

  # `n` and `N` walk the approvals and questions waiting on the user, across
  # every run, in the order the tab row shows the runs: the run in view first,
  # then the rest by recency. From inside one of those dialogs the walk
  # continues from it; from anywhere else it starts at the run in view. Both
  # keys wrap, and both say so when nothing is waiting rather than doing
  # nothing in silence.
  def run(name, _key, state, _table) when name in [:next_need, :previous_need] do
    case waiting_step(state, if(name == :next_need, do: 1, else: -1)) do
      nil -> ok(:nothing_waiting)
      id -> ok({:open_interaction, id})
    end
  end

  # ------------------------------------------------------- pass72: hints

  # A badge letter, a run digit or `0` (the runs dashboard): the reducer holds
  # the labels and decides.
  def run(:hint_key, {code, _mods}, _state, _table), do: ok({:hint, {:key, code}})

  # The overlay's letters act only while its composer is empty (K4, K5);
  # with text in it they type. `y a Y A d D n` also need a request waiting on
  # this agent, or they start a steer like any other letter; `o [ ]` act
  # from the band and the activity, and type once Tab has put the focus in
  # the composer.
  def run(:overlay_letter, {code, []}, %{overlay: %{} = overlay} = state, _table) do
    empty? = Keymap.draft_text(state) == ""
    composer? = overlay.focus == :composer
    waiting? = SwarmCodeCLI.UI.Reducer.Overlay.request(state) != nil

    cond do
      not empty? -> :ignore
      code in ~w(y a Y A d D n) and waiting? -> ok({:overlay, {:answer, code}})
      code in ~w(y a Y A d D n) or composer? -> :ignore
      code == "]" -> ok({:overlay, {:step, :next}})
      code == "[" -> ok({:overlay, {:step, :previous}})
      code == "o" -> ok({:overlay, :raw_ops})
      true -> :ignore
    end
  end

  def run(:overlay_letter, _key, _state, _table), do: :ignore

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

  defp waiting_step(state, step) do
    waiting = waiting_ids(state)

    case waiting do
      [] ->
        nil

      _ ->
        current =
          case state.layers do
            [{kind, id} | _] when kind in [:question, :approval] ->
              Enum.find_index(waiting, &(&1 == id))

            _ ->
              nil
          end

        index =
          case {current, step} do
            {nil, 1} -> 0
            {nil, _} -> length(waiting) - 1
            {at, _} -> Integer.mod(at + step, length(waiting))
          end

        Enum.at(waiting, index)
    end
  end

  # Pending interactions in tab order, then by id inside a run, so the walk is
  # the one the user can predict from the row above the transcript.
  defp waiting_ids(state) do
    by_run =
      state.read_model.interactions
      |> Map.values()
      |> Enum.filter(&(&1.state == :pending))
      |> Enum.group_by(& &1.run_id)

    run_order = SwarmCodeCLI.UI.Projector.Shell.tabline_runs(state) |> Enum.map(& &1.id)
    stray = Map.keys(by_run) -- run_order

    Enum.flat_map(run_order ++ Enum.sort(stray), fn run_id ->
      by_run |> Map.get(run_id, []) |> Enum.map(& &1.id) |> Enum.sort()
    end)
  end

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

  # From the composer the page keys scroll the transcript: the caret stays put.
  defp scroll(%{focus: focus}, operation) when focus in ["main", "inspector"],
    do: ok({:scroll, focus, operation})

  defp scroll(_state, operation), do: ok({:scroll, "main", operation})

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

  # Up on an empty draft (and Up or Down while walking the history) reads
  # the prompts already sent in this conversation; otherwise the arrows move
  # the caret, or the selection of an open slash list.
  defp composer_line(state, direction, movement) do
    cond do
      SlashPalette.open?(state) or PathCompletion.open?(state) -> ok({:move, direction})
      history?(state, direction) -> ok({:history, direction})
      true -> Keymap.edit(state, {:move, movement})
    end
  end

  defp history?(%{history_cursor: {key, _, _}} = state, _direction),
    do: key == State.current_draft_key(state)

  # The reducer reads the history (sent prompts, then the transcript's user
  # turns); an empty draft is all it takes to start walking it.
  defp history?(state, :previous),
    do: State.current_draft_key(state) != nil and Keymap.draft_text(state) == ""

  defp history?(_state, _direction), do: false

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
