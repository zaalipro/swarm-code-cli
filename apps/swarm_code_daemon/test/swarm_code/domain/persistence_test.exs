defmodule SwarmCode.Domain.PersistenceTest do
  use ExUnit.Case, async: false
  alias SwarmCode.Domain.{Conversations, Projects, Repo, Settings, Providers}

  setup_all do
    path = Path.join(System.tmp_dir!(), "swarm-domain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    prior = Application.get_env(:swarm_code_daemon, :domain_config_dir)
    Application.put_env(:swarm_code_daemon, :domain_config_dir, Path.join(path, "config"))

    repo =
      start_supervised!(
        {Repo,
         database: Path.join(path, "domain.db"),
         domain_fixture: true,
         pool_size: 1,
         journal_mode: :wal,
         log: false}
      )

    Ecto.Migrator.run(
      Repo,
      Application.app_dir(:swarm_code_daemon, "priv/domain_repo/migrations"),
      :up,
      all: true,
      log: false
    )

    on_exit(fn ->
      if prior,
        do: Application.put_env(:swarm_code_daemon, :domain_config_dir, prior),
        else: Application.delete_env(:swarm_code_daemon, :domain_config_dir)

      File.rm_rf!(path)
    end)

    %{path: path, repo: repo}
  end

  test "all current migrations admit real projects, provider settings and conversation history",
       c do
    assert Settings.get().id != nil
    project_root = Path.join(c.path, "project")
    File.mkdir_p!(project_root)
    assert {:ok, project} = Projects.create(%{name: "Fixture", root_path: project_root})

    assert {:ok, provider} =
             Providers.create(%{
               name: "fixture",
               kind: "openai_compatible",
               base_url: "http://127.0.0.1:1/v1",
               api_key: "",
               models: ["fixture-model"],
               default_model: "fixture-model"
             })

    assert provider.name == "fixture"
    assert {:ok, conversation} = Conversations.create(project.id)

    assert {:ok, message} =
             Conversations.create_message(%{
               conversation_id: conversation.id,
               role: "user",
               content: "hello"
             })

    assert message.id != nil
    assert Enum.map(Conversations.list_messages(conversation.id), & &1.content) == ["hello"]
  end

  test "ordinary pathname configuration cannot promote the production Repo", c do
    assert {:error, :guarded_database_required} =
             Repo.init(:supervisor, database: Path.join(c.path, "must-not-open.db"))

    refute File.exists?(Path.join(c.path, "must-not-open.db"))
  end
end
