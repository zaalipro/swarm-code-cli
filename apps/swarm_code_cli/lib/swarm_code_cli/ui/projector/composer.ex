defmodule SwarmCodeCLI.UI.Projector.Composer do
  @moduledoc false
  alias SwarmCodeCLI.UI.{
    ActionTarget,
    Drafts,
    Editor,
    Intent,
    SafeText,
    SlashPalette,
    State,
    Theme,
    Width
  }

  alias SwarmCodeCLI.UI.SafeText.Limits
  alias SwarmCodeCLI.UI.Scene.{Block, Cursor, Span}
  alias SwarmCodeCLI.UI.Projector.{Density, Markdown, RunRow, Support}

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

  # Decisions in the order the keys are read, with the key that makes each.
  @decisions [
    {:approve, "y", "once"},
    {:approve_run, "Y", "this run"},
    {:always_prefix, "A", "always"},
    {:always_allow, "A", "always"},
    {:deny, "d", "deny"},
    {:deny_stop, "D", "deny & stop"}
  ]

  @doc """
  The decisions the card offers for `item`: `{decision, key, words, target}`
  for each one the daemon allows and the client can express, in key order.
  """
  def approval_decisions(state, item) do
    allowed =
      Map.get(item, :allowed_decisions) ||
        (is_map(item.approval) && Map.get(item.approval, :allowed_decisions)) ||
        item.allowed_actions || []

    # A decision the daemon already accepted stays off until the interaction
    # moves to a new revision.
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

  @doc "The command an approval would run, its family and where, from the daemon's facts."
  def approval_facts(item) do
    approval = item.approval || %{}
    preview = Map.get(approval, :arguments_preview, "") || ""
    arguments = decode(preview)

    tool = Map.get(item, :tool) || Map.get(approval, :tool) || ""

    # A command tool whose preview is not JSON previews the command itself.
    command =
      first_present([
        Map.get(item, :command),
        Map.get(approval, :command),
        arguments["command"],
        arguments["cmd"],
        if(tool == "run_command" and arguments == %{}, do: compact_preview(preview))
      ])

    path = first_present([arguments["path"], arguments["file_path"]])

    %{
      tool: tool,
      permission: Map.get(approval, :permission),
      command: command,
      path: path,
      subject: command || path || compact_preview(preview),
      cwd: first_present([Map.get(item, :cwd), Map.get(approval, :cwd)]),
      reason: first_present([Map.get(item, :reason), Map.get(approval, :reason)]),
      family:
        first_present([Map.get(item, :command_family), Map.get(approval, :command_family)]) ||
          (command && command |> String.split(" ", parts: 2) |> hd()),
      classification:
        first_present([Map.get(item, :classification), Map.get(approval, :classification)])
    }
  end

  defp decode(preview) do
    case Jason.decode(preview) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp compact_preview(preview), do: preview |> String.replace(~r/\s+/, " ") |> String.trim()

  defp first_present(values),
    do: Enum.find(values, &(is_binary(&1) and String.trim(&1) != ""))

  @doc "The row above the composer: a hairline, or the approval's title."
  def edge(state, rect) do
    width = rect.width

    case waiting_approvals(state) do
      [item | rest] ->
        title = approval_title(item, state)
        count = if rest == [], do: nil, else: "1 of #{length(rest) + 1} waiting"
        mark = SafeText.value(Support.glyph(:waiting, state))

        row(
          [
            {rail(state), tint(:warning, state)},
            {" " <> mark <> " ", tint(:warning, state, [:bold])},
            {title, tint(:text_primary, state, [:bold])}
          ],
          if(count, do: [{count, tint(:warning, state)}], else: []),
          :approval,
          state,
          width
        )

      [] ->
        hairline =
          Markdown.hairline(%{
            ascii?: state.capabilities.ascii?,
            policy: state.capabilities.ambiguous_width
          })

        row(
          [{String.duplicate(hairline, max(1, width)), tint(:text_ghost, state)}],
          [],
          nil,
          state,
          width
        )
    end
  end

  @doc "\"scout-1 wants to run a command\"."
  def approval_title(item, state) do
    agent =
      state.read_model.agents
      |> Map.get(item.node_id)
      |> then(fn
        %{name: name} when is_binary(name) and name != "" -> name
        _ -> agent_of_node(state, item) || default_speaker(state, item)
      end)

    agent <> " wants to " <> verb(approval_facts(item))
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

  defp verb(%{tool: "run_command"}), do: "run a command"

  defp verb(%{tool: tool}) when tool in ["edit_file", "write_file", "edit_files"],
    do: "change a file"

  defp verb(%{tool: "delete_file"}), do: "delete a file"
  defp verb(%{tool: tool, permission: :execute}) when tool != "", do: "run " <> words(tool)
  defp verb(%{tool: tool}) when tool != "", do: "use " <> words(tool)
  defp verb(_), do: "do something that needs your permission"

  defp words(tool), do: String.replace(tool, "_", " ")

  def project(state, rect) do
    case waiting_approvals(state) do
      [item | rest] -> {approval_card(item, rest, state, rect), nil}
      [] -> draft_blocks(state, rect)
    end
  end

  # The approval card: what would run, where and why, and the keys.
  defp approval_card(item, rest, state, rect) do
    facts = approval_facts(item)
    width = rect.width
    policy = state.capabilities.ambiguous_width

    subject =
      cond do
        facts.command -> "$ " <> facts.command
        facts.path -> facts.path
        true -> facts.subject
      end

    where =
      [
        facts.cwd && "in " <> home(facts.cwd),
        facts.classification,
        facts.reason && quoted(facts.reason, state),
        facts.permission == :write && "changes files in the project"
      ]
      |> Enum.reject(&(&1 in [nil, false, ""]))

    where = if where == [], do: [permission_words(facts.permission)], else: where

    keys =
      state
      |> approval_decisions(item)
      |> Enum.map(fn {decision, key, words, _target} ->
        words =
          if decision in [:always_prefix, :always_allow] and facts.family,
            do: words <> " " <> quoted(facts.family, state),
            else: words

        {key, words, focused_decision?(state, decision)}
      end)

    keys = if rest == [], do: keys, else: keys ++ [{"n", "next", false}]

    # The decision the arrows rest on sits on a chip; the others are plain.
    key_spans =
      keys
      |> Enum.map(fn
        {key, words, true} ->
          on = Theme.style(:on_warn, state.capabilities)
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

    subject_lines =
      subject
      |> Density.safe(state, 4_000)
      |> SafeText.value()
      |> Width.wrap(max(1, width - 4), policy)

    body_rows = max(1, rect.height - 2)
    shown = Enum.take(subject_lines, body_rows)

    subject_rows =
      Enum.map(shown, fn line ->
        row(
          [
            {rail(state), tint(:warning, state)},
            {"   " <> line, tint(:text_primary, state, [:bold])}
          ],
          [],
          :approval,
          state,
          width
        )
      end)

    rows =
      subject_rows ++
        if(rect.height - length(shown) >= 2,
          do: [
            row(
              [
                {rail(state), tint(:warning, state)},
                {"   " <> Enum.join(where, " · "), tint(:text_muted, state)}
              ],
              [],
              :approval,
              state,
              width
            )
          ],
          else: []
        ) ++
        [
          row(
            [{rail(state), tint(:warning, state)}, {"   ", tint(:text_muted, state)} | key_spans],
            [],
            :approval,
            state,
            width
          )
        ]

    Enum.take(rows, -max(1, rect.height))
  end

  # The focus ids E's keymap gives the card's decisions (`Keymap.approval_key/3`).
  defp focused_decision?(state, decision) do
    Map.get(state, :layers, []) != [] and state.focus == Atom.to_string(decision)
  end

  defp permission_words(:execute), do: "runs on your machine, in the project"
  defp permission_words(:write), do: "changes files in the project"
  defp permission_words(_), do: "needs your permission"

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

  # The draft, on the same card surface a sent prompt gets in the transcript.
  defp draft_blocks(state, rect) do
    draft = draft(state)
    gutter_value = SafeText.value(Support.glyph(:composer_gutter, state))
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
      visible_lines = lines |> Enum.drop(first) |> Enum.take(editor_height)

      text_rows =
        if slice.text == "" do
          [[{placeholder_text(state), tint(:text_faint, state)}]]
        else
          Enum.map(visible_lines, &[{&1, tint(:text_primary, state)}])
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

  defp placeholder_text(state) do
    state |> placeholder(200) |> SafeText.value()
  end

  @doc """
  The slash popup: up to eight commands matching the draft, drawn by main
  just above the composer, the selected one on the hover surface with the
  accent rail.
  """
  def slash_popup(state, width) do
    suggestions = SlashPalette.visible(state, 8)

    Enum.map(suggestions, fn item ->
      name_style =
        if item.selected?,
          do: tint(:accent, state, [:bold]),
          else: tint(:text_primary, state, [:bold])

      rail =
        if item.selected?,
          do: {SafeText.value(Support.glyph(:stripe, state)), tint(:accent, state)},
          else: {" ", tint(:text_muted, state)}

      row(
        [
          rail,
          {"  /" <> item.name, name_style},
          {"   " <> (item.desc || ""), tint(:text_muted, state)}
        ],
        if(item.selected?,
          do: [{"Tab", tint(:key, state, [:bold])}, {" complete", tint(:text_faint, state)}],
          else: []
        ),
        if(item.selected?, do: :hover, else: :popover),
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
  defp surface_color(:card, state), do: Theme.style(:hover, state.capabilities).background
  defp surface_color(:hover, state), do: Theme.style(:hover, state.capabilities).background
  defp surface_color(:popover, state), do: Theme.style(:popover, state.capabilities).background

  defp rail(state), do: SafeText.value(Support.glyph(:stripe, state))

  defp tint(role, state, modifiers \\ []),
    do: %{RunRow.tinted(role, state) | background: nil, modifiers: modifiers}
end
