defmodule SwarmCodeCLI.UI.Projector.Vitals do
  @moduledoc """
  cli021 U1: the session's vitals — output tokens/second per model the shown
  conversation uses and the RAM ncode costs — drawn as the side panel's top
  section, or in one compact form where the panel is not drawn
  (`docs/superpowers/plans/2026-10-08-cli-0.2.1/notes/U.md` has the mockups).

  The panel section is one table: a `speed` heading with its unit over the
  numbers, one row per model (a dot, the slot words when the dock is wide
  enough, the model name cut in its middle, a sparkline of the recent samples
  on one shared scale, the latest number), then the `RAM` row (a gauge on a
  baseline and the number on the same right edge) and under it what the gauge
  measures against (`of 16 GB`) with the app's and its tools' shares where
  they fit. What streams now is lit in its slot's colour; idle models are
  dim. No data draws nothing.

  `read/1` is the one seam to C2's wire (`DTO.Vitals`, `DTO.ModelSpeed`).
  """
  alias SwarmCodeCLI.UI.Projector.Inspector
  alias SwarmCodeCLI.UI.Projector.Panel.{Draw, Glyph}

  @max_rows 4
  @history 12
  @mib 1_048_576
  @gib 1_073_741_824
  # The soft scale of the RAM gauge when the Mac's memory is not known.
  @soft_scale 2 * @gib
  # Rows the run body keeps under the full section before it folds to one row.
  @body_rows 12
  @min_height 10
  # The cells a model name keeps before the slot words give way.
  @name_floor 18

  @type model :: %{
          model: String.t(),
          roles: [:main | :worker | :validator | :other],
          tps: number() | nil,
          history: [number()],
          live?: boolean()
        }
  @type memory :: %{
          total: pos_integer(),
          app: non_neg_integer() | nil,
          tools: non_neg_integer() | nil,
          system: pos_integer() | nil
        }

  # ------------------------------------------------------------------ the seam

  @doc """
  The vitals in view, normalised: `%{models: [model], memory: memory | nil}`,
  or nil when there is nothing to draw.

  Reads C2's `state.read_model.vitals` (`DTO.Vitals`): `models` of
  `DTO.ModelSpeed` (`slot`, `model`, `tps`, `live`, `history`, `at`; one per
  slot, so a model in two slots becomes one row naming both), and the memory
  fields `beam_bytes` (the VM, daemon and terminal client together),
  `os_rss_bytes` (the VM's resident size), `children_rss_bytes` (what it
  started: the renderer, tool commands) and `machine_bytes`. Speeds of
  another conversation than the one shown are left out; the memory is the
  session's. Slots are atoms of a closed enum on the wire; anything else
  reads as `:other`, never as a new atom.
  """
  @spec read(map()) :: %{models: [model()], memory: memory() | nil} | nil
  def read(%{read_model: read_model} = state) do
    case Map.get(read_model, :vitals) do
      %{} = raw ->
        models =
          if same_conversation?(raw, state),
            do: raw |> Map.get(:models) |> List.wrap() |> Enum.flat_map(&speed/1) |> merge(),
            else: []

        memory = memory(raw)

        if models == [] and memory == nil, do: nil, else: %{models: order(models), memory: memory}

      _ ->
        nil
    end
  end

  def read(_state), do: nil

  defp same_conversation?(raw, state) do
    shown =
      case Map.get(state.read_model.snapshots, :workspace) do
        %{} = workspace -> Map.get(workspace, :conversation_id)
        _ -> nil
      end

    case Map.get(raw, :conversation_id) do
      id when is_binary(id) and is_binary(shown) -> id == shown
      _ -> true
    end
  end

  defp speed(%{} = raw) do
    case Map.get(raw, :model) do
      name when is_binary(name) and name != "" ->
        tps = Map.get(raw, :tps)
        tps = if number?(tps), do: max(tps, 0), else: nil
        live? = Map.get(raw, :live) == true
        history = raw |> Map.get(:history) |> List.wrap() |> Enum.filter(&number?/1)

        # The history holds finished calls' exact rates; a streaming call's
        # estimate is the newest bar.
        samples =
          cond do
            live? and tps -> history ++ [tps]
            history == [] and tps -> [tps]
            true -> history
          end

        [
          %{
            model: String.slice(name, 0, 256),
            roles: [role(Map.get(raw, :slot))],
            tps: tps,
            history: samples |> Enum.map(&max(&1, 0)) |> Enum.take(-@history),
            live?: live?,
            at: if(is_integer(Map.get(raw, :at)), do: Map.get(raw, :at), else: 0)
          }
        ]

      _ ->
        []
    end
  end

  defp speed(_raw), do: []

  # One row per model: its slots together; the numbers of the slot that
  # streams, else of the newest measure.
  defp merge(speeds) do
    speeds
    |> Enum.group_by(& &1.model)
    |> Enum.map(fn {_model, [first | _] = same} ->
      lead =
        Enum.find(same, & &1.live?) ||
          Enum.max_by(same, &{is_number(&1.tps), &1.at}, fn -> first end)

      roles = same |> Enum.flat_map(& &1.roles) |> Enum.uniq() |> Enum.sort_by(&rank/1)
      %{lead | roles: roles, live?: Enum.any?(same, & &1.live?)} |> Map.delete(:at)
    end)
  end

  defp role(slot) when slot in [:main, "main"], do: :main
  defp role(slot) when slot in [:worker, "worker"], do: :worker
  defp role(slot) when slot in [:validator, "validator"], do: :validator
  defp role(_slot), do: :other

  # What the session costs the Mac: the VM's resident size and what it
  # started, else the VM's own total before the first OS reading.
  defp memory(raw) do
    rss = bytes(Map.get(raw, :os_rss_bytes))
    children = bytes(Map.get(raw, :children_rss_bytes))
    beam = bytes(Map.get(raw, :beam_bytes))
    total = if rss, do: rss + (children || 0), else: beam

    if total,
      do: %{
        total: total,
        app: rss && children && rss,
        tools: rss && children && children,
        system: bytes(Map.get(raw, :machine_bytes))
      }
  end

  defp bytes(n) when is_integer(n) and n > 0, do: n
  defp bytes(_), do: nil

  defp number?(n), do: is_integer(n) or is_float(n)

  # The slot order (main, worker, validator, then the rest by name), so rows
  # never trade places while the numbers move.
  defp order(models) do
    Enum.sort_by(models, fn m -> {Enum.min(Enum.map(m.roles, &rank/1)), m.model} end)
  end

  defp rank(:main), do: 0
  defp rank(:worker), do: 1
  defp rank(:validator), do: 2
  defp rank(:other), do: 3

  # ------------------------------------------------------- the panel's section

  @doc """
  The panel's vitals rows for a `width` x `height` pane, the parting blank
  row included: the whole table while the run body keeps #{@body_rows} rows under
  it, else one row, else none (a pane under #{@min_height} rows).
  """
  @spec panel_rows(map(), non_neg_integer(), non_neg_integer()) :: [struct()]
  def panel_rows(state, width, height) do
    case read(state) do
      nil ->
        []

      vitals ->
        full = table(state, vitals, width)

        cond do
          height >= length(full) + 1 + @body_rows -> full ++ [Draw.blank(width, state)]
          height >= @min_height -> [one_row(state, vitals, width), Draw.blank(width, state)]
          true -> []
        end
    end
  end

  defp table(state, %{models: models, memory: memory}, width) do
    shown = Enum.take(models, @max_rows)
    cols = columns(state, shown, width - 2)
    top = scale(shown)

    speed =
      case shown do
        [] ->
          []

        _ ->
          more =
            case length(models) - length(shown) do
              0 -> []
              n -> [Draw.row([{"  +#{n} more", :text_faint}], [], width, state)]
            end

          [Draw.row([{"speed", :text_muted}], [{"tok/s", :text_faint}], width, state)] ++
            Enum.map(shown, &model_row(state, &1, cols, top, width)) ++ more
      end

    speed ++ memory_rows(state, memory, cols, width)
  end

  # The table's columns for `inner` cells: the dot (2), the slot words when
  # the names keep #{@name_floor} cells beside them, the name (what is left), the
  # sparkline, the gap, the number (4).
  defp columns(state, shown, inner) do
    {spark, gap} =
      cond do
        inner >= 50 -> {12, 2}
        inner >= 36 -> {10, 2}
        inner >= 30 -> {8, 2}
        true -> {5, 1}
      end

    name_for = fn role_cells -> inner - 2 - role_cells - 1 - spark - gap - 4 end
    words = Enum.map(shown, &Draw.cells(role_words(&1.roles), state))
    longest = shown |> Enum.map(&Draw.cells(&1.model, state)) |> Enum.max(fn -> 0 end)
    role_w = Enum.max([3 | words])

    role_cells =
      if inner >= 44 and Enum.any?(words, &(&1 > 0)) and
           name_for.(role_w + 2) >= min(@name_floor, longest),
         do: role_w + 2,
         else: 0

    %{
      role_w: if(role_cells > 0, do: role_w, else: 0),
      role_cells: role_cells,
      name: max(1, name_for.(role_cells)),
      spark: spark,
      gap: gap,
      inner: inner
    }
  end

  defp model_row(state, m, cols, top, width) do
    lit? = m.live?
    slot = slot_role(m.roles)

    dot =
      if lit?,
        do: {Glyph.get(:dot_on, state), slot},
        else: {Glyph.get(:dot_off, state), :text_ghost}

    role =
      if cols.role_w > 0,
        do: [
          {Draw.pad_to(role_words(m.roles), cols.role_cells, state),
           if(lit?, do: :text_muted, else: :text_faint)}
        ],
        else: []

    name = m.model |> Draw.elide(cols.name, state, :middle) |> Draw.pad_to(cols.name, state)

    {lead, history, newest} =
      spark_parts(m.history, top, cols.spark, Glyph.tier(state.capabilities))

    # Calm: the history recedes, only the newest bar of what streams is lit;
    # an idle model's line sits on the track.
    spark =
      if lit?,
        do: [{lead, :plain}, {history, :text_ghost}, {newest, slot}],
        else: [{lead, :plain}, {history <> newest, :ticks_track}]

    value =
      case tps_words(m.tps) do
        nil -> {pad_leading(Glyph.get(:minus, state), 4, state), :text_faint, []}
        words when lit? -> {pad_leading(words, 4, state), :text_primary, [:bold]}
        words -> {pad_leading(words, 4, state), :text_faint, []}
      end

    left =
      [dot, {" ", :plain}] ++
        role ++ [{name, if(lit?, do: :text_primary, else: :text_faint)}, {" ", :plain}] ++ spark

    Draw.row(left, [value], width, state)
  end

  defp memory_rows(_state, nil, _cols, _width), do: []

  defp memory_rows(state, memory, cols, width) do
    total = memory.total
    number = bytes_words(total)
    label = if cols.role_cells > 0, do: cols.role_cells, else: 4
    bar = max(1, cols.inner - 2 - label - cols.gap - Draw.cells(number, state))
    {filled, role} = gauge(memory, total, bar)
    # The panel's own gauge (the `found` row's): filled cells on a baseline.
    on = Glyph.get(:report_on, state)
    off = Glyph.get(:report_off, state)

    row =
      Draw.row(
        [
          {"  ", :plain},
          {Draw.pad_to("RAM", label, state), :text_muted},
          {String.duplicate(on, filled), role},
          {String.duplicate(off, bar - filled), :ticks_track}
        ],
        [{number, :text_primary}],
        width,
        state
      )

    case cols.gap > 1 && breakdown(memory, cols.inner - 2 - label, state) do
      {split, scale} ->
        left = if split == [], do: [], else: [{String.duplicate(" ", 2 + label), :plain} | split]
        [row, Draw.row(left, scale, width, state)]

      _ ->
        [row]
    end
  end

  # Under the gauge: the VM's and its helpers' shares on the left (`app 271
  # MB · tools 41 MB`: the renderer and tool commands), when both are known
  # and fit `room`,
  # and what the gauge measures against under the number (`of 16 GB`).
  defp breakdown(memory, room, state) do
    # Against the Mac's memory when it is known, else the soft scale says so.
    scale =
      case memory.system do
        s when is_integer(s) -> [{"of " <> bytes_words(s), :text_faint}]
        _ -> [{"scale " <> bytes_words(soft(memory.total, @soft_scale)), :text_ghost}]
      end

    scale_cells = Draw.cells(elem(hd(scale), 0), state) + 2

    words =
      if memory.app && memory.tools,
        do: "app #{bytes_words(memory.app)} · tools #{bytes_words(memory.tools)}"

    split =
      if words && Draw.cells(words, state) <= room - scale_cells,
        do: [{words, :text_faint}],
        else: []

    {split, scale}
  end

  # The gauge's filled cells and their role: against the Mac's memory when it
  # is known (warning from half, error from four fifths), else a soft scale.
  defp gauge(memory, total, bar) do
    {scale, known?} =
      case memory.system do
        s when is_integer(s) -> {s, true}
        _ -> {soft(total, @soft_scale), false}
      end

    share = total / scale

    filled =
      total |> Kernel.*(bar) |> Kernel./(scale) |> Float.ceil() |> trunc() |> max(1) |> min(bar)

    role =
      cond do
        known? and share >= 0.8 -> :error
        known? and share >= 0.5 -> :warning
        true -> :text_muted
      end

    {filled, role}
  end

  defp soft(total, scale) when total > scale, do: soft(total, scale * 2)
  defp soft(_total, scale), do: scale

  # A pane too short for the table: `● 142 tok/s · deepseek-v4.1-flash  RAM 312 MB`.
  defp one_row(state, %{models: models, memory: memory}, width) do
    left =
      case busiest(models) do
        nil ->
          []

        m ->
          dot =
            if m.live?,
              do: {Glyph.get(:dot_on, state), slot_role(m.roles)},
              else: {Glyph.get(:dot_off, state), :text_ghost}

          [
            dot,
            {" " <> tps_words(m.tps) <> " tok/s",
             if(m.live?, do: :text_primary, else: :text_faint)},
            {" · ", :text_ghost},
            {m.model, :text_muted}
          ]
      end

    right =
      case memory do
        %{total: n} -> [{"RAM " <> bytes_words(n), :text_muted}]
        _ -> []
      end

    Draw.row(left, right, width, state)
  end

  # ------------------------------------------------------------ compact forms

  @doc """
  Where the vitals go in the frame `layout` lays out: `:panel` when the dock
  draws its agents tab and is tall enough for a vitals row, `:strip` when the
  one-row strip is drawn, else `:status` (the status line).
  """
  @spec placement(map(), map()) :: :panel | :strip | :status
  def placement(%{rects: rects}, state) do
    dock = Map.get(rects, :inspector)

    cond do
      dock != nil and Inspector.tab(state) == :agents and Map.get(dock, :height, 0) >= @min_height ->
        :panel

      Map.has_key?(rects, :tabline) ->
        :strip

      true ->
        :status
    end
  end

  @doc """
  The compact form, `[{text, role}]`: the busiest model's tok/s (faint when
  nothing streams) and the RAM, or [] when there is nothing to say.
  """
  @spec compact(map()) :: [{String.t(), atom()}]
  def compact(state) do
    case read(state) do
      nil ->
        []

      %{models: models, memory: memory} ->
        speed =
          case busiest(models) do
            nil -> []
            m -> [{tps_words(m.tps) <> " tok/s", if(m.live?, do: :text_muted, else: :text_faint)}]
          end

        ram =
          case memory do
            %{total: n} -> [{"RAM " <> bytes_words(n), :text_muted}]
            _ -> []
          end

        Enum.intersperse(speed ++ ram, {" · ", :text_ghost})
    end
  end

  @doc """
  cli021 qa: the compact form as separate status facts, `[{kind, words,
  role}]` with kind `:live_speed`, `:speed` (the newest measure, nothing
  streams) or `:ram`, so the status line can keep a live speed while the RAM
  gives way (the whole form used to go at once, exactly while a model
  streamed).
  """
  @spec status_parts(map()) :: [{:live_speed | :speed | :ram, String.t(), atom()}]
  def status_parts(state) do
    case read(state) do
      nil ->
        []

      %{models: models, memory: memory} ->
        speed =
          case busiest(models) do
            nil -> []
            %{live?: true} = m -> [{:live_speed, tps_words(m.tps) <> " tok/s", :text_muted}]
            m -> [{:speed, tps_words(m.tps) <> " tok/s", :text_faint}]
          end

        ram =
          case memory do
            %{total: n} -> [{:ram, "RAM " <> bytes_words(n), :text_muted}]
            _ -> []
          end

        speed ++ ram
    end
  end

  # The live model with the most tok/s; when none streams, the measured one
  # with the most (the newest measure is what each model shows).
  defp busiest(models) do
    measured = Enum.filter(models, &is_number(&1.tps))

    case Enum.filter(measured, & &1.live?) do
      [] -> Enum.max_by(measured, & &1.tps, fn -> nil end)
      live -> Enum.max_by(live, & &1.tps)
    end
  end

  # ------------------------------------------------------------ the sparkline

  @spark ~w(spark_1 spark_2 spark_3 spark_4 spark_5 spark_6 spark_7 spark_8)a

  @doc """
  `samples` (oldest first) as a `cells`-wide sparkline at a glyph tier: the
  newest at the right, blanks where there is no sample, each bar's height on
  the shared scale `0..top` (a zero is the baseline).
  """
  @spec spark([number()], number(), non_neg_integer(), :rich | :measured | :ascii) :: String.t()
  def spark(samples, top, cells, tier) do
    {lead, history, newest} = spark_parts(samples, top, cells, tier)
    lead <> history <> newest
  end

  defp spark_parts(samples, top, cells, tier) do
    shown = Enum.take(samples, -cells)

    glyphs =
      Enum.map(shown, fn v ->
        level = if top > 0, do: round(v / top * 7), else: 0
        @spark |> Enum.at(level |> max(0) |> min(7)) |> Glyph.get(tier)
      end)

    lead = String.duplicate(" ", cells - length(glyphs))

    case glyphs do
      [] -> {lead, "", ""}
      _ -> {lead, glyphs |> Enum.drop(-1) |> Enum.join(), List.last(glyphs)}
    end
  end

  defp scale(models) do
    models
    |> Enum.flat_map(&[&1.tps | &1.history])
    |> Enum.filter(&is_number/1)
    |> Enum.max(fn -> 0 end)
  end

  # ------------------------------------------------------------------- words

  @doc "`142`, `1.2k`, `12k`; nil for no measure."
  def tps_words(nil), do: nil
  def tps_words(n) when n < 999.5, do: Integer.to_string(round(n))
  def tps_words(n) when n < 9_950, do: one_decimal(n / 1000) <> "k"
  def tps_words(n), do: "#{round(n / 1000)}k"

  @doc "`312 MB`, `1.5 GB`, `16 GB` (binary units, like the desktop's RAM chip)."
  def bytes_words(n) when n < @gib, do: "#{div(n, @mib)} MB"
  def bytes_words(n), do: one_decimal(n / @gib) <> " GB"

  defp one_decimal(x),
    do: x |> :erlang.float_to_binary(decimals: 1) |> String.replace_suffix(".0", "")

  defp role_words(roles) do
    roles
    |> Enum.map(fn
      :main -> "main"
      :worker -> "worker"
      :validator -> "validator"
      :other -> "other"
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join("+")
  end

  # The slot's colour: the chat's, the swarm's (workers), Ultra's (the
  # validator); a model only other runs used is muted.
  defp slot_role(roles) do
    cond do
      :main in roles -> :run_assistant
      :worker in roles -> :run_swarm
      :validator in roles -> :run_ultra
      true -> :text_muted
    end
  end

  defp pad_leading(text, n, state) do
    String.duplicate(" ", max(0, n - Draw.cells(text, state))) <> text
  end
end
