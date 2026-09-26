defmodule SwarmCode.Daemon.Service.Settings.Facts do
  @moduledoc """
  The `facts` view (pass 74, spec §3.3.6): where SwarmCode keeps things (with
  `~` for home), the database size, the §2.25 list-B environment as the service
  sees it (a secret name never carries its value), versions, the research
  levels and that schedules run in the desktop app only.
  """
  @behaviour SwarmCode.Daemon.Service.Settings.Handler

  alias SwarmCode.Daemon.Service.Settings.{Context, Error}
  alias SwarmCode.Domain.{Paths, Research}
  alias SwarmCode.Domain.Research.Levels
  alias SwarmCode.Settings.{Registry, SecretPattern}

  @impl true
  def actions, do: []

  @impl true
  def command(_command, _ctx), do: {:error, Error.unsupported()}

  @impl true
  def views, do: [{"facts", nil}]

  @impl true
  def query("facts", _kind, _params, %Context{} = ctx), do: {:ok, body(ctx)}
  def query(_view, _kind, _params, _ctx), do: {:error, Error.unsupported()}

  @doc "The facts body."
  @spec body(Context.t()) :: map()
  def body(%Context{} = ctx) do
    database = database_path()

    %{
      "paths" => paths(ctx, database),
      "database_bytes" => database_bytes(database),
      "env" => env(ctx.env || %{}),
      "versions" => versions(),
      "research_levels" => research_levels(),
      "scheduler" => "desktop_only"
    }
  end

  defp paths(ctx, database) do
    home = safe(fn -> System.user_home!() end, nil)
    config = Paths.config_dir()

    project_dir =
      case ctx.project do
        %{root_path: root} when is_binary(root) -> Path.join(root, ".swarm_code")
        _ -> nil
      end

    %{
      "database" => database,
      "config_dir" => config,
      "research_root" => safe(fn -> Research.root_dir() end, nil),
      "project_dir" => project_dir,
      "user_agents" => home && Path.join([home, ".swarm_code", "agents"]),
      "user_skills" => Path.join(config, "skills"),
      "user_commands" => Path.join(config, "commands"),
      "user_workflows" => Path.join(config, "workflows")
    }
    |> Map.new(fn {name, path} -> {name, tilde(path, home)} end)
  end

  defp tilde(nil, _home), do: nil
  defp tilde(path, nil), do: path

  defp tilde(path, home) do
    cond do
      path == home -> "~"
      String.starts_with?(path, home <> "/") -> "~" <> String.replace_prefix(path, home, "")
      true -> path
    end
  end

  @doc """
  The database file the service has open (cli74 F42: `Repo.config()` names no
  file for the guarded repo, so Files & environment said `Database …`).
  """
  @spec database_path() :: String.t() | nil
  def database_path do
    case safe(fn -> SwarmCode.Domain.Storage.db_path() end, "") do
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  defp database_bytes(nil), do: nil

  defp database_bytes(path) do
    [path, path <> "-wal"]
    |> Enum.map(fn file ->
      case File.stat(file) do
        {:ok, %File.Stat{size: size}} -> size
        _ -> 0
      end
    end)
    |> Enum.sum()
  end

  @doc """
  The list-B environment names (and the developer names that are set): `%{name,
  set, value, secret, feeds}`. A secret name — or a value that looks like a
  secret — is never shown.
  """
  @spec env(%{String.t() => String.t()}) :: [map()]
  def env(environment) do
    feeds = feeds()
    developer = for name <- Context.developer_names(), Map.has_key?(environment, name), do: name

    for name <- Context.list_b() ++ developer do
      value = Map.get(environment, name)

      secret =
        SecretPattern.secret_name?(name) or
          (value != nil and SecretPattern.secret_kv?(name, value))

      %{
        "name" => name,
        "set" => value != nil,
        "value" => if(secret, do: nil, else: value),
        "secret" => secret,
        "feeds" => Map.get(feeds, name)
      }
    end
  end

  defp feeds do
    for entry <- Registry.all(), name <- entry.env, reduce: %{} do
      acc -> Map.put_new(acc, name, entry.key)
    end
  end

  defp versions do
    %{
      "service" => to_string(Application.spec(:swarm_code_daemon, :vsn) || ""),
      "protocol" => 1,
      "otp" => to_string(:erlang.system_info(:otp_release)),
      "elixir" => System.version()
    }
  end

  defp research_levels do
    estimates = safe(fn -> Research.estimates() end, %{})

    for name <- Levels.names() do
      level = Levels.get(name)

      %{
        "key" => name,
        "label" => level.label,
        "steps" => level.steps,
        "fanout" => level.fanout,
        "fast" => level.fast?,
        "median_ms" =>
          case Map.get(estimates, name) do
            %{ms: ms} when is_integer(ms) -> ms
            _ -> nil
          end
      }
    end
  end

  defp safe(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
  end
end
