defmodule SwarmCode.Test.C74S1 do
  @moduledoc """
  pass 74 S1: the fixture database for the settings frame (a private SQLite file,
  `pool_size: 3` — §3.12), and the Appendix A rows the values, overview and
  backend tests need. Nothing here touches a real database or the network.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1, on_exit: 1]

  alias SwarmCode.Daemon.Service.Settings.{Command, Context}
  alias SwarmCode.Domain.{Cache, Conversations, Projects, Providers, Repo, Settings}

  @canary "sk-canary-7Q2X-S1-DO-NOT-SHOW"

  @doc "The canary secret (§6)."
  def canary, do: @canary

  @doc "A fresh fixture database for the calling test. Returns `%{dir}`."
  def repo!(prefix \\ "c74-s1") do
    dir = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    config_dir = Path.join(dir, "config")
    File.mkdir_p!(config_dir)
    File.chmod!(dir, 0o700)

    prior = Application.fetch_env(:swarm_code_daemon, :domain_config_dir)
    Application.put_env(:swarm_code_daemon, :domain_config_dir, config_dir)

    on_exit(fn ->
      case prior do
        {:ok, value} -> Application.put_env(:swarm_code_daemon, :domain_config_dir, value)
        :error -> Application.delete_env(:swarm_code_daemon, :domain_config_dir)
      end

      Cache.clear()
      File.rm_rf(dir)
    end)

    # WAL first, with one connection: three connections switching a new file to
    # WAL at once lock each other out at connect.
    db = Path.join(dir, "fixture.db")
    Repo.ensure_database_permissions!(db)
    {:ok, conn} = Exqlite.Sqlite3.open(db)
    :ok = Exqlite.Sqlite3.execute(conn, "PRAGMA journal_mode=WAL")
    :ok = Exqlite.Sqlite3.close(conn)

    start_supervised!(
      {Repo, database: db, domain_fixture: true, pool_size: 3, journal_mode: :wal, log: false}
    )

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
    %{dir: dir, db: db}
  end

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

  @doc "A conversation in `project` with `attrs`."
  def conversation!(project, attrs \\ %{}) do
    {:ok, conversation} = Conversations.create(project.id)
    {:ok, conversation} = Conversations.update(conversation, attrs)
    conversation
  end

  @doc """
  Appendix A (the parts S1's handlers read): ailogic (trusted, auto, five
  always-allowed commands) and notes, DeepSeek (with a key) and Ollama
  (local), the conversation, and the changed global values.
  """
  def appendix_a!(dir) do
    deepseek =
      provider!(%{
        name: "DeepSeek",
        kind: "openai_compatible",
        base_url: "https://api.deepseek.com/v1",
        api_key: "sk-test-deepseek-00000000a1b2",
        models: ["deepseek-v4-pro", "deepseek-v4-flash"],
        default_model: "deepseek-v4-pro"
      })

    ollama =
      provider!(%{
        name: "Ollama",
        kind: "openai_compatible",
        base_url: "http://127.0.0.1:11434/v1",
        models: ["qwen3-coder"],
        default_model: "qwen3-coder"
      })

    ailogic =
      project!(dir, "ailogic", %{
        approval_mode: "auto",
        auto_approve_prefixes: ["mix test", "git status", "rg", "ls", "mix format"]
      })

    {:ok, ailogic} = Projects.trust(ailogic)

    notes = project!(dir, "notes")

    conversation =
      conversation!(ailogic, %{
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
        mode: "light"
      })

    Cache.clear()

    %{
      deepseek: deepseek,
      ollama: ollama,
      ailogic: ailogic,
      notes: notes,
      conversation: conversation
    }
  end

  @doc "A context for the session's project and conversation."
  def context(fixture, fields \\ []) do
    Context.new(
      Keyword.merge(
        [
          project: fixture[:ailogic],
          conversation: fixture[:conversation],
          env: %{},
          request_id: "11111111-1111-4111-8111-111111111111"
        ],
        fields
      )
    )
  end

  @doc "A settings command."
  def command(action, fields \\ []) do
    struct(
      %Command{
        action: action,
        attributes: %{},
        request_id: "22222222-2222-4222-8222-222222222222"
      },
      fields
    )
  end

  @doc "The number of settings rows."
  def settings_rows,
    do: Repo.aggregate(SwarmCode.Domain.Settings.Setting, :count)
end
