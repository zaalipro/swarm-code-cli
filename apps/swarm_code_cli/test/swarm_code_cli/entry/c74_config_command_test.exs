defmodule SwarmCodeCLI.Release.C74ConfigCommandTest do
  @moduledoc """
  pass74 S1-14: `ncode config` against a fixture database and a temporary
  cli.json. The foundation boot is replaced by a function that runs the work
  on the fixture Repo (or refuses as a held lease would).
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias SwarmCode.Domain.{Cache, Conversations, Projects, Providers, Repo}
  alias SwarmCodeCLI.Release.ConfigCommand

  @canary "sk-canary-7Q2X-S1-DO-NOT-SHOW"

  setup do
    base = Path.join(System.tmp_dir!(), "c74-config-#{System.unique_integer([:positive])}")
    root = Path.join(base, "project")
    config = Path.join(base, "config")
    File.mkdir_p!(root)
    File.mkdir_p!(config)
    prior = Application.fetch_env(:swarm_code_daemon, :domain_config_dir)
    Application.put_env(:swarm_code_daemon, :domain_config_dir, config)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:swarm_code_daemon, :domain_config_dir, value)
        :error -> Application.delete_env(:swarm_code_daemon, :domain_config_dir)
      end

      Cache.clear()
      File.rm_rf(base)
    end)

    start_supervised!(
      {Repo,
       database: Path.join(base, "fixture.db"), domain_fixture: true, pool_size: 2, log: false}
    )

    Ecto.Migrator.run(
      Repo,
      Application.app_dir(:swarm_code_daemon, "priv/domain_repo/migrations"),
      :up,
      all: true,
      log: false
    )

    Cache.clear()
    {:ok, real} = SwarmCode.Domain.Tools.Path.real_path(root)
    {:ok, project} = Projects.create(%{name: "ailogic", root_path: real})

    {:ok, _deepseek} =
      Providers.create(%{
        name: "DeepSeek",
        kind: "openai_compatible",
        base_url: "https://api.deepseek.com/v1",
        api_key: "sk-test-deepseek-00000000a1b2",
        models: ["deepseek-v4-pro"],
        default_model: "deepseek-v4-pro"
      })

    %{
      base: base,
      root: real,
      project: project,
      cli: Path.join(config, "cli.json"),
      foundation: fn fun -> {:ok, fun.()} end,
      held: fn _fun ->
        {:error, %{code: :data_lease_held, status: 3, message: "Another ncode", action: ""}}
      end
    }
  end

  defp config(c, args, opts \\ []) do
    opts =
      Keyword.merge(
        [foundation: c.foundation, cli_path: c.cli, cwd: c.root, stdin: :stdio],
        opts
      )

    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(parent, {:code, ConfigCommand.run(args, opts)}) end)
        send(parent, {:stdout, stdout})
      end)

    assert_received {:code, code}
    assert_received {:stdout, stdout}
    refute stdout <> stderr =~ @canary
    refute stdout <> stderr =~ "sk-test-deepseek"
    {code, stdout, stderr}
  end

  test "help, keys and usage errors" do
    c = %{foundation: nil, cli: nil, root: "/"}
    assert {0, out, _} = config(c, ["help"])
    assert out =~ "ncode config COMMAND"
    assert {0, json, _} = config(c, ["keys", "--json"])
    keys = Jason.decode!(json)
    assert Enum.find(keys, &(&1["key"] == "limits.max_concurrent_agents"))["default"] == 4
    assert {2, _, err} = config(c, [])
    assert err =~ "name a command"
    assert {2, _, err} = config(c, ["frobnicate"])
    assert err =~ "unknown config command"
    assert {2, _, err} = config(c, ["get", "--bogus"])
    assert err =~ "unknown option"
    assert {0, out, _} = config(c, ["--help"])
    assert out =~ "ncode config COMMAND"
  end

  # cli74 G1 (QA F-19): `export --help` wrote a file named `help` into the
  # working directory and `import --help` previewed one.
  test "--help and -h after a subcommand print the usage and touch nothing", c do
    for args <- [
          ["export", "--help"],
          ["import", "-h"],
          ["set", "limits.max_concurrent_agents", "--help"]
        ] do
      assert {0, out, _} = config(c, args)
      assert out =~ "ncode config COMMAND"
    end

    refute File.exists?(Path.join(c.root, "help"))
    assert {0, out, _} = config(c, ["get", "limits.max_concurrent_agents"])
    assert out =~ "limits.max_concurrent_agents  4"
  end

  test "a cli.json key is written without the database, even while a session is open", c do
    assert {0, out, _} = config(c, ["set", "terminal.panel", "hidden"], foundation: c.held)
    assert out =~ "terminal.panel = hidden"
    assert Jason.decode!(File.read!(c.cli))["panel"] == "hidden"
    assert File.stat!(c.cli).mode |> Bitwise.band(0o777) == 0o600

    assert {0, out, _} = config(c, ["get", "terminal.panel"], foundation: c.held)
    assert out =~ "terminal.panel  hidden  (cli)"

    assert {4, _, err} =
             config(c, ["set", "terminal.panel", "full", "--expect", "compact"],
               foundation: c.held
             )

    assert err =~ "terminal.panel changed: now hidden."
    assert {0, _, _} = config(c, ["reset", "terminal.panel"], foundation: c.held)
    refute Map.has_key?(Jason.decode!(File.read!(c.cli)), "panel")
  end

  test "database keys: set, get, list, conflict, invalid", c do
    assert {0, out, _} = config(c, ["set", "limits.max_concurrent_agents", "7"])
    assert out =~ "limits.max_concurrent_agents = 7"

    assert {0, out, _} = config(c, ["get", "limits.max_concurrent_agents"])
    assert out =~ ~r/limits\.max_concurrent_agents\s+7\s+\(global\)/

    assert {0, out, _} = config(c, ["list", "--modified", "--json"])
    rows = Jason.decode!(out)

    assert %{"value" => 7, "layer" => "global"} =
             Enum.find(rows, &(&1["key"] == "limits.max_concurrent_agents"))

    assert {0, out, _} = config(c, ["set", "limits.max_concurrent_agents", "7"])
    assert out =~ "is already 7"

    assert {4, _, err} =
             config(c, ["set", "limits.max_concurrent_agents", "9", "--expect", "5"])

    assert err =~ "limits.max_concurrent_agents changed: now 7."

    assert {2, _, err} = config(c, ["set", "limits.max_concurrent_agents", "lots"])
    assert err =~ "ncode: limits.max_concurrent_agents:"

    assert {0, out, _} = config(c, ["set", "models.chat", "DeepSeek/deepseek-v4-pro"])
    assert out =~ "models.chat = DeepSeek/deepseek-v4-pro"
  end

  test "session and project keys need their conversation and project", c do
    assert {2, _, err} = config(c, ["set", "session.effort", "high"])
    assert err =~ "--conversation"

    assert {2, _, err} =
             config(c, ["set", "session.effort", "high", "--conversation", "latest"])

    assert err =~ "No conversation in this project yet."

    {:ok, conversation} = Conversations.create(c.project.id)

    assert {0, _, _} =
             config(c, ["set", "session.effort", "high", "--conversation", "latest"])

    assert Conversations.get(conversation.id).effort == "high"

    elsewhere = Path.join(c.base, "elsewhere")
    File.mkdir_p!(elsewhere)

    assert {2, _, err} =
             config(c, ["set", "project.approval_mode", "auto", "--project", elsewhere])

    assert err =~ "ncode has not opened "
    assert err =~ "Open it once (ncode "
    assert {0, _, _} = config(c, ["set", "project.approval_mode", "auto"])
    assert Projects.get(c.project.id).approval_mode == "auto"
  end

  test "a held lease: list still shows the cli keys; a database write says why", c do
    # cli020 B17 (onboarding-13): the cli keys print, the database ones cannot
    # be read, and the exit code says so.
    assert {3, out, err} = config(c, ["list"], foundation: c.held)
    assert out =~ "terminal.panel"
    refute out =~ "models.chat"

    assert err =~
             "A session is using the database; this value cannot be read now. Close it and run this again."

    assert {3, _, err} =
             config(c, ["set", "limits.max_concurrent_agents", "7"], foundation: c.held)

    assert err =~ "A ncode session is open ("
    assert err =~ "change it there with /settings, or close it first."
  end

  # cli020 B17 (onboarding-12, -13, -14, -20).
  test "get of a database key while a session is open exits 3; cli keys still answer", c do
    assert {3, "", err} = config(c, ["get", "models.chat"], foundation: c.held)
    assert err =~ "A session is using the database; this value cannot be read now."
    assert {0, out, _} = config(c, ["get", "terminal.panel"], foundation: c.held)
    assert out =~ "terminal.panel"
  end

  test "doctor while a session is open runs its own checks and skips the database", c do
    assert {0, out, _} = config(c, ["doctor"], foundation: c.held)
    assert out =~ "database checks skipped: a session is open"
    assert out =~ "cli.json"
  end

  test "doctor: a newer database and an open app are blocking, with a hint", c do
    ahead = SwarmCode.Daemon.Schema.Refusal.database_ahead()

    newer = fn _ ->
      {:error,
       %{code: :schema_incompatible, status: 3, message: ahead.message, action: ahead.action}}
    end

    assert {1, out, _} = config(c, ["doctor"], foundation: newer)
    assert out =~ ahead.message
    assert out =~ "!!"

    app = fn _ -> {:error, %{code: :desktop_active, status: 3, message: "open", action: ""}} end
    assert {1, out, _} = config(c, ["doctor"], foundation: app)
    assert out =~ "the ncode app is open"
    assert out =~ "quit the ncode app"
  end

  test "doctor: search is a note, problems carry a hint, exit 0 without blocking ones", c do
    assert {0, out, _} = config(c, ["doctor"])
    assert out =~ ~r/--\s+search\s+no search engine is on\s+run: ncode settings search/
    assert {0, json, _} = config(c, ["doctor", "--json"])
    rows = Jason.decode!(json)

    assert %{"level" => "note", "hint" => "run: ncode settings search"} =
             Enum.find(rows, &(&1["id"] == "search"))

    assert Enum.all?(rows, &(&1["level"] in ["ok", "note", "problem"]))

    Repo.query!("DELETE FROM providers")
    Cache.clear()
    assert {1, out, _} = config(c, ["doctor"])
    assert out =~ ~r/!!\s+providers\s+no model provider is set up\s+run: ncode settings providers/
  end

  test "set project.trusted for a folder ncode never opened says what to do", c do
    dir = Path.join(c.base, "unknown")
    File.mkdir_p!(dir)

    assert {2, _, err} = config(c, ["set", "project.trusted", "on", "--project", dir])

    assert err =~
             "ncode has not opened #{dir} yet. Open it once (ncode #{dir}), then run this again."
  end

  # cli020 B18 (onboarding-15).
  test "record add provider takes --base-url and --kind; --preset other needs a URL", c do
    assert {0, out, _} =
             config(c, [
               "record",
               "add",
               "provider",
               "--preset",
               "Other",
               "--name",
               "Mine",
               "--base-url",
               "http://127.0.0.1:9/v1",
               "--kind",
               "openai"
             ])

    assert out =~ "Mine"
    mine = Enum.find(Providers.list(), &(&1.name == "Mine"))
    assert mine.base_url == "http://127.0.0.1:9/v1"
    assert mine.kind == "openai_compatible"

    assert {2, _, err} = config(c, ["record", "add", "provider", "--preset", "other"])
    assert err =~ "--preset other needs --base-url URL."

    assert {2, _, err} =
             config(c, ["record", "add", "provider", "--preset", "openai", "--kind", "gemini"])

    assert err =~ "--kind is anthropic or openai."
  end

  test "config help says what keys lists", c do
    assert {0, out, _} = config(c, ["help"])
    assert out =~ ~r/keys \[--json\]\s+every setting key/
  end

  test "secrets never come from argv; a piped one is read from stdin", c do
    assert {2, _, err} = config(c, ["record", "set", "provider:DeepSeek.api_key", @canary])
    assert err =~ "Secrets are read from stdin so they never reach your shell history"

    # a record's secret named as a setting gets the same sentence, not "not a setting" (A13)
    for key <- ["provider.DeepSeek.api_key", "search.tavily.api_key", "mcp:github.env.GH_PAT"] do
      assert {2, _, err} = config(c, ["set", key, @canary])
      assert err =~ "Secrets are read from stdin", key
      refute err =~ "not a setting"
    end

    {:ok, stdin} = StringIO.open(@canary <> "\n")

    {code, _out, _err} =
      config(c, ["secret", "provider:DeepSeek", "--stdin", "--no-test"], stdin: stdin)

    assert code in [0, 1]
  end

  test "headless provisioning (A61): a provider from a preset, its key, the chat model, an MCP toggle",
       c do
    assert {0, _, _} = config(c, ["record", "add", "provider", "--preset", "openrouter"])
    openrouter = Enum.find(Providers.list(), &(&1.name == "OpenRouter"))
    assert openrouter.base_url == "https://openrouter.ai/api/v1"
    assert openrouter.kind == "openai_compatible"
    assert [_ | _] = openrouter.effort_levels

    assert {2, _, err} = config(c, ["record", "add", "provider", "--preset", "nope"])
    assert err =~ "no preset named nope"

    assert {0, _, _} =
             config(c, ["record", "set", "provider:OpenRouter.base_url", "http://127.0.0.1:9/v1"])

    {:ok, stdin} = StringIO.open("sk-or-test-000000000000beef\n")

    assert {0, _, _} =
             config(c, ["secret", "provider:OpenRouter", "--stdin", "--no-test"], stdin: stdin)

    openrouter = Enum.find(Providers.list(), &(&1.name == "OpenRouter"))
    assert openrouter.api_key == "sk-or-test-000000000000beef"
    assert openrouter.base_url == "http://127.0.0.1:9/v1"

    {:ok, _server} =
      SwarmCode.Domain.MCP.create(%{
        name: "github",
        transport: "stdio",
        command: "github-mcp-server",
        enabled: false
      })

    assert {0, _, _} = config(c, ["mcp", "toggle", "github"])
    assert SwarmCode.Domain.MCP.list() |> Enum.find(&(&1.name == "github")) |> Map.get(:enabled)
    assert {0, _, _} = config(c, ["mcp", "toggle", "github"])
    refute SwarmCode.Domain.MCP.list() |> Enum.find(&(&1.name == "github")) |> Map.get(:enabled)
  end

  test "records takes the kind a record is named by as well as its list (records provider)", c do
    # Found in the sandbox (cli74 F26): `records provider` said "not a settings view"
    # while `record get provider:DeepSeek` and the usage line both name the kind.
    assert {0, plural, _} = config(c, ["records", "providers"])
    assert plural =~ "name=DeepSeek"
    assert {0, ^plural, _} = config(c, ["records", "provider"])
    assert {0, _, _} = config(c, ["records", "search_provider"])
    assert {2, _, err} = config(c, ["records", "nope"])
    assert err =~ "not a settings view"
  end

  test "export, import and doctor run as headless tasks", c do
    file = Path.join(c.base, "settings.json")
    assert {0, _out, _} = config(c, ["set", "limits.max_concurrent_agents", "6"])
    assert {0, _out, _} = config(c, ["set", "terminal.theme", "dark"])
    assert {0, out, _} = config(c, ["export", file])
    assert out =~ "Exported to"
    assert %{"format" => "swarmcode-settings"} = Jason.decode!(File.read!(file))

    assert {0, out, _} = config(c, ["import", file])
    assert out =~ "Nothing was changed; add --apply to import."
    # cli74 G1 (QA F-20): the same machine's cli.json value is `same`, not `- -> dark`.
    assert out =~ ~r/same\s+terminal\s+theme\s+dark -> dark/
    refute out =~ ~r/change\s+terminal\s+theme/

    assert {code, out, _} = config(c, ["doctor"])
    assert code in [0, 1]
    assert out =~ "database"
    assert out =~ "cli.json"
  end

  test "human sinks escape fields and paths while JSON and stored values stay semantic", c do
    hostile = "日本語\e]52;c;payload\a\r\nnext"
    provider = Enum.find(Providers.list(), &(&1.name == "DeepSeek"))

    {:ok, _} =
      Providers.update(provider, %{name: hostile, base_url: "https://example.test/" <> hostile})

    for args <- [
          ["records", "provider"],
          ["record", "get", "provider:" <> hostile],
          ["record", "get", "provider:" <> hostile <> ".base_url"],
          ["doctor"],
          ["get", hostile],
          ["record", "delete", "provider:" <> hostile]
        ] do
      {_code, out, err} = config(c, args)
      assert_inert(out <> err)
      refute out <> err =~ "\nnext"
    end

    assert {0, json, ""} = config(c, ["records", "provider", "--json"])
    assert hd(Jason.decode!(json))["fields"]["name"] == hostile
    assert {0, json, ""} = config(c, ["record", "get", "provider:" <> hostile, "--json"])
    assert Jason.decode!(json)["name"] == hostile
    assert Jason.decode!(json)["api_key"] == %{"set" => true, "hint" => "a1b2"}

    file = Path.join(c.base, hostile <> ".json")
    assert {0, out, ""} = config(c, ["export", file, "--include-records"])
    assert_inert(out)
    assert File.exists?(file)
    assert {0, out, ""} = config(c, ["import", file])
    assert_inert(out)
    assert out =~ "\\n"
    assert Providers.get(provider.id).name == hostile

    assert {0, out, ""} = config(c, ["path"], cwd: Path.join(c.root, hostile))
    assert_inert(out)
    assert out =~ "\\n"

    failure = fn _ ->
      {:error,
       %{
         code: :fixture_failure,
         status: 3,
         message: hostile,
         action: hostile,
         reason: :provider_required
       }}
    end

    assert {3, "", err} = config(c, ["get", "models.chat"], foundation: failure)
    assert_inert(err)
    refute err =~ "\nnext"
    assert {1, json, ""} = config(c, ["doctor", "--json"], foundation: failure)
    assert hd(Jason.decode!(json))["message"] == hostile
  end

  test "human oversized fields use the display marker without changing JSON", c do
    text = "https://example.test/" <> String.duplicate("a", 65_537)
    Repo.query!("UPDATE providers SET base_url = ?", [text])
    assert {0, out, ""} = config(c, ["record", "get", "provider:DeepSeek.base_url"])
    assert out =~ "[value exceeds display limit]"
    assert {0, json, ""} = config(c, ["record", "get", "provider:DeepSeek.base_url", "--json"])
    assert Jason.decode!(json) == text
  end

  test "provider model reads and automatic CAS use the complete stored list", c do
    for models <- [[], ["deepseek-v4-pro", "日本語-model"]] do
      provider = Enum.find(Providers.list(), &(&1.name == "DeepSeek"))
      {:ok, _} = Providers.update(provider, %{models: models})
      assert {0, json, ""} = config(c, ["record", "get", "provider:DeepSeek.models", "--json"])
      assert Jason.decode!(json) == models
      assert {0, out, ""} = config(c, ["record", "get", "provider:DeepSeek.models"])
      assert String.trim(out) == Jason.encode!(models)
      assert {0, json, ""} = config(c, ["record", "get", "provider:DeepSeek", "--json"])
      assert Jason.decode!(json)["models"] == models
      assert Jason.decode!(json)["api_key"] == %{"set" => true, "hint" => "a1b2"}

      assert {0, _, ""} = config(c, ["record", "set", "provider:DeepSeek.models", "new-model"])
      assert Providers.get(provider.id).models == ["new-model"]

      assert {4, "", _} =
               config(c, [
                 "record",
                 "set",
                 "provider:DeepSeek.models",
                 "other",
                 "--expect",
                 "stale"
               ])

      assert Providers.get(provider.id).models == ["new-model"]

      assert {0, _, ""} =
               config(c, [
                 "record",
                 "set",
                 "provider:DeepSeek.models",
                 "other",
                 "--expect",
                 "new-model"
               ])

      assert Providers.get(provider.id).models == ["other"]
    end
  end

  test "MCP secret commands set absent slots and replace exact secret and plain entry masks", c do
    {:ok, server} =
      SwarmCode.Domain.MCP.create(%{
        name: "slots",
        transport: "stdio",
        command: "unused-fixture-command",
        enabled: false,
        env: %{"API_TOKEN" => "old-fixture-secret-1234", "PLAIN" => "ordinary"},
        headers: %{"Authorization" => "Bearer old-fixture-secret-5678"}
      })

    for {slot, map, name} <- [
          {"env.NEW_TOKEN", :env, "NEW_TOKEN"},
          {"headers.X-Api-Key", :headers, "X-Api-Key"},
          {"env.API_TOKEN", :env, "API_TOKEN"},
          {"headers.Authorization", :headers, "Authorization"},
          {"env.PLAIN", :env, "PLAIN"}
        ] do
      {:ok, stdin} = StringIO.open(@canary <> "\n")

      assert {0, _, ""} =
               config(c, ["secret", "mcp_server:slots." <> slot, "--stdin"], stdin: stdin)

      assert Map.fetch!(Map.fetch!(SwarmCode.Domain.MCP.get(server.id), map), name) == @canary

      {:ok, stdin} = StringIO.open("replacement-fixture-secret-9abc\n")

      assert {0, _, ""} =
               config(c, ["secret", "mcp_server:slots." <> slot, "--stdin"], stdin: stdin)

      assert Map.fetch!(Map.fetch!(SwarmCode.Domain.MCP.get(server.id), map), name) ==
               "replacement-fixture-secret-9abc"
    end

    assert {0, json, ""} = config(c, ["record", "get", "mcp_server:slots", "--json"])
    fields = Jason.decode!(json)

    assert Enum.find(fields["env"], &(&1["name"] == "API_TOKEN")) ==
             %{"name" => "API_TOKEN", "secret" => true, "value" => nil, "hint" => "9abc"}

    assert {0, _, ""} = config(c, ["record", "get", "mcp_server:slots"])
    {:ok, stdin} = StringIO.open(@canary <> "\n")

    assert {3, "", _} =
             config(c, ["secret", "mcp_server:slots.env.API_TOKEN", "--stdin"],
               stdin: stdin,
               foundation: c.held
             )
  end

  test "provider and search keys use their authoritative api_key masks", c do
    for ref <- ["provider:DeepSeek", "search_provider:tavily"] do
      for value <- [@canary, "replacement-fixture-secret-9abc"] do
        {:ok, stdin} = StringIO.open(value <> "\n")
        assert {0, _, ""} = config(c, ["secret", ref, "--stdin", "--no-test"], stdin: stdin)
        assert {0, json, ""} = config(c, ["record", "get", ref <> ".api_key", "--json"])
        assert Jason.decode!(json) == %{"set" => true, "hint" => String.slice(value, -4, 4)}
      end
    end
  end

  test "a stale MCP mask conflicts without overwriting the intervening secret", c do
    {:ok, server} =
      SwarmCode.Domain.MCP.create(%{
        name: "racing",
        transport: "stdio",
        command: "unused-fixture-command",
        enabled: false,
        env: %{"API_TOKEN" => "old-fixture-secret-1234"}
      })

    handler = {__MODULE__, make_ref()}
    event = Repo.config()[:telemetry_prefix] ++ [:query]
    peer = "peer-fixture-secret-5678"

    :ok =
      :telemetry.attach(
        handler,
        event,
        &__MODULE__.replace_after_read/4,
        {self(), server.id, peer}
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, stdin} = StringIO.open(@canary <> "\n")

    assert {4, "", err} =
             config(c, ["secret", "mcp_server:racing.env.API_TOKEN", "--stdin"], stdin: stdin)

    assert err =~ "changed"
    assert Process.get(:config_mask_replaced)
    :telemetry.detach(handler)
    assert SwarmCode.Domain.MCP.get(server.id).env["API_TOKEN"] == peer
  end

  test "invalid typed record expectations are usage errors before mutation", c do
    cases = [
      {"provider:DeepSeek.models", "replacement", "["},
      {"provider:DeepSeek.models", "replacement", ~s(["ok", 1])},
      {"provider:DeepSeek.fallbacks", "off", "maybe"},
      {"provider:DeepSeek.kind", "anthropic", "gemini"},
      {"provider:DeepSeek.model_effort_levels", "{}", "not-json"},
      {"search_provider:tavily.position", "7", "lots"}
    ]

    results =
      for {ref, value, expect} <- cases do
        assert {0, before, ""} = config(c, ["record", "get", ref, "--json"])
        result = config(c, ["record", "set", ref, value, "--expect", expect])
        assert {0, ^before, ""} = config(c, ["record", "get", ref, "--json"])
        {ref, result}
      end

    for {ref, result} <- results do
      assert {2, "", err} = result

      assert err ==
               "ncode: invalid --expect value for #{ref}. Run 'ncode config help'.\n"
    end

    assert Providers.get(Enum.find(Providers.list(), &(&1.name == "DeepSeek")).id).models ==
             ["deepseek-v4-pro"]

    assert {2, "", _} =
             config(c, ["record", "set", "provider:DeepSeek.models", "new", "--expect", "["],
               foundation: c.held
             )
  end

  test "explicit false, null and JSON list expectations are not automatic expectations", c do
    assert {4, "", _} =
             config(c, ["record", "set", "provider:DeepSeek.fallbacks", "off", "--expect", "off"])

    assert {4, "", _} =
             config(c, [
               "record",
               "set",
               "provider:DeepSeek.default_model",
               "other",
               "--expect",
               "null"
             ])

    assert {0, _, ""} =
             config(c, [
               "record",
               "set",
               "provider:DeepSeek.models",
               "other",
               "--expect",
               ~s(["deepseek-v4-pro"])
             ])

    assert {3, "", _} =
             config(
               c,
               ["record", "set", "provider:DeepSeek.models", "other", "--expect", "other"],
               foundation: c.held
             )

    assert {0, _, ""} = config(c, ["record", "set", "provider:DeepSeek.fallbacks", "off"])

    assert {0, _, ""} =
             config(c, ["record", "set", "provider:DeepSeek.fallbacks", "on", "--expect", "off"])
  end

  test "parsed wrong-shape expectations are refused before foundation admission", c do
    foundation = fn _ ->
      send(self(), :unexpected_foundation)
      c.held.(nil)
    end

    for {ref, value, expectations} <- [
          {"provider:DeepSeek.model_effort_levels", "{}", ["[]", ~s("ordinary"), "true", "7"]},
          {"search_provider:tavily.position", "7", ["1.5"]},
          {"provider:DeepSeek.fallbacks", "off", ["null", "unset", "default"]},
          {"provider:DeepSeek.kind", "anthropic", ["null"]},
          {"provider:DeepSeek.name", "replacement", ["null"]},
          {"provider:DeepSeek.base_url", "https://example.test", ["null", ""]}
        ] do
      assert {0, before, ""} = config(c, ["record", "get", ref, "--json"])

      for expect <- expectations do
        assert {2, "", err} =
                 config(c, ["record", "set", ref, value, "--expect", expect],
                   foundation: foundation
                 )

        assert err ==
                 "ncode: invalid --expect value for #{ref}. Run 'ncode config help'.\n"

        refute_received :unexpected_foundation
        assert {0, ^before, ""} = config(c, ["record", "get", ref, "--json"])
      end
    end
  end

  test "valid expectation shapes retain lease refusal and integer CAS compatibility", c do
    for {ref, value, expectations} <- [
          {"provider:DeepSeek.model_effort_levels", "{}",
           ["{}", ~s({"model": ["high"]}), "null"]},
          {"search_provider:tavily.position", "7", ["7", "7.0", "null", "default"]},
          {"provider:DeepSeek.default_model", "other", ["ordinary", "null", "default"]},
          {"provider:DeepSeek.fallbacks", "off", ["off", "false", "on"]},
          {"provider:DeepSeek.kind", "anthropic", ["anthropic", "openai_compatible"]},
          {"provider:DeepSeek.models", "other", ["", "[]", "one,two", ~s(["one"]), "null"]}
        ],
        expect <- expectations do
      assert {3, "", _} =
               config(c, ["record", "set", ref, value, "--expect", expect], foundation: c.held)
    end

    assert {0, _, ""} = config(c, ["set", "limits.max_concurrent_agents", "7"])

    assert {0, _, ""} =
             config(c, ["set", "limits.max_concurrent_agents", "8", "--expect", "7.0"])

    assert {0, json, ""} = config(c, ["get", "limits.max_concurrent_agents", "--json"])
    assert [%{"key" => "limits.max_concurrent_agents", "value" => 8}] = Jason.decode!(json)

    assert {4, "", _} =
             config(c, ["set", "limits.max_concurrent_agents", "9", "--expect", "7.0"])

    assert {0, ^json, ""} = config(c, ["get", "limits.max_concurrent_agents", "--json"])
  end

  test "invalid scalar expectations leave integer enum and list values unchanged", c do
    for {key, value, expect} <- [
          {"limits.max_concurrent_agents", "7", "lots"},
          {"terminal.panel", "full", "nope"},
          {"terminal.status_items", "model", "not-a-status-item"}
        ] do
      assert {0, before, ""} = config(c, ["get", key, "--json"])
      assert {2, "", _} = config(c, ["set", key, value, "--expect", expect])
      assert {0, ^before, ""} = config(c, ["get", key, "--json"])
    end
  end

  def replace_after_read(_event, _measurements, metadata, {owner, id, peer}) do
    if self() == owner and String.starts_with?(metadata.query, "SELECT") and
         String.contains?(metadata.query, ~s(FROM "mcp_servers")) and
         id in metadata.params and not Process.get(:config_mask_replaced, false) do
      Process.put(:config_mask_replaced, true)

      Repo.query!("UPDATE mcp_servers SET env = ? WHERE id = ?", [
        Jason.encode!(%{"API_TOKEN" => peer}),
        id
      ])
    end
  end

  defp assert_inert(text) do
    for control <- ["\e", "\a", "\r"], do: refute(text =~ control)
  end
end
