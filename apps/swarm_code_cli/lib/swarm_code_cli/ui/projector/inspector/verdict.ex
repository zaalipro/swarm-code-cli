defmodule SwarmCodeCLI.UI.Projector.Inspector.Verdict do
  @moduledoc """
  The verdict card of a consensus run: the judge's criteria, one row each,
  with a check, a cross or a dash for scored, failed and not-yet-scored, the
  judge's note beside it, and the summary underneath. The newest verdict for
  the run wins; before there is one the card says so and what the judge is
  doing, in plain words.
  """
  alias SwarmCodeCLI.UI.Theme
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  alias SwarmCodeCLI.UI.Projector.{Density, RunRow, Support}
  alias SwarmCodeCLI.UI.Projector.Inspector.{Hive, Words}

  @max_key 16
  @summary_lines 2

  @doc "Whether the run is judged: the summary says so, or its kind does."
  def judged?(nil), do: false
  def judged?(run), do: Map.get(run, :consensus, false) == true or run.kind == :consensus

  @doc "The newest verdict of the run — the highest round, then revision — or `nil`."
  def newest(state, run) do
    state.read_model.verdicts
    |> Map.values()
    |> Enum.filter(&(&1.run_id == run.id))
    |> Enum.max_by(&{&1.round, &1.revision, &1.id}, fn -> nil end)
  end

  @doc "The card's rows, budgeted to `width`; `[]` for a run that is not judged."
  def card(state, run, width) do
    if judged?(run), do: rows(state, run, newest(state, run), width), else: []
  end

  defp rows(state, run, nil, width) do
    judge = state |> Hive.agents(run.id) |> Enum.find(&(&1.role == :judge))

    text =
      case judge do
        nil -> "No verdict yet"
        judge -> "No verdict yet · judge " <> Words.state(judge.state)
      end

    [
      heading("Verdict", state, width),
      Support.styled(text, :text_muted, state, width),
      Hive.blank(state)
    ]
  end

  defp rows(state, _run, verdict, width) do
    round = if verdict.round > 0, do: " · round #{verdict.round}", else: ""
    title = "Verdict" <> round <> " · " <> Words.state(verdict.status)

    key_width =
      verdict.checks
      |> Enum.map(&Hive.measure(&1.key, state))
      |> Enum.max(fn -> 0 end)
      |> min(@max_key)

    checks = Enum.map(verdict.checks, &check(&1, state, width, key_width))

    summary =
      if verdict.summary == "",
        do: [],
        else:
          verdict.summary
          |> Density.lines(state, width, @summary_lines)
          |> Enum.map(&Support.styled(&1, :text_muted, state, width))

    [heading(title, state, width)] ++ checks ++ summary ++ [Hive.blank(state)]
  end

  # `✓ tests_pass       142 tests, 0 failures`
  defp check(check, state, width, key_width) do
    {mark, role} =
      case check.ok do
        true -> {Support.glyph(:check, state), :success}
        false -> {Support.glyph(:fail, state), :error}
        nil -> {Density.safe(dash(state), state, 1), :text_faint}
      end

    note_width = max(0, width - 1 - 1 - key_width - 2)

    %Block.RichText{
      spans: [
        %Span{text: mark, style: %{RunRow.tinted(role, state) | modifiers: [:bold]}},
        RunRow.gap(1, state),
        %Span{
          text: Hive.fit(check.key, key_width, state),
          style: Theme.style(:text_primary, state.capabilities)
        },
        RunRow.gap(2, state),
        %Span{
          text: Density.safe(check.note, state, note_width),
          style: Theme.style(:text_muted, state.capabilities)
        }
      ]
    }
  end

  # An em dash is two cells under the wide policy, so that terminal gets a
  # hyphen: the column must stay aligned with the check and the cross.
  defp dash(%{capabilities: %{ambiguous_width: :wide}}), do: "-"
  defp dash(_state), do: "—"

  defp heading(text, state, width) do
    %Block.RichText{
      spans: [
        %Span{
          text: Density.safe(text, state, width),
          style: %{RunRow.tinted(:run_consensus_judge, state) | modifiers: [:bold]}
        }
      ]
    }
  end
end
