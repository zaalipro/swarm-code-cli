defmodule SwarmCodeCLI.UI.Projector.Dialog do
  @moduledoc "Sticky dialog chrome around a separately windowed, cell-wrapped body."
  alias SwarmCodeCLI.UI.{Editor, FieldEditors, SafeText, Switcher, Theme, UnifiedDiff, Width}
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
        if(match?({:approval, _}, layer),
          do: "PgUp/PgDn: scroll arguments",
          else: "item #{min(ordinal + 1, length(options))} of #{length(options)}"
        ),
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
      title: pad_title(title, state, rect),
      blocks: visible,
      footer: footer,
      focused_control_id: focus,
      body_scroll: first,
      body_visible_range: {first, min(first + height, length(rows))},
      body_total_count: length(rows)
    }
  end

  # Pad the title with one space on each side so it reads like ┌─ Title ─┐
  # rather than starting flush at the corner.  Elide to rect.width - 4 first
  # (2 border + 2 padding) so the padded result fits in rect.width - 2.
  defp pad_title(title, state, rect) do
    max_cells = max(0, rect.width - 4)
    safe = Density.safe(title, state, max_cells)
    text = SafeText.value(safe)

    if text == "" do
      safe
    else
      Density.safe(" " <> text <> " ", state, rect.width - 2)
    end
  end

  defp control(id, label, target), do: {:dialog_control, id, label, target}

  defp contents({:command_report, _}, %{command_report: report} = state, rect, _class)
       when not is_nil(report) do
    rows =
      report.text
      |> String.split("\n")
      |> Enum.with_index()
      |> Enum.map(fn {line, i} ->
        {"report-#{i}", Density.external(line, SafeText.Limits.content()), nil}
      end)

    {Density.safe(report.title, state, rect.width - 2), rows,
     [
       control("cancel", Density.safe("Close", state, rect.width - 2), {:local, :close_top_layer})
     ], state.focus}
  end

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
        {"help-safety",
         if(state.banner in [:live_banner, :persisted_banner],
           do:
             if(state.banner == :persisted_banner,
               do: "Saved local session. Ctrl+K: feature libraries.",
               else: "Live session · unsaved. Ctrl+K: feature libraries."
             ),
           else: "Fake demo only. No user data or real execution."
         )},
        {"help-focus-current", "Focus: " <> state.focus}
      ]
      |> Enum.map(fn {id, label} -> {id, Density.safe(label, state, rect.width * 4), nil} end)

    {SafeText.chrome(:help), options,
     [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})],
     focus(state, options)}
  end

  defp contents({:library, feature}, state, rect, _class) do
    alias SwarmCodeCLI.UI.Library
    body = state.library && state.library.body
    selected = Library.selected(state)

    options =
      Enum.map(Library.rows(state), fn {item, index} ->
        label = item.title <> " · " <> item.status
        label = if selected && selected.id == item.id, do: "› " <> label, else: "  " <> label

        {"row-#{index}", Density.safe(label, state, rect.width * 2),
         {:local, {:library_select, item.id}}}
      end)

    detail =
      cond do
        state.library && state.library.confirmation ->
          {id, action} = state.library.confirmation
          item = Enum.find((body && body.items) || [], &(&1.id == id))

          {verb, consequence} =
            case action do
              :delete -> {"Delete", "This removes the saved entry."}
              :clear -> {"Clear", "This removes the saved memory content."}
              :restore -> {"Restore", "This restores the checkpoint and changes project files."}
            end

          verb <> " " <> ((item && item.title) || id) <> "? " <> consequence

        is_nil(body) ->
          "Loading…"

        body.state == :error ->
          "Unavailable · " <> body.error.message

        options == [] ->
          "No entries"

        selected ->
          selected.subtitle <> "\n" <> selected.detail

        true ->
          "Select an entry to view details and actions."
      end

    options = options ++ detail_rows(feature, detail, state, rect)

    options =
      if state.library && state.library.message,
        do:
          options ++ [{"result", Density.safe(state.library.message, state, rect.width * 2), nil}],
        else: options

    footer =
      Enum.map(Library.controls(state), fn {id, label, action} ->
        control(id, Density.safe(label, state, 40), {:local, action})
      end)

    graph = Library.focus_graph(state)

    {SafeText.external(Library.title(feature), SafeText.Limits.content()) |> elem(1), options,
     footer, if(state.focus in graph, do: state.focus, else: "cancel")}
  end

  defp contents({:research_form, owner}, state, rect, _class) do
    q = FieldEditors.fetch(state.field_editors, {:research_question, owner}) |> Editor.text()
    depth = Map.get(state.selection, {:research_form, :depth}, :medium)

    options =
      [{"question", "Question: " <> if(q == "", do: "(required)", else: q), nil}] ++
        Enum.map([:low, :medium, :high, :ultra], fn d ->
          {Atom.to_string(d), if(d == depth, do: "› ", else: "  ") <> Atom.to_string(d),
           {:local, {:research_depth, d}}}
        end)

    options =
      Enum.map(options, fn {id, label, target} ->
        {id, Density.safe(label, state, 4_100), target}
      end)

    options =
      if state.library.message,
        do:
          options ++ [{"result", Density.safe(state.library.message, state, rect.width * 4), nil}],
        else: options

    {Density.safe("New research", state, rect.width), options,
     [
       control("start", Density.safe("Start", state, 40), {:local, :research_start}),
       control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})
     ], state.focus}
  end

  defp contents({:feature_form, _feature, _id}, state, rect, _class) do
    form = state.feature_form.form

    options =
      Enum.map(form.fields, fn field ->
        value = SwarmCodeCLI.UI.FeatureForm.value(state, field.key)
        label = field.label <> ": " <> if(value == "", do: "(empty)", else: value)
        {"field:" <> field.key, Density.safe(label, state, rect.width * 3), nil}
      end)

    options =
      if state.feature_form.error,
        do:
          options ++
            [{"error", Density.safe(state.feature_form.error, state, rect.width * 4), nil}],
        else: options

    {Density.safe(form.title, state, rect.width - 2), options,
     [
       control("submit", Density.safe(form.submit_label, state, 40), {:local, :feature_submit}),
       control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})
     ], state.focus}
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
              case SwarmCodeCLI.UI.Question.answer_intent(state, item, option.id) do
                :ignore -> nil
                intent -> {:intent, intent}
              end
          end

        marker =
          if item.question.multiple,
            do: if(option.id in selected, do: "[x] ", else: "[ ] "),
            else: ""

        {option.id,
         Density.safe("Option #{ordinal} · " <> marker <> option.label, state, rect.width * 32),
         target}
      end)

    custom = SwarmCodeCLI.UI.Question.other_text(state, item)

    options =
      options ++
        [
          {"other", Density.safe("Your answer: " <> custom, state, rect.width * 8),
           if(permitted, do: {:local, {:focus_region, "other"}})}
        ]

    submit_intent = SwarmCodeCLI.UI.Question.answer_intent(state, item, "submit")

    submit =
      if permitted and submit_intent != :ignore,
        do: [control("submit", SafeText.chrome(:submit), {:intent, submit_intent})],
        else: []

    footer = submit ++ [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})]

    {Density.safe(item.question.prompt, state, rect.width * 4), options, footer,
     focus(state, options)}
  end

  defp interaction(item, state, rect) do
    details =
      case item.approval do
        nil ->
          []

        approval ->
          [
            {"approval_tool",
             Density.safe(
               approval.tool <> " · " <> Atom.to_string(approval.permission),
               state,
               rect.width * 4
             ), nil},
            {"approval_arguments",
             Density.external(approval.arguments_preview, %{
               SwarmCodeCLI.UI.SafeText.Limits.content()
               | ambiguous_width: state.capabilities.ambiguous_width
             }), nil}
          ]
      end

    full =
      if item.approval && item.approval.arguments_detail_ref do
        [
          {"approval_details", Density.safe("Full arguments", state, 40),
           {:local, {:open_detail, item.run_id, item.approval.arguments_detail_ref.id}}}
        ]
      else
        []
      end

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

    body = details ++ full ++ options

    {SafeText.chrome(:approve), body,
     [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})],
     focus(state, body)}
  end

  # The Changes feature sends real `git diff` text as an item's detail. One
  # option row per diff line keeps the +/- prefixes and hunk headers readable;
  # Density.safe/3 would otherwise fold the whole diff onto a single line.
  # Detail that is not a diff at all (a subtitle, a status note) is left alone.
  defp detail_rows(:changes, detail, state, rect) when is_binary(detail) do
    case UnifiedDiff.blocks(detail, ambiguous_width: state.capabilities.ambiguous_width) do
      {[], _note} ->
        [{"details", Density.safe(detail, state, rect.width * 8), nil}]

      {files, _} ->
        files
        |> Enum.flat_map(&diff_detail_lines/1)
        |> Enum.with_index()
        |> Enum.map(fn {line, index} ->
          {"details-#{index}", Density.safe(line, state, rect.width * 2), nil}
        end)
    end
  end

  defp detail_rows(_feature, detail, state, rect),
    do: [{"details", Density.safe(detail, state, rect.width * 8), nil}]

  defp diff_detail_lines(file) do
    header =
      SafeText.value(file.path) <>
        "  +" <> Integer.to_string(file.added) <> "  -" <> Integer.to_string(file.removed)

    body =
      Enum.flat_map(file.hunks, fn {hunk, lines} ->
        [SafeText.value(hunk) | Enum.map(lines, fn {_kind, text} -> SafeText.value(text) end)]
      end)

    [header] ++ body ++ if(file.truncated?, do: ["…"], else: [])
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
    width = max(1, min(80, size.columns - 4))
    height = max(1, min(24, size.rows - 4))

    %Rect{
      x: div(size.columns - width, 2),
      y: div(size.rows - height, 2),
      width: width,
      height: height
    }
  end
end
