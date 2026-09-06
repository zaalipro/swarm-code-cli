defmodule SwarmCodeCLI.UI.Projector.Dialog do
  @moduledoc "Sticky dialog chrome around a separately windowed, cell-wrapped body."
  alias SwarmCodeCLI.UI.{Editor, FieldEditors, SafeText, Switcher, Theme, Width}
  alias SwarmCodeCLI.UI.Scene.{Block, Dialog, Rect, Span}
  alias SwarmCodeCLI.UI.Paint.{Metrics, Options}
  alias SwarmCodeCLI.UI.Projector.{Density, Support}
  def project(state, class, background \\ %{})
  def project(%{layers: []}, _class, _background), do: nil

  def project(state, class, background) do
    layer = hd(state.layers)
    rect = rectangle(state.size, class)

    {title, options, footer, focus} =
      case layer do
        {kind, _} when kind in [:switcher, :action_menu, :jump, :region_filter] ->
          switcher(state, rect, class, background)

        _ ->
          contents(layer, state, rect, class)
      end

    footer_focus? = Enum.any?(footer, &match?({:dialog_control, ^focus, _, _}, &1))
    style = Theme.style(:focus, state.capabilities)

    prefix_width =
      Width.cells(SafeText.value(style.prefix), state.capabilities.ambiguous_width) + 1

    footer =
      Enum.map(footer, fn
        {:dialog_control, id, label, target} when id == focus ->
          Support.action(label, target, style)

        {:dialog_control, _, label, target} ->
          Support.action(label, target)

        block ->
          block
      end)

    ordinal = Enum.find_index(options, fn {id, _, _} -> id == focus end) || 0

    overflow =
      Support.text(
        "item #{min(ordinal + 1, length(options))} of #{length(options)}",
        state,
        rect.width - 2
      )

    footer = [overflow | footer]
    {measured_footer, _} = Support.finalize(footer, state.revision)

    paint_options = %Options{
      color_mode: state.capabilities.color_mode,
      ascii?: state.capabilities.ascii?
    }

    {:ok, footer_height} =
      Metrics.height(
        measured_footer,
        min(rect.width - 2, 500),
        paint_options,
        min(rect.height, 200),
        state.capabilities.ambiguous_width
      )

    rows =
      Enum.flat_map(options, fn {id, label, action} ->
        text = label |> SafeText.value()
        focused? = id == focus and not footer_focus?
        width = max(1, rect.width - 2 - if(focused?, do: prefix_width, else: 0))
        lines = Width.wrap(text, width, state.capabilities.ambiguous_width)

        Enum.map(lines, fn line ->
          {id, Density.safe(line, state, rect.width - 2), action}
        end)
      end)

    height = max(0, rect.height - 2 - footer_height)

    indices =
      rows
      |> Enum.with_index()
      |> Enum.filter(fn {{id, _, _}, _} -> id == focus end)
      |> Enum.map(&elem(&1, 1))

    first_focus = List.first(indices) || 0
    last_focus = List.last(indices) || first_focus

    anchor =
      case layer do
        {:detail, _, _} ->
          case Map.get(state.scrolls, :inspector) do
            %{anchor: {_, line, _}} -> line
            _ -> 0
          end

        _ ->
          Map.get(state.selection, "dialog_scroll", 0)
      end

    anchor = if is_integer(anchor), do: anchor, else: 0

    first =
      cond do
        indices == [] -> anchor
        first_focus < anchor -> first_focus
        last_focus >= anchor + height -> max(first_focus, last_focus - height + 1)
        true -> anchor
      end
      |> min(max(0, length(rows) - height))
      |> max(0)

    # An option may start above the viewport. Attach its target to the first
    # visible continuation, once per option, rather than its clipped first row.
    {visible, _} =
      rows
      |> Enum.drop(first)
      |> Enum.take(height)
      |> Enum.map_reduce(MapSet.new(), fn {id, text, action}, seen ->
        first? = not MapSet.member?(seen, id)
        focused? = id == focus and first? and not footer_focus?

        block =
          cond do
            action && first? && focused? -> Support.action(text, action, style)
            action && first? -> Support.action(text, action)
            focused? -> %Block.RichText{spans: [%Span{text: text, style: style}]}
            true -> %Block.Text{text: text}
          end

        {block, MapSet.put(seen, id)}
      end)

    %Dialog{
      id: "dialog",
      rect: rect,
      title: Density.safe(title, state, rect.width - 2),
      blocks: visible,
      footer: footer,
      focused_control_id: focus,
      body_scroll: first,
      body_visible_range: {first, min(first + height, length(rows))},
      body_total_count: length(rows)
    }
  end

  defp control(id, label, target), do: {:dialog_control, id, label, target}

  defp contents({:unsent_changes, kind}, state, _rect, class) do
    cancel = control("cancel", SafeText.chrome(:cancel_exit), {:local, :close_top_layer})

    confirm_target =
      if kind == :plain,
        do: {:presenter_handoff_confirmed, :plain},
        else: {:quit_confirmed, :detach}

    confirm =
      if class == :compressed_small,
        do: [],
        else: [control("confirm", SafeText.chrome(:confirm_exit), {:local, confirm_target})]

    {SafeText.chrome(:unsent_changes), [{"cancel", SafeText.chrome(:cancel_exit), nil}],
     [cancel] ++ confirm,
     if(state.focus == "confirm" and class != :compressed_small, do: "confirm", else: "cancel")}
  end

  defp contents({:confirm_intent, intent}, state, rect, class) do
    {subject, permission} =
      case intent do
        {:run_control, :stop, id} -> {Map.get(state.read_model.runs, id), :stop}
        {:stop_agent, _run, id, _revision} -> {Map.get(state.read_model.agents, id), :stop_agent}
      end

    revision_valid =
      case intent do
        {:stop_agent, run, id, rev} ->
          subject && subject.run_id == run && subject.id == id && subject.revision == rev

        _ ->
          true
      end

    permitted =
      subject && revision_valid && Support.allowed?(state, subject, permission) &&
        class != :compressed_small

    cancel = control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})

    confirm =
      if permitted,
        do: [control("confirm", SafeText.chrome(:confirm), {:intent, intent})],
        else: []

    title = SafeText.chrome(:stop)

    text =
      if permitted, do: SafeText.chrome(:confirm_stop), else: SafeText.chrome(:read_only_resize)

    focused = if state.focus == "confirm" && permitted, do: "confirm", else: "cancel"

    {title, [{"confirmation", Density.safe(text, state, rect.width - 2), nil}],
     [cancel] ++ confirm, focused}
  end

  defp contents({:detail, _run, _ref}, state, rect, _class) do
    detail = state.detail
    window = detail && detail.window

    limits = %{
      SwarmCodeCLI.UI.SafeText.Limits.content()
      | ambiguous_width: state.capabilities.ambiguous_width
    }

    lines =
      if window do
        window.text
        |> Density.external(limits)
        |> SafeText.value()
        |> Width.wrap(max(1, rect.width - 2), state.capabilities.ambiguous_width)
      else
        []
      end

    options =
      lines
      |> Enum.with_index()
      |> Enum.map(fn {line, index} -> {"line-#{index}", Density.external(line, limits), nil} end)

    options =
      if options == [], do: [{"loading", SafeText.chrome(:status_loading), nil}], else: options

    next =
      cond do
        detail && detail.status == :error ->
          [control("next", SafeText.chrome(:retry), {:local, {:detail_page, :next}})]

        detail && detail.status == :idle && window && window.next_offset ->
          [control("next", SafeText.chrome(:next_page), {:local, {:detail_page, :next}})]

        true ->
          []
      end

    previous =
      if detail && detail.status == :idle && detail.history != [],
        do: [
          control(
            "previous",
            SafeText.chrome(:previous_page),
            {:local, {:detail_page, :previous}}
          )
        ],
        else: []

    footer =
      previous ++
        next ++ [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})]

    offset = if window, do: window.offset, else: 0
    title = Density.safe("Detail · byte #{offset}", state, rect.width - 2)

    {title, options, footer,
     if(state.focus in ["cancel", "next", "previous"], do: state.focus, else: "dialog")}
  end

  defp contents(:help, state, rect, _class) do
    options =
      [
        {"help-focus", "Tab / Shift+Tab: cycle focused region"},
        {"help-move", "Up / Down: move; Enter: activate"},
        {"help-scroll", "PageUp / PageDown: scroll; End: follow"},
        {"help-inspect", "i: Inspector · Esc: Back / close"},
        {"help-detach", "q: Detach · P: Exit; rerun with --plain"},
        {"help-editor", "Composer: Enter send; Ctrl+O newline; Alt+Enter queue"},
        {"help-safety", "Fake demo only. No user data or real execution."},
        {"help-focus-current", "Focus: " <> state.focus}
      ]
      |> Enum.map(fn {id, label} -> {id, Density.safe(label, state, rect.width * 4), nil} end)

    {SafeText.chrome(:help), options,
     [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})],
     focus(state, options)}
  end

  defp contents({:run_inspector, id, _tab}, state, rect, class) do
    state = %{state | destination: {:run, id}}
    # Inspector blocks remain inert display facts; mutation actions are permission filtered.
    agents =
      state.read_model.agents
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.filter(fn {_, a} -> a.run_id == id end)

    options =
      Enum.map(agents, fn {key, agent} ->
        action =
          if class != :compressed_small and Support.allowed?(state, agent, :stop_agent),
            do: {:intent, {:stop_agent, agent.run_id, agent.id, agent.revision}},
            else: nil

        caption = "Agent " <> key <> " · " <> String.upcase(Atom.to_string(agent.state))

        caption =
          if agent.launched_by_superseded,
            do: caption <> " · LAUNCHED BY SUPERSEDED TURN",
            else: caption

        {key, Density.safe(caption, state, rect.width * 4), action}
      end)

    {SafeText.chrome(:inspector), options,
     [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})],
     focus(state, options)}
  end

  defp contents({kind, id}, state, rect, class) when kind in [:question, :approval] do
    item = Map.get(state.read_model.interactions, id)

    if item && item.state == :pending && class != :compressed_small do
      interaction(item, state, rect)
    else
      {SafeText.chrome(:read_only_resize), [{"close", SafeText.chrome(:back_close_help), nil}],
       [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})], "close"}
    end
  end

  defp switcher(state, rect, class, background) do
    key = Switcher.field_key(hd(state.layers))
    query = state.field_editors |> FieldEditors.fetch(key) |> Editor.text()
    entries = Switcher.visible(state, background)

    entries =
      if class == :compressed_small do
        Enum.filter(
          entries,
          &(&1.target in [
              {:local, {:open_layer, :help}},
              {:local, {:quit_requested, :detach}},
              {:local, {:presenter_handoff_requested, :plain}}
            ])
        )
      else
        entries
      end

    options =
      Enum.map(entries, fn entry ->
        {entry.id, Density.safe(entry.label, state, rect.width * 4), entry.target}
      end)

    options = if options == [], do: [{"empty", SafeText.chrome(:no_results), nil}], else: options
    title = Density.safe("Search: " <> query, state, rect.width - 2)

    {title, options, [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})],
     if(state.focus == "query", do: "query", else: focus(state, options))}
  end

  defp interaction(%{kind: :question} = item, state, rect) do
    permitted = Support.allowed?(state, item, :answer_question)
    selected = Map.get(state.selection, {:question, item.id}, [])

    selected =
      Enum.filter(selected, fn id -> Enum.any?(item.question.options, &(&1.id == id)) end)

    options =
      item.question.options
      |> Enum.with_index(1)
      |> Enum.map(fn {option, ordinal} ->
        target =
          cond do
            not permitted ->
              nil

            item.question.multiple ->
              {:local, {:select_option, item.id, option.id}}

            true ->
              {:intent,
               {:answer_question, item.run_id, item.node_id, item.id, item.expected_revision,
                [option.id]}}
          end

        marker =
          if item.question.multiple,
            do: if(option.id in selected, do: "[x] ", else: "[ ] "),
            else: ""

        {option.id,
         Density.safe("Option #{ordinal} · " <> marker <> option.label, state, rect.width * 32),
         target}
      end)

    submit =
      if item.question.multiple and permitted and selected != [] do
        [
          control(
            "submit",
            SafeText.chrome(:submit),
            {:intent,
             {:answer_question, item.run_id, item.node_id, item.id, item.expected_revision,
              selected}}
          )
        ]
      else
        []
      end

    footer = submit ++ [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})]

    {Density.safe(item.question.prompt, state, rect.width * 4), options, footer,
     focus(state, options)}
  end

  defp interaction(item, state, _rect) do
    options =
      for decision <- [:approve, :deny, :always_allow] do
        action =
          if Support.allowed?(state, item, decision),
            do:
              {:intent,
               {:resolve_approval, item.run_id, item.node_id, item.id, item.expected_revision,
                decision}},
            else: nil

        {Atom.to_string(decision), SafeText.chrome(decision), action}
      end

    {SafeText.chrome(:approve), options,
     [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})],
     focus(state, options)}
  end

  defp focus(state, options),
    do:
      if(
        state.focus in ["cancel", "submit"] or
          Enum.any?(options, fn {id, _, _} -> id == state.focus end),
        do: state.focus,
        else:
          case List.first(options) do
            nil -> nil
            {id, _, _} -> id
          end
      )

  defp rectangle(size, class) when class in [:narrow, :small, :compressed_small],
    do: %Rect{x: 0, y: 0, width: size.columns, height: size.rows}

  defp rectangle(size, _class) do
    width = min(80, size.columns - 4)
    height = min(24, size.rows - 4)

    %Rect{
      x: div(size.columns - width, 2),
      y: div(size.rows - height, 2),
      width: width,
      height: height
    }
  end
end
