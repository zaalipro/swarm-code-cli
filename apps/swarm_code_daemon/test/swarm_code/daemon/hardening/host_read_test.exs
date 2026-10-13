defmodule SwarmCode.Daemon.Hardening.HostReadTest do
  # Call tracing of :file.* is node-global, so these tests never run beside each other.
  use ExUnit.Case, async: false

  alias SwarmCode.Domain.Workflows.Host

  @cap 200_000
  @ceiling 5_000_000
  @chunk 65_536
  @family "👨‍👩‍👧"

  setup do
    root = Path.join(System.tmp_dir!(), "host-read-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  defp read(root, name, content) do
    File.write!(Path.join(root, name), content)
    Host.run(:read_file, [path: name], root)
  end

  defp oracle(content), do: String.slice(Host.valid_utf8(content), 0, @cap)

  # Records every :file.open/read/close the calling process makes while `fun`
  # runs. A process cannot be its own tracer, so a collector receives the events.
  defp traced(fun) do
    me = self()
    collector = spawn_link(fn -> collect(me, []) end)
    :erlang.trace(me, true, [:call, {:tracer, collector}])

    :erlang.trace_pattern({:file, :open, 2}, [{:_, [], [{:return_trace}]}], [:global])
    :erlang.trace_pattern({:file, :read, 2}, [{:_, [], [{:return_trace}]}], [:global])
    :erlang.trace_pattern({:file, :close, 1}, true, [:global])

    result =
      try do
        fun.()
      after
        :erlang.trace(me, false, [:call])
        :erlang.trace_pattern({:file, :_, :_}, false, [:global])
      end

    ref = make_ref()
    send(collector, {:done, ref})

    trace =
      receive do
        {:trace_done, ^ref, events} -> events
      after
        5_000 -> flunk("trace collector did not answer")
      end

    {result, trace}
  end

  defp collect(owner, acc) do
    receive do
      {:trace, _pid, :call, {:file, f, args}} ->
        collect(owner, [{:call, f, args} | acc])

      {:trace, _pid, :return_from, {:file, f, _}, ret} ->
        collect(owner, [{:ret, f, ret} | acc])

      {:done, ref} ->
        send(owner, {:trace_done, ref, Enum.reverse(acc)})
    end
  end

  defp opened(trace), do: for({:ret, :open, {:ok, fd}} <- trace, do: fd)
  defp closed(trace), do: for({:call, :close, [fd]} <- trace, do: fd)
  defp read_sizes(trace), do: for({:ret, :read, {:ok, data}} <- trace, do: byte_size(data))

  defp assert_all_closed(trace) do
    assert opened(trace) != []
    assert Enum.sort(opened(trace)) == Enum.sort(closed(trace))
  end

  describe "admission" do
    test "a sparse file over the ceiling is refused before it is opened", %{root: root} do
      path = Path.join(root, "sparse.bin")
      {:ok, io} = :file.open(path, [:write, :raw, :binary])
      {:ok, _} = :file.position(io, @ceiling + 1)
      :ok = :file.write(io, "x")
      :ok = :file.close(io)

      {result, trace} = traced(fn -> Host.run(:read_file, [path: "sparse.bin"], root) end)

      assert result == "Error: file exceeds 5000000 bytes"
      assert opened(trace) == []
    end

    test "a file of exactly the ceiling is admitted and yields the first 200000 graphemes", %{
      root: root
    } do
      path = Path.join(root, "exact.txt")
      {:ok, io} = :file.open(path, [:write, :raw, :binary])
      {:ok, _} = :file.position(io, @ceiling - 1)
      :ok = :file.write(io, "z")
      :ok = :file.close(io)
      assert File.stat!(path).size == @ceiling

      {result, trace} = traced(fn -> Host.run(:read_file, [path: "exact.txt"], root) end)

      # The sparse hole reads back as NUL bytes, one grapheme each.
      assert result == String.duplicate(<<0>>, @cap)
      assert_all_closed(trace)
    end

    test "a text file of exactly the ceiling stops at the grapheme cap", %{root: root} do
      content = String.duplicate("ab", div(@ceiling, 2))
      assert byte_size(content) == @ceiling

      {result, trace} = traced(fn -> read(root, "exact_text.txt", content) end)

      assert result == binary_part(content, 0, @cap)
      assert_all_closed(trace)
    end

    test "a directory is not a regular file", %{root: root} do
      File.mkdir_p!(Path.join(root, "dir"))
      assert Host.run(:read_file, [path: "dir"], root) == "Error: not a regular file"
      assert Host.run(:read_file, [path: "."], root) == "Error: not a regular file"
    end

    test "a FIFO is rejected without being opened", %{root: root} do
      fifo = Path.join(root, "pipe")

      case System.cmd("mkfifo", [fifo], stderr_to_stdout: true) do
        {_, 0} ->
          task =
            Task.async(fn -> traced(fn -> Host.run(:read_file, [path: "pipe"], root) end) end)

          assert {result, trace} = Task.await(task, 5_000)
          assert result == "Error: not a regular file"
          assert opened(trace) == []

        {_, _} ->
          :ok
      end
    end

    test "outside-root and missing paths keep their sentences", %{root: root} do
      assert Host.run(:read_file, [path: "../../etc/hosts"], root) ==
               "path is outside the project root: ../../etc/hosts"

      assert Host.run(:read_file, [path: "missing.txt"], root) ==
               "Error: no such file or directory"
    end

    test "an unreadable file reports the open error and leaves nothing open", %{root: root} do
      path = Path.join(root, "secret.txt")
      File.write!(path, "hidden")
      File.chmod!(path, 0o000)

      try do
        {result, trace} = traced(fn -> Host.run(:read_file, [path: "secret.txt"], root) end)

        if File.read(path) == {:error, :eacces} do
          assert result == "Error: permission denied"
        end

        assert opened(trace) == closed(trace)
      after
        File.chmod!(path, 0o600)
      end
    end
  end

  describe "bounded reads" do
    test "chunks never exceed 65536 bytes and the descriptor is closed", %{root: root} do
      content = String.duplicate("é", 100_000)

      {result, trace} = traced(fn -> read(root, "wide.txt", content) end)

      assert result == oracle(content)
      sizes = read_sizes(trace)
      assert Enum.max(sizes) == @chunk
      assert Enum.all?(sizes, &(&1 <= @chunk))
      assert_all_closed(trace)
    end

    test "the early cap stops reading long before the end of a large file", %{root: root} do
      content = String.duplicate("a", 3_000_000)

      {result, trace} = traced(fn -> read(root, "big.txt", content) end)

      assert result == String.duplicate("a", @cap)
      assert Enum.sum(read_sizes(trace)) < 400_000
      assert_all_closed(trace)
    end

    test "the host module never loads a whole file" do
      source =
        File.read!(Path.join(__DIR__, "../../../../lib/swarm_code/domain/workflows/host.ex"))

      refute source =~ "File.read("
      refute source =~ "File.stream!"
    end
  end

  describe "prefix compatibility with String.slice" do
    test "multibyte, combining and ZWJ sequences crossing a chunk boundary", %{root: root} do
      tails = [
        "é€😀x",
        "e\u0301x",
        "e\u0301\u0302\u0303x",
        @family <> "x",
        "🇫🇷🇩🇪🇮🇹x",
        "\r\nx"
      ]

      for offset <- (@chunk - 6)..(@chunk + 1), tail <- tails do
        content = String.duplicate("a", offset) <> tail

        assert read(root, "f.txt", content) == oracle(content),
               "offset #{offset} #{inspect(tail)}"
      end
    end

    test "clusters straddling the 200000 grapheme boundary", %{root: root} do
      clusters = [@family, "e\u0301", "e\u0301\u0302", "🇫🇷", "\r\n", "é"]

      for cluster <- clusters, follow <- ["", "x", "\u0301", "\u200d👨"] do
        for lead <- [@cap - 2, @cap - 1, @cap] do
          content = String.duplicate("a", lead) <> cluster <> follow <> "tail"
          assert read(root, "f.txt", content) == oracle(content), "#{lead} #{inspect(cluster)}"
        end
      end
    end

    test "a cap-crossing cluster that ends exactly at EOF", %{root: root} do
      for cluster <- [@family, "e\u0301", "🇫🇷"] do
        content = String.duplicate("a", @cap - 1) <> cluster
        assert read(root, "f.txt", content) == oracle(content)
      end
    end

    test "one cluster spanning many chunks is kept whole", %{root: root} do
      content = "e" <> String.duplicate("\u0301", 100_000) <> "x"
      assert read(root, "f.txt", content) == oracle(content)
    end

    test "invalid and incomplete UTF-8 is repaired as String.replace_invalid does", %{root: root} do
      euro = <<0xE2, 0x82, 0xAC>>

      fixtures = [
        "abc" <> <<0xE2, 0x82>>,
        "abc" <> <<0xF0, 0x9F>>,
        "abc" <> <<0xFF>>,
        "abc" <> <<0xE2>> <> "x",
        "ab" <> <<0xC3>>,
        String.duplicate("a", @chunk - 1) <> euro <> "z",
        String.duplicate("a", @chunk - 2) <> euro <> "z",
        String.duplicate("a", @chunk - 2) <> <<0xE2, 0x82>> <> "z",
        String.duplicate("a", @chunk - 1) <> <<0xE2>> <> String.duplicate("a", 10),
        String.duplicate("a", @chunk - 1) <> <<0xE2, 0x82>>,
        String.duplicate("a", @cap - 1) <> <<0xE2, 0x82>>,
        <<0xFF, 0xFE>> <> String.duplicate("a", @chunk)
      ]

      for content <- fixtures do
        assert read(root, "f.txt", content) == oracle(content)
      end
    end

    test "an empty file reads as the empty string", %{root: root} do
      assert read(root, "empty.txt", "") == ""
    end
  end
end
