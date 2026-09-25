defmodule SwarmCode.Daemon.Service.Settings.Doctor do
  @moduledoc """
  The `doctor` task (pass 74, spec §3.3.7): checks the service can make, each
  `%{"id", "ok", "message"}` — the database answers, the config directory is
  there and writable, every provider can answer (D11's predicate, and its
  last test this session), every enabled MCP server's status, a search engine
  is on, the session project's file parses, the research root exists or can
  be made. The client adds its own cli.json and log checks. No message holds
  a secret.
  """
  @behaviour SwarmCode.Daemon.Service.Settings.Handler

  alias SwarmCode.Daemon.Service.SessionConfiguration
  alias SwarmCode.Daemon.Service.Settings.{Command, Context, Error, Result, TaskSpec}
  alias SwarmCode.Domain.{MCP, Paths, Providers, Repo, Research, Search}

  @impl true
  def actions, do: ["doctor"]

  @impl true
  def views, do: []

  @impl true
  def query(_view, _kind, _params, _ctx), do: {:error, Error.unsupported()}

  @impl true
  def cache_reads("doctor"), do: [{"provider.test", :all}]
  def cache_reads(_), do: []

  @impl true
  def command(%Command{action: "doctor"}, %Context{} = ctx) do
    run = fn _report -> {:ok, %{"rows" => checks(ctx)}} end

    summary = fn %{"rows" => rows} ->
      %{"ok" => Enum.count(rows, & &1["ok"]), "failed" => Enum.count(rows, &(not &1["ok"]))}
    end

    {:task, TaskSpec.new("doctor", {"doctor", nil}, run, summary: summary),
     %Result{status: :accepted}}
  end

  def command(_command, _ctx), do: {:error, Error.unsupported()}

  @doc "Every check, in the order the client lists them."
  @spec checks(Context.t()) :: [map()]
  def checks(%Context{} = ctx) do
    [database(), config_dir()] ++
      providers(ctx) ++ mcp() ++ [search(), project_file(ctx), research_root()]
  end

  defp database do
    case safe(fn -> Repo.query("SELECT 1") end) do
      {:ok, %{rows: [[1]]}} -> check("database", true, "the database answers")
      _ -> check("database", false, "the database does not answer")
    end
  end

  defp config_dir do
    dir = safe(fn -> Paths.config_dir() end)

    cond do
      not is_binary(dir) -> check("config_dir", false, "the config folder is not known")
      not File.dir?(dir) -> check("config_dir", false, "#{home(dir)} does not exist")
      writable?(dir) -> check("config_dir", true, home(dir))
      true -> check("config_dir", false, "#{home(dir)} is not writable")
    end
  end

  defp providers(ctx) do
    tests =
      for {{"provider.test", key}, entry} <- ctx.task_results || %{}, into: %{} do
        {entry[:target] && entry.target["id"], {key, entry}}
      end

    case safe(fn -> Providers.list() end) do
      [_ | _] = providers ->
        for provider <- providers do
          usable? = SessionConfiguration.usable?(provider)

          words =
            if usable?,
              do: "#{provider.name} can answer",
              else: "#{provider.name} has no key"

          words =
            case tests[provider.id] do
              {_key, %{state: state}} -> "#{words}; last test this session: #{state}"
              nil -> words
            end

          check("provider:" <> provider.name, usable?, words)
        end

      _ ->
        [check("providers", false, "no model provider is set up")]
    end
  end

  defp mcp do
    for server <- safe(fn -> MCP.list() end) || [], server.enabled do
      case safe(fn -> MCP.status(server.id) end) do
        :ready -> check("mcp:" <> server.name, true, "#{server.name} is connected")
        {:error, _reason} -> check("mcp:" <> server.name, false, "#{server.name} failed")
        _ -> check("mcp:" <> server.name, false, "#{server.name} is not connected")
      end
    end
  end

  defp search do
    engines = Search.engine_kinds()

    enabled =
      for provider <- safe(fn -> Search.list() end) || [],
          provider.enabled and provider.kind in engines,
          do: Search.label(provider.kind)

    case enabled do
      [] -> check("search", false, "no search engine is on")
      names -> check("search", true, Enum.join(names, ", "))
    end
  end

  defp project_file(%Context{project: %{root_path: root}}) when is_binary(root) do
    path = Path.join([root, ".swarm_code", "config.json"])

    case File.read(path) do
      {:error, :enoent} ->
        check("project_file", true, "no project file")

      {:ok, text} ->
        case Jason.decode(text) do
          {:ok, %{}} -> check("project_file", true, home(path))
          _ -> check("project_file", false, "#{home(path)} is not valid JSON")
        end

      {:error, _} ->
        check("project_file", false, "#{home(path)} cannot be read")
    end
  end

  defp project_file(_ctx), do: check("project_file", true, "no project")

  defp research_root do
    root = safe(fn -> Research.root_dir() end)

    cond do
      not is_binary(root) ->
        check("research_root", false, "the research folder is not known")

      File.dir?(root) ->
        check("research_root", true, home(root))

      creatable?(root) ->
        check("research_root", true, "#{home(root)} will be made on the first research")

      true ->
        check("research_root", false, "#{home(root)} is missing and cannot be made")
    end
  end

  defp creatable?(path) do
    parent = Path.dirname(path)

    cond do
      parent == path -> false
      File.dir?(parent) -> writable?(parent)
      File.exists?(parent) -> false
      true -> creatable?(parent)
    end
  end

  defp writable?(dir) do
    case File.stat(dir) do
      {:ok, %File.Stat{access: access}} -> access in [:read_write, :write]
      _ -> false
    end
  end

  defp check(id, ok?, message), do: %{"id" => id, "ok" => ok?, "message" => message}

  defp home(path) do
    home = System.user_home() || ""

    if home != "" and String.starts_with?(path, home <> "/"),
      do: "~" <> String.replace_prefix(path, home, ""),
      else: path
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
