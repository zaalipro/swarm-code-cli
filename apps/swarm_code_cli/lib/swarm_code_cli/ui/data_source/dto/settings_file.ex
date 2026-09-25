defmodule SwarmCodeCLI.UI.DataSource.DTO.SettingsFile do
  @moduledoc """
  pass74 §3.4.6: a `file` view — the file record's declared fields (`ref`, `path`,
  `bytes`, `lines`, `fingerprint`, …; kind `file`) and its `content` (≤ 262 144
  bytes; nil when the file is too large to edit here or does not exist).
  """
  alias SwarmCode.Settings.RecordKind
  alias SwarmCodeCLI.UI.DataSource.DTO.SettingsDecode

  @content_max 262_144

  defstruct fields: %{}, content: nil

  @type t :: %__MODULE__{fields: map(), content: String.t() | nil}

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(wire), do: SettingsDecode.run(fn -> decode!(wire) end)

  @doc false
  def decode!(wire) do
    file = wire |> SettingsDecode.fetch!("file") |> SettingsDecode.map!(256, :file) |> flat()
    {:ok, kind} = RecordKind.fetch("file")

    %__MODULE__{
      fields: SettingsDecode.fields!(kind, Map.delete(file, "content")),
      content: SettingsDecode.opt_text!(SettingsDecode.fetch!(file, "content"), @content_max)
    }
  end

  # The service answers the file as a record (`{"kind": "file", "id",
  # "fields": {…, "content"}}`, §3.4.2's "file record + content"); the fake
  # answers its fields flat. Both read as the fields with `content` beside them.
  defp flat(%{"kind" => "file", "fields" => fields} = record) when is_map(fields) do
    fields = SettingsDecode.map!(fields, 256, :file)
    content = Map.get(record, "content", Map.get(fields, "content"))
    Map.put(fields, "content", content)
  end

  defp flat(file), do: file

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_dto}
  def validate(%__MODULE__{fields: fields, content: content} = file)
      when is_map(fields) and (is_nil(content) or is_binary(content)),
      do: {:ok, file}

  def validate(_file), do: {:error, :invalid_dto}
end
