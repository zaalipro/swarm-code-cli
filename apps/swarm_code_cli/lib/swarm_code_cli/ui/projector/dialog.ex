defmodule SwarmCodeCLI.UI.Projector.Dialog do
  @moduledoc "Sticky dialog chrome around a separately windowed, cell-wrapped body."
  alias SwarmCodeCLI.UI.{
    Editor,
    FieldEditors,
    ModelPicker,
    SafeText,
    State,
    Switcher,
    Theme,
    UnifiedDiff,
    Width
  }

  alias SwarmCodeCLI.UI.Scene.{Block, Dialog, Rect, Span}
  alias SwarmCodeCLI.UI.Keymap.Bindings
  alias SwarmCodeCLI.UI.Paint.{Metrics, Options}

  alias SwarmCodeCLI.UI.Projector.{
    ApprovalCard,
    Composer,
    Density,
    Interview,
    KeyLabel,
    RunPalette,
    RunRow,
    RunsDashboard,
    Support,
    Syntax
  }

  def project(state, class, background \\ %{})
  def project(%{layers: []}, _class, _background), do: nil

  # The runs dashboard owns the whole screen and renders surface cards rather
  # than the centred option list, so it builds its own Scene.Dialog.
  def project(%{layers: [{:runs_dashboard, _} | _]} = state, class, _background),
    do: RunsDashboard.dialog(state, class)

  # The run palette is centred rather than full screen, but it is the same kind
  # of body: striped surface rows carrying a gauge, not single-line options.
  def project(%{layers: [{:run_palette, _} | _]} = state, class, _background),
    do: RunPalette.dialog(state, class)

  # pass75 interview: an `ask_user` call is one note, built by its own
  # projector (frames QA1-QA3).
  def project(%{layers: [{:question, node_id} | _]} = state, class, _background),
    do: Interview.dialog(state, class, node_id)

  # An approval drawn in the composer slot is not a modal (the projector draws
  # no overlay for it), but the reducer still pages its body through this
  # geometry, so here it is the card's own window.
  def project(%{layers: [{:approval, _} | _]} = state, class, background) do
    layout = SwarmCodeCLI.UI.Layout.for_state(state)

    with %{width: width} = rect <- Map.get(layout.rects, :composer),
         id when is_binary(id) <- Composer.opened_approval(state),
         %{window: {first, shown, total}} <- ApprovalCard.layout(state, width) do
      %Dialog{
        id: "dialog",
        rect: rect,
        title:
          Density.safe(ApprovalCard.title(state.read_model.interactions[id], state), state, 80),
        blocks: [],
        focused_control_id: state.focus,
        body_scroll: first,
        body_visible_range: {first, first + shown},
        body_total_count: total
      }
    else
      _ -> modal(state, class, background)
    end
  end

  def project(state, class, background), do: modal(state, class, background)

  defp modal(state, class, background) do
    layer = hd(state.layers)
    rect = layer |> rectangle(state.size, class) |> beside_panel(layer, state)

    # `decor` draws a picker row as more than text in colour: the title with
    # the query's letters picked out, the detail dimmed, the kind or shortcut
    # against the right edge, a check on the current one, provider headings.
    {title, options, footer, focus, decor} =
      case layer do
        {kind, _} when kind in [:switcher, :action_menu, :region_filter] ->
          switcher(state, rect, class, background)

        {:model_picker, _, _} ->
          model_picker(layer, state, rect)

        {:effort_picker, scope} ->
          effort_picker(scope, state, rect)

        _ ->
          {title, options, footer, focus} = contents(layer, state, rect, class)
          {title, options, footer, focus, %{}}
      end

    footer_focus? = Enum.any?(footer, &match?({:dialog_control, ^focus, _, _}, &1))
    theme_focus = Theme.style(:focus, state.capabilities)
    mono? = theme_focus.prefix != nil

    # In colour the focused row is the hover surface with the accent rail and
    # every row is indented by the rail's two cells, so text never shifts as
    # focus moves; in monochrome the focus cue says it in words (ux M6).
    style =
      if mono?,
        do: theme_focus,
        else: %{
          RunRow.tinted(:text_primary, state)
          | modifiers: [:bold],
            background: hover(state)
        }

    prefix_width =
      if mono?,
        do:
          Width.cells(SafeText.value(theme_focus.prefix), state.capabilities.ambiguous_width) + 1,
        else: 2

    footer =
      Enum.map(footer, fn
        {:dialog_control, id, label, target} when id == focus ->
          Support.action(label, target, style)

        {:dialog_control, _, label, target} ->
          Support.action(label, target)

        block ->
          block
      end)

    # Headings (and E20's sublines) are not items.
    items =
      Enum.reject(options, fn {id, _, _} ->
        match?(%{heading: _}, Map.get(decor, id)) or match?(%{subline: _}, Map.get(decor, id))
      end)

    found = Enum.find_index(items, fn {id, _, _} -> id == focus end)
    ordinal = found || 0

    overflow =
      Support.text(
        case layer do
          {:approval, _} ->
            "PgUp/PgDn: scroll arguments"

          :help ->
            "PgUp/PgDn, Ctrl-D/U scroll · #{length(options)} lines"

          # pass70 Q10: where the choice is and how to make it, not "item 1 of 8".
          _ ->
            "#{min(ordinal + 1, length(items))} of #{length(items)} · Enter chooses · Esc closes"
        end,
        state,
        rect.width - 2
      )

    # cli020 E16 (ux-live-19): a message (a confirm, a report) is its words
    # and one row of actions, without a chooser's count line.
    message? = message_layer?(layer) and class != :compressed_small

    footer =
      if message?,
        do: [%Block.ActionDeck{actions: Enum.intersperse(footer, Support.text("   ", state, 3))}],
        else: [overflow | footer]

    {measured_footer, _} = Support.finalize(footer, state.revision)
    diff? = diff_layer?(layer, state)

    paint_options = %Options{
      color_mode: state.capabilities.color_mode,
      ascii?: state.capabilities.ascii?,
      glyph_tier: state.capabilities.glyph_tier
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

        width =
          max(1, rect.width - 2 - if(focused? or not mono?, do: prefix_width, else: 0))

        # A decorated row is one line; its spans clip it. cli020 E11: the
        # library and command reports are prose and wrap at words.
        lines =
          cond do
            Map.has_key?(decor, id) and not mono? ->
              [text]

            prose_layer?(layer) ->
              SwarmCodeCLI.UI.Prose.wrap(text, width, state.capabilities.ambiguous_width)

            true ->
              Width.wrap(text, width, state.capabilities.ambiguous_width)
          end

        Enum.map(lines, fn line ->
          {id, Density.safe(line, state, rect.width - 2), action}
        end)
      end)

    # A picker is as tall as its rows (top edge where the centred box would
    # start, so filtering shortens it from below), never a tall empty box.
    rect =
      if picker_layer?(layer) and class not in [:narrow, :small, :compressed_small],
        do: %{rect | height: min(rect.height, max(8, length(rows) + 2 + footer_height))},
        else: rect

    rect =
      if message? do
        height = min(rect.height, max(4, length(rows) + 2 + footer_height))
        %{rect | height: height, y: rect.y + div(rect.height - height, 2)}
      else
        rect
      end

    height = max(0, rect.height - 2 - footer_height)

    # cli020 E6 (ux-live-1): in a picker the selected entry is always inside
    # the window. With the focus in the query (a fresh Ctrl-P) the selection
    # is the entry the footer counts (`ordinal`), not an offset an earlier
    # dialog left in `dialog_scroll`.
    selected =
      case Enum.any?(rows, fn {id, _, _} -> id == focus end) do
        false when items != [] ->
          if picker_layer?(layer), do: items |> Enum.at(ordinal) |> elem(0), else: focus

        _ ->
          focus
      end

    indices =
      rows
      |> Enum.with_index()
      |> Enum.filter(fn {{id, _, _}, _} -> id == selected end)
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
          if mono? do
            cond do
              action && first? && focused? -> Support.action(text, action, style)
              action && first? -> Support.action(text, action)
              focused? -> %Block.RichText{spans: [%Span{text: text, style: style}]}
              true -> %Block.Text{text: text}
            end
          else
            spans =
              case Map.get(decor, id) do
                nil ->
                  option_spans(
                    text,
                    id == focus and not footer_focus?,
                    state,
                    rect.width - 2,
                    line_role(diff?, text)
                  )

                row ->
                  decor_spans(row, id == focus and not footer_focus?, state, rect.width - 2)
              end

            if action && first?,
              do: Support.action_spans(spans, action),
              else: %Block.RichText{spans: spans}
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

  # What a detail is, from its ref's suffix (`<id>:diff`, `<id>:reasoning`).
  defp detail_words(ref) when is_binary(ref) do
    cond do
      String.ends_with?(ref, ":diff") -> "Diff"
      String.ends_with?(ref, ":reasoning") -> "Reasoning"
      String.ends_with?(ref, ":arguments") -> "Arguments"
      true -> "Full text"
    end
  end

  defp detail_words(_ref), do: "Full text"

  # A diff reads in its colours: the detail of a `…:diff` ref, or of text that
  # is a unified diff, and the Changes feature's git diff.
  defp diff_layer?({:detail, _run, ref}, state) do
    (is_binary(ref) and String.ends_with?(ref, ":diff")) or
      match?(%{window: %{text: "diff --git" <> _}}, state.detail) or
      match?(%{window: %{text: "@@ " <> _}}, state.detail)
  end

  defp diff_layer?({:library, :changes}, _state), do: true
  defp diff_layer?(_layer, _state), do: false

  defp line_role(false, _text), do: :text_primary

  defp line_role(true, text) do
    case text |> SafeText.value() |> Syntax.line(:diff) do
      [{_, :add}] -> :success
      [{_, :del}] -> :error
      [{_, :hunk}] -> :info
      [{_, :meta}] -> :text_muted
      _ -> :text_primary
    end
  end

  # One option row in colour: two cells of rail (the accent stripe when
  # focused), the text, and for the focused row the hover surface to the edge.
  defp option_spans(text, focused?, state, width, role) do
    policy = state.capabilities.ambiguous_width
    used = Width.cells(SafeText.value(text), policy) + 2

    if focused? do
      surface = hover(state)
      rail = SafeText.value(Support.rail(state))

      [
        %Span{
          text: Density.safe(rail <> " ", state, 2),
          style: %{RunRow.tinted(:accent, state) | background: surface}
        },
        %Span{
          text: text,
          style: %{RunRow.tinted(:text_primary, state) | modifiers: [:bold], background: surface}
        },
        %Span{
          text: Density.safe(String.duplicate(" ", max(0, width - used)), state, width),
          style: %{RunRow.tinted(:text_primary, state) | background: surface}
        }
      ]
    else
      [
        %Span{text: Density.safe("  ", state, 2), style: RunRow.tinted(:text_primary, state)},
        %Span{text: text, style: RunRow.tinted(role, state)}
      ]
    end
  end

  defp hover(state), do: Theme.style(:hover, state.capabilities).background

  defp message_layer?({kind, _}) when kind in [:unsent_changes, :confirm_intent, :command_report],
    do: true

  defp message_layer?(_layer), do: false

  defp prose_layer?({kind, _}) when kind in [:library, :command_report, :rewind_confirm],
    do: true

  defp prose_layer?(_layer), do: false

  defp picker_layer?({kind, _}) when kind in [:switcher, :action_menu, :region_filter, :jump],
    do: true

  defp picker_layer?({:model_picker, _, _}), do: true
  defp picker_layer?({:effort_picker, _}), do: true
  defp picker_layer?(_layer), do: false

  # A picker row in colour: rail, an optional check, the title with the
  # query's letters in the accent, the detail dimmed, and the kind or
  # shortcut against the right edge. A heading is a faint bold line.
  defp decor_spans(%{heading: heading}, _focused?, state, width) do
    [
      %Span{
        text: Density.safe("  " <> heading, state, width),
        style: %{RunRow.tinted(:text_faint, state) | modifiers: [:bold]}
      }
    ]
  end

  defp decor_spans(%{subline: text}, _focused?, state, width) do
    policy = state.capabilities.ambiguous_width
    # Under the title: past the rail and the mark column.
    lead = "    "
    room = max(1, width - Width.cells(lead, policy))

    [
      %Span{
        text: Density.safe(lead <> Width.elide(text, room, :end, policy), state, width),
        style: RunRow.tinted(:text_faint, state)
      }
    ]
  end

  defp decor_spans(row, focused?, state, width) do
    policy = state.capabilities.ambiguous_width
    surface = if focused?, do: hover(state)

    paint = fn role, modifiers ->
      %{RunRow.tinted(role, state) | background: surface, modifiers: modifiers}
    end

    rail =
      if focused?,
        do: {SafeText.value(Support.rail(state)) <> " ", paint.(:accent, [])},
        else: {"  ", paint.(:text_primary, [])}

    mark =
      cond do
        not row.marks? ->
          []

        row.current? ->
          [{SafeText.value(Support.glyph(:check, state)) <> " ", paint.(:success, [:bold])}]

        true ->
          [{"  ", paint.(:text_primary, [])}]
      end

    title_style = paint.(:text_primary, if(focused?, do: [:bold], else: []))
    hit_style = paint.(:accent, [:bold])
    measure = fn spans -> Enum.reduce(spans, 0, &(&2 + Width.cells(elem(&1, 0), policy))) end

    detail =
      if row.detail in [nil, ""],
        do: [],
        else: [{"  " <> row.detail, paint.(:text_faint, [])}]

    # pass70 QA: a long title gives way to its detail. The detail ("3 runs ·
    # 5 min ago") is what tells one conversation from the next, and it was
    # the part cut at the border ("11 runs · o"); the title is elided instead,
    # as long as a readable stretch of it is left, and one cell stays clear
    # before the border as on the rows with a kind at the right.
    room = width - measure.([rail | mark]) - measure.(detail) - 1

    # cli020 E20: words at the right edge (a conversation's age) keep their
    # place too, while a readable stretch of the title is left.
    right_room = if row.right in [nil, ""], do: 0, else: Width.cells(row.right, policy) + 2
    room = if room - right_room >= 16, do: room - right_room, else: room

    title_text =
      if detail != [] and Width.cells(row.title, policy) > room and room >= 16,
        do: Width.elide(row.title, room, :end, policy),
        else: row.title

    title =
      for {piece, hit?} <- highlight(title_text, row.query),
          do: {piece, if(hit?, do: hit_style, else: title_style)}

    right = if row.right in [nil, ""], do: [], else: [{row.right, paint.(row.right_role, [])}]

    left = [rail | mark] ++ title ++ detail
    left_cells = measure.(left)
    right_cells = measure.(right)

    spans =
      if right != [] and left_cells + right_cells + 2 <= width,
        do:
          left ++
            [
              {String.duplicate(" ", width - left_cells - right_cells - 1),
               paint.(:text_primary, [])}
            ] ++
            right ++ [{" ", paint.(:text_primary, [])}],
        else:
          left ++ [{String.duplicate(" ", max(0, width - left_cells)), paint.(:text_primary, [])}]

    spans
    |> clip_pieces(width, policy)
    |> Enum.map(fn {text, style} ->
      %Span{text: Density.safe(text, state, width), style: style}
    end)
  end

  defp clip_pieces(pieces, width, policy) do
    {kept, _} =
      Enum.reduce_while(pieces, {[], 0}, fn {text, style}, {acc, used} ->
        cells = Width.cells(text, policy)

        cond do
          text == "" ->
            {:cont, {acc, used}}

          used + cells <= width ->
            {:cont, {[{text, style} | acc], used + cells}}

          used >= width ->
            {:halt, {acc, used}}

          true ->
            {taken, _, taken_cells} = Width.take_cells(text, width - used, policy)
            {:halt, {[{taken, style} | acc], used + taken_cells}}
        end
      end)

    Enum.reverse(kept)
  end

  # The title cut at the query's first case-insensitive match, else whole.
  # The palette matches fuzzily, so most titles it lists do not contain the
  # query at all (`:nomatch`, which is truthy: a `cond` on it crashed the
  # projector and closed the session, pass70 F).
  defp highlight(title, query) do
    query = query |> to_string() |> String.trim() |> String.trim_leading("/") |> strip_kind()
    down = String.downcase(title)

    case query != "" and :binary.match(down, String.downcase(query)) do
      {at, size} when byte_size(down) == byte_size(title) ->
        [
          {binary_part(title, 0, at), false},
          {binary_part(title, at, size), true},
          {binary_part(title, at + size, byte_size(title) - at - size), false}
        ]
        |> Enum.reject(&(elem(&1, 0) == ""))

      _ ->
        [{title, false}]
    end
  end

  defp strip_kind(<<c, rest::binary>>) when c in [?@, ?#, ?>], do: String.trim(rest)
  defp strip_kind(query), do: query

  # Chrome words for what an entry is, when it is not an action.
  @entry_kinds %{
    command: "command",
    workflow: "workflow",
    project: "project",
    repository: "repository",
    conversation: "conversation",
    research: "research",
    run: "run"
  }

  # The key that does the same as a palette action, from the binding table.
  @entry_bindings %{
    {:local, {:open_layer, :help}} => :help,
    {:local, {:toggle_dock, :inspector}} => :toggle_inspector,
    {:local, {:panel_mode, :cycle}} => :toggle_inspector,
    {:local, {:presenter_handoff_requested, :plain}} => :presenter_handoff
  }

  defp entry_right(entry, state) do
    case Map.get(@entry_bindings, entry.target) do
      nil ->
        {Map.get(@entry_kinds, entry.kind, ""), :text_faint}

      id ->
        case Bindings.keys_for(id, SwarmCodeCLI.UI.Keymap.overrides(state)) do
          [key | _] -> {KeyLabel.label(key, state.capabilities.ascii?), :key}
          [] -> {"", :text_faint}
        end
    end
  end

  # "always_allow" and "inspector width balanced" read as sentences.
  defp sentence(text) do
    text = String.replace(text, "_", " ")

    case String.next_grapheme(text) do
      {first, rest} -> String.upcase(first) <> rest
      nil -> text
    end
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

  # The go-to popup is a which-key list, not a search: it shows the four keys the
  # binding table says follow `g`, and the second key closes it and acts.
  defp contents({:jump, _}, state, rect, _class) do
    options =
      Enum.map(Bindings.jump_rows(), fn {id, token, action} ->
        {id, Density.safe(SafeText.chrome(token), state, rect.width - 2), {:local, action}}
      end)

    {SafeText.chrome(:jump_title), options,
     [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})], state.focus}
  end

  defp contents(
         {:command_report, _},
         %{command_report: %{rows: [_ | _] = rows} = report} = state,
         rect,
         _class
       ) do
    table = cost_rows(rows, Map.get(report, :total), state)

    {Density.safe(report.title, state, rect.width - 2),
     table
     |> Enum.with_index()
     |> Enum.map(fn {line, i} ->
       {"report-#{i}", Density.safe(line, state, rect.width * 2), nil}
     end),
     [
       control("cancel", Density.safe("Close", state, rect.width - 2), {:local, :close_top_layer})
     ], state.focus}
  end

  defp contents({:command_report, _}, %{command_report: report} = state, rect, _class)
       when not is_nil(report) do
    rows =
      report.text
      |> report_lines(help_geometry(state, rect).text_width, state)
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

    focused =
      if state.focus == "confirm" and class != :compressed_small, do: "confirm", else: "cancel"

    # Quitting with runs still going asks about the runs (E's `quit_live_runs`);
    # the draft is mentioned only when there is one.
    case Map.get(state, :quit_live_runs) do
      live when is_integer(live) and live > 0 ->
        runs = if live == 1, do: "1 live run", else: "#{live} live runs"
        draft = if State.dirty?(state), do: " Your unsent draft is lost too.", else: ""

        # cli020 E16: the keys in words, one row (`Enter/X quit · Esc cancel`).
        quit =
          if class == :compressed_small,
            do: [],
            else: [
              control(
                "confirm",
                Density.safe("Enter/X quit", state, 20),
                {:local, confirm_target}
              )
            ]

        cancel =
          control("cancel", Density.safe("Esc cancel", state, 20), {:local, :close_top_layer})

        {Density.safe("Stop " <> runs <> " and quit?", state, 60),
         [
           {"quit_live_runs", Density.safe("They stop when ncode quits." <> draft, state, 200),
            nil}
         ], quit ++ [cancel], focused}

      _ ->
        {SafeText.chrome(:unsent_changes), [{"cancel", SafeText.chrome(:cancel_exit), nil}],
         [cancel] ++ confirm, focused}
    end
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
    words = detail_words(elem(hd(state.layers), 2))
    words = if offset > 0, do: words <> " · continued", else: words
    title = Density.safe(words, state, rect.width - 2)

    {title, options, footer,
     if(state.focus in ["cancel", "next", "previous"], do: state.focus, else: "dialog")}
  end

  # The help sheet is the binding table for the context the user pressed ? in,
  # grouped the way the table groups it, two entries to a line when the dialog
  # is wide enough to keep both readable. No row is a control, so the footer's
  # Cancel keeps the focus and the rows are never given a focus prefix that
  # would wrap them.
  # Below this inner width a second column leaves each help line under 40
  # cells and elides most of them; one wide column reads better than two
  # clipped ones.

  @help_two_column_width 130
  @help_gutter 2
  @help_key_max 24

  defp contents(:help, state, rect, _class) do
    context = help_context(state)
    inner = max(1, rect.width - 2)
    lines = help_lines(state, help_geometry(state, rect).text_width)

    options =
      lines
      |> Enum.with_index()
      |> Enum.map(fn {line, index} ->
        {"help-" <> Integer.to_string(index), Density.safe(line, state, inner), nil}
      end)

    title = Density.safe("Keys · " <> SwarmCodeCLI.UI.Keymap.Docs.title(context), state, inner)

    {title, options, [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})],
     "cancel"}
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
          empty_words(feature)

        selected ->
          Library.detail_text(feature, selected)

        true ->
          "Select an entry to view details and actions."
      end

    # cli020 E22 (tui-code-12): the CLI never runs the scheduler, so the
    # Schedules list says first when its tasks fire, after a save as well.
    note =
      if feature == :schedules,
        do: [
          {"schedules-note",
           Density.safe(
             "Scheduled tasks fire only while the ncode app is running. Run now works here.",
             state,
             rect.width * 2
           ), nil}
        ],
        else: []

    options = note ++ options ++ detail_rows(feature, detail, state, rect)

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

  # --- cli020 E15: the rewind list and confirm, history search, the queue -----------

  # `{:rewind, %{turns, selected}}` (D10 opens it from C16's `rewind.turns`):
  # one row per turn, newest first, `Turn 7 · <prompt> · 3 files · 2 h ago`;
  # D's reducer moves `selected` and opens the confirm on Enter.
  defp contents({:rewind, %{turns: turns, selected: selected}}, state, rect, _class) do
    rows =
      turns
      |> Enum.with_index()
      |> Enum.map(fn {turn, index} ->
        {"turn-#{index}", Density.safe(rewind_words(turn, state), state, rect.width * 2), nil}
      end)

    rows =
      if rows == [],
        do: [{"empty", Density.safe("Nothing to rewind yet.", state, rect.width), nil}],
        else: rows

    {Density.safe("Rewind", state, rect.width - 2),
     rows ++
       [
         {"keys", Density.safe("↑↓ choose · Enter rewinds to it · Esc closes", state, rect.width),
          nil}
       ], [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})],
     if(turns == [], do: "cancel", else: "turn-#{min(selected, length(turns) - 1)}")}
  end

  # `{:rewind_confirm, turn}`: the three scopes of D10 and what folding means.
  defp contents({:rewind_confirm, turn}, state, rect, _class) do
    title =
      case Map.get(turn, :turn) do
        n when is_integer(n) -> "Rewind to turn #{n}"
        _ -> "Rewind to this prompt"
      end

    choices =
      for {id, key, words, scope} <- [
            {"both", "b", "Conversation and files", :both},
            {"conversation", "c", "Conversation only", :conversation},
            {"files", "f", "Files only", :files}
          ] do
        {id, Density.safe(key <> "  " <> words, state, rect.width), rewind_target(scope)}
      end

    prompt = Map.get(turn, :prompt) || ""

    body =
      [{"prompt", Density.safe(prompt, state, rect.width * 2), nil} | choices] ++
        [
          {"fold",
           Density.safe(
             "Later turns are folded (kept, not deleted); files come back from checkpoints.",
             state,
             rect.width * 2
           ), nil}
        ]

    {Density.safe(title, state, rect.width - 2), body,
     [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})],
     if(state.focus in ["both", "conversation", "files"], do: state.focus, else: "both")}
  end

  # `{:history_search, %{query, rows, selected}}` (D19, C20's answers).
  defp contents(
         {:history_search, %{query: query, rows: rows, selected: selected}},
         state,
         rect,
         _c
       ) do
    found =
      rows
      |> Enum.with_index()
      |> Enum.map(fn {row, index} ->
        text = row |> Map.get(:text, "") |> String.split(["\r\n", "\n"]) |> hd()
        ago = SwarmCodeCLI.UI.Switcher.ago(Map.get(row, :at), state.now)
        label = if ago, do: text <> "  · " <> ago, else: text
        {"history-#{index}", Density.safe(label, state, rect.width * 2), nil}
      end)

    empty =
      cond do
        found != [] ->
          []

        String.trim(query) == "" ->
          [
            {"empty", Density.safe("Type to search your earlier prompts.", state, rect.width),
             nil}
          ]

        true ->
          [{"empty", Density.safe("No earlier prompt matches.", state, rect.width), nil}]
      end

    marker = SafeText.value(Support.glyph(:caret, state))

    {Density.safe("History", state, rect.width - 2),
     [{"query", Density.safe("› " <> query <> marker, state, rect.width * 2), nil}] ++
       found ++ empty, [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})],
     if(found == [], do: "cancel", else: "history-#{min(selected, length(found) - 1)}")}
  end

  # `{:queue_list}` (D20's bare `/queue`): what waits behind the live turn.
  defp contents({:queue_list}, state, rect, _class) do
    workspace = Map.get(state.read_model.snapshots, :workspace) || %{}
    texts = Map.get(workspace, :queued_texts) || []

    rows =
      texts
      |> Enum.with_index(1)
      |> Enum.map(fn {text, n} ->
        line = text |> to_string() |> String.split(["\r\n", "\n"]) |> hd()
        {"queued-#{n}", Density.safe("#{n}  " <> line, state, rect.width * 2), nil}
      end)

    paused =
      if Map.get(workspace, :queue_paused) == true and rows != [],
        do: [
          {"paused",
           Density.safe(
             "Paused · Enter on an empty composer runs the next one",
             state,
             rect.width
           ), nil}
        ],
        else: []

    rows =
      if rows == [],
        do: [{"empty", Density.safe("Nothing queued.", state, rect.width), nil}],
        else:
          rows ++
            paused ++
            [{"keys", Density.safe("/queue drop N · /queue clear", state, rect.width), nil}]

    {Density.safe("Queue", state, rect.width - 2), rows,
     [control("cancel", Density.safe("Close", state, 20), {:local, :close_top_layer})], "cancel"}
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

  # pass71 V5: `/diff` below the docking width opens the inspector as a
  # dialog on its changes tab: the run's files, each opening its diff.
  defp contents({:run_inspector, id, :changes}, state, rect, _class) do
    alias SwarmCodeCLI.UI.Projector.Inspector.Changes

    run = Map.get(state.read_model.runs, id)
    # A turn that changed nothing shows what the conversation changed.
    changes =
      case Changes.changes(state, run || %{id: id}) do
        [] -> Changes.changes(state, nil)
        changes -> changes
      end

    minus = if state.capabilities.ascii?, do: "-", else: "−"

    options =
      changes
      |> Enum.with_index()
      |> Enum.map(fn {change, index} ->
        letter =
          case Map.get(change, :file_state) do
            :created -> "A "
            :modified -> "M "
            :deleted -> "D "
            _ -> ""
          end

        counts =
          case {Map.get(change, :added), Map.get(change, :removed)} do
            {nil, nil} -> ""
            {a, r} -> "  +#{a || 0} #{minus}#{r || 0}"
          end

        target =
          case Map.get(change, :diff_ref) do
            %{id: ref} when is_binary(ref) -> {:local, {:open_detail, change.run_id, ref}}
            _ -> {:local, {:open_layer, {:library, :checkpoints}}}
          end

        {"change-" <> Integer.to_string(index),
         Density.safe(letter <> change.path <> counts, state, rect.width * 2), target}
      end)

    files = changes |> Enum.map(& &1.path) |> Enum.uniq() |> length()

    title =
      case files do
        0 -> "Changes"
        1 -> "Changes · 1 file"
        n -> "Changes · #{n} files"
      end

    options =
      if options == [],
        do: [{"none", Density.safe("No files changed", state, rect.width), nil}],
        else: options

    {Density.safe(title, state, rect.width), options,
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

        _ = key
        name = if is_binary(agent.name) and agent.name != "", do: agent.name, else: "agent"
        {word, _role} = Theme.status(agent.state)
        caption = name <> " · " <> String.downcase(SafeText.value(word))

        caption =
          if agent.launched_by_superseded,
            do: caption <> " · from a replaced turn",
            else: caption

        {key, Density.safe(caption, state, rect.width * 4), action}
      end)

    {SafeText.chrome(:inspector), options,
     [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})],
     focus(state, options)}
  end

  defp contents({:approval, id}, state, rect, class) do
    item = Map.get(state.read_model.interactions, id)

    if item && item.state == :pending && class != :compressed_small do
      interaction(item, state, rect)
    else
      # A lookup miss is not a terminal-size problem: the request was answered,
      # stopped or replaced while the dialog was on its way (rel F2, ux F1).
      message =
        if class == :compressed_small,
          do: SafeText.chrome(:read_only_resize),
          else: Density.safe("This request is no longer pending", state, rect.width - 2)

      {message, [{"close", SafeText.chrome(:back_close_help), nil}],
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

    # cli020 E20: an entry's `subline` is its own dim row under it, not an item.
    options =
      Enum.flat_map(entries, fn entry ->
        row = {entry.id, Density.safe(entry.label, state, rect.width * 4), entry.target}

        case Map.get(entry, :subline) do
          text when is_binary(text) ->
            [row, {entry.id <> ":subline", Density.safe(text, state, rect.width * 2), nil}]

          _ ->
            [row]
        end
      end)

    marks? = Enum.any?(entries, &Map.get(&1, :current?, false))

    sublines =
      for entry <- entries, is_binary(Map.get(entry, :subline)), into: %{} do
        {entry.id <> ":subline", %{subline: entry.subline}}
      end

    decor =
      Map.new(entries, fn entry ->
        title = Map.get(entry, :title) || entry.label

        {right, right_role} =
          case Map.get(entry, :right) do
            words when is_binary(words) -> {words, :text_faint}
            _ -> entry_right(entry, state)
          end

        {entry.id,
         %{
           title: sentence(title),
           detail: Map.get(entry, :detail),
           query: query,
           current?: Map.get(entry, :current?, false),
           marks?: marks?,
           right: right,
           right_role: right_role
         }}
      end)
      |> Map.merge(sublines)

    options = if options == [], do: [{"empty", SafeText.chrome(:no_results), nil}], else: options
    title = Density.safe(switcher_title(search_query(query, state)), state, rect.width - 2)

    {title, options, [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})],
     if(state.focus == "query", do: "query", else: focus(state, options)), decor}
  end

  # pass70 Q10: the palette names what its prefix lists instead of echoing
  # the prefix ("Search: #" after /resume).
  defp switcher_title("#" <> query), do: "Conversations: " <> query
  defp switcher_title("/" <> query), do: "Commands: " <> query
  # pass73 finisher: the /approval picker's rows are a query of their own
  # (`Switcher.approval_query/0`); its title is what it chooses.
  defp switcher_title(">approvals:"), do: "Approvals · who asks before what runs"

  # pass73 G2 (QA Q2-08): what is typed after it filters the three modes;
  # the title shows it, where "NO RESULTS" alone never said why.
  defp switcher_title(">approvals:" <> typed), do: "Approvals: " <> typed
  defp switcher_title(">" <> query), do: "Actions: " <> query
  defp switcher_title("@" <> query), do: "Projects: " <> query
  # cli020 E9: the hits of the last `/search` (C8), titled by its words.
  defp switcher_title("?" <> query), do: "Search results: " <> query

  defp switcher_title(query), do: "Search: " <> query

  defp search_query("?", state) do
    case Map.get(state, :search_results) do
      %{query: words} when is_binary(words) -> "?" <> words
      _ -> "?"
    end
  end

  defp search_query(query, _state), do: query

  # cli020 E4 (decision 4f, D18): the levels the daemon would accept for the
  # model (C17's `effort_levels`), the current one ticked; Enter picks.
  @classic_efforts ~w(low medium high xhigh max)

  defp effort_picker(scope, state, rect) do
    workspace = Map.get(state.read_model.snapshots, :workspace) || %{}

    {levels, current, title} =
      case scope do
        :chat ->
          {Map.get(workspace, :effort_levels), Map.get(workspace, :effort), "Effort · chat model"}

        :swarm ->
          {Map.get(workspace, :swarm_effort_levels), Map.get(workspace, :swarm_effort),
           "Effort · workers"}
      end

    levels =
      case levels do
        [_ | _] = list -> Enum.filter(list, &is_binary/1)
        _ -> @classic_efforts
      end

    mark = SafeText.value(Support.glyph(:check, state))

    {options, decor} =
      levels
      |> Enum.map(fn level ->
        id = "effort-" <> level
        current? = level == current
        label = if(current?, do: mark, else: " ") <> " " <> level

        {{id, Density.safe(label, state, rect.width * 4), effort_target(level)},
         {id,
          %{
            title: level,
            detail: nil,
            query: "",
            current?: current?,
            marks?: true,
            right: if(current?, do: "in use", else: ""),
            right_role: :text_faint
          }}}
      end)
      |> Enum.unzip()

    ids = Enum.map(options, &elem(&1, 0))

    focus =
      cond do
        state.focus in ids -> state.focus
        is_binary(current) and ("effort-" <> current) in ids -> "effort-" <> current
        true -> List.first(ids)
      end

    {Density.safe(title, state, rect.width - 2), options,
     [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})], focus,
     Map.new(decor)}
  end

  # STUB (cli020 §8.3): `{:effort_pick, level}` is D18's action; until it is
  # in `Action`, a row has no target rather than an invalid one.
  defp rewind_words(turn, state) do
    files =
      case Map.get(turn, :files) do
        n when is_integer(n) and n > 0 -> "#{n} #{if n == 1, do: "file", else: "files"}"
        _ -> nil
      end

    at =
      case Map.get(turn, :at) do
        %DateTime{} = at -> DateTime.to_unix(at, :millisecond)
        at -> at
      end

    [
      case Map.get(turn, :turn) do
        n when is_integer(n) -> "Turn #{n}"
        _ -> "Prompt"
      end,
      (Map.get(turn, :prompt) || "") |> String.split(["\r\n", "\n"]) |> hd(),
      files,
      SwarmCodeCLI.UI.Switcher.ago(at, state.now)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  # STUB (cli020 §8.3): `{:rewind_choose, scope}` is D10's action.
  defp rewind_target(scope) do
    target = {:local, {:rewind_choose, scope}}
    if match?({:ok, _}, SwarmCodeCLI.UI.ActionTarget.validate(target)), do: target
  end

  defp effort_target(level) do
    target = {:local, {:effort_pick, level}}
    if match?({:ok, _}, SwarmCodeCLI.UI.ActionTarget.validate(target)), do: target
  end

  # One row per model the daemon lists, the one in use marked, the provider
  # after the model so a filter on either reads the same. A snapshot with no
  # models says so in one line rather than showing an empty search.
  defp model_picker({:model_picker, target, _} = layer, state, rect) do
    query = ModelPicker.query(state, layer)
    mark = SafeText.value(Support.glyph(:check, state))
    rows = ModelPicker.rows(state, layer)

    # In colour the provider is a heading above its models (E's
    # `first_in_group?`, else where the provider changes); the plain label
    # keeps it after the model for monochrome and older painters.
    {headed, _} =
      Enum.map_reduce(rows, nil, fn row, previous ->
        first? = Map.get(row, :first_in_group?, row.provider != previous)
        {{row, first?}, row.provider}
      end)

    mono? = Theme.style(:focus, state.capabilities).prefix != nil

    {options, decor} =
      Enum.reduce(headed, {[], %{}}, fn {row, first?}, {options, decor} ->
        label =
          if(row.current?, do: mark, else: " ") <> " " <> row.model <> "  " <> row.provider

        option = {row.id, Density.safe(label, state, rect.width * 4), {:intent, row.intent}}

        row_decor = %{
          title: row.model,
          detail: nil,
          query: query,
          current?: row.current?,
          marks?: true,
          right: if(row.current?, do: "in use", else: ""),
          right_role: :text_faint
        }

        heading_id = "heading:" <> (Map.get(row, :provider_id) || row.provider || "")

        if first? and not mono? do
          heading = {heading_id, Density.safe(row.provider || "", state, rect.width), nil}

          {[option, heading | options],
           decor
           |> Map.put(row.id, row_decor)
           |> Map.put(heading_id, %{heading: row.provider || ""})}
        else
          {[option | options], Map.put(decor, row.id, row_decor)}
        end
      end)

    options = Enum.reverse(options)
    choices = Enum.reject(options, &match?({"heading:" <> _, _, _}, &1))

    options =
      cond do
        options != [] -> options
        ModelPicker.options(state) == [] -> [{"empty", no_models(state, rect), nil}]
        true -> [{"empty", SafeText.chrome(:no_results), nil}]
      end

    title = Density.safe(ModelPicker.title(target) <> ": " <> query, state, rect.width - 2)

    {title, options, [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})],
     if(state.focus == "query",
       do: "query",
       else: focus(state, if(choices == [], do: options, else: choices))
     ), decor}
  end

  defp no_models(state, rect),
    do: Density.safe("No provider lists any model.", state, rect.width - 2)

  # The approval card answers the three questions the user has before they
  # press a key: who is asking, what exactly would run, and what it could
  # touch. The command comes first because it is what the user will read; the
  # tool and permission line says it in the system's words for anyone who
  # wants them; the risk line says what a yes lets happen. Each decision row
  # carries its key so the card is usable without the help sheet.
  defp interaction(item, state, rect) do
    wide = rect.width * 4

    details =
      case item.approval do
        nil ->
          []

        approval ->
          [
            {"approval_arguments",
             Density.external(approval.arguments_preview, %{
               SwarmCodeCLI.UI.SafeText.Limits.content()
               | ambiguous_width: state.capabilities.ambiguous_width
             }), nil},
            {"approval_tool", Density.safe(approval_tool_line(approval), state, wide), nil},
            {"approval_risk", Density.safe(approval_risk_line(approval), state, wide), nil}
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

    # The same decisions and keys as the card in the composer slot, so the
    # two never disagree about what `y` does.
    options =
      for {decision, key, _words, target} <- Composer.approval_decisions(state, item) do
        label = decision_words(decision) <> "  " <> key
        {Atom.to_string(decision), Density.safe(label, state, wide), target}
      end

    body = details ++ full ++ options

    {Density.safe(approval_title(item, state), state, max(rect.width - 2, 8)), body,
     [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})],
     focus(state, body)}
  end

  defp decision_words(:approve), do: "Approve once"
  defp decision_words(:approve_run), do: "Approve for this run"
  defp decision_words(:always_prefix), do: "Always allow"
  defp decision_words(:always_allow), do: "Always allow"
  defp decision_words(:deny), do: "Deny"
  defp decision_words(:deny_stop), do: "Deny and stop the run"

  # "scout-1 wants to run a command": the agent by name when the daemon has
  # named it, else the plainest true thing.
  defp approval_title(item, state) do
    agent =
      case Map.get(state.read_model.agents, item.node_id) do
        %{name: name} when is_binary(name) and name != "" -> name
        _ -> "The agent"
      end

    agent <> " wants to " <> approval_verb(item.approval, item)
  end

  # pass73 G2 (QA Q2-07): a workflow run in the card's words ("run the
  # workflow /format-and-test"), not "run workflow run".
  defp approval_verb(%{tool: "workflow_run"}, item),
    do:
      SwarmCodeCLI.UI.Projector.ApprovalCard.verb(
        SwarmCodeCLI.UI.Projector.ApprovalCard.facts(item)
      )

  defp approval_verb(approval, _item), do: approval_verb(approval)

  defp approval_verb(nil), do: "do something that needs your permission"
  defp approval_verb(%{tool: "run_command"}), do: "run a command"
  defp approval_verb(%{tool: tool}) when tool in ["edit_file", "write_file"], do: "change a file"
  defp approval_verb(%{tool: "delete_file"}), do: "delete a file"
  defp approval_verb(%{tool: tool, permission: :execute}), do: "run " <> tool_words(tool)
  defp approval_verb(%{tool: tool}), do: "use " <> tool_words(tool)

  defp tool_words(tool) when is_binary(tool), do: String.replace(tool, "_", " ")
  defp tool_words(_tool), do: "a tool"

  # Who asks, by the one name the card, the band and the overlay use.

  defp approval_tool_line(%{tool: tool, permission: permission}),
    do: "Tool: " <> tool_words(tool) <> " · needs permission to " <> permission_word(permission)

  defp permission_word(:execute), do: "execute"
  defp permission_word(:write), do: "write"
  defp permission_word(other), do: to_string(other)

  defp approval_risk_line(%{permission: :execute}),
    do: "A yes runs it on your machine, in the project directory."

  defp approval_risk_line(%{permission: :write}), do: "A yes changes files in the project."
  defp approval_risk_line(_approval), do: "A yes lets it go ahead."

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

  # cli020 E11: one row per line of the detail, each word-wrapped by the modal.
  defp detail_rows(_feature, detail, state, rect) do
    case String.split(detail, "\n") do
      [line] ->
        [{"details", Density.safe(line, state, rect.width * 8), nil}]

      lines ->
        lines
        |> Enum.with_index()
        |> Enum.map(fn {line, index} ->
          {"details-#{index}", Density.safe(line, state, rect.width * 8), nil}
        end)
    end
  end

  # cli020 E16 (ux-live-19): an empty list says what fills it.
  defp empty_words(:checkpoints), do: "No checkpoints yet: they are taken before each edit."
  defp empty_words(_feature), do: "No entries"

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

  @doc false
  # cli020 E7 (ux-live-8): the sheet's text width is the dialog's inner width
  # minus the two cells of rail every option row is indented by in colour
  # (none in monochrome, where only the focused row carries a prefix and no
  # help row is ever focused). Lines built wider soft-wrapped in the painter:
  # the one-letter `g…` rows and a blank row after every padded entry.
  @spec help_geometry(map(), Rect.t()) :: %{
          text_width: pos_integer(),
          columns: 1 | 2,
          column: pos_integer()
        }
  def help_geometry(state, %Rect{} = rect) do
    mono? = Theme.style(:focus, state.capabilities).prefix != nil
    text_width = max(1, rect.width - 2 - if(mono?, do: 0, else: 2))
    help_columns(text_width)
  end

  defp help_columns(text_width) do
    columns = if text_width + 2 >= @help_two_column_width, do: 2, else: 1
    column = max(1, div(text_width - (columns - 1) * @help_gutter, columns))
    %{text_width: text_width, columns: columns, column: column}
  end

  @doc false
  # The help sheet's text lines at `width` cells (tests read them unscrolled).
  @spec help_lines(map(), pos_integer()) :: [String.t()]
  def help_lines(state, width) do
    context = help_context(state)
    ascii? = state.capabilities.ascii?
    policy = state.capabilities.ambiguous_width
    overrides = SwarmCodeCLI.UI.Keymap.overrides(state)
    %{columns: columns, column: column} = help_columns(width)

    # cli020 E7: the session's keys first (quit and stop lead it); a chord
    # that needs Alt in every spelling is left out (Alt is unreliable on
    # macOS terminals, AGENTS.md).
    sections =
      for group <- help_groups(),
          rows =
            context
            |> Bindings.for_context()
            |> Enum.filter(&(&1.group == group))
            |> Enum.map(&{&1, Bindings.keys_in_context(&1, context, overrides)})
            |> Enum.reject(fn {_binding, keys} -> alt_only?(keys) end)
            |> Enum.sort_by(fn {binding, _keys} -> help_rank(binding.id) end)
            |> Enum.map(fn {binding, keys} -> {KeyLabel.joined(keys, ascii?), binding.help} end),
          rows != [],
          do: {group, rows}

    widest_key =
      sections
      |> Enum.flat_map(fn {_group, rows} -> Enum.map(rows, &Width.cells(elem(&1, 0), policy)) end)
      |> Enum.max(fn -> 0 end)

    # The key column is never wider than half a column, nor than @help_key_max:
    # one row with four spellings of a resize chord must not cost every other
    # row its help text. A chord list that does not fit loses its tail.
    key_width = min(widest_key, max(1, min(@help_key_max, div(column, 2))))

    lines =
      Enum.flat_map(sections, fn {group, rows} ->
        # pass71 V5: headings in sentence case, as everywhere else.
        heading = SwarmCodeCLI.UI.Keymap.Docs.group_title(group)
        entries = Enum.map(rows, &help_entry(&1, key_width, column, state, policy))
        [heading | side_by_side(entries, columns, column)]
      end)

    # pass73 finisher (K's request F2): while wheel reports are on, the sheet
    # ends with how the mouse works and how to select text anyway.
    lines =
      if Map.get(state, :mouse?, true) do
        note =
          SwarmCodeCLI.UI.Keymap.Docs.mouse_note()
          |> String.replace("`", "")
          |> SwarmCodeCLI.UI.Prose.wrap(max(1, width), policy)

        lines ++ [""] ++ note
      else
        lines
      end

    lines ++ help_modes(column, columns, state, policy) ++ help_commands(width, state, policy)
  end

  # Session first (after vim's own keys in a vim mode): Ctrl-C and Esc are
  # what a newcomer looks for.
  defp help_groups, do: [:vim, :session | Bindings.groups() -- [:vim, :session]]

  @help_first [:interrupt, :interrupt_turn, :escape, :close_or_quit]
  defp help_rank(id) do
    case Enum.find_index(@help_first, &(&1 == id)) do
      nil -> length(@help_first)
      index -> index
    end
  end

  defp alt_only?([_ | _] = keys), do: Enum.all?(keys, fn {_code, mods} -> :alt in mods end)
  defp alt_only?(_keys), do: false

  # Entries are lists of rows; two to a line, each padded to `column`, the
  # shorter one padded with blank rows so the pair stays aligned.
  defp side_by_side(entries, 1, _column), do: Enum.concat(entries)

  defp side_by_side(entries, columns, column) do
    blank = String.duplicate(" ", column)

    entries
    |> Enum.chunk_every(columns)
    |> Enum.flat_map(fn chunk ->
      height = chunk |> Enum.map(&length/1) |> Enum.max()

      chunk
      |> Enum.map(&(&1 ++ List.duplicate(blank, height - length(&1))))
      |> Enum.zip_with(&Enum.join(&1, String.duplicate(" ", @help_gutter)))
    end)
  end

  # cli020 E2 (Q6): the six modes and what each does; CLI Ultra runs
  # workflows (the ncode app's missions are not ported yet).
  defp help_modes(column, columns, state, policy) do
    rows =
      for {value, label, _glyph, hint, _icon} <- SwarmCode.Commands.modes(),
          do: {SwarmCodeCLI.UI.Projector.Composer.mode_title(value, label), hint}

    width =
      rows
      |> Enum.map(&Width.cells(elem(&1, 0), policy))
      |> Enum.max(fn -> 0 end)
      |> min(max(1, div(column, 2)))

    entries = Enum.map(rows, &help_entry(&1, width, column, state, policy))
    ["", "Modes" | side_by_side(entries, columns, column)]
  end

  # cli020 E7: `/help` lists the commands too (the `/` list's rows: the
  # client's own and the service's), one to a line.
  defp help_commands(width, state, policy) do
    rows =
      for item <- SwarmCodeCLI.UI.SlashPalette.catalogue("/"),
          do: {String.trim("/" <> item.name <> " " <> (item.args || "")), item.desc || ""}

    key_width =
      rows
      |> Enum.map(&Width.cells(elem(&1, 0), policy))
      |> Enum.max(fn -> 0 end)
      |> min(max(1, min(32, div(width, 2))))

    ["", "Commands" | Enum.flat_map(rows, &help_entry(&1, key_width, width, state, policy))]
  end

  # One "keys  help" entry: rows exactly `column` cells wide so two of them
  # line up. Help longer than its cell word-wraps onto continuation rows
  # under the help column; a key list that does not fit loses its tail.
  defp help_entry({keys, help}, key_width, column, state, policy) do
    key_cell = keys |> Width.elide(key_width, :end, policy) |> RunRow.pad(key_width, state)
    help_width = column - key_width - @help_gutter

    if help_width > 0 do
      indent = String.duplicate(" ", key_width + @help_gutter)
      gutter = String.duplicate(" ", @help_gutter)

      case SwarmCodeCLI.UI.Prose.wrap(help, help_width, policy) do
        [] ->
          [RunRow.pad(key_cell, column, state)]

        [first | rest] ->
          [RunRow.pad(key_cell <> gutter <> first, column, state)] ++
            Enum.map(rest, &RunRow.pad(indent <> &1, column, state))
      end
    else
      [RunRow.pad(key_cell, column, state)]
    end
  end

  # cli020 E16 (C18): `/cost` by model, `model  12k in · 3k out  $0.04`,
  # aligned, then the total (C18's, else the sum; a model without a price
  # reads `—`).
  defp cost_rows(rows, total, state) do
    policy = state.capabilities.ambiguous_width
    rows = Enum.filter(rows, &is_map/1)

    sum = fn key -> Enum.reduce(rows, 0, &(&2 + (Map.get(&1, key) || 0))) end

    total =
      case total do
        %{} = total ->
          total

        _ ->
          prices = rows |> Enum.map(&Map.get(&1, :cost_usd)) |> Enum.filter(&is_number/1)

          %{
            model: "Total",
            tokens_in: sum.(:tokens_in),
            tokens_out: sum.(:tokens_out),
            cost_usd: if(prices == [], do: nil, else: Enum.sum(prices))
          }
      end

    lines =
      Enum.map(rows ++ [Map.put(total, :model, "Total")], fn row ->
        {to_string(Map.get(row, :model) || "?"),
         compact_tokens(Map.get(row, :tokens_in)) <>
           " in · " <> compact_tokens(Map.get(row, :tokens_out)) <> " out",
         case Map.get(row, :cost_usd) do
           cost when is_number(cost) -> "$" <> :erlang.float_to_binary(cost / 1, decimals: 2)
           _ -> "—"
         end}
      end)

    name_w = lines |> Enum.map(&Width.cells(elem(&1, 0), policy)) |> Enum.max(fn -> 0 end)
    tok_w = lines |> Enum.map(&Width.cells(elem(&1, 1), policy)) |> Enum.max(fn -> 0 end)
    pad = fn text, w -> text <> String.duplicate(" ", max(0, w - Width.cells(text, policy))) end

    Enum.map(lines, fn {name, tokens, cost} ->
      pad.(name, name_w) <> "  " <> pad.(tokens, tok_w) <> "  " <> cost
    end)
  end

  defp compact_tokens(n) when is_integer(n) and n >= 1_000,
    do: SwarmCodeCLI.UI.Projector.Workspace.Turns.compact(n)

  defp compact_tokens(n) when is_integer(n), do: Integer.to_string(n)
  defp compact_tokens(_n), do: "0"

  # cli020 E11 (ux-live-7): a report's Markdown list of named entries
  # (`- **reviewer** (bundled) — Code reviewer…`, `/agents`) is a two-column
  # list, the description word-wrapped under its column; other lines as sent.
  @entry_line ~r/^- \*\*(.+?)\*\*(?: \(([^)]*)\))? — (.*)$/u

  defp report_lines(text, width, state) do
    policy = state.capabilities.ambiguous_width
    lines = String.split(text, "\n")

    entries =
      for line <- lines, match = Regex.run(@entry_line, line), match != nil, into: %{} do
        [_, name, source, description] = match ++ List.duplicate("", 4 - length(match))
        label = if source in [nil, ""], do: name, else: name <> " (" <> source <> ")"
        {line, {label, description}}
      end

    column =
      entries
      |> Map.values()
      |> Enum.map(&Width.cells(elem(&1, 0), policy))
      |> Enum.max(fn -> 0 end)
      |> min(max(8, div(width, 2)))

    Enum.flat_map(lines, fn line ->
      case Map.get(entries, line) do
        nil -> [line]
        {label, description} -> help_entry({label, description}, column, width, state, policy)
      end
    end)
  end

  # The sheet describes the state underneath it: the layers below the help
  # layer and the focus the reducer saved when it opened.
  defp help_context(state) do
    focus =
      case state.layer_contexts do
        [%{focus: focus} | _] -> focus
        _ -> state.focus
      end

    SwarmCodeCLI.UI.Keymap.Context.of(%{state | layers: tl(state.layers), focus: focus})
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

  defp rectangle(_layer, size, class) when class in [:narrow, :small, :compressed_small],
    do: %Rect{x: 0, y: 0, width: size.columns, height: size.rows}

  # The help sheet is a reference, not a prompt: it takes the room a wide
  # terminal has, which is what lets it run two columns, and most of the
  # height, which is what keeps a context's whole grammar on one screen.
  defp rectangle(:help, size, _class), do: centred(size, 150, size.rows - 2)
  defp rectangle(_layer, size, _class), do: centred(size, 80, 24)

  # pass72 F: with the side panel docked, a prompt is centred over the chat
  # (main) rather than the whole screen, so it leaves the panel's needs-you
  # band readable while it asks. Only the x moves, and only when main has room.
  defp beside_panel(%Rect{} = rect, layer, state) when layer != :help do
    case SwarmCodeCLI.UI.Layout.for_state(state).rects do
      %{inspector: _, main: %Rect{x: mx, width: mw}} when mw >= rect.width + 2 ->
        %{rect | x: mx + div(mw - rect.width, 2)}

      _ ->
        rect
    end
  end

  defp beside_panel(rect, _layer, _state), do: rect

  defp centred(size, max_width, max_height) do
    width = max(1, min(max_width, size.columns - 4))
    height = max(1, min(max_height, size.rows - 4))

    %Rect{
      x: div(size.columns - width, 2),
      y: div(size.rows - height, 2),
      width: width,
      height: height
    }
  end
end
