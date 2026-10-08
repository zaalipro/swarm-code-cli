defmodule SwarmCode.Daemon.Service.Cli021VitalsBackendTest do
  @moduledoc """
  cli021 C2/C3 through one persisted backend: the shell watch hears a `vitals`
  delta only while it exists, its snapshot carries the same facts, and the
  workspace sends the model's context window (not the 75 % trim budget).
  """
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Projects, Providers, Repo, Settings}
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCodeCLI.UI.DataSource.{Delta, DTO}

  setup_all do
    path =
      Path.join(System.tmp_dir!(), "pass70-conversation-#{System.unique_integer([:positive])}")

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

  # Every test owns its project, so the list holds exactly what it made.
  setup c do
    Cache.clear()
    root = Path.join(c.path, "project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create(%{name: "Conversations", root_path: root})
    {:ok, project} = Projects.update(project, %{approval_mode: "auto"})
    {:ok, current} = Conversations.create(project.id)
    {:ok, current} = Conversations.update(current, %{title: "Current work"})

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

  defp provider! do
    {:ok, provider} =
      Providers.create(%{
        name: "vitals-#{System.unique_integer([:positive])}",
        kind: "openai_compatible",
        base_url: "http://127.0.0.1:9/v1",
        models: ["big-model"],
        default_model: "big-model"
      })

    provider
  end

  defp configure!(pricing) do
    provider = provider!()

    {:ok, _} =
      Settings.update(%{
        default_chat_provider_id: provider.id,
        default_chat_model: "big-model",
        pricing: pricing
      })

    Cache.clear()
    provider
  end

  describe "C3 the context window" do
    test "a configured window is sent whole; without one the 1 M default", c do
      configure!(%{})
      assert {:ok, %{"value" => snapshot}} = query(c.backend, conversation(c.current.id))
      # desktop pass 74 K1, synced in cli021 K7: every unconfigured model is 1 M.
      assert snapshot["context_window"] == 1_000_000

      configure!(%{
        "big-model" => %{"input" => 1.0, "output" => 2.0, "context_window" => 200_000}
      })

      assert {:ok, %{"value" => snapshot}} = query(c.backend, conversation(c.current.id))
      assert snapshot["context_window"] == 200_000

      assert {:ok, %DTO.WorkspaceSnapshot{context_window: 200_000}} =
               DTO.WorkspaceSnapshot.decode(snapshot)
    end
  end

  describe "C2 the vitals" do
    test "the shell watch hears them only while it exists, and its snapshot carries them", c do
      configure!(%{})
      watch!(c.backend, "shell", global(), "shell")

      assert_receive {:service_delta, backend, "shell", %{"kind" => "vitals"} = delta}, 3_000
      send(backend, {:service_credit, self(), "shell", delta["sequence"]})
      assert {:ok, %Delta{kind: :vitals, body: %DTO.Vitals{} = vitals}} = Delta.decode(delta)
      assert vitals.conversation_id == c.current.id
      assert vitals.beam_bytes > 0

      assert {:ok, %{"value" => shell}} = query(c.backend, global(), "shell")

      assert {:ok, %DTO.ShellSnapshot{vitals: %DTO.Vitals{conversation_id: id}}} =
               DTO.ShellSnapshot.decode(shell)

      assert id == c.current.id

      # The watch ends: nothing more is measured or sent to anyone.
      send(c.backend, {:service_unwatch, self(), "shell"})
      _ = :sys.get_state(c.backend)
      flush_vitals()
      refute_receive {:service_delta, _, _, %{"kind" => "vitals"}}, 1_500
    end

    test "a finished call of the shown conversation reaches the delta with its history", c do
      configure!(%{})
      watch!(c.backend, "shell", global(), "shell")
      assert_receive {:service_delta, backend, "shell", %{"kind" => "vitals"} = first}, 3_000
      send(backend, {:service_credit, self(), "shell", first["sequence"]})

      # the synced engine's speed monitor owns the table the vitals read
      if :ets.whereis(:swarm_code_speed) == :undefined,
        do: start_supervised!(SwarmCode.Domain.LLM.Speed)

      shown = %{
        main: %{
          tps: 48,
          ttft_ms: 350,
          model: "big-model",
          at: ~U[2026-10-08 10:00:00Z],
          live?: false
        }
      }

      :ets.insert(:swarm_code_speed, {{:conv, c.current.id}, shown})
      on_exit(fn -> :ets.delete(:swarm_code_speed, {:conv, c.current.id}) end)

      SwarmCode.Domain.PubSub.broadcast(
        SwarmCode.Domain.PubSub,
        "speed",
        {:speed_sample, c.current.id, shown}
      )

      assert {:ok, vitals} =
               await_vitals(backend, fn v -> Enum.any?(v.models, &(&1.tps == 48)) end)

      assert [%DTO.ModelSpeed{slot: :main, model: "big-model", tps: 48, history: [48]} | _] =
               vitals.models
    end
  end

  defp flush_vitals do
    receive do
      {:service_delta, _, _, %{"kind" => "vitals"}} -> flush_vitals()
    after
      0 -> :ok
    end
  end

  defp await_vitals(backend, done?) do
    receive do
      {:service_delta, ^backend, "shell", %{"kind" => "vitals"} = delta} ->
        send(backend, {:service_credit, self(), "shell", delta["sequence"]})
        {:ok, %Delta{body: vitals}} = Delta.decode(delta)
        if done?.(vitals), do: {:ok, vitals}, else: await_vitals(backend, done?)
    after
      4_000 -> :timeout
    end
  end

  defp global, do: %Scope{kind: :global, id: nil, generation: 0}
  defp conversation(id), do: %Scope{kind: :conversation, id: id, generation: 1}

  defp watch!(backend, slot, scope, ref) do
    request = %ServiceRequest{
      operation: :watch,
      timeout_ms: 1000,
      params: %{"watch_ref" => ref, "slot" => slot, "page_size" => 20, "byte_limit" => 262_144}
    }

    assert {:watch, 0, _, _, _} =
             GenServer.call(backend, {:service_watch, self(), "watch-#{ref}", scope, request})

    send(backend, {:service_ready, self(), ref})
  end

  defp query(backend, scope, slot \\ "workspace"),
    do:
      request(backend, "query", scope, %ServiceRequest{
        operation: :query,
        timeout_ms: 5000,
        params: %{
          "slot" => slot,
          "cursor" => nil,
          "direction" => "before",
          "page_size" => 50,
          "byte_limit" => 1_048_576
        }
      })

  defp request(backend, name, scope, request),
    do:
      GenServer.call(
        backend,
        {:service_request, "#{name}-#{System.unique_integer([:positive])}", scope, request},
        10_000
      )
end
