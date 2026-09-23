defmodule SwarmCodeCLI.UI.Projector.Workspace.Turns do
  @moduledoc """
  The rows of the main transcript: a conversation, not a log.

  The persisted daemon creates a turn's answer before the model steps and tool
  calls that produce it, and every model step is a `:thinking` item whose
  text is what that step said. Read in that order the reply sat above the
  work and every other row said "thinking". Here a run reads as it happened:

      ▐ Read mix.exs and list the files under lib/…             (the prompt, on a card)

      ✳ assistant  deepseek-v4.1-flash                17s · 19k tok
        I'll read the requested files first.            (what step 1 said)
        ✓ read   mix.exs                         94 lines     6ms
        ✓ list   lib                  ailogic/ ailogic_web/…   14ms

        ## Dependencies …                               (the rest of the answer)

  * The prompt is a card with an accent rail.
  * The lead's turn has one header row: its mark and name, the model, and on
    the right what it is doing now (`writing ▮`, `thinking ▮`, `running grep ▮`)
    or, once finished, how long it took and what it spent.
  * A model step shows the words it said, when those words are the start of the
    answer; otherwise it takes no row (its time is in the header) until it is
    selected or expanded.
  * Tool calls are one row each, no speaker: status mark, verb, target, and on
    the right the summary and duration. Edits show `+3 −1`.
  * The answer is the message minus what the steps already said, after the
    last item of the run, in markdown (lists, tables, code on a card).
  * A worker's items collapse into one lane line (`✦ worker-a ✓ 16s · 2 tools
    "…"`) that expands in place; agents with no item yet get a queued line.
  * A failed run ends in an error card with what to do next.

  Every row belongs to exactly one item, so the height `ScrollMetrics` reports
  for an item is exactly the rows painted for it. Rows are specs (styled
  segments plus an optional fill) until they are visible; only the visible
  window becomes spans.
  """
  alias SwarmCodeCLI.UI.{ReadModel, SafeText, Theme, Width}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  alias SwarmCodeCLI.UI.Projector.{Density, Markdown, RunRow, Support}

  @margin 2
  @body 4
  # pass71 F2: an expanded row shows this many lines of what it has (5 hid most
  # of a 2 KB output behind a count that nothing opened).
  @preview 20
  @verb_cells 6
  @summary_cells 36
  @lanes [:agent_lane_1, :agent_lane_2, :agent_lane_3, :agent_lane_4, :agent_lane_5]
  @worker_roles [:worker, :sub, :judge]
  @live [:queued, :running, :streaming, :retrying, :waiting_question, :waiting_approval, :paused]

  @doc "Cells before the first cell of a transcript row's mark (the selection rail sits in them)."
  def margin, do: @margin

  @doc "The column prose and tool rows start at."
  def body_column, do: @body

  # --- order and view ---------------------------------------------------------------

  @doc """
  Every transcript item in reading order: runs in the order their first item
  arrived, each run's items in the daemon's order (creation order), so text,
  tools and text read as they happened.
  """
  def order(state) do
    ids =
      case Map.get(state.read_model.order, :workspace, []) do
        [] -> state.read_model.transcript |> Map.keys() |> Enum.sort()
        ids -> ids
      end

    transcript = state.read_model.transcript

    {groups, runs} =
      Enum.reduce(ids, {%{}, []}, fn id, {groups, runs} ->
        case Map.get(transcript, id) do
          %{run_id: run_id} ->
            runs = if Map.has_key?(groups, run_id), do: runs, else: [run_id | runs]
            {Map.update(groups, run_id, [id], &[id | &1]), runs}

          _ ->
            {groups, runs}
        end
      end)

    runs |> Enum.reverse() |> Enum.flat_map(&(groups |> Map.fetch!(&1) |> Enum.reverse()))
  end

  @doc """
  The runs the main view shows, in reading order: one run for a run
  destination, every run of the conversation that has not been replaced by a
  newer turn for a conversation destination.
  """
  def view_runs(state) do
    case state.destination do
      {:run, id} ->
        [id]

      {:conversation, conversation} ->
        transcript = state.read_model.transcript
        runs = state.read_model.runs

        state
        |> order()
        |> Enum.map(&Map.get(transcript, &1))
        |> Enum.filter(&(&1 && &1.conversation_id == conversation))
        |> Enum.map(& &1.run_id)
        |> Enum.concat(
          runs
          |> Map.values()
          |> Enum.filter(&(&1.conversation_id == conversation))
          |> Enum.sort_by(&{&1.created_sequence, &1.id})
          |> Enum.map(& &1.id)
        )
        |> Enum.uniq()
        |> Enum.reject(&match?(%{state: :superseded}, Map.get(runs, &1)))

      _ ->
        []
    end
  end

  @doc "The ids the main view shows, in reading order."
  def view_order(state) do
    runs = view_runs(state)
    rank = runs |> Enum.with_index() |> Map.new()
    transcript = state.read_model.transcript

    state
    |> order()
    |> Enum.filter(fn id ->
      case Map.get(transcript, id) do
        %{run_id: run_id} -> Map.has_key?(rank, run_id)
        _ -> false
      end
    end)
    |> Enum.with_index()
    |> Enum.sort_by(fn {id, index} ->
      {Map.fetch!(rank, Map.fetch!(transcript, id).run_id), index}
    end)
    |> Enum.map(&elem(&1, 0))
  end

  # --- the run context ----------------------------------------------------------------

  @doc """
  What laying out one run's items needs to know about the others: which item
  carries the header, which one the answer and the tail, what each step said,
  and how workers group.
  """
  def context(state, run_id) do
    items =
      state
      |> order()
      |> Enum.flat_map(fn id ->
        case ReadModel.transcript_item(state.read_model, id) do
          %{run_id: ^run_id} = item -> [item]
          _ -> []
        end
      end)

    run = Map.get(state.read_model.runs, run_id)
    agents = state.read_model.agents
    worker? = &worker?(&1, agents)

    answer =
      Enum.find(items, &(&1.role == :assistant and &1.kind == :text and not worker?.(&1)))

    lead_work = Enum.reject(items, &(&1.role == :user or worker?.(&1)))

    # The header opens the turn right under the prompt, whichever item the
    # daemon created first: the answer in a chat turn, a worker's first call
    # when the lead's own items are still to come.
    header =
      Enum.find(items, &(&1.role != :user and &1.kind != :error)) ||
        answer || Enum.find(items, &(&1.role != :user))

    steps = Enum.filter(lead_work, &(&1.kind == :thinking))
    {step_texts, residual} = decompose(answer && answer.text, steps)

    workers =
      items
      |> Enum.filter(worker?)
      |> Enum.group_by(& &1.agent_id)

    first_by_worker =
      items
      |> Enum.filter(worker?)
      |> Enum.reduce(%{}, fn item, acc -> Map.put_new(acc, item.agent_id, item.id) end)

    %{
      run: run,
      run_id: run_id,
      items: items,
      first_id: items |> List.first() |> then(&(&1 && &1.id)),
      last_id: items |> List.last() |> then(&(&1 && &1.id)),
      answer: answer,
      header_id: header && header.id,
      step_texts: step_texts,
      residual: residual,
      workers: workers,
      first_by_worker: first_by_worker,
      worker_ids: Map.new(first_by_worker, fn {agent, id} -> {id, agent} end),
      lead_tools: Enum.filter(lead_work, &(&1.kind == :tool)),
      view_first?: false
    }
  end

  defp worker?(%{agent_id: id}, agents) when is_binary(id) do
    case Map.get(agents, id) do
      %{role: role} -> role in @worker_roles
      _ -> false
    end
  end

  defp worker?(_item, _agents), do: false

  # The answer is the message; each step's text is what that step said, and a
  # model's message is those texts one after another. When the message starts
  # with them in order, each step shows its own words above its tool calls
  # and the answer keeps only what follows. Otherwise the steps stay folded
  # and the answer is shown whole: nothing is ever said twice or dropped.
  defp decompose(nil, _steps), do: {%{}, ""}
  defp decompose(text, []), do: {%{}, text}

  defp decompose(text, steps) do
    Enum.reduce_while(steps, {%{}, text}, fn step, {shown, rest} ->
      said = String.trim(step.text || "")
      rest = String.trim_leading(rest)

      cond do
        said == "" ->
          {:cont, {shown, rest}}

        String.starts_with?(rest, said) ->
          {:cont, {Map.put(shown, step.id, said), cut(rest, said)}}

        true ->
          {:halt, {%{}, text}}
      end
    end)
  end

  defp cut(rest, said), do: binary_part(rest, byte_size(said), byte_size(rest) - byte_size(said))

  # --- rows of one item ------------------------------------------------------------------

  @doc "Row specs of item `id` for a `width`-cell transcript (see the moduledoc)."
  def rows(state, ctx, id, width) do
    width = max(8, min(width, 500))

    case Enum.find(ctx.items, &(&1.id == id)) do
      nil -> []
      item -> item_rows(item, ctx, state, width)
    end
  end

  @doc "The height `ScrollMetrics` reports for item `id`: exactly the rows painted."
  def height(state, width, id) do
    case Map.get(state.read_model.transcript, id) do
      nil ->
        1

      %{run_id: run_id} ->
        runs = view_runs(state)

        # An item of a run the view does not show (a superseded turn) takes no
        # row, so scrolling over the daemon's order skips it as the paint does.
        if runs == [] or run_id in runs do
          ctx = %{context(state, run_id) | view_first?: List.first(runs) == run_id}
          length(rows(state, ctx, id, width))
        else
          0
        end
    end
  end

  defp item_rows(item, ctx, state, width) do
    own =
      cond do
        item.role == :user -> user_rows(item, ctx, state, width)
        Map.has_key?(ctx.worker_ids, item.id) -> lane_rows(item, ctx, state, width)
        worker_item?(item, ctx) -> worker_detail_rows(item, ctx, state, width)
        true -> lead_rows(item, ctx, state, width)
      end

    header = if item.id == ctx.header_id, do: header_rows(ctx, state, width), else: []
    tail = if item.id == ctx.last_id, do: tail_rows(ctx, state, width), else: []

    # The header opens the lead's turn, so it comes before the item's own
    # rows; the answer and the footer close the run after the last item.
    if item.role == :user, do: own ++ header ++ tail, else: header ++ own ++ tail
  end

  defp worker_item?(item, ctx),
    do: is_binary(item.agent_id) and Map.has_key?(ctx.first_by_worker, item.agent_id)

  # --- the prompt -------------------------------------------------------------------------

  defp user_rows(item, ctx, state, width) do
    policy = state.capabilities.ambiguous_width
    inner = max(1, width - @body - 1)
    text = admitted(item.text, state)

    lines =
      text
      |> String.split(["\r\n", "\n"])
      |> Enum.flat_map(&prompt_lines(&1, inner, policy))
      |> then(&if(&1 == [], do: [""], else: &1))

    rail = rail_glyph(state)
    card = if item.state == :superseded, do: :text_muted, else: :text

    time =
      if is_integer(item.at) and item.at > 0, do: clock(item.at), else: nil

    rows =
      lines
      |> Enum.with_index()
      |> Enum.map(fn {line, index} ->
        segs = [{"  ", :plain}, {rail, :user_rail}, {" ", :text}, {line, card}]

        segs =
          if (index == 0 and time) &&
               Width.cells(line, policy) + Width.cells(time, policy) + 2 <= inner,
             do: segs ++ [{:right, [{time, :faint}]}],
             else: segs

        spec(segs, {@margin, :user_card})
      end)

    # One blank row before every run but the first one on screen.
    lead = if item.id == ctx.first_id and not ctx.view_first?, do: [blank()], else: []
    lead ++ rows
  end

  # A blank line in the prompt stays a blank row, and a wrapped continuation
  # starts at the card's left edge rather than on the space it broke at.
  defp prompt_lines("", _inner, _policy), do: [""]

  defp prompt_lines(line, inner, policy) do
    case SwarmCodeCLI.UI.Prose.wrap(line, inner, policy) do
      [first | rest] -> [first | Enum.map(rest, &String.trim_leading(&1, " "))]
      [] -> [""]
    end
  end

  # --- the lead's turn -----------------------------------------------------------------------

  defp header_rows(ctx, state, _width) do
    run = ctx.run
    kind = RunRow.theme_kind((run && run.kind) || :chat)
    {_letter, kind_role} = Theme.run_kind(kind)
    mark = SafeText.value(Support.glyph(Theme.run_mark(kind), state))

    name =
      case ctx.answer && agent(ctx.answer, state) do
        %{name: name} when is_binary(name) and name != "" -> name
        _ -> lead_name(ctx, state)
      end

    model = run && present(run.model)

    left =
      [
        {"  ", :plain},
        {mark, {:role, kind_role, [:bold]}},
        {" ", :text},
        {name, {:role, kind_role, [:bold]}}
      ] ++
        if(model, do: [{"  " <> model, :faint}], else: [])

    right = header_state(ctx, state)
    blank_before = if ctx.header_id != ctx.first_id, do: [blank()], else: []
    blank_before ++ [spec(left ++ [{:right, right}], nil)]
  end

  defp lead_name(ctx, state) do
    lead =
      state.read_model.agents
      |> Map.values()
      |> Enum.find(&(&1.run_id == ctx.run_id and &1.role in [:lead, :assistant]))

    case lead do
      %{name: name} when is_binary(name) and name != "" ->
        String.downcase(name)

      _ ->
        # With no named lead the turn is spoken by what it is.
        case ctx.run && ctx.run.kind do
          kind when kind in [:consensus, :research, :workflow, :goal, :ultra] ->
            Atom.to_string(kind)

          _ ->
            "assistant"
        end
    end
  end

  # What the turn is doing now, or what it came to.
  defp header_state(ctx, state) do
    run = ctx.run
    caret = SafeText.value(Support.glyph(:caret, state))

    cond do
      run == nil ->
        []

      run.state in [:waiting_approval, :waiting_question] ->
        [{"waiting for you", {:role, :warning, [:bold]}}]

      run.state in [:running, :streaming, :retrying, :queued] ->
        doing =
          cond do
            tool = Enum.find(ctx.lead_tools, &(&1.state in [:running, :streaming])) ->
              "running " <> verb(tool.tool || %DTO.ToolCall{})

            ctx.answer != nil and ctx.answer.state == :streaming and
                String.trim(ctx.residual) != "" ->
              "writing"

            run.state == :retrying ->
              "retrying"

            run.state == :queued ->
              "queued"

            true ->
              "thinking"
          end

        [{doing <> " " <> caret, {:role, :accent, []}}] ++ spend(run, state, true)

      run.state == :paused ->
        [{"paused", {:role, :warning, []}}] ++ spend(run, state, true)

      run.state == :failed ->
        [{"failed", {:role, :error, [:bold]}}] ++ stop_chip(run) ++ spend(run, state, true)

      run.state in [:stopped, :interrupted] ->
        [{Atom.to_string(run.state), :muted}] ++ stop_chip(run) ++ spend(run, state, true)

      true ->
        case stop_chip(run) do
          [] -> spend(run, state, false)
          chip -> tl_space(chip) ++ spend(run, state, true)
        end
    end
  end

  # Why a turn ended, when that is news: "turn limit", "rate limit". A turn
  # that simply finished says nothing more than its time.
  @quiet_stops ["", "done", "completed", "complete", "finished", "end turn", "end_turn", "stop"]

  defp stop_chip(run) do
    label = Map.get(run, :stop_label)

    if is_binary(label) and String.downcase(String.trim(label)) not in @quiet_stops and
         String.downcase(label) != Atom.to_string(run.state),
       do: [{"  " <> label, {:role, :warning, []}}],
       else: []
  end

  defp tl_space([{"  " <> text, style} | rest]), do: [{text, style} | rest]
  defp tl_space(chip), do: chip

  defp spend(run, state, leading?) do
    tokens = (run.tokens_in || 0) + (run.tokens_out || 0)

    parts =
      [elapsed(run, state), if(tokens > 0, do: compact(tokens) <> " tok")]
      |> Enum.reject(&is_nil/1)

    case parts do
      [] -> []
      parts -> [{if(leading?, do: "  ", else: "") <> Enum.join(parts, " · "), :faint}]
    end
  end

  defp elapsed(%{started_at: started, finished_at: finished}, _state)
       when is_integer(started) and is_integer(finished) and finished >= started,
       do: duration_text(finished - started)

  defp elapsed(%{started_at: started, state: state}, %{now: now})
       when is_integer(started) and started > 0 and is_integer(now) and now > started and
              state in @live,
       do: duration_text(now - started)

  defp elapsed(_, _), do: nil

  defp lead_rows(%{kind: :thinking} = item, ctx, state, width),
    do: step_rows(item, ctx, state, width)

  defp lead_rows(%{kind: :tool} = item, _ctx, state, width), do: tool_rows(item, state, width)
  defp lead_rows(%{kind: :error} = item, _ctx, state, width), do: error_rows(item, state, width)

  # The answer's own position holds nothing but the header; its words follow
  # the work, after the run's last item.
  defp lead_rows(%{id: id}, %{answer: %{id: id}}, _state, _width), do: []

  defp lead_rows(item, _ctx, state, width),
    do: prose_rows(item.text, state, width, @body) ++ cut_rows(item, state)

  # What a step said, where the answer started with it; else nothing unless
  # the step is selected or expanded, and then its time and its reasoning.
  defp step_rows(item, ctx, state, width) do
    said = Map.get(ctx.step_texts, item.id)
    expanded? = MapSet.member?(state.expansions, item.id)
    selected? = selected?(state, item.id)

    words = if said, do: prose_rows(said, state, width, @body), else: []

    detail =
      if expanded? or (selected? and words == []) do
        duration = item.tool && tool_duration(item.tool, state)
        label = if duration, do: "thought · " <> duration, else: "thought"

        marker =
          SafeText.value(Support.glyph(if(expanded?, do: :expanded, else: :collapsed), state))

        line =
          spec([{String.duplicate(" ", @body), :plain}, {marker <> " " <> label, :faint}], nil)

        thought = if item.reasoning != "", do: item.reasoning, else: item.text || ""
        [line | if(expanded?, do: preview(thought, :muted, state, width), else: [])]
      else
        []
      end

    words ++ detail
  end

  # --- tool rows ------------------------------------------------------------------------------

  defp tool_rows(item, state, width, indent \\ @body) do
    tool = item.tool || %DTO.ToolCall{}
    status = if item.tool, do: tool.status, else: item.state
    # A command that ran but exited non-zero failed, as far as the reader cares.
    code = Map.get(tool, :exit_code)
    status = if status == :done and is_integer(code) and code != 0, do: :failed, else: status
    {mark, mark_style} = status_mark(status, state)
    verb = verb(tool)
    target = target(tool, verb)

    diff = diff_source(item, tool)
    counts = edit_counts(item, tool, diff, state)

    summary =
      if counts == [],
        do: summary_line(tool) || last_line(item, tool) || bytes(tool.result_bytes),
        else: nil

    duration = tool_duration(tool, state)

    right =
      counts ++
        if(summary,
          do: [{Density.safe(summary, state, @summary_cells) |> SafeText.value(), :muted}],
          else: []
        ) ++
        exit_words(tool) ++
        if(duration, do: [{"  " <> duration, :faint}], else: [])

    left = [
      {String.duplicate(" ", indent), :plain},
      {mark, mark_style},
      {" ", :text},
      {pad_verb(verb), :muted},
      {target, if(status in [:failed], do: {:role, :error, []}, else: :text)}
    ]

    expanded? = MapSet.member?(state.expansions, item.id)

    # pass71 V3 (R5): an edit shows its first hunk in place, expanded or not.
    body =
      cond do
        diff -> first_hunk(diff, tool, state, width, indent + 2)
        not expanded? -> []
        true -> preview(item.text, :muted, state, width, indent + 2, item.detail_ref)
      end

    [spec(left ++ [{:right, right}], nil) | body]
  end

  # A command that failed says its exit code; one handed to the background
  # says so, since its output keeps arriving after the row.
  defp exit_words(tool) do
    code = Map.get(tool, :exit_code)

    cond do
      Map.get(tool, :background) == true -> [{"  background", {:role, :info, []}}]
      is_integer(code) and code != 0 -> [{"  exit #{code}", {:role, :error, []}}]
      true -> []
    end
  end

  defp diff?(text) when is_binary(text),
    do: String.contains?(text, "\n@@ ") or String.starts_with?(text, "@@ ")

  defp diff?(_), do: false

  @diff_preview 12

  # The diff an edit row shows: the daemon's first hunk (`ToolCall.hunk`,
  # pass71 S contract, read with `Map.get` until it is on the wire), else the
  # item's own text when that is a unified diff.
  defp diff_source(item, tool) do
    case Map.get(tool, :hunk) do
      hunk when is_binary(hunk) and hunk != "" ->
        if diff?(hunk), do: hunk, else: nil

      _ ->
        if diff?(item.text), do: item.text, else: nil
    end
  end

  # The body lines of a unified diff, without its file headers.
  defp diff_lines(text, state) do
    text
    |> admitted(state)
    |> String.trim_trailing("\n")
    |> String.split(["\r\n", "\n"])
    |> Enum.reject(
      &(String.starts_with?(&1, "--- ") or String.starts_with?(&1, "+++ ") or
          String.starts_with?(&1, "diff --git ") or String.starts_with?(&1, "index "))
    )
    |> Enum.drop_while(&(not String.starts_with?(&1, "@@")))
  end

  # An edit's first hunk, in place: its `@@` line and at most a dozen lines in
  # the diff colours, then how many lines the whole diff has beyond them.
  defp first_hunk(text, tool, state, width, indent) do
    policy = state.capabilities.ambiguous_width
    inner = max(1, width - indent - 1)
    pad = String.duplicate(" ", indent)
    lines = diff_lines(text, state)

    {hunk, _rest} =
      case lines do
        [head | body] ->
          {[head | Enum.take_while(body, &(not String.starts_with?(&1, "@@")))], []}

        [] ->
          {[], []}
      end

    shown = Enum.take(hunk, @diff_preview)

    # The daemon may send only the first hunk and count the rest.
    total =
      case Map.get(tool, :diff_lines) do
        n when is_integer(n) and n >= length(lines) -> n
        _ -> length(lines)
      end

    more = total - length(shown)

    rows =
      for line <- shown do
        {head, _rest, _cells} = Width.take_cells(line, inner, policy)
        [{piece, kind}] = SwarmCodeCLI.UI.Projector.Syntax.line(head, :diff) |> fallback(head)
        spec([{pad, :plain}, {piece, {:syntax, kind}}], {indent, :code_card})
      end

    hint =
      if more > 0,
        do:
          "#{ellipsis(state)} #{more} more #{if more == 1, do: "line", else: "lines"} · Enter opens"

    if hint, do: rows ++ [spec([{pad, :plain}, {hint, :faint}], nil)], else: rows
  end

  defp fallback([], head), do: [{head, :plain}]
  defp fallback(tokens, _head), do: tokens

  defp pad_verb(verb) do
    if String.length(verb) >= @verb_cells,
      do: verb <> " ",
      else: String.pad_trailing(verb, @verb_cells)
  end

  # The tool's verb: the first word of its title ("read mix.exs" → "read",
  # "run: ls" → "run"), else its name in words.
  defp verb(%DTO.ToolCall{title: title, name: name}) do
    case Regex.run(~r/^([a-z][a-z_]*):?\s/u, title || "") do
      [_, word] -> word
      nil -> String.replace(name || "tool", "_", " ")
    end
  end

  defp target(%DTO.ToolCall{title: title} = tool, verb) do
    title = first_line(title) || ""

    rest =
      case Regex.run(~r/^[a-z][a-z_]*:?\s+(.*)$/u, title) do
        [_, rest] -> rest
        nil -> title
      end

    rest =
      if rest == "" and title == "", do: String.replace(tool.name || "", "_", " "), else: rest

    if rest == verb, do: "", else: rest
  end

  # `+3 −1` for an edit, from the counts the daemon sends or its `+N −M` detail.
  defp edit_counts(item, tool, diff, state) do
    added = Map.get(item, :added) || Map.get(tool, :added)
    removed = Map.get(item, :removed) || Map.get(tool, :removed)

    {added, removed} =
      cond do
        is_integer(added) or is_integer(removed) ->
          {added || 0, removed || 0}

        match = Regex.run(~r/^\+(\d+)\s*[−-](\d+)$/u, String.trim(tool.detail || "")) ->
          [_, a, r] = match
          {String.to_integer(a), String.to_integer(r)}

        # The counts of a diff the row shows whole (never of a first hunk alone).
        diff != nil and not is_binary(Map.get(tool, :hunk)) ->
          lines = diff_lines(diff, state)

          {Enum.count(lines, &String.starts_with?(&1, "+")),
           Enum.count(lines, &String.starts_with?(&1, "-"))}

        true ->
          {nil, nil}
      end

    if is_integer(added),
      do: [
        {"+#{added}", {:role, :success, []}},
        {if(state.capabilities.ascii?, do: " -", else: " −") <> "#{removed}", {:role, :error, []}}
      ],
      else: []
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

  # A command's verdict is usually its last line ("11 tests, 1 failure"); a
  # read's is not, so only commands say it.
  defp last_line(%{text: text}, %{name: name})
       when is_binary(text) and text != "" and name in ["run_command", "bash", "shell"] do
    tail = binary_part(text, max(0, byte_size(text) - 512), min(byte_size(text), 512))

    tail
    |> String.split(["\r\n", "\n"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> List.last()
    |> case do
      nil -> nil
      line -> if String.valid?(line), do: line, else: nil
    end
  end

  defp last_line(_item, _tool), do: nil

  # --- workers ------------------------------------------------------------------------------------

  # One line per worker at its first item: mark in its lane colour, name,
  # state and time, how many tools, and the first words of its report.
  defp lane_rows(item, ctx, state, width) do
    agent_id = Map.fetch!(ctx.worker_ids, item.id)
    items = Map.get(ctx.workers, agent_id, [])
    agent = Map.get(state.read_model.agents, agent_id)
    expanded? = MapSet.member?(state.expansions, item.id)

    line = lane_line(agent, agent_id, items, ctx, state)

    detail =
      if expanded?,
        do: Enum.flat_map(items, &worker_detail_rows(&1, ctx, state, width, true)),
        else: []

    [line | detail]
  end

  # A worker's other items take no row until its lane is expanded; expanded,
  # each shows under the lane line.
  defp worker_detail_rows(item, ctx, state, width, force? \\ false) do
    first = Map.get(ctx.first_by_worker, item.agent_id)
    expanded? = MapSet.member?(state.expansions, first)

    cond do
      force? and item.kind == :tool -> tool_rows(item, state, width, @body + 2)
      force? and item.kind == :text -> prose_rows(item.text, state, width, @body + 2)
      force? and item.kind == :error -> error_rows(item, state, width)
      force? -> []
      expanded? or item.id == first -> []
      selected?(state, item.id) -> tool_rows(item, state, width, @body + 2)
      true -> []
    end
  end

  defp lane_line(agent, agent_id, items, ctx, state) do
    lane = lane(agent, ctx, state)
    name = (agent && present(agent.name)) || "worker"
    status = (agent && agent.state) || items |> List.last() |> then(&(&1 && &1.state))
    {mark, mark_style} = status_mark(status, state)
    tools = Enum.count(items, &(&1.kind == :tool))

    report =
      items
      |> Enum.filter(&(&1.kind == :text and &1.role != :user))
      |> List.last()
      |> then(&(&1 && first_line(admitted(&1.text, state))))

    waiting =
      Enum.find(items, &(&1.kind == :tool and &1.state in [:waiting_approval, :waiting_question]))

    failure =
      items
      |> Enum.filter(&(&1.kind == :error))
      |> List.last()
      |> then(&(&1 && first_line(admitted(&1.text, state))))

    duration = agent && agent_duration(agent, state)

    facts =
      cond do
        waiting ->
          [
            {"waiting · " <>
               target(waiting.tool || %DTO.ToolCall{}, verb(waiting.tool || %DTO.ToolCall{})),
             {:role, :warning, []}}
          ]

        true ->
          words =
            [duration, if(tools > 0, do: "#{tools} tool" <> if(tools == 1, do: "", else: "s"))]
            |> Enum.reject(&is_nil/1)
            |> Enum.join(" · ")

          said =
            cond do
              failure -> [{"  " <> failure, {:role, :error, []}}]
              report -> [{"  " <> quoted(report, state), :muted}]
              true -> []
            end

          [{words, :faint}] ++ said
      end

    glyph = SafeText.value(Support.glyph(:agent_sub, state))
    _ = agent_id

    spec(
      [
        {String.duplicate(" ", @body), :plain},
        {glyph, {:role, lane, [:bold]}},
        {" ", :text},
        {name, {:role, lane, [:bold]}},
        {"  ", :text},
        {mark, mark_style},
        {" ", :text}
      ] ++ facts,
      nil
    )
  end

  defp quoted(text, state) do
    open = if state.capabilities.ascii?, do: "\"", else: "“"
    close = if state.capabilities.ascii?, do: "\"", else: "”"
    open <> text <> close
  end

  defp agent_duration(%{started_at: s, finished_at: f}, _state)
       when is_integer(s) and is_integer(f) and f >= s,
       do: duration_text(f - s)

  defp agent_duration(%{started_at: s, state: agent_state}, %{now: now})
       when is_integer(s) and s > 0 and is_integer(now) and now > s and agent_state in @live,
       do: duration_text(now - s)

  defp agent_duration(_, _), do: nil

  defp lane(nil, _ctx, _state), do: :agent_lane_1

  defp lane(agent, ctx, state) do
    workers =
      state.read_model.agents
      |> Map.values()
      |> Enum.filter(&(&1.run_id == ctx.run_id and &1.role in @worker_roles))
      |> Enum.sort_by(&{&1.started_at || 0, &1.id})

    index = Enum.find_index(workers, &(&1.id == agent.id)) || 0
    Enum.at(@lanes, rem(index, length(@lanes)))
  end

  # --- the end of a run ---------------------------------------------------------------------------

  # After the run's last item: workers that have not started, the answer, and
  # for a run that failed or stopped, a card saying what happened.
  defp tail_rows(ctx, state, width) do
    queued = queued_rows(ctx, state)
    answer = answer_rows(ctx, state, width)
    footer = footer_rows(ctx, state, width)
    queued ++ answer ++ footer
  end

  defp queued_rows(ctx, state) do
    state.read_model.agents
    |> Map.values()
    |> Enum.filter(fn agent ->
      agent.run_id == ctx.run_id and agent.role in @worker_roles and
        not Map.has_key?(ctx.first_by_worker, agent.id)
    end)
    |> Enum.sort_by(&{&1.started_at || 0, &1.id})
    |> Enum.map(fn agent ->
      glyph = SafeText.value(Support.glyph(:agent_lead, state))
      word = agent.state |> Theme.status() |> elem(0) |> SafeText.value() |> String.downcase()

      spec(
        [
          {String.duplicate(" ", @body), :plain},
          {glyph, :faint},
          {" ", :text},
          {agent.name || "worker", :muted},
          {"  " <> word, :faint}
        ],
        nil
      )
    end)
  end

  defp answer_rows(%{answer: nil}, _state, _width), do: []

  defp answer_rows(ctx, state, width) do
    text = String.trim(ctx.residual)
    shown_before? = Enum.any?(ctx.items, &drawn_work?(&1, ctx))

    cond do
      text == "" ->
        []

      shown_before? ->
        [blank() | prose_rows(text, state, width, @body)] ++ cut_rows(ctx.answer, state)

      true ->
        prose_rows(text, state, width, @body) ++ cut_rows(ctx.answer, state)
    end
  end

  # pass71 F1 (review R1): a reply longer than what the daemon sends inline
  # (8 KB) says so under its last row, and names the key that opens it all.
  defp cut_rows(%{detail_ref: %{total_bytes: total}} = item, state)
       when is_integer(total) do
    shown = byte_size(item.text || "")
    more = bytes(max(total - shown, 1))

    key =
      if selected?(state, item.id), do: "Enter opens it all", else: "Ctrl-T, Enter opens it all"

    [
      spec(
        [
          {String.duplicate(" ", @body), :plain},
          {"#{ellipsis(state)} #{more} more · #{key}", :faint}
        ],
        nil
      )
    ]
  end

  defp cut_rows(_item, _state), do: []

  # Whether an item of the turn draws a row between the header and the
  # answer: a call, an error, a worker's lane, a step that says something.
  # A folded step draws nothing, so the answer follows the header directly.
  defp drawn_work?(item, ctx) do
    cond do
      item.id == ctx.answer.id or item.role == :user -> false
      item.kind in [:tool, :error] -> true
      Map.has_key?(ctx.worker_ids, item.id) -> true
      Map.has_key?(ctx.step_texts, item.id) -> true
      item.kind == :text and not worker_item?(item, ctx) -> String.trim(item.text || "") != ""
      true -> false
    end
  end

  # A failed run says what failed and what to do; a stopped one says so once.
  defp footer_rows(%{run: %{state: :failed} = run}, state, width) do
    inner = max(1, width - @body - 3)

    reason = present(run.error) || present(Map.get(run, :stop_label))

    lines =
      case reason do
        nil -> "Failed"
        reason -> "Failed · " <> reason
      end
      |> admitted(state)
      |> SwarmCodeCLI.UI.Prose.wrap(inner, state.capabilities.ambiguous_width)

    mark = SafeText.value(Support.glyph(:fail, state))

    head =
      lines
      |> Enum.with_index()
      |> Enum.map(fn {line, index} ->
        lead = if index == 0, do: mark <> " ", else: "  "

        spec(
          [{String.duplicate(" ", @body), :plain}, {lead <> line, {:role, :error, []}}],
          {@body, :error_card}
        )
      end)

    hint =
      spec(
        [{String.duplicate(" ", @body), :plain}, {"  " <> next_step(run, state), :faint}],
        {@body, :error_card}
      )

    [blank()] ++ head ++ [hint]
  end

  defp footer_rows(%{run: %{state: :stopped}} = ctx, _state, _width) do
    residual = String.trim(ctx.residual || "")

    cond do
      # pass70 Q6: the engine ends a stopped answer with "_(stopped)_" itself
      # and the header already says stopped; a third line said it again.
      ctx.answer && String.ends_with?(residual, "_(stopped)_") ->
        []

      ctx.answer && residual != "" ->
        [spec([{String.duplicate(" ", @body), :plain}, {"stopped", :faint}], nil)]

      true ->
        [spec([{String.duplicate(" ", @body), :plain}, {"stopped by you", :faint}], nil)]
    end
  end

  defp footer_rows(_ctx, _state, _width), do: []

  # What to do about a failed turn: wait for the retry the daemon scheduled,
  # or retry it and perhaps switch model.
  defp next_step(run, state) do
    retry_at = Map.get(run, :retry_at)
    now = Map.get(state, :now)
    provider = present(Map.get(run, :provider_name))

    cond do
      is_integer(retry_at) and is_integer(now) and retry_at > now ->
        "retrying in " <>
          duration_text(retry_at - now) <> if(provider, do: " · " <> provider, else: "")

      true ->
        by = if provider, do: " by " <> provider, else: ""

        case Map.get(run, :error_kind) do
          "rate_limit" -> "rate limited" <> by <> " · retry in a moment · /model to switch"
          "usage_limit" -> "out of quota" <> by <> " · /model to switch model"
          "overloaded" -> "provider busy · retry from the palette · /model to switch"
          "unauthorized" -> "the key was refused · check the provider in settings"
          "context_overflow" -> "too long for the model · /compact, then retry"
          "network" -> "connection dropped · retry from the palette"
          "timeout" -> "timed out · retry from the palette"
          _ -> "retry from the palette · /model to switch model"
        end
    end
  end

  # --- errors, previews, prose -----------------------------------------------------------------------

  defp error_rows(item, state, width) do
    inner = max(1, width - @body - 3)
    mark = SafeText.value(Support.glyph(:fail, state))

    name =
      case agent(item, state) do
        %{name: name} when is_binary(name) and name != "" -> name <> " · "
        _ -> ""
      end

    (name <> (item.text || ""))
    |> admitted(state)
    |> String.split(["\r\n", "\n"])
    |> Enum.flat_map(&SwarmCodeCLI.UI.Prose.wrap(&1, inner, state.capabilities.ambiguous_width))
    |> Enum.with_index()
    |> Enum.map(fn {line, index} ->
      lead = if index == 0, do: mark <> " ", else: "  "
      spec([{String.duplicate(" ", @body), :plain}, {lead <> line, {:role, :error, []}}], nil)
    end)
  end

  # The first `@preview` source lines, each clipped to one row, then the count.
  # pass71 F2 (review R2): with a detail ref the text is only the daemon's
  # 2 KB preview, so the count says how much is left in bytes and Enter opens
  # it (`Keymap.content_activate/2`); without one the whole text is here and
  # Enter folds it, so the count names no key.
  defp preview(text, style, state, width, indent \\ @body + 2, ref \\ nil) do
    policy = state.capabilities.ambiguous_width
    inner = max(1, width - indent - 1)

    lines =
      case text |> admitted(state) |> String.trim_trailing("\n") do
        "" -> []
        body -> String.split(body, ["\r\n", "\n", "\r"])
      end

    shown = Enum.take(lines, @preview)
    more = length(lines) - length(shown)
    pad = String.duplicate(" ", indent)

    rows =
      for line <- shown do
        {head, _rest, _cells} = Width.take_cells(line, inner, policy)
        spec([{pad, :plain}, {head, style}], nil)
      end

    tail =
      case ref do
        %{total_bytes: total} when is_integer(total) ->
          left = bytes(max(total - byte_size(text || ""), 1))
          lines = if more > 0, do: "#{more}+ more lines, ", else: ""
          "#{ellipsis(state)} #{lines}#{left} more · Enter opens"

        _ when more > 0 ->
          "#{ellipsis(state)} #{more} more #{if more == 1, do: "line", else: "lines"}"

        _ ->
          nil
      end

    if tail, do: rows ++ [spec([{pad, :plain}, {tail, :faint}], nil)], else: rows
  end

  defp prose_rows(text, state, width, indent) do
    case admitted(text, state) do
      "" ->
        []

      source ->
        inner = max(1, width - indent - 1)
        pad = {String.duplicate(" ", indent), :plain}

        source
        |> Markdown.rows(inner, state.capabilities.ambiguous_width,
          ascii?: state.capabilities.ascii?
        )
        |> Enum.map(fn
          %{fill: :code_card, segments: segments, header: true} ->
            spec([pad | segments] ++ copy_hint(state), {indent, :code_card})

          %{fill: :code_card, segments: segments} ->
            spec([pad | segments], {indent, :code_card})

          %{segments: segments} ->
            spec([pad | segments], nil)
        end)
    end
  end

  # In select mode a code card's header says how to copy it.
  defp copy_hint(%{focus: "main", layers: []} = state) do
    _ = state
    [{:right, [{"y", {:role, :info, [:bold]}}, {" copy ", :faint}]}]
  end

  defp copy_hint(_state), do: []

  # --- facts ------------------------------------------------------------------------------------------

  defp status_mark(:done, state), do: {glyph(:check, state), {:role, :success, []}}

  defp status_mark(status, state) when status in [:failed],
    do: {glyph(:fail, state), {:role, :error, []}}

  defp status_mark(status, state) when status in [:stopped, :interrupted, :superseded],
    do: {glyph(:fail, state), :faint}

  defp status_mark(status, state) when status in [:waiting_question, :waiting_approval],
    do: {glyph(:waiting, state), {:role, :warning, [:bold]}}

  defp status_mark(status, state)
       when status in [:running, :streaming, :queued, :retrying, :paused],
       do: {glyph(:caret, state), {:role, :accent, []}}

  defp status_mark(_, state), do: {glyph(:check, state), :faint}

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

  @doc "`940`, `19k`, `1.2M`."
  def compact(n) when n < 1_000, do: Integer.to_string(n)
  def compact(n) when n < 1_000_000, do: "#{div(n + 500, 1_000)}k"
  def compact(n), do: :erlang.float_to_binary(n / 1_000_000, decimals: 1) <> "M"

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

  defp agent(%{agent_id: id}, state) when is_binary(id), do: Map.get(state.read_model.agents, id)
  defp agent(_, _), do: nil

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  defp selected?(state, id),
    do: state.focus == "main" and state.layers == [] and Map.get(state.selection, "main") == id

  defp glyph(token, state), do: SafeText.value(Support.glyph(token, state))
  defp rail_glyph(state), do: SafeText.value(Support.rail(state))

  defp ellipsis(%{capabilities: %{ascii?: true}}), do: "..."
  defp ellipsis(_), do: "…"

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp limits(state),
    do: %{SafeText.Limits.content() | ambiguous_width: state.capabilities.ambiguous_width}

  # Bounded, escaped source text; over the budget it reads as the limit notice.
  defp admitted(text, state) when is_binary(text),
    do: text |> Density.external(limits(state)) |> SafeText.value()

  defp admitted(_, _), do: ""

  defp spec(segs, fill), do: %{segs: segs, fill: fill}
  defp blank, do: %{segs: [], fill: nil}

  # --- the viewport ------------------------------------------------------------------------------------

  @doc """
  The visible slice of the transcript: `{blocks, first_index, total, newer}`.

  Following the stream, items are taken from the end until `height` rows are
  filled; scrolled, from the anchor's item and row. Only the items that reach
  the screen are laid out, and only their visible rows become spans, so the
  scene is bounded by the viewport, never by the length of the conversation.
  """
  def viewport(state, width, height) do
    scroll = Map.get(state.scrolls, :main)
    follow? = scroll == nil or scroll.follow? == true
    viewport(state, width, height, follow?)
  end

  # pass70 Q1: scrolled so near the end that the rows from the anchor down do
  # not fill the view, the view is drawn from the end instead, like following:
  # the last row sits on the bottom edge and nothing is left blank below it.
  defp viewport(state, width, height, follow?) do
    ids = view_order(state)
    transcript = state.read_model.transcript
    first_run = state |> view_runs() |> List.first()
    scroll = Map.get(state.scrolls, :main)
    anchor = scroll && scroll.anchor

    index =
      case anchor do
        {id, _, _} -> Enum.find_index(ids, &(&1 == id)) || 0
        _ -> 0
      end

    candidates = Enum.with_index(ids)
    candidates = if follow?, do: Enum.reverse(candidates), else: Enum.drop(candidates, index)

    {blocks, left, first, _cache} =
      Enum.reduce_while(candidates, {[], height, index, %{}}, fn
        _, {blocks, left, first, cache} when left <= 0 ->
          {:halt, {blocks, 0, first, cache}}

        {id, item_index}, {blocks, left, first, cache} ->
          run_id = Map.fetch!(transcript, id).run_id

          {ctx, cache} =
            case Map.fetch(cache, run_id) do
              {:ok, ctx} ->
                {ctx, cache}

              :error ->
                ctx = %{context(state, run_id) | view_first?: run_id == first_run}
                {ctx, Map.put(cache, run_id, ctx)}
            end

          offset =
            case anchor do
              {^id, line, _} when not follow? -> line
              _ -> 0
            end

          {block, used} =
            state
            |> rows(ctx, id, width)
            |> window(offset, left, follow?, state, width, selected?(state, id))

          first = if follow? and used > 0, do: item_index, else: first

          if block,
            do: {:cont, {[block | blocks], left - used, first, cache}},
            else: {:cont, {blocks, left, first, cache}}
      end)

    hidden_above? = index > 0 or match?({_, line, _} when line > 0, anchor)

    if not follow? and left > 0 and hidden_above? do
      viewport(state, width, height, true)
    else
      blocks = if follow?, do: blocks, else: Enum.reverse(blocks)
      {blocks, min(first, length(ids)), length(ids)}
    end
  end

  @doc "The visible slice of `rows` as one block, and how many rows it holds."
  def window(rows, offset, limit, follow?, state, width, selected? \\ false) do
    visible =
      cond do
        limit <= 0 -> []
        follow? -> Enum.take(rows, -limit)
        true -> rows |> Enum.drop(max(0, offset)) |> Enum.take(limit)
      end

    spans =
      visible
      |> Enum.map(&render(&1, width, state, selected?))
      |> Enum.intersperse([newline(state)])
      |> List.flatten()

    {if(visible == [], do: nil, else: %Block.RichText{spans: spans}), length(visible)}
  end

  defp newline(state), do: %Span{text: safe("\n", state), style: style_of(:plain, state)}

  # One row spec to spans: the right-aligned group placed against the right
  # margin when it fits (dropped when it does not), the row clipped to the
  # width, the fill painted from its column to the margin, the selection rail
  # in the first cell, and neighbouring spans of one style merged.
  defp render(%{segs: segs, fill: fill}, width, state, selected?) do
    policy = state.capabilities.ambiguous_width
    avail = max(1, width - 1)

    {left, right} =
      case List.last(segs) do
        {:right, right} -> {Enum.drop(segs, -1), right}
        _ -> {segs, []}
      end

    left = Enum.reject(left, fn {text, _} -> text == "" end)
    right = Enum.reject(right, fn {text, _} -> text == "" end)
    left_cells = Markdown.segments_cells(left, policy)
    right_cells = Markdown.segments_cells(right, policy)

    segs =
      if right != [] and left_cells + 2 + right_cells <= avail,
        do: left ++ [{String.duplicate(" ", avail - left_cells - right_cells), :plain}] ++ right,
        else: clip(left, avail, policy)

    fill = fill || if(selected?, do: {@margin, :hover})

    segs =
      case fill do
        nil ->
          segs

        {_, _} ->
          used = Markdown.segments_cells(segs, policy)
          if used < avail, do: segs ++ [{String.duplicate(" ", avail - used), :plain}], else: segs
      end

    segs = if selected?, do: with_rail(segs, state, policy), else: segs
    segs = if segs == [], do: [{" ", :plain}], else: segs

    segs
    |> backgrounds(fill, policy)
    |> Enum.map(fn {text, key, background} -> {text, style_of(key, state, background)} end)
    |> Enum.chunk_by(&elem(&1, 1))
    |> Enum.map(fn [{_, style} | _] = group ->
      %Span{text: safe(Enum.map_join(group, &elem(&1, 0)), state), style: style}
    end)
  end

  defp clip(segs, width, policy) do
    {kept, _} =
      Enum.reduce_while(segs, {[], 0}, fn {text, key}, {acc, used} ->
        cells = Width.cells(text, policy)

        cond do
          used + cells <= width ->
            {:cont, {[{text, key} | acc], used + cells}}

          used >= width ->
            {:halt, {acc, used}}

          true ->
            {taken, _rest, taken_cells} = Width.take_cells(text, width - used, policy)
            {:halt, {[{taken, key} | acc], used + taken_cells}}
        end
      end)

    Enum.reverse(kept)
  end

  # The rail replaces the row's first cell, which is always indentation.
  defp with_rail([{text, key} | rest], state, policy) do
    rail = [{rail_glyph(state), {:role, :accent, []}}]

    case Width.take_cells(text, 1, policy) do
      {" ", tail, 1} -> rail ++ if(tail == "", do: rest, else: [{tail, key} | rest])
      _ -> rail ++ [{text, key} | rest]
    end
  end

  defp with_rail([], state, _policy), do: [{rail_glyph(state), {:role, :accent, []}}]

  # Each segment with the background it sits on: the fill from its column
  # onwards, nothing before it.
  defp backgrounds(segs, nil, _policy), do: Enum.map(segs, fn {text, key} -> {text, key, nil} end)

  defp backgrounds(segs, {from, background}, policy) do
    {out, _} =
      Enum.reduce(segs, {[], 0}, fn {text, key}, {acc, column} ->
        cells = Width.cells(text, policy)

        cond do
          column >= from ->
            {[{text, key, background} | acc], column + cells}

          column + cells <= from ->
            {[{text, key, nil} | acc], column + cells}

          true ->
            {head, tail, head_cells} = Width.take_cells(text, from - column, policy)

            {[{tail, key, background}, {head, key, nil} | acc],
             column + head_cells + Width.cells(tail, policy)}
        end
      end)

    out |> Enum.reverse() |> Enum.reject(fn {text, _, _} -> text == "" end)
  end

  # --- styles ----------------------------------------------------------------------------------------

  @syntax %{
    keyword: :agent_lane_2,
    string: :agent_lane_1,
    number: :agent_lane_3,
    atom: :agent_lane_3,
    type: :agent_lane_5,
    function: :text_primary,
    variable: :agent_lane_4,
    comment: :text_faint,
    punct: :text_muted,
    plain: :text_primary,
    add: :success,
    del: :error,
    hunk: :info,
    meta: :text_muted
  }

  @doc false
  def style_of(key, state, background \\ nil)

  def style_of(key, state, background) do
    base = key_style(key, state)

    # A chip keeps its own surface on a card (pass71 V2: the code card's
    # language chip).
    case base.background == nil && background && surface(background, state) do
      falsy when falsy in [nil, false] -> base
      color -> %{base | background: color}
    end
  end

  defp key_style(:plain, state), do: tint(:text_primary, state)
  defp key_style(:text, state), do: tint(:text_primary, state)
  defp key_style(:muted, state), do: tint(:text_muted, state)
  defp key_style(:faint, state), do: tint(:text_faint, state)
  defp key_style(:strong, state), do: tint(:text_primary, state, [:bold])
  defp key_style(:em, state), do: tint(:text_primary, state, [:italic])
  defp key_style(:strong_em, state), do: tint(:text_primary, state, [:bold, :italic])

  defp key_style(:code, state),
    do: %{tint(:text_primary, state) | background: surface(:chip, state)}

  defp key_style(:link, state), do: tint(:info, state, [:underlined])
  defp key_style(:url, state), do: tint(:text_faint, state)
  defp key_style(:heading, state), do: tint(:text_primary, state, [:bold])
  defp key_style(:subheading, state), do: tint(:text_primary, state, [:bold])
  defp key_style(:bullet, state), do: tint(:text_muted, state)
  defp key_style(:number, state), do: tint(:text_muted, state)
  defp key_style(:quote_rail, state), do: tint(:text_ghost, state)
  defp key_style(:quote, state), do: tint(:text_muted, state, [:italic])
  defp key_style(:rule, state), do: tint(:text_ghost, state)
  defp key_style(:table_head, state), do: tint(:text_primary, state, [:bold])

  defp key_style(:code_lang, state),
    do: %{tint(:text_muted, state) | background: surface(:chip, state)}

  defp key_style(:code_text, state), do: tint(:text_primary, state)
  defp key_style(:user_rail, state), do: tint(:accent, state)
  defp key_style({:syntax, kind}, state), do: tint(Map.get(@syntax, kind, :text_primary), state)
  defp key_style({:role, role, modifiers}, state), do: tint(role, state, modifiers)
  defp key_style(_other, state), do: tint(:text_primary, state)

  defp tint(role, state, modifiers \\ []) do
    %{RunRow.tinted(role, state) | background: nil, modifiers: modifiers}
  end

  # Card surfaces, from the theme's backgrounds; nothing in monochrome.
  defp surface(:user_card, state), do: background(:hover, state)
  defp surface(:code_card, state), do: background(:card, state)
  defp surface(:chip, state), do: background(:hover, state)
  defp surface(:hover, state), do: background(:hover, state)
  defp surface(:error_card, state), do: background(:chip_err, state)

  defp background(role, state), do: Theme.style(role, state.capabilities).background

  # Re-escape complete clusters in source-sized chunks, then concatenate under
  # SafeText's larger escaped-output budget.
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
