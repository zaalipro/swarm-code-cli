defmodule SwarmCode.Daemon.Service.StagedAttachmentTest do
  @moduledoc """
  cli020 C2 (bugs-4): a staged image whose file was pruned no longer refuses
  every later send; the send goes out and says the image was removed.
  """
  use ExUnit.Case, async: false
  import SwarmCode.Test.C020Backend
  alias SwarmCode.Daemon.Service.CommandLedger
  alias SwarmCode.Domain.{Attachments, Conversations, Engine}

  setup_all do
    setup_world("staged")
  end

  test "a send with a staged image that is gone starts and tells", c do
    {:ok, conv} = Conversations.create(c.project.id)
    on_exit(fn -> Engine.stop_all(conv.id) end)
    {conv, _, _} = provider!(c, conv, fn _ -> {:text, "Hi."} end)
    png = <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", 0::64>>
    {:ok, staged} = Attachments.store("shot.png", "image/png", Base.encode64(png))
    :ok = CommandLedger.ensure!()
    :ok = CommandLedger.stage_attachment(c.project.id, conv.id, staged["id"])
    backend = start_backend(c, conv)
    assert :sys.get_state(backend).attachment_ids == [staged["id"]]
    File.rm!(staged["path"])

    assert {:ok, %{"value" => value}} = send_text(backend, scope(conv), "Look at this")
    assert value["status"] == "accepted"
    assert value["disposition"] == "started"
    assert value["feedback"]["text"] == "A staged image was removed before sending."
    assert :sys.get_state(backend).attachment_ids == []
    assert CommandLedger.staged_attachments(c.project.id, conv.id) == []
  end

  # cli020 C3: the backend prunes the ledger once, as owned work, at start.
  test "a starting backend prunes week-old ledger rows", c do
    {:ok, conv} = Conversations.create(c.project.id)
    :ok = CommandLedger.ensure!()
    scope = scope(conv)
    :new = CommandLedger.admit(c.project.id, "c3-old", scope, "f")
    :ok = CommandLedger.complete(c.project.id, "c3-old", {:ok, %{"value" => %{}}})
    old = DateTime.utc_now() |> DateTime.add(-8 * 86_400) |> DateTime.to_iso8601()

    Ecto.Adapters.SQL.query!(
      SwarmCode.Domain.Repo,
      "UPDATE cli_command_ledger SET updated_at = ? WHERE request_id = 'c3-old'",
      [old]
    )

    backend = start_backend(c, conv)
    assert eventually(fn -> :sys.get_state(backend).ledger_prune == nil end)

    assert %{rows: [[0]]} =
             Ecto.Adapters.SQL.query!(
               SwarmCode.Domain.Repo,
               "SELECT count(*) FROM cli_command_ledger WHERE request_id = 'c3-old'",
               []
             )
  end
end
