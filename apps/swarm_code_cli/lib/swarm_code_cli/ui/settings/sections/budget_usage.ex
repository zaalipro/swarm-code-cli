defmodule SwarmCodeCLI.UI.Settings.Sections.BudgetUsage do
  @moduledoc """
  pass74 U3-11 (spec §2.19): Budget & usage. The monthly budget (whole
  dollars; a target, nothing is blocked; a stored value this CLI does not
  understand, such as `12.5`, is the registry row's *invalid* state), this
  month's spend with a gauge against the budget, and the last 30 days by
  model: tokens in and out and the cost, `no price` for a model Pricing has
  no row for (it counts as $0.00 everywhere, AT5).
  """

  use SwarmCodeCLI.UI.Settings.Section, id: :budget

  alias SwarmCodeCLI.UI.Settings.{Glyphs, Row, Rows}

  @gauge_cells 20

  @impl true
  def loads(_ctx), do: [{:values, [:budget]}, :usage]

  @impl true
  def rows(ctx) do
    ctx
    |> Rows.registry(:budget)
    |> Enum.flat_map(fn
      %Row{key: "budget.month"} = row -> [month_row(row, ctx)]
      %Row{key: "budget.by_model"} = row -> by_model_rows(row, ctx)
      row -> [row]
    end)
  end

  defp month_row(row, ctx) do
    case usage(ctx) do
      nil ->
        %Row{row | value: [{"…", :text_faint}], state: :loading}

      usage ->
        # the view's DTO carries the month's two numbers at its top level
        month = get(usage, :month) || usage
        spend = number(get(month, :spend_usd)) || 0.0
        budget = number(get(month, :budget_usd))

        value =
          case budget do
            nil ->
              [{money(spend), :text_primary}, {" this month · no budget", :text_muted}]

            budget ->
              [{money(spend), :text_primary}, {" of #{money(budget)}  ", :text_muted}] ++
                gauge(spend, budget, ctx) ++ [{"  " <> percent(spend, budget), :text_faint}]
          end

        %Row{row | value: value, state: :readonly}
    end
  end

  defp by_model_rows(row, ctx) do
    items =
      case usage(ctx) do
        nil -> nil
        usage -> get(usage, :by_model) || []
      end

    head = %Row{row | value: [], state: :readonly}

    cond do
      is_nil(items) ->
        [%Row{head | value: [{"…", :text_faint}], state: :loading}]

      items == [] ->
        [%Row{head | value: [{"nothing used in the last 30 days", :text_ghost}]}]

      true ->
        header =
          Row.info("usage-head", [{"", :text_faint}],
            label: "model",
            role: :text_faint
          )

        header = %Row{
          header
          | columns: [{"in", :text_faint, 2}, {"out", :text_faint, 3}, {"cost", :text_faint, 1}]
        }

        [head, header | Enum.map(Enum.with_index(items), &model_row/1)]
    end
  end

  defp model_row({item, index}) do
    model = get(item, :model) || "?"
    cost = number(get(item, :cost_usd) || get(item, :cost))

    cost_cell =
      case cost do
        nil -> {"no price", :warning}
        cost -> {money(cost), :text_primary}
      end

    %Row{
      id: "usage:#{index}",
      kind: :info,
      label: model,
      value: [],
      columns: [
        {tokens(get(item, :input_tokens)), :text_muted, 2},
        {tokens(get(item, :output_tokens)), :text_muted, 3},
        {elem(cost_cell, 0), elem(cost_cell, 1), 1}
      ],
      target: {:model, model}
    }
  end

  # ------------------------------------------------------------ formatting

  @doc "Whole dollars without cents, else two decimals: `$50`, `$38.20`."
  @spec money(number()) :: String.t()
  def money(value) when is_integer(value), do: "$#{value}"

  def money(value) when is_float(value) do
    if value == Float.round(value) and value >= 1,
      do: "$#{trunc(value)}",
      else: "$" <> :erlang.float_to_binary(value, decimals: 2)
  end

  @doc "Tokens in thousands or millions: `812`, `41.2 k`, `3.10 M`."
  @spec tokens(term()) :: String.t()
  def tokens(n) when is_integer(n) and n < 1_000, do: Integer.to_string(n)
  def tokens(n) when is_integer(n) and n < 1_000_000, do: "#{Float.round(n / 1_000, 1)} k"
  def tokens(n) when is_integer(n), do: "#{:erlang.float_to_binary(n / 1_000_000, decimals: 2)} M"
  def tokens(_), do: "—"

  @doc "The spend gauge: filled cells for the share of the budget, at most full."
  @spec gauge(number(), number(), term()) :: [{String.t(), atom()}]
  def gauge(spend, budget, ctx) do
    tier = tier(ctx)
    share = if budget > 0, do: min(spend / budget, 1.0), else: 1.0
    on = round(share * @gauge_cells)
    role = if spend > budget, do: :warning, else: :text_muted

    [
      {String.duplicate(Glyphs.get(:gauge_on, tier), on), role},
      {String.duplicate(Glyphs.get(:gauge_off, tier), @gauge_cells - on), :text_ghost}
    ]
  end

  defp percent(_spend, budget) when budget <= 0, do: "over"
  defp percent(spend, budget), do: "#{round(spend / budget * 100)} %"

  defp number(n) when is_number(n), do: n
  defp number(_), do: nil

  defp tier(ctx) do
    caps = Map.get(ctx || %{}, :caps)

    cond do
      is_map(caps) and Map.get(caps, :ascii?) == true -> :ascii
      is_map(caps) -> Map.get(caps, :glyph_tier, :measured)
      true -> :measured
    end
  end

  defp usage(ctx), do: ctx.data |> Map.get(:usage)

  defp get(nil, _key), do: nil
  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp get(_other, _key), do: nil
end
