defmodule SwarmCode.Settings.Registry do
  @moduledoc """
  The one settings registry (pass 74, spec §3.2.6, D3): every value the
  settings layer, the service, `swarmcode config` and `docs/settings.md` know.
  A value that is not here does not exist. Pure compiled data; lookups are maps
  built at compile time; runtime input is looked up in string tables and never
  becomes an atom (D32).

  A compile-time check raises on duplicate keys or ids, a bad key format, an
  unknown section, a default or example the entry's own validators refuse, an
  example equal to the default, a home layer outside the entry's layers, an
  enum default outside its choices, a numeric entry of more than 50 steps
  without a big step, and more scalar keys than one `values.patch` can carry.
  """

  alias SwarmCode.Settings.{Entry, RecordKind, Sections, Validate, WireValue}
  alias SwarmCode.Settings.Registry

  @modules [
    Registry.Models,
    Registry.Session,
    Registry.Web,
    Registry.Research,
    Registry.Limits,
    Registry.Project
  ]

  @section_order Sections.ids() |> Enum.with_index() |> Map.new()

  @all @modules
       |> Enum.flat_map(& &1.entries())
       |> Enum.with_index()
       |> Enum.sort_by(fn {entry, index} ->
         {Map.fetch!(@section_order, entry.section), index}
       end)
       |> Enum.map(&elem(&1, 0))

  @max_patch 256
  @key_format ~r/\A[a-z][a-z0-9_]*(\.[a-z0-9_]+)+\z/

  # --- compile-time checks --------------------------------------------------

  for entry <- @all do
    unless is_binary(entry.key) and byte_size(entry.key) <= 64 and
             Regex.match?(@key_format, entry.key),
           do: raise(ArgumentError, "settings registry: bad key #{inspect(entry.key)}")

    unless Map.has_key?(@section_order, entry.section),
      do: raise(ArgumentError, "settings registry: #{entry.key} names an unknown section")

    if entry.home != nil and entry.home not in entry.layers,
      do: raise(ArgumentError, "settings registry: #{entry.key} home is not one of its layers")

    if Entry.writable?(entry) do
      if entry.resettable and not (entry.default == nil and entry.nullable == false) do
        case Validate.check(entry, entry.default) do
          :ok ->
            :ok

          {:error, message} ->
            raise ArgumentError, "settings registry: #{entry.key} default #{message}"
        end
      end

      case entry.example do
        {:model, _provider, _model} ->
          :ok

        example ->
          if example == entry.default,
            do: raise(ArgumentError, "settings registry: #{entry.key} example equals its default")

          case Validate.check(entry, example) do
            :ok ->
              :ok

            {:error, message} ->
              raise ArgumentError, "settings registry: #{entry.key} example #{message}"
          end
      end
    end

    if entry.type == :enum and entry.default != nil and
         entry.default not in Entry.choice_values(entry),
       do: raise(ArgumentError, "settings registry: #{entry.key} default is not a choice")

    if entry.type in WireValue.numeric_types() and is_nil(entry.big_step) do
      if is_nil(entry.min) or is_nil(entry.max) or (entry.max - entry.min) / entry.step > 50,
        do: raise(ArgumentError, "settings registry: #{entry.key} needs a big_step")
    end
  end

  @keys Enum.map(@all, & &1.key)
  @ids Enum.map(@all, & &1.id)

  if length(Enum.uniq(@keys)) != length(@keys),
    do:
      raise(
        ArgumentError,
        "settings registry: duplicate keys #{inspect(@keys -- Enum.uniq(@keys))}"
      )

  if length(Enum.uniq(@ids)) != length(@ids),
    do: raise(ArgumentError, "settings registry: duplicate ids")

  @by_key Map.new(@all, &{&1.key, &1})
  @scalar_keys for entry <- @all, Entry.scalar?(entry), do: entry.key

  if length(@scalar_keys) > @max_patch,
    do: raise(ArgumentError, "settings registry: more scalar keys than one values.patch carries")

  @cli_entries for entry <- @all, entry.scope == :cli, do: entry
  @by_section Enum.group_by(@all, & &1.section)

  @by_stored_name @all
                  |> Enum.filter(&is_binary(&1.stored_name))
                  |> Enum.group_by(& &1.stored_name)

  # Words the deep links, search and `swarmcode config` resolve (§3.7.12).
  @synonyms (for entry <- @all, word <- entry.synonyms, reduce: %{} do
               acc -> Map.put_new(acc, String.downcase(word), {:key, entry.key})
             end)
            |> Map.merge(%{
              "lsp" => {:section, :language_servers},
              "language servers" => {:section, :language_servers},
              "agents.md" => {:record, "file", "instructions"},
              "instructions" => {:record, "file", "instructions"},
              "tavily" => {:record, "search_provider", "tavily"},
              "exa" => {:record, "search_provider", "exa"},
              "brave" => {:record, "search_provider", "brave"},
              "serper" => {:record, "search_provider", "serper"},
              "jina" => {:record, "search_provider", "jina"},
              "firecrawl" => {:record, "search_provider", "firecrawl"},
              "theme" => {:key, "terminal.theme"},
              "dark mode" => {:key, "terminal.theme"},
              "vim" => {:key, "terminal.keymap"},
              "editor" => {:key, "terminal.editor"},
              "model" => {:key, "models.chat"},
              "effort" => {:key, "efforts.default"},
              "budget" => {:key, "budget.monthly_usd"},
              "retention" => {:key, "storage.retention_days"},
              "mode" => {:key, "session.mode"},
              "plan" => {:key, "session.mode"},
              "consensus" => {:key, "session.mode"},
              "ultra" => {:key, "session.mode"}
            })

  @type synonym ::
          {:key, String.t()}
          | {:section, atom()}
          | {:record, kind :: String.t(), id :: String.t()}

  @doc "Every entry: rail order, then page order."
  @spec all() :: [Entry.t()]
  def all, do: @all

  @doc "The entry of a key."
  @spec fetch(term()) :: {:ok, Entry.t()} | :error
  def fetch(key) when is_binary(key), do: Map.fetch(@by_key, key)
  def fetch(_key), do: :error

  @doc "The entry of a key, or raise."
  @spec fetch!(String.t()) :: Entry.t()
  def fetch!(key), do: Map.fetch!(@by_key, key)

  @doc "The entries stored under a column / json name (`\"max_concurrent_agents\"`)."
  @spec by_stored_name(String.t()) :: [Entry.t()]
  def by_stored_name(name), do: Map.get(@by_stored_name, name, [])

  @doc "The entries of a section, in page order."
  @spec for_section(atom()) :: [Entry.t()]
  def for_section(section), do: Map.get(@by_section, section, [])

  @doc "Every key that holds a value (scopes global, session, project, cli, project_file)."
  @spec scalar_keys() :: [String.t()]
  def scalar_keys, do: @scalar_keys

  @doc "The cli.json entries (scope `:cli`)."
  @spec cli_entries() :: [Entry.t()]
  def cli_entries, do: @cli_entries

  @doc "The cli.json entry whose json name is `name`."
  @spec cli_entry(String.t()) :: {:ok, Entry.t()} | :error
  def cli_entry(name) do
    case Enum.find(@cli_entries, &(&1.storage == {:cli, name})) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @doc "Search and deep-link words (lower case)."
  @spec synonyms() :: %{String.t() => synonym()}
  def synonyms, do: @synonyms

  @doc "Resolve a typed word: a key, a synonym, a stored name or a section."
  @spec resolve(String.t()) :: synonym() | :error
  def resolve(text) when is_binary(text) do
    trimmed = String.trim(text)
    lower = String.downcase(trimmed)

    cond do
      Map.has_key?(@by_key, trimmed) -> {:key, trimmed}
      Map.has_key?(@synonyms, lower) -> Map.fetch!(@synonyms, lower)
      match?([_ | _], by_stored_name(trimmed)) -> {:key, hd(by_stored_name(trimmed)).key}
      match?({:ok, _}, Sections.fetch(trimmed)) -> {:section, elem(Sections.fetch(trimmed), 1)}
      true -> :error
    end
  end

  @doc "The record kinds (§2.23)."
  @spec record_kinds() :: [RecordKind.t()]
  def record_kinds, do: RecordKind.all()

  @doc "The export file format version (§3.3.7)."
  @spec export_version() :: 1
  def export_version, do: 1

  @doc "The most changes one `values.patch` carries (≥ the scalar key count)."
  @spec max_patch() :: pos_integer()
  def max_patch, do: @max_patch
end
