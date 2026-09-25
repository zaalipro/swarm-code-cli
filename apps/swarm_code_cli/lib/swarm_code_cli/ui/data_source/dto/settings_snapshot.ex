defmodule SwarmCodeCLI.UI.DataSource.DTO.SettingsSnapshot do
  @moduledoc """
  pass74 §3.4.2: the answer to a `settings.query` — `view`, the service's settings
  `revision`, `available` (false with `message` when settings cannot be read here,
  e.g. a live session) and `body`, decoded per view: `SettingsValues` (values),
  `SettingsOverview`, `SettingsFacts`, `SettingsUsage`, `SettingsOpen`,
  `SettingsTaskView` (task), `SettingsRecordPage` (records), `SettingsRecord`
  (record), `SettingsFile` (file); nil when not available.
  """
  alias SwarmCodeCLI.UI.DataSource.DTO.{
    SettingsDecode,
    SettingsFacts,
    SettingsFile,
    SettingsOpen,
    SettingsOverview,
    SettingsRecordPage,
    SettingsTaskView,
    SettingsUsage,
    SettingsValues
  }

  @views %{
    "values" => :values,
    "overview" => :overview,
    "facts" => :facts,
    "usage" => :usage,
    "open" => :open,
    "task" => :task,
    "records" => :records,
    "record" => :record,
    "file" => :file
  }

  defstruct request_id: nil, view: nil, revision: 0, available: true, message: nil, body: nil

  @type view :: :values | :overview | :facts | :usage | :open | :task | :records | :record | :file
  @type t :: %__MODULE__{
          request_id: String.t() | nil,
          view: view(),
          revision: non_neg_integer(),
          available: boolean(),
          message: String.t() | nil,
          body: struct() | nil
        }

  @doc "The view atoms by wire name."
  @spec views() :: %{String.t() => view()}
  def views, do: @views

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(wire), do: SettingsDecode.run(fn -> decode!(wire) end)

  @doc false
  def decode!(wire) do
    SettingsDecode.map!(wire, 16, :snapshot)
    view = SettingsDecode.enum!(SettingsDecode.fetch!(wire, "view"), @views, :view)
    available = SettingsDecode.bool!(SettingsDecode.fetch!(wire, "available"), :available)
    body = SettingsDecode.fetch!(wire, "body")

    %__MODULE__{
      request_id: SettingsDecode.opt_id!(SettingsDecode.fetch!(wire, "request_id"), :request_id),
      view: view,
      revision: SettingsDecode.count!(SettingsDecode.fetch!(wire, "revision"), :revision),
      available: available,
      message: SettingsDecode.opt_text!(SettingsDecode.fetch!(wire, "message"), 2_048, :message),
      body: if(available and body != nil, do: body!(view, body))
    }
  end

  defp body!(:values, body), do: SettingsValues.decode!(body)
  defp body!(:overview, body), do: SettingsOverview.decode!(body)
  defp body!(:facts, body), do: SettingsFacts.decode!(body)
  defp body!(:usage, body), do: SettingsUsage.decode!(body)
  defp body!(:open, body), do: SettingsOpen.decode!(body)
  defp body!(:task, body), do: SettingsTaskView.decode!(body)
  defp body!(:records, body), do: SettingsRecordPage.decode!(body)
  defp body!(:record, body), do: SettingsDecode.record!(body)
  defp body!(:file, body), do: SettingsFile.decode!(body)

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_dto}
  def validate(%__MODULE__{view: view, revision: revision, available: available} = snapshot)
      when is_atom(view) and is_integer(revision) and revision >= 0 and is_boolean(available) do
    if view in Map.values(@views), do: {:ok, snapshot}, else: {:error, :invalid_dto}
  end

  def validate(_snapshot), do: {:error, :invalid_dto}
end
