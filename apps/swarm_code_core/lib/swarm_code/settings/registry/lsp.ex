defmodule SwarmCode.Settings.Registry.Lsp do
  @moduledoc false
  # §2.8 Language servers: one entry per language of settings.lsp_servers.
  import SwarmCode.Settings.Registry.Build

  @languages [
    {"elixir", "Elixir", ".ex .exs", "elixir-ls --stdio"},
    {"erlang", "Erlang", ".erl .hrl", nil},
    {"typescript", "TypeScript", ".ts .tsx", "typescript-language-server --stdio"},
    {"javascript", "JavaScript", ".js .jsx .mjs .cjs", "typescript-language-server --stdio"},
    {"python", "Python", ".py", "pyright-langserver --stdio"},
    {"rust", "Rust", ".rs", "rust-analyzer"},
    {"go", "Go", ".go", "gopls serve"},
    {"c", "C", ".c .h", "clangd --log=error"},
    {"cpp", "C++", ".cpp .cxx .cc .hpp", "clangd --log=error"},
    {"ruby", "Ruby", ".rb .rake", "solargraph stdio"},
    {"java", "Java", ".java", "jdtls"},
    {"swift", "Swift", ".swift", "sourcekit-lsp"},
    {"zig", "Zig", ".zig", "zls"}
  ]

  @doc false
  def languages, do: @languages

  @doc false
  def default_commands,
    do:
      for(
        {language, _, _, command} <- @languages,
        command != nil,
        into: %{},
        do: {language, command}
      )

  @entries (for {language, label, extensions, command} <- @languages do
              global("lsp.#{language}", :language_servers, label,
                description:
                  "#{extensions} · built-in: #{command || "none — no default: set a command"}. Commands are split on whitespace; a path with spaces cannot be written. A running server keeps its command until it idles out (300 s) or is stopped.",
                storage: {:setting_map, :lsp_servers, language},
                type: :lsp_command,
                nullable: true,
                null_label: if(command, do: "built-in (#{command})", else: "no default"),
                validate: [:required, :one_line, {:max_length, 1024}],
                applies: :new_clients,
                shared: true,
                synonyms: [language],
                since: :c74,
                parity: "I§4"
              )
            end)

  @actions [
    action("lsp.check", :language_servers, "Check which are installed", "lsp.check",
      description:
        "Looks up each effective command's executable on PATH and counts running servers per project.",
      since: :c74,
      parity: "I§4"
    ),
    action("lsp.stop", :language_servers, "Stop running servers", "lsp.stop",
      description: "For the page's project or every project; applies changed commands now.",
      since: :c74,
      parity: "I§4"
    )
  ]

  def entries, do: @entries ++ @actions
end
