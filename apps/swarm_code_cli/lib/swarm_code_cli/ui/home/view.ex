defmodule SwarmCodeCLI.UI.Home.View do
  @moduledoc """
  orbit U5: what Home shows, as plain data. Everything the projector draws that
  is a decision rather than a position is decided here, from the state alone, so
  it can be tested without a terminal: the project's name, the ring's fraction and
  words, the bars, the dot, the orbits, the rows of the resume list and the
  preview of the selected one.

  Until the overview answers (or when it failed) the data is `nil` where a number
  would be, never a guess: the ring stays a ghost, the bars are empty slots and
  the legend says `…`.
  """

  alias SwarmCodeCLI.UI.Home
  alias SwarmCodeCLI.UI.Home.{Mark, Orbits}
  alias SwarmCodeCLI.UI.DataSource.DTO
  alias SwarmCodeCLI.UI.Switcher

  @doc "The project's name on the title row (its folder), or \"ncode\" when unknown."
  @spec project_name(map()) :: binary()
  def project_name(state) do
    root = launch_fact(state, :project_root)

    cond do
      is_binary(root) and Path.basename(root) not in ["", "/", "."] -> Path.basename(root)
      name = workspace_project(state) -> name
      true -> "ncode"
    end
  end

  defp workspace_project(state) do
    case Map.get(state.read_model.snapshots, :workspace) do
      %{project: name} when is_binary(name) and name != "" -> name
      _ -> nil
    end
  end

  @doc "`ncode <version>` for the title row's right edge, or nil when the version is unknown."
  @spec version(map()) :: binary() | nil
  def version(state) do
    case launch_fact(state, :cli_version) do
      version when is_binary(version) and version != "" -> "ncode " <> version
      _ -> nil
    end
  end

  @doc "A fact the launcher recorded (`cli_version`, `project_root`, `home`), or nil."
  @spec launch_fact(map(), atom()) :: term()
  def launch_fact(state, key), do: state |> Map.get(:launch_facts, %{}) |> Map.get(key)

  @doc "The overview when the service answered it, else nil (also when it answered an error)."
  @spec overview(map()) :: DTO.HomeOverview.t() | nil
  def overview(%{home: %Home{overview: %DTO.HomeOverview{state: :ready} = overview}}),
    do: overview

  def overview(_state), do: nil

  @doc "Whether the overview is an error answer (the legend then says so, once)."
  @spec failed?(map()) :: boolean()
  def failed?(%{home: %Home{overview: %DTO.HomeOverview{state: :error}}}), do: true
  def failed?(_state), do: false

  # ------------------------------------------------------------ the ring

  @doc """
  The ring: `%{frac, words, source}`. `frac` is the month's spend over the budget;
  without a budget it falls back to the tightest provider window's used percent;
  with neither it is nil (a ghost ring) and the words say so. Before the overview
  answers `frac` and `words` are nil.
  """
  @spec ring(map()) :: %{frac: float() | nil, words: binary() | nil, source: atom()}
  def ring(state) do
    case overview(state) do
      nil ->
        %{frac: nil, words: nil, source: :pending}

      %DTO.HomeOverview{month: %DTO.HomeMonth{spend_usd: spend, budget_usd: budget}}
      when is_number(budget) and budget > 0 ->
        %{frac: spend / budget, words: money(spend) <> " of " <> money(budget), source: :budget}

      _overview ->
        case tightest_limit(state) do
          nil ->
            %{frac: nil, words: "no budget set", source: :none}

          limit ->
            percent = round(limit.used_percent)

            %{
              frac: limit.used_percent / 100,
              words:
                [limit.provider, limit.scope, "#{percent}%"]
                |> Enum.reject(&(&1 in [nil, ""]))
                |> Enum.join(" "),
              source: :limit
            }
        end
    end
  end

  @doc "Dollars as the legend writes them: cents when there are any (`$38.40`), else whole (`$60`)."
  @spec money(number()) :: binary()
  def money(amount) when is_number(amount) do
    cents = round(amount * 100)

    if rem(cents, 100) == 0 and amount >= 1,
      do: "$" <> Integer.to_string(div(cents, 100)),
      else: "$" <> :erlang.float_to_binary(cents / 100, decimals: 2)
  end

  defp tightest_limit(state), do: state |> limits(1) |> List.first()

  @doc """
  The provider windows the last responses reported, tightest first, at most
  `count`: the live map by provider wins over the shell snapshot's list.
  """
  @spec limits(map(), pos_integer()) :: [map()]
  def limits(state, count) do
    live = Map.get(state.read_model, :rate_limits, %{})
    shell = Map.get(state.read_model.snapshots, :shell)
    listed = if shell, do: Map.get(shell, :rate_limits, []), else: []

    listed
    |> Enum.reject(&Map.has_key?(live, Map.get(&1, :provider_id)))
    |> Enum.concat(Map.values(live))
    |> Enum.filter(&is_number(Map.get(&1, :used_percent)))
    |> Enum.sort_by(& &1.used_percent, :desc)
    |> Enum.take(count)
  end

  @doc "The Git branch and its changed-path count from the workspace snapshot: `{branch, dirty | nil}` or nil."
  @spec branch(map()) :: {binary(), non_neg_integer() | nil} | nil
  def branch(state) do
    case Map.get(state.read_model.snapshots, :workspace) do
      %{git_branch: branch} = workspace when is_binary(branch) and branch != "" ->
        dirty = Map.get(workspace, :git_dirty)
        {branch, if(is_integer(dirty), do: dirty)}

      _ ->
        nil
    end
  end

  @doc "The gauge's lit cells out of ten for a fraction (a number, never more than ten)."
  @spec gauge_cells(float() | nil) :: 0..10
  def gauge_cells(nil), do: 0
  def gauge_cells(frac), do: frac |> Kernel.*(10) |> round() |> max(0) |> min(10)

  # ------------------------------------------------------ bars and the dot

  @doc """
  The five bars of the mark from the overview's live runs: `nil` for an empty slot,
  else `{role, progress}` (progress nil draws the whole bar).
  """
  @spec bars(map()) :: [Mark.bar()]
  def bars(state) do
    case overview(state) do
      nil ->
        List.duplicate(nil, 5)

      %{live_runs: runs} ->
        bars = Enum.map(runs, &{Mark.kind_role(&1.kind), &1.progress})
        Enum.take(bars ++ List.duplicate(nil, 5), 5)
    end
  end

  @doc "The live runs as the legend names them: `%{count, overflow, kinds: [atom]}`."
  @spec live(map()) :: %{count: non_neg_integer(), overflow: non_neg_integer(), kinds: [atom()]}
  def live(state) do
    case overview(state) do
      nil ->
        %{count: 0, overflow: 0, kinds: []}

      %{live_runs: runs, live_overflow: overflow} ->
        %{count: length(runs) + overflow, overflow: overflow, kinds: Enum.map(runs, & &1.kind)}
    end
  end

  @doc "How many requests wait for a person across every project (the dot)."
  @spec waiting(map()) :: non_neg_integer()
  def waiting(state) do
    case overview(state) do
      nil -> 0
      overview -> overview.waiting_total
    end
  end

  @doc "The mark's options for the state: ring fraction, bars and dot."
  @spec mark_opts(map()) :: Mark.opts()
  def mark_opts(state) do
    %{
      frac: ring(state).frac,
      bars: bars(state),
      dot:
        cond do
          overview(state) == nil -> :ghost
          waiting(state) > 0 -> :on
          true -> :off
        end
    }
  end

  # ----------------------------------------------------------- the orbits

  @doc "The projects to draw, this session's first: `[DTO.HomeProject]` (empty before the overview)."
  @spec projects(map()) :: [DTO.HomeProject.t()]
  def projects(state) do
    case overview(state) do
      nil -> []
      %{projects: projects} -> projects
    end
  end

  @doc "A project's count words: `{count_text, live_text | nil}`; a project with no conversations is `new`."
  @spec count_words(DTO.HomeProject.t()) :: {binary(), binary() | nil}
  def count_words(%DTO.HomeProject{conversation_count: 0, current: true}), do: {"new", nil}

  def count_words(%DTO.HomeProject{conversation_count: count, live: live}) do
    {Integer.to_string(count), if(live > 0, do: "#{live} live")}
  end

  @doc "The ages (minutes) of a project's conversations, newest first, as beads."
  @spec ages(DTO.HomeProject.t(), integer()) :: [non_neg_integer()]
  def ages(%DTO.HomeProject{conversations: conversations}, now),
    do: Enum.map(conversations, &Orbits.age_minutes(&1, now))

  @doc "The next scheduled task as `{name, project_name | nil, minutes_from_now}`, or nil."
  @spec scheduled(map()) :: {binary(), binary() | nil, non_neg_integer()} | nil
  def scheduled(state) do
    case overview(state) do
      %{next_scheduled: %DTO.HomeScheduled{} = task} ->
        minutes = max(div(task.next_run_at - state.now, 60_000), 0)

        project =
          if task.project_id == current_project_id(state), do: nil, else: task.project_name

        {task.name, project, minutes}

      _ ->
        nil
    end
  end

  defp current_project_id(state) do
    case overview(state) do
      %{project_id: id} -> id
      _ -> nil
    end
  end

  @doc "`in 14 min`, `in 3 h`, `in 2 d`: when something is due."
  @spec in_words(non_neg_integer()) :: binary()
  def in_words(minutes) when minutes < 1, do: "in under a minute"
  def in_words(minutes) when minutes < 60, do: "in #{minutes} min"
  def in_words(minutes) when minutes < 48 * 60, do: "in #{div(minutes, 60)} h"
  def in_words(minutes), do: "in #{div(minutes, 1_440)} d"

  # ------------------------------------------------------ the resume list

  @doc """
  The window of the list on screen: `%{start, rows, total}`. `rows` are the
  visible entries (at most `list_rows`), each keeping the digit that opens it
  (1..9, by its place in the window).
  """
  @spec list(map(), pos_integer()) :: %{
          start: non_neg_integer(),
          total: non_neg_integer(),
          rows: [map()]
        }
  def list(state, list_rows) do
    all = Home.rows(state)
    total = length(all)
    selected = state.home.selected
    start = window_start(selected, list_rows, total)

    rows =
      all
      |> Enum.drop(start)
      |> Enum.take(list_rows)
      |> Enum.with_index()
      |> Enum.map(fn {summary, index} ->
        entry(state, summary, index, start + index == selected)
      end)

    %{start: start, total: total, rows: rows}
  end

  defp window_start(selected, rows, total) do
    cond do
      total <= rows -> 0
      selected < rows -> 0
      true -> min(selected - rows + 1, total - rows)
    end
  end

  defp entry(state, %DTO.ConversationSummary{} = summary, index, selected?) do
    run = live_run(state, summary)

    %{
      n: index + 1,
      summary: summary,
      selected?: selected?,
      bead: Orbits.bead(bead_source(summary, run), state.now, bead_tier(state)),
      title_role: title_role(summary, state.now),
      words: state_words(summary, run),
      runs: runs_words(summary.run_count),
      age: Switcher.ago(summary.updated_at, state.now) || ""
    }
  end

  defp bead_tier(state), do: SwarmCodeCLI.UI.Projector.Panel.Glyph.tier(state.capabilities)

  defp bead_source(summary, run) do
    %{
      waiting: summary.waiting,
      live: summary.live,
      live_kind: run && run.kind,
      unread: summary.unread,
      updated_at: summary.updated_at
    }
  end

  defp live_run(state, summary) do
    case overview(state) do
      %{live_runs: runs} -> Enum.find(runs, &(&1.conversation_id == summary.id))
      _ -> nil
    end
  end

  # An old conversation reads quieter, an unread one louder.
  defp title_role(%{unread: true}, _now), do: {:text_primary, [:bold]}

  defp title_role(summary, now) do
    if Orbits.age_minutes(summary, now) > 1_440, do: :text_muted, else: :text_primary
  end

  defp state_words(%{waiting: waiting}, _run) when waiting > 0, do: {"approval waiting", :warning}

  defp state_words(%{live: true}, run) do
    case run do
      nil ->
        {"live", :accent}

      %{kind: kind, progress: nil} ->
        {Atom.to_string(kind), Mark.kind_role(kind)}

      %{kind: kind, progress: progress} ->
        {"#{kind} · #{progress}%", Mark.kind_role(kind)}
    end
  end

  defp state_words(%{unread: true}, _run), do: {"unread", :text_muted}
  defp state_words(_summary, _run), do: nil

  defp runs_words(1), do: "1 run"
  defp runs_words(count), do: "#{count} runs"

  @doc "The preview of an entry: `%{title, facts, last_prompt, waiting}`."
  @spec preview(map(), map()) :: map()
  def preview(state, %{summary: summary}) do
    started = Switcher.ago(summary.created_at, state.now)
    updated = Switcher.ago(summary.updated_at, state.now)

    facts =
      [runs_words(summary.run_count), started && "started " <> started, updated]
      |> Enum.reject(&(&1 in [nil, false]))
      |> Enum.join(" · ")

    %{
      title: summary.title,
      facts: facts,
      last_prompt: summary.last_prompt,
      waiting: summary.waiting
    }
  end

  @doc "`1 approval waiting` / `3 approvals waiting`."
  @spec waiting_words(non_neg_integer()) :: binary()
  def waiting_words(1), do: "1 approval waiting"
  def waiting_words(count), do: "#{count} approvals waiting"
end
