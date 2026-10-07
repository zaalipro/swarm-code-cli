defmodule SwarmCode.Daemon.Service.ClipboardInboxTest do
  @moduledoc """
  cli020 C14 (competitors-6): a pasted clipboard image goes through a slot:
  the service names the file, the terminal writes it, the service checks and
  stages it and removes the file whatever happens.
  """
  use ExUnit.Case, async: false
  import SwarmCode.Test.C020Backend
  alias SwarmCode.Daemon.Service.{ClipboardInbox, CommandLedger}
  alias SwarmCode.Domain.{Attachments, Conversations}

  @png <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, "IHDR", 0::64>>

  setup_all do
    setup_world("inbox")
  end

  setup c do
    {:ok, conv} = Conversations.create(c.project.id)
    :ok = CommandLedger.ensure!()
    %{conversation: conv, backend: start_backend(c, conv)}
  end

  defp slot(c) do
    assert {:ok, %{"value" => %{"status" => "accepted", "result" => result}}} =
             command(c.backend, id("slot"), scope(c.conversation), :attachment_slot, %{})

    result
  end

  defp attach(c, token),
    do:
      command(c.backend, id("attach"), scope(c.conversation), :attachment_attach, %{
        "token" => token
      })

  test "a slot is a fresh 0600 file in the 0700 inbox", c do
    assert %{"kind" => "slot", "token" => token, "path" => path} = slot(c)
    assert path == Path.join([c.path, "config", "cli-inbox", token <> ".png"])
    assert File.stat!(path).size == 0
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(Path.dirname(path)).mode, 0o777) == 0o700
  end

  test "a valid PNG is staged and its file removed", c do
    %{"token" => token, "path" => path} = slot(c)
    File.write!(path, @png)

    assert {:ok, %{"value" => %{"status" => "accepted", "result" => result} = value}} =
             attach(c, token)

    assert %{"kind" => "attachment", "attachment" => %{"id" => id, "bytes" => bytes}} = result
    assert result["attachment"]["name"] =~ ~r/\Aclipboard-\d{6}\.png\z/
    assert result["attachment"]["mime"] == "image/png"
    assert bytes == byte_size(@png)
    assert value["identifiers"] == [id]
    refute File.exists?(path)
    assert :sys.get_state(c.backend).attachment_ids == [id]
    assert {:ok, _, _} = Attachments.path(id)

    {:ok, decoded} = SwarmCodeCLI.UI.DataSource.DTO.Outcome.decode(value)
    assert decoded.result.attachment.bytes == bytes
  end

  test "a symlink, a JPEG, a foreign token and an oversized file are refused and removed", c do
    outside = Path.join(c.path, "outside.png")
    File.write!(outside, @png)

    %{"token" => t1, "path" => p1} = slot(c)
    File.rm!(p1)
    File.ln_s!(outside, p1)

    %{"token" => t2, "path" => p2} = slot(c)
    File.write!(p2, <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16>>)

    %{"token" => t3, "path" => p3} = slot(c)
    File.write!(p3, @png <> :binary.copy(<<0>>, Attachments.max_bytes() + 1 - byte_size(@png)))

    for {token, code} <- [{t1, "invalid_argument"}, {t2, "invalid_argument"}, {t3, "too_large"}] do
      assert {:ok, %{"value" => %{"status" => "rejected", "reason" => %{"code" => ^code}}}} =
               attach(c, token)
    end

    refute Enum.any?([p1, p2, p3], &(File.exists?(&1) or match?({:ok, _}, File.lstat(&1))))
    assert File.exists?(outside)

    foreign = String.duplicate("a", 32)
    File.write!(ClipboardInbox.path(foreign), @png)

    assert {:ok,
            %{"value" => %{"status" => "rejected", "reason" => %{"code" => "invalid_argument"}}}} =
             attach(c, foreign)

    assert :sys.get_state(c.backend).attachment_ids == []
  end

  test "at most four open slots", c do
    for _ <- 1..4, do: slot(c)

    assert {:ok, %{"value" => %{"status" => "rejected"}}} =
             command(c.backend, id("slot"), scope(c.conversation), :attachment_slot, %{})
  end

  test "a starting backend removes inbox files older than an hour", c do
    stale = ClipboardInbox.path(String.duplicate("b", 32))
    fresh = ClipboardInbox.path(String.duplicate("c", 32))
    File.mkdir_p!(Path.dirname(stale))
    File.write!(stale, @png)
    File.write!(fresh, @png)
    File.touch!(stale, System.os_time(:second) - 7_200)
    backend = start_backend(c, c.conversation)
    :sys.get_state(backend)
    assert eventually(fn -> not File.exists?(stale) end)
    assert File.exists?(fresh)
  end
end
