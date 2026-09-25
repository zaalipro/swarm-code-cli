defmodule SwarmCodeCLI.UI.Reducer do
  @moduledoc "Pure semantic transitions. Every clock, identifier seed and external fact comes from the owner."
  alias SwarmCodeCLI.UI.{
    Action,
    Init,
    State,
    WatchState,
    Draft,
    Drafts,
    Editor,
    FieldEditors,
    Layout,
    ModelPicker,
    SafeText,
    FeatureForm
  }

  alias SwarmCodeCLI.UI.Layout.Preferences
  alias SwarmCodeCLI.UI.Keymap
  alias SwarmCodeCLI.UI.Keymap.Bindings
  alias SwarmCodeCLI.UI.Projector.RunRow
  alias SwarmCodeCLI.UI.Vim
  alias SwarmCodeCLI.UI.SlashPalette
  alias SwarmCodeCLI.UI.Reducer.{Watch, Commands, Pages, Editing, Details, PathCompletion}
  alias SwarmCodeCLI.UI.Reducer.Hint, as: Hints
  alias SwarmCodeCLI.UI.Reducer.Overlay
  alias SwarmCodeCLI.UI.Reducer.{Deliveries, Display}
  alias SwarmCodeCLI.UI.WorkflowKeyword
  alias SwarmCodeCLI.UI.Hint
  alias SwarmCodeCLI.UI.DataSource.DTO.Outcome
  alias SwarmCodeCLI.UI.Projector.{RunPalette, RunsDashboard}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Request}

  # The query is drawn on the dashboard header line beside the counts, so it is
  # bounded rather than allowed to grow with every keystroke.
  @max_filter_length 64

  # A second Ctrl-C within this window quits.
  @quit_window_ms 1_500
  # An approval or question that opened by itself takes keys only after the
  # user has paused typing this long.
  @grace_ms 700
  # The run states a quit has to stop.
  @live_states [
    :queued,
    :running,
    :streaming,
    :waiting_question,
    :waiting_approval,
    :paused,
    :retrying
  ]
  # Prompt history: per conversation, newest first.
  @history_limit 100
  @history_conversations 16
  @history_max_bytes 65_536
  @dismissed_limit 64

  @spec init(Init.t()) :: {State.t(), [SwarmCodeCLI.UI.Effect.t()]}
  def init(%Init{} = init) do
    SwarmCodeCLI.UI.Size.validate!(init.size)
    Action.validate!({:terminal_capabilities, init.terminal_generation, init.capabilities})
    {:ok, _} = SwarmCodeCLI.UI.Destination.validate(init.destination)

    unless SwarmCodeCLI.UI.Intent.valid_id?(init.source_epoch) and
             init.banner in [nil, :live_banner, :persisted_banner] and
             init.focus in ["main", "composer"] and init.keymap in [:default, :vim] and
             init.panel_mode in [:full, :compact, :hidden] and
             is_boolean(init.show_diffs) and init.theme_mode in [:dark, :light] and
             init.theme_env in [nil, :dark, :light] and is_boolean(init.mouse?) and
             SwarmCodeCLI.UI.Intent.valid_id?(init.id_prefix) and is_integer(init.now) and
             init.now >= 0 and is_integer(init.deadline_ms) and init.deadline_ms >= 0 and
             is_integer(init.id_sequence) and init.id_sequence >= 0,
           do: raise(ArgumentError, "invalid reducer init")

    state = struct!(State, Map.from_struct(init))

    state = %{
      state
      | watches: Map.new([:shell, :workspace, :activity, :inspector], &{&1, %WatchState{}}),
        drafts: Drafts.new(ambiguous_width: init.capabilities.ambiguous_width),
        field_editors: FieldEditors.new(ambiguous_width: init.capabilities.ambiguous_width),
        panel_shown: shown_panel(init.panel_mode, :full)
    }

    {state, shell} = Watch.open(state, :shell, :global, nil)
    {state, destination} = open_destination(state, init.destination)

    effects = shell ++ destination
    Enum.each(effects, &SwarmCodeCLI.UI.Effect.validate!/1)
    {state, effects}
  end

  @spec update(State.t(), Action.t()) :: {State.t(), [SwarmCodeCLI.UI.Effect.t()]}
  def update(%State{} = state, action) do
    case Action.validate(action) do
      {:ok, action} ->
        {next, effects} = transition(leave_modes(state, action), action)
        next = drop_hint_under_layer(next)
        {next, effects} = replay_deferred(next, effects)
        {next, effects} = track_sent_turn(next, effects)
        {next, effects} = sync_interactions(next, effects, action)
        next = note_policy_change(state, next)
        next = hush_refusals(state, next)
        next = stamp_notice(state, next)
        next = repair_switcher(state, next)
        Enum.each(effects, &SwarmCodeCLI.UI.Effect.validate!/1)

        if next == state,
          do: {state, effects},
          else: {%{next | revision: state.revision + 1}, effects}

      {:error, _} ->
        {state, []}
    end
  end

  defp transition(state, :boot), do: {state, []}

  # ------------------------------------ pass72-O: the panel, hints, the overlay

  # Ctrl-B (K6): full -> compact -> hidden; under 120 columns the panel is a
  # strip, so the cycle is strip -> off. `/panel` sets it directly. Either
  # way the choice is written to the preferences file by the session.
  defp transition(state, {:panel_mode, :cycle}), do: set_panel(state, next_panel(state))
  defp transition(state, {:panel_mode, mode}), do: set_panel(state, mode)

  # pass73-K: /diff, /theme, /mouse (T1, T2, T9), their palette rows, and
  # the rest of cli.json once the session has read it.
  defp transition(state, {:show_diffs, value}), do: Display.set(state, :show_diffs, value)
  defp transition(state, {:theme_mode, value}), do: Display.set(state, :theme_mode, value)
  defp transition(state, {:mouse, value}), do: Display.set(state, :mouse, value)
  defp transition(state, {:preferences_loaded, loaded}), do: Display.loaded(state, loaded)

  # pass73-K T7: a row of the /approval picker sets the project's mode; the
  # picker closes, and the change is announced once the project says so
  # (`note_policy_change/2`).
  defp transition(state, {:approval_mode, mode}) do
    {state, closed} = close_switcher(state)
    {state, sent} = service_request(state, {:project_update, mode, nil}, {:project, :update})
    {state, closed ++ sent}
  end

  # pass73-K T4: Enter on the palette's highlighted command that takes no
  # argument writes it and runs it, as if it had been typed whole.
  defp transition(state, {:run_command, name}) do
    case State.current_draft_key(state) do
      nil ->
        {state, []}

      key ->
        {state, replaced} = replace_draft(state, key, "/" <> name)

        case Keymap.draft_send(state) do
          {:ok, action} ->
            {state, sent} = transition(state, action)
            {state, replaced ++ sent}

          :ignore ->
            {state, replaced}
        end
    end
  end

  # pass73-K T5: the opt-out key sends a message that names a workflow as the
  # plain message it is; anything else goes exactly as Enter sends it.
  defp transition(state, :send_plain) do
    text = Keymap.draft_text(state)

    action =
      if WorkflowKeyword.routes?(text),
        do: Keymap.draft_dispatch(state, :send),
        else: Keymap.draft_send(state)

    case action do
      {:ok, action} -> transition(state, action)
      :ignore -> {state, []}
    end
  end

  defp transition(state, {:panel_preferences_loaded, mode}),
    do: {%{state | panel_mode: mode, panel_shown: shown_panel(mode, state.panel_shown)}, []}

  # pass72 F: over a dialog, hint mode opens only from a request card (D9:
  # "^F <letter> opens the agent"); the other dialogs keep Ctrl-F inert.
  defp transition(%{layers: [layer | _]} = state, {:hint, :open})
       when not is_tuple(layer) or elem(layer, 0) not in [:approval, :question],
       do: {state, []}

  defp transition(state, {:hint, :open}) do
    case Hints.open(state) do
      nil -> feedback(state, "Nothing in the panel to open.")
      hint -> {%{state | hint: hint}, []}
    end
  end

  defp transition(%{hint: nil} = state, {:hint, _}), do: {state, []}
  defp transition(state, {:hint, :cancel}), do: {%{state | hint: nil}, []}

  defp transition(%{hint: %{typed: ""}} = state, {:hint, :backspace}),
    do: {%{state | hint: nil}, []}

  defp transition(%{hint: hint} = state, {:hint, :backspace}),
    do: {%{state | hint: %{hint | typed: ""}}, []}

  # The leader pressed again is Ctrl-N: the next request waiting on you.
  defp transition(state, {:hint, :again}) do
    state = %{state | hint: nil}

    case Keymap.Special.run(:next_need, {"n", [:control]}, state, %{}) do
      {:ok, action} -> transition(state, action)
      :ignore -> {state, []}
    end
  end

  defp transition(%{hint: %{typed: ""}} = state, {:hint, {:key, "0"}}) do
    {id, state} = State.next_id(%{state | hint: nil}, :layer)
    transition(Overlay.close(state), {:open_layer, {:runs_dashboard, id}})
  end

  defp transition(%{hint: hint} = state, {:hint, {:key, key}}) do
    typed = hint.typed <> key

    case Hint.match(hint.labels, typed) do
      {:target, {:agent, run, node}} ->
        transition(%{state | hint: nil}, {:overlay_open, run, node})

      {:target, {:run, run}} ->
        # P10: a run picked in the panel is shown in the chat. pass72 G1 (QA
        # Q1): the chat stays the destination (a run view has no composer
        # target) and the transcript scrolls to the run's first item.
        reveal_run(Overlay.close(%{state | hint: nil}), run)

      :prefix ->
        {%{state | hint: %{hint | typed: typed}}, []}

      :none ->
        {%{state | hint: nil}, []}
    end
  end

  # The overlay's band carries the request, so a request card on top gives
  # way (closed the way Esc closes it) before the overlay covers the chat.
  defp transition(%{layers: [{kind, _} | _]} = state, {:overlay_open, run, node})
       when kind in [:approval, :question] do
    {state, effects} = transition(state, :close_top_layer)
    {state, more} = transition(state, {:overlay_open, run, node})
    {state, effects ++ more}
  end

  defp transition(state, {:overlay_open, run, node}) do
    case Overlay.open(state, run, node) do
      {:ok, next} -> Overlay.request_detail(next)
      {:error, text} -> feedback(state, text)
    end
  end

  defp transition(%{overlay: nil} = state, {:overlay, _}), do: {state, []}
  defp transition(state, {:overlay, :close}), do: {Overlay.close(state), []}

  defp transition(%{overlay: overlay} = state, {:overlay, :raw_ops}),
    do:
      {%{
         state
         | overlay: %{overlay | raw_ops?: not overlay.raw_ops?, cursor: 0, focus: :activity}
       }, []}

  defp transition(state, {:overlay, {:focus, direction}}),
    do: {Overlay.cycle(state, direction), []}

  defp transition(state, {:overlay, {:step, direction}}) do
    case Overlay.step(state, direction) do
      nil -> {state, []}
      agent -> transition(state, {:overlay_open, agent.run_id, agent.id})
    end
  end

  # pass73 T9: the wheel moves the overlay's activity by lines and leaves
  # the focus where it is (the wheel never moves focus).
  defp transition(%{overlay: overlay} = state, {:overlay, {:scroll, lines}}) do
    rows = SwarmCodeCLI.UI.Projector.Overlay.cursor_rows(state)
    cursor = (overlay.cursor + lines) |> min(max(rows - 1, 0)) |> max(0)
    {%{state | overlay: %{overlay | cursor: cursor}}, []}
  end

  defp transition(%{overlay: overlay} = state, {:overlay, {:move, direction}}) do
    rows = SwarmCodeCLI.UI.Projector.Overlay.cursor_rows(state)
    page = max(1, div(state.size.rows, 2))

    cursor =
      case direction do
        :down -> overlay.cursor + 1
        :up -> overlay.cursor - 1
        :page_down -> overlay.cursor + page
        :page_up -> overlay.cursor - page
        :first -> 0
        :last -> rows - 1
      end

    cursor = cursor |> min(max(rows - 1, 0)) |> max(0)
    focus = if overlay.focus == :band, do: :activity, else: overlay.focus
    {%{state | overlay: %{overlay | cursor: cursor, focus: focus}}, []}
  end

  defp transition(%{overlay: overlay} = state, {:overlay, :activate}) do
    case overlay.focus do
      :composer ->
        case Overlay.steer(state) do
          nil ->
            {state, []}

          {:steer, run, node, text, _} = intent ->
            name =
              case Map.get(state.read_model.agents, node) do
                %{name: name} when is_binary(name) and name != "" -> name
                _ -> "the agent"
              end

            steers = Enum.take([{run, String.trim(text), node, name} | state.steers], 50)

            transition(
              %{state | steers: steers},
              {:invoke, intent, elem(State.next_id(state, :request), 0)}
            )
        end

      :band ->
        case Overlay.request(state) do
          nil -> {state, []}
          item -> transition(state, {:open_interaction, item.id})
        end

      :activity ->
        case SwarmCodeCLI.UI.Projector.Overlay.activate_target(state, overlay.cursor) do
          nil ->
            {state, []}

          {:open_detail, run, ref} ->
            transition(state, {:open_detail, run, ref})

          {:expand, key} ->
            expanded =
              if MapSet.member?(overlay.expanded, key),
                do: MapSet.delete(overlay.expanded, key),
                else: MapSet.put(overlay.expanded, key)

            {%{state | overlay: %{overlay | expanded: expanded}}, []}
        end
    end
  end

  defp transition(state, {:overlay, {:answer, "n"}}) do
    case Overlay.next_needing(state) do
      nil -> transition(state, :nothing_waiting)
      {run, node} -> transition(state, {:overlay_open, run, node})
    end
  end

  defp transition(state, {:overlay, {:answer, code}}) do
    case {Overlay.decision(state, code), Overlay.request(state)} do
      {nil, %{kind: :question, id: id}} ->
        transition(state, {:open_interaction, id})

      {nil, _} ->
        {state, []}

      {intent, _} ->
        transition(state, {:invoke, intent, elem(State.next_id(state, :request), 0)})
    end
  end

  # Typing anywhere in the overlay types into its composer and puts the focus
  # there.
  defp transition(
         %{overlay: %{draft_key: key, focus: focus} = overlay} = state,
         {:editor, key, _} = action
       )
       when focus != :composer,
       do: transition(%{state | overlay: %{overlay | focus: :composer}}, action)

  # ------------------------------------------------ the composer-first keys

  # Esc in the composer stops the turn that is generating, and nothing else.
  # A turn that was sent but is not on screen yet is that turn (I3).
  defp transition(state, {:interrupt, :escape}) do
    case Keymap.live_turn(state) do
      %{id: id, allowed_actions: actions} = _turn ->
        if :stop in actions, do: stop_turn(state, id), else: {state, []}

      nil ->
        case stop_unseen_turn(state) do
          {:ok, next} -> {next, []}
          :none -> {state, []}
        end
    end
  end

  # Ctrl-C (pass71 R1): a press closes the top layer, else clears the draft,
  # else stops the turn in view (or the one just sent, I3). Such a press never
  # arms the quit and disarms one that was armed. Only a press that has
  # nothing else to do arms it, and a second such press inside the window
  # quits (asking first when runs are live, and confirming that question when
  # it is already on screen).
  defp transition(%{layers: [{:unsent_changes, kind} | _], exit_pending: kind} = state, {
         :interrupt,
         :ctrl_c
       }),
       do: finish_exit(disarm_quit(state), kind)

  defp transition(state, {:interrupt, :ctrl_c}) do
    turn = Keymap.live_turn(state, @live_states)
    key = State.current_draft_key(state)

    acted =
      cond do
        # pass73 G1 (QA Q1-02): a draft typed under a card that opened by
        # itself is cleared first; the next press puts the card aside.
        Keymap.typing_under_card?(state) and not sending?(state, key) ->
          clear_draft(state, key)

        state.layers != [] ->
          transition(state, :close_top_layer)

        state.overlay != nil ->
          {Overlay.close(state), []}

        key != nil and Keymap.draft_text(state) != "" and not sending?(state, key) ->
          clear_draft(state, key)

        turn != nil and :stop in turn.allowed_actions ->
          case stop_turn(state, turn.id) do
            {_, []} -> :idle
            stopped -> stopped
          end

        turn == nil ->
          case stop_unseen_turn(state) do
            {:ok, next} -> {next, []}
            :none -> :idle
          end

        true ->
          :idle
      end

    case {acted, state.quit_armed} do
      {:idle, nil} ->
        arm_quit(state)

      {:idle, armed} ->
        {state, effects} = exit_requested(disarm_quit(state), :detach)
        {state, [{:cancel_timer, armed} | effects]}

      {{next, effects}, nil} ->
        {next, effects}

      {{next, effects}, armed} ->
        next = disarm_quit(next)

        next =
          if next.notice == {:command_feedback, quit_hint()},
            do: %{next | notice: nil},
            else: next

        {next, [{:cancel_timer, armed} | effects]}
    end
  end

  # Enter typed before the workspace was ready (R2): kept, one at most, and
  # replayed by `replay_deferred/2` once the watch is.
  defp transition(state, :defer_send) do
    case State.current_draft_key(state) do
      nil ->
        {state, []}

      key ->
        {%{
           state
           | deferred_send: {key, Keymap.draft_text(state)},
             notice: {:command_feedback, "Sends once the conversation has loaded."}
         }, []}
    end
  end

  defp transition(%{quit_armed: id} = state, {:timer_fired, id}) do
    state = disarm_quit(state)

    state =
      if state.notice == {:command_feedback, quit_hint()},
        do: %{state | notice: nil},
        else: state

    {state, []}
  end

  defp transition(%{interaction_grace: id} = state, {:timer_fired, id}),
    do: {%{state | interaction_grace: nil}, []}

  # Select mode is the transcript (or inspector) holding the focus: j/k move,
  # Enter opens, y copies, Esc or Ctrl-T hands back to the composer.
  defp transition(%{focus: focus} = state, :select_mode) when focus in ["main", "inspector"],
    do: transition(state, {:focus_region, "composer"})

  defp transition(%{layers: []} = state, :select_mode) do
    {next, effects} = transition(state, {:focus_region, "main"})

    if next.focus == "main" do
      ids =
        Map.get(
          next.read_model.order,
          if(next.destination == :activity, do: :activity, else: :workspace),
          []
        )

      next =
        if Map.get(next.selection, "main") in ids or ids == [],
          do: next,
          else: %{next | selection: Map.put(next.selection, "main", List.last(ids))}

      {next, effects}
    else
      {next, effects}
    end
  end

  defp transition(state, :select_mode), do: {state, []}

  # A printable key select mode does not use goes back to the composer.
  defp transition(state, {:compose, text}) do
    {state, focused} =
      if state.keymap == :vim,
        do: transition(state, {:vim, {:mode, :insert}}),
        else: transition(state, {:focus_region, "composer"})

    case {state.focus, State.current_draft_key(state)} do
      {"composer", key} when not is_nil(key) ->
        {state, typed} = transition(state, {:editor, key, {:insert, text}})
        {state, focused ++ typed}

      _ ->
        {state, focused}
    end
  end

  defp transition(state, :copy_selection) do
    id = Map.get(state.selection, state.focus)

    text =
      case id && SwarmCodeCLI.UI.ReadModel.transcript_item(state.read_model, id) do
        %{text: text} when is_binary(text) and text != "" -> text
        _ -> nil
      end

    cond do
      text == nil ->
        {%{state | notice: {:command_feedback, "Nothing to copy here."}}, []}

      byte_size(text) > SwarmCodeCLI.UI.Effect.max_copy_bytes() ->
        {%{state | notice: {:command_feedback, "Too long to copy; open it with o instead."}}, []}

      true ->
        # The runtime says "Copied" once the terminal acknowledges it.
        {state, [{:copy, text}]}
    end
  end

  defp transition(state, {:history, direction}), do: history(state, direction)

  # A pick in the palette or /resume: the service switches its conversation,
  # and the accepted outcome moves the view (settle_command).
  defp transition(state, {:open_conversation, id}) do
    {state, closed} = close_switcher(state)

    if state.destination == {:conversation, id} do
      {state, closed}
    else
      {state, sent} = service_request(state, {:conversation_open, id}, {:conversation, :open})
      {state, closed ++ sent}
    end
  end

  defp transition(state, :new_conversation) do
    {state, closed} = close_switcher(state)
    {state, sent} = service_request(state, {:conversation_new}, {:conversation, :new})
    {state, closed ++ sent}
  end

  defp transition(state, {:slash_local, command}), do: slash_local(state, command)

  defp transition(state, :editor_detach_notice),
    do:
      {%{state | notice: :detach_requires_confirmation},
       [{:announce, SafeText.chrome(:detach_key)}]}

  # The palette's one route out to a browser. The reducer stays pure and changes
  # nothing: the session runtime owns opening the page and the URL notice.
  defp transition(state, :open_companion), do: {state, [{:companion, :open}]}

  # The only pane left to dock is the inspector, so this is a real toggle rather
  # than a "set the dock to this pane": the value it toggles to when the
  # inspector is already docked is `:none`, the named absence of a dock.
  defp transition(state, {:toggle_dock, :inspector}) do
    dock = if state.preferences.medium_dock == :inspector, do: :none, else: :inspector
    {resize(%{state | preferences: %{state.preferences | medium_dock: dock}}, state.size), []}
  end

  defp transition(state, {:set_tab, tab}) do
    layers =
      case state.layers do
        [{:run_inspector, id, _} | rest] -> [{:run_inspector, id, tab} | rest]
        other -> other
      end

    {%{state | tabs: Map.put(state.tabs, :inspector, tab), layers: layers}, []}
  end

  # Which agent's operations the inspector's drawer shows; the projector falls
  # back to the newest running agent when the chosen one is not in the run.
  defp transition(state, {:select_agent, id}) when is_binary(id),
    do: {%{state | tabs: Map.put(state.tabs, :agent, id)}, []}

  # `[` and `]` rotate the same three tabs `{:set_tab, _}` sets, through the same
  # clause, so a docked inspector and a run_inspector overlay cannot drift apart.
  # `:overview` and `:thread` are older spellings of the agents tab, kept for
  # saved layers.
  defp transition(state, {:inspector_tab, direction}) do
    tabs = Bindings.inspector_tabs()

    current =
      case Map.get(state.tabs, :inspector, :agents) do
        old when old in [:overview, :thread] -> :agents
        tab -> tab
      end

    index = Enum.find_index(tabs, &(&1 == current)) || 0
    step = if direction == :next, do: 1, else: -1
    transition(state, {:set_tab, Enum.at(tabs, Integer.mod(index + step, length(tabs)))})
  end

  # The go-to popup is a which-key list: the second key closes it and acts.
  defp transition(%{layers: [{:jump, _} | _]} = state, {:run_tab, target}) do
    {state, effects} = transition(state, :close_top_layer)
    {state, moved} = transition(state, {:run_tab, target})
    {state, effects ++ moved}
  end

  # Alt-1..4 pick the tab at that position *as drawn*, which is the active-first
  # order the tab row paints.
  defp transition(state, {:run_tab, position}) when is_integer(position) do
    case Enum.at(SwarmCodeCLI.UI.Projector.Shell.tabline_runs(state), position - 1) do
      %{id: id} -> transition(state, {:navigate, {:run, id}})
      _ -> {state, []}
    end
  end

  # g-t cycles the *stable* order instead. The drawn order puts the active run
  # first, so stepping through it would ping-pong between two tabs forever.
  defp transition(state, {:run_tab, direction}) do
    runs = RunRow.visible(state.read_model.runs, "", RunRow.shell_order(state))
    current = current_run_id(state)
    index = Enum.find_index(runs, &(&1.id == current))
    step = if direction == :next, do: 1, else: -1

    target =
      case {runs, index} do
        {[], _} -> nil
        {_, nil} -> if direction == :next, do: List.first(runs), else: List.last(runs)
        {_, index} -> Enum.at(runs, Integer.mod(index + step, length(runs)))
      end

    if target, do: transition(state, {:navigate, {:run, target.id}}), else: {state, []}
  end

  defp transition(state, {:set_keymap, keymap}),
    do: {%{state | keymap: keymap, vim: %Vim{}}, []}

  # Entering INSERT is also entering the composer: `i` from the transcript
  # lands there typing, and a mode is meaningless anywhere else. The other
  # modes only ever start from inside the composer.
  defp transition(%{focus: focus} = state, {:vim, {:mode, :insert}}) when focus != "composer" do
    {state, effects} = transition(state, {:focus_region, "composer"})

    if state.focus == "composer",
      do: {%{state | vim: %Vim{mode: :insert}}, effects},
      else: {state, effects}
  end

  defp transition(state, {:vim, {:mode, mode}}) do
    state =
      if state.vim.mode == :visual and mode != :visual, do: collapse_selection(state), else: state

    {%{state | vim: %Vim{mode: mode}}, []}
  end

  # A cancelled prefix takes its count with it; a new prefix keeps the count
  # typed before it (`2d` then `w`).
  defp transition(state, {:vim, {:pending, nil}}), do: {clear_vim_prefix(state), []}

  defp transition(state, {:vim, {:pending, prefix}}),
    do: {%{state | vim: %{state.vim | pending: prefix}}, []}

  defp transition(state, {:vim, {:count, count}}),
    do: {%{state | vim: %{state.vim | count: count}}, []}

  # One key that edits and changes mode: the operations first, in order, on the
  # composer's draft, then the mode. Both clear the prefix.
  defp transition(state, {:vim, {:edit_then, operations, mode}}) do
    case State.current_draft_key(state) do
      nil ->
        {state, []}

      key ->
        {state, effects} =
          Enum.reduce(operations, {state, []}, fn operation, {state, effects} ->
            {next, more} = transition(state, {:editor, key, operation})
            {next, effects ++ more}
          end)

        {state, more} = transition(state, {:vim, {:mode, mode}})
        {state, effects ++ more}
    end
  end

  defp transition(state, {:open_detail, run_id, ref_id}), do: Details.open(state, run_id, ref_id)
  defp transition(state, {:detail_page, direction}), do: Details.page(state, direction)
  defp transition(state, {:resize, size}), do: {resize(state, size), []}

  defp transition(state, {:terminal_capabilities, generation, capabilities}) do
    if generation > state.terminal_generation do
      state = %{
        state
        | terminal_generation: generation,
          capabilities: capabilities,
          lifecycle: :running
      }

      {resize(state, capabilities.size), []}
    else
      {state, []}
    end
  end

  defp transition(state, {:terminal_focus, focus, generation}) do
    if generation == state.terminal_generation,
      do: {%{state | terminal_focus: focus}, []},
      else: {state, []}
  end

  defp transition(state, {:terminal_lifecycle, lifecycle, generation, _}) do
    if generation != state.terminal_generation do
      {state, []}
    else
      case lifecycle do
        :suspend_requested ->
          {%{state | lifecycle: :suspend_requested}, [{:terminal_control, :suspend}]}

        :suspended ->
          {%{state | lifecycle: :suspended}, []}

        :resumed ->
          {%{state | lifecycle: :running}, [{:terminal_control, :resume}]}

        :closing ->
          exit_requested(state, :detach, false)
      end
    end
  end

  defp transition(state, {:terminal_failed, generation, error}) do
    if generation == state.terminal_generation,
      do: exit_requested(%{state | notice: {:terminal_error, error}}, :plain, false),
      else: {state, []}
  end

  defp transition(state, {:draw_result, _, revision, result}) do
    if revision == state.revision and result != :ok,
      do: exit_requested(%{state | notice: result}, :plain, false),
      else: {state, []}
  end

  defp transition(state, {:input_rejected, reason}),
    do: {%{state | notice: {:input_rejected, reason}}, []}

  defp transition(state, {:navigate, destination}) do
    {state, closed} = close_switcher(state)
    {next, effects} = navigate(state, destination, true)
    {next, closed ++ effects}
  end

  defp transition(%{history: []} = state, :back), do: {state, []}

  defp transition(%{history: [context | rest]} = state, :back) do
    {next, effects} = navigate(%{state | history: rest}, context.destination, false)

    next =
      Enum.reduce(
        [
          :focus,
          :hidden_focus,
          :selection,
          :scrolls,
          :tabs,
          :filters,
          :layers,
          :layer_contexts,
          :expansions
        ],
        next,
        fn key, acc -> Map.put(acc, key, Map.fetch!(context, key)) end
      )

    {next, effects}
  end

  defp transition(state, {:focus_region, region}) do
    graph = focus_graph(state)

    if region in graph,
      do: dashboard_page(%{state | focus: region, hidden_focus: nil}, graph, region),
      else: {state, []}
  end

  defp transition(state, {:focus_cycle, direction}) do
    graph = focus_graph(state)

    # A focus the graph no longer holds — a session restored onto the deleted
    # navigator, say — is not a position to count from: Tab re-enters the ring at
    # its first region instead of stepping off an imaginary index 0.
    focus =
      case Enum.find_index(graph, &(&1 == state.focus)) do
        nil ->
          List.first(graph)

        index ->
          Enum.at(
            graph,
            Integer.mod(index + if(direction == :next, do: 1, else: -1), length(graph))
          )
      end

    dashboard_page(%{state | focus: focus}, graph, focus)
  end

  defp transition(%{layers: [{:jump, _} | _]} = state, {:move, direction}) do
    {state, effects} = transition(state, :close_top_layer)
    {state, moved} = Pages.move(state, direction)
    {state, effects ++ moved}
  end

  defp transition(state, {:move, direction}) do
    cond do
      SlashPalette.open?(state) -> {SlashPalette.move(state, direction), []}
      PathCompletion.open?(state) -> {PathCompletion.move(state, direction), []}
      true -> Pages.move(state, direction)
    end
  end

  defp transition(state, {:complete_command, name}), do: SlashPalette.complete(state, name)

  # pass73 finisher (V1's request K1): Enter on the approval card, with the
  # draft blank, shows every line of its command ("… N more lines · Enter
  # shows all"; PgUp/PgDn page it), and Enter again folds it back.
  defp transition(%{layers: [{:approval, id} | _]} = state, {:approval_show_all, id}) do
    selection =
      if Map.get(state.selection, "approval_all") == id,
        do: Map.delete(state.selection, "approval_all"),
        else: Map.put(state.selection, "approval_all", id)

    {%{state | selection: Map.delete(selection, "dialog_scroll")}, []}
  end

  defp transition(state, {:approval_show_all, _id}), do: {state, []}
  defp transition(state, {:complete_path, path}), do: PathCompletion.complete(state, path)

  # Ctrl-X. The terminal steps aside exactly as for Ctrl-Z (no frame is drawn
  # while it does); the session runtime runs the editor and answers.
  defp transition(%{lifecycle: :running} = state, {:external_editor, key}) do
    if key == State.current_draft_key(state) do
      text = Editor.text(Drafts.fetch(state.drafts, key).editor)
      {%{state | lifecycle: :suspend_requested}, [{:edit_externally, key, text}]}
    else
      {state, []}
    end
  end

  defp transition(state, {:external_editor, _}), do: {state, []}

  # The edited text replaces the draft as one undoable edit; the terminal's
  # own `:resumed` brings the lifecycle back when it was suspended.
  defp transition(state, {:external_edit_done, key, result}) do
    state =
      if state.lifecycle == :suspend_requested, do: %{state | lifecycle: :running}, else: state

    case result do
      {:ok, text} ->
        if text == Editor.text(Drafts.fetch(state.drafts, key).editor),
          do: {state, []},
          else: replace_draft(%{state | history_cursor: nil}, key, text)

      {:error, reason} ->
        {%{state | notice: {:command_feedback, external_edit_words(reason)}}, []}
    end
  end

  defp transition(state, :dismiss_completion), do: PathCompletion.dismiss(state)
  defp transition(state, {:scroll, region, operation}), do: Pages.scroll(state, region, operation)

  defp transition(state, {:retry_page, slot, direction}),
    do: Pages.request(state, slot, direction)

  defp transition(state, {:expand, id, expanded?}) do
    expansions =
      if expanded?,
        do: MapSet.put(state.expansions, id),
        else: MapSet.delete(state.expansions, id)

    {%{state | expansions: expansions}, []}
  end

  # A picker row sends a command the user did not type. The request resolver
  # only admits a dispatch whose text is the draft's, so the draft is given the
  # command first — as if it had been typed — and the accepted outcome clears
  # it the way a sent draft is cleared. Unsent work is never overwritten: the
  # pick is refused instead. The picker closes on either answer, and takes the
  # palette it was opened from with it.
  defp transition(%{layers: [{:model_picker, _, _} | _]} = state, {:invoke, intent, id}) do
    {next, effects} =
      case prime_model_pick(state, intent) do
        {:ok, primed} -> invoke_intent(primed, intent, id)
        {:error, notice} -> {%{state | notice: {:command_feedback, notice}}, []}
      end

    {next, closed} = close_switcher(next)

    {next, closed_palette} =
      if match?([{:switcher, _} | _], next.layers),
        do: close_switcher(next),
        else: {next, []}

    {next, closed ++ closed_palette ++ effects}
  end

  defp transition(state, {:invoke, intent, id}) do
    {next, effects} = invoke_intent(state, intent, id)

    if effects != [] do
      {next, closed} = close_switcher(next)
      {next, closed ++ effects}
    else
      {next, effects}
    end
  end

  defp transition(
         %{layers: [{:research_form, owner} | _], library: %{command_id: nil}} = state,
         {:field_editor, {:research_question, owner} = key, operation}
       ) do
    {next, effects} = Editing.apply(state, :field_editor, key, operation)

    next =
      if next.notice == {:editor_error, :text_too_large},
        do: %{
          next
          | library: %{
              next.library
              | message: "Question is limited to 4,000 bytes. Shorten the text and try again."
            }
        },
        else: next

    {next, effects}
  end

  defp transition(state, {:field_editor, {:research_question, _}, _}), do: {state, []}

  defp transition(
         %{layers: [{:feature_form, _, _} | _], feature_form: %{owner: owner, command_id: nil}} =
           state,
         {:field_editor, {:feature_field, owner, _} = key, operation}
       ) do
    if FeatureForm.editable?(state, elem(key, 2)) do
      {next, effects} = Editing.apply(state, :field_editor, key, operation)

      next =
        if next.notice == {:editor_error, :text_too_large},
          do: %{
            next
            | feature_form: %{
                next.feature_form
                | error: "Field values are limited to 16,384 bytes."
              }
          },
          else: next

      {next, effects}
    else
      {state, []}
    end
  end

  defp transition(state, {:field_editor, {:feature_field, _, _}, _}), do: {state, []}

  defp transition(state, {kind, key, operation}) when kind in [:editor, :field_editor] do
    {next, effects} = Editing.apply(state, kind, key, operation)
    next = if kind == :editor and next != state, do: %{next | slash_palette: nil}, else: next

    # Editing a recalled prompt makes it the draft: Up moves the caret again.
    next =
      if kind == :editor and next.drafts != state.drafts and
           not match?({:undo_boundary, _}, operation),
         do: %{next | history_cursor: nil},
         else: next

    # Typing while an approval has just opened keeps the approval waiting.
    {next, effects} =
      if kind == :editor and next.interaction_grace != nil and next.drafts != state.drafts,
        do: restart_grace(next, effects),
        else: {next, effects}

    # A completed edit is the end of any vim command, so the operator and count
    # that led to it are spent. An undo boundary is the editor's own timer, not
    # a key, and must not swallow a prefix the user is still typing.
    next =
      if kind == :editor and next.keymap == :vim and
           not match?({:undo_boundary, _}, operation),
         do: clear_vim_prefix(next),
         else: next

    # An `@` token at the caret asks the project for its paths.
    if kind == :editor and next != state do
      {next, completion} = PathCompletion.sync(next)
      {next, effects ++ completion}
    else
      {next, effects}
    end
  end

  defp transition(state, {:select_option, id, option_id}) do
    case Map.get(state.read_model.interactions, id) do
      %{state: :pending, question: %{options: options, multiple: multiple}} ->
        if Enum.any?(options, &(&1.id == option_id)) do
          key = {:question, id}
          selected = Map.get(state.selection, key, [])

          selected =
            cond do
              not multiple -> [option_id]
              option_id in selected -> List.delete(selected, option_id)
              true -> selected ++ [option_id]
            end

          {%{state | selection: Map.put(state.selection, key, selected)}, []}
        else
          {state, []}
        end

      _ ->
        {state, []}
    end
  end

  defp transition(state, {:draft_target, key, target}), do: Editing.target(state, key, target)
  defp transition(state, {:timer_fired, id}), do: Editing.timer(state, id)

  defp transition(state, {:layout_adjust, dock, adjustment}) do
    preferences =
      case adjustment do
        :reset -> Preferences.reset(state.preferences, dock)
        {:preset, preset} -> Preferences.preset(state.preferences, dock, preset)
        {:nudge, amount} -> Preferences.nudge(state.preferences, dock, amount)
      end

    {%{state | preferences: preferences}, []}
  end

  defp transition(state, {:composer_height, adjustment}) do
    height =
      case adjustment do
        :reset -> 3
        {:nudge, amount} -> max(1, min(8, state.composer_height + amount))
      end

    {%{
       state
       | composer_height: height,
         preferences: %{state.preferences | composer_height: height}
     }, []}
  end

  defp transition(%{layers: layers} = state, {:open_layer, _}) when length(layers) >= 32,
    do: {%{state | notice: :layer_capacity_reached}, []}

  # Jumping to something that waits on the user opens its card over what is
  # on screen. Only an interaction of another conversation navigates first,
  # to its run, because the conversation in view cannot answer for it. A card
  # already open for another interaction is closed first, or the walk would
  # stack cards the user then has to unwind.
  defp transition(state, {:open_interaction, id}) do
    case Map.get(state.read_model.interactions, id) do
      %{state: :pending, kind: kind, run_id: run_id} = item
      when kind in [:question, :approval] ->
        {state, closed} =
          case state.layers do
            [{top, _} | _] when top in [:question, :approval] ->
              transition(state, :close_top_layer)

            _ ->
              {state, []}
          end

        # pass72 G10: from a conversation, a request in another conversation
        # opens that conversation, not a run view (which has nothing to send,
        # QA Q1); from a run view it opens the request's run, as before.
        {state, moved} =
          cond do
            in_view?(state, item) ->
              {state, []}

            match?({:conversation, _}, state.destination) and is_binary(item.conversation_id) ->
              transition(state, {:navigate, {:conversation, item.conversation_id}})

            true ->
              transition(state, {:navigate, {:run, run_id}})
          end

        {state, opened} = transition(state, {:open_layer, {kind, id}})
        state = %{state | auto_opened: nil, interaction_grace: nil}
        {state, closed ++ moved ++ opened}

      _ ->
        transition(state, :nothing_waiting)
    end
  end

  defp transition(state, :send_unavailable) do
    {:ok, text} =
      SafeText.external(
        "This run view sends nothing; Alt-Left goes back to the chat.",
        SafeText.Limits.content()
      )

    {%{state | notice: {:command_feedback, SafeText.value(text)}}, [{:announce, text}]}
  end

  defp transition(state, :nothing_waiting) do
    {:ok, text} = SafeText.external("Nothing is waiting on you.", SafeText.Limits.content())
    {%{state | notice: {:command_feedback, SafeText.value(text)}}, [{:announce, text}]}
  end

  defp transition(state, {:open_layer, {:detail, run_id, ref_id}}),
    do: Details.open(state, run_id, ref_id)

  defp transition(state, {:open_layer, {:library, feature} = layer}) do
    state = push_layer_context(state)

    SwarmCodeCLI.UI.Library.open(
      %{state | layers: [layer | state.layers], focus: "cancel"},
      feature
    )
  end

  defp transition(
         %{layers: [{:library, :research} | _], library: %{command_id: nil, request_id: nil}} =
           state,
         {:open_layer, {:research_form, _owner} = layer}
       ) do
    state = push_layer_context(state)

    %{
      state
      | layers: [layer | state.layers],
        focus: "question",
        hidden_focus: state.focus,
        library: %{state.library | message: nil},
        selection: Map.put(state.selection, {:research_form, :depth}, :medium)
    }
    |> then(&{&1, []})
  end

  defp transition(state, {:open_layer, {:research_form, _}}), do: {state, []}

  defp transition(
         %{
           layers: [{:library, feature} | _],
           library: %{request_id: nil, command_id: nil, body: body}
         } = state,
         {:open_layer, {:feature_form, feature, id}}
       )
       when feature in [:workflows, :schedules, :settings, :mcp, :memory] and is_binary(id) do
    item = Enum.find(body.items, &(&1.id == id && not is_nil(&1.form)))

    form =
      cond do
        item -> item.form
        id == "new" and feature == :schedules -> SwarmCodeCLI.UI.Library.new_form(:schedules)
        id == "new" and feature == :mcp -> SwarmCodeCLI.UI.Library.new_form(:mcp)
        true -> nil
      end

    case form do
      %DTO.FeatureForm{} = form ->
        context = %{focus: state.focus, hidden_focus: state.hidden_focus}

        FeatureForm.open(
          %{state | layer_contexts: [context | state.layer_contexts]},
          feature,
          id,
          form
        )

      _ ->
        {state, []}
    end
  end

  defp transition(state, {:open_layer, {:feature_form, _, _}}), do: {state, []}

  defp transition(state, {:library_page, direction}),
    do: SwarmCodeCLI.UI.Library.page(state, direction)

  defp transition(
         %{library: %{feature: feature}} = state,
         {:library_command, feature, id, action}
       ),
       do: SwarmCodeCLI.UI.Library.command(state, id, action)

  defp transition(state, {:library_command, _, _, _}), do: {state, []}
  defp transition(state, {:library_select, id}), do: SwarmCodeCLI.UI.Library.select(state, id)

  defp transition(state, {:library_confirm, value}),
    do: SwarmCodeCLI.UI.Library.confirm(state, value)

  defp transition(state, :research_start), do: SwarmCodeCLI.UI.Library.start_research(state)
  defp transition(state, :feature_submit), do: FeatureForm.submit(state)

  defp transition(state, {:feature_cycle, field, direction}),
    do: FeatureForm.cycle(state, field, direction)

  defp transition(
         %{layers: [{:research_form, _} | _], library: %{command_id: nil}} = state,
         {:research_depth, depth}
       ),
       do: {%{state | selection: Map.put(state.selection, {:research_form, :depth}, depth)}, []}

  defp transition(state, {:research_depth, _}), do: {state, []}

  defp transition(state, {:open_layer, {:run_inspector, id, tab} = layer}) do
    state = push_layer_context(state)
    {state, effects} = Watch.open(state, :inspector, :run, id)

    {%{
       state
       | layers: [layer | state.layers],
         tabs: Map.put(state.tabs, :inspector, tab),
         hidden_focus: state.focus,
         focus: "inspector"
     }, effects}
  end

  defp transition(state, {:open_layer, {:switcher, _} = layer}) do
    {state, opened} = open_plain_layer(state, layer)
    {state, listed} = request_conversations(state)
    {state, opened ++ listed}
  end

  defp transition(state, {:open_layer, layer}), do: open_plain_layer(state, layer)

  # The runs filter is a plain query string in `selection`, not a field editor:
  # neither run view carries a cursor or a selection, so a keystroke is an
  # append, a delete of the last grapheme, or a reset. The Ctrl-G dashboard and
  # the Ctrl-R palette share the query and the action; only one of them is ever
  # the top layer, and both drop the query when they close.
  defp transition(%{layers: [layer | _]} = state, {:dashboard_filter, operation})
       when is_tuple(layer) and tuple_size(layer) == 2 and
              elem(layer, 0) in [:runs_dashboard, :run_palette] do
    query = State.runs_filter(state)

    next =
      case operation do
        {:append, fragment} -> String.slice(query <> fragment, 0, @max_filter_length)
        :backspace -> String.slice(query, 0, max(String.length(query) - 1, 0))
        :clear -> ""
      end

    {reanchor(State.put_runs_filter(state, next)), []}
  end

  # Typing only reaches the filter while a run view is the top layer.
  defp transition(state, {:dashboard_filter, _operation}), do: {state, []}

  defp transition(%{layers: []} = state, :close_top_layer), do: {state, []}

  defp transition(%{layers: [layer | rest]} = state, :close_top_layer) do
    state = if match?({:library, _}, layer), do: SwarmCodeCLI.UI.Library.close(state), else: state
    state = dismiss(state, layer)

    state =
      if match?({:command_report, _}, layer), do: %{state | command_report: nil}, else: state

    {context, contexts} =
      case state.layer_contexts do
        [head | tail] -> {head, tail}
        [] -> {%{focus: state.hidden_focus || "main", hidden_focus: nil}, []}
      end

    fields =
      case layer do
        {kind, owner}
        when kind in [
               :switcher,
               :jump,
               :action_menu,
               :region_filter,
               :question,
               :approval,
               :research_form
             ] ->
          FieldEditors.close_owner(state.field_editors, owner)

        {:model_picker, _, owner} ->
          FieldEditors.close_owner(state.field_editors, owner)

        _ ->
          state.field_editors
      end

    state = %{
      state
      | field_editors: fields,
        layers: rest,
        layer_contexts: contexts,
        focus: context.focus,
        hidden_focus: context.hidden_focus,
        exit_pending: nil
    }

    state =
      if match?({:research_form, _}, layer),
        do: %{state | selection: Map.delete(state.selection, {:research_form, :depth})},
        else: state

    # A closed run view keeps no query, so the next Ctrl-G or Ctrl-R opens on
    # every run.
    state =
      if match?({:runs_dashboard, _}, layer) or match?({:run_palette, _}, layer),
        do: State.put_runs_filter(state, ""),
        else: state

    if match?({:research_form, _}, layer) do
      Editing.close_fields(state, elem(layer, 1))
    else
      if match?({:feature_form, _, _}, layer) do
        FeatureForm.close(state)
      else
        if match?({:run_inspector, _, _}, layer) or match?({:detail, _, _}, layer) do
          state = %{state | detail: nil}

          case Enum.find(rest, &match?({:run_inspector, _, _}, &1)) do
            {:run_inspector, run_id, tab} ->
              Watch.open(
                %{state | tabs: Map.put(state.tabs, :inspector, tab)},
                :inspector,
                :run,
                run_id
              )

            nil ->
              Watch.close(state, :inspector)
          end
        else
          {state, []}
        end
      end
    end
  end

  defp transition(state, {:data, %{kind: :response} = delivery}) do
    case Map.get(state.requests, delivery.request_id) do
      %{scope: scope, generation: generation} = request
      when scope == delivery.scope and generation == delivery.generation ->
        case {request.expected_response, delivery.body} do
          {:library_snapshot, body} ->
            if PathCompletion.owns?(state, request),
              do: PathCompletion.response(state, request, body),
              else: SwarmCodeCLI.UI.Library.response(state, request, body)

          {:outcome, %Outcome{request_id: id} = outcome} when id == delivery.request_id ->
            cond do
              match?({:feature_form, _}, request.origin) ->
                FeatureForm.command_response(state, request, outcome)

              match?({:feature, _}, request.origin) ->
                SwarmCodeCLI.UI.Library.command_response(state, request, outcome)

              true ->
                settle_command(state, request, outcome)
            end

          {:outcome, _} ->
            {state, []}

          {:detail_window, body} ->
            Details.response(state, request, body)

          {:agent_detail, body} ->
            Overlay.detail_response(state, request, body)

          {:conversation_list, %DTO.ConversationList{} = body} ->
            state = %{state | requests: Map.delete(state.requests, delivery.request_id)}

            if body.state == :error,
              do: {state, []},
              else: {%{state | conversations: body}, []}

          {:watch_snapshot, _} ->
            {state, []}

          _ ->
            Pages.response(state, request, delivery.body)
        end

      _ ->
        {state, []}
    end
  end

  # While the agent overlay is up, news about its run asks for a fresh detail.
  defp transition(%{overlay: %{run_id: run}} = state, {:data, delivery}) do
    {state, effects} = Watch.deliver(state, delivery)

    case delivery do
      %{kind: :delta, body: %{run_id: ^run}} when state.overlay != nil ->
        {state, more} = Overlay.request_detail(state, false)
        {state, effects ++ more}

      _ ->
        {state, effects}
    end
  end

  defp transition(state, {:data, delivery}), do: Watch.deliver(state, delivery)
  defp transition(state, {:quit_requested, :detach}), do: exit_requested(state, :detach)

  defp transition(state, {:quit_requested, :daemon_shutdown}) do
    {:ok, text} =
      SafeText.external("Daemon shutdown is unavailable in this UI.", SafeText.Limits.content())

    {%{state | notice: :daemon_shutdown_unavailable}, [{:announce, text}]}
  end

  defp transition(state, {:presenter_handoff_requested, :plain}),
    do: exit_requested(state, :plain)

  defp transition(%{exit_pending: :detach} = state, {:quit_confirmed, :detach}),
    do: finish_exit(state, :detach)

  defp transition(%{exit_pending: :plain} = state, {:presenter_handoff_confirmed, :plain}),
    do: finish_exit(state, :plain)

  defp transition(state, {:quit_confirmed, :detach}), do: {state, []}
  defp transition(state, {:presenter_handoff_confirmed, :plain}), do: {state, []}

  defp settle_command(state, %{origin: {kind, _}} = request, outcome)
       when kind in [:conversation, :project] do
    {settled, effects} = Commands.settle(state, request, outcome)
    {settled, more} = settle_service(settled, request, outcome)
    {settled, effects ++ more}
  end

  defp settle_command(state, request, outcome) do
    {settled, effects} = Commands.settle(state, request, outcome)
    settled = remember_prompt(settled, request, outcome)
    settled = note_sent_turn(settled, request, outcome)
    settled = Deliveries.settled(settled, request, outcome)
    settled = steer_refusal(settled, request, outcome)

    case {outcome.status, outcome.feedback, request.origin, State.current_draft_key(state)} do
      {:accepted, %{kind: kind} = feedback, {:draft, {conversation, _}}, {conversation, _}}
      when feedback.conversation_id in [nil, conversation] ->
        {shown, extra} = show_feedback(settled, kind, feedback, request.request_id)
        {shown, effects ++ extra}

      _ ->
        {settled, effects}
    end
  end

  # An accepted open or new has switched the service's conversation: the view
  # follows it. A refusal says so; project updates show the service's words.
  defp settle_service(state, %{kind: {:conversation_open, id}}, %Outcome{status: :accepted}),
    do: navigate_conversation(state, id)

  defp settle_service(state, %{kind: {:conversation_new}}, %Outcome{
         status: :accepted,
         identifiers: [id | _]
       }),
       do: navigate_conversation(state, id)

  # pass73 T7: the policy change the workspace already showed keeps its words
  # ("Approvals: auto → full access") when the service's own answer comes
  # after it; a /trust says both.
  defp settle_service(state, %{kind: {:project_update, _mode, trust}}, %Outcome{
         status: :accepted,
         feedback: %{text: text}
       })
       when is_binary(text) do
    words =
      case {recent_policy_words(state), trust} do
        {nil, _} -> text
        {policy, true} -> "Project trusted · " <> policy
        {policy, _} -> policy
      end

    {%{state | notice: {:command_feedback, words}}, []}
  end

  defp settle_service(state, %{kind: kind}, %Outcome{status: status})
       when status != :accepted do
    words =
      case kind do
        {:conversation_open, _} -> "That conversation could not be opened."
        {:conversation_new} -> "A new conversation could not be started."
        {:project_update, _, _} -> "The project setting did not change."
        _ -> nil
      end

    if words, do: {%{state | notice: {:command_feedback, words}}, []}, else: {state, []}
  end

  defp settle_service(state, _request, _outcome), do: {state, []}

  defp navigate_conversation(state, id) do
    {state, effects} = transition(state, {:navigate, {:conversation, id}})
    # The list's "current" mark moved with it.
    {state, listed} = request_conversations(state)
    {%{state | focus: "composer", hidden_focus: nil}, effects ++ listed}
  end

  defp show_feedback(state, :navigate, %{feature: feature}, _)
       when feature in [:workflows, :research, :checkpoints],
       do: transition(state, {:open_layer, {:library, feature}})

  # `/diff` (pass70 F16): the service answers "navigate to changes"; the
  # inspector's changes tab is that view.
  # pass71 F3 (V's request I-1): below the docking width there is no
  # inspector to switch, so the run's changes open as a dialog (V draws
  # `{:run_inspector, run, :changes}` as one) on the current run.
  defp show_feedback(state, :navigate, %{feature: :changes}, _) do
    docked? =
      state.size &&
        Map.has_key?(
          SwarmCodeCLI.UI.Layout.for_state(state).rects,
          :inspector
        )

    case {docked?, SwarmCodeCLI.UI.Projector.Support.run(state)} do
      {false, %{id: run_id}} ->
        transition(state, {:open_layer, {:run_inspector, run_id, :changes}})

      _ ->
        transition(state, {:set_tab, :changes})
    end
  end

  defp show_feedback(state, :report, feedback, id) do
    transition(%{state | command_report: feedback}, {:open_layer, {:command_report, id}})
  end

  defp show_feedback(state, :notice, feedback, _),
    do: {%{state | notice: {:command_feedback, feedback.text}}, []}

  defp show_feedback(state, _, _, _), do: {state, []}

  def focus_graph(%{layers: [{kind, _} | _]}) when kind in [:unsent_changes, :confirm_intent],
    do: ["cancel", "confirm"]

  def focus_graph(%{layers: [{:question, id} | _]} = state) do
    case Map.get(state.read_model.interactions, id) do
      %{question: %{options: options}} ->
        Enum.map(options, & &1.id) ++ ["other", "submit", "cancel"]

      _ ->
        ["cancel"]
    end
  end

  def focus_graph(%{layers: [{:approval, id} | _]} = state) do
    case Map.get(state.read_model.interactions, id) do
      %{allowed_actions: actions} = item ->
        detail =
          if item.approval && item.approval.arguments_detail_ref,
            do: ["approval_details"],
            else: []

        detail ++
          Enum.map(
            Enum.filter([:approve, :deny, :always_allow], &(&1 in actions)),
            &Atom.to_string/1
          ) ++ ["cancel"]

      _ ->
        ["cancel"]
    end
  end

  # The go-to popup lists four fixed rows rather than a searchable catalogue, so
  # its ring is those rows. `Bindings.jump_rows/0` is the one copy of them.
  def focus_graph(%{layers: [{:jump, _} | _]}),
    do: Enum.map(Bindings.jump_rows(), &elem(&1, 0)) ++ ["cancel"]

  def focus_graph(%{layers: [{kind, _} | _]} = state)
      when kind in [:switcher, :action_menu, :region_filter],
      do: ["query"] ++ Enum.map(SwarmCodeCLI.UI.Switcher.visible(state), & &1.id) ++ ["cancel"]

  def focus_graph(%{layers: [{:model_picker, _, _} = layer | _]} = state),
    do: ModelPicker.focus_graph(state, layer)

  def focus_graph(%{layers: [{:detail, _, _} | _]}), do: ["detail", "previous", "next", "cancel"]

  def focus_graph(%{layers: [{:library, _} | _]} = state),
    do: SwarmCodeCLI.UI.Library.focus_graph(state)

  def focus_graph(%{layers: [{:research_form, _} | _]}),
    do: ["question", "low", "medium", "high", "ultra", "start", "cancel"]

  def focus_graph(%{layers: [{:feature_form, _, _} | _]} = state),
    do: FeatureForm.focus_graph(state)

  def focus_graph(%{layers: [{:run_inspector, _, _} | _]}), do: ["inspector", "cancel"]

  def focus_graph(%{layers: [{:run_palette, _} | _]} = state), do: RunPalette.focus_graph(state)

  def focus_graph(%{layers: [{:runs_dashboard, _} | _]} = state),
    do: RunsDashboard.focus_graph(state)

  def focus_graph(%{layers: [_ | _]}), do: ["dialog", "cancel"]

  # Only regions the layout actually draws are offered to Tab. The navigator is
  # not one of them any more, so a restored session focused on it finds itself
  # outside the ring; `focus_cycle` puts it back on the first real region rather
  # than counting from a member that no longer exists.
  def focus_graph(state) do
    rects = Layout.for_state(state).rects

    Enum.filter(["main", "inspector", "composer"], fn region ->
      Map.has_key?(rects, region_atom(region))
    end)
  end

  defp clear_vim_prefix(state), do: %{state | vim: %{state.vim | pending: nil, count: nil}}

  # Leaving VISUAL drops the selection without moving the caret. The editor has
  # no operation for "select nothing" (every move both moves and deselects), so
  # the anchor is cleared on the draft directly.
  defp collapse_selection(state) do
    case State.current_draft_key(state) do
      nil ->
        state

      key ->
        draft = Drafts.fetch(state.drafts, key)
        editor = %{draft.editor | anchor: nil}
        %{state | drafts: Drafts.put(state.drafts, %{draft | editor: editor})}
    end
  end

  # The run the shell considers current: the tab row and g-t have to agree on it.
  defp current_run_id(state) do
    case SwarmCodeCLI.UI.Projector.Support.run(state) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp region_atom("main"), do: :main
  defp region_atom("inspector"), do: :inspector
  defp region_atom("composer"), do: :composer

  defp resize(state, size) do
    state = %{state | size: size, capabilities: %{state.capabilities | size: size}}
    graph = focus_graph(state)

    cond do
      state.hidden_focus in graph -> %{state | focus: state.hidden_focus, hidden_focus: nil}
      state.focus not in graph -> %{state | hidden_focus: state.focus, focus: "main"}
      true -> state
    end
  end

  defp navigate(%{destination: destination} = state, destination, _), do: {state, []}

  defp navigate(state, destination, save?) do
    context =
      Map.take(state, [
        :destination,
        :focus,
        :hidden_focus,
        :selection,
        :scrolls,
        :tabs,
        :filters,
        :layers,
        :layer_contexts,
        :expansions
      ])

    # pass71 F10 (review R8): a conversation opened forward follows its tail;
    # the old one's anchor named items the new one does not have, so it opened
    # at the first prompt. `:back` restores the saved scrolls.
    state =
      if save?,
        do: %{
          state
          | history: [context | Enum.take(state.history, 31)],
            activity_return:
              if(state.destination == :activity, do: context, else: state.activity_return),
            scrolls: Map.put(state.scrolls, :main, SwarmCodeCLI.UI.Scroll.new())
        },
        else: state

    {state, effects} =
      if state.destination == :activity != (destination == :activity),
        do:
          Watch.close(state, if(state.destination == :activity, do: :activity, else: :workspace)),
        else: {state, []}

    state =
      if destination != state.destination and state.focus == "navigator",
        do: %{state | focus: "main", hidden_focus: nil},
        else: state

    {state, opened} = open_destination(%{state | destination: destination}, destination)
    {state, effects ++ opened}
  end

  defp open_destination(state, :activity), do: Watch.open(state, :activity, :global, nil)
  defp open_destination(state, {kind, id}), do: Watch.open(state, :workspace, kind, id)

  # A quit the user asked for confirms unsent work and live runs: the release
  # stops every run it owns on the way out. A terminal that failed or is
  # closing only confirms unsent work, as before.
  defp exit_requested(state, kind, count_live? \\ true) do
    live = if count_live?, do: live_run_count(state), else: 0

    if State.dirty?(state) or live > 0 do
      layer = {:unsent_changes, kind}
      state = if List.first(state.layers) == layer, do: state, else: push_layer_context(state)

      layers =
        if List.first(state.layers) == layer, do: state.layers, else: [layer | state.layers]

      {%{
         state
         | exit_pending: kind,
           quit_live_runs: live,
           layers: layers,
           hidden_focus: state.focus,
           focus: "cancel"
       }, []}
    else
      finish_exit(state, kind)
    end
  end

  @doc "The runs a quit would stop: every run in view that has not finished."
  @spec live_run_count(State.t()) :: non_neg_integer()
  def live_run_count(state),
    do: Enum.count(state.read_model.runs, fn {_, run} -> run.state in @live_states end)

  defp repair_switcher(old, %{layers: [{kind, _} = layer | _]} = next)
       when kind in [:switcher, :action_menu, :region_filter] do
    if next == old or next.focus in ["query", "cancel"] or List.first(old.layers) != layer do
      next
    else
      previous = SwarmCodeCLI.UI.Switcher.visible(old)
      index = Enum.find_index(previous, &(&1.id == old.focus)) || 0

      %{
        next
        | focus:
            SwarmCodeCLI.UI.Switcher.repair_selection(
              next.focus,
              index,
              SwarmCodeCLI.UI.Switcher.visible(next)
            )
      }
    end
  end

  defp repair_switcher(old, %{layers: [{:model_picker, _, _} = layer | _]} = next) do
    if next == old or next.focus in ["query", "cancel"] or List.first(old.layers) != layer do
      next
    else
      previous = ModelPicker.rows(old, layer)
      index = Enum.find_index(previous, &(&1.id == old.focus)) || 0

      %{
        next
        | focus: ModelPicker.repair_selection(next.focus, index, ModelPicker.rows(next, layer))
      }
    end
  end

  defp repair_switcher(_, next), do: next

  # The composer's draft is emptied only when it is the bare command that
  # opened the picker; a draft opened over from the palette is left alone.
  defp clear_opener_draft(state) do
    with key when not is_nil(key) <- State.current_draft_key(state),
         draft = Drafts.fetch(state.drafts, key),
         target when not is_nil(target) <- ModelPicker.opener(Editor.text(draft.editor)) do
      %{state | drafts: Drafts.put(state.drafts, Draft.clear(draft))}
    else
      _ -> state
    end
  end

  # pass73 T3/T8: every dispatch that leaves is recorded until the daemon
  # says where it went (`Reducer.Deliveries`).
  defp invoke_intent(state, intent, id) do
    if Layout.for_state(state).mutations_visible? do
      {next, effects} = Commands.invoke(state, intent, id)
      {next |> Deliveries.sent(effects) |> still_sending(state, intent, effects), effects}
    else
      {state, []}
    end
  end

  # pass73 S (request K1): a refused steer from the overlay says the
  # service's words (`Outcome.reason`); a refused send says them through
  # `Reducer.Deliveries`. pass73 finisher: so does every other refused
  # request (a stop, a retry, an approval answer), instead of the notice it
  # set while it was on its way ("Stopping the turn.").
  defp steer_refusal(state, %{kind: kind}, %{status: status} = outcome)
       when status != :accepted and elem(kind, 0) != :dispatch do
    case outcome.reason do
      %{text: text} when is_binary(text) ->
        if String.trim(text) == "",
          do: state,
          else: %{state | notice: {:command_feedback, String.trim(text)}}

      _ ->
        state
    end
  end

  defp steer_refusal(state, _request, _outcome), do: state

  # pass73 T3/T8: Enter again while the last send has not been answered is
  # never silent: the draft waits for that answer, and the status says so.
  defp still_sending(next, state, {:dispatch, _, _, _, _}, []) do
    case State.current_draft_key(state) do
      nil ->
        next

      key ->
        if sending?(state, key),
          do: %{next | notice: {:command_feedback, "Still sending the last message; one moment."}},
          else: next
    end
  end

  defp still_sending(next, _state, _intent, _effects), do: next

  # The draft takes the picked command when it is empty or already holds it;
  # anything else is unsent work the pick must not replace.
  defp prime_model_pick(state, {:dispatch, :send, text, :main, []}) do
    case State.current_draft_key(state) do
      nil ->
        {:error, "No conversation is open to switch the model of."}

      key ->
        draft = Drafts.fetch(state.drafts, key)
        current = Editor.text(draft.editor)

        cond do
          current == text ->
            {:ok, state}

          String.trim(current) == "" and draft.attachments == [] ->
            {:ok, editor} = Editor.apply(Editor.reset(draft.editor), {:insert, text})
            draft = %{Draft.clear(draft) | editor: editor}
            {:ok, %{state | drafts: Drafts.put(state.drafts, draft)}}

          true ->
            {:error, "Send or clear the draft first, then pick a model."}
        end
    end
  end

  defp prime_model_pick(_state, _intent), do: {:error, "That is not a model to pick."}

  # Narrowing can hide the selected palette row, so the selection falls back to
  # the first run still listed rather than pointing at a row you cannot see.
  defp reanchor(%{layers: [{:run_palette, _} | _]} = state) do
    graph = RunPalette.focus_graph(state)
    if state.focus in graph, do: state, else: %{state | focus: List.first(graph)}
  end

  defp reanchor(%{layers: [{:runs_dashboard, _} | _]} = state) do
    graph = RunsDashboard.focus_graph(state)
    if state.focus in graph, do: state, else: %{state | focus: List.first(graph)}
  end

  defp reanchor(state), do: state

  # Reaching the end of the dashboard's list asks the shell for the next page.
  # The navigator's scroll used to be the only caller that paged shell rows in;
  # the dashboard that replaced it is now that caller.
  defp dashboard_page(%{layers: [{:runs_dashboard, _} | _]} = state, graph, focus) do
    if focus == List.last(graph) and Map.has_key?(state.read_model.runs, focus) and
         is_map(Map.get(state.watches, :shell)),
       do: Pages.request(state, :shell, :after),
       else: {state, []}
  end

  defp dashboard_page(state, _graph, _focus), do: {state, []}

  defp close_switcher(%{layers: [{kind, _} | _]} = state)
       when kind in [
              :switcher,
              :jump,
              :action_menu,
              :region_filter,
              :run_palette,
              :runs_dashboard
            ],
       do: transition(state, :close_top_layer)

  defp close_switcher(%{layers: [{:confirm_intent, _} | _]} = state),
    do: transition(state, :close_top_layer)

  defp close_switcher(%{layers: [{:model_picker, _, _} | _]} = state),
    do: transition(state, :close_top_layer)

  defp close_switcher(state), do: {state, []}

  defp push_layer_context(state),
    do: %{
      state
      | layer_contexts: [
          %{focus: state.focus, hidden_focus: state.hidden_focus} | state.layer_contexts
        ]
    }

  defp open_plain_layer(state, layer) do
    {preview, advanced} = State.next_id(state, :layer)

    state =
      if match?({_, ^preview}, layer) or match?({_, _, ^preview}, layer),
        do: advanced,
        else: state

    # The bare `/model` in the composer is the picker's opener, not a message:
    # once the picker is up the composer has nothing left to send.
    state =
      if match?({:model_picker, _, _}, layer), do: clear_opener_draft(state), else: state

    state =
      if match?({:approval, _}, layer) or match?({:command_report, _}, layer),
        do: %{state | selection: Map.delete(state.selection, "dialog_scroll")},
        else: state

    next = %{
      push_layer_context(state)
      | layers: [layer | state.layers],
        hidden_focus: state.focus
    }

    focus =
      cond do
        match?({:unsent_changes, _}, layer) or match?({:approval, _}, layer) or
          match?({:question, _}, layer) or match?({:confirm_intent, _}, layer) ->
          "cancel"

        # The palette is a switcher: it opens on the run you are looking at, not
        # on the top of its own list.
        match?({:run_palette, _}, layer) ->
          RunPalette.initial_focus(next)

        true ->
          List.first(focus_graph(next))
      end

    {%{next | focus: focus}, []}
  end

  # ------------------------------------------------- interrupt and quit

  defp stop_turn(state, run_id) do
    {id, _} = State.next_id(state, :request)
    {next, effects} = invoke_intent(state, {:run_control, :stop, run_id}, id)

    if effects == [],
      do: {next, effects},
      else:
        {%{
           next
           | notice: {:command_feedback, "Stopping the turn."},
             stops_asked: Enum.take([run_id | List.delete(next.stops_asked, run_id)], 32)
         }, effects}
  end

  # The draft is on its way: its send is pending with the service.
  defp sending?(state, key), do: match?({:send, _}, send_in_flight(state, key))

  defp send_in_flight(state, key) do
    case Map.get(state.mutations, {:draft, key}) do
      {:pending, id, {:dispatch, :send, _, _, _}} -> {:send, id}
      _ -> nil
    end
  end

  # pass71 I3: Ctrl-C or Esc right after Enter. The send is still pending, or
  # it was accepted but its run is not on screen yet; either way the stop is
  # kept and sent once the run appears (`stop_on_arrival/2`), never dropped.
  defp stop_unseen_turn(state) do
    with {conversation, _} = key <- State.current_draft_key(state),
         target when not is_nil(target) <- unseen_turn(state, key, conversation),
         # A stop already waiting for this turn: this press has nothing to add.
         false <- state.stop_on_arrival == {conversation, target} do
      {:ok,
       %{
         state
         | stop_on_arrival: {conversation, target},
           notice: {:command_feedback, "Stopping the turn."}
       }}
    else
      _ -> :none
    end
  end

  defp unseen_turn(state, key, conversation) do
    case {send_in_flight(state, key), state.sent_turn} do
      {{:send, id}, _} -> {:request, id}
      {nil, {^conversation, run_id}} -> {:run, run_id}
      _ -> nil
    end
  end

  # After every transition: the run an accepted send started is remembered
  # until the read model shows it, and a stop asked for before it did is sent
  # once it does (or dropped once the run has ended, or the view has moved to
  # another conversation, or the send was refused).
  defp track_sent_turn(state, effects) do
    conversation =
      case State.current_draft_key(state) do
        {id, _} -> id
        nil -> nil
      end

    state =
      case state.sent_turn do
        {^conversation, run_id} ->
          if Map.has_key?(state.read_model.runs, run_id),
            do: %{state | sent_turn: nil},
            else: state

        nil ->
          state

        _other ->
          %{state | sent_turn: nil}
      end

    case state.stop_on_arrival do
      nil ->
        {state, effects}

      {^conversation, {:request, id}} ->
        if Map.has_key?(state.requests, id),
          do: {state, effects},
          else: {%{state | stop_on_arrival: nil}, effects}

      {^conversation, {:run, run_id}} ->
        case Map.get(state.read_model.runs, run_id) do
          nil ->
            {state, effects}

          %{state: run_state, allowed_actions: actions} ->
            cond do
              run_state not in @live_states ->
                {%{state | stop_on_arrival: nil}, effects}

              :stop in actions ->
                {state, more} = stop_turn(%{state | stop_on_arrival: nil}, run_id)
                {state, effects ++ more}

              true ->
                {state, effects}
            end
        end

      _other ->
        {%{state | stop_on_arrival: nil}, effects}
    end
  end

  # An accepted send names the run it started: remember it while it is not on
  # screen, and aim a stop that waited for this request at it. pass73 (S's
  # request K4): only a send that started a run; a steered one names the
  # running turn (already on screen), a queued one names none.
  defp note_sent_turn(
         state,
         %{kind: {:dispatch, :send, _, _, _}, origin: {:draft, {conv, _}}} = request,
         %Outcome{
           status: :accepted,
           identifiers: [run_id | _],
           disposition: disposition
         }
       )
       when disposition in [nil, :started] do
    state =
      if Map.has_key?(state.read_model.runs, run_id),
        do: state,
        else: %{state | sent_turn: {conv, run_id}}

    case state.stop_on_arrival do
      {^conv, {:request, id}} when id == request.request_id ->
        %{state | stop_on_arrival: {conv, {:run, run_id}}}

      _ ->
        state
    end
  end

  defp note_sent_turn(state, _request, _outcome), do: state

  # R2: the Enter kept while the workspace loaded is sent once its watch is
  # ready, exactly as Send would have sent it then. It is dropped, and says
  # so, when the draft changed meanwhile, the view moved elsewhere, or the
  # watch failed.
  defp replay_deferred(%{deferred_send: nil} = state, effects), do: {state, effects}

  defp replay_deferred(%{deferred_send: {key, text}} = state, effects) do
    status = Map.get(state.watches, :workspace, %{status: :closed}).status

    cond do
      State.current_draft_key(state) != key ->
        drop_deferred(state, effects, "Not sent: another conversation opened first.")

      status in [:frozen, :resyncing] ->
        {state, effects}

      status != :ready ->
        drop_deferred(state, effects, "Not sent: the conversation did not load.")

      Keymap.draft_text(state) != text ->
        drop_deferred(state, effects, "Not sent: the draft changed after Enter.")

      true ->
        state = %{state | deferred_send: nil}

        case Keymap.draft_send(state) do
          {:ok, action} ->
            {state, more} = transition(state, action)
            {state, effects ++ more}

          :ignore ->
            {state, effects}
        end
    end
  end

  defp drop_deferred(state, effects, words),
    do: {%{state | deferred_send: nil, notice: {:command_feedback, words}}, effects}

  # Only a press with nothing else to do arms the quit, and it says how to
  # quit (pass70 F12, pass71 R1).
  defp arm_quit(state) do
    {id, state} = State.next_id(state, :timer)

    {%{state | quit_armed: id, notice: {:command_feedback, quit_hint()}},
     [{:start_timer, id, @quit_window_ms, {:timer_fired, id}}]}
  end

  defp disarm_quit(state), do: %{state | quit_armed: nil}

  defp clear_draft(state, key) do
    {state, a} = Editing.apply(state, :editor, key, :select_all)
    {state, b} = Editing.apply(state, :editor, key, :delete_backward)
    {%{state | history_cursor: nil, slash_palette: nil}, a ++ b}
  end

  # pass70 Q2: feedback on the status line ("Project trusted", "Command
  # rejected", "Stopping the turn.") is a toast, not a banner. The moment it
  # appears is stamped here; `State.shown_notice/1` stops showing it a few
  # seconds later instead of leaving it over the key hints until the next one.
  defp stamp_notice(%{notice: notice}, %{notice: notice} = next), do: next
  defp stamp_notice(_previous, %{notice: nil} = next), do: %{next | notice_at: nil}
  defp stamp_notice(_previous, next), do: %{next | notice_at: next.now}

  defp quit_hint, do: "Press Ctrl-C again to quit."

  # pass73 G1 (QA Q1-09): "Not sent: …" stays on the status row only until
  # the user moves on: an edit of that draft, or any new request (a card
  # answered, another send), puts the stale refusal away, so the row shows
  # the hints that are true now. The pending and accepted ones are kept.
  defp hush_refusals(before, next) do
    stale =
      for {{:draft, key} = origin, {:settled, _id, status}} <- next.mutations,
          status != :accepted,
          new_mutation?(before, next) or draft_edited?(before, next, key),
          do: origin

    if stale == [],
      do: next,
      else: %{
        next
        | mutations: Map.drop(next.mutations, stale),
          mutation_reasons: Map.drop(next.mutation_reasons, stale)
      }
  end

  # A request the user started: a send, an answer, a stop (not a background
  # query such as the conversation list).
  defp new_mutation?(%{mutations: mutations}, %{mutations: mutations}), do: false

  defp new_mutation?(before, next) do
    Enum.any?(next.mutations, fn {origin, mutation} ->
      match?({:pending, _, _}, mutation) and Map.get(before.mutations, origin) != mutation
    end)
  end

  defp draft_edited?(%{drafts: drafts}, %{drafts: drafts}, _key), do: false

  defp draft_edited?(before, next, key),
    do:
      Editor.text(Drafts.fetch(before.drafts, key).editor) !=
        Editor.text(Drafts.fetch(next.drafts, key).editor)

  # --------------------------------------- approvals and questions in view

  # Whether an interaction belongs to what is on screen: its conversation, or
  # the run the view is scoped to.
  defp in_view?(state, item) do
    case state.destination do
      {:conversation, id} -> item.conversation_id == id
      {:run, id} -> item.run_id == id
      _ -> false
    end
  end

  # After every transition: a card whose interaction is no longer pending
  # closes by itself, and when nothing is open the first pending approval or
  # question of the conversation in view opens by itself, over the composer's
  # draft, which it leaves exactly as it was.
  defp sync_interactions(state, effects, action) do
    {state, effects} = close_settled(state, effects)

    if auto_open?(state, action) do
      case next_in_view(state) do
        nil ->
          {state, effects}

        item ->
          {opened, more} = transition(state, {:open_layer, {item.kind, item.id}})
          {opened, grace} = start_grace(%{opened | auto_opened: item.id})
          {opened, effects ++ more ++ grace}
      end
    else
      {state, effects}
    end
  end

  # A card closes by itself when its interaction stopped waiting, and a card
  # that opened by itself also closes when the view moved away from it.
  defp close_settled(%{layers: [{kind, id} | _]} = state, effects)
       when kind in [:approval, :question] do
    case Map.get(state.read_model.interactions, id) do
      %{state: :pending} = item ->
        if state.auto_opened != id or in_view?(state, item),
          do: {state, effects},
          else: close_card(state, effects, id)

      _ ->
        close_card(state, effects, id)
    end
  end

  defp close_settled(state, effects), do: {state, effects}

  # Closing a card for the user is not the user putting it aside: it is not
  # dismissed, and comes back when its conversation is in view again.
  defp close_card(state, effects, id) do
    {closed, more} = transition(state, :close_top_layer)

    closed = %{
      closed
      | dismissed_interactions: state.dismissed_interactions,
        auto_opened: if(closed.auto_opened == id, do: nil, else: closed.auto_opened),
        interaction_grace: nil
    }

    {closed, effects ++ more}
  end

  # Only data, a closed layer or a navigation can make something newly
  # waiting; a keystroke that opened nothing must not. Hint mode and the
  # agent overlay (pass 72) hold them back: the overlay's band shows its own
  # agent's request, and Ctrl-N reaches the rest.
  defp auto_open?(%{layers: [], lifecycle: :running, hint: nil, overlay: nil} = state, action) do
    (match?({:data, %{kind: kind}} when kind != :response, action) or
       action in [:close_top_layer, :boot] or match?({:navigate, _}, action)) and
      state.focus in ["composer", "main", "inspector"] and
      Layout.for_state(state).mutations_visible?
  end

  defp auto_open?(_state, _action), do: false

  defp next_in_view(state) do
    state.read_model.interactions
    |> Map.values()
    |> Enum.filter(
      &(&1.state == :pending and &1.kind in [:approval, :question] and in_view?(state, &1) and
          {&1.id, &1.expected_revision} not in state.dismissed_interactions)
    )
    |> Enum.min_by(&{&1.created_at, &1.id}, fn -> nil end)
  end

  # Esc on a card that is still pending puts it aside: it does not reopen by
  # itself until its revision moves. Ctrl-N brings it back on purpose.
  defp dismiss(state, {kind, id}) when kind in [:approval, :question] do
    case Map.get(state.read_model.interactions, id) do
      %{state: :pending, expected_revision: revision} ->
        dismissed =
          [{id, revision} | List.delete(state.dismissed_interactions, {id, revision})]
          |> Enum.take(@dismissed_limit)

        %{state | dismissed_interactions: dismissed, auto_opened: nil, interaction_grace: nil}

      _ ->
        %{state | auto_opened: nil, interaction_grace: nil}
    end
  end

  defp dismiss(state, _layer), do: state

  defp start_grace(state) do
    {id, state} = State.next_id(state, :timer)
    cancel = if state.interaction_grace, do: [{:cancel_timer, state.interaction_grace}], else: []

    {%{state | interaction_grace: id},
     cancel ++ [{:start_timer, id, @grace_ms, {:timer_fired, id}}]}
  end

  defp restart_grace(state, effects) do
    {state, more} = start_grace(state)
    {state, effects ++ more}
  end

  # ------------------------------------------------------ prompt history

  defp remember_prompt(state, %{origin: {:draft, {conversation, _}}, kind: kind}, %Outcome{
         status: :accepted
       })
       when elem(kind, 0) in [:dispatch, :steer] do
    text =
      case kind do
        {:dispatch, _, text, _, _} -> text
        {:steer, _, _, text, _} -> text
      end

    if byte_size(text) > @history_max_bytes or String.trim(text) == "" do
      state
    else
      sent = [text | List.delete(Map.get(state.prompt_history, conversation, []), text)]

      history =
        state.prompt_history
        |> Map.put(conversation, Enum.take(sent, @history_limit))
        |> bound_history(conversation)

      %{state | prompt_history: history, history_cursor: nil}
    end
  end

  defp remember_prompt(state, _request, _outcome), do: state

  # At most @history_conversations conversations keep a history; the one just
  # written stays, and the others go smallest first.
  defp bound_history(history, _keep) when map_size(history) <= @history_conversations,
    do: history

  defp bound_history(history, keep) do
    {drop, _} =
      history
      |> Map.delete(keep)
      |> Enum.min_by(fn {_, prompts} -> length(prompts) end)

    bound_history(Map.delete(history, drop), keep)
  end

  @doc """
  The prompts Up walks through in a conversation, newest first: what this
  session sent, then the user turns the transcript already holds.
  """
  @spec prompt_history(State.t(), binary()) :: [binary()]
  def prompt_history(state, conversation) do
    typed =
      state.read_model.transcript
      |> Map.values()
      |> Enum.filter(
        &(&1.role == :user and &1.conversation_id == conversation and is_nil(&1.detail_ref) and
            &1.state != :superseded and String.trim(&1.text) != "")
      )
      |> Enum.sort_by(&{&1.at, &1.created_sequence}, :desc)
      |> Enum.map(& &1.text)

    Enum.uniq(Map.get(state.prompt_history, conversation, []) ++ typed)
    |> Enum.take(@history_limit)
  end

  defp history(state, direction) do
    with {conversation, _} = key <- State.current_draft_key(state),
         prompts when prompts != [] <- prompt_history(state, conversation) do
      current = Keymap.draft_text(state)

      {index, saved} =
        case state.history_cursor do
          {^key, index, saved} -> {index, saved}
          _ -> {-1, current}
        end

      target = if direction == :previous, do: index + 1, else: index - 1

      cond do
        target >= length(prompts) ->
          {state, []}

        target < 0 ->
          {state, effects} = replace_draft(state, key, saved)
          {%{state | history_cursor: nil}, effects}

        true ->
          {state, effects} = replace_draft(state, key, Enum.at(prompts, target))
          {%{state | history_cursor: {key, target, saved}}, effects}
      end
    else
      _ -> {state, []}
    end
  end

  # One undoable replacement of the draft's text, like a slash completion.
  defp replace_draft(state, key, text) do
    {state, a} = Editing.apply(state, :editor, key, :select_all)

    {state, b} =
      if text == "",
        do: Editing.apply(state, :editor, key, :delete_backward),
        else: Editing.apply(state, :editor, key, {:paste, text})

    {%{state | slash_palette: nil}, a ++ b}
  end

  defp external_edit_words({:exit, status}),
    do: "The editor exited with status #{status}; the draft is unchanged."

  defp external_edit_words(:too_large),
    do: "The edited text is over 256 KiB; the draft is unchanged."

  defp external_edit_words(:not_utf8),
    do: "The edited text is not UTF-8; the draft is unchanged."

  defp external_edit_words(:terminal),
    do: "The terminal could not step aside for the editor."

  defp external_edit_words(:busy), do: "The editor is already open."

  defp external_edit_words(:unavailable),
    do: "No editor could be started; set $VISUAL or $EDITOR."

  # ------------------------------------------------- client slash commands

  defp slash_local(state, :help) do
    {state, cleared} = clear_command_draft(state)
    {state, opened} = transition(state, {:open_layer, :help})
    {state, cleared ++ opened}
  end

  defp slash_local(state, :quit) do
    {state, cleared} = clear_command_draft(state)
    {state, exited} = exit_requested(state, :detach)
    {state, cleared ++ exited}
  end

  # `/queue text` queues the text behind the running turn: the draft becomes
  # the text, then goes out exactly as Alt-Enter would send it.
  defp slash_local(state, :queue) do
    key = State.current_draft_key(state)
    text = Keymap.draft_text(state)
    rest = text |> String.replace_prefix("/queue", "") |> String.trim_leading()

    cond do
      key == nil ->
        {state, []}

      String.trim(rest) == "" ->
        {%{state | notice: {:command_feedback, "Type the message after /queue."}}, []}

      true ->
        {state, replaced} = replace_draft(state, key, rest)

        case Keymap.draft_dispatch(state, :queue) do
          {:ok, {:invoke, intent, id}} ->
            {state, sent} = invoke_intent(state, intent, id)
            {state, replaced ++ sent}

          _ ->
            {state, replaced}
        end
    end
  end

  defp slash_local(state, :new) do
    {state, cleared} = clear_command_draft(state)
    {state, sent} = transition(state, :new_conversation)
    {state, cleared ++ sent}
  end

  # /resume and /conversations open the palette on its conversation list:
  # the query starts at "#", which keeps conversations and runs.
  defp slash_local(state, command) when command in [:resume, :conversations] do
    {state, cleared} = clear_command_draft(state)
    layer = SwarmCodeCLI.UI.Switcher.open(state, state.focus)
    {state, opened} = transition(state, {:open_layer, layer})

    {state, typed} =
      case SwarmCodeCLI.UI.Switcher.field_key(layer) do
        nil -> {state, []}
        key -> Editing.apply(state, :field_editor, key, {:insert, "#"})
      end

    {state, cleared ++ opened ++ typed}
  end

  # /approval read-only | auto | full sets the project's approval mode, as
  # the desktop's selector does; without an argument it says what it is.
  defp slash_local(state, :approval) do
    argument =
      state
      |> Keymap.draft_text()
      |> String.trim()
      |> String.replace_prefix("/approval", "")
      |> String.trim()
      |> String.downcase()

    case approval_mode(argument) do
      # pass73 T7: without an argument, a small picker of the three modes
      # with the current one checked (the palette, narrowed to them).
      nil when argument == "" ->
        {state, cleared} = clear_command_draft(state)
        layer = SwarmCodeCLI.UI.Switcher.open(state, state.focus)
        {state, opened} = transition(state, {:open_layer, layer})

        {state, typed} =
          case SwarmCodeCLI.UI.Switcher.field_key(layer) do
            nil ->
              {state, []}

            key ->
              Editing.apply(
                state,
                :field_editor,
                key,
                {:insert, SwarmCodeCLI.UI.Switcher.approval_query()}
              )
          end

        # The cursor starts on the current mode: Enter keeps it, Up and
        # Down reach the other two.
        state =
          case Enum.find(SwarmCodeCLI.UI.Switcher.visible(state), &Map.get(&1, :current?)) do
            %{id: id} -> %{state | focus: id}
            nil -> state
          end

        {state, cleared ++ opened ++ typed}

      nil ->
        {%{
           state
           | notice: {:command_feedback, "Approval is read-only, auto or full: /approval auto."}
         }, []}

      mode ->
        {state, cleared} = clear_command_draft(state)
        {state, sent} = service_request(state, {:project_update, mode, nil}, {:project, :update})
        {state, cleared ++ sent}
    end
  end

  defp slash_local(state, :panel) do
    argument =
      state
      |> Keymap.draft_text()
      |> String.trim()
      |> String.replace_prefix("/panel", "")
      |> String.trim()
      |> String.downcase()

    mode =
      case argument do
        "full" -> :full
        "compact" -> :compact
        value when value in ["hidden", "off", "hide", "none"] -> :hidden
        _ -> nil
      end

    cond do
      mode != nil ->
        {state, cleared} = clear_command_draft(state)
        {state, set} = set_panel(state, mode)
        {state, cleared ++ set}

      argument == "" ->
        feedback(state, "Panel is #{state.panel_mode}: /panel full, compact or hidden.")

      true ->
        feedback(state, "Panel is full, compact or hidden: /panel compact.")
    end
  end

  # pass73-K: /diff, /theme and /mouse, with or without their argument.
  defp slash_local(state, command) when command in [:diff, :theme, :mouse] do
    case Display.parse(command, Keymap.draft_text(state)) do
      {:ok, field, value} ->
        {state, cleared} = clear_command_draft(state)
        {state, set} = transition(state, {field, value})
        {state, cleared ++ set}

      {:error, words} ->
        feedback(state, words)
    end
  end

  defp slash_local(state, :trust) do
    {state, cleared} = clear_command_draft(state)
    {state, sent} = service_request(state, {:project_update, nil, true}, {:project, :update})
    {state, cleared ++ sent}
  end

  defp approval_mode(value) when value in ["read-only", "readonly", "read_only", "ro"],
    do: :read_only

  defp approval_mode("auto"), do: :auto

  defp approval_mode(value) when value in ["full", "full-access", "full_access"],
    do: :full_access

  defp approval_mode(_value), do: nil

  # pass73 T7: however the project's approval mode changes (this session's
  # /approval or picker, /trust, the desktop, another client), the change is
  # said in the transcript ("Approvals: auto → full access", `policy_notices`)
  # and as a toast, once. The mode last seen is kept apart from the snapshot,
  # so a change that arrives with a resync (the snapshot replaced, not
  # patched) is noticed too; the first mode a session sees is no change.
  defp note_policy_change(_before, next) do
    case Map.get(next.read_model.snapshots, :workspace) do
      %{conversation_id: conversation, approval_mode: to} when not is_nil(to) ->
        case next.approval_seen do
          ^to ->
            next

          nil ->
            %{next | approval_seen: to}

          from ->
            notice = %{conversation_id: conversation, from: from, to: to, at: next.now}
            # pass73 (V2's request K-5): the toast adds what the new mode
            # means; the transcript notice (V1) is the short form.
            words = SwarmCodeCLI.UI.Projector.Status.policy_words(from, to, true)

            %{
              next
              | approval_seen: to,
                policy_notices: Enum.take([notice | next.policy_notices], 20),
                notice: {:command_feedback, words}
            }
        end

      _ ->
        next
    end
  end

  @policy_recent_ms 5_000

  defp recent_policy_words(%{policy_notices: [%{at: at, from: from, to: to} | _], now: now})
       when is_integer(at) and is_integer(now) and now - at <= @policy_recent_ms,
       do: SwarmCodeCLI.UI.Projector.Status.policy_words(from, to, true)

  defp recent_policy_words(_state), do: nil

  # ------------------------------------------ requests that are not intents

  # Conversation and project operations are service requests of their own
  # (pass70 C1), sent in the shell watch's scope, which the service accepts
  # for all of them.
  defp service_request(state, kind, origin) do
    watch = Map.get(state.watches, :shell)

    expected =
      if match?({:conversation_list, _, _, _}, kind), do: :conversation_list, else: :outcome

    with %{status: :ready, scope: scope, generation: generation} <- watch,
         {id, state} = State.next_id(state, :request),
         {:ok, request} <-
           Request.validate(%Request{
             request_id: id,
             kind: kind,
             scope: scope,
             generation: generation,
             origin: origin,
             deadline: state.now + state.deadline_ms,
             expected_response: expected
           }) do
      effect = if expected == :outcome, do: :command, else: :query
      {%{state | requests: Map.put(state.requests, id, request)}, [{effect, request}]}
    else
      _ ->
        {%{state | notice: {:command_feedback, "The session is not connected yet."}}, []}
    end
  end

  # One list request at a time; the palette shows the last answer meanwhile.
  defp request_conversations(state) do
    in_flight =
      Enum.any?(state.requests, fn {_, request} ->
        request.origin == {:conversation, :list}
      end)

    if in_flight or not match?(%{status: :ready}, Map.get(state.watches, :shell)),
      do: {state, []},
      else: service_request(state, {:conversation_list, nil, 50, 262_144}, {:conversation, :list})
  end

  defp clear_command_draft(state) do
    case State.current_draft_key(state) do
      nil -> {state, []}
      key -> replace_draft(state, key, "")
    end
  end

  defp finish_exit(state, :detach),
    do: {%{state | lifecycle: :closing, exit_pending: nil}, [{:detach, 0}]}

  defp finish_exit(state, :plain),
    do: {%{state | lifecycle: :closing, exit_pending: nil}, [{:presenter_handoff, :plain}]}

  # Hint mode lasts one keystroke: whatever the user does next that is not a
  # hint key ends it first. Facts arriving from the source, timers and the
  # terminal's own reports do not.
  @hint_neutral [
    :data,
    :timer_fired,
    :draw_result,
    :terminal_capabilities,
    :terminal_lifecycle,
    :terminal_failed,
    :terminal_focus,
    :resize,
    :hint,
    :panel_preferences_loaded,
    :preferences_loaded,
    :external_edit_done
  ]

  defp leave_modes(state, action) do
    state =
      if state.hint != nil and not hint_neutral?(action),
        do: %{state | hint: nil},
        else: state

    # Going somewhere else leaves the agent overlay the way Esc does.
    case action do
      {kind, _} when kind in [:navigate, :open_conversation] and state.overlay != nil ->
        Overlay.close(state)

      :new_conversation when state.overlay != nil ->
        Overlay.close(state)

      _ ->
        state
    end
  end

  # An editor's undo boundary arrives from its timer a second after typing
  # stopped; it is not the user doing something.
  defp hint_neutral?({kind, _key, {:undo_boundary, _}}) when kind in [:editor, :field_editor],
    do: true

  defp hint_neutral?(action),
    do: action == :boot or (is_tuple(action) and elem(action, 0) in @hint_neutral)

  # A request card may sit under hint mode (pass72 F: Ctrl-F over the card).
  defp drop_hint_under_layer(%{hint: %{}, layers: [{kind, _} | _]} = state)
       when kind in [:approval, :question],
       do: state

  defp drop_hint_under_layer(%{hint: %{}, layers: [_ | _]} = state), do: %{state | hint: nil}
  defp drop_hint_under_layer(state), do: state

  # ------------------------------------------------ pass72-O helpers

  defp next_panel(state) do
    narrow? = state.size != nil and state.size.columns < 120

    case {narrow?, state.panel_mode} do
      {true, :hidden} -> state.panel_shown
      {true, _} -> :hidden
      {false, :full} -> :compact
      {false, :compact} -> :hidden
      {false, :hidden} -> :full
    end
  end

  defp set_panel(state, mode) do
    narrow? = state.size != nil and state.size.columns < 120

    words =
      case {narrow?, mode} do
        {true, :hidden} -> "Panel off."
        {true, _} -> "Panel strip (#{mode} at 120 columns and wider)."
        {false, mode} -> "Panel #{mode}."
      end

    state = %{state | panel_mode: mode, panel_shown: shown_panel(mode, state.panel_shown)}
    {state, effects} = feedback(state, words)
    {state, effects ++ [{:save_preferences, %{panel_mode: mode}}]}
  end

  defp shown_panel(:hidden, shown), do: shown
  defp shown_panel(mode, _shown), do: mode

  defp feedback(state, text) do
    {:ok, safe} = SafeText.external(text, SafeText.Limits.content())
    {%{state | notice: {:command_feedback, SafeText.value(safe)}}, []}
  end

  defp reveal_run(state, run) do
    ids = SwarmCodeCLI.UI.ScrollMetrics.order(state, :main, :workspace)
    transcript = state.read_model.transcript

    case Enum.find(ids, &match?(%{run_id: ^run}, Map.get(transcript, &1))) do
      nil ->
        case Map.get(state.read_model.runs, run) do
          %{conversation_id: conversation} when is_binary(conversation) ->
            if state.destination == {:conversation, conversation},
              do: feedback(state, "That run has nothing in the chat yet."),
              else: transition(state, {:navigate, {:conversation, conversation}})

          _ ->
            feedback(state, "That run is not in this chat.")
        end

      id ->
        scroll = %{
          Map.get(state.scrolls, :main, %SwarmCodeCLI.UI.Scroll{})
          | anchor: {id, 0, :top},
            follow?: false
        }

        {%{state | scrolls: Map.put(state.scrolls, :main, scroll)}, []}
    end
  end
end
