defmodule SwarmCode.Daemon.Service.CommandLedgerTest do
  use ExUnit.Case, async: false
  alias SwarmCode.Domain.Repo
  alias SwarmCode.Daemon.Schema.{Gate, MigrationManifest}
  alias SwarmCode.Daemon.Service.CommandLedger
  alias SwarmCode.Protocol.Scope

  setup do
    path = SchemaFixture.database!(:current)

    start_supervised!(
      {Repo, database: path, domain_fixture: true, pool_size: 4, journal_mode: :wal, log: false}
    )

    %{path: path, manifest: MigrationManifest.load!()}
  end

  test "exact CLI extension preserves audited Gate admission across reconnect", c do
    :ok = CommandLedger.ensure!()
    assert {:ok, %{status: :ready}} = Gate.check_bound(c.path, c.manifest, "0.1.0-dev", [])
    :ok = CommandLedger.ensure!()
    assert {:ok, %{status: :ready}} = Gate.check_bound(c.path, c.manifest, "0.1.0-dev", [])
  end

  test "malformed same-name metadata refuses without treating it as a CLI extension", c do
    Ecto.Adapters.SQL.query!(Repo, "CREATE TABLE cli_command_ledger(unexpected TEXT)", [])

    assert {:error, %{code: :schema_incompatible}} =
             Gate.check_bound(c.path, c.manifest, "0.1.0-dev", [])

    assert_raise RuntimeError, "CLI metadata schema mismatch", fn -> CommandLedger.ensure!() end
  end

  test "additional triggers on metadata are refused", c do
    :ok = CommandLedger.ensure!()

    Ecto.Adapters.SQL.query!(
      Repo,
      "CREATE TRIGGER cli_extra AFTER INSERT ON cli_command_ledger BEGIN SELECT 1; END",
      []
    )

    assert {:error, %{code: :schema_incompatible}} =
             Gate.check_bound(c.path, c.manifest, "0.1.0-dev", [])
  end

  test "atomic durable reservation admits only one concurrent caller and preserves unknown outcomes" do
    :ok = CommandLedger.ensure!()
    project = Ecto.UUID.generate()
    scope = %Scope{kind: :conversation, id: Ecto.UUID.generate(), generation: 4}

    answers =
      1..8
      |> Task.async_stream(
        fn _ -> CommandLedger.admit(project, "stable", scope, "fingerprint") end,
        max_concurrency: 8
      )
      |> Enum.map(fn {:ok, value} -> value end)

    assert Enum.count(answers, &(&1 == :new)) == 1
    assert Enum.count(answers, &(&1 == {:unresolved, :unknown_outcome})) == 7

    assert {:unresolved, :unknown_outcome} =
             CommandLedger.admit(project, "stable", %{scope | generation: 5}, "fingerprint")

    response = {:ok, %{"op" => "result", "value" => %{"status" => "accepted"}}}
    :ok = CommandLedger.complete(project, "stable", response)

    assert {:replay, ^response} =
             CommandLedger.admit(project, "stable", %{scope | generation: 5}, "fingerprint")

    assert {:conflict, :request_conflict} =
             CommandLedger.admit(project, "stable", scope, "different")
  end
end
