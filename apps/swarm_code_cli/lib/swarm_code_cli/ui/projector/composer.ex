defmodule SwarmCodeCLI.UI.Projector.Composer do
  @moduledoc false
  alias SwarmCodeCLI.UI.{Drafts, Editor, Intent, SafeText, State, Width}
  alias SwarmCodeCLI.UI.SafeText.Limits
  alias SwarmCodeCLI.UI.Scene.{Block, Cursor}
  alias SwarmCodeCLI.UI.Projector.{Density, Support}

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
        nil -> "Main"
        :none -> "Main"
        :main -> "Main"
        {:reply, _} -> "Reply"
        {:thread, _} -> "Thread"
        {:revise, _} -> "Revise"
        {:chip, kind, _} -> Atom.to_string(kind)
      end

    validation =
      case draft && draft.staged_validation do
        nil -> "none"
        :none -> "none"
        {:pending, _} -> "pending"
        {:valid, _} -> "valid"
        {:invalid, errors} -> "ERROR " <> Enum.join(errors, ", ")
      end

    [
      Support.text("Target: " <> target, state, width),
      Support.text("Validation: " <> validation, state, width)
    ]
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

      dispatch =
        for operation <- [:send, :queue],
            workspace && operation in workspace.allowed_actions,
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

    if draft do
      policy = state.capabilities.ambiguous_width
      slice = Editor.visible_slice(draft.editor, rect.width, max(1, rect.height - 1), policy)
      limits = %{Limits.composer_viewport() | ambiguous_width: policy}
      safe = Density.external(slice.text, limits)
      lines = safe |> SafeText.value() |> Width.wrap(rect.width, policy)
      # Keep the caret's source context visible after control escaping expands it.
      before =
        slice.text
        |> String.graphemes()
        |> Enum.take(slice.cursor_offset)
        |> Enum.join()
        |> Density.external(limits)
        |> SafeText.value()

      prefix_lines = Width.wrap(before, rect.width, policy)
      caret_row = max(0, length(prefix_lines) - 1)
      first = max(0, caret_row - max(0, rect.height - 1))

      visible =
        lines
        |> Enum.drop(first)
        |> Enum.take(rect.height)
        |> Enum.join("\n")
        |> Density.external(limits)

      cursor =
        if state.focus == "composer" and state.layers == [] do
          %Cursor{
            x: rect.x + min(rect.width - 1, Width.cells(List.last(prefix_lines) || "", policy)),
            y: rect.y + min(rect.height - 1, caret_row - first),
            shape: :bar,
            visible?: state.terminal_focus == :gained
          }
        end

      {[
         %Block.Composer{
           text: visible,
           placeholder: Density.safe(SafeText.chrome(:composer), state, rect.width)
         }
       ], cursor}
    else
      {[
         %Block.Composer{
           text: SafeText.chrome(:empty),
           placeholder: Density.safe(SafeText.chrome(:composer), state, rect.width)
         }
       ], nil}
    end
  end
end
