defmodule SwarmCode.Domain.FeatureCatalogTest do
  use ExUnit.Case, async: false
  alias SwarmCode.Domain.{Conversations, FeatureCatalog, Projects, Repo, Research, Settings}
  alias SwarmCode.Protocol.Scope

  setup_all do
    path = Path.join(System.tmp_dir!(), "swarm-features-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    prior = Application.get_env(:swarm_code_daemon, :domain_config_dir)
    Application.put_env(:swarm_code_daemon, :domain_config_dir, Path.join(path, "config"))

    start_supervised!(
      {Repo,
       database: Path.join(path, "fixture.db"), domain_fixture: true, pool_size: 1, log: false}
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

    %{path: path}
  end

  setup %{path: path} do
    root = Path.join(path, "project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create(%{name: "Feature test", root_path: root})
    {:ok, conversation} = Conversations.create(project.id)

    %{
      project: project,
      conversation: conversation,
      scope: %Scope{kind: :conversation, id: conversation.id, generation: 0}
    }
  end

  test "invalid scopes, IDs and limits do not reach database APIs" do
    assert {:error, :invalid_options} =
             FeatureCatalog.query(:schedules, %Scope{kind: :global, id: nil, generation: 0},
               limit: 0
             )

    assert {:error, :invalid_id} =
             FeatureCatalog.query(:schedules, %Scope{kind: :project, id: "bad", generation: 0})

    assert {:error, :invalid_id} = FeatureCatalog.schedule_detail("not-a-uuid")

    assert {:error, :invalid_options} =
             FeatureCatalog.save_schedule(%{"last_run_at" => "2020-01-01"})

    assert {:error, :invalid_options} =
             FeatureCatalog.update_settings(%{"tavily_api_key" => "secret"})
  end

  test "settings mutations use persisted validations and hide credentials" do
    {:ok, _} = Settings.update(%{tavily_api_key: "SECRET-CATALOG-FIXTURE"})
    assert {:ok, _} = FeatureCatalog.update_settings(%{"max_concurrent_agents" => 7})
    assert Settings.get().max_concurrent_agents == 7
    assert {:error, _} = FeatureCatalog.update_settings(%{"max_concurrent_agents" => -2})

    assert {:ok, page} =
             FeatureCatalog.query(:settings, %Scope{kind: :global, id: nil, generation: 0})

    assert is_binary(hd(page.items).detail)
    refute inspect(page) =~ "SECRET-CATALOG-FIXTURE"
    assert {:ok, settings} = FeatureCatalog.settings()
    refute Map.has_key?(settings, :tavily_api_key)
  end

  test "schedule CRUD is persisted, scoped and paginated", c do
    attrs = %{
      "name" => "Catalog task",
      "prompt" => "Review changes",
      "project_id" => c.project.id,
      "timezone" => "Etc/UTC",
      "schedule_kind" => "daily",
      "time_of_day" => "09:00"
    }

    assert {:ok, task} = FeatureCatalog.save_schedule(attrs)

    assert {:ok, changed} =
             FeatureCatalog.save_schedule(
               Map.merge(attrs, %{"id" => task.id, "name" => "Updated"})
             )

    assert changed.id == task.id
    assert changed.name == "Updated"
    assert {:ok, page} = FeatureCatalog.query(:schedules, c.scope, limit: 1)
    assert [%{id: id, title: "Updated", detail: detail}] = page.items
    assert id == task.id
    assert is_binary(detail)
    assert page.next_cursor == nil
    assert {:ok, _} = FeatureCatalog.toggle_schedule(task.id)
    assert {:ok, %{enabled: false}} = FeatureCatalog.schedule_detail(task.id)
    assert {:ok, _} = FeatureCatalog.delete_schedule(task.id)
    assert {:error, :not_found} = FeatureCatalog.schedule_detail(task.id)
  end

  test "workflow catalog resolves project definitions and filters details", c do
    dir = Path.join([c.project.root_path, ".swarm_code", "workflows"])
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "catalog-test.exs"),
      "meta = %{name: \"catalog-test\", description: \"Fixture definition\"}\n:ok\n"
    )

    assert {:ok, page} = FeatureCatalog.query(:workflows, c.scope, id: "catalog-test")
    assert [%{id: "catalog-test", title: "catalog-test", detail: detail}] = page.items
    assert detail =~ "Fixture definition"

    assert {:error, :not_found} =
             FeatureCatalog.query(:workflows, c.scope, id: "unknown-definition")
  end

  test "Git and checkpoint reads derive project from scope", c do
    System.cmd("git", ["init", "--quiet", c.project.root_path])
    File.write!(Path.join(c.project.root_path, "new.txt"), "hello")
    project = %Scope{kind: :project, id: c.project.id, generation: 0}
    assert {:ok, page} = FeatureCatalog.query(:changes, project)
    assert Enum.any?(page.items, &(&1.title == "new.txt"))
    # pass70 C8: a conversation's Changes are what its runs changed, not the
    # working tree.
    assert {:ok, %{items: []}} = FeatureCatalog.query(:changes, c.scope)
    assert {:ok, %{items: []}} = FeatureCatalog.query(:checkpoints, c.scope)
  end

  test "pages exclude another project and advance without duplicates", c do
    root = Path.join(c.path, "other-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, other} = Projects.create(%{name: "Other", root_path: root})

    for {name, project} <- [
          {"Visible A", c.project},
          {"Visible B", c.project},
          {"Private task", other}
        ] do
      assert {:ok, _} =
               FeatureCatalog.save_schedule(%{
                 name: name,
                 prompt: "review",
                 project_id: project.id,
                 timezone: "Etc/UTC"
               })
    end

    assert {:ok, first} = FeatureCatalog.query(:schedules, c.scope, limit: 1)
    assert is_binary(first.next_cursor)

    assert {:ok, second} =
             FeatureCatalog.query(:schedules, c.scope, limit: 1, cursor: first.next_cursor)

    assert first.items != second.items
    assert second.next_cursor == nil
    refute inspect(first) <> inspect(second) =~ "Private task"
    assert {:error, :not_found} = FeatureCatalog.query(:schedules, c.scope, id: "not-a-row")
  end

  test "checkpoint detail excludes file contents and restore uses ownership", c do
    target = Path.join(c.project.root_path, "checkpoint.txt")
    File.write!(target, "PRIVATE-CHECKPOINT-CONTENT")

    assert :ok =
             SwarmCode.Domain.Checkpoints.snapshot(%{conversation_id: c.conversation.id}, target)

    File.write!(target, "changed")
    assert {:ok, %{items: [item]}} = FeatureCatalog.query(:checkpoints, c.scope)
    refute item.detail =~ "PRIVATE-CHECKPOINT-CONTENT"
    assert {:ok, %{path: ^target}} = FeatureCatalog.restore_checkpoint(c.conversation.id, item.id)
    assert File.read!(target) == "PRIVATE-CHECKPOINT-CONTENT"
  end

  test "workflow launch executes the real supervisor and persists completion", c do
    dir = Path.join([c.project.root_path, ".swarm_code", "workflows"])
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "catalog-run.exs"),
      "meta = %{name: \"catalog-run\", description: \"No-model workflow\"}\ncomplete(\"catalog-finished\")\n"
    )

    assert {:ok, wf} =
             FeatureCatalog.start_workflow(%{
               conversation_id: c.conversation.id,
               name: "catalog-run"
             })

    assert eventually(fn -> Conversations.get_run(wf.run_id).status == "done" end)
    assert SwarmCode.Domain.Workflows.get_run(wf.run_id).result =~ "catalog-finished"
    assert {:ok, %{items: [_]}} = FeatureCatalog.query(:workflows, c.scope, id: wf.run_id)
  end

  test "research and schedule scopes cannot widen to unrelated global data", c do
    assert {:ok, task} =
             FeatureCatalog.save_schedule(%{
               name: "Scoped task",
               prompt: "review",
               project_id: c.project.id,
               timezone: "Etc/UTC"
             })

    assert {:error, :invalid_scope} =
             FeatureCatalog.query(:settings, %Scope{kind: :schedule, id: task.id, generation: 0})
  end

  test "research detail exposes bounded result, report and source metadata", c do
    assert {:ok, row} =
             Research.create(%{
               "question" => "Catalog research",
               "level" => "low",
               "project_id" => c.project.id
             })

    File.write!(Research.result_path(row), String.duplicate("result ", 6_000))
    File.write!(Research.report_path(row), "<html><body>designed report</body></html>")

    assert {:ok, _} =
             Research.update(row, %{
               sources: [%{"title" => "Source", "url" => "https://example.test"}]
             })

    assert {:ok, %{items: [item]}} =
             FeatureCatalog.query(:research, c.scope, id: to_string(row.id))

    assert item.detail =~ "designed report"
    assert item.detail =~ "Source"
    assert byte_size(item.detail) <= 16_000
  end

  test "memory library exposes global and project files with edit forms", c do
    assert {:ok, page} = FeatureCatalog.query(:memory, c.scope)
    assert Enum.map(page.items, & &1.id) == ["global", c.project.id]
    assert Enum.all?(page.items, &match?(%{form: %{}}, &1))
    assert Enum.find(page.items, &(&1.id == c.project.id)).status == "empty"

    assert :ok = SwarmCode.Domain.Memory.write(:project, c.project.root_path, "project fact")
    assert {:ok, %{items: items}} = FeatureCatalog.query(:memory, c.scope, id: c.project.id)
    assert hd(items).detail =~ "project fact"
  end

  defp eventually(check, attempts \\ 100)
  defp eventually(check, 0), do: check.()

  defp eventually(check, attempts) do
    if check.() do
      true
    else
      Process.sleep(20)
      eventually(check, attempts - 1)
    end
  end
end
