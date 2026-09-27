defmodule SwarmCodeCLI.UI.Settings.Sections.Storage do
  @moduledoc """
  The Storage section (spec §2.18): the page text, the two retention rows with their quick
  picks (`storage.retention_days` Off · 30 · 60 · 90 · 180, `storage.prune_days` Off · 14 ·
  30 · 90; 7–3650 days), the pruning sentence, the last sweep, the measured overview (a bar
  of the kinds, the legend and the desktop's line; `storage.measure` runs when the page
  opens and no measure ran this session), `▸ Clean up…` (the `CleanupWizard` sub-page),
  `▸ Reclaim disk space (VACUUM)` and `▸ Apply retention now`. Pure.
  """

  alias SwarmCodeCLI.UI.Settings.{CleanupWizard, Glyphs, Grid}
  alias SwarmCodeCLI.UI.Settings.IntegrationRows, as: R

  @retention [
    {"storage.retention_days", "Automatically delete sessions older than",
     [nil, 30, 60, 90, 180]},
    {"storage.prune_days", "Prune agent details older than", [nil, 14, 30, 90]}
  ]

  @bar_width 48

  def id, do: :storage

  def loads(ctx) do
    measure =
      if R.task(ctx, "storage.measure"), do: [], else: [{:auto_task, "storage.measure", nil}]

    wizard = if R.page_sub(ctx) == :cleanup, do: CleanupWizard.loads(ctx), else: []
    [{:values, [:storage]}] ++ measure ++ wizard
  end

  def title(ctx) do
    if R.page_sub(ctx) == :cleanup, do: CleanupWizard.title(ctx), else: "Storage"
  end

  def counts(_ctx), do: %{records: nil}
  def attention(_ctx), do: []
  def record_rows(_ctx, _kind, _id), do: []

  def sub_rows(ctx, :cleanup), do: CleanupWizard.rows(ctx)
  def sub_rows(_ctx, _sub), do: []

  # ------------------------------------------------------------------ rows

  def rows(ctx) do
    if R.page_sub(ctx) == :cleanup, do: CleanupWizard.rows(ctx), else: page_rows(ctx)
  end

  defp page_rows(ctx) do
    [
      R.info(
        "storage:intro",
        "What SwarmCode's own database and research folders hold. Nothing here touches your projects.",
        :text_faint
      ),
      R.heading("retention", "retention")
    ] ++
      Enum.map(@retention, &retention_row(ctx, &1)) ++
      [
        R.info(
          "storage:prune_note",
          "Pruning keeps every transcript: a run keeps its tokens, cost and timings, and only the tool output and prompts are dropped. Pinned sessions, open sessions and anything still running are never touched, and the sweep never compacts the file on its own.",
          :text_faint
        ),
        last_sweep_row(ctx),
        overview_heading(ctx)
      ] ++
      overview_rows(ctx) ++
      [R.heading("actions", "actions")] ++ action_rows(ctx)
  end

  defp retention_row(ctx, {key, label, quick}) do
    value = R.value_of(ctx, key)
    row_id = "key:#{key}"

    R.row(
      id: row_id,
      kind: :setting,
      key: key,
      label: label,
      value: [{days_words(value), if(value, do: :text_primary, else: :text_faint)}],
      tag: [{"quick: " <> Enum.map_join(quick, " · ", &quick_words/1), :text_faint}],
      lines: error_lines(ctx, row_id),
      editor:
        {SwarmCodeCLI.UI.Settings.Editors.Number,
         %{
           value: value,
           min: 7,
           max: 3650,
           nullable: true,
           null_label: "off",
           unit: "days",
           quick: quick
         }},
      keys: [{"Enter", :open_row, "edit"}, {"←→", :step, "quick picks"}, {"r", :reset, "off"}],
      target: {:retention, key, quick, value}
    )
  end

  defp quick_words(nil), do: "Off"
  defp quick_words(n), do: "#{n}"

  defp days_words(nil), do: "off"
  defp days_words(n), do: "#{n} days"

  defp last_sweep_row(ctx) do
    at =
      case R.value_of(ctx, "storage.last_sweep") do
        nil -> measure_field(ctx, "last_cleanup_at")
        v -> v
      end

    R.row(
      id: "fact:storage.last_sweep",
      kind: :fact,
      key: "storage.last_sweep",
      label: "Last sweep",
      value: [{sweep_words(at), :text_muted}],
      state: :readonly
    )
  end

  defp sweep_words(nil), do: "never"

  defp sweep_words(iso) when is_binary(iso),
    do: R.local_stamp(iso, "%d %b %Y %H:%M") || iso

  defp sweep_words(other), do: to_string(other)

  defp measure_task(ctx), do: R.task(ctx, "storage.measure")

  defp measure(ctx) do
    case measure_task(ctx) do
      {id, t} ->
        if R.field(t, "state") == "done", do: R.task_summary(ctx, id) || R.field(t, "summary")

      nil ->
        nil
    end
  end

  defp measure_field(ctx, key) do
    case measure(ctx) do
      nil -> nil
      m -> R.field(m, key)
    end
  end

  defp overview_rows(ctx) do
    case {measure_task(ctx), measure(ctx)} do
      {nil, _} ->
        [R.info("storage:measuring", R.glyph(ctx, :running) <> " measuring", :info)]

      {{_id, t} = task, nil} ->
        if R.running?(task),
          do: [
            R.info(
              "storage:measuring",
              "#{R.glyph(ctx, :running)} measuring · #{R.elapsed_s(ctx, t)} s",
              :info
            )
          ],
          else: [
            R.info(
              "storage:measure_failed",
              R.glyph(ctx, :error) <>
                " " <> to_string(R.field(t, "message") || "the measure failed"),
              :error
            )
          ]

      {{_id, _t}, m} ->
        kinds = R.field(m, "kinds") || []
        total = kinds |> Enum.map(&(R.field(&1, "bytes") || 0)) |> Enum.sum()

        bar =
          R.row(
            id: "info:storage:bar",
            kind: :info,
            label: "",
            value: bar_segments(ctx, kinds, total),
            state: :readonly
          )

        # Pass 75 (R27.1): each kind wears its bar texture in the mark slot;
        # the count and the size line up right.
        legend =
          for {k, i} <- Enum.with_index(kinds) do
            {texture, role} = texture(i, R.field(k, "kind"), nil)

            R.row(
              id: "info:storage:kind:#{R.field(k, "kind")}",
              kind: :info,
              label: R.field(k, "label"),
              marks: [{:swatch, texture, role}],
              # QA F-21: counts in thin groups, as Pricing prints them (`12 496`).
              value: [
                {String.pad_leading(
                   SwarmCodeCLI.UI.Settings.Sections.Pricing.group_digits(R.field(k, "count")),
                   6
                 ), :text_primary},
                {" · ", :text_faint},
                {String.pad_leading(R.bytes(R.field(k, "bytes")), 8), :text_primary}
              ]
            )
          end

        line =
          "#{R.bytes(R.field(m, "db_bytes"))} on disk · #{R.bytes(R.field(m, "wal_bytes"))} write-ahead log · at least #{R.bytes(R.field(m, "reclaimable_bytes"))} reclaimable · #{R.field(m, "isolation_dirs") || 0} isolation directories (#{R.bytes(R.field(m, "isolation_bytes"))}) · #{R.count(R.field(m, "sessions") || 0, "session")}"

        [bar] ++ legend ++ [R.info("storage:line", line)]
    end
  end

  # `overview`, with when it was measured as its tag (pass 75, R27.1).
  defp overview_heading(ctx) do
    tag =
      case {measure_task(ctx), measure(ctx)} do
        {{_id, t}, m} when not is_nil(m) ->
          [{"measured #{R.hhmm(R.field(t, "at")) || "just now"}", :text_faint}]

        _ ->
          []
      end

    R.heading("overview", "overview", tag)
  end

  @textures [:tex_1, :tex_2, :tex_3, :tex_4, :tex_5]
  @roles [:text_muted, :text_faint]

  # Pass 75 (R27.1): a texture strip the width of the page less four, one
  # texture per kind (`█ ▓ ▒ ░ ▄`, ASCII `# = - . :`) in quiet roles that
  # alternate; `warning` only for the bar's subject, never `text_primary`.
  defp bar_segments(ctx, kinds, total, subject_kind \\ nil) do
    bytes = Enum.map(kinds, &(R.field(&1, "bytes") || 0))
    cells = shares(bytes, total, bar_width(ctx))

    kinds
    |> Enum.zip(cells)
    |> Enum.with_index()
    |> Enum.map(fn {{k, cells}, i} ->
      {texture, role} = texture(i, R.field(k, "kind"), subject_kind)
      {String.duplicate(Glyphs.get(texture, R.tier(ctx)), cells), role}
    end)
  end

  # Each kind's cells of a `width`-cell bar: its share, at least one for a
  # kind that holds bytes, the largest remainders first so the bar is whole.
  defp shares(bytes, total, _width) when total <= 0, do: Enum.map(bytes, fn _ -> 0 end)

  defp shares(bytes, total, width) do
    raw = Enum.map(bytes, &(&1 * width / total))
    floor = Enum.zip_with(raw, bytes, fn r, b -> if b > 0, do: max(1, trunc(r)), else: 0 end)
    diff = width - Enum.sum(floor)

    order =
      raw
      |> Enum.zip(floor)
      |> Enum.with_index()
      |> Enum.sort_by(fn {{r, f}, _i} -> f - r end)
      |> Enum.map(&elem(&1, 1))

    cond do
      diff > 0 ->
        extra = order |> Stream.cycle() |> Enum.take(diff) |> Enum.frequencies()
        floor |> Enum.with_index() |> Enum.map(fn {f, i} -> f + Map.get(extra, i, 0) end)

      diff < 0 ->
        trim(floor, -diff)

      true ->
        floor
    end
  end

  # Takes `n` cells from the widest kinds (never below one cell).
  defp trim(cells, 0), do: cells

  defp trim(cells, n) do
    {widest, at} = cells |> Enum.with_index() |> Enum.max_by(&elem(&1, 0))
    if widest <= 1, do: cells, else: trim(List.replace_at(cells, at, widest - 1), n - 1)
  end

  defp texture(i, kind, subject_kind) do
    role = if kind != nil and kind == subject_kind, do: :warning, else: Enum.at(@roles, rem(i, 2))
    {Enum.at(@textures, rem(i, 5)), role}
  end

  defp bar_width(ctx) do
    case Map.get(ctx, :size) do
      %{columns: columns, rows: rows} when is_integer(columns) and is_integer(rows) ->
        case Grid.for(columns, rows) do
          %Grid{page: %{width: page}} -> page - 4
          %Grid{} -> @bar_width
        end

      _ ->
        @bar_width
    end
  end

  defp action_rows(ctx) do
    measure = measure_task(ctx)
    vacuum = R.task(ctx, "storage.vacuum")
    retention = R.task(ctx, "storage.apply_retention")
    policies? = Enum.any?(@retention, fn {key, _, _} -> R.value_of(ctx, key) != nil end)

    {measure_value, measure_tag} =
      if measure,
        do:
          R.task_words(ctx, measure, "measuring", fn m ->
            "#{R.bytes(R.field(m, "db_bytes"))} on disk"
          end),
        else: {[{"runs when this page opens", :text_faint}], []}

    {vacuum_value, vacuum_tag} =
      if vacuum,
        do:
          R.task_words(ctx, vacuum, "rewriting the database file", fn s ->
            "the file went from #{R.bytes(R.field(s, "before"))} to #{R.bytes(R.field(s, "after"))}"
          end),
        else: {[{"compacts the file; deletes nothing", :text_faint}], []}

    {retention_value, retention_tag} =
      cond do
        retention ->
          R.task_words(ctx, retention, "applying retention", fn s ->
            if (R.field(s, "items") || 0) > 0,
              do:
                "Freed #{R.bytes(R.field(s, "freed_bytes"))} from #{R.count(R.field(s, "items"), "item")}",
              else: "Nothing was removed"
          end)

        policies? ->
          {[{"the desktop app normally does this daily", :text_faint}], []}

        true ->
          {[{"set a retention first", :text_faint}], []}
      end

    [
      R.row(
        id: "act:storage.measure",
        kind: :action,
        label: if(measure, do: "▸ Re-measure", else: "▸ Measure"),
        value: measure_value,
        tag: measure_tag,
        state: if(R.running?(measure), do: :running, else: :normal),
        keys: [{"Enter", :open_row, "measure"}],
        target: {:measure}
      ),
      R.row(
        id: "act:storage.cleanup",
        kind: :action,
        label: "▸ Clean up…",
        value: [{"choose what to delete or prune; you review it first", :text_faint}],
        keys: [{"Enter", :open_row, "open"}],
        target: {:cleanup}
      ),
      R.row(
        id: "act:storage.vacuum",
        kind: :action,
        label: "▸ Reclaim disk space (VACUUM)",
        value: vacuum_value,
        tag: vacuum_tag,
        state: if(R.running?(vacuum), do: :running, else: :normal),
        keys: [{"Enter", :open_row, "start"}],
        target: {:vacuum}
      ),
      R.row(
        id: "act:storage.apply_retention",
        kind: :action,
        label: "▸ Apply retention now",
        value: retention_value,
        tag: retention_tag,
        state:
          cond do
            R.running?(retention) -> :running
            policies? -> :normal
            true -> :disabled
          end,
        keys: [{"Enter", :open_row, "apply"}],
        target: {:apply_retention, policies?}
      )
    ]
  end

  defp error_lines(ctx, row_id) do
    case R.row_error(ctx, row_id) do
      nil -> []
      m -> [[{R.glyph(ctx, :error) <> " " <> m, :error}]]
    end
  end

  # ------------------------------------------------------------------- act

  def act(ctx, row, verb) do
    if R.page_sub(ctx) == :cleanup do
      CleanupWizard.act(ctx, row, verb)
    else
      page_act(ctx, Map.get(row, :target), verb)
    end
  end

  defp page_act(ctx, target, verb) do
    case {target, verb} do
      {{:measure}, :open_row} ->
        [{:task, "storage.measure", nil, %{}}]

      {{:cleanup}, :open_row} ->
        CleanupWizard.open_ops(ctx)

      {{:vacuum}, :open_row} ->
        if(R.running?(R.task(ctx, "storage.vacuum")),
          do: [{:toast, "A cleanup is already running.", :info}],
          else: [{:task, "storage.vacuum", nil, %{}}]
        )

      {{:apply_retention, false}, :open_row} ->
        [{:toast, "set a retention first", :info}]

      {{:apply_retention, true}, :open_row} ->
        [{:task, "storage.apply_retention", nil, %{}}]

      {{:retention, key, quick, value}, :step} ->
        [{:patch, key, next_quick(quick, value)}]

      {{:retention, _key, _quick, nil}, :reset} ->
        [{:toast, "Already off", :info}]

      {{:retention, key, _quick, _value}, :reset} ->
        [{:patch, key, nil}]

      _ ->
        :default
    end
  end

  defp next_quick(quick, value) do
    case Enum.find_index(quick, &(&1 == value)) do
      nil -> Enum.find(quick, &(is_integer(&1) and is_integer(value) and &1 > value))
      i -> Enum.at(quick, rem(i + 1, length(quick)))
    end
  end

  # ---------------------------------------------------------------- commit

  def commit(ctx, row, value) do
    if R.page_sub(ctx) == :cleanup do
      CleanupWizard.commit(ctx, row, value)
    else
      case Map.get(row, :target) do
        {:retention, key, _quick, current} ->
          case validate_days(value) do
            {:ok, ^current} -> []
            {:ok, v} -> [{:patch, key, v}]
            {:error, m} -> [{:row_error, row.id, m}]
          end

        _ ->
          :default
      end
    end
  end

  @doc "Validates a retention value: nil/`off`, or 7–3650 days."
  def validate_days(nil), do: {:ok, nil}
  def validate_days("off"), do: {:ok, nil}
  def validate_days(n) when is_integer(n) and n >= 7 and n <= 3650, do: {:ok, n}
  def validate_days(n) when is_integer(n), do: {:error, "must be between 7 and 3650"}

  def validate_days(text) when is_binary(text) do
    case Integer.parse(String.trim(text)) do
      {n, rest} when rest in ["", "d", " days", "days"] ->
        validate_days(n)

      _ ->
        if String.trim(text) == "", do: {:ok, nil}, else: {:error, "must be between 7 and 3650"}
    end
  end

  def validate_days(_), do: {:error, "must be between 7 and 3650"}
end
