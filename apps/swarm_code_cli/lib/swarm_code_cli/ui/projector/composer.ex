defmodule SwarmCodeCLI.UI.Projector.Composer do
  @moduledoc false
  alias SwarmCodeCLI.UI.{
    Drafts,
    Editor,
    Intent,
    SafeText,
    SlashPalette,
    State,
    Theme,
    Width,
    WorkflowKeyword
  }

  alias SwarmCodeCLI.UI.Keymap.Bindings

  alias SwarmCodeCLI.UI.SafeText.Limits
  alias SwarmCodeCLI.UI.Scene.{Block, Cursor, Span}

  alias SwarmCodeCLI.UI.Projector.{
    ApprovalCard,
    Density,
    HiveStrip,
    KeyLabel,
    Markdown,
    RunRow,
    Support
  }

  def mode_label(state) do
    workspace = Map.get(state.read_model.snapshots, :workspace)

    case workspace && Map.get(workspace, :mode) do
      :plan -> "Plan"
      :swarm -> "Swarm"
      :ultra -> "Ultra"
      :workflow -> "Workflow"
      :consensus -> "Consensus"
      :research -> "Research"
      _ -> "Build"
    end
  end

  def label(state), do: "Composer · " <> mode_label(state)

  @doc "cli020 E2 (Q6): a mode's words on the status chip and in the help sheet."
  @spec mode_title(String.t(), String.t()) :: String.t()
  def mode_title("ultra", _label), do: "Ultra · workflows"
  def mode_title(_value, label), do: label

  def placeholder(state, width),
    do: Density.safe("Type a message, or / for commands…", state, width)

  def draft(state) do
    case State.current_draft_key(state) do
      nil -> nil
      key -> Drafts.fetch(state.drafts, key)
    end
  end

  def facts(state, width) do
    draft = draft(state)

    target =
      case draft && draft.target do
        nil -> nil
        :none -> nil
        :main -> nil
        {:reply, _} -> "Reply"
        {:thread, _} -> "Thread"
        {:revise, _} -> "Revise"
        {:chip, kind, _} -> Atom.to_string(kind)
      end

    validation =
      case draft && draft.staged_validation do
        nil -> nil
        :none -> nil
        {:pending, _} -> "pending"
        {:valid, _} -> "valid"
        {:invalid, errors} -> "ERROR " <> Enum.join(errors, ", ")
      end

    for {label, value} <- [{"Target", target}, {"Validation", validation}],
        value != nil,
        do: Support.text(label <> ": " <> value, state, width)
  end

  def actions(state, class) do
    draft = draft(state)
    workspace = Map.get(state.read_model.snapshots, :workspace)

    if draft && class not in [:compressed_small, :too_small] do
      text = Editor.text(draft.editor)
      target = if draft.target == :none, do: :main, else: draft.target
      refs = Enum.map(draft.attachments, & &1.reference)

      ready =
        Enum.all?(draft.attachments, &(&1.status == :ready)) and
          not match?({:invalid, _}, draft.staged_validation)

      allowed_actions = if workspace, do: Map.get(workspace, :allowed_actions, []), else: []

      dispatch =
        for operation <- [:send, :queue],
            operation in allowed_actions,
            intent = {:dispatch, operation, text, target, refs},
            ready and Intent.valid?(intent),
            not Map.has_key?(state.drafts.pending, draft.key),
            not Enum.any?(state.mutations, fn {_, mutation} ->
              match?({:pending, _, ^intent}, mutation)
            end) do
          Support.action(SafeText.chrome(operation), {:intent, intent})
        end

      selected = state.read_model.transcript[Map.get(state.selection, "main")]

      run =
        case {state.destination, selected} do
          {{:conversation, conversation}, %{conversation_id: conversation}} ->
            state.read_model.runs[selected.run_id]

          _ ->
            Support.run(state)
        end

      steer =
        state.read_model.transcript
        |> Enum.sort_by(fn {id, _} -> {if(selected && selected.id == id, do: 0, else: 1), id} end)
        |> Enum.filter(fn {_, node} ->
          run && elem(draft.key, 0) == run.conversation_id &&
            run.state in [:running, :streaming, :retrying] &&
            node.run_id == run.id && node.conversation_id == run.conversation_id &&
            node.state != :superseded &&
            Support.allowed?(state, run, :steer) && not Support.pending?(state, node)
        end)
        |> Enum.take(1)
        |> Enum.flat_map(fn {_, node} ->
          intent = {:steer, node.run_id, node.node_id, text, refs}

          if ready and target == :main and Intent.valid?(intent) and
               not Map.has_key?(state.drafts.pending, draft.key),
             do: [Support.action(SafeText.chrome(:steer), {:intent, intent})],
             else: []
        end)

      dispatch ++ steer
    else
      []
    end
  end

  # --- the composer slot ------------------------------------------------------------

  @doc """
  The interaction the composer slot shows instead of the draft, or nil.

  An approval waiting in this conversation (or this run) takes the slot, like
  a prompt in a chat harness: the command, where and why, and the decision
  keys. The draft is kept underneath and comes back when the approval is
  decided. The keymap uses this to route `y Y A d D n` to the card only while
  it is on screen.
  """
  def slot_interaction(state) do
    case waiting_approvals(state) do
      [item | _] -> item.id
      [] -> nil
    end
  end

  @doc """
  Pending approvals in view, oldest first; the one opened as the top layer
  leads, and one the user put aside with Esc waits until it is brought back.
  """
  def waiting_approvals(state) do
    runs = view_run_ids(state)
    opened = opened_approval(state)
    dismissed = Map.get(state, :dismissed_interactions) || []

    state.read_model.interactions
    |> Map.values()
    |> Enum.filter(fn item ->
      item.kind == :approval and item.state == :pending and
        (item.id == opened or runs == :all or item.run_id in runs) and
        (item.id == opened or not Enum.member?(dismissed, {item.id, item.expected_revision})) and
        not match?(%{state: :superseded}, Map.get(state.read_model.runs, item.run_id))
    end)
    |> Enum.sort_by(&{if(&1.id == opened, do: 0, else: 1), &1.created_at || 0, &1.id})
  end

  @doc """
  The approval opened as the top layer, when it is still pending: the
  projector draws it in the composer slot instead of a modal, so the
  conversation stays in view while the user decides.
  """
  def opened_approval(state) do
    case state.layers do
      [{:approval, id} | _] ->
        case Map.get(state.read_model.interactions, id) do
          %{kind: :approval, state: :pending} -> id
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp view_run_ids(state) do
    case state.destination do
      {:run, id} ->
        [id]

      {:conversation, id} ->
        state.read_model.runs
        |> Map.values()
        |> Enum.filter(&(&1.conversation_id == id))
        |> Enum.map(& &1.id)

      _ ->
        :all
    end
  end

  @doc "See `ApprovalCard.decisions/2`."
  defdelegate approval_decisions(state, item), to: ApprovalCard, as: :decisions

  @doc "See `ApprovalCard.facts/1`."
  defdelegate approval_facts(item), to: ApprovalCard, as: :facts

  @doc "See `ApprovalCard.title/2`."
  defdelegate approval_title(item, state), to: ApprovalCard, as: :title

  @doc """
  The row above the composer. pass73 T7 (V1): the approval card is drawn
  whole at the bottom of main with a blank row under it, so the edge row
  stays the composer's own: the workflow hint, else the hive strip, else a
  quiet hairline. pass73 G1 (QA Q1-02): a draft typed under the card that
  names "workflow" gets its hint there too, with the key that sends it
  plainly.
  """
  def edge(state, rect) do
    width = rect.width

    case ApprovalCard.layout(state, width) do
      %{edge: :composer} ->
        workflow_hint(state, width) || HiveStrip.block(state, width) || hairline(state, width)

      %{rows: rows, growth: growth} ->
        {left, right} = Enum.at(rows, growth)
        row(left, right, if(growth == 0, do: :approval, else: :approval_body), state, width)

      nil ->
        workflow_hint(state, width) || HiveStrip.block(state, width) || hairline(state, width)
    end
  end

  @doc """
  pass73 T5: while the draft names "workflow" and Enter would send it as
  `/create-workflow`, the row above the composer says so, and which key
  sends it as a plain message instead:
  `workflow · sends as /create-workflow · ^S plain message`. Nil otherwise.
  """
  def workflow_hint(state, width) do
    text = draft_text(state)

    with true <- text != "",
         :run_command <- SwarmCodeCLI.UI.Composer.enter_action(state),
         true <- WorkflowKeyword.routes?(text),
         %{} = binding <- Bindings.fetch(:send_plain),
         key when key != nil <-
           Bindings.key_in_context(binding, :composer, SwarmCodeCLI.UI.Keymap.overrides(state)) do
      label = KeyLabel.label(key, state.capabilities.ascii?)
      dot = if state.capabilities.ascii?, do: "-", else: "·"
      faint = tint(:text_faint, state)

      row(
        [
          {"  ", faint},
          {"workflow", tint(:run_workflow, state, [:bold])},
          {" " <> dot <> " sends as ", faint},
          {"/create-workflow", tint(:text_muted, state)},
          {" " <> dot <> " ", faint},
          {label, tint(:key, state, [:bold])},
          {" plain message", faint}
        ],
        [],
        nil,
        state,
        width
      )
    else
      _ -> nil
    end
  end

  defp draft_text(state) do
    case draft(state) do
      nil -> ""
      draft -> Editor.text(draft.editor)
    end
  end

  defp hairline(state, width) do
    hairline =
      Markdown.hairline(%{
        ascii?: state.capabilities.ascii?,
        policy: state.capabilities.ambiguous_width
      })

    # pass71 V5: prompts waiting behind the live turn are counted on the rule,
    # near its right end, until they start.
    label =
      case queued(state) do
        0 -> nil
        n -> " #{n} queued "
      end

    tail = 2
    label_cells = if label, do: Width.cells(label, state.capabilities.ambiguous_width), else: 0

    segments =
      if label && width >= label_cells + tail + 8,
        do: [
          {String.duplicate(hairline, width - label_cells - tail), tint(:text_ghost, state)},
          {label, tint(:warning, state, [:bold])},
          {String.duplicate(hairline, tail), tint(:text_ghost, state)}
        ],
        else: [{String.duplicate(hairline, max(1, width)), tint(:text_ghost, state)}]

    segments = with_rule_chips(segments, rule_chips(state), hairline, state)

    row(segments, [], nil, state, width)
  end

  # cli020 E15 (decisions 4c, 4i): what the draft carries, on the rule above
  # it, after two cells of rule: `$ shell` while Enter runs the draft as a
  # command (D7's rule: the first character is `!` and the rest is not
  # blank), and one chip per staged image, `[Image #1 · 412 KB]`.
  defp rule_chips(state) do
    case draft(state) do
      nil ->
        []

      draft ->
        shell =
          if shell_draft?(Editor.text(draft.editor)),
            do: [{" $ shell ", tint(:accent, state, [:bold])}],
            else: []

        images =
          draft.attachments
          |> Enum.with_index(1)
          |> Enum.map(fn {image, n} ->
            {" [Image ##{n} · #{size_words(image.byte_size)}] ", tint(:text_muted, state)}
          end)

        shell ++ images
    end
  end

  @doc false
  def shell_draft?("!" <> rest), do: String.trim(rest) != ""
  def shell_draft?(_text), do: false

  defp size_words(bytes) when is_integer(bytes) and bytes >= 1_048_576,
    do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1) <> " MB"

  defp size_words(bytes) when is_integer(bytes) and bytes >= 1_024,
    do: "#{round(bytes / 1_024)} KB"

  defp size_words(bytes) when is_integer(bytes), do: "#{bytes} B"
  defp size_words(_bytes), do: "?"

  # The chips replace the rule's cells from the third one on; the queued
  # label at the right end keeps its place, and chips that do not fit drop
  # from the last.
  defp with_rule_chips(segments, [], _hairline, _state), do: segments

  defp with_rule_chips(segments, chips, hairline, state) do
    policy = state.capabilities.ambiguous_width
    [{rule, rule_style} | rest] = segments
    rule_cells = Width.cells(rule, policy)
    lead = 2

    chips =
      chips
      |> Enum.reduce({[], 0}, fn {text, style}, {kept, used} ->
        cells = Width.cells(text, policy)

        if lead + used + cells + 1 <= rule_cells,
          do: {kept ++ [{text, style}], used + cells},
          else: {kept, used}
      end)

    case chips do
      {[], _} ->
        segments

      {kept, used} ->
        [{String.duplicate(hairline, lead), rule_style} | kept] ++
          [{String.duplicate(hairline, max(1, rule_cells - lead - used)), rule_style} | rest]
    end
  end

  @doc """
  How many prompts of the open conversation wait behind its live turn: the
  workspace snapshot's `queued` (pass71 S5), `0` when unknown.
  """
  def queued(state) do
    snapshot = state.read_model.snapshots |> Map.get(:workspace)

    case snapshot && Map.get(snapshot, :queued, 0) do
      n when is_integer(n) and n > 0 -> n
      _ -> 0
    end
  end

  # The draft is always drawn: an approval sits on the rows above it.
  def project(state, rect), do: draft_blocks(state, rect)

  # The draft, on the same card surface a sent prompt gets in the transcript.
  defp draft_blocks(state, rect) do
    draft = draft(state)
    # pass71 V1 (R3): a thin rail where the terminal draws `▏`; below the rich
    # tier the gutter keeps its stripe, the only focus cue the draft has.
    gutter_value =
      if state.capabilities.glyph_tier == :rich and not state.capabilities.ascii?,
        do: SafeText.value(Support.rail(state)),
        else: SafeText.value(Support.glyph(:composer_gutter, state))

    editor_width = max(1, rect.width - 4)
    focused? = state.focus == "composer" and state.layers == []
    gutter_style = if focused?, do: tint(:accent, state), else: tint(:text_faint, state)

    if draft do
      policy = state.capabilities.ambiguous_width
      editor_height = max(1, rect.height)
      slice = Editor.visible_slice(draft.editor, editor_width, max(1, editor_height), policy)
      limits = %{Limits.composer_viewport() | ambiguous_width: policy}

      lines =
        slice.text
        |> Density.external(limits)
        |> SafeText.value()
        |> Width.wrap(editor_width, policy)

      # Keep the caret's source context visible after control escaping expands it.
      before =
        slice.text
        |> String.graphemes()
        |> Enum.take(slice.cursor_offset)
        |> Enum.join()
        |> Density.external(limits)
        |> SafeText.value()

      prefix_lines = Width.wrap(before, editor_width, policy)
      caret_row = max(0, length(prefix_lines) - 1)
      first = max(0, caret_row - max(0, editor_height - 1))

      text_rows =
        if slice.text == "" do
          [[{placeholder_text(state), tint(:text_faint, state)}]]
        else
          lines
          |> keyword_rows(first, editor_height, draft, slice, state)
          |> command_row(first == 0 and slice.start == 0, state)
        end

      rows =
        text_rows
        |> Enum.with_index()
        |> Enum.map(fn {segments, index} ->
          lead =
            if index == 0,
              do: [{gutter_value, gutter_style}, {"  ", gutter_style}],
              else: [{"   ", gutter_style}]

          row(lead ++ segments, [], :card, state, rect.width)
        end)

      rows =
        rows ++
          List.duplicate(
            row([{" ", gutter_style}], [], :card, state, rect.width),
            max(0, rect.height - length(rows))
          )

      cursor =
        if focused? do
          %Cursor{
            x:
              rect.x + 3 +
                min(editor_width - 1, Width.cells(List.last(prefix_lines) || "", policy)),
            y: rect.y + min(editor_height - 1, caret_row - first),
            shape: :bar,
            visible?: state.terminal_focus == :gained
          }
        end

      {rows, cursor}
    else
      rows = [
        row(
          [
            {gutter_value, gutter_style},
            {"  " <> placeholder_text(state), tint(:text_faint, state)}
          ],
          [],
          :card,
          state,
          rect.width
        )
      ]

      {rows ++
         List.duplicate(
           row([{" ", gutter_style}], [], :card, state, rect.width),
           max(0, rect.height - 1)
         ), nil}
    end
  end

  # pass73 T5: the word "workflow" (K's `WorkflowKeyword`: whole word, outside
  # backticks, not in a slash command) is drawn in the workflow colour, bold,
  # in the composer. The keyword spans are found on the whole draft; the
  # drawn lines are the escaped, wrapped visible slice, so each raw
  # "workflow" letter run in the slice is matched, in order, to the same run
  # in the lines (escaping never makes or splits those letters). When the two
  # counts differ (a run cut by the wrap) the lines are drawn plain.
  @letters ~r/workflows?/i

  defp keyword_rows(lines, first, height, draft, slice, state) do
    plain = tint(:text_primary, state)
    keyword = tint(:run_workflow, state, [:bold])
    visible = lines |> Enum.drop(first) |> Enum.take(height)
    flags = keyword_flags(Editor.text(draft.editor), slice)
    count = fn some -> Enum.reduce(some, 0, &(&2 + length(Regex.scan(@letters, &1)))) end

    faint = tint(:text_faint, state)

    if Enum.any?(flags) and count.(lines) == length(flags) do
      {rows, _} =
        Enum.map_reduce(visible, Enum.drop(flags, count.(Enum.take(lines, first))), fn line,
                                                                                       flags ->
          split_line(line, flags, plain, keyword)
        end)

      rows
    else
      Enum.map(visible, &paste_segments(&1, plain, faint))
    end
  end

  # cli021 B4: the command token of a draft that starts with `/<word>` (the
  # first word, up to a space or the end of the line): a command the client or
  # the core registry knows in the accent, bold; any other word muted. Only
  # the first row of a draft whose start is on screen has one; the arguments
  # and every later row keep their colour. The text itself is not touched.
  @command_token ~r/\A(\s*)(\/[A-Za-z0-9_.-]*)(?=\s|\z)/u

  defp command_row([[{line, style} | segments] | rows], true, state) do
    case Regex.run(@command_token, line) do
      [whole, lead, token] ->
        name = String.replace_prefix(token, "/", "")

        command =
          if SlashPalette.known?(name),
            do: tint(:accent, state, [:bold]),
            else: tint(:text_muted, state)

        rest = binary_part(line, byte_size(whole), byte_size(line) - byte_size(whole))

        head =
          [{lead, style}, {token, command}, {rest, style}]
          |> Enum.reject(fn {text, _} -> text == "" end)

        [head ++ segments | rows]

      _ ->
        [[{line, style} | segments] | rows]
    end
  end

  defp command_row(rows, _top?, _state), do: rows

  # cli020 E15 (decision 4e, D8): a collapsed paste's placeholder
  # `[Pasted text #1 · 60 lines]` is one dim chip in the draft.
  @paste ~r/\[Pasted text #\d+ · \d+ lines?\]/u

  defp paste_segments(line, plain, faint) do
    case Regex.split(@paste, line, include_captures: true, trim: true) do
      [] -> [{line, plain}]
      parts -> Enum.map(parts, &{&1, if(Regex.match?(@paste, &1), do: faint, else: plain)})
    end
  end

  # One flag per raw letter run of the slice, in order: whether it is a keyword.
  defp keyword_flags(text, slice) do
    starts =
      text
      |> WorkflowKeyword.grapheme_spans()
      |> MapSet.new(fn {at, _count} -> at - slice.start end)

    @letters
    |> Regex.scan(slice.text, return: :index)
    |> Enum.map(fn [{byte, _}] ->
      MapSet.member?(starts, String.length(binary_part(slice.text, 0, byte)))
    end)
  end

  defp split_line(line, flags, plain, keyword) do
    matches = Regex.scan(@letters, line, return: :index)

    {segments, at, flags} =
      Enum.reduce(matches, {[], 0, flags}, fn [{start, length}], {acc, at, flags} ->
        {flag, rest} =
          case flags do
            [flag | rest] -> {flag, rest}
            [] -> {false, []}
          end

        before = if start > at, do: [{binary_part(line, at, start - at), plain}], else: []
        word = [{binary_part(line, start, length), if(flag, do: keyword, else: plain)}]
        {acc ++ before ++ word, start + length, rest}
      end)

    tail = byte_size(line) - at
    segments = if tail > 0, do: segments ++ [{binary_part(line, at, tail), plain}], else: segments
    {if(segments == [], do: [{line, plain}], else: segments), flags}
  end

  defp placeholder_text(state) do
    state |> placeholder(200) |> SafeText.value()
  end

  @doc """
  The slash popup: up to eight commands matching the draft (`rows`, fewer
  under an approval card), drawn by main just above the composer, the
  selected one on the hover surface with the accent rail.
  """
  def slash_popup(state, width, rows \\ SlashPalette.rows()) do
    suggestions = SlashPalette.visible(state, rows)
    entries = SlashPalette.entries(state)
    policy = state.capabilities.ambiguous_width

    # pass73 T4/T6: the selected row says what Enter does with it now (runs a
    # bare command, completes one that waits for its argument, or queues
    # `/compact` behind the running turn, as the status row says since F7).
    enter =
      case SwarmCodeCLI.UI.Projector.Status.enter_action(state) do
        :run_command -> " run"
        :complete -> " complete"
        :queue -> " queue"
        _ -> nil
      end

    # cli020 E8 (ux-live-18): the descriptions start in one column (the
    # widest `/name args` of every match, at most 2/5 of the row) and are
    # elided with `…` where the row ends.
    signature = fn item ->
      case Map.get(item, :args) do
        args when is_binary(args) and args != "" -> "  /" <> item.name <> " " <> args
        _ -> "  /" <> item.name
      end
    end

    column =
      entries
      |> Enum.map(&Width.cells(signature.(&1), policy))
      |> Enum.max(fn -> 0 end)
      |> min(max(8, div(width * 2, 5)))

    rows =
      Enum.map(suggestions, fn item ->
        name_style =
          if item.selected?,
            do: tint(:accent, state, [:bold]),
            else: tint(:text_primary, state, [:bold])

        rail =
          if item.selected?,
            do: {SafeText.value(Support.rail(state)), tint(:accent, state)},
            else: {" ", tint(:text_muted, state)}

        right =
          cond do
            item.selected? and enter != nil ->
              [{"Enter", tint(:key, state, [:bold])}, {enter, tint(:text_faint, state)}]

            item.selected? ->
              [{"Tab", tint(:key, state, [:bold])}, {" complete", tint(:text_faint, state)}]

            true ->
              []
          end

        name = "  /" <> item.name
        args = String.replace_prefix(signature.(item), name, "")
        rail_cells = Width.cells(elem(rail, 0), policy)
        {name, args} = fit_signature(name, args, column, policy)
        used = rail_cells + Width.cells(name <> args, policy)
        pad = String.duplicate(" ", max(0, column - Width.cells(name <> args, policy)))

        right_cells =
          Enum.reduce(right, 0, fn {text, _}, sum -> sum + Width.cells(text, policy) end)

        room =
          width - used - String.length(pad) - 3 - if(right == [], do: 0, else: right_cells + 2)

        # cli022 F3: an argument row's current value is a muted dot before the
        # description (a blank slot on the other rows keeps the column).
        mark = if Map.get(item, :arg?) == true, do: current_mark(item, state, policy), else: ""
        mark_cells = Width.cells(mark, policy)
        desc = item.desc || ""
        room = room - mark_cells
        desc = if room > 0, do: Width.elide(desc, room, :end, policy), else: ""

        row(
          [rail, {name, name_style}, {args <> pad, tint(:text_faint, state)}] ++
            [{"   " <> mark <> desc, tint(:text_muted, state)}],
          right,
          if(item.selected?, do: :hover, else: :popover),
          state,
          width
        )
      end)

    # The list's top rule: how many of the matches are shown, and the keys.
    if length(entries) > length(suggestions) and suggestions != [] do
      [slash_rule(length(suggestions), length(entries), state, width) | rows]
    else
      rows
    end
  end

  # `● ` on the current row, two blanks on the others; `*` where the dot is not
  # one cell (ASCII terminals, the wide ambiguous-width policy).
  defp current_mark(item, state, policy) do
    dot = if state.capabilities.ascii? or Width.cells("●", policy) != 1, do: "*", else: "●"
    if Map.get(item, :current?) == true, do: dot <> " ", else: "  "
  end

  defp fit_signature(name, args, column, policy) do
    if Width.cells(name <> args, policy) <= column,
      do: {name, args},
      else: {name, Width.elide(args, max(0, column - Width.cells(name, policy)), :end, policy)}
  end

  defp slash_rule(shown, total, state, width) do
    policy = state.capabilities.ambiguous_width
    ascii? = state.capabilities.ascii?
    {line, arrows} = if ascii?, do: {"-", "up/down"}, else: {"─", "↑↓"}
    label = " #{shown} of #{total} · #{arrows} "
    label_cells = Width.cells(label, policy)
    unit = max(1, Width.cells(line, policy))
    lead = div(max(0, width - label_cells - 2), unit)
    text = String.duplicate(line, lead) <> label

    row(
      [{text, tint(:text_faint, state)}],
      [],
      :popover,
      state,
      width
    )
  end

  @doc """
  The `@path` popup: the project files matching the token at the caret (E5's
  `Reducer.PathCompletion.visible/2` items: `title` a project-relative path,
  `matches` its matched grapheme indices, drawn bold), the selected one on
  the hover surface with the accent rail.
  """
  def path_popup(items, state, width) do
    Enum.map(items, fn item ->
      selected? = Map.get(item, :selected?, false)
      path = to_string(Map.get(item, :title) || Map.get(item, :id) || "")
      matches = item |> Map.get(:matches, []) |> List.wrap() |> MapSet.new()

      base = if selected?, do: tint(:text_primary, state), else: tint(:text_muted, state)
      hit = tint(:accent, state, [:bold])

      rail =
        if selected?,
          do: {SafeText.value(Support.rail(state)), tint(:accent, state)},
          else: {" ", tint(:text_muted, state)}

      pieces =
        path
        |> String.graphemes()
        |> Enum.with_index()
        |> Enum.chunk_by(fn {_g, i} -> MapSet.member?(matches, i) end)
        |> Enum.map(fn [{_, i} | _] = run ->
          {Enum.map_join(run, &elem(&1, 0)), if(MapSet.member?(matches, i), do: hit, else: base)}
        end)

      row(
        [rail, {"  @", tint(:text_faint, state)} | pieces],
        if(selected?,
          do: [{"Tab", tint(:key, state, [:bold])}, {" insert", tint(:text_faint, state)}],
          else: []
        ),
        if(selected?, do: :hover, else: :popover),
        state,
        width
      )
    end)
  end

  # One row as a RichText: the left spans clipped to the width, the right
  # group against the right edge when it fits, the surface filled to the edge.
  defp row(left, right, surface, state, width) do
    policy = state.capabilities.ambiguous_width
    background = surface && surface_color(surface, state)

    cells = fn spans ->
      Enum.reduce(spans, 0, fn {text, _}, sum -> sum + Width.cells(text, policy) end)
    end

    left_cells = cells.(left)
    right_cells = cells.(right)

    spans =
      cond do
        right != [] and left_cells + right_cells + 2 <= width ->
          left ++
            [
              {String.duplicate(" ", width - left_cells - right_cells - 1),
               tint(:text_primary, state)}
            ] ++ right ++ [{" ", tint(:text_primary, state)}]

        true ->
          left ++
            [{String.duplicate(" ", max(0, width - left_cells)), tint(:text_primary, state)}]
      end

    {kept, _} =
      Enum.reduce_while(spans, {[], 0}, fn {text, style}, {acc, used} ->
        c = Width.cells(text, policy)

        cond do
          text == "" ->
            {:cont, {acc, used}}

          used + c <= width ->
            {:cont, {[{text, style} | acc], used + c}}

          used >= width ->
            {:halt, {acc, used}}

          true ->
            {taken, _, taken_cells} = Width.take_cells(text, width - used, policy)
            {:halt, {[{taken, style} | acc], used + taken_cells}}
        end
      end)

    %Block.RichText{
      spans:
        kept
        |> Enum.reverse()
        |> Enum.map(fn {text, style} ->
          style =
            if background && is_nil(style.background),
              do: %{style | background: background},
              else: style

          %Span{text: Density.safe(text, state, width), style: style}
        end)
    }
  end

  defp surface_color(:approval, state), do: Theme.style(:chip_warn, state.capabilities).background
  defp surface_color(:approval_body, state), do: Theme.style(:card, state.capabilities).background
  defp surface_color(:card, state), do: Theme.style(:hover, state.capabilities).background
  defp surface_color(:hover, state), do: Theme.style(:hover, state.capabilities).background
  defp surface_color(:popover, state), do: Theme.style(:popover, state.capabilities).background

  defp tint(role, state, modifiers \\ []),
    do: %{RunRow.tinted(role, state) | background: nil, modifiers: modifiers}
end
