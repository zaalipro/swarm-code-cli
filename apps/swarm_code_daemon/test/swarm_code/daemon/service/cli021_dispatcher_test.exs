defmodule SwarmCode.Daemon.Service.Cli021DispatcherTest do
  @moduledoc """
  cli021 lane C parity items on the command dispatcher: P1 `/profile`, P2 the
  session's `--approval` reaches a workflow launch, P3 `/resume-run` skips a run
  that already has a continuation or was rewound away.
  """
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.CommandDispatcher, as: Dispatcher
  alias SwarmCode.Domain.{Cache, Conversations, Projects, Providers, Repo}
  alias SwarmCode.Domain.Conversations.Run

  setup_all do
    path =
      Path.join(System.tmp_dir!(), "cli021-disp-" <> Base.encode16(:crypto.strong_rand_bytes(8)))

    File.mkdir_p!(Path.join(path, "project"))
    prior = Application.get_env(:swarm_code_daemon, :domain_config_dir)
    Application.put_env(:swarm_code_daemon, :domain_config_dir, Path.join(path, "config"))

    on_exit(fn ->
      Cache.clear()

      if prior,
        do: Application.put_env(:swarm_code_daemon, :domain_config_dir, prior),
        else: Application.delete_env(:swarm_code_daemon, :domain_config_dir)

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
    {:ok, project} = Projects.create(%{name: "Profiles", root_path: Path.join(path, "project")})
    %{project: project, path: path}
  end

  setup c do
    Cache.clear()
    {:ok, conversation} = Conversations.create(c.project.id)
    File.rm_rf!(Path.join(c.project.root_path, ".swarm_code"))
    %{conversation: conversation}
  end

  defp config!(c, profiles) do
    dir = Path.join(c.project.root_path, ".swarm_code")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "config.json"), Jason.encode!(%{"profiles" => profiles}))
  end

  defp provider!(name, models) do
    {:ok, provider} =
      Providers.create(%{
        name: "#{name}-#{System.unique_integer([:positive])}",
        kind: "openai_compatible",
        base_url: "http://127.0.0.1:1/v1",
        api_key: "",
        models: models,
        default_model: hd(models)
      })

    Cache.clear()
    provider
  end

  describe "P1 /profile" do
    test "with no profiles it says where to add them", %{conversation: conv} do
      assert {:ok, %{type: :profile, text: text}} = Dispatcher.dispatch(conv.id, "/profile")
      assert text == "No profiles defined — add them to .swarm_code/config.json"
      assert {:ok, %{type: :profile, text: ^text}} = Dispatcher.dispatch(conv.id, "/profile fast")
    end

    test "bare it lists the names; an unknown name lists them too", c do
      config!(c, %{"fast" => %{"effort" => "low"}, "deep" => %{"effort" => "max"}})
      conv = c.conversation

      assert {:ok, %{type: :profile, text: "Available profiles: deep, fast"}} =
               Dispatcher.dispatch(conv.id, "/profile")

      assert {:ok, %{type: :profile, text: text}} = Dispatcher.dispatch(conv.id, "/profile nope")
      assert text == ~s(Unknown profile "nope" — available: deep, fast)
      assert Conversations.get!(conv.id).effort == nil
    end

    test "a profile sets the effort, the worker effort and the models", c do
      fast = provider!("fast", ["m-fast", "m-worker"])

      config!(c, %{
        "fast" => %{
          "effort" => "low",
          "swarm_effort" => "medium",
          "model" => "m-fast",
          "swarm_model" => "m-worker"
        }
      })

      assert {:ok, %{type: :profile, text: "Switched to profile: fast"}} =
               Dispatcher.dispatch(c.conversation.id, "/profile fast")

      saved = Conversations.get!(c.conversation.id)

      assert {saved.effort, saved.swarm_effort, saved.chat_model, saved.swarm_model} ==
               {"low", "medium", "m-fast", "m-worker"}

      assert {saved.chat_provider_id, saved.swarm_provider_id} == {fast.id, fast.id}
    end

    test "only the named fields change, and what cannot apply is said", c do
      provider!("known", ["m-known"])
      {:ok, _} = Conversations.update(c.conversation, %{effort: "high", swarm_effort: "high"})

      config!(c, %{
        "odd" => %{"swarm_effort" => "turbo", "model" => "m-nobody-lists", "effort" => "max"},
        "ignored" => %{"model" => 3, "effort" => ""}
      })

      assert {:ok, %{type: :profile, text: text}} =
               Dispatcher.dispatch(c.conversation.id, "/profile odd")

      assert text ==
               "Switched to profile: odd · skipped swarm_effort turbo (not offered), " <>
                 "model m-nobody-lists (no provider lists it)"

      saved = Conversations.get!(c.conversation.id)
      assert {saved.effort, saved.swarm_effort, saved.chat_model} == {"max", "high", nil}

      assert {:ok, %{text: "Switched to profile: ignored"}} =
               Dispatcher.dispatch(c.conversation.id, "/profile ignored")
    end

    test "a name that is not a profile name is refused by the parser", c do
      assert {:error, :invalid_argument} = Dispatcher.dispatch(c.conversation.id, "/profile a/b")
      assert {:error, :invalid_argument} = Dispatcher.dispatch(c.conversation.id, "/profile a b")
    end
  end

  describe "P2 a workflow launch carries the session's approval mode" do
    test "the launch map names it when the session has one, and only then" do
      conv = %{id: "c", project: %{id: "p"}}
      definition = %SwarmCode.Domain.Workflows.Definition{name: "wf"}
      cmd = %{inputs: %{}, input: "x"}

      with_mode =
        Dispatcher.workflow_launch_attrs(conv, definition, cmd, "m-1", approval_mode: "auto")

      assert with_mode.approval_mode == "auto"
      assert with_mode.created_by == "user" and with_mode.launch_message_id == "m-1"

      refute Map.has_key?(
               Dispatcher.workflow_launch_attrs(conv, definition, cmd, "m-1", []),
               :approval_mode
             )
    end
  end

  describe "P3 /resume-run" do
    defp run(id, status, extra \\ %{}),
      do: struct(Run, Map.merge(%{id: id, kind: "chat", status: status}, extra))

    test "the newest run that can still be resumed" do
      runs = [run("c", "done"), run("b", "stopped"), run("a", "failed")]
      assert Dispatcher.resumable_run(runs).id == "b"
      assert Dispatcher.resumable_run([run("x", "done")]) == nil
      assert Dispatcher.resumable_run([run("x", "stopped", %{kind: "workflow"})]) == nil
    end

    test "a run that was already continued is skipped, so are the rewound ones" do
      runs = [
        run("resumed", "done", %{resumed_from_run_id: "b"}),
        run("b", "stopped"),
        run("rewound", "stopped", %{superseded_at: ~U[2026-10-08 10:00:00.000000Z]}),
        run("a", "interrupted")
      ]

      assert Dispatcher.resumable_run(runs).id == "a"
    end

    test "only a continuation that ran, waits, finished or has a root blocks another resume" do
      ids = fn run -> MapSet.to_list(Dispatcher.continued_ids([run])) end
      from_b = %{resumed_from_run_id: "b"}

      # compensated to failed at start, no root node: b may be resumed again
      assert ids.(run("x", "failed", from_b)) == []

      assert ids.(run("x", "failed", Map.put(from_b, :root_node_id, Ecto.UUID.generate()))) == [
               "b"
             ]

      for status <- ["running", "paused", "waiting_user", "done"],
          do: assert(ids.(run("x", status, from_b)) == ["b"])

      assert ids.(run("x", "stopped", %{})) == []
    end

    test "nothing to resume is the desktop's sentence", c do
      assert {:error, :not_resumable} = Dispatcher.dispatch(c.conversation.id, "/resume-run")
    end
  end
end
