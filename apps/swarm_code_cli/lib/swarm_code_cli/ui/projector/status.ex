defmodule SwarmCodeCLI.UI.Projector.Status do
  @moduledoc """
  The status row: where the keys are, what the vim mode is, and the few
  bindings worth a reminder right now.

  The hints are read off `UI.Keymap.Bindings` for the current context, so a
  rebind can never leave the row advertising a key that does something else.
  How many fit is the layout class's `bindings` budget plus one, the count the
  row has always shown; a hint that would push the row past its width is
  dropped from the low-priority end before anything wraps.
  """
  alias SwarmCodeCLI.UI.{SafeText, Width}
  alias SwarmCodeCLI.UI.Keymap.{Bindings, Context}
  alias SwarmCodeCLI.UI.Scene.{Block, Span, Style}
  alias SwarmCodeCLI.UI.Projector.{Density, KeyLabel, RunRow}

  @composer_contexts [:composer, :composer_normal, :composer_visual]

  def project(state, class, width) do
    policy = state.capabilities.ambiguous_width
    context = Context.of(state)
    budget = Density.budget(class).bindings

    lead = lead_spans(state, context, width)
    showcmd = showcmd_spans(state, width)
    warning = connection_warning(state, width)
    fixed = cells(lead ++ showcmd ++ warning, policy)

    hints =
      context
      |> Bindings.hinted()
      |> Enum.take(budget + 1)
      |> Enum.flat_map(fn binding ->
        case Bindings.key_in_context(binding, context) do
          nil -> []
          key -> [{KeyLabel.label(key, state.capabilities.ascii?), binding.label}]
        end
      end)

    [
      %Block.RichText{
        spans: lead ++ showcmd ++ fit(hints, state, width - fixed, policy) ++ warning
      }
    ]
  end

  # With vim on and the composer focused the left segment is the mode, in the
  # colour of its role but without the role's text cue (a cue would print the
  # word twice in a colourless terminal). Everywhere else it is the focus.
  defp lead_spans(%{keymap: :vim} = state, context, width) when context in @composer_contexts do
    {word, role} =
      case state.vim.mode do
        :insert -> {"INSERT", :success}
        :normal -> {"NORMAL", :accent}
        :visual -> {"VISUAL", :warning}
      end

    [
      %Span{
        text: Density.safe(word, state, width),
        style: %{RunRow.tinted(role, state) | modifiers: [:bold]}
      }
    ]
  end

  defp lead_spans(state, _context, width) do
    [
      %Span{text: Density.safe("Focus: ", state, width), style: %Style{role: :text_primary}},
      %Span{text: Density.safe(state.focus, state, width), style: %Style{role: :text_primary}}
    ]
  end

  # Vim's showcmd: the count and operator typed so far, so "2d" is visible while
  # the motion is still to come.
  defp showcmd_spans(%{keymap: :vim, vim: %{count: count, pending: pending}} = state, width)
       when not (is_nil(count) and is_nil(pending)) do
    text = " " <> if(count, do: Integer.to_string(count), else: "") <> (pending || "")
    [%Span{text: Density.safe(text, state, width), style: %Style{role: :text_muted}}]
  end

  defp showcmd_spans(_state, _width), do: []

  # As many hints as fit, dropped from the weakest end; the separator, the key
  # and the label are three spans so the key alone carries the key role.
  defp fit(hints, state, available, policy) do
    spans = Enum.flat_map(hints, &hint_spans(&1, state))

    if hints == [] or cells(spans, policy) <= available,
      do: spans,
      else: fit(Enum.drop(hints, -1), state, available, policy)
  end

  defp hint_spans({key, label}, state) do
    [
      %Span{text: Density.safe("  ", state, 2), style: %Style{role: :text_primary}},
      %Span{text: Density.safe(key, state, 24), style: %Style{role: :key}},
      %Span{text: Density.safe(" " <> label, state, 24), style: %Style{role: :text_muted}}
    ]
  end

  defp cells(spans, policy),
    do:
      Enum.reduce(spans, 0, fn span, sum ->
        sum + Width.cells(SafeText.value(span.text), policy)
      end)

  defp connection_warning(state, width) do
    # Find the worst connection status across all watch slots
    worst =
      state.watches
      |> Map.values()
      |> Enum.reduce(nil, fn watch, worst ->
        case watch.status do
          :disconnected -> :disconnected
          :resyncing -> if worst == :disconnected, do: worst, else: :resyncing
          :stale -> if worst in [:disconnected, :resyncing], do: worst, else: :stale
          _ -> worst
        end
      end)

    case worst do
      :disconnected ->
        [
          %Span{text: Density.safe("  ", state, width), style: %Style{role: :text_primary}},
          %Span{text: Density.safe("disconnected", state, width), style: %Style{role: :error}}
        ]

      :resyncing ->
        [
          %Span{text: Density.safe("  ", state, width), style: %Style{role: :text_primary}},
          %Span{text: Density.safe("resyncing", state, width), style: %Style{role: :warning}}
        ]

      :stale ->
        [
          %Span{text: Density.safe("  ", state, width), style: %Style{role: :text_primary}},
          %Span{text: Density.safe("stale", state, width), style: %Style{role: :warning}}
        ]

      nil ->
        []
    end
  end

  def notice(%{notice: nil}, _width), do: []

  def notice(%{notice: {:command_feedback, text}} = state, width) when is_binary(text),
    do: [%Block.Notice{text: Density.safe(text, state, width), severity: :info}]

  def notice(state, width) do
    label =
      case state.notice do
        {kind, reason} when is_atom(kind) and is_atom(reason) ->
          Atom.to_string(kind) <> " · " <> Atom.to_string(reason)

        kind when is_atom(kind) ->
          Atom.to_string(kind)

        _ ->
          "ERROR"
      end

    label = label |> String.replace("_", " ") |> String.upcase()
    [%Block.Notice{text: Density.safe(label, state, width), severity: :error}]
  end

  def mutations(state, width) do
    state.mutations
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {_origin, mutation} ->
      key =
        case mutation do
          {:pending, _, _} ->
            :status_mutation_pending

          {:settled, _, :interrupted} ->
            :status_interrupted

          {:settled, _, outcome}
          when outcome in [
                 :accepted,
                 :needs_input,
                 :rejected,
                 :deadline_exceeded,
                 :revision_conflict,
                 :outcome_unknown
               ] ->
            outcome

          _ ->
            :empty
        end

      %Block.Notice{
        text: Density.safe(SafeText.chrome(key), state, width),
        severity: severity(key)
      }
    end)
  end

  defp severity(key)
       when key in [:rejected, :deadline_exceeded, :revision_conflict, :outcome_unknown],
       do: :error

  defp severity(:accepted), do: :success
  defp severity(_), do: :info
end
