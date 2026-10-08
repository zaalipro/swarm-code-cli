defmodule SwarmCode.Daemon.Service.Cli022IntEffortE2ETest do
  @moduledoc """
  cli022 integration: F4 -> F2/F3 end to end. A persisted backend whose
  session has `NCODE_EFFORT=medium` sends the workspace with no stored effort
  but `effort_effective: "medium"`, source `env`; the client decodes it, and
  the status line, the `/effort` argument dropdown (the `default` row is the
  current one, `●`, and names the level and where it comes from) and the
  effort picker (`default · medium`) all show it before any `/effort`. After a
  stored level the level row is current; after `/effort default` (nil) the env
  level is back.
  """
  use ExUnit.Case, async: false

  import SwarmCodeCLI.Cli020EHelpers, only: [put_workspace: 2, screen: 1, screen_text: 1]
  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0, type: 2]

  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Daemon.Service.SessionConfiguration
  alias SwarmCode.Domain.{Cache, Conversations, Projects, Providers, Repo, Settings}
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCode.Domain.Scheduler.Next
  alias SwarmCodeCLI.UI.{FeatureForm, Library, Reducer, SlashPalette}
  alias SwarmCodeCLI.UI.DataSource.DTO

  setup_all do
    path = Path.join(System.tmp_dir!(), "cli022-int-effort-#{System.unique_integer([:positive])}")
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
    {:ok, project} = Projects.create(%{name: "Effort e2e", root_path: root})
    {:ok, current} = Conversations.create(project.id)

    {:ok, provider} =
      Providers.create(%{
        name: "effort-e2e-#{System.unique_integer([:positive])}",
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
        default_swarm_effort: "low",
        default_scheduled_effort: "max"
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

    conversation = Conversations.get!(current.id)

    assert {:ok, _} =
             SessionConfiguration.prepare(
               %{conversation: conversation, project: project},
               %{"NCODE_EFFORT" => "medium", "SWARM_EFFORT" => "medium"}
             )

    %{backend: backend, current: current}
  end

  # The daemon's workspace, decoded the way the client decodes it, put on a
  # ready client state (the fixture's levels: the test model offers none).
  defp client(c) do
    assert {:ok, %{"value" => wire}} = query(c.backend, conversation(c.current.id))
    assert {:ok, %DTO.WorkspaceSnapshot{} = ws} = DTO.WorkspaceSnapshot.decode(wire)

    fields = [
      chat_model: "big-model",
      effort: ws.effort,
      effort_effective: ws.effort_effective,
      effort_source: ws.effort_source,
      swarm_effort: ws.swarm_effort,
      swarm_effort_effective: ws.swarm_effort_effective,
      swarm_effort_source: ws.swarm_effort_source,
      effort_levels: ~w(low medium high),
      swarm_effort_levels: ~w(low medium high)
    ]

    {ws, put_workspace(ready(), fields)}
  end

  defp current(state, command) do
    for %{current?: true} = e <- SlashPalette.entries(type(state, command)), do: {e.value, e.desc}
  end

  defp picker(state, target) do
    {state, []} = Reducer.update(state, {:slash_local, {:effort, target}})
    screen_text(state)
  end

  test "NCODE_EFFORT shows on the status line, the dropdown and the picker before /effort", c do
    {ws, state} = client(c)
    assert {ws.effort, ws.effort_effective, ws.effort_source} == {nil, "medium", :env}

    assert List.last(screen(state)) =~ "big-model · medium"

    assert [{"default", desc}] = current(state, "/effort ")
    assert desc =~ "medium"
    assert desc =~ "NCODE_EFFORT"
    assert SlashPalette.selected(type(state, "/effort ")).value == "default"

    assert picker(state, :chat) =~ ~r/default · medium/

    # The worker slot follows Settings' worker default, not the environment.
    assert [{"default", worker}] = current(state, "/worker_effort ")
    assert worker =~ "low"
    refute worker =~ "NCODE_EFFORT"
  end

  test "a stored level is the current row; /effort default gives the env level back", c do
    {:ok, _} = Conversations.update(Conversations.get!(c.current.id), %{effort: "high"})
    {ws, state} = client(c)
    assert {ws.effort, ws.effort_effective, ws.effort_source} == {"high", "high", :conversation}
    assert [{"high", _}] = current(state, "/effort ")
    assert List.last(screen(state)) =~ "big-model · high"
    refute picker(state, :chat) =~ "default ·"

    {:ok, _} = Conversations.update(Conversations.get!(c.current.id), %{effort: nil})
    {_ws, state} = client(c)
    assert [{"default", desc}] = current(state, "/effort ")
    assert desc =~ "medium"
    assert List.last(screen(state)) =~ "big-model · medium"
  end

  # cli022 F1 (the words X left open): the workspace also sends Settings'
  # scheduled effort and the Mac's zone (`Next.local_zone/0`, the desktop
  # form's `zone()`), so a new scheduled task shows `default · max` and the
  # zone, and still stores a nil effort.
  test "a new scheduled task shows Settings' scheduled effort and the Mac's zone", c do
    {ws, state} = client(c)
    assert ws.scheduled_effort_default == "max"
    assert ws.local_zone == Next.local_zone()

    state = put_workspace(state, scheduled_effort_default: "max", local_zone: ws.local_zone)
    {state, [{:query, request}]} = Reducer.update(state, {:open_layer, {:library, :schedules}})

    {state, []} =
      Library.response(state, request, %DTO.LibrarySnapshot{
        feature: :schedules,
        request_id: request.request_id,
        items: []
      })

    {state, []} = Reducer.update(state, {:open_layer, {:feature_form, :schedules, "new"}})
    text = screen_text(state)
    assert text =~ "default · max"
    assert FeatureForm.value(state, "effort") == "default"
    assert FeatureForm.value(state, "timezone") == ws.local_zone
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
