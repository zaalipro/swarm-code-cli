defmodule SwarmCode.Daemon.Service.Settings.Usage do
  @moduledoc """
  The `usage` view and `records:usage_rows` (pass 74, spec §3.3.6): this month's
  spend (the source `FeatureCatalog.usage/1` reads) against the budget, and the
  last 30 days by model — tokens in and out and the cost, nil for a model that
  has no price.
  """
  @behaviour SwarmCode.Daemon.Service.Settings.Handler

  import Ecto.Query, only: [from: 2]

  alias SwarmCode.Daemon.Service.Settings.{Context, Error, Values}
  alias SwarmCode.Domain.Conversations.Run
  alias SwarmCode.Domain.Repo

  @rows 200

  @impl true
  def actions, do: []

  @impl true
  def command(_command, _ctx), do: {:error, Error.unsupported()}

  @impl true
  def views, do: [{"usage", nil}, {"records", "usage_rows"}]

  @impl true
  def query("usage", _kind, _params, %Context{}), do: {:ok, body()}

  def query("records", "usage_rows", _params, %Context{}) do
    rows = by_model()

    {:ok,
     %{
       "kind" => "usage_rows",
       "items" => Enum.map(rows, &%{"kind" => "usage_row", "id" => &1["model"], "fields" => &1}),
       "next_cursor" => nil,
       "total" => length(rows)
     }}
  end

  def query(_view, _kind, _params, _ctx), do: {:error, Error.unsupported()}

  @doc "The usage body."
  @spec body() :: map()
  def body do
    row = Values.settings_row()

    %{
      "month" => %{"spend_usd" => month_spend(), "budget_usd" => budget(row)},
      "by_model" => by_model()
    }
  end

  defp budget(nil), do: nil
  defp budget(%{monthly_budget_usd: nil}), do: nil

  defp budget(%{monthly_budget_usd: value}) when is_float(value),
    do: if(value == Float.round(value), do: trunc(value), else: value)

  defp budget(%{monthly_budget_usd: value}), do: value

  @doc "This calendar month's spend in USD (runs started this month)."
  @spec month_spend() :: number()
  def month_spend do
    first =
      DateTime.utc_now()
      |> DateTime.to_date()
      |> Date.beginning_of_month()
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")

    Repo.one(from(r in Run, where: r.started_at >= ^first, select: sum(r.cost_usd))) || 0
  end

  @doc "The last 30 days by model, most expensive first (≤ 200 rows)."
  @spec by_model() :: [map()]
  def by_model do
    since = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)
    pricing = pricing()

    from(r in Run,
      where: r.started_at >= ^since and not is_nil(r.model),
      group_by: r.model,
      select: {r.model, sum(r.tokens_in), sum(r.tokens_out), sum(r.cost_usd)},
      order_by: [desc: sum(r.tokens_in)],
      limit: ^@rows
    )
    |> Repo.all()
    |> Enum.map(fn {model, tokens_in, tokens_out, cost} ->
      priced? = is_map(pricing) and Map.has_key?(pricing, model)

      %{
        "model" => model,
        "input_tokens" => tokens_in || 0,
        "output_tokens" => tokens_out || 0,
        "cost_usd" => if(priced?, do: cost || 0.0, else: nil)
      }
    end)
    |> Enum.sort_by(&(-(&1["cost_usd"] || 0)))
  end

  defp pricing do
    case Values.settings_row() do
      %{pricing: pricing} when is_map(pricing) -> pricing
      _ -> %{}
    end
  end
end
