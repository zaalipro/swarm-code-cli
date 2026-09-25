defmodule SwarmCode.Settings.Registry.Records do
  @moduledoc false
  # §2.23 Record kinds and task row kinds. Created by S1 for the tag
  # `c74-S1-core`; S2 owns this file after it (additive changes only, and a
  # field the client would receive is noted first — the decoder refuses
  # undeclared fields).
  alias SwarmCode.Settings.RecordKind
  alias SwarmCode.Settings.RecordKind.Field

  defp f(name, type, opts \\ []), do: struct(%Field{name: name, type: type}, opts)
  defp secret(name), do: f(name, :secret, secret: true, editable: true)
  defp derived(name, type, opts \\ []), do: f(name, type, [derived: true] ++ opts)

  defp kind(name, table, fields, opts \\ []),
    do: struct(%RecordKind{name: name, table: table, fields: fields}, opts)

  @doc false
  def kinds do
    [
      kind("provider", "providers", [
        f("id", :uuid),
        f("name", :string,
          required: true,
          editable: true,
          max: 120,
          nullable: false,
          messages: %{required: "can't be blank", taken: "has already been taken"}
        ),
        f("kind", :enum,
          editable: true,
          nullable: false,
          choices: ["openai_compatible", "anthropic", "fake"]
        ),
        f("base_url", :url,
          required: true,
          editable: true,
          nullable: false,
          messages: %{required: "can't be blank", format: "must start with http:// or https://"}
        ),
        secret("api_key"),
        f("models", :list, editable: true, max: 2_000, item: :model_id),
        f("default_model", :string, editable: true),
        f("fallbacks", :bool, editable: true, nullable: false),
        f("effort_levels", {:records, "effort_level"}, editable: true, max: 32),
        f("model_effort_levels", :map, editable: true, max: 64),
        f("updated_at", :datetime),
        derived("usable", :bool),
        derived("models_count", :integer),
        derived("last_test", :map),
        derived("last_fetch", :map),
        derived("used_by", :map),
        derived("caps", :map),
        derived("builtin_levels", {:records, "effort_level"}, max: 32),
        derived("presets", {:records, "effort_preset"}, max: 32)
      ]),
      kind(
        "effort_level",
        nil,
        [
          f("key", :string, required: true, editable: true),
          f("label", :string, editable: true),
          f("hint", :string, editable: true),
          f("body", :json, editable: true),
          f("drop", :list, editable: true, max: 32)
        ],
        role: :nested,
        id_field: "key"
      ),
      kind(
        "effort_preset",
        nil,
        [
          f("id", :string),
          f("name", :string),
          f("kinds", :list, max: 8),
          f("levels", {:records, "effort_level"}, max: 32)
        ],
        role: :nested
      ),
      kind(
        "search_provider",
        "search_providers",
        [
          f("kind", :enum, choices: ~w(tavily exa brave serper jina firecrawl), nullable: false),
          f("role", :enum, choices: ~w(engine reader), nullable: false),
          derived("label", :string),
          derived("hint", :string),
          f("enabled", :bool,
            editable: true,
            nullable: false,
            messages: %{needs_key: "is needed to enable {kind}"}
          ),
          secret("api_key"),
          derived("needs_key", :bool),
          f("base_url", :url,
            editable: true,
            messages: %{format: "must start with http:// or https://"}
          ),
          derived("default_base_url", :string),
          f("position", :integer, editable: true),
          derived("persisted", :bool),
          derived("last_test", :map)
        ],
        id_field: "kind"
      ),
      kind("mcp_server", "mcp_servers", [
        f("id", :uuid),
        f("updated_at", :datetime),
        f("name", :string, required: true, editable: true, max: 64, nullable: false),
        f("enabled", :bool, editable: true, nullable: false),
        f("project_id", :uuid, editable: true),
        derived("scope", :enum, choices: ~w(global project)),
        f("transport", :enum, editable: true, choices: ~w(stdio http), nullable: false),
        f("command", :string, editable: true),
        f("args", :list, editable: true, max: 64),
        f("env", :kv_secrets, editable: true, max: 64),
        f("url", :url, editable: true),
        f("headers", :kv_secrets, editable: true, max: 64),
        f("disabled_tools", :list, editable: true, max: 512),
        derived("status", :enum, choices: ~w(ready connecting error stopped)),
        derived("status_message", :string),
        derived("slug", :string),
        derived("tools_total", :integer),
        derived("tools_enabled", :integer),
        derived("tools", {:records, "mcp_tool"}, max: 512),
        derived("output", :list, max: 20)
      ]),
      kind(
        "mcp_tool",
        nil,
        [
          f("name", :string),
          f("published_name", :string),
          f("description", :string),
          f("enabled", :bool, editable: true),
          f("read_only", :bool)
        ],
        role: :nested,
        id_field: "name"
      ),
      kind(
        "pricing_row",
        nil,
        [
          f("model", :string, required: true, editable: true, max: 256),
          f("input", :number, required: true, editable: true),
          f("output", :number, required: true, editable: true),
          f("cache_read", :number, editable: true),
          f("cache_write", :number, editable: true),
          f("context_window", :integer, editable: true),
          derived("derived_cache_read", :number),
          derived("derived_cache_write", :number)
        ],
        id_field: "model"
      ),
      kind(
        "unpriced_model",
        nil,
        [f("model", :string), f("conversations_30d", :integer), f("in_defaults", :bool)],
        id_field: "model"
      ),
      kind("project", "projects", [
        f("id", :uuid),
        f("name", :string),
        f("root", :string),
        f("approval_mode", :enum, choices: ~w(read_only auto full_access)),
        f("trusted", :bool),
        f("trusted_at", :datetime),
        f("prefixes", :list, max: 64),
        f("scratch", :bool),
        f("last_opened_at", :datetime),
        f("current", :bool)
      ]),
      kind(
        "hook",
        nil,
        [
          f("event", :enum,
            choices: ~w(session_start pre_tool_use post_tool_use),
            nullable: false
          ),
          f("index", :integer),
          f("command", :string, required: true, editable: true),
          f("matcher", :string, editable: true),
          f("timeout_ms", :integer, editable: true),
          f("output_cap", :integer, editable: true)
        ],
        role: :nested,
        id_field: nil
      ),
      kind(
        "profile",
        nil,
        [
          f("name", :string, required: true, editable: true),
          f("effort", :string, editable: true),
          f("swarm_effort", :string, editable: true),
          f("model", :string, editable: true),
          f("swarm_model", :string, editable: true)
        ],
        role: :nested,
        id_field: "name"
      ),
      kind("project_config", nil, [
        f("id", :uuid),
        f("path", :string),
        f("exists", :bool),
        f("parse", :enum, choices: ~w(ok invalid missing)),
        f("error", :string),
        f("line", :integer),
        f("column", :integer),
        f("fingerprint", :map),
        f("trusted", :bool),
        f("hooks", :map),
        f("profiles", {:records, "profile"}, max: 64),
        f("top_level", :map),
        f("denied", :list, max: 16),
        f("unknown_keys", :list, max: 64),
        f("ignored_entries", :list, max: 64)
      ]),
      kind(
        "file",
        nil,
        [
          f("file_kind", :enum,
            choices:
              ~w(memory_project memory_global instructions command agent skill workflow project_config)
          ),
          f("ref", :string),
          f("name", :string),
          f("scope", :string),
          f("path", :string),
          f("bytes", :integer),
          f("lines", :integer),
          f("fingerprint", :map),
          f("editable_in_place", :bool),
          f("too_large", :bool),
          f("content", :text),
          f("winner", :string),
          f("exists", :bool),
          f("trusted", :bool),
          f("parse", :string)
        ],
        id_field: "ref"
      ),
      kind(
        "command",
        nil,
        [
          f("ref", :string),
          f("name", :string),
          f("scope", :enum, choices: ~w(project global)),
          f("description", :string),
          f("swarm", :bool),
          f("mode", :string),
          f("overrides_global", :bool),
          f("shadowed_by_builtin", :bool),
          f("path", :string)
        ],
        id_field: "ref"
      ),
      kind(
        "agent_def",
        nil,
        [
          f("ref", :string),
          f("name", :string),
          f("tier", :enum, choices: ~w(project user bundled)),
          f("description", :string),
          f("tools_label", :string),
          f("model", :string),
          f("effort", :string),
          f("prewalk", :bool),
          f("max_turns", :integer),
          f("shadows", :string),
          f("shadowed", :bool),
          f("parse_error", :string),
          f("path", :string)
        ],
        id_field: "ref"
      ),
      kind(
        "skill",
        nil,
        [
          f("ref", :string),
          f("name", :string),
          f("scope", :enum, choices: ~w(project user builtin)),
          f("description", :string),
          f("files", :integer),
          f("bytes", :integer),
          f("shadowed", :bool),
          f("path", :string)
        ],
        id_field: "ref"
      ),
      kind(
        "workflow",
        nil,
        [
          f("ref", :string),
          f("name", :string),
          f("scope", :enum, choices: ~w(project user builtin)),
          f("path", :string),
          f("smoke", :string)
        ],
        id_field: "ref"
      ),
      kind(
        "lsp_language",
        nil,
        [
          f("language", :string),
          f("extensions", :list, max: 8),
          f("default", :string),
          f("override", :string),
          f("effective", :string),
          f("installed", :bool),
          f("executable", :string),
          f("running", :list, max: 64)
        ],
        role: :task_row,
        id_field: "language"
      ),
      kind("storage_session", nil, [
        f("id", :uuid),
        f("title", :string),
        f("project", :string),
        f("updated_at", :datetime),
        f("messages", :integer),
        f("runs", :integer),
        f("bytes", :integer),
        f("running", :bool),
        f("open", :bool),
        f("pinned", :bool),
        f("deletable", :bool),
        f("reason", :string)
      ]),
      kind(
        "model_option",
        nil,
        [
          f("provider_id", :uuid),
          f("provider_name", :string),
          f("provider_kind", :string),
          f("model", :string),
          f("price", :map),
          f("context_window", :integer),
          f("in_last_fetch", :bool),
          f("provider_default", :bool)
        ],
        id_field: nil
      ),
      kind(
        "usage_row",
        nil,
        [
          f("model", :string),
          f("input_tokens", :integer),
          f("output_tokens", :integer),
          f("cost_usd", :number)
        ],
        id_field: "model"
      ),
      kind(
        "model_diff_row",
        nil,
        [
          f("model", :string),
          f("change", :enum, choices: ~w(new gone same)),
          f("conversations", :integer)
        ],
        role: :task_row,
        id_field: "model"
      ),
      kind(
        "import_row",
        nil,
        [
          f("id", :string),
          f("scope", :string),
          f("key_or_record", :string),
          f("now", :json),
          f("after", :json),
          f("status", :enum, choices: ~w(change same invalid secret_skipped)),
          f("message", :string)
        ],
        role: :task_row
      ),
      kind(
        "mcp_import_draft",
        nil,
        [
          f("name", :string),
          f("transport", :string),
          f("command", :string),
          f("args", :list, max: 64),
          f("env", :kv_secrets, max: 64),
          f("url", :string),
          f("headers", :kv_secrets, max: 64),
          f("conflict", :bool),
          f("unsupported", :bool),
          f("message", :string),
          f("variables", :list, max: 128)
        ],
        role: :task_row,
        id_field: "name"
      ),
      kind("plan_item", nil, [f("label", :string), f("count", :integer), f("bytes", :integer)],
        role: :task_row,
        id_field: nil
      ),
      kind("check", nil, [f("id", :string), f("ok", :bool), f("message", :string)],
        role: :task_row
      ),
      kind("smoke_row", nil, [f("ref", :string), f("name", :string), f("smoke", :string)],
        role: :task_row,
        id_field: "ref"
      )
    ]
  end

  @doc false
  def by_name, do: Map.new(kinds(), &{&1.name, &1})

  @doc "The row kind a task action's `view=task` rows decode against (§2.23)."
  def task_rows do
    %{
      "provider.fetch_models" => "model_diff_row",
      "import.preview" => "import_row",
      "mcp.import.read" => "mcp_import_draft",
      "storage.plan" => "plan_item",
      "doctor" => "check",
      "workflow.smoke" => "smoke_row",
      "lsp.check" => "lsp_language"
    }
  end

  @doc "The record kind of a `records:<kind>`/`record:<kind>` view (§3.3.2)."
  def query_kind_records do
    %{
      "providers" => "provider",
      "provider" => "provider",
      "model_options" => "model_option",
      "effort_presets" => "effort_preset",
      "pricing_rows" => "pricing_row",
      "unpriced_models" => "unpriced_model",
      "search_providers" => "search_provider",
      "search_provider" => "search_provider",
      "mcp_servers" => "mcp_server",
      "mcp_server" => "mcp_server",
      "storage_sessions" => "storage_session",
      "memory_files" => "file",
      "commands" => "command",
      "agent_defs" => "agent_def",
      "skills" => "skill",
      "workflows" => "workflow",
      "projects" => "project",
      "usage_rows" => "usage_row",
      "project_config" => "project_config"
    }
  end
end
