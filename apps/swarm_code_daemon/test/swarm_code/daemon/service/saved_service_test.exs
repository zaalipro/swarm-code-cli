defmodule SwarmCode.Daemon.Service.SavedServiceTest do
  use ExUnit.Case, async: false

  alias SwarmCode.Daemon.{RepoLauncher, Service.PersistedBackend, Service.SessionSelection}
  alias SwarmCode.Domain.Repo
  alias SwarmCode.Protocol.Scope

  test "guarded Repo, selection and persisted service form a saved vertical slice" do
    root =
      Path.join(
        SwarmCode.Daemon.Test.LeaseFixture.build_root(),
        "saved-slice-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
      )

    File.mkdir_p!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)
    database = Path.join(root, "swarm_code.db")

    boot = [
      platform: :linux,
      mode: :test,
      home: root,
      env:
        Map.new(
          ~w(XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR),
          &{&1, root}
        ),
      database_path: database,
      app_version: "0.1.0-dev",
      desktop_detector: fn -> :none end,
      directory_ensure: fn path, uid ->
        case File.mkdir(path) do
          :ok -> File.chmod!(path, 0o700)
          {:error, :eexist} -> :ok
        end

        SwarmCode.Daemon.Platform.PrivateDirectory.ensure(path, uid)
      end,
      identity: fn ->
        {:ok,
         %SwarmCode.Daemon.Platform.ProcessIdentity{
           uid: File.stat!(root).uid,
           pid: String.to_integer(System.pid()),
           process_start_id: "saved-slice",
           boot_id: "saved-slice"
         }}
      end
    ]

    {:ok, launcher} = RepoLauncher.start_link(boot_config: boot, pool_size: 2)
    assert {:ok, repo} = RepoLauncher.await_ready(launcher, 60_000)
    assert Process.whereis(Repo) == repo

    Task.async(fn ->
      assert {:ok, session} = SessionSelection.open(root)

      assert {:ok, backend} =
               PersistedBackend.start_link(
                 mode: :persisted,
                 repo: Repo,
                 project_root: root,
                 project_id: session.project.id,
                 conversation_id: session.conversation.id,
                 source_epoch: Ecto.UUID.generate()
               )

      scope = %Scope{kind: :conversation, id: session.conversation.id, generation: 1}

      request = %SwarmCode.Protocol.ServiceRequest{
        operation: :query,
        params: %{
          "slot" => "workspace",
          "cursor" => nil,
          "direction" => "after",
          "page_size" => 200,
          "byte_limit" => 1_048_576
        },
        timeout_ms: 5_000
      }

      assert {:ok, %{"value" => %{"conversation_id" => id}}} =
               GenServer.call(backend, {:service_request, "saved-query", scope, request})

      assert id == session.conversation.id
      GenServer.stop(backend, :normal, 15_000)
    end)
    |> Task.await(15_000)

    assert :ok = RepoLauncher.close(launcher)
    File.rm_rf!(root)
  end
end
