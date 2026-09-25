defmodule SwarmCodeCLI.UI.DataSource.DTO.SettingsRecordPage do
  @moduledoc """
  pass74 §3.4.6: a `records` view — `kind` (the query kind, e.g. `providers`), up to
  200 `SettingsRecord` items, the next cursor and the total when known.
  """
  alias SwarmCodeCLI.UI.DataSource.DTO.{SettingsDecode, SettingsRecord}

  defstruct kind: nil, items: [], next_cursor: nil, total: nil

  @type t :: %__MODULE__{
          kind: String.t(),
          items: [SettingsRecord.t()],
          next_cursor: String.t() | nil,
          total: non_neg_integer() | nil
        }

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(wire), do: SettingsDecode.run(fn -> decode!(wire) end)

  @doc false
  def decode!(wire) do
    %__MODULE__{
      kind: SettingsDecode.text!(SettingsDecode.fetch!(wire, "kind"), 64, :records_kind),
      items:
        wire
        |> SettingsDecode.fetch!("items")
        |> SettingsDecode.list!(200, :records_items)
        |> Enum.map(&SettingsDecode.record!/1),
      next_cursor: SettingsDecode.opt_text!(SettingsDecode.fetch!(wire, "next_cursor"), 256),
      total: SettingsDecode.opt_count!(SettingsDecode.fetch!(wire, "total"), :records_total)
    }
  end

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_dto}
  def validate(%__MODULE__{kind: kind, items: items} = page)
      when is_binary(kind) and is_list(items) and length(items) <= 200 do
    if Enum.all?(items, &match?({:ok, _}, SettingsRecord.validate(&1))),
      do: {:ok, page},
      else: {:error, :invalid_dto}
  end

  def validate(_page), do: {:error, :invalid_dto}
end
