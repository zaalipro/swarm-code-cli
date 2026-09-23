defmodule SwarmCodeCLI.UI.Projector.Inspector.Changes do
  @moduledoc """
  The changes tab: the ledger of every file an agent touched in the run.

  One row per checkpoint — what happened to the file (A created, M modified,
  D deleted), the path, the lines it added and removed, the agent that wrote
  it in its lane colour, whether it can be restored, and when — under a
  header that counts files, lines and agents. When two agents touched the same
  path the ledger says so in the warning colour before the rows: overlapping
  edits are the swarm's own failure mode and nothing else on screen shows
  them. A row with a diff opens it; any other row opens the checkpoints
  library, the existing route to a checkpoint.
  """
  alias SwarmCodeCLI.UI.{Theme, Width}
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  alias SwarmCodeCLI.UI.Projector.{Density, RunRow, Support}
  alias SwarmCodeCLI.UI.Projector.Inspector.{Hive, Words}

  @max_chip 10
  @time_width 5
  @restorable_word "restorable"
  # Below this width the restorable column is a one-cell mark, not the word.
  @word_width 56
  @min_path 12
  # The file-state letter and its gap.
  @mark_width 2

  @doc "The tab's rows, budgeted to `width` and capped at `height`."
  def tab(state, run, width, height) do
    changes = changes(state, run)
    agents = agents(state, run)

    header =
      [header(changes, agents, state, width)] ++ blast_radius(changes, agents, state, width)

    body =
      case changes do
        [] -> [Support.text(empty_words(run), state, width)]
        changes -> rows(changes, agents, state, width, max(0, height - length(header) - 1))
      end

    Enum.take(header ++ [Hive.blank(state) | body], max(0, height))
  end

  # pass71 V1: a finished turn that changed nothing has nothing still to come.
  defp empty_words(%{state: state}) when state in [:done, :failed, :stopped, :interrupted],
    do: "No files changed"

  defp empty_words(_run), do: "No files changed yet"

  @doc """
  The changes of the run, newest first; or of the conversation's runs when the
  destination is a conversation with no current run.
  """
  def changes(state, run) do
    run_ids =
      case {run, state.destination} do
        {%{id: id}, _} ->
          [id]

        {nil, {:conversation, conversation_id}} ->
          state.read_model.runs
          |> Map.values()
          |> Enum.filter(&(&1.conversation_id == conversation_id))
          |> Enum.map(& &1.id)

        _ ->
          []
      end

    state.read_model.changes
    |> Map.values()
    |> Enum.filter(&(&1.run_id in run_ids))
    |> Enum.sort_by(&{-&1.at, &1.id})
  end

  @doc "Paths more than one agent touched, each with the agents that did, in lane order."
  def overlaps(changes, agents) do
    order = agents |> Enum.with_index() |> Map.new(fn {agent, index} -> {agent.id, index} end)

    changes
    |> Enum.reject(&is_nil(&1.agent_id))
    |> Enum.group_by(& &1.path, & &1.agent_id)
    |> Enum.map(fn {path, ids} ->
      {path, ids |> Enum.uniq() |> Enum.sort_by(&Map.get(order, &1, 99))}
    end)
    |> Enum.filter(fn {_path, ids} -> length(ids) > 1 end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp agents(_state, nil), do: []
  defp agents(state, run), do: Hive.agents(state, run.id)

  defp header(changes, agents, state, width) do
    files = changes |> Enum.map(& &1.path) |> Enum.uniq() |> length()

    authors =
      changes |> Enum.map(& &1.agent_id) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> length()

    authors = max(authors, if(changes != [] and agents == [], do: 1, else: 0))

    # A zero is never shown: an empty ledger is headed "Changes" alone.
    parts =
      ["Changes"] ++
        if(files > 0, do: [Words.count(files, "file", "files")], else: []) ++
        lines(changes, state) ++
        if(authors > 0, do: [Words.count(authors, "agent", "agents")], else: [])

    Support.section_heading(Enum.join(parts, " · "), state, width)
  end

  # `Blast radius · lib/auth.ex · scout-1, builder-4` when that fits the panel,
  # else the counts; the overlapping rows themselves are painted in the warning
  # colour either way, so the file is never lost to the elision.
  defp blast_radius(changes, agents, state, width) do
    case overlaps(changes, agents) do
      [] ->
        []

      [{path, ids} | rest] = overlaps ->
        names = Enum.map_join(ids, ", ", &agent_name(&1, agents))

        long =
          case rest do
            [] -> "Blast radius · #{path} · #{names}"
            more -> "Blast radius · #{path} · #{names} · #{length(more)} more"
          end

        authors = overlaps |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq() |> length()

        short =
          "Blast radius · " <>
            Words.count(length(overlaps), "file", "files") <>
            " · " <> Words.count(authors, "agent", "agents")

        text = if Hive.measure(long, state) <= width, do: long, else: short

        [
          %Block.RichText{
            spans: [
              %Span{
                text: Density.safe(text, state, width),
                style: %{RunRow.tinted(:warning, state) | modifiers: [:bold]}
              }
            ]
          }
        ]
    end
  end

  # "+42 −7" over the whole ledger, when the daemon counted any lines.
  defp lines(changes, state) do
    counted = Enum.filter(changes, &(is_integer(added(&1)) or is_integer(removed(&1))))

    if counted == [],
      do: [],
      else: [
        "+#{counted |> Enum.map(&(added(&1) || 0)) |> Enum.sum()} " <>
          minus(state) <> "#{counted |> Enum.map(&(removed(&1) || 0)) |> Enum.sum()}"
      ]
  end

  defp added(change), do: Map.get(change, :added)
  defp removed(change), do: Map.get(change, :removed)

  defp minus(state), do: if(state.capabilities.ascii?, do: "-", else: "−")

  defp rows(changes, agents, state, width, height) do
    chip_width =
      changes
      |> Enum.map(&Hive.measure(agent_name(&1.agent_id, agents), state))
      |> Enum.max(fn -> 0 end)
      |> min(@max_chip)

    counts_width =
      changes
      |> Enum.map(&Hive.measure(counts_text(&1, state), state))
      |> Enum.max(fn -> 0 end)

    restorable_width = if width >= @word_width, do: Hive.measure(@restorable_word, state), else: 1
    counts_cost = if counts_width > 0, do: counts_width + 1, else: 0

    # A ledger that knows no file states (an older daemon) has no letter column.
    mark_width =
      if Enum.any?(changes, &(Map.get(&1, :file_state) in [:created, :modified, :deleted])),
        do: @mark_width,
        else: 0

    fixed =
      mark_width + counts_cost + (chip_width + 1) + (restorable_width + 1) + (@time_width + 1)

    # Too narrow for every column: the restorable mark goes first, then the
    # line counts; the path and the chip are what matter.
    {restorable_width, counts_width, path_width} =
      cond do
        width - fixed >= @min_path ->
          {restorable_width, counts_width, width - fixed}

        width - (fixed - restorable_width - 1) >= @min_path ->
          {0, counts_width, width - (fixed - restorable_width - 1)}

        true ->
          {0, 0, max(0, width - mark_width - (chip_width + 1) - (@time_width + 1))}
      end

    overlapping = changes |> overlaps(agents) |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    widths = {mark_width, path_width, counts_width, chip_width, restorable_width}

    changes
    |> Enum.take(max(0, height))
    |> Enum.map(&row(&1, agents, overlapping, state, widths))
  end

  defp counts_text(change, state) do
    case {added(change), removed(change)} do
      {nil, nil} -> ""
      {a, r} -> "+#{a || 0} " <> minus(state) <> "#{r || 0}"
    end
  end

  # What happened to the file, as git says it, in one cell.
  defp mark(_change, _state, 0), do: []

  defp mark(change, state, _width) do
    {letter, role} =
      case Map.get(change, :file_state) do
        :created -> {"A", :success}
        :modified -> {"M", :info}
        :deleted -> {"D", :error}
        _ -> {" ", :text_faint}
      end

    [
      %Span{text: Density.safe(letter, state, 1), style: RunRow.tinted(role, state)},
      RunRow.gap(1, state)
    ]
  end

  defp counts(_change, _state, 0), do: []

  defp counts(change, state, width) do
    text = counts_text(change, state)

    pad =
      Density.safe(String.duplicate(" ", max(0, width - Hive.measure(text, state))), state, width)

    spans =
      case {added(change), removed(change)} do
        {nil, nil} ->
          []

        {a, r} ->
          [
            %Span{
              text: Density.safe("+#{a || 0}", state, width),
              style: RunRow.tinted(:success, state)
            },
            %Span{
              text: Density.safe(" " <> minus(state) <> "#{r || 0}", state, width),
              style: RunRow.tinted(:error, state)
            }
          ]
      end

    [%Span{text: pad, style: RunRow.tinted(:text_faint, state)} | spans] ++ [RunRow.gap(1, state)]
  end

  defp row(change, agents, overlapping, state, widths) do
    {mark_width, path_width, counts_width, chip_width, restorable_width} = widths
    index = Enum.find_index(agents, &(&1.id == change.agent_id))
    agent = if index, do: Enum.at(agents, index)
    role = if agent, do: Hive.lane_role(agent, index), else: :text_muted
    chip_style = %{RunRow.tinted(role, state) | modifiers: [:bold]}

    path_style =
      if MapSet.member?(overlapping, change.path),
        do: RunRow.tinted(:warning, state),
        else: Theme.style(:text_primary, state.capabilities)

    # Paths lose whole directories from the middle so the file name survives:
    # `lib/…/repo.ex`.
    path =
      change.path
      |> fit_path(path_width, state.capabilities.ambiguous_width)
      |> RunRow.pad(path_width, state)
      |> Density.safe(state, path_width)

    spans =
      mark(change, state, mark_width) ++
        [%Span{text: path, style: path_style}, RunRow.gap(1, state)] ++
        counts(change, state, counts_width) ++
        [
          %Span{
            text: Hive.fit(agent_name(change.agent_id, agents), chip_width, state),
            style: chip_style
          }
        ] ++
        restorable(change, state, restorable_width) ++
        [
          RunRow.gap(1, state),
          %Span{
            text:
              Density.safe(
                RunRow.pad_leading(Words.clock(change.at) || "", @time_width, state),
                state,
                @time_width
              ),
            style: Theme.style(:text_faint, state.capabilities)
          }
        ]

    target =
      case Map.get(change, :diff_ref) do
        %{id: ref} when is_binary(ref) -> {:local, {:open_detail, change.run_id, ref}}
        _ -> {:local, {:open_layer, {:library, :checkpoints}}}
      end

    Support.action_spans(spans, target)
  end

  @doc false
  def fit_path(path, width, policy) do
    if Width.cells(path, policy) <= width do
      path
    else
      [first | rest] = segments = String.split(path, "/")
      name = List.last(segments)

      tails =
        if length(segments) > 2,
          do:
            for(
              k <- (length(rest) - 1)..1//-1,
              do: first <> "/…/" <> Enum.join(Enum.take(rest, -k), "/")
            ),
          else: []

      Enum.find(tails ++ ["…/" <> name], &(Width.cells(&1, policy) <= width)) ||
        Width.elide(name, width, :middle, policy)
    end
  end

  defp restorable(_change, _state, 0), do: []

  defp restorable(change, state, 1) do
    text =
      if change.restorable,
        do: Support.glyph(:check, state),
        else: Density.safe(" ", state, 1)

    [RunRow.gap(1, state), %Span{text: text, style: RunRow.tinted(:success, state)}]
  end

  defp restorable(change, state, width) do
    text = if change.restorable, do: @restorable_word, else: ""

    [
      RunRow.gap(1, state),
      %Span{
        text: Density.safe(RunRow.pad(text, width, state), state, width),
        style: RunRow.tinted(:success, state)
      }
    ]
  end

  defp agent_name(nil, _agents), do: "run"

  defp agent_name(id, agents) do
    case Enum.find(agents, &(&1.id == id)) do
      nil -> id
      agent -> Hive.name(agent)
    end
  end
end
