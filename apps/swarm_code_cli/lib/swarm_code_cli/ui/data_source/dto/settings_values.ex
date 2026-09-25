defmodule SwarmCodeCLI.UI.DataSource.DTO.SettingsValues do
  @moduledoc """
  pass74 §3.4.2: the `values` view body — up to 400 `SettingValue`s (keys this
  client does not know are dropped) and the project and conversation they were
  resolved for.
  """
  alias SwarmCodeCLI.UI.DataSource.DTO.{SettingsDecode, SettingValue}

  defstruct values: [], project_id: nil, conversation_id: nil

  @type t :: %__MODULE__{
          values: [SettingValue.t()],
          project_id: String.t() | nil,
          conversation_id: String.t() | nil
        }

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(wire), do: SettingsDecode.run(fn -> decode!(wire) end)

  @doc false
  def decode!(wire) do
    values =
      wire
      |> SettingsDecode.fetch!("values")
      |> SettingsDecode.list!(400, :values)
      |> Enum.map(&SettingValue.decode!/1)
      |> Enum.reject(&(&1 == :drop))

    %__MODULE__{
      values: values,
      project_id: SettingsDecode.opt_id!(SettingsDecode.fetch!(wire, "project_id"), :project_id),
      conversation_id:
        SettingsDecode.opt_id!(SettingsDecode.fetch!(wire, "conversation_id"), :conversation_id)
    }
  end

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_dto}
  def validate(%__MODULE__{values: values} = body) when is_list(values) and length(values) <= 400,
    do: {:ok, body}

  def validate(_body), do: {:error, :invalid_dto}
end
