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
  (`SwarmCode.Settings.Sections`).
  """

  alias SwarmCodeCLI.UI.Settings.Section

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

  alias SwarmCode.Settings.Sections, as: Core

  @ids Core.ids()
  @order @ids |> Enum.with_index() |> Map.new()

  @doc "The 22 section ids in rail order."
  @spec ids() :: [atom()]
  def ids, do: @ids

  @doc "The module that builds `id`'s page (it may not be part of this build yet)."
  @spec module_for(atom()) :: module()
  def module_for(id) when is_map_key(@modules, id), do: Map.fetch!(@modules, id)

  @doc "Every section as `%{id, title, group, synonyms}` in rail order (the core registry's)."
  @spec all() :: [map()]
  def all, do: Core.all()

  @doc "The title of `id`."
  @spec title(atom()) :: String.t()
  def title(id) do
    case Core.get(id) do
      %{title: title} -> title
      nil -> to_string(id)
    end
  end

  @doc "The rail group of `id` (nil for Overview)."
  @spec group(atom()) :: String.t() | nil
  def group(id) do
    case Core.get(id) do
      %{group: group} -> group
      nil -> nil
    end
  end

  @doc "`{group, [ids]}` in rail order."
  @spec groups() :: [{String.t() | nil, [atom()]}]
  def groups, do: Core.groups()

  @doc "Section id => its index in rail order."
  @spec order() :: %{atom() => non_neg_integer()}
  def order, do: @order

  @doc "The section after (`1`) or before (`-1`) `id`, wrapping."
  @spec step(atom(), 1 | -1) :: atom()
  def step(id, delta) do
    index = Map.get(@order, id, 0)
    Enum.at(@ids, Integer.mod(index + delta, length(@ids)))
  end

  @doc """
  The section a string names: its id, its title or a synonym, case-insensitive
  with spaces, `-` and `_` folded. `:error` otherwise.
  """
  @spec fetch(String.t()) :: {:ok, atom()} | :error
  def fetch(text), do: Core.fetch(text)

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

  @doc "A picker's choice for the section (`on_pick: {:section, id, tag}`): its ops."
  def picked(id, ctx, tag, value), do: call(id, :picked, [ctx, tag, value], fn -> [] end)

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
  defp invoke(module, :picked, [ctx, tag, value]), do: module.picked(ctx, tag, value)
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
