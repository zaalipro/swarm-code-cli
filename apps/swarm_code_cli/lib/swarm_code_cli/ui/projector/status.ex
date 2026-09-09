defmodule SwarmCodeCLI.UI.Projector.Status do
  @moduledoc false
  alias SwarmCodeCLI.UI.SafeText
  alias SwarmCodeCLI.UI.Scene.Block
  alias SwarmCodeCLI.UI.Projector.{Density, Support}

  def project(state, class, width) do
    bindings = Density.budget(class).bindings

    keys =
      if state.focus == "composer" do
        if bindings >= 3,
          do: "Enter Send · Esc Read · Ctrl-O Newline · Ctrl-K Features",
          else: "Enter Send · Esc Read"
      else
        tab = if state.focus == "main", do: "Tab Type", else: "Tab Next"

        case bindings do
          4 -> tab <> " · Enter Act · Ctrl-K Features · ? Help · q Quit"
          3 -> tab <> " · Ctrl-K Features · ? Help · q Quit"
          2 -> tab <> " · q Quit · ? Help"
          1 -> tab <> " · q Quit"
          0 -> "?"
        end
      end

    [Support.text("Focus: " <> state.focus <> " · " <> keys, state, width)]
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
