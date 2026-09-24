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
  def title(item, state) do
    facts = facts(item)

    who =
      facts.agent ||
        case Map.get(state.read_model.agents, item.node_id) do
          %{name: name} when is_binary(name) and name != "" -> name
          _ -> agent_of_node(state, item) || default_speaker(state, item)
        end

    who <> " wants to " <> verb(facts)
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
          %{name: name} when is_binary(name) and name != "" -> name
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

  # The lines the card shows about the call, before wrapping: the command, or
  # the file and the change as a small diff, or the arguments one per line.
  defp body(facts) do
    cond do
      facts.command ->
        facts.command
        |> String.split(["\r\n", "\n"])
        |> Enum.with_index()
        |> Enum.map(fn {line, index} ->
          {if(index == 0, do: "$ ", else: "  ") <> line, :command}
        end)

      facts.path ->
        [{facts.path, :command}] ++ change_lines(facts.arguments)

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

  # --- layout -------------------------------------------------------------------------

  @doc """
  The card for the approval in the slot at `width` cells, or nil when there
  is none or no composer to draw it in:

    * `rows` — `{left, right}` segment lists, top to bottom; the first
      `growth` rows are drawn by main at its bottom, the next one on the edge
      row and the rest in the composer;
    * `growth` — rows the card takes from the bottom of main;
    * `window` — `{first, shown, total}` body lines, for paging.
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

  defp waiting(state), do: SwarmCodeCLI.UI.Projector.Composer.waiting_approvals(state)

  defp build(item, rest, state, width, main_rows) do
    policy = state.capabilities.ambiguous_width
    facts = facts(item)
    inner = max(1, width - 4)

    limits = %{SafeText.Limits.content() | ambiguous_width: policy}

    body =
      facts
      |> body()
      |> bounded()
      |> Enum.flat_map(fn {line, kind} ->
        line
        |> SwarmCodeCLI.UI.Projector.Density.external(limits)
        |> SafeText.value()
        |> then(&if(&1 == "", do: [""], else: Width.wrap(&1, inner, policy)))
        |> Enum.map(&{&1, kind})
      end)

    where = where(facts, state)
    total = length(body)

    # The keys sit on the row above the composer, so the draft stays in view
    # under the card; the title, the body and where it runs grow up into
    # main, by at most half of it.
    needed = 2 + total + if(where == [], do: 0, else: 1)
    rows_total = min(needed, 1 + max(2, div(main_rows, 2)))
    growth = rows_total - 1

    room = max(0, rows_total - 2)
    where_rows = if where != [] and (room - min(total, room) >= 1 or room >= 3), do: 1, else: 0
    shown = min(total, max(0, room - where_rows))
    first = scroll(state, item, total, shown)

    visible = body |> Enum.drop(first) |> Enum.take(shown)

    title = title_row(item, rest, state)
    body_rows = Enum.map(visible, &body_row(&1, state))

    more =
      if shown < total,
        do: [
          {"#{first + 1}#{if(state.capabilities.ascii?, do: "-", else: "–")}#{first + shown} of #{total} · PgDn",
           tint(:text_faint, state)}
        ],
        else: []

    where_row =
      cond do
        where_rows == 0 -> []
        true -> [{[indent(state) | where], more}]
      end

    keys = [{[indent(state) | keys(item, rest, facts, state)], []}]
    filler = List.duplicate({[{rail(state), tint(:warning, state)}], []}, rows_total)

    rows =
      [title | body_rows] ++
        where_row ++
        Enum.take(filler, max(0, rows_total - 2 - length(body_rows) - length(where_row))) ++ keys

    %{item: item, rows: rows, growth: growth, window: {first, shown, total}}
  end

  # The body's first visible line: the page the user scrolled to while the
  # card is the open layer, else the top.
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

  defp title_row(item, rest, state) do
    mark = SafeText.value(Support.glyph(:waiting, state))

    count =
      if rest == [], do: [], else: [{"1 of #{length(rest) + 1} waiting", tint(:warning, state)}]

    {[
       {rail(state), tint(:warning, state)},
       {" " <> mark <> " ", tint(:warning, state, [:bold])},
       {title(item, state), tint(:text_primary, state, [:bold])}
     ], count}
  end

  defp body_row({line, kind}, state) do
    style =
      case kind do
        :command -> tint(:text_primary, state, [:bold])
        :add -> tint(:success, state)
        :del -> tint(:error, state)
        :plain -> tint(:text_muted, state)
        :omitted -> tint(:text_faint, state)
      end

    {[indent(state), {line, style}], []}
  end

  defp indent(state), do: {rail(state) <> "   ", tint(:warning, state)}

  # Where it runs, how the service classes it and why the model wants it.
  defp where(facts, state) do
    parts =
      [
        facts.cwd && {"in " <> cwd_words(facts.cwd), tint(:text_muted, state)},
        case facts.classification do
          :dangerous -> {"dangerous", tint(:error, state, [:bold])}
          :safe -> {"read-only", tint(:success, state)}
          _ -> nil
        end,
        facts.reason && {quoted(facts.reason, state), tint(:text_muted, state)}
      ]
      |> Enum.reject(&is_nil/1)

    parts =
      if parts == [],
        do: [{permission_words(facts.permission), tint(:text_muted, state)}],
        else: parts

    Enum.intersperse(parts, {" · ", tint(:text_ghost, state)})
  end

  defp cwd_words("."), do: "the project"
  defp cwd_words(cwd), do: home(cwd)

  defp permission_words(:execute), do: "runs on your machine, in the project"
  defp permission_words(:write), do: "changes files in the project"
  defp permission_words(:read), do: "reads the project"
  defp permission_words(_), do: "needs your permission"

  defp keys(item, rest, facts, state) do
    keys =
      state
      |> decisions(item)
      |> Enum.map(fn {decision, key, words, _target} ->
        words =
          if decision == :always_prefix and facts.family,
            do: words <> " " <> quoted(facts.family, state),
            else: words

        {key, words, focused?(state, decision)}
      end)

    keys = if rest == [], do: keys, else: keys ++ [{"n", "next", false}]

    keys
    |> Enum.map(fn
      {key, words, true} ->
        on = SwarmCodeCLI.UI.Theme.style(:on_warn, state.capabilities)
        chip = %{tint(:text_primary, state, [:bold]) | foreground: on.foreground}
        chip = %{chip | background: on.background}

        # Monochrome has no chip colour, so the focus is spelled in brackets.
        if state.capabilities.color_mode == :monochrome,
          do: [{"[" <> key <> " " <> words <> "]", chip}],
          else: [{" " <> key <> " " <> words <> " ", chip}]

      {key, words, false} ->
        [{key, tint(:key, state, [:bold])}, {" " <> words, tint(:text_muted, state)}]
    end)
    |> Enum.intersperse([{"   ", tint(:text_muted, state)}])
    |> List.flatten()
  end

  # The focus ids E's keymap gives the card's decisions (`Keymap.approval_key/3`).
  defp focused?(state, decision),
    do: state.layers != [] and state.focus == Atom.to_string(decision)

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

  defp rail(state), do: SafeText.value(Support.rail(state))

  defp tint(role, state, modifiers \\ []),
    do: %{RunRow.tinted(role, state) | background: nil, modifiers: modifiers}

  @doc "The geometry the reducer pages with while the card is the open layer."
  def scroll_key, do: @scroll_key
end
