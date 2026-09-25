defmodule SwarmCodeCLI.UI.DataSource.DTO.SettingsRecord do
  @moduledoc """
  pass74 §3.4.6: one settings record — `kind` (a `SwarmCode.Settings.RecordKind`
  name), `id` and `fields` (string keys, only the kind's declared fields; a secret
  field is `%{set: boolean, hint: nil | 4 characters}`, an MCP env/header list is
  `[%{name, secret, value, hint}]`, everything else the wire's JSON).
  """
  alias SwarmCodeCLI.UI.DataSource.DTO.SettingsDecode

  defstruct kind: nil, id: nil, fields: %{}

  @type t :: %__MODULE__{kind: String.t(), id: String.t() | nil, fields: map()}

  @doc "Decode a wire record `{kind, id, fields}` with the §3.4.6 rules."
  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(wire), do: SettingsDecode.run(fn -> SettingsDecode.record!(wire) end)

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_dto}
  def validate(%__MODULE__{kind: kind, id: id, fields: fields} = record)
      when is_binary(kind) and (is_nil(id) or is_binary(id)) and is_map(fields),
      do: {:ok, record}

  def validate(_record), do: {:error, :invalid_dto}
end
