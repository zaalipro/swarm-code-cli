defmodule SwarmCode.Settings.Sections do
  @moduledoc """
  The 22 settings sections in rail order (pass 74, spec §1.3 D4 and §3.2.5).

  `fetch/1` matches a section id, its title or one of its synonyms,
  case-insensitively with spaces, `-` and `_` folded. `theme` is deliberately
  not a section synonym: it names the key `terminal.theme`.
  """

  @sections [
    %{id: :overview, title: "Overview", group: nil, synonyms: ["home", "summary"]},
    %{
      id: :models_effort,
      title: "Models & effort",
      group: "models",
      synonyms: ["models", "effort", "efforts", "defaults"]
    },
    %{
      id: :providers,
      title: "Providers",
      group: "models",
      synonyms: ["provider", "api keys"]
    },
    %{id: :pricing, title: "Pricing", group: "models", synonyms: ["prices", "price", "cost"]},
    %{
      id: :search_web,
      title: "Search & web",
      group: "tools",
      synonyms: ["search", "web", "web search", "reader", "search providers"]
    },
    %{id: :deep_research, title: "Deep research", group: "tools", synonyms: ["research"]},
    %{
      id: :mcp,
      title: "MCP servers",
      group: "tools",
      synonyms: ["mcp server", "servers"]
    },
    %{
      id: :language_servers,
      title: "Language servers",
      group: "tools",
      synonyms: ["language server", "lsp servers"]
    },
    %{
      id: :agents_limits,
      title: "Agents & limits",
      group: "agents",
      synonyms: ["limits", "agents", "shell", "isolation", "timeouts"]
    },
    %{
      id: :approvals,
      title: "Approvals & trust",
      group: "agents",
      synonyms: ["approval", "trust", "permissions", "always allowed"]
    },
    %{
      id: :project_file,
      title: "Project file",
      group: "agents",
      synonyms: ["config.json", "hooks", "profiles", "project config"]
    },
    %{
      id: :memory,
      title: "Memory & instructions",
      group: "agents",
      synonyms: ["memory", "memory.md"]
    },
    %{
      id: :library,
      title: "Library",
      group: "agents",
      synonyms: ["commands", "agent definitions", "skills", "workflows"]
    },
    %{
      id: :appearance,
      title: "Appearance",
      group: "this terminal",
      synonyms: ["colours", "colors", "glyphs"]
    },
    %{
      id: :layout,
      title: "Layout & transcript",
      group: "this terminal",
      synonyms: ["transcript", "panel", "side panel"]
    },
    %{
      id: :keys,
      title: "Keys & input",
      group: "this terminal",
      synonyms: ["keybindings", "key bindings", "bindings", "input", "mouse"]
    },
    %{
      id: :startup,
      title: "Session & startup",
      group: "this terminal",
      synonyms: ["session", "launch"]
    },
    %{id: :storage, title: "Storage", group: "data", synonyms: ["cleanup", "disk"]},
    %{id: :budget, title: "Budget & usage", group: "data", synonyms: ["usage", "spend"]},
    %{
      id: :desktop,
      title: "Desktop app",
      group: "more",
      synonyms: ["desktop", "desktop keys", "window"]
    },
    %{
      id: :files_env,
      title: "Files & environment",
      group: "more",
      synonyms: ["files", "environment", "env", "paths", "doctor", "versions"]
    },
    %{
      id: :import_export,
      title: "Import & export",
      group: "more",
      synonyms: ["import", "export", "backup", "transfer"]
    }
  ]

  @ids Enum.map(@sections, & &1.id)
  @by_id Map.new(@sections, &{&1.id, &1})
  @id_strings Map.new(@sections, &{Atom.to_string(&1.id), &1.id})

  @type id :: atom()
  @type section :: %{id: id(), title: String.t(), group: String.t() | nil, synonyms: [String.t()]}

  @doc "The 22 sections in rail order."
  @spec all() :: [section()]
  def all, do: @sections

  @doc "The section ids in rail order."
  @spec ids() :: [id()]
  def ids, do: @ids

  @doc "The section id strings (the wire form)."
  @spec id_strings() :: [String.t()]
  def id_strings, do: Map.keys(@id_strings)

  @doc "The rail groups in order: `{group heading or nil, [section id]}`."
  @spec groups() :: [{String.t() | nil, [id()]}]
  def groups do
    @sections
    |> Enum.chunk_by(& &1.group)
    |> Enum.map(fn [first | _] = chunk -> {first.group, Enum.map(chunk, & &1.id)} end)
  end

  @doc "The section map of an id."
  @spec get(id()) :: section() | nil
  def get(id) when is_atom(id), do: Map.get(@by_id, id)
  def get(_id), do: nil

  @doc "The section id of a wire id string (exact match), or nil. Never creates atoms."
  @spec from_wire(term()) :: id() | nil
  def from_wire(value) when is_binary(value), do: Map.get(@id_strings, value)
  def from_wire(_value), do: nil

  @doc "True when `value` is a known section id (atom) or its wire string."
  @spec valid?(term()) :: boolean()
  def valid?(value) when is_atom(value), do: Map.has_key?(@by_id, value)
  def valid?(value) when is_binary(value), do: Map.has_key?(@id_strings, value)
  def valid?(_value), do: false

  @doc """
  Resolve a typed section name: an id, a title or a synonym, case-insensitive,
  with spaces, `-` and `_` folded (`"mcp"`, `"Search & web"`, `"keybindings"`).
  """
  @spec fetch(String.t()) :: {:ok, id()} | :error
  def fetch(text) when is_binary(text) do
    folded = fold(text)

    case Enum.find(@sections, &section_match?(&1, folded)) do
      nil -> :error
      section -> {:ok, section.id}
    end
  end

  def fetch(_text), do: :error

  defp section_match?(section, folded) do
    folded != "" and
      (fold(Atom.to_string(section.id)) == folded or fold(section.title) == folded or
         Enum.any?(section.synonyms, &(fold(&1) == folded)))
  end

  @doc false
  @spec fold(String.t()) :: String.t()
  def fold(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[\s_\-&]+/u, "")
  end
end
