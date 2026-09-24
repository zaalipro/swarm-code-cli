defmodule SwarmCodeCLI.UI.Projector.Overlay do
  @moduledoc """
  The agent overlay (pass 72, P8 and D8): one agent, full screen, over the
  chat and the panel until Esc.

      header   run › agent  state        [ ‹ prev  ●◐✓!  next › ]   Esc back to chat
      meta     role · approval mode · model · 3rd of 5         elapsed · tokens · cost
      band     ! NEEDS YOU, the literal request and the real grammar (only when one waits)
      life     the agent's whole life on an absolute axis, one cell per slice of it
      columns  BRIEF / WHY IT ASKS / FINDINGS │ ACTIVITY, grouped │ WHERE IT SITS, FILES, TOKENS
      composer steer <agent> only
      footer   the overlay's keys

  Under 120 columns the three columns are pages the focus ring walks (Tab).

  Everything is derived from the read model: the agent's summary, its run and
  siblings, its pending requests, and its own transcript items (tool calls,
  thoughts, what it said), plus owner S's on-demand agent detail when it is
  there (read with `Map.get` defaults: `brief`, `findings`, `life`,
  `context_used`, `context_window`, `budget`). Nothing is estimated: there
  is no ETA, no percent and no rate, and a figure the domain does not record
  is left out.

  `project/2` returns `nil` when no overlay is open, else `{regions, cursor}`
  for the projector to use instead of the shell's.
  """

  alias SwarmCodeCLI.UI.{Drafts, Keymap, SafeText, Theme, Width}
  alias SwarmCodeCLI.UI.Projector.{Density, Support}
  alias SwarmCodeCLI.UI.Reducer.Hint
  alias SwarmCodeCLI.UI.Reducer.Overlay, as: OverlayState
  alias SwarmCodeCLI.UI.Scene.{Block, Cursor, Rect, Region, Span}

  @read ~w(read_file glob view read)
  @search ~w(grep search ripgrep find rg code_search find_files)
  @explore ~w(list_dir ls git_status git_log git_diff lsp)
  @command ~w(run_command bash shell exec command)
  @write ~w(write_file edit_file edit write edit_files apply_patch multi_edit create_file)
  @spawn ~w(spawn_agent spawn start_swarm)
  @web ~w(web_search web_fetch tavily_search fetch)

  @expanded_rows 12

  # --------------------------------------------------------------- public

  @doc "The overlay's regions and cursor, or nil when it is closed."
  def project(%{overlay: nil}, _layout), do: nil

  def project(%{overlay: %{}} = state, _layout) do
    %{columns: width, rows: height} = state.size
    body = body(state, width, height)
    {composer, cursor_x} = composer(state, width)
    footer = footer(state, width)

    # The body fills what the composer (a rule, one row) and the footer leave.
    body_rows = max(0, height - 3)
    blocks = body |> Enum.take(body_rows) |> pad_rows(body_rows, state)
    rule = rule_row(state, width)
    rows = blocks ++ [rule, composer, footer]

    region = %Region{
      id: "agent-overlay",
      role: :main,
      rect: %Rect{x: 0, y: 0, width: width, height: height},
      label: SafeText.chrome(:empty),
      blocks: Enum.take(rows, height),
      focus: :active
    }

    cursor =
      if state.overlay.focus == :composer and height >= 3,
        do: %Cursor{x: min(cursor_x, width - 1), y: height - 2, shape: :bar},
        else: nil

    {[region], cursor}
  end

  @doc "How many rows the activity cursor moves over (groups, or raw operations)."
  def cursor_rows(%{overlay: %{}} = state) do
    if state.overlay.raw_ops?, do: length(raw_ops(state)), else: length(groups(state))
  end

  def cursor_rows(_state), do: 0

  @doc """
  What Enter on the activity cursor does: `{:expand, key}` for a group,
  `{:open_detail, run, ref}` for a raw operation with its whole output or
  diff on demand, nil for nothing.
  """
  def activate_target(%{overlay: %{raw_ops?: true, run_id: run}} = state, cursor) do
    case Enum.at(raw_ops(state), cursor) do
      %{ref: ref} when is_binary(ref) -> {:open_detail, run, ref}
      _ -> nil
    end
  end

  def activate_target(%{overlay: %{}} = state, cursor) do
    case Enum.at(groups(state), cursor) do
      %{key: key} -> {:expand, key}
      nil -> nil
    end
  end

  def activate_target(_state, _cursor), do: nil

  @doc "The overlay agent's transcript items, oldest first."
  def items(%{overlay: %{run_id: run, node_id: node}} = state) do
    state.read_model.transcript
    |> Map.values()
    |> Enum.filter(
      &(&1.run_id == run and &1.agent_id == node and &1.state != :superseded and
          &1.role != :user)
    )
    |> Enum.sort_by(&{&1.at, &1.created_sequence, &1.id})
  end

  def items(_state), do: []

  @doc """
  The activity, grouped (P8): consecutive reads, searches, thoughts, commands
  and edits fold into one group each; what the agent said stands alone.
  """
  def groups(state) do
    case Map.get(detail(state), :activity) do
      [_ | _] = activity -> activity |> Enum.with_index() |> Enum.map(&detail_group/1)
      _ -> derived_groups(state)
    end
    |> Kernel.++(steer_groups(state))
  end

  # pass72 G11 (QA Q12): what the user steered this agent with, from here.
  defp steer_groups(%{overlay: %{run_id: run, node_id: node}} = state) do
    state
    |> Map.get(:steers, [])
    |> Enum.filter(&match?({^run, _, ^node, _}, &1))
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.map(fn {{_, text, _, _}, index} ->
      %{
        key: "steer:#{index}",
        class: :steer,
        items: [],
        title: "you steered it",
        details: [quoted(sentence(text))],
        duration_ms: nil
      }
    end)
  end

  defp steer_groups(_state), do: []

  @detail_class %{
    read: :read,
    explore: :read,
    search: :search,
    think: :thought,
    said: :said,
    command: :command,
    edit: :edit,
    web: :web,
    agents: :spawn,
    ask: :ask,
    other: :tool
  }

  defp detail_group({group, index}) do
    class = Map.get(@detail_class, group.kind, :tool)

    details =
      cond do
        is_binary(group.quote) and group.quote != "" and class in [:thought, :said] ->
          [quoted(group.quote)]

        is_binary(group.quote) and group.quote != "" ->
          [group.quote]

        true ->
          [Enum.join(group.items, " · ")]
      end

    %{
      key: "detail:#{index}:#{group.kind}:#{group.started_at}",
      class: class,
      items: Enum.map(group.items, &%{text: &1}),
      title: group.title,
      details: Enum.reject(details, &(&1 == "")),
      duration_ms: group.duration_ms
    }
  end

  @doc "The raw operations `o` lists, oldest first, as %{name, words, ms, ref}."
  def raw_ops(state) do
    case Map.get(detail(state), :operations) do
      [_ | _] = ops ->
        Enum.map(ops, &%{name: &1.op_type, words: &1.title, ms: &1.duration_ms, ref: nil})

      _ ->
        Enum.map(items(state), fn item ->
          name =
            case item do
              %{kind: :tool, tool: %{name: name}} -> name
              %{kind: kind} -> Atom.to_string(kind)
            end

          words =
            case item do
              %{kind: :tool} -> tool_words(item)
              other -> thought(other) || ""
            end

          ref =
            case item do
              %{tool: %{diff_ref: %{id: ref}}} when is_binary(ref) -> ref
              %{detail_ref: %{id: ref}} when is_binary(ref) -> ref
              _ -> nil
            end

          %{name: name, words: words, ms: finish(item) - item.at, ref: ref}
        end)
    end
  end

  defp steps(state) do
    case Map.get(detail(state), :activity) do
      [_ | _] = activity -> activity |> Enum.map(&max(&1.count, 1)) |> Enum.sum()
      _ -> length(items(state))
    end
  end

  defp derived_groups(state) do
    state
    |> items()
    |> Enum.map(&{class(&1), &1})
    |> Enum.reject(fn {class, _} -> class == :skip end)
    |> Enum.chunk_while(
      nil,
      fn {class, item}, acc ->
        case acc do
          {^class, items} when class not in [:said, :error, :command] ->
            {:cont, {class, [item | items]}}

          nil ->
            {:cont, {class, [item]}}

          done ->
            {:cont, done, {class, [item]}}
        end
      end,
      fn
        nil -> {:cont, nil}
        acc -> {:cont, acc, nil}
      end
    )
    |> Enum.map(fn {class, items} -> group(class, Enum.reverse(items)) end)
  end

  # ------------------------------------------------------------ classify

  defp class(%{kind: :thinking}), do: :thought
  defp class(%{kind: :error}), do: :error
  defp class(%{kind: :text, role: :assistant, text: text}) when text != "", do: :said
  defp class(%{kind: :tool, tool: %{name: name}}) when name in @read, do: :read
  defp class(%{kind: :tool, tool: %{name: name}}) when name in @search, do: :search
  defp class(%{kind: :tool, tool: %{name: name}}) when name in @explore, do: :explore
  defp class(%{kind: :tool, tool: %{name: name}}) when name in @command, do: :command
  defp class(%{kind: :tool, tool: %{name: name}}) when name in @write, do: :edit
  defp class(%{kind: :tool, tool: %{name: name}}) when name in @spawn, do: :spawn
  defp class(%{kind: :tool, tool: %{name: name}}) when name in @web, do: :web
  defp class(%{kind: :tool}), do: :tool
  defp class(_item), do: :skip

  defp group(class, [first | _] = items) do
    last = List.last(items)
    started = first.at
    finished = finish(last)
    duration = if started > 0 and finished >= started, do: finished - started, else: nil
    {title, details} = describe(class, items)

    %{
      key: class_key(class) <> ":" <> first.id,
      class: class,
      items: items,
      title: title,
      details: details,
      duration_ms: duration
    }
  end

  defp class_key(class), do: Atom.to_string(class)

  defp finish(%{tool: %{finished_at: at}}) when is_integer(at), do: at

  defp finish(%{tool: %{duration_ms: ms}, at: at}) when is_integer(ms) and is_integer(at),
    do: at + ms

  defp finish(%{at: at}), do: at

  defp describe(:read, items) do
    files = items |> Enum.flat_map(&files/1) |> Enum.uniq()
    n = max(length(files), length(items))
    {"read " <> count(n, "file"), [Enum.map_join(files, " · ", &Path.basename/1)]}
  end

  defp describe(:search, items) do
    patterns = items |> Enum.map(&tool_words/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()
    {"searched " <> count(length(items), "pattern"), [Enum.map_join(patterns, "  ", &quoted/1)]}
  end

  defp describe(:thought, items) do
    latest = items |> Enum.reverse() |> Enum.find_value("", &thought/1)

    title =
      if length(items) == 1, do: "thought", else: "thought #{length(items)} times"

    {title, if(latest == "", do: [], else: [quoted(latest)])}
  end

  # pass72 G7 (QA Q8): a command says what became of it, never "ran" for
  # one that waits on you or was blocked; the tool's "run: " is not repeated.
  defp describe(:command, [item]) do
    words = command_words(item)

    case item.tool.status do
      :waiting_approval ->
        {"asked to run " <> words, ["waiting for your answer"]}

      status when status in [:running, :streaming, :retrying, :queued] ->
        {"running " <> words, []}

      :stopped ->
        {"stopped " <> words, []}

      :interrupted ->
        {"stopped " <> words, []}

      :failed ->
        {"failed: " <> words, failed_lines(item)}

      _ ->
        {"ran " <> words, command_lines(item)}
    end
  end

  defp describe(:command, items) do
    last = List.last(items)
    {"ran #{length(items)} commands", [command_words(last) | command_lines(last)]}
  end

  defp describe(:explore, items) do
    places = items |> Enum.map(&explore_words/1) |> Enum.uniq()
    {"looked around: " <> Enum.join(Enum.take(places, 3), ", "), []}
  end

  defp describe(:edit, items) do
    files = items |> Enum.flat_map(&files/1) |> Enum.uniq()
    added = items |> Enum.map(&(&1.tool.added || 0)) |> Enum.sum()
    removed = items |> Enum.map(&(&1.tool.removed || 0)) |> Enum.sum()
    stat = if added + removed > 0, do: " +#{added} −#{removed}", else: ""

    {"edited " <> count(max(length(files), 1), "file") <> stat,
     [Enum.map_join(files, " · ", &Path.basename/1)]}
  end

  defp describe(:spawn, items), do: {"started " <> count(length(items), "agent"), []}

  defp describe(:web, items) do
    {"looked up " <> count(length(items), "source"),
     [items |> Enum.map(&tool_words/1) |> Enum.join("  ")]}
  end

  defp describe(:said, [item]), do: {"said", [quoted(sentence(item.text))]}
  defp describe(:error, [item]), do: {"failed", [sentence(item.text)]}

  defp describe(:tool, items) do
    names = items |> Enum.map(&humanize(&1.tool.name)) |> Enum.uniq() |> Enum.join(", ")
    {"used " <> names <> if(length(items) > 1, do: " ×#{length(items)}", else: ""), []}
  end

  defp command_words(item) do
    case tool_words(item) do
      "run: " <> command -> command
      words -> words
    end
  end

  defp failed_lines(%{tool: tool} = item) do
    detail = if is_binary(tool.detail), do: String.trim(tool.detail), else: ""

    cond do
      detail != "" and detail != tool.title -> [detail]
      true -> command_lines(item)
    end
  end

  defp explore_words(%{tool: %{name: name}} = item) do
    case {name, tool_words(item)} do
      {"git_status", _} -> "git status"
      {"git_log", _} -> "the git log"
      {"git_diff", _} -> "the git diff"
      {"lsp", _} -> "the language server"
      {_, words} -> String.replace(words, ~r/^(list|ls)\s+/u, "") |> place()
    end
  end

  defp place(""), do: "the project"
  defp place("."), do: "the project"
  defp place("./"), do: "the project"
  defp place(path), do: path

  defp humanize(name), do: name |> String.replace(~r/[_.]+/u, " ") |> String.trim()

  defp files(%{tool: %{files: [_ | _] = files}}), do: files
  defp files(%{tool: %{title: title}}) when is_binary(title) and title != "", do: [title]
  defp files(_item), do: []

  defp tool_words(%{tool: %{title: title}}) when is_binary(title) and title != "", do: title
  defp tool_words(%{tool: %{detail: detail}}) when is_binary(detail) and detail != "", do: detail
  defp tool_words(%{tool: %{name: name}}), do: name
  defp tool_words(_item), do: ""

  defp command_lines(%{tool: tool}) do
    exit =
      case tool.exit_code do
        code when is_integer(code) and code != 0 -> ["exit #{code}"]
        _ -> []
      end

    last =
      if is_binary(tool.detail) and tool.detail != "" and tool.detail != tool.title,
        do: [tool.detail |> String.split(["\r\n", "\n"], trim: true) |> List.last() || ""],
        else: []

    last ++ exit
  end

  defp thought(%{reasoning: text}) when is_binary(text) and text != "", do: sentence(text)
  defp thought(%{text: text}) when is_binary(text) and text != "", do: sentence(text)
  defp thought(_item), do: nil

  # The first sentence, on one line.
  defp sentence(text) when is_binary(text) do
    flat = text |> String.replace(["\r\n", "\n", "\r"], " ") |> String.trim()

    case Regex.run(~r/^(.{12,}?[.!?])(\s|$)/u, flat) do
      [_, first | _] -> first
      _ -> flat
    end
  end

  defp sentence(_text), do: ""

  defp quoted(""), do: ""
  defp quoted(text), do: "“" <> text <> "”"

  defp count(1, noun), do: "1 " <> noun
  defp count(n, noun), do: "#{n} " <> noun <> "s"

  # ----------------------------------------------------------------- body

  defp body(state, width, height) do
    agent = OverlayState.agent(state)
    run = Map.get(state.read_model.runs, state.overlay.run_id)

    if agent == nil or run == nil do
      [
        line(
          state,
          [{" That agent is not in this conversation any more.", st(state, :text_muted)}],
          width
        ),
        blank(state),
        line(state, [{" Esc back to chat", st(state, :text_faint)}], width)
      ]
    else
      head =
        header(state, run, agent, width) ++
          [meta(state, run, agent, width), rule_row(state, width)]

      band = band(state, agent, width)
      life = life(state, agent, width)
      used = length(head) + length(band) + length(life) + 1
      rows = max(0, height - 3 - used)

      columns =
        if OverlayState.narrow?(state),
          do: pages(state, run, agent, width, rows),
          else: columns(state, run, agent, width, rows)

      head ++ band ++ life ++ [blank(state)] ++ columns
    end
  end

  # ------------------------------------------------------------- header

  defp header(state, run, agent, width) do
    {mark_token, mark_role} = run_mark(run)
    {glyph, word, role} = agent_state(state, agent)
    name = agent_name(agent)

    left = [
      {" ", st(state, :text_primary)},
      {Support.glyph(mark_token, state), st(state, mark_role)},
      {" " <> title(run) <> " › ", st(state, :text_muted)},
      {name, bold(state, lane_role(state, agent))},
      {"  ", st(state, :text_primary)},
      {glyph, st(state, role)},
      {" " <> word, st(state, role)}
    ]

    wide? = width >= 140
    rail = neighbours(state, agent, wide?)

    right =
      if wide?,
        do: rail ++ [{"      Esc back to chat ", st(state, :text_faint)}],
        else: rail ++ [{" ", st(state, :text_faint)}]

    [spread(state, left, right, width)]
  end

  defp neighbours(state, agent, names?) do
    agents = OverlayState.neighbours(state)

    if length(agents) < 2 do
      []
    else
      index = Enum.find_index(agents, &(&1.id == agent.id)) || 0
      prev = Enum.at(agents, Integer.mod(index - 1, length(agents)))
      next = Enum.at(agents, Integer.mod(index + 1, length(agents)))

      orbs =
        agents
        |> Enum.map(fn current ->
          {glyph, _word, role} = agent_state(state, current)
          style = if current.id == agent.id, do: bold(state, role), else: st(state, role)
          {glyph <> " ", style}
        end)

      {prev, next} =
        if names?, do: {" " <> short(prev) <> "  ", " " <> short(next)}, else: {" ", ""}

      [{"[ ‹" <> prev, st(state, :text_faint)}] ++
        orbs ++ [{next <> " › ]", st(state, :text_faint)}]
    end
  end

  defp meta(state, run, agent, width) do
    agents = OverlayState.neighbours(state)
    index = Enum.find_index(agents, &(&1.id == agent.id))

    parts =
      [
        role_word(agent),
        approval_words(state),
        agent.model || run.model,
        if(index && length(agents) > 1,
          do: ordinal(index + 1) <> " of #{length(agents)} in the run"
        )
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" · ")

    figures =
      [elapsed(state, agent), tokens_k(agent.tokens_in + agent.tokens_out), cost(agent.cost_usd)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    spread(
      state,
      [{" " <> parts, st(state, :text_muted)}],
      [{figures <> " ", st(state, :text_muted)}],
      width
    )
  end

  # --------------------------------------------------------------- band

  defp band(state, agent, width) do
    case OverlayState.request(state) do
      nil -> []
      item -> band_rows(state, agent, item, width) ++ [blank(state)]
    end
  end

  defp band_rows(state, agent, %{kind: :approval, approval: approval} = item, width) do
    focus? = state.overlay.focus == :band
    waiting = length(Hint.pending(state, item.run_id, agent.id))
    asked = asked_at(approval, item)
    age = if asked, do: "asked " <> seconds(state.now - asked) <> " ago · ", else: ""
    reason = (approval && approval.reason) || ""

    verb =
      case approval && approval.permission do
        :execute -> " wants to run a command"
        :read -> " wants to read"
        _ -> " wants to change a file"
      end

    title =
      spread(
        state,
        [
          {if(focus?, do: one_cell(state, "▌", "|"), else: " "), st(state, :accent)},
          {"! NEEDS YOU", bold(state, :warning)},
          {"   " <> agent_name(agent) <> verb, st(state, :text_primary)},
          {if(reason == "", do: "", else: "   " <> reason), st(state, :text_muted)}
        ],
        [{age <> "#{waiting} waiting ", st(state, :text_faint)}],
        width
      )

    literal = literal(approval)

    request =
      literal
      |> wrap(state, width - 6)
      |> Enum.take(3)
      |> Enum.with_index()
      |> Enum.map(fn {text, i} ->
        prefix =
          if (i == 0 and approval) && approval.permission == :execute,
            do: "    $ ",
            else: "      "

        line(state, [{prefix, st(state, :text_faint)}, {text, st(state, :text_primary)}], width)
      end)

    [title | request] ++ [grammar(state, item, width)]
  end

  defp band_rows(state, agent, %{kind: :question} = item, width) do
    focus? = state.overlay.focus == :band
    prompt = (item.question && item.question.prompt) || ""

    [
      line(
        state,
        [
          {if(focus?, do: one_cell(state, "▌", "|"), else: " "), st(state, :accent)},
          {"? ASKS YOU", bold(state, :warning)},
          {"   " <> agent_name(agent) <> " has a question", st(state, :text_primary)}
        ],
        width
      )
    ] ++
      (prompt
       |> wrap(state, width - 6)
       |> Enum.take(3)
       |> Enum.map(
         &line(state, [{"      ", st(state, :text_faint)}, {&1, st(state, :text_primary)}], width)
       )) ++
      [
        line(
          state,
          [
            {"    Enter", bold(state, :text_primary)},
            {" answer it in its card    ", st(state, :text_muted)},
            {"n", bold(state, :text_primary)},
            {" next", st(state, :text_muted)}
          ],
          width
        )
      ]
  end

  defp band_rows(_state, _agent, _item, _width), do: []

  defp literal(nil), do: ""

  defp literal(approval) do
    Enum.find(
      [approval.command, approval.arguments_preview, approval.tool],
      "",
      &(is_binary(&1) and String.trim(&1) != "")
    )
  end

  defp asked_at(%{requested_at: at}, _item) when is_integer(at) and at > 0, do: at
  defp asked_at(_approval, %{created_at: at}) when is_integer(at) and at > 0, do: at
  defp asked_at(_approval, _item), do: nil

  # The real grammar, only the decisions this request offers (K4).
  defp grammar(state, item, width) do
    offered = Keymap.decisions(item)
    family = item.approval && item.approval.command_family

    keys =
      [
        {"y", "once", :approve in offered},
        {"Y", "this run", :approve_run in offered},
        {"A", if(family, do: "always “" <> family <> "”", else: "always"),
         Enum.any?([:always_prefix, :always_allow], &(&1 in offered))},
        {"d", "deny", :deny in offered},
        {"D", "deny + stop", :deny_stop in offered},
        {"n", "next", true}
      ]
      |> Enum.filter(&elem(&1, 2))
      |> Enum.flat_map(fn {key, words, _} ->
        [{key, bold(state, :text_primary)}, {" " <> words <> "    ", st(state, :text_muted)}]
      end)

    right =
      if width >= 140,
        do: [{"letters answer while the composer is empty ", st(state, :text_faint)}],
        else: []

    spread(state, [{"    ", st(state, :text_primary)} | keys], right, width)
  end

  # --------------------------------------------------------------- life

  # The whole life on an absolute axis (R7 allows it here): one cell is an
  # equal slice of the time since the agent started, marked by the dominant
  # activity recorded in that slice.
  defp life(state, agent, width) do
    lane_width = max(8, min(120, width - 40))
    start = agent.started_at
    stop = agent.finished_at || state.now

    cells =
      case Map.get(detail(state), :life) do
        [_ | _] = life ->
          life
          |> Enum.take(lane_width)
          |> Enum.map(&if(&1 == :wait_you, do: :waiting, else: &1))

        _ ->
          derived_life(state, start, stop, lane_width)
      end

    if cells == [] do
      []
    else
      span = if is_integer(start) and stop > start, do: stop - start, else: 0
      lane = Enum.map(cells, &lane_cell(state, &1))
      thought = thought_ms(state)

      legend =
        [
          {lane_glyph(state, :think) <> " think  ", st(state, :text_faint)},
          {lane_glyph(state, :tools) <> " tools  ", st(state, :text_faint)},
          {lane_glyph(state, :write) <> " write  ", st(state, :text_faint)},
          {lane_glyph(state, :waiting) <> " on you ", st(state, :warning)}
        ]

      axis =
        [{"        0:00", st(state, :text_faint)}] ++
          [
            {String.duplicate(" ", max(1, length(cells) - 8)) <> clock(span),
             st(state, :text_faint)}
          ]

      told =
        if thought > 0 and span > 0,
          do: [
            {"   thought " <> seconds(thought) <> " of " <> clock(span), st(state, :text_faint)}
          ],
          else: []

      [
        spread(state, [{"  LIFE  ", bold(state, :text_faint)} | lane], legend, width),
        line(state, axis ++ told, width)
      ]
    end
  end

  defp derived_life(state, start, stop, cells) when is_integer(start) and stop > start do
    slice = max(1, div(stop - start + cells - 1, cells))
    marks = :array.new(cells, default: :idle)

    marks =
      Enum.reduce(items(state), marks, fn item, marks ->
        kind = lane_kind(item)
        from = item.at
        to = max(finish(item), from)

        if kind == nil or from < start do
          marks
        else
          first = min(cells - 1, div(from - start, slice))
          last = min(cells - 1, div(to - start, slice))
          Enum.reduce(first..last//1, marks, &mark(&2, &1, kind))
        end
      end)

    marks =
      case OverlayState.request(state) do
        %{created_at: at} when is_integer(at) and at >= start ->
          first = min(cells - 1, div(at - start, slice))
          last = min(cells - 1, div(state.now - start, slice))
          Enum.reduce(first..last//1, marks, &mark(&2, &1, :waiting))

        _ ->
          marks
      end

    used = min(cells, div(stop - start, slice) + 1)
    marks |> :array.to_list() |> Enum.take(used)
  end

  defp derived_life(_state, _start, _stop, _cells), do: []

  @rank %{idle: 0, think: 1, tools: 2, write: 3, waiting: 4}

  defp mark(marks, index, kind) do
    current = :array.get(index, marks)
    if @rank[kind] > @rank[current], do: :array.set(index, kind, marks), else: marks
  end

  defp lane_kind(item) do
    case class(item) do
      :thought -> :think
      :edit -> :write
      class when class in [:read, :search, :explore, :command, :spawn, :web, :tool] -> :tools
      _ -> nil
    end
  end

  defp thought_ms(state) do
    case Map.get(detail(state), :think_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> derived_thought_ms(state)
    end
  end

  defp derived_thought_ms(state) do
    state
    |> items()
    |> Enum.filter(&(class(&1) == :thought))
    |> Enum.map(&max(0, finish(&1) - &1.at))
    |> Enum.sum()
  end

  defp lane_cell(state, kind) when kind in [:idle, :think, :tools, :write, :waiting] do
    role =
      case kind do
        :waiting -> :warning
        :idle -> :text_ghost
        _ -> :text_muted
      end

    {lane_glyph(state, kind), st(state, role)}
  end

  defp lane_cell(state, _other), do: lane_cell(state, :idle)

  defp lane_glyph(state, kind) do
    {unicode, ascii} =
      case kind do
        :think -> {"▂", "_"}
        :tools -> {"▅", "="}
        :write -> {"█", "#"}
        :waiting -> {"▒", "!"}
        :idle -> {"·", "."}
      end

    one_cell(state, unicode, ascii)
  end

  # ------------------------------------------------------------ columns

  defp columns(state, run, agent, width, rows) do
    left_width = min(50, div(width * 30, 100))
    right_width = min(46, div(width * 28, 100))
    middle_width = max(10, width - left_width - right_width - 6)

    left = brief(state, run, agent, left_width - 2)
    middle = activity(state, middle_width, rows)
    right = where(state, run, agent, right_width - 2)

    sep = {" │ ", st(state, :border)}

    for index <- 0..(rows - 1)//1 do
      segments =
        [{"  ", st(state, :text_primary)}] ++
          cell(Enum.at(left, index), left_width - 2, state) ++
          [sep] ++
          cell(Enum.at(middle, index), middle_width, state) ++
          [sep] ++ cell(Enum.at(right, index), right_width - 2, state)

      line(state, segments, width)
    end
  end

  # Under 120 columns: one page at a time, named on a tab row.
  defp pages(state, run, agent, width, rows) do
    page = state.overlay.page
    names = ["brief", "activity", "where it sits"]

    tabs =
      names
      |> Enum.with_index()
      |> Enum.flat_map(fn {name, index} ->
        style =
          cond do
            index == page and state.overlay.focus == :activity -> bold(state, :accent)
            index == page -> bold(state, :text_primary)
            true -> st(state, :text_faint)
          end

        [{"  " <> if(index == page, do: "[" <> name <> "]", else: " " <> name <> " "), style}]
      end)

    content_rows = max(0, rows - 2)

    content =
      case page do
        0 -> brief(state, run, agent, width - 4)
        1 -> activity(state, width - 4, content_rows)
        _ -> where(state, run, agent, width - 4)
      end

    tab_row =
      spread(state, tabs, [{"Tab next page ", st(state, :text_faint)}], width)

    [tab_row, blank(state)] ++
      (content
       |> Enum.take(content_rows)
       |> Enum.map(&line(state, [{"  ", st(state, :text_primary)} | &1], width)))
  end

  defp cell(nil, width, state), do: [{String.duplicate(" ", width), st(state, :text_primary)}]

  defp cell(segments, width, state),
    do: state |> fit(segments, width, true) |> Enum.map(&{&1.text, &1.style})

  # BRIEF, WHY IT ASKS (in its words), LOOKING FOR (its latest thought), and
  # the numbered findings or the files it changed.
  defp brief(state, _run, agent, width) do
    detail = detail(state)
    brief = first_text([Map.get(detail, :brief), agent.title])

    brief_rows =
      if brief == "",
        do: [[{"no brief recorded", st(state, :text_faint)}]],
        else:
          brief
          |> wrap(state, width)
          |> Enum.take(6)
          |> Enum.map(&[{&1, st(state, :text_primary)}])

    asks =
      case OverlayState.request(state) do
        %{approval: %{reason: reason}} when is_binary(reason) and reason != "" ->
          [[], heading(state, "WHY IT ASKS · in its words", false)] ++
            (quoted(reason)
             |> wrap(state, width)
             |> Enum.take(4)
             |> Enum.map(&[{&1, st(state, :text_primary)}]))

        _ ->
          []
      end

    looking =
      case if(agent.state in [:running, :streaming, :retrying],
             do: latest_thought(state),
             else: ""
           ) do
        "" ->
          []

        thought ->
          [[], heading(state, "LOOKING FOR · its latest thought", false)] ++
            (thought
             |> wrap(state, width)
             |> Enum.take(3)
             |> Enum.map(&[{&1, st(state, :text_muted)}]))
      end

    [heading(state, "BRIEF · from the lead", false) | brief_rows] ++
      asks ++ looking ++ [[] | produced(state, agent, width)]
  end

  defp produced(state, agent, width) do
    findings = findings(state, agent)
    changed = changed_files(state)
    result = Map.get(detail(state), :result) || ""

    cond do
      findings != [] ->
        [heading(state, "FINDINGS", false)] ++
          (findings
           |> Enum.with_index(1)
           |> Enum.flat_map(fn {finding, n} ->
             text = Map.get(finding, :text) || ""
             ref = Map.get(finding, :ref)
             severity = Map.get(finding, :severity)

             first = [
               {Integer.to_string(n) <> "  ", bold(state, :text_primary)},
               {if(severity, do: to_string(severity) <> " ", else: ""), st(state, :warning)},
               {text, st(state, :text_primary)}
             ]

             [first | if(ref, do: [[{"   " <> ref, st(state, :info)}]], else: [])]
           end))

      changed != [] ->
        [heading(state, "CHANGES", false)] ++
          Enum.map(changed, fn {file, added, removed} ->
            stat = if added + removed > 0, do: "  +#{added} −#{removed}", else: ""
            [{Path.basename(file), st(state, :text_primary)}, {stat, st(state, :text_muted)}]
          end) ++
          [[{"o then Enter on an edit opens its diff", st(state, :text_faint)}]]

      result != "" ->
        [heading(state, "RESULT · what the lead gets", false)] ++
          (result
           |> wrap(state, width)
           |> Enum.take(12)
           |> Enum.map(&[{&1, st(state, :text_primary)}]))

      agent.state in [:done, :failed, :stopped, :interrupted] ->
        [heading(state, "FINDINGS", false), [{"none recorded", st(state, :text_faint)}]]

      true ->
        [
          heading(state, "FINDINGS", false),
          [{"none yet · the lead gets them when it ends", st(state, :text_faint)}]
        ]
    end
    |> Enum.take(20)
    |> then(fn rows -> Enum.map(rows, &clip_row(&1, state, width)) end)
  end

  defp first_text(values), do: Enum.find(values, "", &(is_binary(&1) and String.trim(&1) != ""))

  defp findings(state, agent) do
    detail = detail(state)

    case Map.get(detail, :findings) do
      [_ | _] = findings ->
        Enum.map(findings, &normalize_finding/1)

      _ when map_size(detail) > 0 ->
        []

      _ ->
        case agent.finding do
          text when is_binary(text) and text != "" ->
            refs = agent.finding_refs || []
            [%{text: text, ref: Enum.join(refs, "  "), severity: nil}]

          _ ->
            []
        end
    end
  end

  defp normalize_finding(%{} = finding),
    do: %{
      text: Map.get(finding, :text) || Map.get(finding, :title) || "",
      ref: Map.get(finding, :ref) || Map.get(finding, :location),
      severity: Map.get(finding, :severity)
    }

  defp normalize_finding(text) when is_binary(text), do: %{text: text, ref: nil, severity: nil}
  defp normalize_finding(_other), do: %{text: "", ref: nil, severity: nil}

  defp changed_files(state) do
    case Map.get(detail(state), :files_changed) do
      [_ | _] = files -> Enum.map(files, &{&1, 0, 0})
      _ -> derived_changed_files(state)
    end
  end

  defp derived_changed_files(state) do
    state
    |> items()
    |> Enum.filter(&(class(&1) == :edit))
    |> Enum.flat_map(fn item ->
      Enum.map(files(item), &{&1, item.tool.added || 0, item.tool.removed || 0})
    end)
    |> Enum.group_by(&elem(&1, 0))
    |> Enum.map(fn {file, rows} ->
      {file, rows |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
       rows |> Enum.map(&elem(&1, 2)) |> Enum.sum()}
    end)
    |> Enum.sort()
  end

  defp latest_thought(state) do
    state
    |> items()
    |> Enum.filter(&(class(&1) == :thought))
    |> Enum.reverse()
    |> Enum.find_value("", &thought/1)
  end

  # ACTIVITY: the groups, or every raw operation after `o`; the cursor row is
  # lit while the activity has the focus, and the window follows it.
  defp activity(state, width, rows) do
    focus? = state.overlay.focus == :activity
    raw? = state.overlay.raw_ops?

    title =
      if raw?,
        do: "ACTIVITY · every operation · #{length(raw_ops(state))}",
        else: "ACTIVITY · said and did · " <> count(steps(state), "step") <> ", grouped"

    head = [
      heading(state, title, focus?) ++
        [{"   o " <> if(raw?, do: "grouped", else: "raw"), st(state, :text_faint)}]
    ]

    entries = if raw?, do: raw_entries(state, width), else: group_entries(state, width)
    tail = tail_rows(state, width)
    body_rows = max(1, rows - 1 - length(tail))
    cursor = state.overlay.cursor

    # Keep the cursor's entry on screen: skip whole entries before it.
    visible = window(entries, cursor, body_rows)

    rows_out =
      visible
      |> Enum.flat_map(fn {index, lines} ->
        lit? = focus? and index == cursor

        Enum.with_index(lines)
        |> Enum.map(fn {segments, n} ->
          if lit? and n == 0, do: highlight(state, segments), else: segments
        end)
      end)
      |> Enum.take(body_rows)

    empty =
      if entries == [],
        do: [[{"nothing recorded yet", st(state, :text_faint)}]],
        else: []

    head ++ empty ++ rows_out ++ tail
  end

  defp window(entries, cursor, rows) do
    indexed = Enum.with_index(entries, fn lines, index -> {index, lines} end)
    before = Enum.take(indexed, cursor)
    from_cursor = Enum.drop(indexed, cursor)
    needed = from_cursor |> Enum.take(1) |> Enum.map(&length(elem(&1, 1))) |> Enum.sum()

    # As many entries before the cursor as fit above it.
    {kept, _} =
      before
      |> Enum.reverse()
      |> Enum.reduce({[], rows - needed}, fn {_, lines} = entry, {kept, room} ->
        if room - length(lines) >= 0 and room > 0,
          do: {[entry | kept], room - length(lines)},
          else: {kept, 0}
      end)

    kept ++ from_cursor
  end

  defp group_entries(state, width) do
    expanded = state.overlay.expanded

    Enum.map(groups(state), fn group ->
      open? = MapSet.member?(expanded, group.key)
      arrow = if group.details == [], do: " ", else: if(open?, do: "▾", else: "▸")
      arrow = one_cell(state, arrow, if(open?, do: "v", else: ">"))

      {role, marker} =
        case group.class do
          :said -> {:text_primary, "›"}
          :steer -> {:accent, "›"}
          :error -> {:error, "✗"}
          :ask -> {:warning, "!"}
          :edit -> {:success, arrow}
          _ -> {:text_primary, arrow}
        end

      marker = one_cell(state, marker, if(group.class == :error, do: "x", else: marker))

      time =
        if group.duration_ms && group.duration_ms >= 1000, do: clock(group.duration_ms), else: ""

      first =
        case group.class do
          :said ->
            [
              {marker <> " ", st(state, :text_faint)},
              {hd(group.details), st(state, :text_primary)},
              {" said", st(state, :text_faint)}
            ]

          :steer ->
            [
              {marker <> " ", st(state, :text_faint)},
              {"you: ", st(state, :accent)},
              {hd(group.details), st(state, :text_primary)}
            ]

          _ ->
            [{marker <> " ", st(state, :text_faint)}, {group.title, st(state, role)}]
        end

      first = right_align(state, first, [{time, st(state, :text_faint)}], width)

      details =
        cond do
          group.class in [:said, :steer] ->
            []

          open? ->
            expanded_details(state, group, width)

          true ->
            group.details |> Enum.take(1) |> Enum.map(&[{"  " <> &1, st(state, :text_muted)}])
        end

      [first | details]
    end)
  end

  defp expanded_details(state, group, width) do
    group.items
    |> Enum.map(fn item ->
      text =
        case {group.class, item} do
          {_, %{text: text} = item} when map_size(item) == 1 -> text
          {:thought, item} -> quoted(thought(item) || "")
          {_, item} -> tool_words(item)
        end

      [{"  " <> text, st(state, :text_muted)}]
    end)
    |> Enum.take(@expanded_rows)
    |> Enum.map(&clip_row(&1, state, width))
  end

  defp raw_entries(state, width) do
    Enum.map(raw_ops(state), fn op ->
      time = if is_integer(op.ms) and op.ms >= 1000, do: clock(op.ms), else: ""

      [
        right_align(
          state,
          [{op.name <> "  ", st(state, :text_faint)}, {op.words || "", st(state, :text_primary)}],
          [{time, st(state, :text_faint)}],
          width
        )
      ]
    end)
  end

  # The request, in time order at the bottom (linked to the band), and what
  # the agent is doing now.
  defp tail_rows(state, _width) do
    waiting =
      case OverlayState.request(state) do
        %{kind: :approval, approval: approval} = item ->
          age =
            if asked_at(approval, item),
              do: "waiting " <> seconds(state.now - asked_at(approval, item)),
              else: "waiting"

          [
            [],
            [
              {"! asked to " <> short_request(approval), st(state, :warning)},
              {"   " <> age, st(state, :text_faint)}
            ]
          ]

        %{kind: :question} ->
          [[], [{"? asked you a question", st(state, :warning)}]]

        nil ->
          []
      end

    now =
      case now_sentence(state) do
        "" -> []
        sentence -> [[{now_glyph(state) <> " now " <> sentence, st(state, :text_primary)}]]
      end

    waiting ++ now
  end

  defp short_request(%{permission: :execute} = approval), do: "run " <> literal(approval)
  defp short_request(approval), do: "change " <> literal(approval)

  defp now_sentence(state) do
    agent = OverlayState.agent(state)

    cond do
      agent == nil ->
        ""

      agent.state not in [:running, :streaming, :retrying] ->
        ""

      first_text([Map.get(detail(state), :now), agent.now]) != "" ->
        first_text([Map.get(detail(state), :now), agent.now])

      is_binary(agent.step) and agent.step != "" ->
        agent.step

      true ->
        ""
    end
  end

  defp now_glyph(state), do: one_cell(state, "●", "*")

  defp level(nil, _levels), do: 0
  defp level(parent, levels), do: Map.get(levels, parent, 0) + 1

  # WHERE IT SITS, FILES, TOKENS, CONTEXT, BUDGET (only when set).
  defp where(state, _run, agent, width) do
    agents = OverlayState.neighbours(state)

    # pass72 G2 (QA Q2): the tree is drawn from parent_id; the neighbours
    # come in pre-order, so a node's last sibling closes with ╰.
    ids = MapSet.new(agents, & &1.id)
    parent = &if(&1.parent_id in ids and &1.parent_id != &1.id, do: &1.parent_id)
    last = agents |> Enum.group_by(parent) |> Map.new(fn {k, v} -> {k, List.last(v).id} end)
    levels = Enum.reduce(agents, %{}, &Map.put(&2, &1.id, level(parent.(&1), &2)))

    tree =
      agents
      |> Enum.take(12)
      |> Enum.map(fn current ->
        {glyph, _word, role} = agent_state(state, current)
        up = parent.(current)
        indent = String.duplicate("  ", max(Map.fetch!(levels, current.id) - 1, 0))

        connector =
          cond do
            up == nil -> ""
            Map.get(last, up) == current.id -> indent <> one_cell(state, "╰", "`") <> " "
            true -> indent <> one_cell(state, "├", "|") <> " "
          end

        here = if current.id == agent.id, do: "  ‹ you are here", else: ""

        [
          {connector, st(state, :border)},
          {glyph <> " ", st(state, role)},
          {agent_name(current),
           if(current.id == agent.id,
             do: bold(state, lane_role(state, current)),
             else: st(state, :text_muted)
           )},
          {here, st(state, :accent)}
        ]
      end)

    items = items(state)

    read =
      items
      |> Enum.filter(&(class(&1) == :read))
      |> Enum.flat_map(&files/1)
      |> Enum.uniq()
      |> length()

    searched = Enum.count(items, &(class(&1) == :search))
    changed = length(changed_files(state))

    {read, searched} =
      case detail(state) do
        %{files_read: files_read, files_searched: files_searched} ->
          {length(files_read), length(files_searched)}

        _ ->
          {read, searched}
      end

    detail = detail(state)

    context =
      case {Map.get(detail, :context_used), Map.get(detail, :context_window)} do
        {used, window} when is_integer(used) and is_integer(window) and window > 0 ->
          [
            [],
            right_align(
              state,
              [{"CONTEXT", bold(state, :text_faint)}],
              [{tokens_k(used) <> " of " <> tokens_k(window), st(state, :text_primary)}],
              width
            ),
            gauge(state, used, window, min(24, width))
          ]

        _ ->
          []
      end

    budget =
      case {Map.get(detail, :turn), Map.get(detail, :max_turns)} do
        {turn, max} when is_integer(turn) and is_integer(max) and max > 0 ->
          [
            [],
            right_align(
              state,
              [{"TURNS", bold(state, :text_faint)}],
              [{"#{turn} of #{max}", st(state, :text_primary)}],
              width
            )
          ]

        _ ->
          []
      end ++
        case Map.get(detail, :budget) do
          %{used: used, limit: limit} when is_number(used) and is_number(limit) and limit > 0 ->
            [
              right_align(
                state,
                [{"BUDGET", bold(state, :text_faint)}],
                [{cost(used) <> " of " <> cost(limit), st(state, :text_primary)}],
                width
              )
            ]

          _ ->
            []
        end

    ([heading(state, "WHERE IT SITS", false)] ++
       tree ++
       [
         [],
         heading(state, "FILES", false),
         [{"#{read} read   #{searched} searched   #{changed} changed", st(state, :text_primary)}],
         [],
         right_align(
           state,
           [{"TOKENS", bold(state, :text_faint)}],
           [
             {exact(agent.tokens_in) <> " in · " <> exact(agent.tokens_out) <> " out",
              st(state, :text_primary)}
           ],
           width
         )
       ] ++ context ++ budget)
    |> Enum.map(&clip_row(&1, state, width))
  end

  defp gauge(state, used, window, cells) do
    on = min(cells, round(used / window * cells))

    [
      {String.duplicate(one_cell(state, "▰", "#"), on), st(state, :text_muted)},
      {String.duplicate(one_cell(state, "▱", "-"), cells - on), st(state, :text_ghost)}
    ]
  end

  # ------------------------------------------------------- composer, footer

  defp composer(state, width) do
    agent = OverlayState.agent(state)
    name = if agent, do: agent_name(agent), else: "this agent"
    focus? = state.overlay.focus == :composer
    key = OverlayState.draft_key(state)
    editor = Drafts.fetch(state.drafts, key).editor
    before = editor.buffer.left |> Enum.reverse() |> IO.iodata_to_binary() |> flat()
    after_text = editor.buffer.right |> IO.iodata_to_binary() |> flat()
    policy = state.capabilities.ambiguous_width
    gutter = one_cell(state, "▍", "|")
    room = max(1, width - 4)

    if before == "" and after_text == "" do
      placeholder =
        if OverlayState.request(state),
          do: "reply to #{name}, or steer it · y Y A d D n answer while this is empty",
          else: "steer #{name} only"

      {line(
         state,
         [
           {" " <> gutter, st(state, if(focus?, do: :accent, else: :text_ghost))},
           {placeholder, st(state, :text_faint)}
         ],
         width
       ), 3}
    else
      # The caret stays in view: the text before it keeps its tail.
      shown_before = tail_cells(before, room - 1, policy)
      used = Width.cells(shown_before, policy)
      {shown_after, _, _} = Width.take_cells(after_text, max(0, room - used), policy)

      {line(
         state,
         [
           {" " <> gutter, st(state, if(focus?, do: :accent, else: :text_ghost))},
           {shown_before <> shown_after, st(state, :text_primary)}
         ],
         width
       ), 3 + used}
    end
  end

  defp tail_cells(text, cells, policy) do
    if Width.cells(text, policy) <= cells do
      text
    else
      text
      |> String.graphemes()
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn g, {acc, used} ->
        w = Width.cells(g, policy)
        if used + w > cells, do: {:halt, {acc, used}}, else: {:cont, {[g | acc], used + w}}
      end)
      |> elem(0)
      |> Enum.join()
    end
  end

  defp flat(text), do: String.replace(text, ["\r\n", "\n", "\r", "\t"], " ")

  defp footer(state, width) do
    focus_words =
      if OverlayState.narrow?(state),
        do: "Tab band · pages · composer",
        else: "Tab band · activity · composer"

    keys = [
      {"Esc", "back to chat"},
      {"[ ]", "agents"},
      {"Tab", String.replace_prefix(focus_words, "Tab ", "")},
      {"Enter", if(state.overlay.focus == :composer, do: "steer", else: "expand / send")},
      {"o", if(state.overlay.raw_ops?, do: "grouped", else: "raw operations")},
      {"^F", "hints"}
    ]

    segments =
      Enum.flat_map(keys, fn {key, words} ->
        [
          {" " <> key, bold(state, :text_primary)},
          {" " <> words <> "   ", st(state, :text_faint)}
        ]
      end)

    spread(state, segments, [{"agent overlay ", st(state, :text_ghost)}], width)
  end

  defp rule_row(state, width) do
    line(state, [{String.duplicate(one_cell(state, "─", "-"), width), st(state, :border)}], width)
  end

  # ------------------------------------------------------------- helpers

  # Owner S's on-demand agent detail (`DTO.AgentDetail`), when it has arrived
  # for this agent; the reducer keeps it on the overlay.
  defp detail(%{overlay: %{node_id: node} = overlay}) do
    case Map.get(overlay, :detail) do
      %{agent_id: ^node, state: :idle} = detail -> Map.from_struct(detail)
      _ -> %{}
    end
  end

  defp detail(_state), do: %{}

  # One screen row: the segments clipped to `width`, padded to it.
  defp line(state, segments, width),
    do: %Block.RichText{spans: fit(state, segments, width, true)}

  defp blank(state), do: line(state, [], 1)

  defp pad_rows(rows, count, state),
    do: rows ++ List.duplicate(blank(state), max(0, count - length(rows)))

  defp fit(state, segments, width, pad?) do
    policy = state.capabilities.ambiguous_width

    {spans, used} =
      Enum.reduce(segments, {[], 0}, fn {text, style}, {acc, used} ->
        room = width - used
        value = if is_struct(text, SafeText), do: SafeText.value(text), else: to_string(text)
        value = if state.capabilities.ascii?, do: asciify(value), else: value

        if room <= 0 or value == "" do
          {acc, used}
        else
          safe = Density.safe(value, state, room)
          cells = Width.cells(SafeText.value(safe), policy)
          {[%Span{text: safe, style: style} | acc], used + cells}
        end
      end)

    spans = Enum.reverse(spans)

    cond do
      pad? and used < width ->
        spans ++
          [
            %Span{
              text: Density.safe(String.duplicate(" ", width - used), state, width - used),
              style: st(state, :text_primary)
            }
          ]

      spans == [] and width > 0 ->
        [%Span{text: Density.safe(" ", state, 1), style: st(state, :text_primary)}]

      true ->
        spans
    end
  end

  # Left segments, then the right ones flush with the right edge; the left
  # side gives way when both do not fit.
  defp spread(state, left, right, width) do
    right_cells = min(cells(state, right), max(0, width - 1))
    left_room = max(0, width - right_cells - 1)
    gap = %Span{text: Density.safe(" ", state, 1), style: st(state, :text_primary)}

    %Block.RichText{
      spans: fit(state, left, left_room, true) ++ [gap] ++ fit(state, right, right_cells, false)
    }
  end

  defp right_align(state, left, right, width) do
    right_cells = cells(state, right)
    left_cells = cells(state, left)

    if left_cells + right_cells + 1 <= width,
      do:
        left ++
          [{String.duplicate(" ", width - left_cells - right_cells), st(state, :text_primary)}] ++
          right,
      else: left
  end

  defp clip_row(segments, state, width),
    do: Enum.map(fit(state, segments, width, false), &{&1.text, &1.style})

  defp cells(state, segments) do
    policy = state.capabilities.ambiguous_width

    segments
    |> Enum.map(fn {text, _} ->
      value = if is_struct(text, SafeText), do: SafeText.value(text), else: to_string(text)
      Width.cells(flat(value), policy)
    end)
    |> Enum.sum()
  end

  # The ASCII tier gets ASCII punctuation too.
  @ascii_punctuation [
    {"“", "\""},
    {"”", "\""},
    {"‹", "<"},
    {"›", ">"},
    {"·", "-"},
    {"…", "..."},
    {"−", "-"},
    {"─", "-"},
    {"│", "|"}
  ]

  defp asciify(value) do
    Enum.reduce(@ascii_punctuation, value, fn {from, to}, acc -> String.replace(acc, from, to) end)
  end

  defp highlight(state, segments) do
    background = Theme.style(:hover, state.capabilities).background
    Enum.map(segments, fn {text, style} -> {text, %{style | background: background}} end)
  end

  defp heading(state, text, focus?) do
    if focus?,
      do: [{one_cell(state, "▌", "|"), st(state, :accent)}, {text, bold(state, :accent)}],
      else: [{text, bold(state, :text_faint)}]
  end

  # Word wrap; a word longer than the line is cut where it must be.
  defp wrap(text, state, width) do
    policy = state.capabilities.ambiguous_width
    width = max(1, width)

    text
    |> flat()
    |> String.split(" ", trim: true)
    |> Enum.reduce({[], "", 0}, fn word, {lines, line, used} ->
      cells = Width.cells(word, policy)

      cond do
        used == 0 and cells <= width -> {lines, word, cells}
        used + 1 + cells <= width -> {lines, line <> " " <> word, used + 1 + cells}
        cells <= width -> {[line | lines], word, cells}
        true -> long_word(word, width, policy, if(used == 0, do: lines, else: [line | lines]))
      end
    end)
    |> then(fn {lines, line, used} -> if used == 0, do: lines, else: [line | lines] end)
    |> Enum.reverse()
  end

  defp long_word(word, width, policy, lines) do
    pieces = Width.wrap(word, width, policy)
    last = List.last(pieces)
    {Enum.reverse(Enum.drop(pieces, -1)) ++ lines, last, Width.cells(last, policy)}
  end

  # Rows are measured to the cell, so monochrome's cue prefixes are left out:
  # the meaning is in the words, the `!` and the lane heights (R12).
  defp st(%{capabilities: %{color_mode: :monochrome} = caps}, role) do
    modifiers =
      cond do
        role in [:text_muted, :text_faint, :text_ghost, :border] -> [:dim]
        role in [:warning, :error, :accent] -> [:bold]
        true -> []
      end

    %{Theme.style(:plain, caps) | modifiers: modifiers, prefix: nil}
  end

  defp st(state, role), do: %{Theme.style(role, state.capabilities) | prefix: nil}

  defp bold(state, role),
    do: %{st(state, role) | modifiers: Enum.uniq([:bold | st(state, role).modifiers -- [:dim]])}

  # A glyph only where it is one cell under the terminal's width policy and
  # the terminal is not ASCII; its twin otherwise.
  defp one_cell(state, unicode, ascii) do
    if state.capabilities.ascii? or Width.cells(unicode, state.capabilities.ambiguous_width) != 1,
      do: ascii,
      else: unicode
  end

  @doc "The P3 state of an agent as {glyph, word, theme role}."
  def agent_state(state, agent) do
    p3 = if Hint.pending(state, agent.run_id, agent.id) != [], do: :needs_you, else: p3(agent)

    {unicode, ascii, word, role} =
      case p3 do
        :working -> {"●", "*", "working", :text_primary}
        :thinking -> {"◐", "~", "thinking", :text_primary}
        :waiting -> {"◌", ".", "waiting", :text_muted}
        :needs_you -> {"!", "!", "needs you", :warning}
        :done -> {"✓", "v", "done", :success}
        :failed -> {"✗", "x", "failed", :error}
        :stopped -> {"✗", "x", "stopped", :text_muted}
        :queued -> {"○", "o", "queued", :text_faint}
        :paused -> {"⏸", "=", "paused", :text_muted}
      end

    {one_cell(state, unicode, ascii), word, role}
  end

  @p3 [:working, :thinking, :waiting, :needs_you, :done, :failed, :queued, :paused]

  # Owner S's summary names the P3 state (`panel_state`, or `state` once it is
  # one of them); otherwise it follows from the run-state enum.
  defp p3(agent) do
    case {agent.panel_state, agent.state} do
      {state, _} when state in @p3 -> state
      {_, state} when state in @p3 -> state
      {_, state} when state in [:running, :streaming, :retrying] -> :working
      {_, state} when state in [:waiting_approval, :waiting_question] -> :needs_you
      {_, :paused} -> :paused
      {_, :queued} -> :queued
      {_, :done} -> :done
      {_, :stopped} -> :stopped
      {_, _} -> :failed
    end
  end

  defp agent_name(agent) do
    case agent.name do
      name when is_binary(name) and name != "" -> name
      _ -> if agent.role == :lead, do: "Lead", else: "agent"
    end
  end

  defp short(agent) do
    name = agent_name(agent)
    if String.length(name) > 16, do: String.slice(name, 0, 15) <> "…", else: name
  end

  defp lane_role(state, agent) do
    index =
      state
      |> OverlayState.neighbours()
      |> Enum.find_index(&(&1.id == agent.id))

    case index do
      nil -> :text_primary
      index -> elem(Theme.agent_lane(Integer.mod(index, 5) + 1), 1)
    end
  end

  defp run_mark(run) do
    kind =
      case run.kind do
        :chat -> :assistant
        :consensus -> :consensus_judge
        other -> other
      end

    {Theme.run_mark(kind), elem(Theme.run_kind(kind), 1)}
  end

  defp title(run) do
    case Map.get(run, :title) do
      title when is_binary(title) and title != "" -> title
      _ -> Atom.to_string(run.kind)
    end
  end

  defp role_word(%{role: :lead}), do: "lead"
  defp role_word(%{role: :judge}), do: "judge"
  defp role_word(%{role: role}) when role in [:sub, :worker], do: "worker"
  defp role_word(_agent), do: nil

  defp approval_words(state) do
    case Map.get(state.read_model.snapshots, :workspace) do
      %{} = workspace ->
        case Map.get(workspace, :approval_mode) do
          :read_only -> "read-only"
          :auto -> "auto"
          :full_access -> "full access"
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp ordinal(1), do: "1st"
  defp ordinal(2), do: "2nd"
  defp ordinal(3), do: "3rd"
  defp ordinal(n), do: "#{n}th"

  defp elapsed(state, %{started_at: start} = agent) when is_integer(start) and start > 0 do
    stop = agent.finished_at || state.now
    if stop >= start, do: clock(stop - start), else: nil
  end

  defp elapsed(_state, _agent), do: nil

  defp tokens_k(n) when is_integer(n) and n >= 1000, do: "#{div(n, 1000)}k"
  defp tokens_k(n) when is_integer(n), do: Integer.to_string(n)
  defp tokens_k(_n), do: nil

  # The exact figure, thousands apart by a space: 11 204.
  defp exact(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(" ", &Enum.join/1)
    |> String.reverse()
  end

  defp exact(_n), do: "0"

  defp cost(value) when is_number(value) and value > 0,
    do: "$" <> :erlang.float_to_binary(value * 1.0, decimals: 2)

  defp cost(_value), do: nil

  defp clock(ms) when is_integer(ms) and ms >= 0 do
    total = div(ms, 1000)
    "#{div(total, 60)}:" <> String.pad_leading(Integer.to_string(rem(total, 60)), 2, "0")
  end

  defp clock(_ms), do: "0:00"

  defp seconds(ms) when is_integer(ms) and ms >= 60_000, do: clock(ms)
  defp seconds(ms) when is_integer(ms) and ms >= 0, do: "#{div(ms, 1000)} s"
  defp seconds(_ms), do: "0 s"
end
