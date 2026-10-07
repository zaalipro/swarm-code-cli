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
    assert {:ok, %{status: :ready}} = Gate.check_bound(c.path, c.manifest, "0.1.0", [])
    :ok = CommandLedger.ensure!()
    assert {:ok, %{status: :ready}} = Gate.check_bound(c.path, c.manifest, "0.1.0", [])
  end

  test "malformed same-name metadata refuses without treating it as a CLI extension", c do
    Ecto.Adapters.SQL.query!(Repo, "CREATE TABLE cli_command_ledger(unexpected TEXT)", [])

    assert {:error, %{code: :schema_incompatible}} =
             Gate.check_bound(c.path, c.manifest, "0.1.0", [])

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
             Gate.check_bound(c.path, c.manifest, "0.1.0", [])
  end

  # cli020 C2 (bugs-4): a staged image whose file is gone (the 24 h prune)
  # leaves the staging table instead of poisoning every later send.
  test "a staged row whose attachment file is gone is removed", c do
    :ok = CommandLedger.ensure!()
    dir = Path.join(Path.dirname(c.path), "c2-config-#{System.unique_integer([:positive])}")
    prior = Application.get_env(:swarm_code_daemon, :domain_config_dir)
    Application.put_env(:swarm_code_daemon, :domain_config_dir, dir)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:swarm_code_daemon, :domain_config_dir, prior),
        else: Application.delete_env(:swarm_code_daemon, :domain_config_dir)

      File.rm_rf!(dir)
    end)

    png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", 0::64>>
    {:ok, kept} = SwarmCode.Domain.Attachments.store("a.png", "image/png", Base.encode64(png))
    {:ok, gone} = SwarmCode.Domain.Attachments.store("b.png", "image/png", Base.encode64(png))
    project = Ecto.UUID.generate()
    conversation = Ecto.UUID.generate()
    :ok = CommandLedger.stage_attachment(project, conversation, kept["id"])
    :ok = CommandLedger.stage_attachment(project, conversation, gone["id"])
    File.rm!(gone["path"])

    assert CommandLedger.staged_attachments(project, conversation) == [kept["id"]]
    assert CommandLedger.staged_attachment_ids() == [kept["id"]]

    assert %{rows: [[1]]} =
             Ecto.Adapters.SQL.query!(Repo, "SELECT count(*) FROM cli_attachment_staging", [])
  end

  # cli020 C3 (bugs-19): the ledger is pruned: rows untouched for 7 days, and
  # unresolved rows of an earlier session, at most 5,000 per call.
  test "prune drops rows older than 7 days and earlier sessions' processing rows" do
    :ok = CommandLedger.ensure!()
    project = Ecto.UUID.generate()
    scope = %Scope{kind: :conversation, id: Ecto.UUID.generate(), generation: 1}
    now = ~U[2026-10-07 12:00:00.000000Z]
    old = DateTime.add(now, -8 * 86_400) |> DateTime.to_iso8601()

    for id <- ["old-1", "old-2", "old-3", "new-1", "stuck-1"],
        do: :new = CommandLedger.admit(project, id, scope, "f")

    for id <- ["old-1", "old-2", "old-3"],
        do: :ok = CommandLedger.complete(project, id, {:ok, %{"value" => %{}}})

    :ok = CommandLedger.complete(project, "new-1", {:ok, %{"value" => %{}}})

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE cli_command_ledger SET updated_at = ? WHERE request_id LIKE 'old-%'",
      [old]
    )

    # This session started after the stuck row was admitted.
    epoch = DateTime.add(DateTime.utc_now(), 60)
    assert CommandLedger.prune(now, epoch) == 4

    assert %{rows: [["new-1"]]} =
             Ecto.Adapters.SQL.query!(Repo, "SELECT request_id FROM cli_command_ledger", [])
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
