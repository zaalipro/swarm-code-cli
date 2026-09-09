defmodule SwarmCode.Domain.Providers.Provider do
  @moduledoc """
  An LLM provider endpoint (OpenAI-compatible or Anthropic).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(openai_compatible anthropic) ++ if(Mix.env() == :test, do: ["fake"], else: [])

  # Spec 51 §6.9: this row sits in every AgentServer and RunServer state and in
  # every `%LLM.Request{}`, and `config/prod.exs` turns SASL reports on — one
  # `GenServer.cast(agent, :bogus)` printed the key three times. `inspect/1` is
  # the only way it ever reached a log, so `inspect/1` is where it stops.
  @derive {Inspect, except: [:api_key]}
  schema "providers" do
    field(:name, :string)
    field(:kind, :string, default: "openai_compatible")
    field(:base_url, :string)
    field(:api_key, :string, default: "")
    field(:models, {:array, :string}, default: [])
    field(:default_model, :string)
    # Spec 45 §3.3: the provider's reasoning-effort levels (nil = the built-in
    # defaults for its kind) and per-model overrides, `%{"<model>" => [level]}`.
    field(:effort_levels, {:array, :map})
    field(:model_effort_levels, :map, default: %{})
    # Spec 53b §3: opt into the Messages API's server-side refusal
    # fallback (`fallbacks: "default"`, beta `server-side-fallback-2026-07-01`).
    # On by default, and only ever sent for the model families the API accepts
    # it for — `SwarmCode.Domain.LLM.Anthropic.fallbacks?/1`.
    field(:fallbacks, :boolean, default: true)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(provider, attrs) do
    provider
    |> cast(attrs, [
      :name,
      :kind,
      :base_url,
      :api_key,
      :models,
      :default_model,
      :effort_levels,
      :model_effort_levels,
      :fallbacks
    ])
    |> update_change(:base_url, &String.trim_trailing(String.trim(&1), "/"))
    |> validate_required([:name, :base_url])
    |> validate_inclusion(:kind, @kinds)
    |> validate_format(:base_url, ~r{^https?://}, message: "must start with http:// or https://")
    |> validate_levels(:effort_levels)
    |> validate_model_levels(:model_effort_levels)
    |> unique_constraint(:name, message: "has already been taken")
  end

  # Spec 45 §3.3: every level list goes through `Efforts.validate/1`; the
  # first message is the changeset error.
  defp validate_levels(changeset, field) do
    validate_change(changeset, field, fn ^field, levels ->
      case levels && SwarmCode.Domain.LLM.Efforts.validate(levels) do
        {:error, errors} -> [{field, first_error(errors)}]
        _ok -> []
      end
    end)
  end

  defp validate_model_levels(changeset, field) do
    validate_change(changeset, field, fn ^field, map ->
      if is_map(map) do
        Enum.find_value(map, [], fn {model, levels} ->
          case SwarmCode.Domain.LLM.Efforts.validate(levels) do
            {:error, errors} -> [{field, "#{model}: " <> first_error(errors)}]
            _ok -> nil
          end
        end)
      else
        [{field, "must be a map of model to levels"}]
      end
    end)
  end

  defp first_error(errors), do: errors |> Enum.min_by(fn {i, _} -> i end) |> elem(1)

  def models_text(provider), do: Enum.join(provider.models || [], "\n")

  def parse_models(text) when is_binary(text) do
    text
    |> String.split([",", "\n", "\r"])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  def parse_models(_), do: []
end
