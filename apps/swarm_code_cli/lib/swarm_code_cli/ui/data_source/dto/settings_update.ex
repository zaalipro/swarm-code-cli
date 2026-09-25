defmodule SwarmCodeCLI.UI.DataSource.DTO.SettingsUpdate do
  @moduledoc """
  pass74 §3.4.4: the `settings_update` delta — the new settings `revision`, the
  `sections` it touched (section ids; ids this client does not know are dropped)
  and its `origin` (`:settings` — a write through the settings service —
  or `:elsewhere`). Never values: the layer re-queries what it shows.
  """
  alias SwarmCode.Settings.Sections
  alias SwarmCodeCLI.UI.DataSource.DTO.SettingsDecode

  @origins %{"settings" => :settings, "elsewhere" => :elsewhere}

  defstruct revision: 0, sections: [], origin: :elsewhere

  @type t :: %__MODULE__{
          revision: non_neg_integer(),
          sections: [atom()],
          origin: :settings | :elsewhere
        }

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(wire), do: SettingsDecode.run(fn -> decode!(wire) end)

  @doc false
  def decode!(wire) do
    %__MODULE__{
      revision: SettingsDecode.count!(SettingsDecode.fetch!(wire, "revision"), :revision),
      sections:
        wire
        |> SettingsDecode.fetch!("sections")
        |> SettingsDecode.list!(22, :sections)
        |> Enum.map(&Sections.from_wire/1)
        |> Enum.reject(&is_nil/1),
      origin: SettingsDecode.enum!(SettingsDecode.fetch!(wire, "origin"), @origins, :origin)
    }
  end

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_dto}
  def validate(%__MODULE__{revision: revision, sections: sections, origin: origin} = update)
      when is_integer(revision) and revision >= 0 and is_list(sections) and
             length(sections) <= 22 and origin in [:settings, :elsewhere] do
    if Enum.all?(sections, &Sections.valid?/1), do: {:ok, update}, else: {:error, :invalid_dto}
  end

  def validate(_update), do: {:error, :invalid_dto}
end
