defmodule SwarmCodeCLI.UI.Settings.Sections.DeepResearch do
  @moduledoc """
  pass74 U3-5 (spec §2.6, F7 second page): Deep research. The level with this
  machine's measured medians (or `not measured yet`), the clocks and caps,
  the domain lists, the designed report, and the three tiers — lead, worker,
  reporter — each with its model (the sub-agent model when unset), effort and
  how many runs it makes per research at the chosen level (the desktop's
  `tier_runs/2`, from `facts.research_levels`). The research folder is a fact
  row: `o` opens it, `y` copies the path.
  """

  use SwarmCodeCLI.UI.Settings.Section, id: :deep_research

  alias SwarmCodeCLI.UI.Settings.{Row, Rows}

  # Research.Levels as the desktop defines them, for a snapshot without facts.
  @levels %{
    "low" => %{label: "Fastest", steps: 1, fanout: 4, fast: true},
    "medium" => %{label: "Medium", steps: 2, fanout: 3, fast: false},
    "high" => %{label: "High", steps: 3, fanout: 4, fast: false},
    "ultra" => %{label: "Ultra", steps: 4, fanout: 10, fast: false}
  }

  @tiers [
    {"lead", "research.lead_model", "research.lead_effort"},
    {"worker", "research.worker_model", "research.worker_effort"},
    {"reporter", "research.reporter_model", "research.reporter_effort"}
  ]

  @impl true
  def loads(_ctx), do: [{:values, [:deep_research]}, :facts]

  @impl true
  def rows(ctx) do
    ctx
    |> Rows.registry(:deep_research)
    |> Enum.map(&decorate(&1, ctx))
  end

  @impl true
  def act(ctx, %Row{key: "research.root"}, verb) when verb in [:open_related, :open] do
    case root(ctx) do
      nil -> [{:toast, "The research folder is not known yet", :warning}]
      path -> [{:open_folder, path}]
    end
  end

  def act(ctx, %Row{key: "research.root"}, :copy) do
    case root(ctx) do
      nil -> :default
      path -> [{:copy, path}, {:toast, "Copied #{path}", :success}]
    end
  end

  def act(_ctx, _row, _verb), do: :default

  # ------------------------------------------------------------------ rows

  defp decorate(%Row{key: "research.level"} = row, ctx) do
    level = value(ctx, "research.level") || "medium"
    info = level_info(ctx, level)

    line =
      "#{info.label}: #{rounds(info.steps)} · #{info.fanout} agents each · #{level_hint(ctx, level)}"

    %Row{row | lines: row.lines ++ [[{line, :text_faint}]]}
  end

  defp decorate(%Row{key: key} = row, ctx) do
    case Enum.find(@tiers, fn {_tier, model, _effort} -> model == key end) do
      {tier, _model, _effort} ->
        %Row{
          row
          | lines: row.lines ++ [[{"runs per research: #{tier_runs(ctx, tier)}", :text_faint}]]
        }

      nil ->
        if key == "research.root", do: root_row(row, ctx), else: row
    end
  end

  defp root_row(row, ctx) do
    case root(ctx) do
      nil ->
        row

      path ->
        %Row{
          row
          | value: [{path, :text_muted}],
            keys: [{"o", :open_related, "open the folder"}, {"y", :copy, "copy the path"}]
        }
    end
  end

  # ------------------------------------------------------------- the rules

  @doc """
  The desktop's `tier_runs/2`: how many model runs a tier makes in one
  research at `level` (lead: steps, doubled for headlines unless the level is
  fast; worker: steps × fanout; reporter: 2 when the designed report starts
  by itself at that level, else 1).
  """
  @spec tier_runs(String.t(), String.t(), boolean(), String.t(), map()) :: pos_integer()
  def tier_runs(tier, level, headlines?, auto_design, levels \\ @levels) do
    info = Map.get(levels, level) || Map.fetch!(@levels, "medium")

    case tier do
      "lead" -> if headlines? and not info.fast, do: info.steps * 2, else: info.steps
      "worker" -> info.steps * info.fanout
      "reporter" -> if auto_design?(auto_design, info), do: 2, else: 1
    end
  end

  defp auto_design?("all", _info), do: true
  defp auto_design?("never", _info), do: false
  defp auto_design?(_deep, info), do: not info.fast

  @doc "A level's hint: this machine's median time, or `not measured yet`."
  @spec median_words(integer() | nil) :: String.t()
  def median_words(ms) when is_integer(ms) and ms > 0 do
    seconds = div(ms + 500, 1000)

    cond do
      seconds < 90 -> "median #{seconds} s on this machine"
      seconds < 5400 -> "median #{div(seconds + 30, 60)} min on this machine"
      true -> "median #{Float.round(seconds / 3600, 1)} h on this machine"
    end
  end

  def median_words(_), do: "not measured yet"

  defp tier_runs(ctx, tier) do
    level = value(ctx, "research.level") || "medium"
    headlines? = value(ctx, "research.headlines") != false
    auto = value(ctx, "research.auto_design") || "deep"
    "#{tier_runs(tier, level, headlines?, auto, levels(ctx))} on #{level}"
  end

  defp level_hint(ctx, level) do
    ctx
    |> facts_levels()
    |> Enum.find(fn l -> get(l, :key) == level end)
    |> case do
      nil -> "not measured yet"
      l -> median_words(get(l, :median_ms))
    end
  end

  defp level_info(ctx, level), do: Map.get(levels(ctx), level) || Map.fetch!(@levels, "medium")

  defp levels(ctx) do
    case facts_levels(ctx) do
      [] ->
        @levels

      list ->
        Enum.reduce(list, @levels, fn l, acc ->
          key = get(l, :key)

          if is_binary(key) and is_integer(get(l, :steps)) and is_integer(get(l, :fanout)) do
            Map.put(acc, key, %{
              label: get(l, :label) || key,
              steps: get(l, :steps),
              fanout: get(l, :fanout),
              fast: get(l, :fast) == true
            })
          else
            acc
          end
        end)
    end
  end

  defp rounds(1), do: "1 round"
  defp rounds(n), do: "#{n} rounds"

  defp facts_levels(ctx) do
    case facts(ctx) |> get(:research_levels) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp root(ctx) do
    case facts(ctx) |> get(:paths) |> get(:research_root) do
      path when is_binary(path) -> path
      _ -> nil
    end
  end

  defp facts(ctx), do: ctx.data |> Map.get(:facts)

  defp value(ctx, key) do
    case ctx.data |> Map.get(:values, %{}) |> Map.get(key) do
      nil -> nil
      value -> get(value, :value)
    end
  end

  defp get(nil, _key), do: nil
  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp get(_other, _key), do: nil
end
