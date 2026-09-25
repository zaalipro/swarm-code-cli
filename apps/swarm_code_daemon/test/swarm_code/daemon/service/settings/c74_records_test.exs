defmodule SwarmCode.Daemon.Service.Settings.C74RecordsTest do
  @moduledoc """
  pass 74 S2-1: the record kinds S2 owns after `c74-S1-core` (§2.23) — every
  kind with a secret field declares it, the list bounds of §3.12, and every
  S2 handler's records decode against their kind as the client would.
  """
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Service.Settings.{Efforts, Models, Providers, Router}
  alias SwarmCode.Settings.RecordKind
  alias SwarmCode.Test.C74S2

  @s2_handlers [
    SwarmCode.Daemon.Service.Settings.Providers,
    SwarmCode.Daemon.Service.Settings.Efforts,
    SwarmCode.Daemon.Service.Settings.Models,
    SwarmCode.Daemon.Service.Settings.Pricing,
    SwarmCode.Daemon.Service.Settings.Search,
    SwarmCode.Daemon.Service.Settings.MCP,
    SwarmCode.Daemon.Service.Settings.MCPImport,
    SwarmCode.Daemon.Service.Settings.Storage,
    SwarmCode.Daemon.Service.Settings.LSP,
    SwarmCode.Daemon.Service.Settings.Files,
    SwarmCode.Daemon.Service.Settings.Library,
    SwarmCode.Daemon.Service.Settings.ProjectConfig
  ]

  defp kind!(name) do
    {:ok, kind} = RecordKind.fetch(name)
    kind
  end

  describe "declarations" do
    test "every record kind with a secret field is listed" do
      secret_kinds =
        for kind <- RecordKind.all(),
            field <- kind.fields,
            field.secret or field.type == :kv_secrets,
            uniq: true,
            do: kind.name

      assert Enum.sort(secret_kinds) ==
               Enum.sort(~w(provider search_provider mcp_server mcp_import_draft))

      assert RecordKind.secret_fields(kind!("provider")) == ["api_key"]
      assert RecordKind.secret_fields(kind!("search_provider")) == ["api_key"]

      for kind <- ~w(mcp_server mcp_import_draft), name <- ~w(env headers) do
        assert RecordKind.field(kind!(kind), name).type == :kv_secrets
      end

      # a field whose name says it holds a credential is secret or kv-masked
      for kind <- RecordKind.all(),
          field <- kind.fields,
          field.name =~ ~r/(^|_)(api_key|token|secret|password|headers|env)$/i do
        assert field.secret or field.type == :kv_secrets,
               "#{kind.name}.#{field.name} looks like a credential but is not masked"
      end
    end

    test "the list bounds of §3.12" do
      assert RecordKind.field(kind!("provider"), "models").max == 2_000
      assert RecordKind.field(kind!("mcp_server"), "tools").max == 512
      assert RecordKind.field(kind!("mcp_server"), "disabled_tools").max == 512
      assert RecordKind.field(kind!("mcp_server"), "output").max == 20
      assert RecordKind.field(kind!("project_config"), "ignored_entries").max == 64
      assert RecordKind.field(kind!("file"), "winner")
      assert RecordKind.field(kind!("file"), "content").type == :text
    end

    test "every S2 handler in the build is a Handler with its routed actions and views" do
      for module <- @s2_handlers, Code.ensure_loaded?(module) do
        behaviours = Keyword.get_values(module.module_info(:attributes), :behaviour)
        assert SwarmCode.Daemon.Service.Settings.Handler in List.flatten(behaviours)

        for action <- module.actions() do
          assert Router.action_module(action) == module, "#{action} routes elsewhere"
        end

        for {view, kind} <- module.views() do
          assert {:ok, ^module} = Router.view(view, kind)
        end
      end
    end
  end

  describe "handler records decode against their kinds" do
    setup do
      fx = C74S2.repo!("c74-records")
      data = C74S2.appendix_a!(fx)
      Map.merge(data, %{ctx: C74S2.context(data.ailogic, data.conversation)})
    end

    test "providers, effort presets and model options", c do
      {:ok, page} = Providers.query("records", "providers", %{}, c.ctx)
      assert page["kind"] == "provider" and page["total"] == 4
      C74S2.declared!(page)

      {:ok, record} =
        Providers.query("record", "provider", %{"id" => c.deepseek.id}, c.ctx)

      C74S2.declared!(record)
      refute inspect(record) =~ "sk-"

      {:ok, presets} = Efforts.query("records", "effort_presets", %{}, c.ctx)
      C74S2.declared!(presets)

      {:ok, options} = Models.query("records", "model_options", %{}, c.ctx)
      C74S2.declared!(options)
    end
  end
end
