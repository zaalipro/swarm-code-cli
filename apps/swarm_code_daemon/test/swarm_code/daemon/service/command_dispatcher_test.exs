defmodule SwarmCode.Daemon.Service.CommandDispatcherTest do
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.CommandDispatcher, as: Dispatcher

  alias SwarmCode.Domain.{
    Cache,
    Conversations,
    Engine,
    Projects,
    Providers,
    Repo,
    Research,
    Workflows
  }

  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  setup_all do
    path =
      Path.join(System.tmp_dir!(), "dispatcher-" <> Base.encode16(:crypto.strong_rand_bytes(12)))

    File.mkdir_p!(Path.join(path, "project"))

    prior =
      for key <- [:domain_config_dir, :research_root, :llm_providers],
          into: %{},
          do: {key, Application.get_env(:swarm_code_daemon, key)}

    Application.put_env(:swarm_code_daemon, :domain_config_dir, Path.join(path, "config"))
    Application.put_env(:swarm_code_daemon, :research_root, Path.join(path, "research"))

    Application.put_env(:swarm_code_daemon, :llm_providers, %{
      "openai_compatible" => SwarmCode.Domain.LLM.OpenAI
    })

    on_exit(fn ->
      Cache.clear()

      Enum.each(prior, fn {key, value} ->
        if value == nil,
          do: Application.delete_env(:swarm_code_daemon, key),
          else: Application.put_env(:swarm_code_daemon, key, value)
      end)

      File.rm_rf!(path)
    end)

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

    Cache.clear()
    {:ok, project} = Projects.create(%{name: "Dispatcher", root_path: Path.join(path, "project")})
    %{project: project, path: path}
  end

  setup c do
    Cache.clear()
    {:ok, conversation} = Conversations.create(c.project.id)
    %{conversation: conversation}
  end

  test "invalid requests and unknown commands do not mutate", %{conversation: c} do
    assert {:error, :invalid_request} = Dispatcher.dispatch(1, "/stop")
    assert {:error, :invalid_request} = Dispatcher.dispatch(c.id, <<255>>)
    assert {:error, :invalid_request} = Dispatcher.dispatch(c.id, "/stop", [{:custom, []} | :bad])
    assert {:error, :conversation_not_found} = Dispatcher.dispatch(Ecto.UUID.generate(), "/stop")
    assert {:error, :unknown_command} = Dispatcher.dispatch(c.id, "/missing")
    assert Conversations.list_messages(c.id) == []
  end

  test "navigation selection and goal reports are explicit bounded values", %{conversation: c} do
    assert {:ok, %{type: :navigate, destination: :workflows}} =
             Dispatcher.dispatch(c.id, "/workflows")

    assert {:ok, %{type: :select, subject: :rewind, options: []}} =
             Dispatcher.dispatch(c.id, "/rewind")

    assert {:ok, %{type: :select, subject: :research}} =
             Dispatcher.dispatch(c.id, "/deep_research")

    assert {:ok, %{type: :select, subject: :goal, goal: nil}} = Dispatcher.dispatch(c.id, "/goal")
    {:ok, goal} = Conversations.add_goal(c, "ship", "chat")
    assert {:ok, %{goal: %{id: id, text: "ship"}}} = Dispatcher.dispatch(c.id, "/goal")
    assert id == goal.id
  end

  test "mode flags are normalized on every pick and effort is persisted", %{conversation: c} do
    assert {:ok, %{mode: :plan}} = Dispatcher.dispatch(c.id, "/plan")
    assert {:ok, %{value: :high}} = Dispatcher.dispatch(c.id, "/effort high")
    assert {:ok, %{value: :max}} = Dispatcher.dispatch(c.id, "/swarm_effort max")
    assert Conversations.get!(c.id).effort == "high"
    assert {:error, :invalid_effort} = Dispatcher.dispatch(c.id, "/effort high", efforts: [:low])
    assert {:ok, %{mode: :ultra}} = Dispatcher.dispatch(c.id, "/ultra on")
    assert %{mode: "build", ultra: true, consensus: false} = Conversations.get!(c.id)
    assert {:ok, %{mode: :build}} = Dispatcher.dispatch(c.id, "/ultra")
    assert {:ok, %{mode: :consensus}} = Dispatcher.dispatch(c.id, "/consensus")
    assert %{consensus: true, ultra: false} = Conversations.get!(c.id)
    assert {:ok, %{mode: :plan}} = Dispatcher.dispatch(c.id, "/plan")
    assert %{consensus: false, mode: "plan"} = Conversations.get!(c.id)
    {:ok, _} = Conversations.update(Conversations.get!(c.id), %{authoring_workflow: true})

    assert {:ok, %{fields: %{authoring_workflow: false}}} =
             Dispatcher.dispatch(c.id, "/create-workflow off")
  end

  test "model switches resolve exact, bare and ambiguous ids and refuse unknown ones", %{
    conversation: c
  } do
    make = fn name, models ->
      {:ok, provider} =
        Providers.create(%{
          name: name,
          kind: "openai_compatible",
          base_url: "http://127.0.0.1:1/v1",
          api_key: "",
          models: models,
          default_model: hd(models)
        })

      on_exit(fn -> Providers.delete(provider) end)
      provider
    end

    alpha = make.("alpha-" <> c.id, ["shared-model", "alpha-only"])
    beta = make.("beta-" <> c.id, ["shared-model", "beta-only"])

    # An exact "<provider_id>|<model>" pair wins outright.
    assert {:ok, %{type: :updated, command: "model", field: :chat_model, value: "beta-only"}} =
             Dispatcher.dispatch(c.id, "/model " <> beta.id <> "|beta-only")

    assert %{chat_provider_id: beta_id, chat_model: "beta-only"} = Conversations.get!(c.id)
    assert beta_id == beta.id

    # A pair naming a model that provider does not list is not an exact match.
    assert {:error, :unknown_model} =
             Dispatcher.dispatch(c.id, "/model " <> beta.id <> "|alpha-only")

    # A bare id only one provider lists goes to that provider.
    assert {:ok, %{field: :swarm_model, value: "alpha-only"}} =
             Dispatcher.dispatch(c.id, "/swarm_model alpha-only")

    assert %{swarm_provider_id: alpha_id, swarm_model: "alpha-only"} = Conversations.get!(c.id)
    assert alpha_id == alpha.id

    # A bare id both list prefers the provider the conversation already uses
    # for that role: beta for chat, alpha for swarm.
    assert {:ok, %{value: "shared-model"}} = Dispatcher.dispatch(c.id, "/model shared-model")
    assert %{chat_provider_id: ^beta_id, chat_model: "shared-model"} = Conversations.get!(c.id)

    assert {:ok, %{value: "shared-model"}} =
             Dispatcher.dispatch(c.id, "/swarm_model shared-model")

    assert %{swarm_provider_id: ^alpha_id, swarm_model: "shared-model"} =
             Conversations.get!(c.id)

    # Nobody lists it: nothing changes.
    assert {:error, :unknown_model} = Dispatcher.dispatch(c.id, "/model nobody-has-this")
    assert {:error, :missing_argument} = Dispatcher.dispatch(c.id, "/model")
    assert %{chat_model: "shared-model", swarm_model: "shared-model"} = Conversations.get!(c.id)
  end

  test "engine errors remain failures while goal and custom mode changes persist", %{
    conversation: c
  } do
    for command <- [
          "/swarm task",
          "/review",
          "/consensus task",
          "/create-workflow task",
          "/workflow build a release flow"
        ] do
      assert {:error, :not_configured} = Dispatcher.dispatch(c.id, command, workflows: [])
    end

    assert {:error, :not_configured} = Dispatcher.dispatch(c.id, "/swarm /goal ship it")
    assert %{mode: "swarm", text: "ship it"} = Conversations.newest_goal(c.id)
    custom = [%{name: "ship", body: "Do $ARGUMENTS", mode: "plan", swarm: false}]
    assert {:error, :not_configured} = Dispatcher.dispatch(c.id, "/ship now", custom: custom)
    assert Conversations.get!(c.id).mode == "plan"
    assert {:error, :not_configured} = Dispatcher.dispatch(c.id, "/compact")
    assert {:error, :nothing_to_stop} = Dispatcher.dispatch(c.id, "/stop")
    assert {:error, :not_resumable} = Dispatcher.dispatch(c.id, "/resume")
  end

  test "research attachment requires an existing finished report", %{conversation: c} do
    assert {:error, :not_found} = Dispatcher.dispatch(c.id, "/deep_research 999999")
    {:ok, row} = Research.create(%{"question" => "fixture research"})
    assert {:error, :not_attachable} = Dispatcher.dispatch(c.id, "/deep_research #{row.id}")
    {:ok, row} = Research.update(row, %{status: "done"})
    File.write!(Research.result_path(row), "report")

    assert {:ok, %{type: :attached, research_id: id, attachment_target: :next_message}} =
             Dispatcher.dispatch(c.id, "/deep_research #{row.id}")

    assert id == row.id
    assert Conversations.list_messages(c.id) == []
  end

  test "project image attachment is staged through the typed slash dispatcher", %{conversation: c} do
    image = Path.join(c.project.root_path, "fixture.png")
    File.write!(image, <<137, "PNG", 13, 10, 26, 10>>)

    assert {:ok, %{type: :attachment_staged, attachment: %{"id" => id}}} =
             Dispatcher.dispatch(c.id, "/attach fixture.png")

    assert {:ok, _path, "image/png"} = SwarmCode.Domain.Attachments.path(id)
  end

  test "workflow controls are scoped and saved sources really appear", %{conversation: c} do
    source = "meta = %{name: \"fixture-flow\", description: \"Fixture\"}\n\"done\""

    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: c.id,
        kind: "workflow",
        status: "running",
        started_at: DateTime.utc_now()
      })

    {:ok, wf} =
      %SwarmCode.Domain.Workflows.Run{}
      |> SwarmCode.Domain.Workflows.Run.changeset(%{
        run_id: run.id,
        conversation_id: c.id,
        definition_name: "fixture-flow",
        display_name: "fixture-flow-test",
        source: source,
        scope: "project",
        budget: 4,
        max_live: 1
      })
      |> Repo.insert()

    assert {:ok, %{control: :pause}} = Dispatcher.dispatch(c.id, "/workflow pause #{wf.run_id}")
    assert Conversations.get_run(run.id).status == "paused"
    {:ok, other} = Conversations.create(c.project_id)
    assert {:error, :not_found} = Dispatcher.dispatch(other.id, "/workflow stop #{wf.run_id}")

    assert {:ok, %{type: :saved, workflow: "copied-flow"}} =
             Dispatcher.dispatch(c.id, "/workflow save #{wf.run_id} as copied-flow")

    assert Workflows.get(c.project, "copied-flow") != nil
    assert {:ok, %{control: :stop}} = Dispatcher.dispatch(c.id, "/workflow stop #{wf.run_id}")
    assert Conversations.get_run(run.id).status == "stopped"
  end

  test "actual loopback provider completes a custom chat run with expanded prompt", %{
    conversation: c
  } do
    server =
      HTTP.start(fn socket, _request, _index ->
        HTTP.stream(socket, [
          HTTP.sse(%{
            "choices" => [
              %{"delta" => %{"content" => "Fixture complete."}, "finish_reason" => "stop"}
            ]
          })
        ])
      end)

    on_exit(fn -> HTTP.stop(server) end)

    {:ok, provider} =
      Providers.create(%{
        name: "fixture-" <> c.id,
        kind: "openai_compatible",
        base_url: server.url <> "/v1",
        api_key: "",
        models: ["fixture"],
        default_model: "fixture"
      })

    {:ok, _} = Conversations.update(c, %{chat_provider_id: provider.id, chat_model: "fixture"})
    custom = [%{name: "ship", body: "Complete $ARGUMENTS", mode: "build", swarm: false}]

    assert {:ok, %{type: :started, command: "ship", run_id: id}} =
             Dispatcher.dispatch(c.id, "/ship now", custom: custom)

    assert Conversations.get_run(id).conversation_id == c.id
    assert_receive {:http_request, _, request}, 10_000
    assert request.body =~ "Complete now"
    assert eventually(fn -> Conversations.get_run(id).status in ["done", "failed"] end)
    assert Conversations.get_run(id).status == "done"
    assert Enum.any?(Conversations.list_messages(c.id), &(&1.content == "Fixture complete."))

    assert {:ok, %{type: :started, command: "review", run_id: review_id}} =
             Dispatcher.dispatch(c.id, "/review")

    assert eventually(fn -> Conversations.get_run(review_id).status in ["done", "failed"] end)
    assert Conversations.get_run(review_id).status == "done"
    Engine.stop_all(c.id)
  end

  test "workflow aliases launch a real persisted workflow with quoted arguments", %{
    conversation: c
  } do
    source =
      "meta = %{name: \"fixture-launch\", description: \"Fixture\", args: %{target: %{type: :string, required: true}}}\n\"finished\""

    {:ok, definition} = Workflows.parse(source, "project")

    assert {:error, :invalid_workflow_arguments} =
             Dispatcher.dispatch(c.id, "/fixture-launch", workflows: [definition])

    assert Conversations.list_messages(c.id) == []

    assert {:ok, %{type: :started, run_id: id}} =
             Dispatcher.dispatch(c.id, "/fixture-launch target=\"lib web\"",
               workflows: [definition]
             )

    assert Workflows.get_run(id).args["target"] == "lib web"
    assert Conversations.get_run(id).conversation_id == c.id
    assert eventually(fn -> Conversations.get_run(id).status in ["done", "failed"] end)
    assert Conversations.get_run(id).status == "done"
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(25)
          eventually(fun, attempts - 1)
        )
  end
end
