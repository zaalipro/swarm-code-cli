defmodule SwarmCode.Settings.Registry.Actions do
  @moduledoc false
  # Page actions of the record sections (§2.3 Providers, §2.7 MCP servers) and
  # §2.22 Import & export.
  import SwarmCode.Settings.Registry.Build

  @doc false
  def provider_presets do
    [
      %{
        id: "anthropic",
        name: "Anthropic",
        kind: "anthropic",
        base_url: "https://api.anthropic.com",
        effort_preset: "anthropic_adaptive",
        key: true
      },
      %{
        id: "openai",
        name: "OpenAI",
        kind: "openai_compatible",
        base_url: "https://api.openai.com/v1",
        effort_preset: "openai",
        key: true
      },
      %{
        id: "openrouter",
        name: "OpenRouter",
        kind: "openai_compatible",
        base_url: "https://openrouter.ai/api/v1",
        effort_preset: "openrouter",
        key: true
      },
      %{
        id: "deepseek",
        name: "DeepSeek",
        kind: "openai_compatible",
        base_url: "https://api.deepseek.com/v1",
        effort_preset: "deepseek",
        key: true
      },
      %{
        id: "llmotions",
        name: "llmotions",
        kind: "openai_compatible",
        base_url: "https://cli.llmotions.com/v1",
        effort_preset: nil,
        key: true
      },
      %{
        id: "ollama",
        name: "Ollama",
        kind: "openai_compatible",
        base_url: "http://localhost:11434/v1",
        effort_preset: nil,
        key: false
      },
      %{
        id: "lmstudio",
        name: "LM Studio",
        kind: "openai_compatible",
        base_url: "http://localhost:1234/v1",
        effort_preset: nil,
        key: false
      },
      %{
        id: "other",
        name: "Other",
        kind: "openai_compatible",
        base_url: "",
        effort_preset: nil,
        key: true
      }
    ]
  end

  @entries [
    action("providers.add", :providers, "Add a provider", "provider.create",
      description:
        "A draft from a preset: Anthropic, OpenAI, OpenRouter, DeepSeek, llmotions, Ollama, LM Studio or Other. Ctrl-S creates it and runs the test.",
      synonyms: ["add provider", "new provider"],
      parity: "D§4c, D§4d"
    ),
    action(
      "providers.fetch_all",
      :providers,
      "Fetch every provider's models",
      "provider.fetch_all",
      description: "Lists every provider's models and shows what changed; apply per provider.",
      parity: "D§1c"
    ),
    action("mcp.add", :mcp, "Add an MCP server", "mcp.create",
      description: "A draft (stdio, enabled); Ctrl-S creates it.",
      synonyms: ["add mcp server", "new mcp server"],
      parity: "D§6c"
    ),
    action("mcp.import", :mcp, "Import from .mcp.json", "mcp.import.read",
      description:
        "Reads <project root>/.mcp.json or a path you type (the mcpServers object); ticked servers are created; secret-looking env and header values arrive masked.",
      synonyms: [".mcp.json", "import mcp"],
      since: :c74,
      parity: "NEW"
    ),
    action("transfer.export", :import_export, "Export settings…", "export",
      description:
        "Writes the chosen scopes to a JSON file (0600). Never secrets: MCP values are written as <secret: set> unless you include plain values.",
      synonyms: ["export settings"],
      since: :c74,
      parity: "NEW"
    ),
    action("transfer.import", :import_export, "Import settings…", "import.preview",
      description:
        "Reads a file, shows key · now · after with ticks, and applies the ticked rows as one undoable batch. Keys are pasted after an import, never imported.",
      synonyms: ["import settings"],
      since: :c74,
      parity: "NEW"
    ),
    action(
      "transfer.reset_everything",
      :import_export,
      "Reset everything to defaults…",
      "values.reset",
      description:
        "Clears cli.json keys (unknown keys stay) and writes every global value's default. Never touches secrets, records, sessions or projects.",
      synonyms: ["factory reset", "reset all"],
      since: :c74,
      parity: "NEW"
    )
  ]

  def entries, do: @entries
end
