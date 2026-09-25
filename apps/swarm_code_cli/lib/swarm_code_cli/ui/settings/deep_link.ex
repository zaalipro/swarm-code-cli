defmodule SwarmCodeCLI.UI.Settings.DeepLink do
  @moduledoc """
  Where `/settings [ARG]`, F2, a palette row or `swarmcode settings [QUERY]`
  opens the layer (spec §3.7.12). Pure.

  `resolve(arg, resume)` answers `%{stack, search, deep_link}`:

    * blank → the resume point when there is one, else the Overview (its
      first attention item focused once the overview arrives);
    * `@…` → the search with the argument;
    * a section (`Sections.fetch/1`) → that section;
    * a registry key, a stored name or a synonym (`Registry.resolve/1`:
      `theme` → `terminal.theme`, `vim` → `terminal.keymap`, `lsp` → the
      section, `tavily` → that search provider's record) → its section with
      the row focused (records open when their list loads);
    * anything else → the search with the words; a provider or MCP server
      whose name is exactly the words opens once those records load.
  """

  alias SwarmCode.Settings.Registry
  alias SwarmCodeCLI.UI.Settings.{Page, Sections}

  # The section that lists each record kind (§2.23).
  @record_sections %{
    "provider" => :providers,
    "effort_level" => :providers,
    "effort_preset" => :providers,
    "search_provider" => :search_web,
    "mcp_server" => :mcp,
    "mcp_tool" => :mcp,
    "pricing_row" => :pricing,
    "unpriced_model" => :pricing,
    "project" => :approvals,
    "hook" => :project_file,
    "profile" => :project_file,
    "project_config" => :project_file,
    "file" => :memory,
    "command" => :library,
    "agent_def" => :library,
    "skill" => :library,
    "workflow" => :library,
    "lsp_language" => :language_servers,
    "storage_session" => :storage
  }

  @type t :: %{stack: [Page.t()], search: nil | String.t(), deep_link: term()}

  @max_arg_bytes 200

  @doc """
  The argument of `/settings ARG` as the action carries it: nil when blank,
  else at most 200 bytes (cut at a character boundary).
  """
  @spec clip(String.t()) :: String.t() | nil
  def clip(""), do: nil

  def clip(text) when byte_size(text) <= @max_arg_bytes, do: text

  def clip(text) do
    text
    |> String.graphemes()
    |> Enum.reduce_while("", fn grapheme, acc ->
      if byte_size(acc) + byte_size(grapheme) > @max_arg_bytes,
        do: {:halt, acc},
        else: {:cont, acc <> grapheme}
    end)
  end

  @doc "The section that lists records of `kind` (nil for a kind no page lists)."
  @spec record_section(String.t()) :: atom() | nil
  def record_section(kind), do: Map.get(@record_sections, kind)

  @doc "Resolve an open argument against the resume point (nil when none)."
  @spec resolve(term(), nil | map()) :: t()
  def resolve(nil, resume), do: blank(resume)

  def resolve({:section, id}, _resume), do: section(id)

  def resolve({:key, key}, resume) do
    case Registry.fetch(key) do
      {:ok, entry} -> key_page(entry)
      :error -> blank(resume)
    end
  end

  def resolve(text, resume) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      trimmed == "" -> blank(resume)
      String.starts_with?(trimmed, "@") -> search(trimmed, nil)
      true -> words(trimmed)
    end
  end

  def resolve(_arg, resume), do: blank(resume)

  defp words(text) do
    case Sections.fetch(text) do
      {:ok, id} ->
        section(id)

      :error ->
        case Registry.resolve(text) do
          {:key, key} -> key_page(Registry.fetch!(key))
          {:section, id} -> section(id)
          {:record, kind, id} -> record(kind, id)
          :error -> search(text, {:name, String.downcase(text)})
        end
    end
  end

  defp blank(%{stack: [_ | _] = stack}), do: %{stack: stack, search: nil, deep_link: nil}

  defp blank(_resume),
    do: %{stack: [Page.section(:overview)], search: nil, deep_link: :first_attention}

  defp section(id), do: %{stack: [Page.section(id)], search: nil, deep_link: nil}

  defp key_page(entry) do
    row = "key:" <> entry.key

    %{
      stack: [%Page{section: entry.section, cursor: row}],
      search: nil,
      deep_link: {:row, row}
    }
  end

  defp record(kind, id) do
    case record_section(kind) do
      nil -> search(id, nil)
      section -> %{stack: [Page.section(section)], search: nil, deep_link: {:record, kind, id}}
    end
  end

  defp search(query, deep_link),
    do: %{stack: [Page.section(:overview)], search: query, deep_link: deep_link}
end
