defmodule SwarmCodeCLI.UI.Projector.Interview do
  @moduledoc "pass75 interview: the ask_user note (frames QA1-QA3)."

  alias SwarmCodeCLI.UI.{Editor, FieldEditors, Layout, Question, SafeText, Size, Theme, Width}
  alias SwarmCodeCLI.UI.Keymap.Bindings
  alias SwarmCodeCLI.UI.Projector.{ApprovalCard, Density, KeyLabel, RunRow, Support}
  alias SwarmCodeCLI.UI.Projector.Panel.{Glyph, Model}
  alias SwarmCodeCLI.UI.Scene.{Block, Dialog, Rect, Span}

  @narrow_classes [:narrow, :small, :compressed_small]
  @joiner "   "
  @placeholder "Something else, in your own words…"

  @doc """
  The note for the ask of `node_id` as a `Scene.Dialog` (style `:note`), or
  nil when nothing of that ask is pending.
  """
  @spec dialog(map(), atom(), binary()) :: Dialog.t() | nil
  def dialog(state, class, node_id) do
    case Question.ask(state, node_id) do
      nil ->
        nil

      ask ->
        interview = Question.interview(state, node_id)
        first = hd(ask.rows)
        name = ApprovalCard.who(first, state)
        size = state.size
        main = Map.get(Layout.for_state(state).rects, :main) || full(size)
        text_width = max(rect(size, main, class, 1).width - 8, 1)
        all = rows(state, class, ask, interview, text_width)
        rect = rect(size, main, class, length(all))
        {visible, scroll} = fit(all, max(rect.height - 2, 0), focus_tag(state))
        total = length(all)
        narrow? = class in @narrow_classes
        {:ok, title} = SafeText.external(name <> " asks you", SafeText.Limits.content())

        # The focus region is "dialog", as every dialog's is (19.3: the
        # gallery's question cells carry `data-focus="dialog"`).
        %Dialog{
          id: "dialog",
          rect: rect,
          title: title,
          blocks: Enum.map(visible, &elem(&1, 1)),
          focused_control_id: focus_control(state, ask, interview),
          footer: [],
          body_scroll: min(scroll, total),
          body_visible_range: {min(scroll, total), min(scroll + length(visible), total)},
          body_total_count: total,
          style: :note,
          edges: edges(state, ask, name, name_role(first, state), state.now),
          air: not narrow?,
          backdrop: if(narrow?, do: :plain, else: :ghost)
        }
    end
  end

  defp full(size), do: %Rect{x: 0, y: 0, width: size.columns, height: size.rows}

  defp focus_tag(%{focus: "other"}), do: :other
  defp focus_tag(%{focus: focus}) when is_binary(focus), do: {:option, focus}
  defp focus_tag(_state), do: nil

  # The focused option of the current question or "other"; nil otherwise.
  defp focus_control(state, ask, interview) do
    if state.focus in Question.focus_ids(Question.current(ask, interview)),
      do: state.focus
  end

  # The Lead (or the assistant) speaks in its run's hue, a worker in its lane.
  defp name_role(row, state) do
    case ApprovalCard.name_role(row, state) do
      :text_primary -> state |> run_kind(row.run_id) |> Theme.run_kind() |> elem(1)
      lane -> lane
    end
  end

  defp run_kind(state, run_id) do
    case Map.get(state.read_model.runs, run_id) do
      nil -> :assistant
      run -> Model.kind(run)
    end
  end

  @doc """
  The four edge texts: `<mark> <Name> asks you [m questions]`, `<kind> · <run
  title> · asked m:ss ago`, `Esc later: …` and `^N reopens`.
  """
  @spec edges(map(), Question.ask(), binary(), atom(), integer()) :: map()
  def edges(state, ask, name, role, now_ms) do
    ctx = %{state: state}
    run = Map.get(state.read_model.runs, ask.run_id)
    mark = state |> run_kind(ask.run_id) |> Theme.run_mark() |> Support.glyph(state)
    count = if ask.total >= 2, do: [{" #{ask.total} questions", :text_primary}], else: []

    asked =
      case ask.requested_at do
        nil ->
          nil

        at ->
          seconds = max(div(now_ms - at, 1000), 0)
          ss = seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")
          "asked #{div(seconds, 60)}:#{ss} ago"
      end

    about =
      [run && Atom.to_string(run.kind), run && clean(run.title, ctx), asked]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" · ")

    {words, words_role} = Question.deadline_words(ask, now_ms, name)
    "Esc" <> later = words

    reopen =
      case key(state, :next_need_chord) do
        nil -> []
        label -> [{chord(label), {:text_primary, [:bold]}}, {" reopens", :text_faint}]
      end

    %{
      top_left:
        spans(ctx, [
          {SafeText.value(mark) <> " " <> name, {role, [:bold]}},
          {" asks you", :text_primary} | count
        ]),
      top_right: spans(ctx, [{about, :text_faint}]),
      bottom_left: spans(ctx, [{"Esc", {:text_primary, [:bold]}}, {later, words_role}]),
      bottom_right: spans(ctx, reopen)
    }
  end

  # `Ctrl-N` reads `^N` on the note's edge, as the panel writes it.
  defp chord("Ctrl-" <> <<letter::binary-size(1)>>), do: "^" <> letter
  defp chord(label), do: label

  @doc "The label of the first key bound to `id` under the user's overrides; nil when unbound."
  @spec key(map(), atom()) :: String.t() | nil
  def key(state, id) do
    case id |> Bindings.keys_for(SwarmCodeCLI.UI.Keymap.overrides(state)) |> List.first() do
      nil -> nil
      key -> KeyLabel.label(key, state.capabilities.ascii?)
    end
  end

  @doc """
  The note's rectangle: `min(86, columns - 16)` wide and as tall as its content
  (at most `rows - 4`), centred on the chat (`main`); the whole screen below 100
  columns.
  """
  @spec rect(Size.t(), Rect.t(), atom(), pos_integer()) :: Rect.t()
  def rect(%Size{} = size, _main, class, _content_rows) when class in @narrow_classes,
    do: %Rect{x: 0, y: 0, width: size.columns, height: size.rows}

  def rect(%Size{} = size, %Rect{} = main, _class, content_rows) do
    width = size.columns |> Kernel.-(16) |> min(86) |> max(1) |> min(size.columns)
    height = (content_rows + 2) |> min(size.rows - 4) |> max(3) |> min(size.rows)
    x = main.x + div(main.width - width, 2)
    y = main.y + div(main.height - height, 2)

    %Rect{
      x: x |> max(0) |> min(size.columns - width),
      y: y |> max(0) |> min(size.rows - height),
      width: width,
      height: height
    }
  end

  @doc """
  The rows that fit `max_rows`, and the scroll of the body. Nothing is dropped
  when the rows fit. Else the blank rows go first (bottom-most first), then the
  why row; a body still too tall scrolls the slice between the stepper and the
  keys row so the focused row stays in view.
  """
  @spec fit([{term(), term()}], non_neg_integer(), term()) ::
          {[{term(), term()}], non_neg_integer()}
  def fit(tagged_rows, max_rows, focused_tag) do
    if length(tagged_rows) <= max_rows do
      {tagged_rows, 0}
    else
      rows = drop_blanks(tagged_rows, length(tagged_rows) - max_rows)

      rows =
        if length(rows) > max_rows,
          do: Enum.reject(rows, &(elem(&1, 0) == :why)),
          else: rows

      if length(rows) <= max_rows, do: {rows, 0}, else: scroll(rows, max_rows, focused_tag)
    end
  end

  # Blank rows go bottom-most first, `count` of them at most.
  defp drop_blanks(rows, count) do
    {kept, _} =
      rows
      |> Enum.reverse()
      |> Enum.reduce({[], count}, fn
        {:blank, _}, {kept, left} when left > 0 -> {kept, left - 1}
        row, {kept, left} -> {[row | kept], left}
      end)

    kept
  end

  # The stepper (and what stands above it) and the keys row stay; the rows in
  # between scroll so the focused one is inside the window.
  defp scroll(rows, max_rows, focused_tag) do
    head_count =
      case Enum.find_index(rows, &(elem(&1, 0) == :stepper)) do
        nil -> 0
        index -> index + 1
      end

    {head, rest} = Enum.split(rows, head_count)
    {slice, tail} = Enum.split_with(rest, &(elem(&1, 0) != :keys))
    window = max(max_rows - length(head) - length(tail), 0)
    focused = Enum.find_index(slice, &(elem(&1, 0) == focused_tag)) || 0
    last = max(length(slice) - window, 0)
    offset = (focused - window + 1) |> max(0) |> min(last)
    visible = slice |> Enum.drop(offset) |> Enum.take(window)
    {Enum.take(head ++ visible ++ tail, max_rows), offset}
  end

  @doc """
  Why the agent asks: the last sentence of the asker's newest assistant text
  of the same run written before the ask's own op item, quoted by the caller,
  cut to `width - 2` cells; nil when the op item is not loaded or nothing
  precedes it.
  """
  @spec why(map(), map(), non_neg_integer()) :: SafeText.t() | nil
  def why(state, ask, width) do
    items = Map.values(state.read_model.transcript)

    with %{created_sequence: bound} <- Enum.find(items, &(&1.node_id == ask.node_id)),
         %{} = said <-
           items
           |> Enum.filter(
             &(&1.run_id == ask.run_id and &1.role == :assistant and &1.kind == :text and
                 &1.created_sequence < bound)
           )
           |> Enum.max_by(& &1.created_sequence, fn -> nil end),
         sentence when sentence != "" <- last_sentence(plain(said.text)) do
      Density.safe(sentence, state, max(width - 2, 0))
    else
      _ -> nil
    end
  end

  defp plain(%SafeText{} = text), do: SafeText.value(text)
  defp plain(text) when is_binary(text), do: text
  defp plain(_), do: ""

  defp last_sentence(text) do
    text
    |> String.trim()
    |> String.split(~r/(?<=[.!?])\s+/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> Kernel.||("")
  end

  # ------------------------------------------------------------------ rows

  @doc """
  The note's body as `{tag, block}` rows, in order. Every row starts with the
  2-cell rail slot and fills `text_width` cells after it: right-aligned words
  end exactly at the text column's end.
  """
  @spec rows(map(), atom(), Question.ask(), Question.interview(), pos_integer()) :: [
          {term(), term()}
        ]
  def rows(state, _class, ask, interview, text_width) do
    current = Question.current(ask, interview)
    ctx = %{state: state, tw: text_width, node: ask.node_id, current: current}

    why =
      case why(state, ask, text_width) do
        nil ->
          []

        sentence ->
          [
            {:why, rich(ctx, rail(ctx, false) ++ [{quoted(sentence), :text_muted}])},
            {:blank, blank()}
          ]
      end

    stepper =
      if ask.total >= 2,
        do: [{:stepper, stepper(ctx, ask, interview)}, {:blank, blank()}],
        else: []

    [{:blank, blank()}] ++
      why ++
      stepper ++
      prompt(ctx, current) ++
      [{:blank, blank()}] ++
      options(ctx, current) ++
      [{:blank, blank()}, {:other, other(ctx, current)}, {:blank, blank()}] ++
      ledger(ctx, ask) ++
      refused(ctx, ask, interview) ++
      [{:blank, blank()}, {:keys, keys(ctx, ask, interview)}]
  end

  defp quoted(sentence), do: "\"" <> SafeText.value(sentence) <> "\""

  # `✓ Format   ›   ● Fields   ›   ○ Delivery ... 2 of 3`: each glyph and
  # header is its own target (goto that question).
  defp stepper(ctx, ask, interview) do
    state = ctx.state
    ledger = Question.ledger(state, ask)
    positions = Map.new(Enum.with_index(ask.rows), fn {row, i} -> {row.question.index, i} end)
    count = length(ledger)
    joiner = @joiner <> Glyph.get(:next, state) <> @joiner
    step = min(interview.step, length(ask.rows) - 1)
    at = Enum.at(ask.rows, step).question.index + 1
    right = [{"#{at} of #{ask.total}", :text_faint}]
    glyphs = count * 2 + (count - 1) * cells(joiner, ctx)
    room = ctx.tw - width(right, ctx) - 1 - glyphs
    header_room = max(div(room, max(count, 1)), 1)

    pairs =
      ledger
      |> Enum.with_index()
      |> Enum.map(fn {{mark, header, _words}, i} ->
        {glyph, glyph_role} = mark(mark, state)

        header_role =
          case mark do
            :current -> {:text_primary, [:bold, :underlined]}
            :open -> :text_faint
            _ -> :text_muted
          end

        spans = [
          {glyph, glyph_role},
          {" ", :text_faint},
          {cut(header, header_room, ctx), header_role}
        ]

        {spans, Map.get(positions, i)}
      end)

    rail = rail(ctx, false)

    columns =
      pairs
      |> Enum.with_index()
      |> Enum.flat_map(fn {{spans, position}, i} ->
        spans = if i == 0, do: rail ++ spans, else: spans

        pair =
          if position == nil,
            do: rich(ctx, spans),
            else:
              Support.action_spans(
                spans(ctx, spans),
                {:local, {:interview, {:goto, ctx.node, position}}}
              )

        column = %{width: width(spans, ctx), blocks: [pair]}

        if i < count - 1,
          do: [column, %{width: cells(joiner, ctx), blocks: [rich(ctx, [{joiner, :text_faint}])]}],
          else: [column]
      end)

    used = Enum.reduce(columns, 0, &(&1.width + &2))
    total = ctx.tw + 2
    pad = max(total - used - width(right, ctx), 0)
    tail = [{String.duplicate(" ", pad), :text_faint} | right]

    %Block.Columns{
      columns: columns ++ [%{width: width(tail, ctx), blocks: [rich(ctx, tail)]}],
      gap: 0
    }
  end

  defp mark(:current, state), do: {Glyph.get(:dot_on, state), :accent}
  defp mark(:open, state), do: {Glyph.get(:dot_off, state), :text_faint}
  defp mark(_done_or_earlier, state), do: {Glyph.get(:done, state), :success}

  # The question in bold with `pick one`/`pick any` right-aligned; a long
  # question wraps, the words stay on its first row.
  defp prompt(ctx, row) do
    pick = if row.question.multiple, do: "pick any", else: "pick one"
    right = [{pick, :text_faint}]
    room = max(ctx.tw - width(right, ctx) - 2, 1)
    text = clean(row.question.prompt, ctx)

    case wrap_prose(text, room, ctx) do
      [] ->
        [{:prompt, rich(ctx, rail(ctx, false) ++ line([], right, ctx))}]

      [first | rest] ->
        [
          {:prompt,
           rich(ctx, rail(ctx, false) ++ line([{first, {:text_primary, [:bold]}}], right, ctx))}
        ] ++
          Enum.map(rest, fn more ->
            {:prompt,
             rich(ctx, rail(ctx, false) ++ line([{more, {:text_primary, [:bold]}}], [], ctx))}
          end)
    end
  end

  defp wrap_prose(text, width, ctx),
    do: SwarmCodeCLI.UI.Prose.wrap(text, width, ctx.state.capabilities.ambiguous_width)

  # Two rows per option: `<N>  <label>` (a multi-select `[✓]` before the
  # label) and its description under the label. The focused option carries
  # the accent rail on both rows.
  defp options(ctx, row) do
    state = ctx.state
    multiple = row.question.multiple
    ticked = Map.get(state.selection, {:question, row.id}, [])

    row.question.options
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {option, n} ->
      focused? = state.focus == option.id
      tick? = multiple and option.id in ticked
      number = Integer.to_string(n)

      number_role = if focused?, do: {:accent, [:bold]}, else: :text_faint

      box =
        cond do
          not multiple ->
            []

          tick? ->
            [
              {"[", :text_faint},
              {Glyph.get(:done, state), {:success, [:bold]}},
              {"] ", :text_faint}
            ]

          true ->
            [{"[ ] ", :text_faint}]
        end

      lead = [{number, number_role}, {"  ", :text_faint}] ++ box
      label_role = if focused? or tick?, do: {:text_primary, [:bold]}, else: :text_primary
      label_room = max(ctx.tw - width(lead, ctx), 1)
      label = {cut(clean(option.label, ctx), label_room, ctx), label_role}
      label = if focused?, do: focus_prefix(label, state), else: label
      option_spans = rail(ctx, focused?) ++ lead ++ [label]
      action = if multiple, do: :toggle, else: :pick

      option_row =
        {{:option, option.id},
         Support.action_spans(
           spans(ctx, option_spans),
           {:local, {:interview, {action, ctx.node, option.id}}}
         )}

      description = clean(Map.get(option, :description) || "", ctx)

      if description == "" do
        [option_row]
      else
        indent = width([{number, :text_faint}, {"  ", :text_faint}] ++ box, ctx)
        role = if focused?, do: :text_primary, else: :text_muted

        [
          option_row,
          {{:desc, option.id},
           rich(
             ctx,
             rail(ctx, focused?) ++
               [
                 {String.duplicate(" ", indent), :text_faint},
                 {cut(description, max(ctx.tw - indent, 1), ctx), role}
               ]
           )}
        ]
      end
    end)
  end

  # In monochrome the focus words mark the focused option once, on its row.
  defp focus_prefix({text, role}, %{capabilities: %{color_mode: :monochrome} = caps}),
    do: {text, role, Theme.style(:focus, caps).prefix}

  defp focus_prefix(label, _state), do: label

  # `›  Something else, in your own words…   Tab to type`, or, focused, the
  # text with the caret and `Tab back to the list`.
  defp other(ctx, row) do
    state = ctx.state
    focused? = state.focus == "other"

    editor =
      FieldEditors.fetch(state.field_editors, {:question_other, row.id, row.expected_revision})

    text = clean(Editor.text(editor), ctx)
    tab = key(state, :focus_next)
    next = Glyph.get(:next, state)

    right =
      cond do
        tab == nil -> []
        focused? -> [{tab, {:text_primary, [:bold]}}, {" back to the list", :text_faint}]
        true -> [{tab, {:text_primary, [:bold]}}, {" to type", :text_faint}]
      end

    room = max(ctx.tw - width(right, ctx) - 1 - cells(next <> "  ", ctx), 1)

    left =
      cond do
        focused? ->
          caret = SafeText.value(Support.glyph(:caret, state))
          {before, after_caret} = text |> String.graphemes() |> Enum.split(Editor.cursor(editor))

          [
            {next, {:accent, [:bold]}},
            {"  ", :text_faint},
            {tail_cut(Enum.join(before) <> caret, Enum.join(after_caret), room, ctx),
             :text_primary}
          ]

        text == "" ->
          [{cut(next <> "  " <> @placeholder, room + cells(next <> "  ", ctx), ctx), :text_faint}]

        true ->
          [{next, :text_faint}, {"  ", :text_faint}, {cut(text, room, ctx), :text_primary}]
      end

    Support.action_spans(
      spans(ctx, rail(ctx, focused?) ++ line(left, right, ctx)),
      {:local, {:interview, {:toggle_other, ctx.node}}}
    )
  end

  # The text up to the caret stays in view: a long draft loses its start.
  defp tail_cut(before, after_caret, room, ctx) do
    whole = before <> after_caret

    if cells(whole, ctx) <= room do
      whole
    else
      ellipsis = "…"
      visible = cut(before <> after_caret, room, ctx)

      if String.starts_with?(visible, before),
        do: visible,
        else: ellipsis <> keep_end(before, room - cells(ellipsis, ctx), ctx)
    end
  end

  defp keep_end(text, room, ctx) do
    text
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn g, {kept, used} ->
      w = cells(g, ctx)
      if used + w > room, do: {:halt, {kept, used}}, else: {:cont, {[g | kept], used + w}}
    end)
    |> elem(0)
    |> Enum.join()
  end

  # `You will send` and one row per asked question; a one-question ask says
  # it on one row.
  defp ledger(ctx, ask) do
    state = ctx.state
    entries = Question.ledger(state, ask)

    if ask.total >= 2 do
      widest = entries |> Enum.map(fn {_, header, _} -> cells(header, ctx) end) |> Enum.max()

      [{:ledger_title, rich(ctx, rail(ctx, false) ++ [{"You will send", :text_muted}])}] ++
        (entries
         |> Enum.with_index()
         |> Enum.map(fn {{mark, header, words}, i} ->
           {glyph, glyph_role} = mark(mark, state)
           padded = header <> String.duplicate(" ", widest + 2 - cells(header, ctx))
           lead = [{glyph, glyph_role}, {" ", :text_faint}, {padded, :text_muted}]
           room = max(ctx.tw - width(lead, ctx), 1)

           {{:ledger, i},
            rich(
              ctx,
              rail(ctx, false) ++ lead ++ [{cut(clean(words, ctx), room, ctx), words_role(words)}]
            )}
         end))
    else
      [{_, _, words}] = entries
      lead = [{"You will send", :text_muted}, {"  ", :text_faint}]
      room = max(ctx.tw - width(lead, ctx), 1)

      role =
        if words_role(words) == :text_faint, do: :text_faint, else: {:text_primary, [:bold]}

      [
        {:ledger,
         rich(ctx, rail(ctx, false) ++ lead ++ [{cut(clean(words, ctx), room, ctx), role}])}
      ]
    end
  end

  defp words_role(words) when words in ["not answered yet", "answered earlier"], do: :text_faint
  defp words_role(_words), do: :text_primary

  # A refused answer says why under the ledger; the row stays answerable.
  defp refused(ctx, ask, interview) do
    for row <- ask.rows, text = Map.get(interview.refused, row.id), text != nil do
      words = Question.header(row) <> ": " <> text
      {:refused, rich(ctx, rail(ctx, false) ++ [{cut(clean(words, ctx), ctx.tw, ctx), :warning}])}
    end
  end

  # `1-4 pick   ↑↓ move   ←→ question        Enter send to the Lead`; the
  # Enter words are the confirm target.
  defp keys(ctx, ask, interview) do
    state = ctx.state
    row = ctx.current
    n = length(row.question.options)
    multiple = row.question.multiple

    digits =
      case key(state, :question_option) do
        nil -> nil
        "1" when n >= 2 -> "1-" <> Integer.to_string(n)
        label -> label
      end

    groups =
      [
        {digits, if(multiple, do: " tick", else: " pick")},
        {if(multiple, do: key(state, :select_option)), " tick"},
        {pair(arrow_key(state, :dialog_previous), arrow_key(state, :dialog_next)), " move"},
        {if(length(ask.rows) >= 2,
           do: pair(key(state, :dialog_left), key(state, :dialog_right))
         ), " question"}
      ]
      |> Enum.reject(&(elem(&1, 0) == nil))
      |> Enum.map(fn {k, words} -> [{k, {:text_primary, [:bold]}}, {words, :text_faint}] end)

    name = ApprovalCard.who(hd(ask.rows), state)
    enter_words = Question.enter_words(ask, interview, name)

    enter =
      case key(state, :activate) do
        nil -> []
        label -> [{label, {:accent, [:bold]}}, {" ", :text_faint}, {enter_words, :text_muted}]
      end

    enter_width = width(enter, ctx)
    left_room = max(ctx.tw - enter_width - 1, 0)
    left = fit_groups(groups, left_room, ctx)
    left_spans = rail(ctx, false) ++ left
    left_width = ctx.tw + 2 - enter_width
    pad = max(left_width - width(left_spans, ctx), 0)
    left_spans = left_spans ++ [{String.duplicate(" ", pad), :text_faint}]

    if enter == [] do
      rich(ctx, left_spans)
    else
      %Block.Columns{
        columns: [
          %{width: left_width, blocks: [rich(ctx, left_spans)]},
          %{
            width: enter_width,
            blocks: [
              Support.action_spans(
                spans(ctx, enter),
                {:local, {:interview, {:confirm, ctx.node}}}
              )
            ]
          }
        ],
        gap: 0
      }
    end
  end

  # Groups joined by three spaces, as many as fit.
  defp fit_groups(groups, room, ctx) do
    groups
    |> Enum.reduce_while({[], 0}, fn group, {kept, used} ->
      joiner = if kept == [], do: [], else: [{@joiner, :text_faint}]
      w = width(joiner ++ group, ctx)

      if used + w <= room,
        do: {:cont, {kept ++ joiner ++ group, used + w}},
        else: {:halt, {kept, used}}
    end)
    |> elem(0)
  end

  defp pair(nil, _), do: nil
  defp pair(_, nil), do: nil

  defp pair(a, b) do
    if String.length(a) == 1 and String.length(b) == 1, do: a <> b, else: a <> "/" <> b
  end

  # The arrow a binding names, when it has one (`↑` over `k`).
  defp arrow_key(state, id) do
    keys = Bindings.keys_for(id, SwarmCodeCLI.UI.Keymap.overrides(state))

    case Enum.find(keys, fn {code, mods} -> code in [:up, :down, :left, :right] and mods == [] end) ||
           List.first(keys) do
      nil -> nil
      key -> KeyLabel.label(key, state.capabilities.ascii?)
    end
  end

  # --------------------------------------------------------------- helpers

  defp rail(ctx, true),
    do: [{Glyph.get(:in_chat, ctx.state), :accent}, {" ", :text_faint}]

  defp rail(_ctx, false), do: [{"  ", :text_faint}]

  # `left` then padding then `right`, `right` ending at the text column's end;
  # a left side too long for the room is cut.
  defp line(left, right, ctx) do
    right_width = width(right, ctx)
    room = if right_width > 0, do: ctx.tw - right_width - 1, else: ctx.tw
    left = cut_parts(left, max(room, 0), ctx)
    pad = max(ctx.tw - width(left, ctx) - right_width, 0)
    left ++ [{String.duplicate(" ", pad), :text_faint}] ++ right
  end

  defp cut_parts(parts, room, ctx) do
    parts
    |> Enum.reduce_while({[], 0}, fn part, {kept, used} ->
      text = elem(part, 0)
      w = cells(text, ctx)

      if used + w <= room,
        do: {:cont, {kept ++ [part], used + w}},
        else: {:halt, {kept ++ [put_elem(part, 0, cut(text, room - used, ctx))], room}}
    end)
    |> elem(0)
  end

  defp blank do
    {:ok, space} = SafeText.external(" ", SafeText.Limits.content())
    %Block.Text{text: space}
  end

  defp rich(ctx, parts), do: %Block.RichText{spans: spans(ctx, parts)}

  defp spans(ctx, parts) do
    for part <- parts, elem(part, 0) != "" do
      {text, role, prefix} =
        case part do
          {text, role} -> {text, role, nil}
          {text, role, prefix} -> {text, role, prefix}
        end

      %Span{
        text: Density.safe(text, ctx.state, cells(text, ctx)),
        style: %{style(role, ctx.state) | prefix: prefix}
      }
    end
  end

  # A role's colour without its monochrome cue word (`RunRow.tinted/2`), as
  # the approval card draws it.
  defp style({role, modifiers}, state),
    do: %{RunRow.tinted(role, state) | background: nil, modifiers: modifiers}

  defp style(role, state), do: style({role, []}, state)

  defp width(parts, ctx), do: Enum.reduce(parts, 0, &(cells(elem(&1, 0), ctx) + &2))

  defp cells(text, ctx), do: Width.cells(text, ctx.state.capabilities.ambiguous_width)

  defp clean(text, ctx) when is_binary(text),
    do: text |> Density.safe(ctx.state, max(cells(text, ctx), 1)) |> SafeText.value()

  defp clean(_text, _ctx), do: ""

  defp cut(text, room, ctx),
    do: Width.elide(text, max(room, 0), :end, ctx.state.capabilities.ambiguous_width)
end
