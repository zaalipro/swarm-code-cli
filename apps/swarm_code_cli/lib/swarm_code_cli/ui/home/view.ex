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

  alias SwarmCodeCLI.UI.{Drafts, Editor, Home, SafeText, Width}
  alias SwarmCodeCLI.UI.Home.{Canvas, CopyCommand, Grid, Mark, Orbits}
  alias SwarmCodeCLI.UI.Projector.Density
  alias SwarmCodeCLI.UI.Projector.Panel.Glyph
  alias SwarmCodeCLI.UI.SafeText.Limits
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

  @doc """
  The live runs as the legend names them: `%{count, overflow, kinds, project}`.
  `project` is the name of the project a single run belongs to (the legend then
  says where it runs), else nil.
  """
  @spec live(map()) :: %{
          count: non_neg_integer(),
          overflow: non_neg_integer(),
          kinds: [atom()],
          project: binary() | nil
        }
  def live(state) do
    case overview(state) do
      nil ->
        %{count: 0, overflow: 0, kinds: [], project: nil}

      %{live_runs: runs, live_overflow: overflow} = overview ->
        project =
          with [run] <- runs,
               0 <- overflow,
               %{name: name} <- Enum.find(overview.projects, &(&1.id == run.project_id)) do
            name
          else
            _ -> nil
          end

        %{
          count: length(runs) + overflow,
          overflow: overflow,
          kinds: Enum.map(runs, & &1.kind),
          project: project
        }
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
  (1..9, by its place in the window). With the map focused on another project's
  bead the list is that project's conversations (D5), selected by the bead.
  """
  @spec list(map(), pos_integer()) :: %{
          start: non_neg_integer(),
          total: non_neg_integer(),
          rows: [map()]
        }
  def list(state, list_rows) do
    case map_target(state) do
      %{project: %{current: false} = project} ->
        window(state, project.conversations, state.home.bead, list_rows)

      _ ->
        rows = Home.rows(state)
        window(state, rows, list_selected(state, rows), list_rows)
    end
  end

  # With the map focused on this project the bead is the cursor, and the row
  # lit is the bead's own conversation, found by id: the overview's beads and
  # the conversation list are two lists (the list keeps scheduled-task
  # conversations, the overview drops them), so the same index could light
  # another row than the one Enter opens (orbit int, UI-U-5). A bead the list
  # does not hold lights no row.
  defp list_selected(%{home: %Home{focus: :map}} = state, rows) do
    case map_target(state) do
      %{conversation: %{id: id}} -> Enum.find_index(rows, &(&1.id == id)) || -1
      _ -> state.home.bead
    end
  end

  defp list_selected(state, _rows), do: state.home.selected

  defp window(state, all, selected, list_rows) do
    total = length(all)
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

  defp entry(state, summary, index, selected?) do
    run = live_run(state, summary)

    %{
      n: index + 1,
      summary: summary,
      selected?: selected?,
      bead: Orbits.bead(bead_source(summary, run), state.now, bead_tier(state)),
      title_role: title_role(summary, state.now),
      words: state_words(summary, run),
      runs: if(Map.get(summary, :run_count), do: runs_words(summary.run_count)),
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

  defp state_words(%{live: true} = summary, run) do
    case run do
      nil ->
        case Map.get(summary, :live_kind) do
          nil -> {"live", :accent}
          kind -> {Atom.to_string(kind), Mark.kind_role(kind)}
        end

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

  @doc """
  The preview of a bead of another project (D5): the overview knows a title, an
  age, and whether it is live or waiting, but no prompt and no run count. The
  copy command is what Enter puts on the clipboard.
  """
  @spec foreign_preview(map(), map(), DTO.HomeProject.t()) :: map()
  def foreign_preview(state, %{summary: conversation}, project) do
    home = launch_fact(state, :home)
    run = live_run(state, conversation)
    updated = Switcher.ago(conversation.updated_at, state.now)

    live =
      if conversation.live do
        kind = (run && run.kind) || Map.get(conversation, :live_kind)
        progress = run && run.progress
        {kind, progress}
      end

    facts =
      case run do
        %{started_at: started} when is_integer(started) ->
          "started " <> (Switcher.ago(started, state.now) || "")

        _ ->
          if updated, do: "updated " <> updated, else: ""
      end

    %{
      title: conversation.title,
      where: project.name,
      path: CopyCommand.abbreviate(project.root_path, home),
      live: live,
      waiting: conversation.waiting,
      facts: facts,
      command: CopyCommand.command(project.root_path, conversation.id, home)
    }
  end

  @doc """
  The bead the project map points at: `%{project, conversation, index}`, or nil
  unless the map has the focus (and the orbit exists).
  """
  @spec map_target(map()) ::
          %{project: DTO.HomeProject.t(), conversation: term(), index: integer()} | nil
  def map_target(%{home: %Home{focus: :map} = home} = state) do
    # orbit int (UI-U-9): the orbits drawn, not every project the overview
    # carries (a smaller terminal draws fewer).
    case Enum.at(map_projects(state), home.orbit) do
      nil ->
        nil

      project ->
        %{
          project: project,
          conversation: Enum.at(project.conversations, home.bead),
          index: home.bead
        }
    end
  end

  def map_target(_state), do: nil

  @doc "Whether the map points at a bead of another project (Enter then copies a command)."
  @spec foreign?(map()) :: boolean()
  def foreign?(state) do
    match?(%{project: %{current: false}}, map_target(state))
  end

  @doc """
  First run (D11): the project has nothing to resume, no search is shown, and the
  conversation list has answered (before that the list zone is just empty).
  """
  @spec first_run?(map()) :: boolean()
  def first_run?(
        %{home: %Home{filter: "", search: nil}, conversations: %DTO.ConversationList{}} = state
      ),
      do: Home.rows(state) == []

  def first_run?(_state), do: false

  @doc """
  The newest conversations of the other projects, `count` at most (the first-run
  card's "recently, elsewhere"): `%{n, project, conversation, bead, age, command}`.
  """
  @spec elsewhere(map(), pos_integer()) :: [map()]
  def elsewhere(state, count) do
    home = launch_fact(state, :home)

    state
    |> projects()
    |> Enum.reject(& &1.current)
    |> Enum.flat_map(fn project -> Enum.map(project.conversations, &{project, &1}) end)
    |> Enum.sort_by(fn {_project, conversation} -> conversation.updated_at end, :desc)
    |> Enum.take(count)
    |> Enum.with_index(1)
    |> Enum.map(fn {{project, conversation}, n} ->
      %{
        n: n,
        project: project,
        conversation: conversation,
        bead: Orbits.bead(conversation, state.now, bead_tier(state)),
        age:
          String.replace_suffix(
            Switcher.ago(conversation.updated_at, state.now) || "",
            " ago",
            ""
          ),
        command: CopyCommand.command(project.root_path, conversation.id, home)
      }
    end)
  end

  # ------------------------------------------------------ grid and the draft

  @placeholder "Type to start a new conversation, or / for commands…"
  @small_placeholder "Type to start a new conversation…"

  @doc "The grid of the state's terminal size and glyph tier, for the orbits there are."
  @spec grid(map()) :: Grid.t()
  def grid(state) do
    %{columns: columns, rows: rows} = state.size
    Grid.for(columns, rows, Glyph.tier(state.capabilities), max(length(projects(state)), 1))
  end

  @doc "The projects the map shows: as many as the grid has orbits for."
  @spec map_projects(map()) :: [DTO.HomeProject.t()]
  def map_projects(state), do: state |> projects() |> Enum.take(grid(state).orbit_slots)

  @doc "Whether a map is drawn at all (a focus on it needs something to point at)."
  @spec map?(map()) :: boolean()
  def map?(state), do: map_projects(state) != []

  @doc """
  The visible window of the resume list: what the projector draws, so the digit of
  a row and the row Alt-digit opens agree.
  """
  @spec visible_list(map()) :: %{
          start: non_neg_integer(),
          total: non_neg_integer(),
          rows: [map()]
        }
  def visible_list(state) do
    extra = max(draft_rows(state, state.size.columns) - 1, 0)
    list(state, max(grid(state).list_rows - extra, 1))
  end

  @doc "How many rows the Home draft takes in a canvas `width` wide (1..3)."
  @spec draft_rows(map(), pos_integer()) :: pos_integer()
  def draft_rows(state, width), do: state |> draft_lines(width) |> elem(0) |> length()

  @doc "The visible lines of the Home draft (at most 3) and the caret as `{row, col}`."
  @spec draft_lines(map(), pos_integer()) :: {[map()], {non_neg_integer(), non_neg_integer()}}
  def draft_lines(state, width) do
    policy = state.capabilities.ambiguous_width
    draft = Drafts.fetch(state.drafts, {state.source_epoch, :home})
    editor_width = max(width - 4, 1)
    slice = Editor.visible_slice(draft.editor, editor_width, 3, policy)

    if slice.text == "" do
      {[
         %{
           text: Canvas.clip(Canvas.new(state, width, 1), placeholder(state), editor_width),
           placeholder?: true
         }
       ], {0, 0}}
    else
      limits = %{Limits.composer_viewport() | ambiguous_width: policy}

      lines =
        slice.text
        |> Density.external(limits)
        |> SafeText.value()
        |> Width.wrap(editor_width, policy)

      before =
        slice.text
        |> String.graphemes()
        |> Enum.take(slice.cursor_offset)
        |> Enum.join()
        |> Density.external(limits)
        |> SafeText.value()

      prefix = Width.wrap(before, editor_width, policy)
      caret_row = max(length(prefix) - 1, 0)
      first = max(caret_row - 2, 0)
      shown = lines |> Enum.drop(first) |> Enum.take(3)
      col = min(editor_width - 1, Width.cells(List.last(prefix) || "", policy))
      {Enum.map(shown, &%{text: &1, placeholder?: false}), {min(caret_row - first, 2), col}}
    end
  end

  defp placeholder(state) do
    cond do
      first_run?(state) and small?(state) ->
        "Type to start the first conversation…"

      first_run?(state) ->
        "Type to start the first conversation in " <>
          project_name(state) <> ", or / for commands…"

      small?(state) ->
        @small_placeholder

      true ->
        @placeholder
    end
  end

  @doc "The two classes with no preview and no room for sentences in the hint row."
  @spec small?(map()) :: boolean()
  def small?(state) do
    %{columns: columns, rows: rows} = state.size
    tier = Glyph.tier(state.capabilities)
    Grid.class(columns, rows, tier) in [:compact, :minimal]
  end

  @doc "`1 approval waiting` / `3 approvals waiting`."
  @spec waiting_words(non_neg_integer()) :: binary()
  def waiting_words(1), do: "1 approval waiting"
  def waiting_words(count), do: "#{count} approvals waiting"
end
