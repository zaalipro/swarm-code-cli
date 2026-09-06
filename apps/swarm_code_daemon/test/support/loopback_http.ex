defmodule SwarmCode.Test.LoopbackHTTP do
  @moduledoc "Private TCP HTTP fixture; never touches browser sessions or remote providers."
  def start(handler) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_, port}} = :inet.sockname(listener)
    owner = self()
    pid = spawn_link(fn -> accept(listener, handler, owner, 1) end)
    %{url: "http://127.0.0.1:#{port}", listener: listener, pid: pid}
  end

  def stop(server) do
    :gen_tcp.close(server.listener)
    Process.unlink(server.pid)
    monitor = Process.monitor(server.pid)
    Process.exit(server.pid, :shutdown)

    receive do
      {:DOWN, ^monitor, :process, _, _} -> :ok
    after
      5_000 -> raise "loopback fixture did not stop"
    end
  end

  defp accept(listener, handler, owner, index) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        request = read_request(socket, "")
        send(owner, {:http_request, index, request})
        handler.(socket, request, index)
        :gen_tcp.close(socket)
        accept(listener, handler, owner, index + 1)

      {:error, :closed} ->
        :ok
    end
  end

  defp read_request(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [head, rest] ->
        [line | headers] = String.split(head, "\r\n")

        headers =
          Map.new(headers, fn entry ->
            [key, value] = String.split(entry, ":", parts: 2)
            {String.downcase(key), String.trim(value)}
          end)

        length = String.to_integer(headers["content-length"] || "0")
        body = read_body(socket, rest, length)
        [method, path, _] = String.split(line, " ")
        %{method: method, path: path, headers: headers, body: body}

      [_] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        read_request(socket, buffer <> data)
    end
  end

  defp read_body(_socket, body, length) when byte_size(body) >= length,
    do: binary_part(body, 0, length)

  defp read_body(socket, body, length) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    read_body(socket, body <> data, length)
  end

  def respond(socket, status, body, headers \\ []) do
    header = Enum.map_join(headers, "", fn {k, v} -> "#{k}: #{v}\r\n" end)

    :gen_tcp.send(
      socket,
      "HTTP/1.1 #{status} Fixture\r\nconnection: close\r\ncontent-length: #{byte_size(body)}\r\n#{header}\r\n#{body}"
    )
  end

  def stream(socket, chunks) do
    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 200 OK\r\nconnection: close\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n"
      )

    Enum.each(chunks, fn chunk ->
      :gen_tcp.send(socket, [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"])
    end)

    :gen_tcp.send(socket, "0\r\n\r\n")
  end

  def sse(data), do: "data: " <> Jason.encode!(data) <> "\n\n"

  def event(type, data),
    do: "event: #{type}\ndata: " <> Jason.encode!(Map.put(data, "type", type)) <> "\n\n"
end
