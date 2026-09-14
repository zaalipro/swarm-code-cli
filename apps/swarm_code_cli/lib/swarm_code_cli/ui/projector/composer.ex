defmodule SwarmCodeCLI.UI.Projector.Composer do
  @moduledoc false
  alias SwarmCodeCLI.UI.{Drafts, Editor, Intent, SafeText, SlashPalette, State, Width}
  alias SwarmCodeCLI.UI.SafeText.Limits
  alias SwarmCodeCLI.UI.Scene.{Block, Cursor}
  alias SwarmCodeCLI.UI.Projector.{Density, Support}

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

  def project(state, rect) do
    draft = draft(state)
    # 2-cell left gutter: ▐ (accent when focused, text_faint otherwise; ASCII > )
    gutter_value = SafeText.value(Support.glyph(:composer_gutter, state))
    gutter_prefix = gutter_value <> " "
    indent = "  "
    editor_width = max(1, rect.width - 2)

    if draft do
      policy = state.capabilities.ambiguous_width
      suggestions = SlashPalette.visible(state, min(4, max(0, rect.height - 1)))
      editor_height = max(1, rect.height - length(suggestions))
      slice = Editor.visible_slice(draft.editor, editor_width, max(1, editor_height - 1), policy)
      limits = %{Limits.composer_viewport() | ambiguous_width: policy}
      safe = Density.external(slice.text, limits)
      lines = safe |> SafeText.value() |> Width.wrap(editor_width, policy)
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

      visible_lines =
        lines
        |> Enum.drop(first)
        |> Enum.take(editor_height)

      # Prepend gutter on first visible line, 2-space indent on subsequent lines.
      # When the editor is empty, leave text empty so the placeholder (with gutter) shows.
      visible =
        if slice.text != "" do
          prefixed =
            case visible_lines do
              [fl | rest] ->
                [gutter_prefix <> fl | Enum.map(rest, &(indent <> &1))]

              [] ->
                []
            end

          Density.external(Enum.join(prefixed, "\n"), limits)
        else
          Density.external("", limits)
        end

      cursor =
        if state.focus == "composer" and state.layers == [] do
          %Cursor{
            x:
              rect.x + 2 +
                min(editor_width - 1, Width.cells(List.last(prefix_lines) || "", policy)),
            y: rect.y + min(editor_height - 1, caret_row - first),
            shape: :bar,
            visible?: state.terminal_focus == :gained
          }
        end

      {[
         %Block.Composer{
           text: visible,
           placeholder: gutter_placeholder(state, editor_width, gutter_prefix)
         }
       ] ++ palette_blocks(suggestions, state, rect.width), cursor}
    else
      {[
         %Block.Composer{
           text: SafeText.chrome(:empty),
           placeholder: gutter_placeholder(state, editor_width, gutter_prefix)
         },
         Support.text("Enter send  ·  Ctrl-O newline  ·  Ctrl-K features", state, rect.width)
       ], nil}
    end
  end

  defp gutter_placeholder(state, editor_width, gutter_prefix) do
    base = SafeText.value(placeholder(state, editor_width))
    Density.safe(gutter_prefix <> base, state, editor_width + 2)
  end

  defp palette_blocks(suggestions, state, width) do
    Enum.map(suggestions, fn item ->
      marker = if item.selected?, do: "> ", else: "  "
      hint = if item.selected?, do: " [Tab]", else: ""
      Support.text(marker <> "/" <> item.name <> hint <> "  " <> item.desc, state, width)
    end)
  end
end
