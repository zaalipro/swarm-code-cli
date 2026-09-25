defmodule SwarmCode.Daemon.Service.Settings.Pricing do
  @moduledoc """
  Pricing rows in settings (pass 74 §3.5.2): the rows of the one map column
  `settings.pricing`, each written with compare-and-set on the row as read and
  the desktop's exact row texts, and the models in use that have no row
  (AT5: they count as $0.00 in every cost).
  """

  @behaviour SwarmCode.Daemon.Service.Settings.Handler

  import Ecto.Query, warn: false

  alias SwarmCode.Daemon.Service.Settings.Kit
  alias SwarmCode.Daemon.Service.Settings.Providers, as: ProviderSettings
  alias SwarmCode.Domain.{Cache, Repo, Settings}
  alias SwarmCode.Domain.Conversations.Conversation
  alias SwarmCode.Domain.Pricing, as: Rates
  alias SwarmCode.Domain.Settings.Setting

  @max_model 256
  @window_days 30

  @doc false
  def actions, do: ~w(pricing.put_row pricing.delete_row)

  @doc false
  def views, do: [{"records", "pricing_rows"}, {"records", "unpriced_models"}]

  @doc false
  def cache_reads(_action_or_view), do: []

  ## ------------------------------------------------------------ queries

  @doc false
  def query("records", "pricing_rows", params, _ctx) do
    items =
      (ProviderSettings.settings_row().pricing || %{})
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {model, row} -> Kit.record("pricing_row", model, row_fields(model, row)) end)

    {:ok, Kit.records_body("pricing_row", items, params)}
  end

  def query("records", "unpriced_models", params, ctx) do
    items =
      for row <- unpriced(ctx) do
        Kit.record("unpriced_model", row["model"], row)
      end

    {:ok, Kit.records_body("unpriced_model", items, params)}
  end

  def query(_view, _kind, _params, _ctx), do: unsupported()

  @doc "A row's wire fields, with the cache rates a blank cell would derive."
  @spec row_fields(String.t(), map()) :: map()
  def row_fields(model, row) do
    input = number(Map.get(row, "input")) || 0

    %{
      "model" => model,
      "input" => Map.get(row, "input"),
      "output" => Map.get(row, "output"),
      "cache_read" => Map.get(row, "cache_read"),
      "cache_write" => Map.get(row, "cache_write"),
      "context_window" => Map.get(row, "context_window"),
      "derived_cache_read" => Rates.cache_read_rate(%{}, model, input),
      "derived_cache_write" => Rates.cache_write_rate(%{}, input)
    }
  end

  @doc """
  The models named by a model default or by a conversation updated in the
  last 30 days that have no pricing row: `%{model, conversations_30d,
  in_defaults}`, sorted by model.
  """
  @spec unpriced(map()) :: [map()]
  def unpriced(ctx) do
    settings = ProviderSettings.settings_row()
    priced = settings.pricing || %{}

    defaults =
      for {_key, _pf, mf} <- ProviderSettings.pairs(),
          model = Map.get(settings, mf),
          is_binary(model) and model != "",
          into: MapSet.new(),
          do: model

    since = DateTime.add(Kit.ctx(ctx, :now), -@window_days * 86_400, :second)

    used =
      from(c in Conversation,
        where: c.updated_at >= ^since,
        select: {c.chat_model, c.swarm_model, c.judge_model, c.implementer_model}
      )
      |> Repo.all()
      |> Enum.flat_map(fn row ->
        row |> Tuple.to_list() |> Enum.filter(&(is_binary(&1) and &1 != "")) |> Enum.uniq()
      end)
      |> Enum.frequencies()

    defaults
    |> MapSet.union(MapSet.new(Map.keys(used)))
    |> Enum.reject(&Map.has_key?(priced, &1))
    |> Enum.sort()
    |> Enum.map(fn model ->
      %{
        "model" => model,
        "conversations_30d" => Map.get(used, model, 0),
        "in_defaults" => MapSet.member?(defaults, model)
      }
    end)
  end

  ## ------------------------------------------------------------ commands

  @doc false
  def command(%{action: "pricing.put_row"} = cmd, _ctx) do
    attrs = Kit.cmd(cmd, :attributes)
    expected = Kit.cmd(cmd, :expected)
    rename_from = Kit.string(attrs, "rename_from")

    with {:ok, model, row} <- validate_row(attrs),
         true <- Kit.has?(expected, "row") || missing("row"),
         true <-
           (is_nil(rename_from) or rename_from == model or Kit.has?(expected, "rename_row")) ||
             missing("rename_row") do
      expected_row = Kit.get(expected, "row")

      write(cmd, fn pricing ->
        rename? = is_binary(rename_from) and rename_from != model
        taken? = Map.has_key?(pricing, model)

        cond do
          taken? and (rename? or is_nil(expected_row)) ->
            {:invalid, "model", "duplicate model"}

          not Kit.same?(expected_row, Map.get(pricing, model)) ->
            {:conflict, model, Map.get(pricing, model)}

          rename? and
              not Kit.same?(Kit.get(expected, "rename_row"), Map.get(pricing, rename_from)) ->
            {:conflict, rename_from, Map.get(pricing, rename_from)}

          Map.get(pricing, model) == row and not rename? ->
            :unchanged

          true ->
            pricing = if rename?, do: Map.delete(pricing, rename_from), else: pricing
            {:write, Map.put(pricing, model, row), model}
        end
      end)
    end
  end

  def command(%{action: "pricing.delete_row"} = cmd, _ctx) do
    model = Kit.string(Kit.cmd(cmd, :target), "model")
    expected = Kit.cmd(cmd, :expected)

    with true <- (is_binary(model) and model != "") || Kit.error(:invalid, "name the model"),
         true <- Kit.has?(expected, "row") || missing("row") do
      write(cmd, fn pricing ->
        cond do
          not Kit.same?(Kit.get(expected, "row"), Map.get(pricing, model)) ->
            {:conflict, model, Map.get(pricing, model)}

          not Map.has_key?(pricing, model) ->
            :unchanged

          true ->
            {:write, Map.delete(pricing, model), model}
        end
      end)
    end
  end

  def command(_cmd, _ctx), do: unsupported()

  defp write(cmd, decide) do
    outcome =
      Repo.retry(:settings_pricing, fn ->
        Repo.transaction(fn ->
          fresh = Repo.one(from(s in Setting, order_by: s.inserted_at, limit: 1)) || %Setting{}

          case decide.(fresh.pricing || %{}) do
            {:conflict, model, current} ->
              Repo.rollback({:conflict, model, current})

            {:invalid, field, message} ->
              Repo.rollback({:refused, field, message})

            :unchanged ->
              :unchanged

            {:write, _pricing, model} when cmd.dry_run == true ->
              {:dry_run, model}

            {:write, pricing, model} ->
              case Settings.update(%{pricing: pricing}) do
                {:ok, _} -> {:written, model}
                {:error, changeset} -> Repo.rollback({:invalid, changeset})
              end
          end
        end)
      end)

    case outcome do
      {:ok, {:written, model}} ->
        Cache.delete(:settings)
        Kit.ok(record: record(model), message: "Pricing saved")

      {:ok, {:dry_run, model}} ->
        Kit.ok(record: record(model))

      {:ok, :unchanged} ->
        Kit.ok(:unchanged, [])

      {:error, {:conflict, model, current}} ->
        Kit.ok(:conflict,
          results: [Kit.row(model, :conflict, current: current)],
          message: "#{model}'s price changed while you edited it."
        )

      {:error, {:refused, field, message}} ->
        Kit.error(:invalid, message, [Kit.field_error(field, message)])

      {:error, {:invalid, changeset}} ->
        Kit.changeset_error(changeset)

      {:error, _other} ->
        Kit.error(:busy, "Settings is busy; try again in a moment.")
    end
  end

  defp record(model) do
    case Map.get(ProviderSettings.settings_row().pricing || %{}, model) do
      nil -> nil
      row -> Kit.record("pricing_row", model, row_fields(model, row))
    end
  end

  @doc false
  # The desktop's row validation (D§5), with its exact texts.
  def validate_row(attrs) do
    model = Kit.string(attrs, "model") || ""

    checks = [
      {"model", model_error(model)},
      {"input", required_rate(Kit.get(attrs, "input"), "input")},
      {"output", required_rate(Kit.get(attrs, "output"), "output")},
      {"cache_read", optional_rate(Kit.get(attrs, "cache_read"), "cache read")},
      {"cache_write", optional_rate(Kit.get(attrs, "cache_write"), "cache write")},
      {"context_window", window(Kit.get(attrs, "context_window"))}
    ]

    case for({field, {:error, message}} <- checks, do: Kit.field_error(field, message)) do
      [] ->
        values =
          for {field, {:ok, value}} <- checks, not is_nil(value), into: %{}, do: {field, value}

        {:ok, model, Map.delete(values, "model")}

      [%{message: message} | _] = errors ->
        Kit.error(:invalid, message, errors)
    end
  end

  defp model_error(""), do: {:error, "model: can't be blank"}

  defp model_error(model) do
    if String.length(model) > @max_model,
      do: {:error, "model: should be at most #{@max_model} character(s)"},
      else: {:ok, nil}
  end

  defp required_rate(value, label) do
    case number(value) do
      n when is_number(n) and n >= 0 -> {:ok, n * 1.0}
      _ -> {:error, "#{label}: must be a number ≥ 0"}
    end
  end

  defp optional_rate(value, _label) when value in [nil, ""], do: {:ok, nil}
  defp optional_rate(value, label), do: required_rate(value, label)

  defp window(value) when value in [nil, ""], do: {:ok, nil}

  defp window(value) do
    case whole(value) do
      n when is_integer(n) and n >= 8_000 and n <= 2_000_000 ->
        {:ok, n}

      _ ->
        {:error, "context window: a whole number of tokens between 8000 and 2000000"}
    end
  end

  defp number(n) when is_number(n), do: n

  defp number(text) when is_binary(text) do
    case Float.parse(String.trim(text)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp number(_other), do: nil

  defp whole(n) when is_integer(n), do: n
  defp whole(n) when is_float(n) and n == trunc(n), do: trunc(n)

  defp whole(text) when is_binary(text) do
    case Integer.parse(String.trim(text)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp whole(_other), do: nil

  ## ------------------------------------------------------------ attention

  @doc "AT5 (§2.1)."
  @spec attention(map()) :: [map()]
  def attention(ctx) do
    case unpriced(ctx) do
      [] ->
        []

      rows ->
        models = Enum.map(rows, & &1["model"])
        n = length(models)

        [
          %{
            id: "AT5",
            severity: "warning",
            section: "pricing",
            target: %{"kind" => "unpriced_model", "id" => hd(models)},
            title:
              "#{n} #{if n == 1, do: "model", else: "models"} in use #{if n == 1, do: "has", else: "have"} no price",
            reason: "#{list_words(models)} count as $0.00 in every cost"
          }
        ]
    end
  end

  defp list_words(models) when length(models) <= 3, do: Enum.join(models, ", ")
  defp list_words(models), do: Enum.join(Enum.take(models, 3), ", ") <> " +#{length(models) - 3}"

  defp missing(key), do: Kit.error(:invalid, "expected is missing for #{key}")

  defp unsupported,
    do: Kit.error(:unsupported, "This part of settings is not available in this build.")
end
