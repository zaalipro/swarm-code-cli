defmodule SwarmCodeCLI.UI.Reducer do
  @moduledoc "Pure semantic transitions. Every clock, identifier seed and external fact comes from the owner."
  alias SwarmCodeCLI.UI.{
    Action,
    Init,
    State,
    WatchState,
    Drafts,
    FieldEditors,
    Layout,
    SafeText,
    FeatureForm
  }

  alias SwarmCodeCLI.UI.Layout.Preferences
  alias SwarmCodeCLI.UI.Keymap.Bindings
  alias SwarmCodeCLI.UI.Projector.RunRow
  alias SwarmCodeCLI.UI.Vim
  alias SwarmCodeCLI.UI.SlashPalette
  alias SwarmCodeCLI.UI.Reducer.{Watch, Commands, Pages, Editing, Details}
  alias SwarmCodeCLI.UI.DataSource.DTO.Outcome
  alias SwarmCodeCLI.UI.Projector.{RunPalette, RunsDashboard}
  alias SwarmCodeCLI.UI.DataSource.DTO

  # The query is drawn on the dashboard header line beside the counts, so it is
  # bounded rather than allowed to grow with every keystroke.
  @max_filter_length 64

  @spec init(Init.t()) :: {State.t(), [SwarmCodeCLI.UI.Effect.t()]}
  def init(%Init{} = init) do
    SwarmCodeCLI.UI.Size.validate!(init.size)
    Action.validate!({:terminal_capabilities, init.terminal_generation, init.capabilities})
    {:ok, _} = SwarmCodeCLI.UI.Destination.validate(init.destination)

    unless SwarmCodeCLI.UI.Intent.valid_id?(init.source_epoch) and
             init.banner in [nil, :live_banner, :persisted_banner] and
             init.focus in ["main", "composer"] and init.keymap in [:default, :vim] and
             SwarmCodeCLI.UI.Intent.valid_id?(init.id_prefix) and is_integer(init.now) and
             init.now >= 0 and is_integer(init.deadline_ms) and init.deadline_ms >= 0 and
             is_integer(init.id_sequence) and init.id_sequence >= 0,
           do: raise(ArgumentError, "invalid reducer init")

    state = struct!(State, Map.from_struct(init))

    state = %{
      state
      | watches: Map.new([:shell, :workspace, :activity, :inspector], &{&1, %WatchState{}}),
        drafts: Drafts.new(ambiguous_width: init.capabilities.ambiguous_width),
        field_editors: FieldEditors.new(ambiguous_width: init.capabilities.ambiguous_width)
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
        {next, effects} = transition(state, action)
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
        [{:run_inspector, id, _} | rest] ->
          [{:run_inspector, id, if(tab == :thread, do: :overview, else: tab)} | rest]

        other ->
          other
      end

    {%{state | tabs: Map.put(state.tabs, :inspector, tab), layers: layers}, []}
  end

  # `[` and `]` rotate the same four tabs `{:set_tab, _}` sets, through the same
  # clause, so a docked inspector and a run_inspector overlay cannot drift apart.
  # `:overview` is the run_inspector layer's spelling of `:thread`.
  defp transition(state, {:inspector_tab, direction}) do
    tabs = Bindings.inspector_tabs()

    current =
      case Map.get(state.tabs, :inspector, :thread) do
        :overview -> :thread
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
          exit_requested(state, :detach)
      end
    end
  end

  defp transition(state, {:terminal_failed, generation, error}) do
    if generation == state.terminal_generation,
      do: exit_requested(%{state | notice: {:terminal_error, error}}, :plain),
      else: {state, []}
  end

  defp transition(state, {:draw_result, _, revision, result}) do
    if revision == state.revision and result != :ok,
      do: exit_requested(%{state | notice: result}, :plain),
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
    if SlashPalette.open?(state),
      do: {SlashPalette.move(state, direction), []},
      else: Pages.move(state, direction)
  end

  defp transition(state, {:complete_command, name}), do: SlashPalette.complete(state, name)
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

  defp transition(state, {:invoke, intent, id}) do
    if Layout.calculate(state.size, state.preferences).mutations_visible? do
      {next, effects} = Commands.invoke(state, intent, id)

      if effects != [] do
        {next, closed} = close_switcher(next)
        {next, closed ++ effects}
      else
        {next, effects}
      end
    else
      {state, []}
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

    # A completed edit is the end of any vim command, so the operator and count
    # that led to it are spent. An undo boundary is the editor's own timer, not
    # a key, and must not swallow a prefix the user is still typing.
    next =
      if kind == :editor and next.keymap == :vim and
           not match?({:undo_boundary, _}, operation),
         do: clear_vim_prefix(next),
         else: next

    {next, effects}
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

  defp transition(state, {:open_layer, layer}) do
    {preview, advanced} = State.next_id(state, :layer)
    state = if match?({_, ^preview}, layer), do: advanced, else: state

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
            SwarmCodeCLI.UI.Library.response(state, request, body)

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

          {:watch_snapshot, _} ->
            {state, []}

          _ ->
            Pages.response(state, request, delivery.body)
        end

      _ ->
        {state, []}
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

  defp settle_command(state, request, outcome) do
    {settled, effects} = Commands.settle(state, request, outcome)

    case {outcome.status, outcome.feedback, request.origin, State.current_draft_key(state)} do
      {:accepted, %{kind: kind} = feedback, {:draft, {conversation, _}}, {conversation, _}}
      when feedback.conversation_id in [nil, conversation] ->
        {shown, extra} = show_feedback(settled, kind, feedback, request.request_id)
        {shown, effects ++ extra}

      _ ->
        {settled, effects}
    end
  end

  defp show_feedback(state, :navigate, %{feature: feature}, _)
       when feature in [:workflows, :research, :checkpoints],
       do: transition(state, {:open_layer, {:library, feature}})

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
    rects = Layout.calculate(state.size, state.preferences).rects

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

    state =
      if save?,
        do: %{
          state
          | history: [context | Enum.take(state.history, 31)],
            activity_return:
              if(state.destination == :activity, do: context, else: state.activity_return)
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

  defp exit_requested(state, kind) do
    if State.dirty?(state) do
      layer = {:unsent_changes, kind}
      state = if List.first(state.layers) == layer, do: state, else: push_layer_context(state)

      layers =
        if List.first(state.layers) == layer, do: state.layers, else: [layer | state.layers]

      {%{state | exit_pending: kind, layers: layers, hidden_focus: state.focus, focus: "cancel"},
       []}
    else
      finish_exit(state, kind)
    end
  end

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

  defp repair_switcher(_, next), do: next

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

  defp close_switcher(state), do: {state, []}

  defp push_layer_context(state),
    do: %{
      state
      | layer_contexts: [
          %{focus: state.focus, hidden_focus: state.hidden_focus} | state.layer_contexts
        ]
    }

  defp finish_exit(state, :detach),
    do: {%{state | lifecycle: :closing, exit_pending: nil}, [{:detach, 0}]}

  defp finish_exit(state, :plain),
    do: {%{state | lifecycle: :closing, exit_pending: nil}, [{:presenter_handoff, :plain}]}
end
