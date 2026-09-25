defmodule SwarmCode.Daemon.Service.Settings.Router do
  @moduledoc """
  The static routing table of the settings service (pass 74, spec §3.3.2). An
  action string or a view kind is looked up in a compile-time map: runtime
  input never selects a module. A module this build does not have (another
  owner's handler, not merged yet) answers `unsupported`.
  """

  alias SwarmCode.Daemon.Service.Settings, as: S
  alias SwarmCode.Daemon.Service.Settings.Error
  alias SwarmCode.Settings.WireBounds

  @backend :backend

  @actions %{
    "values.patch" => S.Values,
    "values.reset" => S.Values,
    "profile.apply" => S.Values,
    "task.cancel" => @backend,
    "export" => S.Transfer,
    "import.preview" => S.Transfer,
    "import.apply" => S.Transfer,
    "doctor" => S.Doctor,
    "mcp.import.read" => S.MCPImport,
    "mcp.import.apply" => S.MCPImport,
    "workflow.smoke" => S.Library
  }

  @prefixes [
    {"provider.", S.Providers},
    {"efforts.", S.Efforts},
    {"pricing.", S.Pricing},
    {"search.", S.Search},
    {"mcp.", S.MCP},
    {"storage.", S.Storage},
    {"lsp.", S.LSP},
    {"file.", S.Files},
    {"project_config.", S.ProjectConfig}
  ]

  @views %{
    {"values", nil} => S.Values,
    {"overview", nil} => S.Overview,
    {"facts", nil} => S.Facts,
    {"usage", nil} => S.Usage,
    {"open", nil} => @backend,
    {"task", nil} => @backend,
    {"records", "projects"} => S.Projects,
    {"records", "usage_rows"} => S.Usage,
    {"records", "providers"} => S.Providers,
    {"record", "provider"} => S.Providers,
    {"records", "effort_presets"} => S.Efforts,
    {"records", "model_options"} => S.Models,
    {"records", "pricing_rows"} => S.Pricing,
    {"records", "unpriced_models"} => S.Pricing,
    {"records", "search_providers"} => S.Search,
    {"record", "search_provider"} => S.Search,
    {"records", "mcp_servers"} => S.MCP,
    {"record", "mcp_server"} => S.MCP,
    {"records", "storage_sessions"} => S.Storage,
    {"file", nil} => S.Files,
    {"records", "memory_files"} => S.Files,
    {"records", "commands"} => S.Library,
    {"records", "agent_defs"} => S.Library,
    {"records", "skills"} => S.Library,
    {"records", "workflows"} => S.Library,
    {"record", "project_config"} => S.ProjectConfig
  }

  # §3.3.2: task-cache reads the table declares (handlers may add their own).
  @cache_reads %{
    "records:providers" => [{"provider.test", :all}, {"provider.fetch_models", :all}],
    "record:provider" => [{"provider.test", :all}, {"provider.fetch_models", :all}],
    "overview" => [
      {"provider.test", :all},
      {"provider.fetch_models", :all},
      {"search.test", :all}
    ],
    "open" => [{"provider.test", :all}, {"provider.fetch_models", :all}, {"search.test", :all}],
    "provider.apply_models" => [{"provider.fetch_models", {:param, "fetch_task_id"}}],
    "records:model_options" => [{"provider.fetch_models", :all}],
    "records:search_providers" => [{"search.test", :all}],
    "record:search_provider" => [{"search.test", :all}],
    "records:storage_sessions" => [{"storage.measure", :sessions_store}],
    "storage.plan" => [{"storage.measure", :sessions_store}],
    "storage.run" => [{"storage.plan", {:param, "plan_id"}}],
    "mcp.import.apply" => [{"mcp.import.read", {:param, "import_id"}}],
    "import.apply" => [{"import.preview", {:param, "preview_id"}}],
    "records:workflows" => [{"workflow.smoke", :all}],
    "doctor" => [{"provider.test", :all}]
  }

  @doc "The handler module (or `:backend`) of an action."
  @spec action(String.t()) :: {:ok, module() | :backend} | {:error, Error.t()}
  def action(action) when is_binary(action) do
    if action in WireBounds.actions() do
      action
      |> action_module()
      |> loaded()
    else
      {:error, Error.new(:invalid, "not a settings action")}
    end
  end

  def action(_action), do: {:error, Error.new(:invalid, "not a settings action")}

  @doc "The handler module (or `:backend`) of a view and its kind."
  @spec view(String.t(), String.t() | nil) :: {:ok, module() | :backend} | {:error, Error.t()}
  def view(view, kind) do
    case Map.fetch(@views, {view, kind}) do
      {:ok, module} -> loaded(module)
      :error -> {:error, Error.new(:not_found, "not a settings view")}
    end
  end

  @doc "The static table's module of an action, loaded or not (tests and docs)."
  @spec action_module(String.t()) :: module() | :backend | nil
  def action_module(action) do
    case Map.fetch(@actions, action) do
      {:ok, module} ->
        module

      :error ->
        Enum.find_value(@prefixes, fn {prefix, module} ->
          if String.starts_with?(action, prefix), do: module
        end)
    end
  end

  @doc "Every view key of the table (`\"records:providers\"`, `\"values\"`)."
  @spec view_keys() :: [String.t()]
  def view_keys, do: Enum.map(Map.keys(@views), &view_key/1)

  @doc "The routing key of a view: `view` or `view:kind`."
  @spec view_key({String.t(), String.t() | nil}) :: String.t()
  def view_key({view, nil}), do: view
  def view_key({view, kind}), do: view <> ":" <> kind

  @doc """
  The task-cache entries an action or view declares: the table's, plus its
  handler's own `cache_reads/1` when the handler exports it.
  """
  @spec cache_reads(String.t()) :: list()
  def cache_reads(action_or_view) do
    declared = Map.get(@cache_reads, action_or_view, [])

    module =
      case String.split(action_or_view, ":", parts: 2) do
        [view, kind] -> Map.get(@views, {view, kind})
        [name] -> Map.get(@views, {name, nil}) || action_module(name)
      end

    own =
      if is_atom(module) and module not in [nil, @backend] and Code.ensure_loaded?(module) and
           function_exported?(module, :cache_reads, 1),
         do: safe_cache_reads(module, action_or_view),
         else: []

    Enum.uniq(declared ++ own)
  end

  @doc "Every handler module the table names (loaded or not)."
  @spec modules() :: [module()]
  def modules do
    (Map.values(@actions) ++ Enum.map(@prefixes, &elem(&1, 1)) ++ Map.values(@views))
    |> Enum.reject(&(&1 == @backend))
    |> Enum.uniq()
  end

  @doc "The handler modules this build has."
  @spec loaded_modules() :: [module()]
  def loaded_modules, do: Enum.filter(modules(), &Code.ensure_loaded?/1)

  defp safe_cache_reads(module, key) do
    case module.cache_reads(key) do
      list when is_list(list) -> list
      _ -> []
    end
  rescue
    _ -> []
  end

  defp loaded(nil), do: {:error, Error.unsupported()}
  defp loaded(@backend), do: {:ok, @backend}

  defp loaded(module) do
    if Code.ensure_loaded?(module), do: {:ok, module}, else: {:error, Error.unsupported()}
  end
end
