defmodule SwarmCode.Daemon.Service.Settings.Models do
  @moduledoc """
  Every model a picker can offer (pass 74 §3.5.1 `records:model_options`):
  each provider × model (its list plus a default model it does not list), with
  the price and context window from Pricing and whether the provider's last
  fetch of this session still listed it.
  """

  alias SwarmCode.Daemon.Service.Settings.Kit
  alias SwarmCode.Daemon.Service.Settings.Providers, as: ProviderSettings
  alias SwarmCode.Domain.Providers

  @doc false
  def actions, do: []

  @doc false
  def views, do: [{"records", "model_options"}]

  @doc false
  def cache_reads("records:model_options"), do: [{"provider.fetch_models", :all}]
  def cache_reads(_other), do: []

  @doc false
  def query("records", "model_options", params, ctx) do
    only = Kit.get(Kit.options(params), "provider_id")
    pricing = ProviderSettings.settings_row().pricing || %{}
    fetched = fetched_lists(ctx)

    items =
      Providers.list()
      |> Enum.filter(&(is_nil(only) or &1.id == only))
      |> Enum.sort_by(&{String.downcase(&1.name || ""), &1.name})
      |> Enum.flat_map(fn provider ->
        provider
        |> models()
        |> Enum.map(&option(provider, &1, pricing, Map.get(fetched, provider.id)))
      end)

    {:ok, Kit.records_body("model_option", items, params)}
  end

  def query(_view, _kind, _params, _ctx),
    do: Kit.error(:unsupported, "This part of settings is not available in this build.")

  @doc false
  def command(_cmd, _ctx),
    do: Kit.error(:unsupported, "This part of settings is not available in this build.")

  defp models(provider) do
    listed = provider.models || []
    default = provider.default_model

    if(is_binary(default) and default != "" and default not in listed,
      do: listed ++ [default],
      else: listed
    )
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp option(provider, model, pricing, fetched) do
    row = Map.get(pricing, model)

    Kit.record("model_option", "#{provider.id}|#{model}", %{
      "provider_id" => provider.id,
      "provider_name" => provider.name,
      "provider_kind" => provider.kind,
      "model" => model,
      "price" => price(row),
      "context_window" => row && Map.get(row, "context_window"),
      "in_last_fetch" => if(fetched, do: MapSet.member?(fetched, model)),
      "provider_default" => model == provider.default_model
    })
  end

  defp price(%{} = row) do
    %{
      "input" => Map.get(row, "input"),
      "output" => Map.get(row, "output"),
      "cache_read" => Map.get(row, "cache_read"),
      "cache_write" => Map.get(row, "cache_write")
    }
  end

  defp price(_row), do: nil

  # provider id → the models its last fetch of this session listed, when the
  # declared cache entry still holds the full result.
  defp fetched_lists(ctx) do
    ctx
    |> Kit.task_entries("provider.fetch_models")
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn entry, acc ->
      with %{} = result <- entry.result,
           id when is_binary(id) <- Kit.get(result, "provider_id"),
           models when is_list(models) <- Kit.get(result, "models") do
        Map.put(acc, id, MapSet.new(models))
      else
        _ -> acc
      end
    end)
  end
end
