defmodule SwarmCodeCLI.UI.DataSource.DTO.SettingsUsage do
  @moduledoc """
  pass74 §3.3.6: the `usage` view — this month's spend and budget (USD, nil when
  unknown/unset) and the last 30 days by model (≤ 200 `usage_row` field maps: model,
  input/output tokens, cost or nil when the model has no price).
  """
  alias SwarmCode.Settings.RecordKind
  alias SwarmCodeCLI.UI.DataSource.DTO.SettingsDecode

  defstruct spend_usd: nil, budget_usd: nil, by_model: []

  @type t :: %__MODULE__{
          spend_usd: number() | nil,
          budget_usd: number() | nil,
          by_model: [map()]
        }

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(wire), do: SettingsDecode.run(fn -> decode!(wire) end)

  @doc false
  def decode!(wire) do
    month = SettingsDecode.map!(SettingsDecode.fetch!(wire, "month"), 16, :month)

    rows =
      wire
      |> SettingsDecode.fetch!("by_model")
      |> SettingsDecode.list!(200, :by_model)

    rows =
      case RecordKind.fetch("usage_row") do
        {:ok, kind} -> Enum.map(rows, &SettingsDecode.fields!(kind, &1))
        :error -> Enum.map(rows, &SettingsDecode.json!(&1, 1_024, :by_model))
      end

    %__MODULE__{
      spend_usd: money!(Map.get(month, "spend_usd")),
      budget_usd: money!(Map.get(month, "budget_usd")),
      by_model: rows
    }
  end

  defp money!(nil), do: nil
  defp money!(value) when is_number(value) and value >= 0, do: value
  defp money!(_value), do: SettingsDecode.reject!({:usage, :money})

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_dto}
  def validate(%__MODULE__{by_model: rows} = usage) when is_list(rows) and length(rows) <= 200,
    do: {:ok, usage}

  def validate(_usage), do: {:error, :invalid_dto}
end
