defmodule SwarmCodeCLI.UI.Projector.Workspace.Turns do
  @moduledoc """
  The rows of the main transcript.

  A transcript item becomes a short list of rows that already fit the transcript
  width: a speaker line (`you · 14:58`, `lead · planning ▮`), its prose, a tool
  one-liner (`▸ scout-1  grep "Repo\\."  41 hits  0.4s ✓`) with an optional
  five-line preview, a dim thinking line, or an error. The same rows give an item
  its height, so the anchors `ScrollMetrics` computes and the rows the painter
  draws can never disagree.

  Rhythm: text starts two cells into the rect, one blank row separates turns and
  none sits inside one, and tool one-liners sit two further cells in under their
  agent's line. Consecutive tool and thinking items form one burst, so a fan-out
  of five tool calls reads as a block rather than five turns.
  """
  alias SwarmCodeCLI.UI.{Prose, ReadModel, SafeText, Theme, Width}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Paint.{Markdown, Options, Text}
  alias SwarmCodeCLI.UI.Paint.Style, as: PaintStyle
  alias SwarmCodeCLI.UI.Scene.{Block, Color, Span, Style}
  alias SwarmCodeCLI.UI.Projector.{Density, RunRow, Support}

  @margin 2
  @tool_indent 2
  @preview 5
  @summary_cells 40
  @lanes [:agent_lane_1, :agent_lane_2, :agent_lane_3, :agent_lane_4, :agent_lane_5]
  @base %{foreground: nil, background: nil, modifiers: []}

  @doc "Cells before the first text cell of a transcript row."
  def margin, do: @margin

  @doc "The run's item just before `id` in the workspace order, or nil at the top."
  def previous(state, run_id, id) do
    transcript = state.read_model.transcript

    state
    |> order()
    |> Enum.take_while(&(&1 != id))
    |> Enum.reverse()
    |> Enum.find_value(fn candidate ->
      case Map.get(transcript, candidate) do
        %{run_id: ^run_id} = item -> item
        _ -> nil
      end
    end)
  end

  @doc "Rows of `item` for a `width`-cell transcript; `previous` decides the blank row."
  def rows(item, previous, run, state, width) do
    width = max(1, min(width, 500))
    separator = if turn_start?(item, previous), do: [blank(state)], else: []
    separator ++ item_rows(item, run, state, width)
  end

  @doc "The height `ScrollMetrics` reports for item `id`: exactly the rows painted."
  def height(state, width, id) do
    case ReadModel.transcript_item(state.read_model, id) do
      nil ->
        1

      item ->
        run = Map.get(state.read_model.runs, item.run_id)

        item
        |> rows(previous(state, item.run_id, id), run, state, width)
        |> length()
        |> max(1)
    end
  end

  @doc "The visible slice of `rows` as one block, and how many rows it holds."
  def window(rows, offset, limit, follow?, state) do
    visible =
      cond do
        limit <= 0 -> []
        follow? -> Enum.take(rows, -limit)
        true -> rows |> Enum.drop(max(0, offset)) |> Enum.take(limit)
      end

    # Prose rows stay as laid-out units until they are actually shown: escaping
    # every row of a long streaming reply on every frame is what would make the
    # transcript slow, and only the visible slice needs spans.
    spans =
      visible
      |> Enum.intersperse(:newline)
      |> Enum.flat_map(fn
        :newline -> [%Span{text: safe("\n", state)}]
        {:prose, row} -> row_spans(row, state)
        row -> row
      end)

    {if(spans == [], do: nil, else: %Block.RichText{spans: spans}), length(visible)}
  end

  @doc "Local wall-clock `HH:MM` of a unix-millisecond stamp."
  def clock(ms) when is_integer(ms) do
    {{_, _, _}, {hour, minute, _}} = :calendar.system_time_to_local_time(ms, :millisecond)
    pad2(hour) <> ":" <> pad2(minute)
  end

  @doc ~S|"20ms", "0.4s", "12s", "1m 02s" or "1h 02m".|
  def duration_text(ms) when is_integer(ms) and ms < 100, do: "#{ms}ms"

  def duration_text(ms) when is_integer(ms) and ms < 10_000,
    do: :erlang.float_to_binary(ms / 1000, decimals: 1) <> "s"

  def duration_text(ms) when is_integer(ms) and ms < 60_000, do: "#{div(ms, 1000)}s"

  def duration_text(ms) when is_integer(ms) and ms < 3_600_000,
    do: "#{div(ms, 60_000)}m #{pad2(rem(div(ms, 1000), 60))}s"

  def duration_text(ms) when is_integer(ms),
    do: "#{div(ms, 3_600_000)}h #{pad2(rem(div(ms, 60_000), 60))}m"

  # --- turns -----------------------------------------------------------------

  @doc """
  The workspace's items in reading order. The daemon orders by creation, and
  a chat turn creates its answer before the tool calls that produce it; read
  that way the reply sits above the work. Here each run reads as a turn: the
  prompt, then the agents and their calls as they happened, then what was
  said. Runs keep the order they were created in.
  """
  def order(state) do
    ids =
      case Map.get(state.read_model.order, :workspace, []) do
        [] -> state.read_model.transcript |> Map.keys() |> Enum.sort()
        ids -> ids
      end

    transcript = state.read_model.transcript

    first_index_by_run =
      ids
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {id, index}, acc ->
        case Map.get(transcript, id) do
          %{run_id: run_id} -> Map.put_new(acc, run_id, index)
          _ -> acc
        end
      end)

    ids
    |> Enum.with_index()
    |> Enum.sort_by(fn {id, index} ->
      case Map.get(transcript, id) do
        %{run_id: run_id} = item ->
          {Map.get(first_index_by_run, run_id, index), rank(item), index}

        _ ->
          {index, 0, index}
      end
    end)
    |> Enum.map(&elem(&1, 0))
  end

  @doc "Within a run: the prompt (0), then the work (1: agents, tool calls, thinking), then the words (2)."
  def rank(%{role: :user}), do: 0
  def rank(%{kind: kind}) when kind in [:tool, :thinking], do: 1
  def rank(%{id: id, node_id: id}), do: 1
  def rank(_), do: 2

  defp turn_start?(_item, nil), do: false
  defp turn_start?(item, previous), do: not (burst?(item) and burst?(previous))
  defp burst?(%{kind: kind}), do: kind in [:tool, :thinking]

  defp item_rows(%{kind: :tool} = item, run, state, width), do: tool_rows(item, run, state, width)

  defp item_rows(%{kind: :thinking} = item, run, state, width),
    do: thinking_rows(item, run, state, width)

  defp item_rows(%{kind: :error} = item, run, state, width),
    do: error_rows(item, run, state, width)

  defp item_rows(item, run, state, width), do: text_rows(item, run, state, width)

  # `you · 14:58` or `lead · planning ▮`, then the prose two cells in.
  defp text_rows(item, run, state, width) do
    {name, style} = speaker(item, run, state)
    body_role = if item.state == :superseded, do: :text_muted, else: :text_primary
    inner = max(1, width - @margin)

    line = speaker_line(name, style, meta(item, state), live?(item), state, width)
    body = prose_rows(item.text, body_role, item.role == :assistant, state, inner)
    [line | body]
  end

  defp speaker_line(name, style, meta, live?, state, width) do
    spans =
      [gap(@margin, state), span(name, bold(style), state)] ++
        if(meta, do: [span(" · " <> meta, tint(:text_faint, state), state)], else: []) ++
        if(live?, do: [span(" " <> glyph(:caret, state), tint(:accent, state), state)], else: [])

    fit(spans, width, state)
  end

  # The agent's current step while it streams, otherwise the local time.
  defp meta(item, state) do
    agent = agent(item, state)

    cond do
      live?(item) and agent != nil and agent.step != "" -> agent.step
      item.state == :superseded -> "superseded"
      is_integer(item.at) and item.at > 0 -> clock(item.at)
      true -> nil
    end
  end

  defp live?(%{state: state}), do: state in [:streaming, :running]

  # `▸ scout-1  grep "Repo\."  41 hits  0.4s ✓`; expanded, the first five lines
  # of the result follow and `… N more  (Enter opens)` counts the rest.
  defp tool_rows(item, run, state, width) do
    tool = item.tool || %DTO.ToolCall{}
    expanded? = MapSet.member?(state.expansions, item.id)
    {name, style} = speaker(item, run, state)
    marker = if expanded?, do: :expanded, else: :collapsed
    title = first_line(tool.title) || first_line(tool.name) || "tool"
    summary = summary_line(tool) || bytes(tool.result_bytes)
    status = if item.tool, do: tool.status, else: item.state
    {mark, mark_style} = status_mark(status, state)
    duration = tool_duration(tool, state)

    head = [
      gap(@margin + @tool_indent, state),
      span(glyph(marker, state), tint(:text_faint, state), state),
      gap(1, state),
      span(name, bold(style), state),
      gap(2, state),
      span(title, tint(:text_primary, state), state)
    ]

    tail =
      if(duration, do: [gap(2, state), span(duration, tint(:text_faint, state), state)], else: []) ++
        if(mark, do: [gap(1, state), span(mark, mark_style, state)], else: [])

    line = one_liner(head, summary, tail, state, width)
    body = if expanded?, do: preview(item.text, :text_primary, state, width), else: []
    [line | body]
  end

  # A backend's detail often repeats the path the title already names
  # ("lib/x.ex (1196 lines) defmodule…" under "read lib/x.ex"); the row says
  # the path once and keeps what the detail adds.
  defp summary_line(tool) do
    detail = first_line(tool.detail)

    case {detail, tool.files} do
      {text, [path | _]} when is_binary(text) and is_binary(path) and path != "" ->
        if String.starts_with?(text, path) do
          text
          |> String.replace_prefix(path, "")
          |> String.replace(~r/^\s*\((.*?)\)\s*/, "\\1 · ")
          |> String.trim()
          |> String.trim_trailing("·")
          |> String.trim()
          |> case do
            "" -> nil
            rest -> rest
          end
        else
          text
        end

      _ ->
        detail
    end
  end

  # The summary is the part that gives way: it takes what is left after the
  # name, title, duration and status, up to 40 cells, and disappears under four.
  defp one_liner(head, summary, tail, state, width) do
    policy = state.capabilities.ambiguous_width
    avail = width - cells(head, policy) - cells(tail, policy) - 2

    middle =
      if summary && avail >= 4,
        do: [
          gap(2, state),
          span(
            Density.safe(summary, state, min(@summary_cells, avail)),
            tint(:text_muted, state),
            state
          )
        ],
        else: []

    fit(head ++ middle ++ tail, width, state)
  end

  # `▸ lead  thinking · 12s`, dim; expanded, the first five lines of the thought.
  defp thinking_rows(item, _run, state, width) do
    expanded? = MapSet.member?(state.expansions, item.id)
    marker = if expanded?, do: :expanded, else: :collapsed
    duration = item.tool && tool_duration(item.tool, state)
    label = if duration, do: "thinking · " <> duration, else: "thinking"
    faint = tint(:text_faint, state)

    name =
      case agent(item, state) do
        %{name: name} when name != "" -> name
        _ -> nil
      end

    spans =
      [
        gap(@margin + @tool_indent, state),
        span(glyph(marker, state), faint, state),
        gap(1, state)
      ] ++
        if(name, do: [span(name, bold(faint), state), gap(2, state)], else: []) ++
        [span(label, faint, state)]

    thought = if item.text == "", do: item.reasoning, else: item.text
    body = if expanded?, do: preview(thought, :text_muted, state, width), else: []
    [fit(spans, width, state) | body]
  end

  # `✕ builder-4 · 14:57` and the message, all in the error role.
  defp error_rows(item, _run, state, width) do
    error = tint(:error, state)
    policy = state.capabilities.ambiguous_width
    inner = max(1, width - @margin)

    name =
      case agent(item, state) do
        %{name: name} when name != "" -> name
        _ -> "error"
      end

    time = if is_integer(item.at) and item.at > 0, do: clock(item.at)

    line =
      fit(
        [gap(@margin, state), span(glyph(:fail, state) <> " " <> name, bold(error), state)] ++
          if(time, do: [span(" · " <> time, tint(:text_faint, state), state)], else: []),
        width,
        state
      )

    body =
      item.text
      |> admitted(state)
      |> Prose.wrap(inner, policy)
      |> Enum.map(&fit([gap(@margin, state), span(&1, error, state)], width, state))

    [line | body]
  end

  # The first `@preview` source lines, each clipped to one row, then the count.
  defp preview(text, role, state, width) do
    indent = @margin + @tool_indent + 2
    inner = max(1, width - indent)

    lines =
      case text |> admitted(state) |> String.trim_trailing("\n") do
        "" -> []
        body -> String.split(body, ["\r\n", "\n", "\r"])
      end

    shown = Enum.take(lines, @preview)
    more = length(lines) - length(shown)

    rows =
      for line <- shown,
          do:
            fit(
              [
                gap(indent, state),
                span(Density.safe(line, state, inner), tint(role, state), state)
              ],
              width,
              state
            )

    if more > 0 do
      rows ++
        [
          fit(
            [
              gap(indent, state),
              span(
                "#{ellipsis(state)} #{more} more  (Enter opens)",
                tint(:text_faint, state),
                state
              )
            ],
            width,
            state
          )
        ]
    else
      rows
    end
  end

  # --- speakers --------------------------------------------------------------

  defp speaker(%{role: :user}, _run, state), do: {"you", tint(:text_primary, state)}

  defp speaker(item, run, state) do
    case agent(item, state) do
      %{name: name} = agent when name != "" -> {name, tint(lane(agent, run, state), state)}
      _ -> {role_word(item.role, run), tint(role_tint(item.role), state)}
    end
  end

  # A consensus docket or a research report is spoken by what it is, not by "tool".
  defp role_word(:tool, %{kind: :consensus}), do: "Consensus"
  defp role_word(:tool, %{kind: :research}), do: SafeText.value(SafeText.chrome(:research_report))
  defp role_word(role, _run), do: role_word(role)

  defp agent(%{agent_id: id}, state) when is_binary(id), do: Map.get(state.read_model.agents, id)
  defp agent(_, _), do: nil

  defp role_word(:assistant), do: "assistant"
  defp role_word(:tool), do: "tool"
  defp role_word(:system), do: "system"
  defp role_word(_), do: "you"

  defp role_tint(:assistant), do: :accent
  defp role_tint(:tool), do: :text_muted
  defp role_tint(:system), do: :text_faint
  defp role_tint(_), do: :text_primary

  # Lead accent, judge info, workers by lane on the theme's five-hue ring.
  defp lane(%{role: :lead}, _run, _state), do: :accent
  defp lane(%{role: :judge}, _run, _state), do: :info

  defp lane(agent, run, state) do
    run_id = if run, do: run.id, else: agent.run_id

    workers =
      state.read_model.agents
      |> Map.values()
      |> Enum.filter(&(&1.run_id == run_id and &1.role not in [:lead, :judge]))
      |> Enum.sort_by(&{&1.started_at || 0, &1.id})

    index = Enum.find_index(workers, &(&1.id == agent.id)) || 0
    Enum.at(@lanes, rem(index, length(@lanes)))
  end

  # --- tool facts ------------------------------------------------------------

  defp status_mark(:done, state), do: {glyph(:check, state), tint(:success, state)}

  defp status_mark(status, state) when status in [:failed, :stopped, :interrupted],
    do: {glyph(:fail, state), tint(:error, state)}

  defp status_mark(status, state) when status in [:waiting_question, :waiting_approval],
    do: {glyph(:waiting, state), tint(:warning, state)}

  defp status_mark(status, state)
       when status in [:running, :streaming, :queued, :retrying, :paused],
       do: {glyph(:caret, state), tint(:accent, state)}

  defp status_mark(_, _), do: {nil, nil}

  # A zero is what a backend sends when it has no timing, and "0.0s" would
  # read as a measurement; only a real span is shown.
  defp tool_duration(%{duration_ms: ms}, _state) when is_integer(ms) and ms > 0,
    do: duration_text(ms)

  # A running tool with no duration yet counts from its start on the state clock.
  defp tool_duration(%{started_at: started, finished_at: nil, status: status}, %{now: now})
       when is_integer(started) and started > 0 and status in [:running, :streaming] and
              is_integer(now) and now > started,
       do: duration_text(now - started)

  defp tool_duration(_, _), do: nil

  defp first_line(nil), do: nil

  defp first_line(text) when is_binary(text) do
    case text |> String.split(["\r\n", "\n", "\r"], parts: 2) |> hd() |> String.trim() do
      "" -> nil
      line -> line
    end
  end

  defp bytes(n) when is_integer(n) and n <= 0, do: nil
  defp bytes(n) when is_integer(n) and n < 1_000, do: "#{n} B"

  defp bytes(n) when is_integer(n) and n < 1_000_000,
    do: :erlang.float_to_binary(n / 1_000, decimals: 1) <> " kB"

  defp bytes(n) when is_integer(n),
    do: :erlang.float_to_binary(n / 1_000_000, decimals: 1) <> " MB"

  defp bytes(_), do: nil

  # --- prose -----------------------------------------------------------------

  defp prose_rows("", _role, _markdown?, _state, _inner), do: []

  defp prose_rows(text, role, markdown?, state, inner) do
    caps = state.capabilities
    options = %Options{color_mode: caps.color_mode, ascii?: caps.ascii?}
    {:ok, base} = PaintStyle.resolve(%Style{role: role}, @base, options.color_mode)
    policy = caps.ambiguous_width
    text = admitted(text, state)

    lines =
      if markdown?,
        do: Markdown.parsed_lines(text, options, base, inner, policy),
        else: plain_lines(text, base)

    lines
    |> Stream.flat_map(&layout(&1, inner, policy))
    |> Enum.map(&{:prose, &1})
  end

  defp plain(text, style),
    do: %{runs: [%{text: text, style: style, action_id: nil}], code?: false}

  defp plain_lines(text, style) do
    Stream.unfold(text, fn
      nil ->
        nil

      remaining ->
        case :binary.match(remaining, "\n") do
          :nomatch ->
            {plain(remaining, style), nil}

          {at, 1} ->
            {plain(binary_part(remaining, 0, at), style),
             binary_part(remaining, at + 1, byte_size(remaining) - at - 1)}
        end
    end)
  end

  defp layout(%{runs: runs, code?: code?}, width, policy) do
    text = Enum.map_join(runs, & &1.text)
    lines = if code?, do: Width.wrap(text, width, policy), else: Prose.wrap(text, width, policy)
    lines = if lines == [], do: [""], else: lines

    Stream.transform(lines, runs, fn line, remaining ->
      {selected, rest} = take_runs(remaining, byte_size(line), [])
      {:ok, rows} = Text.lines(selected, width, policy, 200)
      {if(rows == [], do: [%{units: [], cells: 0}], else: rows), rest}
    end)
  end

  defp take_runs(runs, 0, acc), do: {Enum.reverse(acc), runs}

  defp take_runs([run | rest], bytes, acc) do
    count = min(byte_size(run.text), bytes)
    selected = %{run | text: binary_part(run.text, 0, count)}
    remaining = binary_part(run.text, count, byte_size(run.text) - count)
    tail = if remaining == "", do: rest, else: [%{run | text: remaining} | rest]
    take_runs(tail, bytes - count, [selected | acc])
  end

  defp row_spans(%{units: []}, state), do: [gap(@margin, state)]

  defp row_spans(%{units: units}, state) do
    spans =
      units
      |> Enum.chunk_by(& &1.style)
      |> Enum.map(fn group ->
        style = hd(group).style

        %Span{
          text: safe(Enum.map_join(group, & &1.text), state),
          style: %Style{
            role: :plain,
            foreground: color(style.foreground),
            background: color(style.background),
            modifiers: style.modifiers
          }
        }
      end)

    [gap(@margin, state) | spans]
  end

  defp color(nil), do: nil
  defp color(value), do: %Color{role: :default, value: value}

  # --- spans -----------------------------------------------------------------

  # Clips a row to `width` cells from the right so nothing can exceed the rect.
  defp fit(spans, width, state) do
    policy = state.capabilities.ambiguous_width

    {kept, _used} =
      Enum.reduce_while(spans, {[], 0}, fn span, {acc, used} ->
        text = SafeText.value(span.text)
        cells = Width.cells(text, policy)

        cond do
          used + cells <= width ->
            {:cont, {[span | acc], used + cells}}

          used >= width ->
            {:halt, {acc, used}}

          true ->
            {taken, _rest, taken_cells} = Width.take_cells(text, width - used, policy)
            {:halt, {[%{span | text: safe(taken, state)} | acc], used + taken_cells}}
        end
      end)

    Enum.reverse(kept)
  end

  defp cells(spans, policy),
    do: Enum.reduce(spans, 0, &(Width.cells(SafeText.value(&1.text), policy) + &2))

  defp blank(state), do: [gap(1, state)]

  defp gap(n, state) when n > 0,
    do: %Span{
      text: safe(String.duplicate(" ", n), state),
      style: Theme.style(:plain, state.capabilities)
    }

  defp span(%SafeText{} = text, style, _state), do: %Span{text: text, style: style}
  defp span(text, style, state), do: %Span{text: safe(text, state), style: style}

  defp tint(role, state), do: RunRow.tinted(role, state)
  defp bold(style), do: %{style | modifiers: Enum.uniq([:bold | style.modifiers])}
  defp glyph(token, state), do: SafeText.value(Support.glyph(token, state))

  defp ellipsis(%{capabilities: %{ascii?: true}}), do: "..."
  defp ellipsis(_), do: "…"

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp limits(state),
    do: %{SafeText.Limits.content() | ambiguous_width: state.capabilities.ambiguous_width}

  # Bounded, escaped source text; over the budget it reads as the limit notice.
  defp admitted(text, state) when is_binary(text),
    do: text |> Density.external(limits(state)) |> SafeText.value()

  defp admitted(_, _), do: ""

  # Re-escape complete clusters in source-sized chunks, then concatenate under
  # SafeText's larger escaped-output budget, exactly as Transcript did.
  defp safe(text, state) do
    limits = limits(state)

    text
    |> String.graphemes()
    |> Enum.chunk_while(
      {[], 0},
      fn grapheme, {parts, bytes} ->
        if bytes + byte_size(grapheme) > limits.input_bytes do
          {:cont, parts |> Enum.reverse() |> Enum.join(), {[grapheme], byte_size(grapheme)}}
        else
          {:cont, {[grapheme | parts], bytes + byte_size(grapheme)}}
        end
      end,
      fn {parts, _} -> {:cont, parts |> Enum.reverse() |> Enum.join(), {[], 0}} end
    )
    |> Enum.map(fn chunk ->
      {:ok, safe} = SafeText.external(chunk, limits)
      safe
    end)
    |> SafeText.concat()
  end
end
