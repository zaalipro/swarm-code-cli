defmodule SwarmCode.Daemon.Service.Cli021IntVitalsE2ETest do
  @moduledoc """
  cli021 integration: C2 -> U1 and C3 -> U2 end to end. A persisted backend
  measures (the synced engine's speed table, the VM's memory) and sends the
  `vitals` delta on its shell watch; the client decodes it (`Delta`, the DTOs),
  its `ReadModel` keeps it, and U's projector draws the side panel's top block
  and the status line from it. The workspace sends the model's window (K1's
  1 M default, synced in K7), and the status line reads `ctx used/1M`.
  """
  use ExUnit.Case, async: false

  import SwarmCodeCLI.Cli020EHelpers, only: [fixture: 2, put_workspace: 2, screen: 1]

  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Projects, Providers, Repo, Settings}
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCodeCLI.UI.ReadModel
  alias SwarmCodeCLI.UI.DataSource.{Delta, DTO}

  setup_all do
    path = Path.join(System.tmp_dir!(), "cli021-int-vitals-#{System.unique_integer([:positive])}")
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
    root = Path.join(c.path, "project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create(%{name: "Vitals", root_path: root})
    {:ok, conv} = Conversations.create(project.id)

    {:ok, provider} =
      Providers.create(%{
        name: "vitals-e2e-#{System.unique_integer([:positive])}",
        kind: "openai_compatible",
        base_url: "http://127.0.0.1:9/v1",
        models: ["big-model"],
        default_model: "big-model"
      })

    {:ok, _} =
      Settings.update(%{
        default_chat_provider_id: provider.id,
        default_chat_model: "big-model",
        pricing: %{}
      })

    Cache.clear()

    backend =
      start_supervised!(
        {Backend,
         mode: :persisted,
         repo: Repo,
         project_root: root,
         project_id: project.id,
         conversation_id: conv.id,
         source_epoch: Ecto.UUID.generate()}
      )

    if :ets.whereis(:swarm_code_speed) == :undefined,
      do: start_supervised!(SwarmCode.Domain.LLM.Speed)

    on_exit(fn -> :ets.delete(:swarm_code_speed, {:conv, conv.id}) end)
    %{backend: backend, conversation: conv}
  end

  test "a measured call reaches the side panel's top block and the compact form", c do
    watch!(c.backend)
    assert {:ok, _first} = await_vitals(c.backend, fn _ -> true end)

    sample = %{
      main: %{tps: 48, ttft_ms: 350, model: "big-model", at: DateTime.utc_now(), live?: false}
    }

    :ets.insert(:swarm_code_speed, {{:conv, c.conversation.id}, sample})

    SwarmCode.Domain.PubSub.broadcast(
      SwarmCode.Domain.PubSub,
      "speed",
      {:speed_sample, c.conversation.id, sample}
    )

    assert {:ok, delta} =
             await_vitals(c.backend, fn %Delta{body: v} ->
               Enum.any?(v.models, &(&1.tps == 48))
             end)

    # The client's read model keeps it, beside a workspace of that conversation.
    swarm = fixture(:swarm, {160, 48}) |> Map.put(:panel_mode, :full) |> shown(c)
    swarm = keep(swarm, delta)
    assert %DTO.Vitals{} = swarm.read_model.vitals

    rows = screen(swarm)
    top = Enum.find_index(rows, &(&1 =~ ~r/speed\s+tok\/s/))
    assert is_integer(top), Enum.join(rows, "\n")
    block = Enum.slice(rows, top, 6) |> Enum.join("\n")
    assert block =~ ~r/big-model.*\b48\b/
    assert block =~ ~r/RAM .* MB/

    # Panel hidden: the busiest model's tok/s and RAM move to the status line.
    chat = fixture(:chat, {160, 30}) |> Map.put(:panel_mode, :auto) |> shown(c) |> keep(delta)
    assert List.last(screen(chat)) =~ ~r/48 tok\/s · RAM \d+ MB/
  end

  test "the workspace's window is the 1 M default, drawn as used/window", c do
    {:ok, %{"value" => snapshot}} =
      request(c.backend, conversation(c.conversation.id), %ServiceRequest{
        operation: :query,
        timeout_ms: 5000,
        params: %{
          "slot" => "workspace",
          "cursor" => nil,
          "direction" => "before",
          "page_size" => 50,
          "byte_limit" => 1_048_576
        }
      })

    assert {:ok, %DTO.WorkspaceSnapshot{context_window: 1_000_000} = ws} =
             DTO.WorkspaceSnapshot.decode(snapshot)

    line =
      fixture(:chat, {160, 30})
      |> put_workspace(context_window: ws.context_window, context_used: 8_000)
      |> screen()
      |> List.last()

    assert line =~ ~r/ctx \S+ 8k\/1M/
  end

  defp shown(state, c), do: put_workspace(state, conversation_id: c.conversation.id)

  defp keep(state, %Delta{} = delta) do
    {:ok, model, _, _} = ReadModel.delta(state.read_model, :shell, delta)
    %{state | read_model: model}
  end

  defp watch!(backend) do
    request = %ServiceRequest{
      operation: :watch,
      timeout_ms: 1000,
      params: %{
        "watch_ref" => "shell",
        "slot" => "shell",
        "page_size" => 20,
        "byte_limit" => 262_144
      }
    }

    assert {:watch, 0, _, _, _} =
             GenServer.call(backend, {:service_watch, self(), "watch-shell", global(), request})

    send(backend, {:service_ready, self(), "shell"})
  end

  defp await_vitals(backend, done?) do
    receive do
      {:service_delta, ^backend, "shell", %{"kind" => "vitals"} = wire} ->
        send(backend, {:service_credit, self(), "shell", wire["sequence"]})
        {:ok, %Delta{body: %DTO.Vitals{}} = delta} = Delta.decode(wire)
        if done?.(delta), do: {:ok, delta}, else: await_vitals(backend, done?)

      {:service_delta, ^backend, "shell", wire} ->
        send(backend, {:service_credit, self(), "shell", wire["sequence"]})
        await_vitals(backend, done?)
    after
      6_000 -> :timeout
    end
  end

  defp global, do: %Scope{kind: :global, id: nil, generation: 0}
  defp conversation(id), do: %Scope{kind: :conversation, id: id, generation: 1}

  defp request(backend, scope, request),
    do:
      GenServer.call(
        backend,
        {:service_request, "q-#{System.unique_integer([:positive])}", scope, request},
        10_000
      )
end
