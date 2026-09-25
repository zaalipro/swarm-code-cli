defmodule SwarmCodeCLI.UI.Settings.Sections do
  @moduledoc """
  The 22 sections of the settings layer (spec §1.3 D4) and the module that
  builds each page (§3.1). `module_for/1` is a compile-time map; a module that
  is not part of this build falls back to the default implementation
  (`Settings.Section`'s defaults: every registry row of the section), so every
  branch runs end to end. The UI never loads code by name (the architecture
  test forbids it), so a missing module is recognised by the
  `UndefinedFunctionError` that names exactly that module and callback.

  Titles, groups and synonyms come from the core registry
  (`SwarmCode.Settings.Sections`) when it is loaded, else from the copy here.
  """

  alias SwarmCodeCLI.UI.Settings.Section

  @compile {:no_warn_undefined, [SwarmCode.Settings.Sections]}

  @modules %{
    overview: SwarmCodeCLI.UI.Settings.Sections.Overview,
    models_effort: SwarmCodeCLI.UI.Settings.Sections.ModelsEffort,
    providers: SwarmCodeCLI.UI.Settings.Sections.Providers,
    pricing: SwarmCodeCLI.UI.Settings.Sections.Pricing,
    search_web: SwarmCodeCLI.UI.Settings.Sections.SearchWeb,
    deep_research: SwarmCodeCLI.UI.Settings.Sections.DeepResearch,
    mcp: SwarmCodeCLI.UI.Settings.Sections.MCP,
    language_servers: SwarmCodeCLI.UI.Settings.Sections.LanguageServers,
    agents_limits: SwarmCodeCLI.UI.Settings.Sections.AgentsLimits,
    approvals: SwarmCodeCLI.UI.Settings.Sections.Approvals,
    project_file: SwarmCodeCLI.UI.Settings.Sections.ProjectFile,
    memory: SwarmCodeCLI.UI.Settings.Sections.Memory,
    library: SwarmCodeCLI.UI.Settings.Sections.Library,
    appearance: SwarmCodeCLI.UI.Settings.Sections.Appearance,
    layout: SwarmCodeCLI.UI.Settings.Sections.Layout,
    keys: SwarmCodeCLI.UI.Settings.Sections.KeysInput,
    startup: SwarmCodeCLI.UI.Settings.Sections.SessionStartup,
    storage: SwarmCodeCLI.UI.Settings.Sections.Storage,
    budget: SwarmCodeCLI.UI.Settings.Sections.BudgetUsage,
    desktop: SwarmCodeCLI.UI.Settings.Sections.DesktopApp,
    files_env: SwarmCodeCLI.UI.Settings.Sections.FilesEnv,
    import_export: SwarmCodeCLI.UI.Settings.Sections.ImportExport
  }

  # The rail (D4): Overview, then 21 sections in six groups.
  @fallback [
    {:overview, "Overview", nil, []},
    {:models_effort, "Models & effort", "models", ["model", "models", "effort"]},
    {:providers, "Providers", "models", ["provider", "api key", "keys api"]},
    {:pricing, "Pricing", "models", ["price", "prices", "cost"]},
    {:search_web, "Search & web", "tools", ["search", "web", "reader"]},
    {:deep_research, "Deep research", "tools", ["research"]},
    {:mcp, "MCP servers", "tools", ["mcp", "servers", "tools"]},
    {:language_servers, "Language servers", "tools", ["lsp", "language server"]},
    {:agents_limits, "Agents & limits", "agents", ["agents", "limits", "timeouts"]},
    {:approvals, "Approvals & trust", "agents", ["approval", "approvals", "trust"]},
    {:project_file, "Project file", "agents", ["config.json", "hooks", "profiles"]},
    {:memory, "Memory & instructions", "agents", ["memory", "instructions"]},
    {:library, "Library", "agents", ["commands", "skills", "workflows", "agent definitions"]},
    {:appearance, "Appearance", "this terminal", ["colours", "colors", "glyphs"]},
    {:layout, "Layout & transcript", "this terminal", ["layout", "panel", "transcript"]},
    {:keys, "Keys & input", "this terminal", ["keys", "keybindings", "key bindings", "mouse"]},
    {:startup, "Session & startup", "this terminal", ["startup", "launch"]},
    {:storage, "Storage", "data", ["cleanup", "disk"]},
    {:budget, "Budget & usage", "data", ["usage", "spend"]},
    {:desktop, "Desktop app", "more", ["desktop"]},
    {:files_env, "Files & environment", "more", ["files", "environment", "env", "paths"]},
    {:import_export, "Import & export", "more", ["import", "export", "backup"]}
  ]

  @ids Enum.map(@fallback, &elem(&1, 0))

  @doc "The 22 section ids in rail order."
  @spec ids() :: [atom()]
  def ids, do: @ids

  @doc "The module that builds `id`'s page (it may not be loaded in this build)."
  @spec module_for(atom()) :: module()
  def module_for(id) when is_map_key(@modules, id), do: Map.fetch!(@modules, id)

  @doc "Every section as `%{id, title, group, synonyms}` in rail order."
  @spec all() :: [map()]
  def all do
    core =
      optional(SwarmCode.Settings.Sections, :all, fn -> SwarmCode.Settings.Sections.all() end)

    case core do
      [_ | _] = sections ->
        by_id = Map.new(sections, &{Map.get(&1, :id), &1})

        Enum.map(@fallback, fn {id, title, group, synonyms} ->
          case Map.get(by_id, id) do
            nil ->
              %{id: id, title: title, group: group, synonyms: synonyms}

            section ->
              %{
                id: id,
                title: Map.get(section, :title, title),
                group: group,
                synonyms: Map.get(section, :synonyms, synonyms)
              }
          end
        end)

      _ ->
        Enum.map(@fallback, fn {id, title, group, synonyms} ->
          %{id: id, title: title, group: group, synonyms: synonyms}
        end)
    end
  end

  @doc "The title of `id`."
  @spec title(atom()) :: String.t()
  def title(id) do
    case List.keyfind(@fallback, id, 0) do
      {_, title, _, _} -> title
      nil -> to_string(id)
    end
  end

  @doc "The rail group of `id` (nil for Overview)."
  @spec group(atom()) :: String.t() | nil
  def group(id) do
    case List.keyfind(@fallback, id, 0) do
      {_, _, group, _} -> group
      nil -> nil
    end
  end

  @doc "`{group, [ids]}` in rail order."
  @spec groups() :: [{String.t() | nil, [atom()]}]
  def groups do
    @fallback
    |> Enum.chunk_by(&elem(&1, 2))
    |> Enum.map(fn [{_, _, group, _} | _] = chunk -> {group, Enum.map(chunk, &elem(&1, 0))} end)
  end

  @doc "Section id => its index in rail order."
  @spec order() :: %{atom() => non_neg_integer()}
  def order, do: @ids |> Enum.with_index() |> Map.new()

  @doc "The section after (`1`) or before (`-1`) `id`, wrapping."
  @spec step(atom(), 1 | -1) :: atom()
  def step(id, delta) do
    index = Enum.find_index(@ids, &(&1 == id)) || 0
    Enum.at(@ids, Integer.mod(index + delta, length(@ids)))
  end

  @doc """
  The section a string names: its id, its title or a synonym, case-insensitive
  with spaces, `-` and `_` folded. `:error` otherwise.
  """
  @spec fetch(String.t()) :: {:ok, atom()} | :error
  def fetch(text) when is_binary(text) do
    wanted = fold(text)

    found =
      Enum.find(all(), fn section ->
        fold(Atom.to_string(section.id)) == wanted or fold(section.title) == wanted or
          Enum.any?(section.synonyms || [], &(fold(&1) == wanted))
      end)

    if found, do: {:ok, found.id}, else: :error
  end

  defp fold(text),
    do: text |> String.downcase() |> String.replace(~r/[\s_\-&]+/u, "") |> String.trim()

  # ------------------------------------------------------------ dispatch

  @doc "The data `id`'s page needs (the section's `loads/1`, else the defaults)."
  def loads(id, ctx), do: call(id, :loads, [ctx], fn -> Section.default_loads(id, ctx) end)

  @doc "The page rows of section `id`."
  def rows(id, ctx), do: call(id, :rows, [ctx], fn -> Section.default_rows(id, ctx) end)

  @doc "The rows of a record page."
  def record_rows(id, ctx, kind, record_id),
    do: call(id, :record_rows, [ctx, kind, record_id], fn -> [] end)

  @doc "The rows of a sub-page."
  def sub_rows(id, ctx, sub), do: call(id, :sub_rows, [ctx, sub], fn -> [] end)

  @doc "A row letter or Enter on a row: the section's ops, or `:default`."
  def act(id, ctx, row, action), do: call(id, :act, [ctx, row, action], fn -> :default end)

  @doc "An editor's committed value: the section's ops, or `:default`."
  def commit(id, ctx, row, value), do: call(id, :commit, [ctx, row, value], fn -> :default end)

  @doc "The page title (`unsaved · Ctrl-S creates it · Esc discards` on a draft)."
  def page_title(id, ctx), do: call(id, :title, [ctx], fn -> title(id) end)

  @doc "The client-side attention items of section `id`."
  def attention(id, ctx), do: call(id, :attention, [ctx], fn -> [] end)

  @doc "The section's record count for the rail (nil when it has none)."
  def counts(id, ctx), do: call(id, :counts, [ctx], fn -> %{records: nil} end)

  defp call(id, name, args, default) do
    module = module_for(id)

    case optional(module, name, fn -> invoke(module, name, args) end) do
      nil -> default.()
      result -> result
    end
  end

  defp invoke(module, :loads, [ctx]), do: module.loads(ctx)
  defp invoke(module, :rows, [ctx]), do: module.rows(ctx)
  defp invoke(module, :record_rows, [ctx, kind, id]), do: module.record_rows(ctx, kind, id)
  defp invoke(module, :sub_rows, [ctx, sub]), do: module.sub_rows(ctx, sub)
  defp invoke(module, :act, [ctx, row, action]), do: module.act(ctx, row, action)
  defp invoke(module, :commit, [ctx, row, value]), do: module.commit(ctx, row, value)
  defp invoke(module, :title, [ctx]), do: module.title(ctx)
  defp invoke(module, :attention, [ctx]), do: module.attention(ctx)
  defp invoke(module, :counts, [ctx]), do: module.counts(ctx)

  @doc false
  # `fun`'s result, or nil when `module` (or its `name` callback) is not part
  # of this build. Any other error is the section's own and is raised.
  def optional(module, name, fun) do
    fun.()
  rescue
    error in UndefinedFunctionError ->
      if error.module == module and error.function == name,
        do: nil,
        else: reraise(error, __STACKTRACE__)
  end
end
