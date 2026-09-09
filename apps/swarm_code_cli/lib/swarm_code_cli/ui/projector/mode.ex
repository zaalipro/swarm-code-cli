defmodule SwarmCodeCLI.UI.Projector.Mode do
  @moduledoc "Mode specific projections from bounded read model facts."
  alias SwarmCodeCLI.UI.Scene.Block
  alias SwarmCodeCLI.UI.Projector.Support

  def project(state, run, width, height) do
    rows = transcript(state, run)
    kind = run.kind

    blocks =
      case kind do
        :chat -> stream(rows, state, width)
        :goal -> goal(rows, state, width)
        :ultra -> pipeline(run, rows, state, width)
        :workflow -> workflow(state, rows, width)
        :consensus -> consensus(rows, state, width)
        :research -> research(rows, state, width)
        :swarm -> swarm(state, run, rows, width)
        _ -> stream(rows, state, width)
      end

    first = first_index(state, run, blocks, height)

    [
      %Block.VirtualList{
        total_count: length(blocks),
        first_index: first,
        items: blocks |> Enum.drop(first) |> Enum.take(max(height, 0)),
        overscan: 0
      }
    ]
  end

  defp first_index(state, run, blocks, height) do
    scroll = Map.get(state, :scrolls, %{}) |> Map.get(:main)

    requested =
      case scroll && scroll.anchor do
        {id, _, _} ->
          state.read_model.transcript
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.with_index()
          |> Enum.find_value(0, fn {{key, item}, index} ->
            if key == id and item.run_id == run.id, do: index
          end)

        _ -> if(scroll && scroll.follow?, do: max(length(blocks) - height, 0), else: 0)
      end

    min(max(requested, 0), length(blocks))
  end

  defp transcript(state, run),
    do:
      state.read_model.transcript
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.filter(fn {_, i} -> i.run_id == run.id end)
      |> Enum.map(&elem(&1, 1))

  defp stream(rows, state, width) do
    case rows do
      [] ->
        [Support.text("Waiting for live stream…", state, width)]

      _ ->
        Enum.map(rows, fn i ->
          Support.styled(
            to_string(i.role) <> " · " <> text(i),
            role(i),
            state,
            width
          )
        end)
    end
  end

  defp goal(rows, state, width) do
    items = rows |> Enum.flat_map(&markdown_items/1)

    if items == [],
      do: [Support.text("No checklist items reported yet.", state, width)],
      else:
        Enum.map(items, fn {done, label} ->
          Support.styled(if(done, do: "✓ ", else: "□ ") <> label, :body, state, width)
        end)
  end

  defp pipeline(run, rows, state, width) do
    status = to_string(run.state)

    [
      Support.styled("PLAN  →  BUILD  →  VERIFY", :run_ultra, state, width),
      Support.text("Run status · " <> status, state, width),
      Support.text(
        if(rows == [],
          do: "Stage details unavailable.",
          else: "Stage updates available in live stream."
        ),
        state,
        width
      )
    ]
  end

  defp workflow(state, rows, width) do
    [
      Support.styled("WORKFLOW LIBRARY", :run_workflow, state, width),
      Support.text("Workflow entry action is available from the feature library.", state, width)
    ] ++ stream(rows, state, width)
  end

  defp consensus(rows, state, width) do
    [
      Support.styled("Consensus", :heading, state, width),
      Support.styled("PLAN", :run_consensus_judge, state, width),
      Support.text(section(rows, "plan"), state, width),
      Support.styled("CHANGES", :run_consensus_judge, state, width),
      Support.text(section(rows, "change"), state, width),
      Support.text("Docket 01 · " <> section(rows, "docket"), state, width),
      Support.text("Ledger: " <> section(rows, "ledger"), state, width)
    ]
  end

  defp research(rows, state, width) do
    [
      Support.styled("Research report", :heading, state, width),
      Support.styled("RESEARCH REPORT", :run_research, state, width),
      Support.text(section(rows, "report"), state, width),
      Support.styled("SOURCES", :run_research, state, width),
      Support.text(section(rows, "source"), state, width),
      Support.text("Fixture notes · " <> section(rows, "notes"), state, width)
    ]
  end

  defp swarm(state, run, rows, width) do
    agents = state.read_model.agents |> Enum.count(fn {_, a} -> a.run_id == run.id end)

    [
      Support.styled("SWARM AGENTS", :run_swarm, state, width),
      Support.text("Agents reported · " <> Integer.to_string(agents), state, width)
    ] ++ stream(rows, state, width)
  end

  defp section(rows, needle) do
    texts = Enum.map(rows, &text/1)

    candidate = Enum.find(texts, &String.contains?(String.downcase(&1), needle))
    excerpt(candidate || List.first(texts) || "Unavailable from run facts.")
  end

  defp excerpt(text),
    do: if(String.length(text) > 180, do: String.slice(text, 0, 177) <> "…", else: text)

  defp markdown_items(i) do
    Regex.scan(~r/^\s*- \[([ xX])\]\s+(.+)$/m, text(i), capture: :all_but_first)
    |> Enum.map(fn [mark, label] -> {mark in ["x", "X"], label} end)
  end

  defp text(i), do: i.text || ""
  defp role(%{role: :tool}), do: :accent
  defp role(%{role: :assistant}), do: :run_assistant
  defp role(_), do: :body
end
