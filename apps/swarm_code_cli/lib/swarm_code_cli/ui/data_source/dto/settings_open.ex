defmodule SwarmCodeCLI.UI.DataSource.DTO.SettingsOpen do
  @moduledoc """
  pass74 §3.3.6: the `open` view — what opening the layer needs in one answer:
  `values` (every section), `overview`, `facts` and `projects` (the first
  `records:projects` page). The last three are nil when the service answered the
  values alone (an answer that would not fit); the client then queries them.
  """
  alias SwarmCodeCLI.UI.DataSource.DTO.{
    SettingsDecode,
    SettingsFacts,
    SettingsOverview,
    SettingsRecordPage,
    SettingsValues
  }

  defstruct values: nil, overview: nil, facts: nil, projects: nil

  @type t :: %__MODULE__{
          values: SettingsValues.t(),
          overview: SettingsOverview.t() | nil,
          facts: SettingsFacts.t() | nil,
          projects: SettingsRecordPage.t() | nil
        }

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(wire), do: SettingsDecode.run(fn -> decode!(wire) end)

  @doc false
  def decode!(wire) do
    %__MODULE__{
      values: SettingsValues.decode!(SettingsDecode.fetch!(wire, "values")),
      overview: optional(Map.get(wire, "overview"), &SettingsOverview.decode!/1),
      facts: optional(Map.get(wire, "facts"), &SettingsFacts.decode!/1),
      projects: optional(Map.get(wire, "projects"), &SettingsRecordPage.decode!/1)
    }
  end

  defp optional(nil, _decode), do: nil
  defp optional(value, decode), do: decode.(value)

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_dto}
  def validate(%__MODULE__{values: %SettingsValues{}} = open), do: {:ok, open}
  def validate(_open), do: {:error, :invalid_dto}
end
