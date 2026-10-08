defmodule SwarmCode.Daemon.Service.Cli022EffectiveEffortTest do
  @moduledoc """
  cli022 F4: the workspace sends the effort each slot really uses and where it
  came from. Before, it sent the conversation's raw column (`effort`, nil until
  `/effort`), so the status line and the dropdown showed nothing while the turn
  ran at Settings' default; and `NCODE_EFFORT` was read only on a first run.
  The chain is the conversation's value, else the session's `NCODE_EFFORT`
  (chat slot only), else Settings' default, else `"medium"`.
  """
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Daemon.Service.SessionConfiguration
  alias SwarmCode.Domain.{Cache, Conversations, Projects, Providers, Repo, Settings}
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCodeCLI.UI.DataSource.DTO

  setup_all do
    path = Path.join(System.tmp_dir!(), "cli022-effort-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
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
       database: Path.join(path, "fixture.db"),
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

    %{path: path}
  end

  setup c do
    Cache.clear()
    SessionConfiguration.clear_override()
    SessionConfiguration.clear_env_effort()

    on_exit(fn ->
      SessionConfiguration.clear_override()
      SessionConfiguration.clear_env_effort()
    end)

    root = Path.join(c.path, "project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create(%{name: "Effort", root_path: root})
    {:ok, current} = Conversations.create(project.id)

    {:ok, provider} =
      Providers.create(%{
        name: "effort-#{System.unique_integer([:positive])}",
        kind: "openai_compatible",
        base_url: "http://127.0.0.1:9/v1",
        models: ["big-model"],
        default_model: "big-model"
      })

    {:ok, _} =
      Settings.update(%{
        default_chat_provider_id: provider.id,
        default_chat_model: "big-model",
        default_effort: "high",
        default_swarm_effort: "low"
      })

    Cache.clear()

    backend =
      start_supervised!(
        {Backend,
         mode: :persisted,
         repo: Repo,
         project_root: root,
         project_id: project.id,
         conversation_id: current.id,
         source_epoch: Ecto.UUID.generate()}
      )

    %{backend: backend, project: project, current: current}
  end

  defp prepare!(c, env) do
    conversation = Conversations.get!(c.current.id)

    assert {:ok, _} =
             SessionConfiguration.prepare(%{conversation: conversation, project: c.project}, env)
  end

  defp snapshot(c) do
    assert {:ok, %{"value" => snapshot}} = query(c.backend, conversation(c.current.id))
    snapshot
  end

  test "without a value of its own each slot sends Settings' default, sourced", c do
    s = snapshot(c)
    assert s["effort"] == nil
    assert s["swarm_effort"] == nil
    assert {s["effort_effective"], s["effort_source"]} == {"high", "default"}
    assert {s["swarm_effort_effective"], s["swarm_effort_source"]} == {"low", "default"}

    assert {:ok, %DTO.WorkspaceSnapshot{} = dto} = DTO.WorkspaceSnapshot.decode(s)
    assert {dto.effort_effective, dto.effort_source} == {"high", :default}
    assert {dto.swarm_effort_effective, dto.swarm_effort_source} == {"low", :default}
  end

  test "NCODE_EFFORT is the chat slot's level until the conversation has its own", c do
    prepare!(c, %{"NCODE_EFFORT" => "medium", "SWARM_EFFORT" => "medium"})

    s = snapshot(c)
    assert s["effort"] == nil
    assert {s["effort_effective"], s["effort_source"]} == {"medium", "env"}
    # The worker slot has its own default and no environment name.
    assert {s["swarm_effort_effective"], s["swarm_effort_source"]} == {"low", "default"}

    # The engine gets the same level: the overlay is what turns start from.
    overlaid = SessionConfiguration.overlay(Conversations.get!(c.current.id))
    assert overlaid.effort == "medium"
    assert SessionConfiguration.env_effort() == %{value: "medium", name: "NCODE_EFFORT"}

    # `/effort xhigh` stores a value: the conversation's own wins.
    {:ok, _} = Conversations.update(Conversations.get!(c.current.id), %{effort: "xhigh"})
    s = snapshot(c)

    assert {s["effort"], s["effort_effective"], s["effort_source"]} ==
             {"xhigh", "xhigh", "conversation"}

    assert SessionConfiguration.overlay(Conversations.get!(c.current.id)).effort == "xhigh"

    # Back to nil (`/effort default`): the environment's level again.
    {:ok, _} = Conversations.update(Conversations.get!(c.current.id), %{effort: nil})
    assert {"medium", "env"} == then(snapshot(c), &{&1["effort_effective"], &1["effort_source"]})
  end

  test "the older SWARM_EFFORT name alone is named as such", c do
    prepare!(c, %{"SWARM_EFFORT" => "low"})
    assert SessionConfiguration.env_effort() == %{value: "low", name: "SWARM_EFFORT"}
    assert {"low", "env"} == then(snapshot(c), &{&1["effort_effective"], &1["effort_source"]})
  end

  test "a malformed or blank value is ignored, never sent", c do
    for value <- ["", "  ", "not a level!", "high\n", String.duplicate("a", 40)] do
      prepare!(c, %{"SWARM_EFFORT" => value})
      assert SessionConfiguration.env_effort() == nil

      assert {"high", "default"} ==
               then(snapshot(c), &{&1["effort_effective"], &1["effort_source"]})
    end
  end

  test "the conversation's stored worker level is sourced to it", c do
    {:ok, _} = Conversations.update(Conversations.get!(c.current.id), %{swarm_effort: "max"})
    s = snapshot(c)

    assert {s["swarm_effort"], s["swarm_effort_effective"], s["swarm_effort_source"]} ==
             {"max", "max", "conversation"}
  end

  defp conversation(id), do: %Scope{kind: :conversation, id: id, generation: 1}

  defp query(backend, scope),
    do:
      GenServer.call(
        backend,
        {:service_request, "query-#{System.unique_integer([:positive])}", scope,
         %ServiceRequest{
           operation: :query,
           timeout_ms: 5000,
           params: %{
             "slot" => "workspace",
             "cursor" => nil,
             "direction" => "before",
             "page_size" => 50,
             "byte_limit" => 1_048_576
           }
         }},
        10_000
      )
end
