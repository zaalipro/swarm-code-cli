# spec 70 B1
defmodule SwarmCode.Domain.LSP.Language do
  @moduledoc "Extension-to-language mapping and default LSP server commands."

  # Only the languages where a server exists and works over stdio.
  @extensions %{
    ".ex" => "elixir",
    ".exs" => "elixir",
    ".erl" => "erlang",
    ".hrl" => "erlang",
    ".ts" => "typescript",
    ".tsx" => "typescript",
    ".js" => "javascript",
    ".jsx" => "javascript",
    ".mjs" => "javascript",
    ".cjs" => "javascript",
    ".py" => "python",
    ".rs" => "rust",
    ".go" => "go",
    ".c" => "c",
    ".h" => "c",
    ".cpp" => "cpp",
    ".cxx" => "cpp",
    ".cc" => "cpp",
    ".hpp" => "cpp",
    ".rb" => "ruby",
    ".rake" => "ruby",
    ".java" => "java",
    ".swift" => "swift",
    ".zig" => "zig"
  }

  # The command string is split on whitespace to get [executable | args].
  # A user override replaces the whole entry for that language.
  @defaults %{
    "elixir" => "elixir-ls --stdio",
    "typescript" => "typescript-language-server --stdio",
    "javascript" => "typescript-language-server --stdio",
    "python" => "pyright-langserver --stdio",
    "rust" => "rust-analyzer",
    "go" => "gopls serve",
    "c" => "clangd --log=error",
    "cpp" => "clangd --log=error",
    "ruby" => "solargraph stdio",
    "java" => "jdtls",
    "swift" => "sourcekit-lsp",
    "zig" => "zls"
  }

  @doc "The language ID for a file path, or nil."
  @spec detect(String.t()) :: String.t() | nil
  def detect(path) do
    ext = Path.extname(path)
    Map.get(@extensions, ext)
  end

  @doc "The [executable | args] for `language`, or nil when unconfigured or off."
  @spec server_command(String.t(), map()) :: [String.t()] | nil
  def server_command(language, overrides \\ %{}) do
    raw = Map.get(overrides, language) || Map.get(@defaults, language)

    case raw do
      nil -> nil
      "off" -> nil
      cmd when is_binary(cmd) -> String.split(cmd)
    end
  end

  @doc """
  The `file://` URI of an absolute path, percent-encoded per segment (spec 73
  T21). `"file://" <> path` sent a space, `#` or `%` raw, which servers reject
  or mis-resolve, and their answers came back encoded and unreadable.
  """
  @spec file_uri(String.t()) :: String.t()
  def file_uri(path) when is_binary(path),
    do: "file://" <> URI.encode(path, &(URI.char_unreserved?(&1) or &1 == ?/))

  @doc "The path of a `file://` URI, percent-decoded; anything else unchanged (spec 73 T21)."
  @spec uri_to_path(String.t()) :: String.t()
  def uri_to_path("file://" <> encoded), do: URI.decode(encoded)
  def uri_to_path(other), do: other
end
