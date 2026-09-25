defmodule SwarmCodeCLI.UI.DataSource.DTO.SettingsOverview do
  @moduledoc """
  pass74 §3.4.2: the `overview` view — up to 64 attention items (`%{id, severity,
  section, target, title, reason}`; `section` a `Sections` id, `target` `%{key}` or
  `%{kind, id}`) and the glance fragments (`providers`, `search`, `mcp`, `agents`,
  `approvals`, `storage`, `budget`: string-keyed maps of numbers and strings).
  """
  alias SwarmCode.Settings.Sections
  alias SwarmCodeCLI.UI.DataSource.DTO.SettingsDecode

  @severities %{"error" => :error, "warning" => :warning, "info" => :info}

  defstruct attention: [], glance: %{}

  @type item :: %{
          id: String.t(),
          severity: :error | :warning | :info,
          section: atom() | nil,
          target: %{key: String.t()} | %{kind: String.t(), id: String.t() | nil} | nil,
          title: String.t(),
          reason: String.t() | nil
        }
  @type t :: %__MODULE__{attention: [item()], glance: %{String.t() => map()}}

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(wire), do: SettingsDecode.run(fn -> decode!(wire) end)

  @doc false
  def decode!(wire) do
    %__MODULE__{
      attention:
        wire
        |> SettingsDecode.fetch!("attention")
        |> SettingsDecode.list!(64, :attention)
        |> Enum.map(&item!/1),
      glance: glance!(SettingsDecode.fetch!(wire, "glance"))
    }
  end

  defp item!(wire) do
    %{
      id: SettingsDecode.text!(SettingsDecode.fetch!(wire, "id"), 128, :attention_id),
      severity:
        SettingsDecode.enum!(SettingsDecode.fetch!(wire, "severity"), @severities, :severity),
      section: Sections.from_wire(SettingsDecode.fetch!(wire, "section")),
      target: target!(SettingsDecode.fetch!(wire, "target")),
      title: SettingsDecode.text!(SettingsDecode.fetch!(wire, "title"), 400, :attention_title),
      reason: SettingsDecode.opt_text!(Map.get(wire, "reason"), 2_048, :attention_reason)
    }
  end

  defp target!(nil), do: nil
  defp target!(%{"key" => key}), do: %{key: SettingsDecode.text!(key, 64, :target_key)}

  defp target!(%{"kind" => kind} = target),
    do: %{
      kind: SettingsDecode.text!(kind, 64, :target_kind),
      id: SettingsDecode.record_id!(Map.get(target, "id"))
    }

  defp target!(_target), do: SettingsDecode.reject!({:attention_target, :map})

  defp glance!(glance) do
    glance
    |> SettingsDecode.map!(16, :glance)
    |> Map.new(fn {name, fragment} ->
      fragment = SettingsDecode.map!(fragment, 16, :glance_fragment)
      {name, SettingsDecode.json!(fragment, 1_024, :glance_fragment)}
    end)
  end

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_dto}
  def validate(%__MODULE__{attention: attention, glance: glance} = overview)
      when is_list(attention) and length(attention) <= 64 and is_map(glance),
      do: {:ok, overview}

  def validate(_overview), do: {:error, :invalid_dto}
end
