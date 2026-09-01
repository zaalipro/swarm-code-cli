defmodule SwarmCode.Daemon.Platform.Paths do
  @moduledoc false

  alias SwarmCode.Daemon.Platform.PathSet

  @non_production [:development, :test, :recovery]

  @spec resolve(keyword()) ::
          {:ok, PathSet.t()}
          | {:error,
             :unsupported_platform
             | :relative_xdg_path
             | :relative_database_path
             | :alternate_database_forbidden}
  def resolve(opts) do
    platform = Keyword.fetch!(opts, :platform)
    mode = Keyword.fetch!(opts, :mode)
    home = opts |> Keyword.fetch!(:home) |> Path.expand()
    env = Keyword.get(opts, :env, %{})

    with {:ok, roots} <- roots(platform, home, env),
         {:ok, database} <- database(Keyword.get(opts, :database_path), mode, roots.data) do
      data =
        if database == Path.join(roots.data, "swarm_code.db"),
          do: roots.data,
          else: Path.dirname(database)

      {:ok,
       struct!(
         PathSet,
         Map.merge(roots, %{
           platform: platform,
           data: data,
           database: database,
           lease: Path.join(data, "instance_lease.db"),
           owner_record: Path.join(data, "instance_owner.json"),
           socket: Path.join(roots.runtime, "daemon.sock"),
           socket_metadata: Path.join(roots.runtime, "daemon.json"),
           backups: Path.join(data, "backups")
         })
       )}
    end
  end

  defp roots(:macos, home, env) do
    data = Path.join([home, "Library", "Application Support", "SwarmCode"])
    runtime_base = absolute_or(Map.get(env, "TMPDIR"), Path.join([home, "Library", "Caches"]))

    {:ok,
     %{
       data: data,
       config: data,
       state: Path.join([home, "Library", "Logs", "SwarmCode"]),
       cache: Path.join([home, "Library", "Caches", "SwarmCode", "CLI"]),
       runtime: Path.join(runtime_base, "swarm-code")
     }}
  end

  defp roots(:linux, home, env) do
    with {:ok, data} <- xdg(env, "XDG_DATA_HOME", Path.join([home, ".local", "share"])),
         {:ok, config} <- xdg(env, "XDG_CONFIG_HOME", Path.join(home, ".config")),
         {:ok, state} <- xdg(env, "XDG_STATE_HOME", Path.join([home, ".local", "state"])),
         {:ok, cache} <- xdg(env, "XDG_CACHE_HOME", Path.join(home, ".cache")),
         {:ok, runtime_root} <-
           xdg(env, "XDG_RUNTIME_DIR", Path.join([state, "swarm-code", "run"])) do
      app_state = Path.join(state, "swarm-code")

      runtime =
        if Map.get(env, "XDG_RUNTIME_DIR") in [nil, ""],
          do: runtime_root,
          else: Path.join(runtime_root, "swarm-code")

      {:ok,
       %{
         data: Path.join(data, "swarm-code"),
         config: Path.join(config, "swarm-code"),
         state: app_state,
         cache: Path.join(cache, "swarm-code"),
         runtime: runtime
       }}
    end
  end

  defp roots(_platform, _home, _env), do: {:error, :unsupported_platform}

  defp database(nil, _mode, data), do: {:ok, Path.join(data, "swarm_code.db")}

  defp database(path, mode, _data) when mode in @non_production and is_binary(path) do
    if Path.type(path) == :absolute,
      do: {:ok, Path.expand(path)},
      else: {:error, :relative_database_path}
  end

  defp database(_path, _mode, _data), do: {:error, :alternate_database_forbidden}

  defp xdg(env, key, fallback) do
    case Map.get(env, key) do
      value when is_binary(value) and value != "" ->
        if Path.type(value) == :absolute,
          do: {:ok, Path.expand(value)},
          else: {:error, :relative_xdg_path}

      _other ->
        {:ok, fallback}
    end
  end

  defp absolute_or(value, fallback) when is_binary(value) and value != "" do
    if Path.type(value) == :absolute, do: Path.expand(value), else: fallback
  end

  defp absolute_or(_value, fallback), do: fallback
end
