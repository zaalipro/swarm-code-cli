defmodule SwarmCodeCLI.Release.C74ConfigCommandTest do
  @moduledoc """
  pass74 S1-14: `swarmcode config` against a fixture database and a temporary
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
        {:error, %{code: :data_lease_held, status: 3, message: "Another swarmcode", action: ""}}
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
    assert out =~ "swarmcode config COMMAND"
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
    assert out =~ "swarmcode config COMMAND"
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
    assert err =~ "swarmcode: limits.max_concurrent_agents:"

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

    assert err =~ "This folder is not a SwarmCode project yet."
    assert {0, _, _} = config(c, ["set", "project.approval_mode", "auto"])
    assert Projects.get(c.project.id).approval_mode == "auto"
  end

  test "a held lease: list still shows the cli keys; a database write says why", c do
    assert {0, out, _} = config(c, ["list"], foundation: c.held)
    assert out =~ "terminal.panel"
    assert out =~ "(unavailable while a session is open)"

    assert {3, _, err} =
             config(c, ["set", "limits.max_concurrent_agents", "7"], foundation: c.held)

    assert err =~ "A swarmcode session is open ("
    assert err =~ "change it there with /settings, or close it first."
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
    {code, _out, _err} = config(c, ["secret", "provider:DeepSeek", "--stdin"], stdin: stdin)
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

  test "export, import and doctor run as headless tasks", c do
    file = Path.join(c.base, "settings.json")
    assert {0, _out, _} = config(c, ["set", "limits.max_concurrent_agents", "6"])
    assert {0, out, _} = config(c, ["export", file])
    assert out =~ "Exported to"
    assert %{"format" => "swarmcode-settings"} = Jason.decode!(File.read!(file))

    assert {0, out, _} = config(c, ["import", file])
    assert out =~ "Nothing was changed; add --apply to import."

    assert {code, out, _} = config(c, ["doctor"])
    assert code in [0, 1]
    assert out =~ "database"
    assert out =~ "cli.json"
  end
end
