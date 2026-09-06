defmodule SwarmCodeCLI.UI.Reducer do
  @moduledoc "Pure semantic transitions. Every clock, identifier seed and external fact comes from the owner."
  alias SwarmCodeCLI.UI.{Action, Init, State, WatchState, Drafts, FieldEditors, Layout, SafeText}
  alias SwarmCodeCLI.UI.Layout.Preferences
  alias SwarmCodeCLI.UI.Reducer.{Watch, Commands, Pages, Editing, Details}
  alias SwarmCodeCLI.UI.DataSource.DTO.Outcome

  @spec init(Init.t()) :: {State.t(), [SwarmCodeCLI.UI.Effect.t()]}
  def init(%Init{} = init) do
    SwarmCodeCLI.UI.Size.validate!(init.size)
    Action.validate!({:terminal_capabilities, init.terminal_generation, init.capabilities})
    {:ok, _} = SwarmCodeCLI.UI.Destination.validate(init.destination)

    unless SwarmCodeCLI.UI.Intent.valid_id?(init.source_epoch) and
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

  defp transition(state, {:toggle_dock, dock}) do
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
    if region in focus_graph(state),
      do: {%{state | focus: region, hidden_focus: nil}, []},
      else: {state, []}
  end

  defp transition(state, {:focus_cycle, direction}) do
    graph = focus_graph(state)
    index = Enum.find_index(graph, &(&1 == state.focus)) || 0
    index = Integer.mod(index + if(direction == :next, do: 1, else: -1), length(graph))
    {%{state | focus: Enum.at(graph, index)}, []}
  end

  defp transition(%{layers: [{:jump, _} | _]} = state, {:move, direction}) do
    {state, effects} = transition(state, :close_top_layer)
    {state, moved} = Pages.move(state, direction)
    {state, effects ++ moved}
  end

  defp transition(state, {:move, direction}), do: Pages.move(state, direction)
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

  defp transition(state, {kind, key, operation}) when kind in [:editor, :field_editor],
    do: Editing.apply(state, kind, key, operation)

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

    next = %{
      push_layer_context(state)
      | layers: [layer | state.layers],
        hidden_focus: state.focus
    }

    focus =
      if match?({:unsent_changes, _}, layer) or match?({:approval, _}, layer) or
           match?({:question, _}, layer) or match?({:confirm_intent, _}, layer),
         do: "cancel",
         else: List.first(focus_graph(next))

    {%{next | focus: focus}, []}
  end

  defp transition(%{layers: []} = state, :close_top_layer), do: {state, []}

  defp transition(%{layers: [layer | rest]} = state, :close_top_layer) do
    {context, contexts} =
      case state.layer_contexts do
        [head | tail] -> {head, tail}
        [] -> {%{focus: state.hidden_focus || "main", hidden_focus: nil}, []}
      end

    fields =
      case layer do
        {kind, owner}
        when kind in [:switcher, :jump, :action_menu, :region_filter, :question, :approval] ->
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

  defp transition(state, {:data, %{kind: :response} = delivery}) do
    case Map.get(state.requests, delivery.request_id) do
      %{scope: scope, generation: generation} = request
      when scope == delivery.scope and generation == delivery.generation ->
        case {request.expected_response, delivery.body} do
          {:outcome, %Outcome{request_id: id} = outcome} when id == delivery.request_id ->
            Commands.settle(state, request, outcome)

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

  def focus_graph(%{layers: [{kind, _} | _]}) when kind in [:unsent_changes, :confirm_intent],
    do: ["cancel", "confirm"]

  def focus_graph(%{layers: [{:question, id} | _]} = state) do
    case Map.get(state.read_model.interactions, id) do
      %{question: %{options: options, multiple: multiple}} ->
        Enum.map(options, & &1.id) ++ if(multiple, do: ["submit", "cancel"], else: ["cancel"])

      _ ->
        ["cancel"]
    end
  end

  def focus_graph(%{layers: [{:approval, id} | _]} = state) do
    case Map.get(state.read_model.interactions, id) do
      %{allowed_actions: actions} ->
        Enum.map(
          Enum.filter([:approve, :deny, :always_allow], &(&1 in actions)),
          &Atom.to_string/1
        ) ++ ["cancel"]

      _ ->
        ["cancel"]
    end
  end

  def focus_graph(%{layers: [{kind, _} | _]} = state)
      when kind in [:switcher, :jump, :action_menu, :region_filter],
      do: ["query"] ++ Enum.map(SwarmCodeCLI.UI.Switcher.visible(state), & &1.id) ++ ["cancel"]

  def focus_graph(%{layers: [{:detail, _, _} | _]}), do: ["detail", "previous", "next", "cancel"]
  def focus_graph(%{layers: [{:run_inspector, _, _} | _]}), do: ["inspector", "cancel"]
  def focus_graph(%{layers: [_ | _]}), do: ["dialog", "cancel"]

  def focus_graph(state) do
    rects = Layout.calculate(state.size, state.preferences).rects

    Enum.filter(["navigator", "main", "inspector", "composer"], fn region ->
      Map.has_key?(rects, region_atom(region))
    end)
  end

  defp region_atom("navigator"), do: :navigator
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
       when kind in [:switcher, :jump, :action_menu, :region_filter] do
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

  defp close_switcher(%{layers: [{kind, _} | _]} = state)
       when kind in [:switcher, :jump, :action_menu, :region_filter],
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
