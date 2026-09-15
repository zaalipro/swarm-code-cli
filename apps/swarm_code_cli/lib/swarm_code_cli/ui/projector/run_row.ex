defmodule SwarmCodeCLI.UI.Projector.RunRow do
  @moduledoc """
  The one-line run row shared by the Ctrl-G runs dashboard and the Ctrl-R run palette.

  Both views draw the same thing: a kind mark, a title, a status word, an inline
  tick gauge and the kind's meta, on a single line. The rules that make that work
  are subtle enough that a second copy would drift:

    * blocks inside a `Block.Surface` stack vertically, so a row that must occupy
      one line has to be a single `Block.RichText` of styled spans, and the gauge
      has to be drawn as lit and unlit tick spans rather than as a `Block.Gauge`,
      which claims a full-width line of its own;
    * Paint resolves a span prefix as `style.prefix || themed.prefix`, so setting
      `prefix: nil` does not suppress a role's cue. `tinted/2` borrows a role's
      colour onto the cue-free `:plain` role instead, which is what keeps the
      kind letter from being printed beside the kind mark and the status cue from
      being printed beside the status word;
    * the wire kinds `:chat` and `:consensus` are not `Theme.run_kind/1` keys, so
      `theme_kind/1` translates them before any theme lookup.

  Callers own their own chrome and column widths: the dashboard wraps the row in
  a kind-accented card with a wide gauge, the palette in a selection-striped one
  with a narrow gauge, a timestamp and no accent column.
  """
  alias SwarmCodeCLI.UI.{SafeText, Theme, Width}
  alias SwarmCodeCLI.UI.Scene.Span
  alias SwarmCodeCLI.UI.Projector.{Density, Support}

  # Column widths the dashboard was built with; the palette overrides them.
  @status_width 12
  @gauge_width 28
  @meta_width 30
  @min_title 10

  # Each optional column carries the gap that precedes it, so dropping the column
  # drops its gap too and the row stays exactly as wide as its budget.
  @mark_cost 2
  @status_gap 1
  @gauge_gap 1
  @meta_gap 2

  @doc "The wire run kind translated into the `Theme.run_kind/1` vocabulary."
  def theme_kind(:chat), do: :assistant
  def theme_kind(:consensus), do: :consensus_judge
  def theme_kind(kind), do: kind

  @doc """
  Live runs narrowed by `filter`, in the order the shell hands them over.

  `order` is `read_model.order[:shell]`, the sequence the data source itself
  sent, and it wins wherever it speaks: it is the only ordering fact the server
  supplies, and the old navigator listed exactly it. Runs the shell order does
  not mention — a run known only from a workspace or inspector snapshot — follow
  it, newest first by `created_sequence`, the only recency fact a `RunSummary`
  carries, with the id breaking ties so a map's hash order can never decide what
  the user sees.

  Superseded runs are never listed: they have been replaced by a newer turn.
  """
  def visible(runs, filter, order \\ [])

  def visible(runs, filter, order) when is_map(runs),
    do: runs |> Map.values() |> visible(filter, order)

  def visible(runs, filter, order) when is_list(runs) do
    pattern = String.downcase(to_string(filter))
    positions = order |> Enum.with_index() |> Map.new()

    runs
    |> Enum.reject(&(&1.state == :superseded))
    |> Enum.filter(fn run ->
      pattern == "" or String.contains?(String.downcase(run.title), pattern)
    end)
    |> Enum.sort_by(fn run ->
      case Map.fetch(positions, run.id) do
        {:ok, index} -> {0, index, run.id}
        :error -> {1, -run.created_sequence, run.id}
      end
    end)
  end

  @doc "The shell order the data source supplied, or `[]` when it has sent none."
  def shell_order(state), do: Map.get(state.read_model.order, :shell, [])

  @doc "Adds the run's agent count, counted from the read model's own agents."
  def enrich(run, state) do
    count =
      state.read_model.agents
      |> Map.values()
      |> Enum.count(&(&1.run_id == run.id))

    Map.put(run, :agent_count, count)
  end

  @doc """
  The kind-specific meta line for a run.

  Only facts the read model actually carries are shown: `RunSummary` exposes
  progress, and agents are counted from `read_model.agents`. Research source
  counts, workflow stage positions and consensus proposal counts are not in the
  read model today, so those kinds fall back to the run's real progress rather
  than inventing numbers the daemon never sent.
  """
  def meta(run, :swarm), do: join([agents(run), percent(run)])
  def meta(run, :consensus_judge), do: join([reviewers(run), percent(run)])
  def meta(run, :ultra), do: join([agents(run), percent(run)])
  def meta(run, _kind), do: join([percent(run)])

  @doc """
  A short relative age for a run, or `nil` when the read model holds no clock fact.

  A `RunSummary` carries no timestamp: `created_sequence` is an ordering
  revision, not a time. The one real clock fact about a run is
  `ActivityItem.created_at`, which shares `state.now`'s wall-clock millisecond
  domain, so the age is measured from the newest activity item the read model
  holds for this run. A run with no activity has no age and its caller leaves the
  column blank rather than inventing one.
  """
  def age(run, state) do
    state.read_model.activity
    |> Map.values()
    |> Enum.filter(&(&1.run_id == run.id))
    |> Enum.map(& &1.created_at)
    |> case do
      [] -> nil
      stamps -> elapsed(state.now - Enum.max(stamps))
    end
  end

  @doc "Cells a row spends on everything except the title, gaps included."
  def chrome_width(opts \\ []) do
    Keyword.get(opts, :reserved, 0) + @mark_cost +
      cost(Keyword.get(opts, :status_width, @status_width), @status_gap) +
      cost(Keyword.get(opts, :gauge_width, @gauge_width), @gauge_gap) +
      cost(Keyword.get(opts, :meta_width, @meta_width), @meta_gap)
  end

  @doc "Title cells left over once every other column has taken its share of `budget`."
  def title_width(budget, opts \\ []),
    do: max(Keyword.get(opts, :min_title, @min_title), budget - chrome_width(opts))

  @doc """
  The styled spans of one run row.

  `:lead` and `:trail` are already-styled spans the caller puts either side of
  the row (a selection stripe, a timestamp); a column given a width of `0` is
  dropped along with its gap.
  """
  def spans(run, kind, state, opts) do
    title_width = Keyword.fetch!(opts, :title_width)
    status_width = Keyword.get(opts, :status_width, @status_width)
    gauge_width = Keyword.get(opts, :gauge_width, @gauge_width)
    meta_width = Keyword.get(opts, :meta_width, @meta_width)

    {_kind_letter, kind_role} = Theme.run_kind(kind)
    mark = Support.glyph(Theme.run_mark(kind), state)
    {status_text, status_role} = Theme.status(run.state)

    # The mark leads the row as text and the title carries the same kind colour
    # without the role's cue: that cue is the old single letter, and a run_* role
    # on either span would print the letter again in front of the mark.
    kind_style = %{tinted(kind_role, state) | modifiers: [:bold]}

    Keyword.get(opts, :lead, []) ++
      [
        %Span{text: mark, style: kind_style},
        gap(1, state),
        cell(run.title, title_width, kind_style, state)
      ] ++
      column(
        SafeText.value(status_text),
        status_width,
        @status_gap,
        tinted(status_role, state),
        state
      ) ++
      gauge_spans(run, gauge_width, kind_role, state) ++
      column(
        meta(run, kind),
        meta_width,
        @meta_gap,
        Theme.style(:text_muted, state.capabilities),
        state
      ) ++
      Keyword.get(opts, :trail, [])
  end

  @doc """
  A role's colour without its prefix cue.

  Paint falls back to the theme's own prefix whenever `style.prefix` is nil, so
  suppressing a cue means borrowing the colour onto the cue-free `:plain` role
  rather than blanking the field.
  """
  def tinted(role, state) do
    themed = Theme.style(role, state.capabilities)

    %{
      Theme.style(:plain, state.capabilities)
      | foreground: themed.foreground,
        background: themed.background
    }
  end

  @doc "Clips `value` to `width` cells and pads it on the right with spaces."
  def pad(value, width, state) do
    {taken, _rest, cells} = Width.take_cells(value, width, state.capabilities.ambiguous_width)
    taken <> String.duplicate(" ", max(0, width - cells))
  end

  @doc "Clips `value` to `width` cells and pads it on the left with spaces."
  def pad_leading(value, width, state) do
    {taken, _rest, cells} = Width.take_cells(value, width, state.capabilities.ambiguous_width)
    String.duplicate(" ", max(0, width - cells)) <> taken
  end

  @doc "A run-plain spacer of `width` cells."
  def gap(width, state),
    do: %Span{
      text: Density.safe(String.duplicate(" ", width), state, width),
      style: Theme.style(:plain, state.capabilities)
    }

  # The gauge is `width` cells: the lit run in the kind's colour, the rest on the
  # muted track, mirroring Block.Gauge's :ticks style inline.
  defp gauge_spans(_run, 0, _kind_role, _state), do: []

  defp gauge_spans(run, width, kind_role, state) do
    progress = Map.get(run, :progress) || 0
    lit = round(progress / 100 * width)
    lit = lit |> max(0) |> min(width)
    unlit = width - lit

    tick = SafeText.value(Support.glyph(:seg_on, state))

    [
      gap(@gauge_gap, state),
      %Span{
        text: Density.safe(String.duplicate(tick, lit), state, lit),
        style: tinted(kind_role, state)
      },
      %Span{
        text: Density.safe(String.duplicate(tick, unlit), state, unlit),
        style: tinted(:ticks_track, state)
      }
    ]
  end

  defp column(_value, 0, _gap, _style, _state), do: []

  defp column(value, width, gap_width, style, state),
    do: [gap(gap_width, state), cell(value, width, style, state)]

  defp cell(value, width, style, state),
    do: %Span{text: Density.safe(pad(value, width, state), state, width), style: style}

  defp cost(0, _gap), do: 0
  defp cost(width, gap), do: width + gap

  # A clock that has not moved yet, or an activity item stamped after the state's
  # own clock, reads as "now" rather than as a negative age.
  defp elapsed(ms) when ms < 5_000, do: "now"

  defp elapsed(ms) do
    seconds = div(ms, 1000)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3_600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  defp agents(run) do
    case Map.get(run, :agent_count, 0) do
      0 -> nil
      1 -> "1 agent"
      n -> "#{n} agents"
    end
  end

  defp reviewers(run) do
    case Map.get(run, :agent_count, 0) do
      0 -> nil
      1 -> "1 reviewer"
      n -> "#{n} reviewers"
    end
  end

  defp percent(run) do
    case Map.get(run, :progress) do
      nil -> nil
      value when is_integer(value) -> "#{value}%"
      _ -> nil
    end
  end

  defp join(parts) do
    parts
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end
end
