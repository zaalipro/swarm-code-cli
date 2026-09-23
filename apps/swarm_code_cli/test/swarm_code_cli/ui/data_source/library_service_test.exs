defmodule SwarmCodeCLI.UI.DataSource.LibraryServiceTest do
  use ExUnit.Case, async: false
  alias SwarmCode.Domain.{Repo, Settings}
  alias SwarmCode.Daemon.Service
  alias SwarmCode.Daemon.Service.LiveBackend
  alias SwarmCode.Protocol.Scope
  alias SwarmCode.Providers.Provider
  alias SwarmCodeCLI.UI.DataSource
  alias SwarmCodeCLI.UI.DataSource.{Daemon, DTO, Request}

  setup do
    root = Path.join("/tmp", "sc-lib-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, provider} =
      Provider.new(name: "unused", base_url: "http://127.0.0.1:1", default_model: "unused")

    epoch = Ecto.UUID.generate()
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    backend =
      start_supervised!(
        {LiveBackend,
         mode: :transient,
         provider: provider,
         project_root: root,
         conversation_id: Ecto.UUID.generate(),
         project_id: Ecto.UUID.generate(),
         source_epoch: epoch}
      )

    path = Path.join(root, "socket")

    start_supervised!(
      {Service, socket_path: path, backend: backend, nonce: nonce, source_epoch: epoch}
    )

    client = start_supervised!({Daemon, socket_path: path, nonce: nonce, source_epoch: epoch})
    assert {:ok, "bound"} = DataSource.bind_owner(client, self(), "bound")
    %{root: root, client: client, epoch: epoch}
  end

  test "unavailable persisted features return a typed error without closing the client", c do
    query(c.client, "settings-1")

    assert_receive {:swarm_code_ui_data, epoch, receipt,
                    %{body: %DTO.LibrarySnapshot{state: :error, feature: :settings, error: error}}},
                   5_000

    assert epoch == c.epoch
    assert error.code == :source_unavailable
    DataSource.consume(c.client, receipt, :applied)
    assert Process.alive?(c.client)
  end

  test "persisted settings cross the socket as bounded rows without credentials", c do
    start_supervised!(
      {Repo,
       database: Path.join(c.root, "fixture.db"), domain_fixture: true, pool_size: 1, log: false}
    )

    Ecto.Migrator.run(
      Repo,
      Application.app_dir(:swarm_code_daemon, "priv/domain_repo/migrations"),
      :up,
      all: true,
      log: false
    )

    {:ok, _} =
      Settings.update(%{tavily_api_key: "MUST-NOT-CROSS-SOCKET", max_concurrent_agents: 7})

    query(c.client, "settings-2")

    assert_receive {:swarm_code_ui_data, epoch, receipt,
                    %{
                      body:
                        %DTO.LibrarySnapshot{state: :idle, feature: :settings, items: items} =
                          page
                    }},
                   5_000

    assert epoch == c.epoch
    assert items != []
    assert Enum.any?(items, &String.contains?(&1.detail, "max_concurrent_agents"))
    refute inspect(page) =~ "MUST-NOT-CROSS-SOCKET"
    assert :ok = DataSource.consume(c.client, receipt, :applied)
  end

  defp query(client, id) do
    scope = %Scope{kind: :global, id: nil, generation: 2}

    request = %Request{
      request_id: id,
      kind: {:feature_query, :settings, nil, nil, 20, 262_144},
      scope: scope,
      generation: 2,
      origin: {:feature, :settings},
      deadline: System.system_time(:millisecond) + 5_000,
      expected_response: :library_snapshot
    }

    assert :ok = DataSource.query(client, request)
  end
end
