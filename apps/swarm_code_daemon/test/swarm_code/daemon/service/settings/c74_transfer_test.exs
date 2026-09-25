defmodule SwarmCode.Daemon.Service.Settings.C74TransferTest do
  @moduledoc """
  pass74 S1-12 (§3.3.7): export v1, import preview and apply, and doctor on
  fixture databases. The tasks' run functions are called in a task of the
  test (as the backend would start them).
  """
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.Service.Settings
  alias SwarmCode.Daemon.Service.Settings.{Doctor, Result, TaskSpec, Transfer, Values}
  alias SwarmCode.Domain.{Cache, MCP, Providers, Repo, Search}
  alias SwarmCode.Settings.{Entry, Registry}
  alias SwarmCode.Test.C74S1

  @moduletag timeout: 120_000

  setup do
    %{dir: dir} = C74S1.repo!("c74-s1-transfer")
    fixture = C74S1.appendix_a!(dir)

    {:ok, _} =
      SwarmCode.Domain.Settings.update(%{
        pricing: %{"deepseek-v4-pro" => %{"input" => 0.27, "output" => 1.1}},
        lsp_servers: %{"erlang" => "erlang_ls"},
        keybindings: %{"side" => "meta+shift+s"}
      })

    {:ok, _} =
      MCP.create(%{
        name: "github",
        transport: "stdio",
        command: "github-mcp-server",
        args: ["stdio"],
        env: %{"GITHUB_PERSONAL_ACCESS_TOKEN" => C74S1.canary(), "GITHUB_TOOLSETS" => "repos"},
        enabled: false
      })

    {:ok, _} = Search.upsert("tavily", %{enabled: true, api_key: "tvly-canary-0000000000"})
    Cache.clear()

    on_exit(fn -> Application.delete_env(:swarm_code_daemon, :research_root) end)
    Map.put(fixture, :dir, dir)
  end

  defp ctx(fixture, fields \\ []),
    do: C74S1.context(fixture, Keyword.merge([conversation: nil], fields))

  defp run(%TaskSpec{run: run}) do
    Task.async(fn -> run.(fn _ -> :ok end) end) |> Task.await(30_000)
  end

  defp export!(fixture, path, attributes \\ %{}) do
    command =
      C74S1.command("export",
        target: %{"path" => path},
        attributes: Map.merge(%{"terminal" => %{"panel" => "compact"}}, attributes)
      )

    assert {:task, %TaskSpec{kind: :file} = spec, %Result{status: :accepted}} =
             Settings.command(command, ctx(fixture))

    run(spec)
  end

  # Model values name their provider (ids differ between databases).
  defp global_values(ctx) do
    entries = for e <- Registry.all(), Entry.writable?(e), e.home == :global, do: e
    %{"values" => values} = Values.body(%{ctx | conversation: nil}, entries)
    names = Map.new(Providers.list(), &{&1.id, &1.name})

    Map.new(values, fn value ->
      shown =
        case value["value"] do
          %{"provider_id" => id} = model -> Map.put(model, "provider_id", names[id])
          other -> other
        end

      {value["key"], {shown, value["state"]}}
    end)
  end

  test "export writes v1 at 0600 with no secret; MCP values are masked unless asked", fixture do
    path = Path.join(fixture.dir, "settings.json")
    assert {:ok, %{"bytes" => bytes}} = export!(fixture, path)

    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    text = File.read!(path)
    assert byte_size(text) == bytes
    refute text =~ C74S1.canary()
    refute text =~ "sk-test-deepseek"
    refute text =~ "tvly-canary"
    assert File.ls!(fixture.dir) |> Enum.filter(&String.ends_with?(&1, ".tmp")) == []

    doc = Jason.decode!(text)
    assert %{"format" => "swarmcode-settings", "version" => 1} = doc
    assert doc["scopes"] == Transfer.scopes()
    assert doc["global"]["limits.max_concurrent_agents"] == 6

    assert doc["global"]["models.chat"] == %{
             "provider" => "DeepSeek",
             "model" => "deepseek-v4-pro"
           }

    assert [%{"name" => "github", "env" => env}] = doc["mcp_servers"]

    assert env == %{
             "GITHUB_PERSONAL_ACCESS_TOKEN" => "<secret: set>",
             "GITHUB_TOOLSETS" => "<secret: set>"
           }

    assert %{"name" => "DeepSeek", "api_key" => "<secret: set>"} =
             Enum.find(doc["providers"], &(&1["name"] == "DeepSeek"))

    assert %{"name" => "Ollama", "api_key" => nil} =
             Enum.find(doc["providers"], &(&1["name"] == "Ollama"))

    assert doc["pricing"] == %{"deepseek-v4-pro" => %{"input" => 0.27, "output" => 1.1}}
    assert doc["lsp"] == %{"erlang" => "erlang_ls"}
    assert doc["desktop_keys"] == %{"side" => "meta+shift+s"}
    assert doc["terminal"] == %{"panel" => "compact"}
    assert doc["project"]["approval_mode"] == "auto"

    plain = Path.join(fixture.dir, "plain.json")
    assert {:ok, _} = export!(fixture, plain, %{"mcp_plain_values" => true})
    [server] = Jason.decode!(File.read!(plain))["mcp_servers"]

    assert server["env"] == %{
             "GITHUB_PERSONAL_ACCESS_TOKEN" => "<secret: set>",
             "GITHUB_TOOLSETS" => "repos"
           }
  end

  test "export refuses a missing folder and an existing file unless allowed", fixture do
    missing = Path.join([fixture.dir, "nope", "s.json"])

    assert {:error, %{message: "the folder does not exist: " <> _}} =
             Settings.command(
               C74S1.command("export", target: %{"path" => missing}),
               ctx(fixture)
             )

    path = Path.join(fixture.dir, "s.json")
    File.write!(path, "{}")

    assert {:error, %{message: "that file exists; choose another name or allow replacing it"}} =
             Settings.command(C74S1.command("export", target: %{"path" => path}), ctx(fixture))

    assert {:ok, _} = export!(fixture, path, %{"overwrite" => true})
    assert %{"format" => "swarmcode-settings"} = Jason.decode!(File.read!(path))
  end

  test "export then import on a fresh database gives the same values", fixture do
    path = Path.join(fixture.dir, "roundtrip.json")
    assert {:ok, _} = export!(fixture, path)
    before = global_values(ctx(fixture))

    # A fresh database: the second fixture Repo replaces the first.
    stop_supervised!(Repo)
    %{dir: fresh} = C74S1.repo!("c74-s1-fresh")
    project = C74S1.project!(fresh, "ailogic")
    fresh_ctx = C74S1.context(%{ailogic: project, conversation: nil})

    preview =
      C74S1.command("import.preview", target: %{"path" => path})

    assert {:task, spec, _} = Settings.command(preview, fresh_ctx)
    assert spec.holds_secrets?
    assert {:ok, %{"rows" => rows, "_document" => _} = result} = run(spec)
    assert rows != [] and length(rows) <= 2_000
    assert Enum.all?(rows, &(&1["status"] in ~w(change same invalid secret_skipped)))

    assert Enum.any?(rows, fn row ->
             row["status"] == "secret_skipped" and row["message"] == "paste the key after import"
           end)

    refute Enum.any?(rows, &(&1["status"] == "invalid" and &1["scope"] == "global")),
           inspect(Enum.filter(rows, &(&1["status"] == "invalid")))

    ids = for row <- rows, row["status"] == "change", do: row["id"]
    entry = %{state: "done", result: result}

    apply =
      C74S1.command("import.apply", attributes: %{"preview_id" => "p1", "rows" => ids})

    apply_ctx = %{fresh_ctx | task_results: %{{"import.preview", "p1"} => entry}}
    assert {:task, %TaskSpec{cancellable?: false} = spec, _} = Settings.command(apply, apply_ctx)
    assert {:ok, %{"rows" => results, "terminal" => terminal}} = run(spec)

    refute Enum.any?(results, &(&1["status"] in ["rejected", "conflict"])),
           inspect(Enum.filter(results, &(&1["status"] in ["rejected", "conflict"])))

    assert terminal == %{"panel" => "compact"}
    Cache.clear()
    assert global_values(fresh_ctx) == before

    assert Enum.map(Providers.list(), & &1.name) |> Enum.sort() == ["DeepSeek", "Ollama"]
    assert Enum.all?(Providers.list(), &(&1.api_key in [nil, ""]))
    assert [%{name: "github", env: env}] = MCP.list()
    assert env == %{}
    # Without its key the imported search provider waits, off, for a paste.
    assert %{enabled: false} = Search.get("tavily")

    assert Enum.any?(results, fn r ->
             r["message"] == "paste the key after import, then turn it on"
           end)

    # A preview that is gone.
    assert {:error, %{code: :not_found}} = Settings.command(apply, fresh_ctx)
  end

  test "a file carrying a secret is refused with the words", fixture do
    path = Path.join(fixture.dir, "secret.json")

    File.write!(
      path,
      Jason.encode!(%{
        "format" => "swarmcode-settings",
        "version" => 1,
        "providers" => [%{"name" => "DeepSeek", "api_key" => "sk-live-000000000000"}]
      })
    )

    assert {:task, spec, _} =
             Settings.command(
               C74S1.command("import.preview", target: %{"path" => path}),
               ctx(fixture)
             )

    assert {:error,
            "the file contains a secret for providers.DeepSeek.api_key; secrets are pasted, not imported"} =
             run(spec)

    newer = Path.join(fixture.dir, "newer.json")
    File.write!(newer, Jason.encode!(%{"format" => "swarmcode-settings", "version" => 2}))
    assert {:error, "made by a newer SwarmCode (version 2)"} = Transfer.read_document(newer)

    other = Path.join(fixture.dir, "other.json")
    File.write!(other, ~s({"hello": 1}))
    assert {:error, "not a SwarmCode settings file"} = Transfer.read_document(other)
  end

  test "doctor lists its checks and reports a research root that cannot be made", fixture do
    blocker = Path.join(fixture.dir, "a-file")
    File.write!(blocker, "x")
    Application.put_env(:swarm_code_daemon, :research_root, Path.join(blocker, "research"))

    assert {:task, spec, _} = Settings.command(C74S1.command("doctor"), ctx(fixture))
    assert {:ok, %{"rows" => rows}} = run(spec)
    by_id = Map.new(rows, &{&1["id"], &1})

    assert %{"ok" => true} = by_id["database"]
    assert %{"ok" => false, "message" => message} = by_id["research_root"]
    assert message =~ "cannot be made"
    assert %{"ok" => true} = by_id["provider:DeepSeek"]
    assert %{"ok" => true} = by_id["provider:Ollama"]
    assert %{"ok" => true} = by_id["search"]
    assert %{"ok" => true} = by_id["project_file"]
    refute Jason.encode!(rows) =~ C74S1.canary()
    assert Doctor.cache_reads("doctor") == [{"provider.test", :all}]
  end
end
