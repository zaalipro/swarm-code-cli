defmodule SwarmCodeCLI.UI.Projector.Status do
  @moduledoc false
  alias SwarmCodeCLI.UI.SafeText
  alias SwarmCodeCLI.UI.Scene.{Block, Span, Style}
  alias SwarmCodeCLI.UI.Projector.Density

  def project(state, class, width) do
    bindings = Density.budget(class).bindings
    focus = state.focus

    hints =
      cond do
        focus == "composer" and bindings >= 4 ->
          [
            {"Tab", "Composer"},
            {"Enter", "Send"},
            {"Esc", "Read"},
            {"Ctrl-O", "Newline"},
            {"Ctrl-K", "Features"}
          ]

        focus == "composer" and bindings >= 3 ->
          [{"Enter", "Send"}, {"Esc", "Read"}, {"Ctrl-O", "Newline"}, {"Ctrl-K", "Features"}]

        focus == "composer" and bindings >= 2 ->
          [{"Enter", "Send"}, {"Esc", "Read"}, {"?", "Help"}]

        focus == "composer" and bindings >= 1 ->
          [{"Enter", "Send"}, {"Esc", "Read"}]

        focus == "composer" ->
          [{"?", ""}]

        # Non-composer focus
        bindings >= 4 ->
          tab = if focus == "main", do: "Type", else: "Next"
          [{"Tab", tab}, {"Enter", "Act"}, {"Ctrl-K", "Features"}, {"?", "Help"}, {"q", "Quit"}]

        bindings >= 3 ->
          tab = if focus == "main", do: "Type", else: "Next"
          [{"Tab", tab}, {"Ctrl-K", "Features"}, {"?", "Help"}, {"q", "Quit"}]

        bindings >= 2 ->
          tab = if focus == "main", do: "Type", else: "Next"
          [{"Tab", tab}, {"q", "Quit"}, {"?", "Help"}]

        bindings >= 1 ->
          tab = if focus == "main", do: "Type", else: "Next"
          [{"Tab", tab}, {"q", "Quit"}]

        true ->
          [{"?", ""}]
      end

    # Build RichText spans
    focus_spans = [
      %Span{text: Density.safe("Focus: ", state, width), style: %Style{role: :text_primary}},
      %Span{text: Density.safe(focus, state, width), style: %Style{role: :text_primary}}
    ]

    hint_spans =
      Enum.flat_map(hints, fn {key, label} ->
        sep = [%Span{text: Density.safe("  ", state, width), style: %Style{role: :text_primary}}]
        key_span = [%Span{text: Density.safe(key, state, width), style: %Style{role: :key}}]

        label_span =
          if label != "",
            do: [
              %Span{
                text: Density.safe(" " <> label, state, width),
                style: %Style{role: :text_muted}
              }
            ],
            else: []

        sep ++ key_span ++ label_span
      end)

    spans = focus_spans ++ hint_spans ++ connection_warning(state, width)

    [%Block.RichText{spans: spans}]
  end

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
