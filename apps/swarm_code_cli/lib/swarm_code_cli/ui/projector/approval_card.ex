defmodule SwarmCodeCLI.UI.Projector.ApprovalCard do
  @moduledoc """
  The approval waiting on the user, drawn where they type (plan D4/D5, ux M1):

      ▐ ! scout-1 wants to run a command                              1 of 2 waiting
      ▐   $ mix test --failed
      ▐   in lib/ · “re-run only what failed”
      ▐   y once   Y this run   A always “mix test”   d deny   D deny & stop   n next

  The keys sit on the row right above the composer and the rest of the card
  grows up into the bottom of main (by at most half of it), so the draft stays
  in view underneath: letters still type there during E's grace. A long body
  (a script, a file change, long arguments) scrolls with PgUp/PgDn through
  `selection["dialog_scroll"]`, the same selection the modal used, so the
  reducer's paging reaches every line. Only a layout with no composer falls
  back to the modal card.

  The card is data here (`layout/2`: rows of `{left, right}` styled segments
  and how many rows it takes from main); `Workspace` paints the rows it grew
  into main and `Composer.edge/2` the keys.
  """
  alias SwarmCodeCLI.UI.{ActionTarget, Layout, SafeText, Width}
  alias SwarmCodeCLI.UI.Projector.{RunRow, Support}
  alias SwarmCodeCLI.UI.Projector.Panel.Name

  # Decisions in the order the keys are read, with the key that makes each.
  # `:always_allow` is the legacy name the service reads as "for this run"
  # (C1), so it says so rather than promising to remember anything.
  @decisions [
    {:approve, "y", "once"},
    {:approve_run, "Y", "this run"},
    {:always_prefix, "A", "always"},
    {:always_allow, "A", "for this run"},
    {:deny, "d", "deny"},
    {:deny_stop, "D", "deny & stop"}
  ]

  @scroll_key "dialog_scroll"

  # --- decisions --------------------------------------------------------------------

  @doc """
  The decisions the card offers for `item`: `{decision, key, words, target}`
  for each one the daemon allows and the client can express, in key order.
  A decision already accepted stays off until the interaction moves to a new
  revision.
  """
  def decisions(state, item) do
    allowed = allowed(item)

    accepted? =
      match?(
        {:settled, _, :accepted},
        Map.get(state.mutations, {:interaction, item.id, item.expected_revision})
      )

    @decisions
    |> Enum.filter(fn {decision, _, _} -> decision in allowed end)
    |> Enum.uniq_by(fn {_, key, _} -> key end)
    |> Enum.flat_map(fn {decision, key, words} ->
      target =
        {:intent,
         {:resolve_approval, item.run_id, item.node_id, item.id, item.expected_revision, decision}}

      if not accepted? and not Support.pending?(state, item) and
           match?({:ok, _}, ActionTarget.validate(target)),
         do: [{decision, key, words, target}],
         else: []
    end)
  end

  # The service's closed list when it sends one; an older daemon's empty list
  # falls back to the interaction's permissions.
  defp allowed(item) do
    from_item = Map.get(item, :allowed_decisions)
    from_approval = if is_map(item.approval), do: Map.get(item.approval, :allowed_decisions)

    cond do
      is_list(from_item) and from_item != [] -> from_item
      is_list(from_approval) and from_approval != [] -> from_approval
      true -> item.allowed_actions || []
    end
  end

  # --- facts ------------------------------------------------------------------------

  @doc "What the approval would do, where and why, from the daemon's facts and the arguments."
  def facts(item) do
    approval = item.approval || %{}
    preview = Map.get(approval, :arguments_preview) || ""
    arguments = decode(preview)
    tool = Map.get(approval, :tool) || ""

    # A command tool whose preview is not JSON previews the command itself.
    command =
      first_present([
        Map.get(approval, :command),
        string(arguments["command"]),
        string(arguments["cmd"]),
        if(tool == "run_command" and arguments == %{}, do: preview)
      ])

    path = first_present(Enum.map(~w(path file_path file filename), &string(arguments[&1])))

    %{
      tool: tool,
      permission: Map.get(approval, :permission),
      command: command,
      path: path,
      arguments: arguments,
      preview: preview,
      subject: command || path || compact(preview),
      cwd: first_present([Map.get(approval, :cwd), string(arguments["workdir"])]),
      reason: first_present([Map.get(approval, :reason), string(arguments["justification"])]),
      family: first_present([Map.get(approval, :command_family)]),
      classification: Map.get(approval, :classification),
      agent: first_present([Map.get(approval, :agent_name)])
    }
  end

  defp decode(preview) do
    case Jason.decode(preview) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp string(value) when is_binary(value), do: value
  defp string(_), do: nil

  defp compact(text), do: text |> String.replace(~r/\s+/, " ") |> String.trim()

  defp first_present(values), do: Enum.find(values, &(is_binary(&1) and String.trim(&1) != ""))

  @doc "\"scout-1 wants to run a command\": the asking agent by name, else the plainest true thing."
  def title(item, state), do: who(item, state) <> " wants to " <> verb(facts(item))

  @doc """
  Who asks, by the one name the panel, the band and the overlay use
  (`Panel.Name`, pass73 T10): the approval's own agent, else the agent of
  the waiting op, else the plainest true thing.
  """
  def who(item, state) do
    approval = item.approval || %{}
    agent_id = Map.get(approval, :agent_id)
    fallback = first_present([Map.get(approval, :agent_name)])

    Name.for_node(state, item.run_id, agent_id, fallback) ||
      Name.for_node(state, item.run_id, item.node_id) ||
      agent_of_node(state, item) || default_speaker(state, item)
  end

  defp default_speaker(state, item) do
    case Map.get(state.read_model.runs, item.run_id) do
      %{kind: :chat} -> "The assistant"
      _ -> "An agent"
    end
  end

  # An approval sits on the op node; its agent is the transcript item's.
  defp agent_of_node(state, item) do
    state.read_model.transcript
    |> Map.values()
    |> Enum.find(&(&1.node_id == item.node_id))
    |> case do
      %{agent_id: id} when is_binary(id) ->
        case Map.get(state.read_model.agents, id) do
          %{} = agent -> Name.of(state, agent)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  @doc "What the tool would do, in words: \"run a command\", \"change a file\"."
  def verb(%{tool: "run_command"}), do: "run a command"

  def verb(%{tool: tool}) when tool in ["edit_file", "write_file", "edit_files"],
    do: "change a file"

  def verb(%{tool: "delete_file"}), do: "delete a file"
  def verb(%{tool: tool, permission: :execute}) when tool != "", do: "run " <> words(tool)
  def verb(%{tool: tool}) when tool != "", do: "use " <> words(tool)
  def verb(_), do: "do something that needs your permission"

  defp words(tool), do: String.replace(tool, "_", " ")

  # --- the body -----------------------------------------------------------------------

  # The source lines the card shows about the call, before wrapping, each with
  # its kind: the command (shell-coloured on the code surface), the file and
  # the change as a small diff, or the arguments one per line.
  defp body(facts) do
    cond do
      facts.command ->
        facts.command
        |> String.trim_trailing()
        |> String.split(["\r\n", "\n"])
        |> Enum.map(&{&1, :command})

      facts.path ->
        [{facts.path, :path}] ++ change_lines(facts.arguments)

      facts.arguments != %{} ->
        facts.arguments
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.flat_map(fn {key, value} -> argument_lines(key, value) end)

      facts.preview != "" ->
        [{compact(facts.preview), :plain}]

      true ->
        []
    end
  end

  defp change_lines(arguments) do
    edits =
      case arguments["edits"] do
        edits when is_list(edits) -> Enum.filter(edits, &is_map/1)
        _ -> [arguments]
      end

    Enum.flat_map(edits, fn edit ->
      old = string(edit["old_string"]) || string(edit["old"])
      new = string(edit["new_string"]) || string(edit["new"]) || string(edit["content"])

      marked(old, "- ", :del) ++ marked(new, "+ ", :add)
    end)
  end

  defp marked(nil, _mark, _kind), do: []

  defp marked(text, mark, kind),
    do: text |> String.split(["\r\n", "\n"]) |> Enum.map(&{mark <> &1, kind})

  defp argument_lines(key, value) when is_binary(value) do
    case String.split(value, ["\r\n", "\n"]) do
      [one] -> [{key <> ": " <> one, :plain}]
      many -> [{key <> ":", :plain} | Enum.map(many, &{"  " <> &1, :plain})]
    end
  end

  defp argument_lines(key, value) do
    case Jason.encode(value) do
      {:ok, json} -> [{key <> ": " <> json, :plain}]
      _ -> []
    end
  end

  # The card redraws on every frame, so a body past a few KiB keeps its start
  # and its end and says, in the card, how much of the middle it leaves to
  # the full arguments (the palette's "Full arguments" when the daemon sent a
  # reference). Commands and file changes are far under the budget.
  @head_bytes 3_072
  @tail_bytes 1_024

  defp bounded(lines) do
    size = Enum.reduce(lines, 0, fn {line, _}, sum -> sum + byte_size(line) + 1 end)

    if size <= @head_bytes + @tail_bytes do
      lines
    else
      head = take_lines(lines, @head_bytes, :head)
      tail = lines |> Enum.reverse() |> take_lines(@tail_bytes, :tail) |> Enum.reverse()
      kept = Enum.reduce(head ++ tail, 0, fn {line, _}, sum -> sum + byte_size(line) + 1 end)
      head ++ [{"… #{bytes(size - kept)} more", :omitted}] ++ tail
    end
  end

  defp take_lines(lines, budget, side) do
    {kept, _} =
      Enum.reduce_while(lines, {[], budget}, fn {line, kind}, {acc, left} ->
        cond do
          left <= 0 ->
            {:halt, {acc, left}}

          byte_size(line) + 1 <= left ->
            {:cont, {[{line, kind} | acc], left - byte_size(line) - 1}}

          true ->
            {:halt, {[{cut(line, left, side), kind} | acc], 0}}
        end
      end)

    Enum.reverse(kept)
  end

  # At most `bytes` of `line` from its start or its end, on a grapheme boundary.
  defp cut(line, bytes, :head) do
    line |> String.graphemes() |> take_bytes(bytes) |> Enum.join()
  end

  defp cut(line, bytes, :tail) do
    line
    |> String.graphemes()
    |> Enum.reverse()
    |> take_bytes(bytes)
    |> Enum.reverse()
    |> Enum.join()
  end

  defp take_bytes(graphemes, bytes) do
    graphemes
    |> Enum.reduce_while({[], 0}, fn g, {acc, used} ->
      if used + byte_size(g) <= bytes,
        do: {:cont, {[g | acc], used + byte_size(g)}},
        else: {:halt, {acc, used}}
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp bytes(n) when n >= 1_024, do: "#{Float.round(n / 1_024, 1)} KB"
  defp bytes(n), do: "#{n} bytes"

  # --- wrapping ----------------------------------------------------------------------

  # The body as display lines `{prefix, text, kind}` for `room` cells. A
  # command is a shell prompt: `$ ` before its first line, its other lines
  # under the command, and a line too long for the card breaks between shell
  # words (a quoted string stays whole when it fits) and goes on four cells in.
  defp display_lines(lines, room, policy) do
    lines
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{line, :command}, index} ->
        prefix = if index == 0, do: "$ ", else: "  "

        line
        |> shell_wrap(max(1, room - 2), max(1, room - 4), policy)
        |> Enum.with_index()
        |> Enum.map(fn {piece, i} -> {if(i == 0, do: prefix, else: "    "), piece, :command} end)

      {{"", kind}, _index} ->
        [{"", "", kind}]

      {{line, kind}, _index} ->
        line |> Width.wrap(max(1, room), policy) |> Enum.map(&{"", &1, kind})
    end)
  end

  @doc """
  `line` in rows of at most `first` cells, then `rest` cells, broken between
  shell words: at blanks outside quotes, and a word longer than a row is cut
  by cells. A quote left open at the end of the line (a `python3 -c "` that
  continues on the next line) does not hold the rest of the line together.
  """
  def shell_wrap(line, first, rest, policy) do
    words = shell_words(line)

    {rows, current} =
      Enum.reduce(words, {[], ""}, fn word, {rows, current} ->
        room = if rows == [], do: first, else: rest
        candidate = current <> word

        cond do
          Width.cells(candidate, policy) <= room ->
            {rows, candidate}

          String.trim(current) == "" ->
            hard(rows, candidate, room, rest, policy)

          true ->
            rows = [String.trim_trailing(current) | rows]
            word = String.trim_leading(word)

            if Width.cells(word, policy) <= rest,
              do: {rows, word},
              else: hard(rows, word, rest, rest, policy)
        end
      end)

    rows = if current == "" and rows != [], do: rows, else: [current | rows]
    Enum.reverse(rows)
  end

  # A word wider than its row, cut by cells; the last piece stays open.
  defp hard(rows, text, room, rest, policy) do
    {head, tail, _} = Width.take_cells(text, max(1, room), policy)

    if tail == "" do
      {rows, head}
    else
      hard([head | rows], tail, rest, rest, policy)
    end
  end

  # The line cut before each blank that is outside quotes; each word keeps
  # its leading blanks, so the words join back to the line. A quote with no
  # partner later on the line (a `python3 -c "` whose script follows on the
  # next lines) is an ordinary character.
  defp shell_words(line), do: split_words(String.graphemes(line), "", [])

  defp split_words([], current, words),
    do: Enum.reverse(if current == "", do: words, else: [current | words])

  defp split_words([g | rest], current, words) when g in [" ", "\t"] do
    if String.trim(current) == "",
      do: split_words(rest, current <> g, words),
      else: split_words(rest, g, [current | words])
  end

  defp split_words([g | rest], current, words) when g in ["\"", "'"] do
    case Enum.find_index(rest, &(&1 == g)) do
      nil ->
        split_words(rest, current <> g, words)

      i ->
        {quoted, after_quote} = Enum.split(rest, i + 1)
        split_words(after_quote, current <> g <> Enum.join(quoted), words)
    end
  end

  defp split_words([g | rest], current, words), do: split_words(rest, current <> g, words)

  # --- layout -------------------------------------------------------------------------

  @command_rows 6

  @doc """
  The card for the approval waiting in the composer slot, at `width` cells
  of main, or nil when there is none or no composer. pass73 T7 (the owner:
  "super ugly"): a framed card in the D2 language,

      ╭─ ! angular-plan wants to run a command ─────────────── dangerous ─╮
      │  “check the plan payload's shape before the angular client changes” │
      │                                                                      │
      │   $ cd apps/ailogic_web && curl -s http://localhost:4000/api/plans…  │
      │       | python3 -c "                                                 │
      │     import json,sys                                                  │
      │  … 5 more lines · Enter shows all                                    │
      │                                                                      │
      │   y  once    Y  this run    A  always “curl”    d  deny    D  deny …  │
      ╰─ in the project · read-only asks ───────────────── 1 of 2 · n next ─╯

  a header with the glyph, the agent, the verb and the risk word in its
  colour; the reason on its own line; the command in a code block wrapped
  between shell words, at most six lines until Enter shows all (K's
  `selection["approval_all"]`, paged with PgUp/PgDn in either form); the
  decisions as key chips with even spacing; and one blank row under it, so
  the card never touches the composer. Every row of it is drawn in main:

    * `rows` — `{left, right}` segment lists, top to bottom; the first
      `growth` rows (the card and the blank row) are drawn at the bottom of
      main, the last one is the composer's edge row (a hairline);
    * `growth` — rows the card takes from the bottom of main;
    * `window` — `{first, shown, total}` command lines, for paging;
    * `edge: :composer` — the edge row belongs to the composer.
  """
  def layout(state, width) do
    layout = Layout.for_state(state)

    with %{} <- Map.get(layout.rects, :composer),
         [item | rest] <- waiting(state) do
      build(item, rest, state, width, layout.rects.main.height)
    else
      _ -> nil
    end
  end

  @doc "Whether the card shows every line of `item` (Enter on the card, K's `approval_all`)."
  def expanded?(state, item), do: Map.get(state.selection, "approval_all") == item.id

  @doc """
  How many command lines the open card leaves out (0 when it shows them
  all), so a hint can say "Enter shows all" only when that is true.
  """
  def hidden_lines(state, width) do
    case layout(state, width) do
      %{window: {_first, shown, total}} -> max(0, total - shown)
      nil -> 0
    end
  end

  defp waiting(state), do: SwarmCodeCLI.UI.Projector.Composer.waiting_approvals(state)

  defp build(item, rest, state, width, main_rows) do
    policy = state.capabilities.ambiguous_width
    facts = facts(item)
    frame = frame(state)

    # Two cells of margin on the left, one on the right; inside the frame a
    # blank each side, and the code block pads its text by one more.
    card = max(12, width - 3)
    inner = card - 4
    room = max(1, inner - 2)

    limits = %{SafeText.Limits.content() | ambiguous_width: policy}

    lines =
      facts
      |> body()
      |> bounded()
      |> Enum.map(fn {line, kind} ->
        {line |> SwarmCodeCLI.UI.Projector.Density.external(limits) |> SafeText.value(), kind}
      end)
      |> display_lines(room, policy)

    total = length(lines)
    expanded? = expanded?(state, item)
    keys = key_rows(keys(item, facts, state), inner - 1, state)
    reason = reason_text(facts, state)

    # Rows the card may take from main: most of it, never all of it.
    budget = max(6, div(main_rows * 2, 3))
    fixed = 1 + length(keys) + 1 + 1
    limit = if expanded?, do: total, else: min(total, @command_rows)

    {spacer?, gaps?, reason?, shown} = fit(fixed, limit, total, budget)
    first = scroll(state, item, total, shown)
    more = more_words(first, shown, total, expanded?, state)
    visible = lines |> Enum.drop(first) |> Enum.take(shown)

    gap = if gaps?, do: [blank_row(frame, card, state)], else: []

    # A blank row above the card, when there is room, keeps the transcript
    # off its top border; the one under it is never given up.
    rows =
      if(spacer?, do: [separator()], else: []) ++
        [top_row(item, facts, frame, card, state)] ++
        if(reason?, do: [text_row(reason, :text_muted, frame, card, state)], else: []) ++
        gap ++
        Enum.map(visible, &code_row(&1, frame, card, state)) ++
        if(more, do: [text_row(more, :text_faint, frame, card, state)], else: []) ++
        gap ++
        Enum.map(keys, &keys_row(&1, frame, card, state)) ++
        [bottom_row(item, rest, facts, frame, card, state), separator()]

    growth = length(rows)

    %{
      item: item,
      rows: rows ++ [edge_row(state, width)],
      growth: growth,
      window: {first, shown, total},
      edge: :composer
    }
  end

  # What fits `budget` rows, as `{spacer?, gaps?, reason?, shown}`: the
  # blank row above the card goes first, then the gaps inside it, then
  # command lines down to one (with its "more" line), then the reason.
  defp fit(fixed, limit, total, budget) do
    more = fn shown -> if shown < total, do: 1, else: 0 end
    need = fn spacer, gaps, shown -> fixed + spacer + gaps + 1 + shown + more.(shown) end

    cond do
      need.(1, 2, limit) <= budget -> {true, true, true, limit}
      need.(0, 2, limit) <= budget -> {false, true, true, limit}
      need.(0, 0, limit) <= budget -> {false, false, true, limit}
      (shown = budget - fixed - 2) >= 1 -> {false, false, true, min(shown, limit)}
      true -> {false, false, false, max(1, min(limit, budget - fixed - 1))}
    end
  end

  # The command's first visible line: the page the user scrolled to while
  # the card is the open layer, else the top.
  defp scroll(state, item, total, shown) do
    first =
      case state.layers do
        [{:approval, id} | _] when id == item.id ->
          case Map.get(state.selection, @scroll_key, 0) do
            n when is_integer(n) -> n
            _ -> 0
          end

        _ ->
          0
      end

    first |> min(max(0, total - shown)) |> max(0)
  end

  defp more_words(_first, shown, total, _expanded?, _state) when shown >= total, do: nil

  defp more_words(0, shown, total, false, state) do
    n = total - shown
    "#{ellipsis(state)} #{n} more #{if n == 1, do: "line", else: "lines"} · Enter shows all"
  end

  defp more_words(first, shown, total, expanded?, state) do
    dash = if state.capabilities.ascii?, do: "-", else: "–"
    tail = if expanded?, do: "", else: " · Enter shows all"
    "lines #{first + 1}#{dash}#{first + shown} of #{total} · PgUp PgDn" <> tail
  end

  # --- rows ---------------------------------------------------------------------------

  defp frame(%{capabilities: %{ascii?: true}}),
    do: %{tl: "+", tr: "+", bl: "+", br: "+", h: "-", v: "|"}

  defp frame(state) do
    if Width.cells("╭", state.capabilities.ambiguous_width) == 1,
      do: %{tl: "╭", tr: "╮", bl: "╰", br: "╯", h: "─", v: "│"},
      else: %{tl: "⎡", tr: "⎤", bl: "⎣", br: "⎦", h: "⎯", v: "⎜"}
  end

  # `╭─ ! angular-plan wants to run a command ───── dangerous ─╮`
  defp top_row(item, facts, frame, card, state) do
    policy = state.capabilities.ambiguous_width
    border = tint(:warning, state)
    mark = SafeText.value(Support.glyph(:waiting, state))
    name = who(item, state)
    risk = risk(facts, state)
    risk_cells = segments_cells(risk, policy)

    # `╭─ ` title ` ─…─` then ` risk ─╮` or `╮`; the title gives way (from
    # its end) before the risk word does, and the rule keeps one cell.
    tail = if risk == [], do: 1, else: risk_cells + 4
    room = card - 3 - 1 - 1 - tail
    verb = " wants to " <> verb(facts)

    title =
      [
        {mark <> " ", tint(:warning, state, [:bold])},
        {name, tint(name_role(item, state), state, [:bold])},
        {verb, tint(:text_primary, state, [:bold])}
      ]
      |> clip(max(1, room), state)

    fill = max(1, card - 3 - segments_cells(title, policy) - 1 - tail)

    left =
      [{margin(), plain(state)}, {frame.tl <> frame.h <> " ", border}] ++
        title ++
        [{" " <> String.duplicate(frame.h, fill), border}] ++
        if(risk == [],
          do: [{frame.tr, border}],
          else: [{" ", border}] ++ risk ++ [{" " <> frame.h <> frame.tr, border}]
        )

    {pad(left, card + 2, state), []}
  end

  # The risk word in its colour, as a chip: "dangerous" in red, "read-only"
  # in green; nothing for an ordinary call.
  defp risk(%{classification: :dangerous}, state), do: [{" dangerous ", chip(:chip_err, state)}]
  defp risk(%{classification: :safe}, state), do: [{" read-only ", chip(:chip_ok, state)}]
  defp risk(_facts, _state), do: []

  defp text_row(text, role, frame, card, state) do
    policy = state.capabilities.ambiguous_width
    border = tint(:warning, state)
    inner = card - 4
    text = if Width.cells(text, policy) > inner - 1, do: elide(text, inner - 1, state), else: text

    left = [
      {margin(), plain(state)},
      {frame.v <> "  ", border},
      {text, tint(role, state)}
    ]

    {close(left, frame, card, state), []}
  end

  defp blank_row(frame, card, state) do
    border = tint(:warning, state)
    {close([{margin(), plain(state)}, {frame.v, border}], frame, card, state), []}
  end

  # A command line on the code block's surface: the prompt faint, the shell
  # coloured by `Syntax`, the command's first word bold.
  defp code_row({prefix, text, kind}, frame, card, state) do
    policy = state.capabilities.ambiguous_width
    border = tint(:warning, state)
    inner = card - 4
    surface = surface(state)

    body =
      case kind do
        :command -> shell_segments(prefix, text, state)
        :path -> [{text, tint(:text_primary, state, [:bold])}]
        :add -> [{text, tint(:success, state)}]
        :del -> [{text, tint(:error, state)}]
        :omitted -> [{text, tint(:text_faint, state)}]
        _ -> [{text, tint(:text_muted, state)}]
      end
      |> clip(inner - 2, state)
      |> Enum.map(fn {t, style} -> {t, %{style | background: surface}} end)

    used = segments_cells(body, policy)

    left =
      [
        {margin(), plain(state)},
        {frame.v <> " ", border},
        {" ", %{plain(state) | background: surface}}
      ] ++
        body ++
        [{String.duplicate(" ", max(0, inner - 1 - used)), %{plain(state) | background: surface}}]

    {close(left, frame, card, state), []}
  end

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
    plain: :text_primary
  }

  defp shell_segments(prefix, text, state) do
    prompt = if prefix == "", do: [], else: [{prefix, tint(:text_faint, state)}]

    tokens =
      case SwarmCodeCLI.UI.Projector.Syntax.line(text, :shell) do
        [] -> if text == "", do: [], else: [{text, :plain}]
        tokens -> tokens
      end

    # The program the line runs reads first: its first word in bold.
    {segments, _} =
      Enum.map_reduce(tokens, prefix == "$ ", fn {piece, kind}, lead? ->
        role = Map.get(@syntax, kind, :text_primary)
        word? = lead? and String.trim(piece) != ""
        mods = if word? and kind in [:plain, :keyword, :function], do: [:bold], else: []
        {{piece, tint(role, state, mods)}, lead? and not word?}
      end)

    prompt ++ segments
  end

  defp keys_row(chips, frame, card, state) do
    border = tint(:warning, state)
    left = [{margin(), plain(state)}, {frame.v <> "  ", border}] ++ chips
    {close(left, frame, card, state), []}
  end

  # `╰─ in the project · read-only asks ──────── 1 of 2 waiting · n next ─╯`
  defp bottom_row(_item, rest, facts, frame, card, state) do
    policy = state.capabilities.ambiguous_width
    border = tint(:warning, state)
    faint = tint(:text_faint, state)
    dot = {" · ", tint(:text_ghost, state)}

    info =
      [where_words(facts), policy_words(facts, state)]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&{&1, faint})
      |> Enum.intersperse(dot)

    next =
      if rest == [],
        do: [],
        else: [
          {"1 of #{length(rest) + 1} waiting", tint(:warning, state)},
          dot,
          {"n", tint(:text_primary, state, [:bold])},
          {" next", tint(:text_muted, state)}
        ]

    # `╰─` then ` info ` then the rule, then ` next ─╯` or `╯`.
    tail = if next == [], do: 1, else: segments_cells(next, policy) + 4
    info = if info == [], do: [], else: clip(info, max(0, card - 5 - tail), state)

    head =
      if info == [],
        do: [{margin(), plain(state)}, {frame.bl <> frame.h, border}],
        else:
          [{margin(), plain(state)}, {frame.bl <> frame.h <> " ", border}] ++
            info ++ [{" ", border}]

    fill = max(1, card - (segments_cells(head, policy) - 2) - tail)

    left =
      head ++
        [{String.duplicate(frame.h, fill), border}] ++
        if(next == [],
          do: [{frame.br, border}],
          else: [{" ", border}] ++ next ++ [{" " <> frame.h <> frame.br, border}]
        )

    {pad(left, card + 2, state), []}
  end

  defp separator, do: {[], []}

  # The composer's own row under the card: its hairline, as when no card is
  # up (drawn by `Composer.edge/2`, which owner V2 lets fall through to its
  # hairline for `edge: :composer`).
  defp edge_row(state, width) do
    hairline =
      SwarmCodeCLI.UI.Projector.Markdown.hairline(%{
        ascii?: state.capabilities.ascii?,
        policy: state.capabilities.ambiguous_width
      })

    {[{String.duplicate(hairline, max(1, width)), tint(:text_ghost, state)}], []}
  end

  # The frame's right side after `left`, padded to the card's width.
  defp close(left, frame, card, state) do
    policy = state.capabilities.ambiguous_width
    border = tint(:warning, state)
    used = segments_cells(left, policy) - 2
    left ++ [{String.duplicate(" ", max(0, card - used - 1)), plain(state)}, {frame.v, border}]
  end

  defp pad(left, cells, state) do
    used = segments_cells(left, state.capabilities.ambiguous_width)
    if used < cells, do: left ++ [{String.duplicate(" ", cells - used), plain(state)}], else: left
  end

  defp margin, do: "  "

  # Why it asks, on its own line: the model's own reason in quotes, else the
  # rule that made it ask.
  defp reason_text(facts, state) do
    case facts.reason do
      nil -> rule_words(facts, state)
      reason -> quoted(compact(reason), state)
    end
  end

  defp rule_words(facts, state) do
    what = if facts.permission == :execute, do: "command", else: "change"

    case approval_mode(state) do
      :read_only -> "read-only run, so every #{what} asks first"
      :auto when what == "command" -> "auto runs safe commands; this one asks first"
      :auto -> "auto asks before this change"
      _ -> permission_words(facts.permission)
    end
  end

  # The bottom border's short form of the rule, when the reason line holds
  # the model's own words.
  defp policy_words(%{reason: nil}, _state), do: nil

  defp policy_words(_facts, state) do
    case approval_mode(state) do
      :read_only -> "read-only asks"
      :auto -> "auto asks"
      _ -> nil
    end
  end

  defp where_words(%{cwd: nil}), do: nil
  defp where_words(%{cwd: cwd}), do: "in " <> cwd_words(cwd)

  defp approval_mode(state) do
    case Map.get(state.read_model.snapshots, :workspace) do
      %{} = workspace -> Map.get(workspace, :approval_mode)
      _ -> nil
    end
  end

  defp cwd_words("."), do: "the project"
  defp cwd_words(cwd), do: home(cwd)

  defp permission_words(:execute), do: "runs on your machine, in the project"
  defp permission_words(:write), do: "changes files in the project"
  defp permission_words(:read), do: "reads the project"
  defp permission_words(_), do: "needs your permission"

  # The asking agent's lane colour, as its panel row draws the name (R11).
  defp name_role(item, state) do
    approval = item.approval || %{}
    agent_id = Map.get(approval, :agent_id) || item.node_id

    siblings =
      state
      |> SwarmCodeCLI.UI.Projector.Inspector.Hive.agents(item.run_id)
      |> Enum.reject(&(&1.role in [:lead, :assistant]))

    case Enum.find_index(siblings, &(&1.id == agent_id)) do
      nil -> :text_primary
      index -> :"agent_lane_#{rem(index, 5) + 1}"
    end
  end

  # --- keys ---------------------------------------------------------------------------

  # The decisions as `{key, words, focused?}`, in key order.
  defp keys(item, facts, state) do
    state
    |> decisions(item)
    |> Enum.map(fn {decision, key, words, _target} ->
      words =
        if decision == :always_prefix and facts.family,
          do: words <> " " <> quoted(facts.family, state),
          else: words

      {key, words, focused?(state, decision)}
    end)
  end

  # Key chips with even spacing: the letter on a warm keycap, its words
  # beside it; the focused one lit whole. Keycaps with a blank each side of
  # the letter when the row holds them all, else snug keycaps, else the
  # chips wrap onto a second row.
  defp key_rows(keys, room, state) do
    policy = state.capabilities.ambiguous_width
    roomy = keys |> Enum.map(&key_chip(&1, true, state)) |> joined("    ", state)
    snug = Enum.map(keys, &key_chip(&1, false, state))

    cond do
      keys == [] -> [[]]
      segments_cells(roomy, policy) <= room -> [roomy]
      segments_cells(joined(snug, "   ", state), policy) <= room -> [joined(snug, "   ", state)]
      true -> snug |> wrap_chips(room, state) |> Enum.map(&clip(&1, room, state))
    end
  end

  defp joined(chips, gap, state),
    do: chips |> Enum.intersperse([{gap, plain(state)}]) |> List.flatten()

  defp wrap_chips(chips, room, state) do
    policy = state.capabilities.ambiguous_width

    {rows, current} =
      Enum.reduce(chips, {[], []}, fn chip, {rows, current} ->
        candidate = if current == [], do: chip, else: current ++ [{"   ", plain(state)}] ++ chip

        if current != [] and segments_cells(candidate, policy) > room,
          do: {[current | rows], chip},
          else: {rows, candidate}
      end)

    Enum.reverse(if current == [], do: rows, else: [current | rows])
  end

  defp key_chip({key, words, true}, _roomy?, state) do
    on = SwarmCodeCLI.UI.Theme.style(:on_warn, state.capabilities)

    chip = %{
      tint(:text_primary, state, [:bold])
      | foreground: on.foreground,
        background: on.background
    }

    # Monochrome has no chip colour, so the focus is spelled in brackets.
    if state.capabilities.color_mode == :monochrome,
      do: [{"[" <> key <> " " <> words <> "]", chip}],
      else: [{" " <> key <> " " <> words <> " ", chip}]
  end

  defp key_chip({key, words, false}, roomy?, state) do
    cond do
      state.capabilities.color_mode == :monochrome ->
        [
          {"[" <> key <> "]", tint(:text_primary, state, [:bold])},
          {" " <> words, tint(:text_muted, state)}
        ]

      roomy? ->
        [{" " <> key <> " ", chip(:chip_warn, state)}, {" " <> words, tint(:text_muted, state)}]

      true ->
        [{key, chip(:chip_warn, state)}, {" " <> words, tint(:text_muted, state)}]
    end
  end

  # The focus ids E's keymap gives the card's decisions (`Keymap.approval_key/3`).
  defp focused?(state, decision),
    do: state.layers != [] and state.focus == Atom.to_string(decision)

  # --- drawing the rows ----------------------------------------------------------------

  @doc """
  One row of the card as a block for main, on the canvas (the card is a
  frame, not a filled surface; only its code block carries one).
  """
  def block({left, right}, state, width) do
    policy = state.capabilities.ambiguous_width
    used = segments_cells(left, policy) + segments_cells(right, policy)

    segments =
      left ++
        if(right == [] or used + 1 > width,
          do: [],
          else: [{String.duplicate(" ", max(0, width - used - 1)), plain(state)}] ++ right
        )

    segments = clip(segments, width, state)

    %SwarmCodeCLI.UI.Scene.Block.RichText{
      spans:
        case segments do
          [] -> [span(" ", plain(state), state, width)]
          segments -> Enum.map(segments, fn {text, style} -> span(text, style, state, width) end)
        end
    }
  end

  defp span(text, style, state, width),
    do: %SwarmCodeCLI.UI.Scene.Span{
      text: SwarmCodeCLI.UI.Projector.Density.safe(text, state, max(1, width)),
      style: style
    }

  # --- helpers ------------------------------------------------------------------------

  defp segments_cells(segments, policy),
    do: Enum.reduce(segments, 0, fn {text, _}, sum -> sum + Width.cells(text, policy) end)

  # The segments cut to `cells`, the last one ending in `…` when anything
  # was cut.
  defp clip(segments, cells, state) do
    policy = state.capabilities.ambiguous_width

    if segments_cells(segments, policy) <= cells do
      segments
    else
      mark = ellipsis(state)
      room = max(0, cells - Width.cells(mark, policy))

      {kept, _} =
        Enum.reduce_while(segments, {[], 0}, fn {text, style}, {acc, used} ->
          c = Width.cells(text, policy)

          cond do
            used + c <= room ->
              {:cont, {[{text, style} | acc], used + c}}

            true ->
              {taken, _, taken_cells} = Width.take_cells(text, max(0, room - used), policy)
              {:halt, {[{taken, style} | acc], used + taken_cells}}
          end
        end)

      case kept do
        [{text, style} | rest] -> Enum.reverse([{text <> mark, style} | rest])
        [] -> [{mark, plain(state)}]
      end
    end
  end

  defp elide(text, cells, state),
    do: Width.elide(text, cells, :end, state.capabilities.ambiguous_width)

  defp home(path) do
    case System.user_home() do
      home when is_binary(home) and home != "" ->
        if String.starts_with?(path, home),
          do: "~" <> String.replace_prefix(path, home, ""),
          else: path

      _ ->
        path
    end
  end

  defp quoted(text, %{capabilities: %{ascii?: true}}), do: "\"" <> text <> "\""
  defp quoted(text, _state), do: "“" <> text <> "”"

  defp ellipsis(%{capabilities: %{ascii?: true}}), do: "..."
  defp ellipsis(_state), do: "…"

  defp plain(state), do: tint(:text_primary, state)

  defp surface(state), do: SwarmCodeCLI.UI.Theme.style(:card, state.capabilities).background

  defp chip(role, state) do
    style = SwarmCodeCLI.UI.Theme.style(role, state.capabilities)
    %{RunRow.tinted(role, state) | background: style.background, modifiers: [:bold]}
  end

  defp tint(role, state, modifiers \\ []),
    do: %{RunRow.tinted(role, state) | background: nil, modifiers: modifiers}

  @doc "The geometry the reducer pages with while the card is the open layer."
  def scroll_key, do: @scroll_key
end
