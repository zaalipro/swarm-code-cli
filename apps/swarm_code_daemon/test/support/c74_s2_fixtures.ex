defmodule SwarmCode.Test.C74S2 do
  @moduledoc """
  pass 74 S2: the fixture database for the settings handlers (a private SQLite
  file, `pool_size: 3` — §3.12), the isolated global directory, and the
  Appendix A data. Nothing here touches a real database, a real global
  directory or the network.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1, on_exit: 1]

  alias SwarmCode.Daemon.Service.Settings.{Command, Context}
  alias SwarmCode.Domain.{Cache, Conversations, MCP, Projects, Providers, Repo, Settings}
  alias SwarmCode.Domain.MCP.Server
  alias SwarmCode.Domain.Search.SearchProvider

  @canary "sk-canary-7Q2X-DO-NOT-SHOW"

  @doc "The spec's canary secret (§6)."
  def canary, do: @canary

  @doc """
  A fresh fixture database and global directory for the calling test (or
  module, from `setup_all`). Returns `%{dir, config_dir, user_agents_dir}`.
  """
  def repo!(prefix \\ "c74-s2") do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    config_dir = Path.join(dir, "config")
    user_agents = Path.join([dir, "home", ".swarm_code", "agents"])
    File.mkdir_p!(config_dir)
    File.chmod!(dir, 0o700)

    prior = Application.fetch_env(:swarm_code_daemon, :domain_config_dir)
    prior_agents = Application.fetch_env(:swarm_code_daemon, :settings_user_agents_dir)
    Application.put_env(:swarm_code_daemon, :domain_config_dir, config_dir)
    Application.put_env(:swarm_code_daemon, :settings_user_agents_dir, user_agents)

    on_exit(fn ->
      restore(:domain_config_dir, prior)
      restore(:settings_user_agents_dir, prior_agents)
      Cache.clear()
      File.rm_rf(dir)
    end)

    # WAL first, with one connection: three connections switching a new file
    # to WAL at once lock each other out at connect.
    db = Path.join(dir, "fixture.db")
    SwarmCode.Domain.Repo.ensure_database_permissions!(db)
    {:ok, conn} = Exqlite.Sqlite3.open(db)
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
    :ok = Exqlite.Sqlite3.close(conn)

    start_supervised!(
      {Repo, database: db, domain_fixture: true, pool_size: 3, journal_mode: :wal, log: false}
    )

    # The migrations are loaded once per test; the second load is not news.
    ignore = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      Ecto.Migrator.run(
        Repo,
        Application.app_dir(:swarm_code_daemon, "priv/domain_repo/migrations"),
        :up,
        all: true,
        log: false
      )
    after
      Code.put_compiler_option(:ignore_module_conflict, ignore)
    end

    Cache.clear()
    %{dir: dir, config_dir: config_dir, user_agents_dir: user_agents}
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:swarm_code_daemon, key, value)
  defp restore(key, :error), do: Application.delete_env(:swarm_code_daemon, key)

  @doc "A project with a real root under `dir`."
  def project!(dir, name, attrs \\ %{}) do
    root = Path.join(dir, name)
    File.mkdir_p!(root)
    {:ok, project} = Projects.create(%{name: name, root_path: root})
    {:ok, project} = Projects.update(project, attrs)
    project
  end

  @doc "A provider row."
  def provider!(attrs) do
    {:ok, provider} = Providers.create(attrs)
    provider
  end

  @doc "An MCP row written without starting its client."
  def mcp_server!(attrs) do
    {:ok, server} = %Server{} |> Server.changeset(attrs) |> Repo.insert()
    server
  end

  @doc "Tool maps as an MCP server lists them."
  def tools(prefix, n) do
    for i <- 1..n do
      %{
        "name" => "#{prefix}_#{String.pad_leading(Integer.to_string(i), 2, "0")}",
        "description" => "Tool #{i} of #{prefix}",
        "annotations" => %{"readOnlyHint" => rem(i, 2) == 0}
      }
    end
  end

  @doc """
  Appendix A: two projects, one conversation, four providers, the changed
  global values and pricing rows, two search rows, three MCP servers (with
  status and tools, no client), and the files.
  """
  def appendix_a!(fx) do
    ailogic =
      project!(fx.dir, "ailogic", %{
        auto_approve_prefixes: ["mix test", "git status", "rg", "ls", "mix format"]
      })

    {:ok, ailogic} = Projects.trust(ailogic)
    {:ok, ailogic} = Projects.update(ailogic, %{approval_mode: "auto"})
    notes = project!(fx.dir, "notes")

    deepseek =
      provider!(%{
        name: "DeepSeek",
        kind: "openai_compatible",
        base_url: "https://api.deepseek.com/v1",
        api_key: "sk-test-deepseek-00000000a1b2",
        models: ["deepseek-v4-pro", "deepseek-v4-flash"],
        default_model: "deepseek-v4-pro"
      })

    anthropic =
      provider!(%{
        name: "Anthropic",
        kind: "anthropic",
        base_url: "https://api.anthropic.com",
        api_key: "sk-ant-test-000000000000c3d4",
        models: ["claude-sonnet-5", "claude-opus-5"],
        default_model: "claude-sonnet-5"
      })

    ollama =
      provider!(%{
        name: "Ollama",
        kind: "openai_compatible",
        base_url: "http://127.0.0.1:11434/v1",
        models: ["qwen3-coder"],
        default_model: "qwen3-coder"
      })

    openrouter =
      provider!(%{
        name: "OpenRouter",
        kind: "openai_compatible",
        base_url: "https://openrouter.ai/api/v1"
      })

    {:ok, conversation} = Conversations.create(ailogic.id)

    {:ok, conversation} =
      Conversations.update(conversation, %{
        title: "Refactor the parser",
        effort: "high",
        chat_provider_id: deepseek.id,
        chat_model: "deepseek-v4-pro"
      })

    {:ok, _} =
      Settings.update(%{
        default_chat_provider_id: deepseek.id,
        default_chat_model: "deepseek-v4-pro",
        default_swarm_provider_id: deepseek.id,
        default_swarm_model: "deepseek-v4-flash",
        max_concurrent_agents: 6,
        research_max_live: 12,
        monthly_budget_usd: 50.0,
        mode: "light",
        pricing: %{
          "deepseek-v4-pro" => %{"input" => 0.27, "output" => 1.10},
          "deepseek-v4-flash" => %{"input" => 0.07, "output" => 0.28},
          "claude-opus-5" => %{"input" => 15, "output" => 75}
        }
      })

    search_row!("tavily", %{api_key: "tvly-test-000000000000e5f6", enabled: true, position: 0})
    search_row!("exa", %{api_key: "exa-test-0000000000000g7h8", enabled: true, position: 1})

    github =
      mcp_server!(%{
        name: "github",
        transport: "stdio",
        command: "github-mcp-server",
        args: ["stdio"],
        env: %{
          "GITHUB_PERSONAL_ACCESS_TOKEN" => "ghp_test_0000000000000000i9j0",
          "GITHUB_TOOLSETS" => "repos,issues"
        }
      })

    fs =
      mcp_server!(%{
        name: "fs",
        transport: "stdio",
        command: "mcp-fs",
        args: [ailogic.root_path],
        project_id: ailogic.id,
        disabled_tools: ["fs_01", "fs_02"]
      })

    docs =
      mcp_server!(%{
        name: "docs",
        transport: "http",
        url: "https://mcp.example.test/mcp",
        headers: %{"Authorization" => "Bearer test-token-0000000000k1l2"},
        disabled_tools: ["docs_01"]
      })

    MCP.put_status(github.id, {:error, "command not found: github-mcp-server"})
    MCP.put_tools(fs, tools("fs", 12))
    MCP.put_status(fs.id, :ready)
    MCP.put_tools(docs, tools("docs", 29))
    MCP.put_status(docs.id, :ready)

    files!(fx, ailogic, notes)
    Cache.clear()

    %{
      ailogic: Projects.get(ailogic.id),
      notes: Projects.get(notes.id),
      conversation: Conversations.get(conversation.id),
      deepseek: Providers.get(deepseek.id),
      anthropic: Providers.get(anthropic.id),
      ollama: Providers.get(ollama.id),
      openrouter: Providers.get(openrouter.id),
      github: MCP.get(github.id),
      fs: MCP.get(fs.id),
      docs: MCP.get(docs.id)
    }
  end

  @doc "A search provider row written directly."
  def search_row!(kind, attrs) do
    {:ok, row} =
      (Repo.get_by(SearchProvider, kind: kind) || %SearchProvider{})
      |> SearchProvider.changeset(Map.put(attrs, :kind, kind))
      |> Repo.insert_or_update()

    row
  end

  @config_json ~s({"effort": "high",
   "hooks": {"post_tool_use": [{"matcher": "^edit_file$", "command": "mix format", "timeout_ms": 10000}],
             "post_edit": [{"matcher": "*.ex", "command": "mix format"}]},
   "profiles": {"fast": {"mode": "auto", "effort": "low"}},
   "x-custom": true}
  )

  @doc "Appendix A's project config file text."
  def config_json, do: @config_json

  defp files!(fx, ailogic, notes) do
    swarm = Path.join(ailogic.root_path, ".swarm_code")
    File.mkdir_p!(swarm)
    File.write!(Path.join(swarm, "MEMORY.md"), lines("- [2026-09-01] fact", 42))
    File.write!(Path.join(ailogic.root_path, "AGENTS.md"), lines("instruction", 120))
    File.write!(Path.join(notes.root_path, "CLAUDE.md"), "# notes\n")
    File.write!(Path.join(swarm, "config.json"), @config_json)

    File.mkdir_p!(Path.join(fx.config_dir, "commands"))

    File.write!(
      Path.join([fx.config_dir, "commands", "review.md"]),
      "---\ndescription: Review the diff\n---\nReview $ARGUMENTS\n"
    )

    File.mkdir_p!(Path.join(swarm, "commands"))

    File.write!(
      Path.join([swarm, "commands", "deploy.md"]),
      "---\ndescription: Deploy it\nswarm: true\nmode: plan\n---\nDeploy\n"
    )

    File.mkdir_p!(fx.user_agents_dir)

    File.write!(
      Path.join(fx.user_agents_dir, "scout.md"),
      "---\nname: scout\ndescription: My scout\ntools: read_file,grep\n---\nLook around.\n"
    )

    File.mkdir_p!(Path.join(swarm, "agents"))

    File.write!(
      Path.join([swarm, "agents", "reviewer.md"]),
      "---\nname: reviewer\ndescription: Project reviewer\neffort: high\n---\nReview hard.\n"
    )

    File.mkdir_p!(Path.join([swarm, "skills", "html-report"]))

    File.write!(
      Path.join([swarm, "skills", "html-report", "SKILL.md"]),
      "# html-report\n\nWrites an HTML report.\n"
    )

    File.mkdir_p!(Path.join(fx.config_dir, "workflows"))

    File.write!(
      Path.join([fx.config_dir, "workflows", "nightly.exs"]),
      SwarmCode.Domain.Workflows.template("nightly")
    )

    File.mkdir_p!(Path.join(swarm, "workflows"))

    File.write!(
      Path.join([swarm, "workflows", "broken.exs"]),
      String.replace(
        SwarmCode.Domain.Workflows.template("broken"),
        ~s{phase("Plan")},
        ~s{_t = System.os_time()\nphase("Plan")},
        global: false
      )
    )
  end

  defp lines(text, n), do: Enum.map_join(1..n, "", fn i -> "#{text} #{i}\n" end)

  @doc "A settings context for `project` and `conversation`."
  def context(project, conversation \\ nil, opts \\ []) do
    struct(
      Context,
      Keyword.merge(
        [
          project: project,
          conversation: conversation,
          now: DateTime.utc_now(),
          task_results: %{},
          env: %{}
        ],
        opts
      )
    )
  end

  @doc "A settings command."
  def command(action, opts \\ []) do
    struct(
      Command,
      Keyword.merge(
        [action: action, target: %{}, attributes: %{}, expected: nil, secrets: []],
        opts
      )
    )
  end

  @doc "A task-cache entry as the backend copies it into `ctx.task_results`."
  def task_entry(task_id, state, result, opts \\ []) do
    %{
      task_id: task_id,
      state: state,
      at: Keyword.get(opts, :at, DateTime.utc_now()),
      summary: Keyword.get(opts, :summary, %{}),
      result: result,
      message: Keyword.get(opts, :message)
    }
  end

  @doc "Runs a task spec's `run` in the calling process, collecting progress reports."
  def run_task(spec) do
    me = self()
    spec.run.(fn progress -> send(me, {:progress, progress}) end)
  end
end
