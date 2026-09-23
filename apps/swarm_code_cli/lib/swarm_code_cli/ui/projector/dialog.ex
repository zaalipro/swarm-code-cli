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

  # An approval drawn in the composer slot is not a modal (the projector draws
  # no overlay for it), but the reducer still pages its body through this
  # geometry, so here it is the card's own window.
  def project(%{layers: [{:approval, _} | _]} = state, class, background) do
    layout = SwarmCodeCLI.UI.Layout.calculate(state.size, state.preferences)

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
    rect = rectangle(layer, state.size, class)

    # `decor` draws a picker row as more than text in colour: the title with
    # the query's letters picked out, the detail dimmed, the kind or shortcut
    # against the right edge, a check on the current one, provider headings.
    {title, options, footer, focus, decor} =
      case layer do
        {kind, _} when kind in [:switcher, :action_menu, :region_filter] ->
          switcher(state, rect, class, background)

        {:model_picker, _, _} ->
          model_picker(layer, state, rect)

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

    # Headings are not items.
    items = Enum.reject(options, fn {id, _, _} -> match?(%{heading: _}, Map.get(decor, id)) end)
    ordinal = Enum.find_index(items, fn {id, _, _} -> id == focus end) || 0

    overflow =
      Support.text(
        case layer do
          {:approval, _} -> "PgUp/PgDn: scroll arguments"
          :help -> "PgUp/PgDn, Ctrl-D/U scroll · #{length(options)} lines"
          _ -> "item #{min(ordinal + 1, length(items))} of #{length(items)}"
        end,
        state,
        rect.width - 2
      )

    footer = [overflow | footer]
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

        # A decorated row is one line; its spans clip it.
        lines =
          if Map.has_key?(decor, id) and not mono?,
            do: [text],
            else: Width.wrap(text, width, state.capabilities.ambiguous_width)

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
      rail = SafeText.value(Support.glyph(:stripe, state))

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

  defp picker_layer?({kind, _}) when kind in [:switcher, :action_menu, :region_filter, :jump],
    do: true

  defp picker_layer?({:model_picker, _, _}), do: true
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

  defp decor_spans(row, focused?, state, width) do
    policy = state.capabilities.ambiguous_width
    surface = if focused?, do: hover(state)

    paint = fn role, modifiers ->
      %{RunRow.tinted(role, state) | background: surface, modifiers: modifiers}
    end

    rail =
      if focused?,
        do: {SafeText.value(Support.glyph(:stripe, state)) <> " ", paint.(:accent, [])},
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

    title =
      for {piece, hit?} <- highlight(row.title, row.query),
          do: {piece, if(hit?, do: hit_style, else: title_style)}

    detail =
      if row.detail in [nil, ""],
        do: [],
        else: [{"  " <> row.detail, paint.(:text_faint, [])}]

    right = if row.right in [nil, ""], do: [], else: [{row.right, paint.(row.right_role, [])}]

    left = [rail | mark] ++ title ++ detail
    measure = fn spans -> Enum.reduce(spans, 0, &(&2 + Width.cells(elem(&1, 0), policy))) end
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
    {:local, {:presenter_handoff_requested, :plain}} => :presenter_handoff
  }

  defp entry_right(entry, state) do
    case Map.get(@entry_bindings, entry.target) do
      nil ->
        {Map.get(@entry_kinds, entry.kind, ""), :text_faint}

      id ->
        case Bindings.keys_for(id) do
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

    focused =
      if state.focus == "confirm" and class != :compressed_small, do: "confirm", else: "cancel"

    # Quitting with runs still going asks about the runs (E's `quit_live_runs`);
    # the draft is mentioned only when there is one.
    case Map.get(state, :quit_live_runs) do
      live when is_integer(live) and live > 0 ->
        runs = if live == 1, do: "1 live run", else: "#{live} live runs"
        draft = if State.dirty?(state), do: " Your unsent draft is lost too.", else: ""

        {Density.safe("Stop " <> runs <> " and quit?", state, 60),
         [
           {"quit_live_runs",
            Density.safe("They stop when SwarmCode quits." <> draft, state, 200), nil}
         ], [cancel] ++ confirm, focused}

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
    ascii? = state.capabilities.ascii?
    policy = state.capabilities.ambiguous_width

    sections =
      for group <- Bindings.groups(),
          rows =
            context
            |> Bindings.for_context()
            |> Enum.filter(&(&1.group == group))
            |> Enum.map(fn binding ->
              keys = binding |> Bindings.keys_in_context(context) |> KeyLabel.joined(ascii?)
              {keys, binding.help}
            end),
          rows != [],
          do: {group, rows}

    columns = if inner >= @help_two_column_width, do: 2, else: 1
    column = div(inner - (columns - 1) * @help_gutter, columns)

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
        heading = String.upcase(SwarmCodeCLI.UI.Keymap.Docs.group_title(group))

        entries =
          rows
          |> Enum.map(&help_entry(&1, key_width, column, state, policy))
          |> Enum.chunk_every(columns)
          |> Enum.map(&Enum.join(&1, String.duplicate(" ", @help_gutter)))

        [heading | entries]
      end)

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

  defp contents({kind, id}, state, rect, class) when kind in [:question, :approval] do
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

    options =
      Enum.map(entries, fn entry ->
        {entry.id, Density.safe(entry.label, state, rect.width * 4), entry.target}
      end)

    marks? = Enum.any?(entries, &Map.get(&1, :current?, false))

    decor =
      Map.new(entries, fn entry ->
        title = Map.get(entry, :title) || entry.label
        {right, right_role} = entry_right(entry, state)

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

    options = if options == [], do: [{"empty", SafeText.chrome(:no_results), nil}], else: options
    title = Density.safe("Search: " <> query, state, rect.width - 2)

    {title, options, [control("cancel", SafeText.chrome(:cancel), {:local, :close_top_layer})],
     if(state.focus == "query", do: "query", else: focus(state, options)), decor}
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

    agent <> " wants to " <> approval_verb(item.approval)
  end

  defp approval_verb(nil), do: "do something that needs your permission"
  defp approval_verb(%{tool: "run_command"}), do: "run a command"
  defp approval_verb(%{tool: tool}) when tool in ["edit_file", "write_file"], do: "change a file"
  defp approval_verb(%{tool: "delete_file"}), do: "delete a file"
  defp approval_verb(%{tool: tool, permission: :execute}), do: "run " <> tool_words(tool)
  defp approval_verb(%{tool: tool}), do: "use " <> tool_words(tool)

  defp tool_words(tool) when is_binary(tool), do: String.replace(tool, "_", " ")
  defp tool_words(_tool), do: "a tool"

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

  # One "keys  help" cell, padded to exactly `column` cells so two of them line
  # up. The help text is elided before the keys are.
  defp help_entry({keys, help}, key_width, column, state, policy) do
    key_cell = keys |> Width.elide(key_width, :end, policy) |> RunRow.pad(key_width, state)
    help_width = max(0, column - key_width - @help_gutter)

    help_cell =
      if help_width > 0,
        do: String.duplicate(" ", @help_gutter) <> Width.elide(help, help_width, :end, policy),
        else: ""

    RunRow.pad(key_cell <> help_cell, column, state)
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
