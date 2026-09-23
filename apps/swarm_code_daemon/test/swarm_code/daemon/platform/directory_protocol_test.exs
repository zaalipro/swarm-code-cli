defmodule SwarmCode.Daemon.Platform.DirectoryProtocolTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Daemon.Platform.DirectoryProtocol
  alias SwarmCode.Daemon.Schema.Probe
  alias SwarmCode.Daemon.StartupError

  test "incremental framing caps the announced body before reading or allocating it" do
    assert {:more, decoder} = DirectoryProtocol.push(DirectoryProtocol.new_decoder(), <<0, 0>>)
    assert {:more, decoder} = DirectoryProtocol.push(decoder, <<0, 3, 1>>)
    assert {:ok, <<1, 2, 3>>, "tail"} = DirectoryProtocol.push(decoder, <<2, 3, "tail">>)

    maximum = DirectoryProtocol.maximum_bytes()

    assert {:error, :invalid_frame} =
             DirectoryProtocol.push(
               DirectoryProtocol.new_decoder(),
               <<maximum + 1::unsigned-big-32>>
             )
  end

  test "blocking frame reads accept partial headers and reject oversized headers before body reads" do
    chunks = [<<0>>, <<0, 0>>, <<3>>, <<1>>, <<2, 3>>]
    Process.put(:directory_protocol_chunks, chunks)

    reader = fn maximum ->
      [chunk | rest] = Process.get(:directory_protocol_chunks)
      assert byte_size(chunk) <= maximum
      Process.put(:directory_protocol_chunks, rest)
      chunk
    end

    assert {:ok, <<1, 2, 3>>} = DirectoryProtocol.read_frame(reader)
    assert Process.get(:directory_protocol_chunks) == []

    Process.put(:directory_protocol_reads, 0)
    maximum = DirectoryProtocol.maximum_bytes()

    oversized_reader = fn _maximum ->
      Process.put(:directory_protocol_reads, Process.get(:directory_protocol_reads) + 1)
      <<maximum + 1::unsigned-big-32>>
    end

    assert {:error, :invalid_frame} = DirectoryProtocol.read_frame(oversized_reader)
    assert Process.get(:directory_protocol_reads) == 1
  after
    Process.delete(:directory_protocol_chunks)
    Process.delete(:directory_protocol_reads)
  end

  test "safe closed decoding rejects compressed ETF, unknown atoms, and invalid request shapes" do
    compressed =
      :erlang.term_to_binary(
        {:write_private, ".owned", :binary.copy(<<0>>, 32 * 1_024), 501},
        compressed: 9
      )

    assert {:error, :invalid_protocol} = DirectoryProtocol.decode_request(compressed)

    unknown_name = "task7_protocol_atom_that_must_not_exist_4f73935b"

    unknown_atom_etf =
      <<131, 118, byte_size(unknown_name)::unsigned-big-16, unknown_name::binary>>

    assert {:error, :invalid_protocol} = DirectoryProtocol.decode_request(unknown_atom_etf)

    assert {:error, :invalid_protocol} =
             DirectoryProtocol.decode_request(:erlang.term_to_binary({:unlink, "../escape"}))

    assert {:ok, frame} = DirectoryProtocol.encode_request({:unlink, ".owned"})

    identity = {:regular, 1, 0, 42, 501, 0o100600, 7}
    probe = valid_probe()

    assert {:error, :invalid_protocol} =
             DirectoryProtocol.encode_request({
               :open_source,
               [{:main, "relative.sqlite3", ".pin.sqlite3", identity}],
               probe,
               501
             })

    assert {:more, decoder} =
             DirectoryProtocol.push(
               DirectoryProtocol.new_decoder(),
               binary_part(IO.iodata_to_binary(frame), 0, 2)
             )

    encoded = IO.iodata_to_binary(frame)

    assert {:ok, payload, <<>>} =
             DirectoryProtocol.push(decoder, binary_part(encoded, 2, byte_size(encoded) - 2))

    assert {:ok, {:unlink, ".owned"}} = DirectoryProtocol.decode_request(payload)
  end

  test "closed struct validation rejects extra keys and invalid typed fields" do
    probe = %Probe{
      application_id: 0,
      migration_versions: [20_260_901_000_000],
      schema_sha256: String.duplicate("a", 64),
      sqlite_version: "3.53.3",
      sqlite_source_id: "bounded-source-id",
      quick_check: [["ok"]],
      foreign_key_violations: []
    }

    invalid_probe = Map.put(probe, :message, "unexpected extra key")

    assert {:error, :invalid_protocol} =
             DirectoryProtocol.decode_request(
               :erlang.term_to_binary({:verify_database, ".backup.sqlite3", invalid_probe})
             )

    assert {:error, :invalid_protocol} =
             DirectoryProtocol.encode_request({
               :verify_database,
               ".backup.sqlite3",
               %{probe | application_id: "0"}
             })

    invalid_error = %StartupError{
      code: :backup_failed,
      retryable: false,
      message: :not_text,
      action: "Inspect the backup."
    }

    assert {:error, :invalid_protocol} =
             DirectoryProtocol.decode_reply(
               :pwd,
               :erlang.term_to_binary({:error, invalid_error})
             )
  end

  test "the current migration probe crosses the closed protocol but a 58th row rejects" do
    versions =
      SwarmCode.Daemon.Schema.MigrationManifest.load!().migrations |> Enum.map(& &1.version)

    assert length(versions) == 57
    probe = %{valid_probe() | migration_versions: versions}
    request = {:verify_database, ".backup.sqlite3", probe}
    assert {:ok, frame} = DirectoryProtocol.encode_request(request)

    assert {:ok, payload, <<>>} =
             DirectoryProtocol.push(DirectoryProtocol.new_decoder(), IO.iodata_to_binary(frame))

    assert {:ok, ^request} = DirectoryProtocol.decode_request(payload)

    overflow =
      {:verify_database, ".backup.sqlite3",
       %{probe | migration_versions: versions ++ [20_990_101_000_000]}}

    assert {:error, :invalid_protocol} = DirectoryProtocol.encode_request(overflow)

    assert {:error, :invalid_protocol} =
             DirectoryProtocol.decode_request(:erlang.term_to_binary(overflow))
  end

  defp valid_probe do
    %Probe{
      application_id: 0,
      migration_versions: [20_260_901_000_000],
      schema_sha256: String.duplicate("a", 64),
      sqlite_version: "3.53.3",
      sqlite_source_id: "bounded-source-id",
      quick_check: [["ok"]],
      foreign_key_violations: []
    }
  end

  test "reply decoding is operation-specific and never accepts an unbounded or foreign shape" do
    operation = {:private_identity, ".owned", 501}
    identity = {:regular, 1, 0, 42, 501, 0o100600, 7}

    assert {:ok, frame} = DirectoryProtocol.encode_reply(operation, {:ok, identity})

    assert {:ok, payload, <<>>} =
             DirectoryProtocol.push(DirectoryProtocol.new_decoder(), IO.iodata_to_binary(frame))

    assert {:ok, {:ok, ^identity}} = DirectoryProtocol.decode_reply(operation, payload)

    assert {:error, :invalid_protocol} =
             DirectoryProtocol.decode_reply(:pwd, :erlang.term_to_binary({:ok, identity}))

    assert {:error, :invalid_protocol} =
             DirectoryProtocol.encode_reply(:pwd, {:ok, String.duplicate("x", 16 * 1_024 + 1)})

    assert {:error, :invalid_protocol} =
             DirectoryProtocol.encode_reply(
               {:file_entry, ".backup.sqlite3", 501, "backup.sqlite3"},
               {:ok,
                %{
                  "name" => "backup.sqlite3",
                  "sha256" => String.duplicate("a", 64),
                  "size" => 1,
                  "unexpected" => true
                }}
             )

    assert {:error, :invalid_protocol} =
             DirectoryProtocol.encode_reply(
               {:verify_database, ".backup.sqlite3", nil},
               {:ok, %{"quick_check" => "ok"}}
             )

    assert {:ok, _frame} =
             DirectoryProtocol.encode_reply(
               {:verify_database, ".backup.sqlite3", nil},
               {:error, :mismatch}
             )
  end

  test "cleanup-pending startup errors remain in the closed wire union" do
    error = %StartupError{
      code: :cleanup_pending,
      retryable: true,
      message: "cleanup is pending",
      action: "retry later"
    }

    assert {:ok, frame} = DirectoryProtocol.encode_reply(:pwd, {:error, error})

    assert {:ok, payload, <<>>} =
             DirectoryProtocol.push(DirectoryProtocol.new_decoder(), IO.iodata_to_binary(frame))

    assert {:ok, {:error, ^error}} = DirectoryProtocol.decode_reply(:pwd, payload)
  end

  test "open-source replies contain exactly the identities requested by the source specs" do
    probe = %Probe{
      application_id: 0,
      migration_versions: [20_260_901_000_000],
      schema_sha256: String.duplicate("a", 64),
      sqlite_version: "3.53.3",
      sqlite_source_id: "bounded-source-id",
      quick_check: [["ok"]],
      foreign_key_violations: []
    }

    identity = {:regular, 1, 0, 42, 501, 0o100600, 7}

    one_spec =
      {:open_source, [{:main, "/source.sqlite3", ".pin.sqlite3", identity}], probe, 501}

    assert {:ok, _frame} = DirectoryProtocol.encode_reply(one_spec, {:ok, %{main: identity}})

    assert {:error, :invalid_protocol} =
             DirectoryProtocol.encode_reply(one_spec, {
               :ok,
               %{main: identity, wal: nil, shm: nil}
             })

    three_specs =
      {:open_source,
       [
         {:main, "/source.sqlite3", ".pin.sqlite3", identity},
         {:wal, "/source.sqlite3-wal", ".pin.sqlite3-wal", nil},
         {:shm, "/source.sqlite3-shm", ".pin.sqlite3-shm", nil}
       ], probe, 501}

    assert {:ok, _frame} =
             DirectoryProtocol.encode_reply(three_specs, {
               :ok,
               %{main: identity, wal: nil, shm: nil}
             })
  end

  test "successful replies match the public helper result shape" do
    identity = {:regular, 1, 0, 42, 501, 0o100600, 7}

    assert {:ok, _frame} = DirectoryProtocol.encode_reply(:finish_copy, {:ok, identity})

    assert {:error, :invalid_protocol} =
             DirectoryProtocol.encode_reply(:finish_copy, :ok)
  end
end
