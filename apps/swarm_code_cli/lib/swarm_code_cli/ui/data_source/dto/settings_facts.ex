defmodule SwarmCodeCLI.UI.DataSource.DTO.SettingsFacts do
  @moduledoc """
  pass74 §3.3.6: the `facts` view — `paths` (name → path with `~`),
  `database_bytes`, `env` (the variables of §2.25 list B as the service sees them:
  `%{name, set, value, secret, feeds}`), `versions`, `research_levels` and
  `scheduler`. A bounded generic map: keys a newer service adds are ignored.

  A secret variable never carries a value (a daemon that sends one is refused); a
  shown value that looks like a secret (`SecretPattern.secret_kv?/2`) is masked
  here rather than refusing the view, so settings still open.
  """
  alias SwarmCode.Settings.SecretPattern
  alias SwarmCodeCLI.UI.DataSource.DTO.SettingsDecode

  defstruct paths: %{},
            database_bytes: nil,
            env: [],
            versions: %{},
            research_levels: [],
            scheduler: nil

  @type env :: %{
          name: String.t(),
          set: boolean(),
          value: String.t() | nil,
          secret: boolean(),
          feeds: term()
        }
  @type t :: %__MODULE__{
          paths: %{String.t() => String.t() | nil},
          database_bytes: non_neg_integer() | nil,
          env: [env()],
          versions: map(),
          research_levels: [map()],
          scheduler: String.t() | nil
        }

  @spec decode(term()) :: {:ok, t()} | {:error, term()}
  def decode(wire), do: SettingsDecode.run(fn -> decode!(wire) end)

  @doc false
  def decode!(wire) do
    SettingsDecode.map!(wire, 64, :facts)

    %__MODULE__{
      paths: wire |> Map.get("paths", %{}) |> map_json!(:paths),
      database_bytes: SettingsDecode.opt_count!(Map.get(wire, "database_bytes"), :database),
      env:
        wire
        |> Map.get("env", [])
        |> SettingsDecode.list!(64, :env)
        |> Enum.map(&env!/1),
      versions: wire |> Map.get("versions", %{}) |> map_json!(:versions),
      research_levels:
        wire
        |> Map.get("research_levels", [])
        |> SettingsDecode.list!(16, :research_levels)
        |> Enum.map(&map_json!(&1, :research_levels)),
      scheduler: SettingsDecode.opt_text!(Map.get(wire, "scheduler"), 64, :scheduler)
    }
  end

  defp map_json!(value, what),
    do: value |> SettingsDecode.map!(64, what) |> SettingsDecode.json!(4_096, what)

  defp env!(wire) do
    name = SettingsDecode.text!(SettingsDecode.fetch!(wire, "name"), 128, :env_name)
    secret = SettingsDecode.bool!(SettingsDecode.fetch!(wire, "secret"), :env_secret)
    value = SettingsDecode.opt_text!(SettingsDecode.fetch!(wire, "value"), 4_096, :env_value)

    if secret and value != nil,
      do: SettingsDecode.reject!({:secret_shown, "env", "value"})

    masked? = not secret and value != nil and SecretPattern.secret_kv?(name, value)

    %{
      name: name,
      set: SettingsDecode.bool!(SettingsDecode.fetch!(wire, "set"), :env_set),
      value: if(masked?, do: nil, else: value),
      secret: secret or masked?,
      feeds: SettingsDecode.json!(Map.get(wire, "feeds"), 256, :env_feeds)
    }
  end

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_dto}
  def validate(%__MODULE__{paths: paths, env: env} = facts) when is_map(paths) and is_list(env),
    do: {:ok, facts}

  def validate(_facts), do: {:error, :invalid_dto}
end
