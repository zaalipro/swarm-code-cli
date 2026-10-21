defmodule SwarmCodeCLI.Test.AcpPipe do
  @moduledoc """
  Two in-memory IO devices for driving `SwarmCodeCLI.Release.Acp.loop/2`:
  a pipe the test writes to and a sink it reads from.

  The pipe answers the IO protocol's `get_until` the way an IO server does: the
  callback is fed the data there is, a chunk at a time, until it is done;
  `served/1` counts the reads asked of it. The sink sends every complete JSON
  line written to it to `test` as `{:acp_out, map}`; with `block: true` its first
  write waits for `:release` (a client that does not read).
  """

  @chunk 65_536

  def pipe do
    spawn_link(fn -> pipe_loop(%{buffer: "", waiting: nil, eof?: false, served: 0}) end)
  end

  def push(pipe, object), do: send(pipe, {:push, Jason.encode!(object) <> "\n"})
  def push_raw(pipe, binary), do: send(pipe, {:push, binary})
  def eof(pipe), do: send(pipe, :eof)

  def served(pipe) do
    send(pipe, {:served, self()})

    receive do
      {:served, count} -> count
    after
      2_000 -> raise "the pipe did not answer"
    end
  end

  defp pipe_loop(state) do
    state = feed(state)

    receive do
      {:push, data} ->
        pipe_loop(%{state | buffer: state.buffer <> data})

      :eof ->
        pipe_loop(%{state | eof?: true})

      {:served, from} ->
        send(from, {:served, state.served})
        pipe_loop(state)

      {:io_request, from, ref, {:get_until, _encoding, _prompt, m, f, args}} ->
        pipe_loop(%{state | waiting: {from, ref, m, f, args, []}, served: state.served + 1})

      {:io_request, from, ref, _other} ->
        send(from, {:io_reply, ref, {:error, :enotsup}})
        pipe_loop(state)
    end
  end

  # Gives a waiting reader the data there is (one chunk per call) until its callback is done.
  defp feed(%{waiting: nil} = state), do: state

  defp feed(%{waiting: {from, ref, m, f, args, cb}} = state) do
    cond do
      state.buffer != "" ->
        size = min(byte_size(state.buffer), @chunk)
        <<chunk::binary-size(size), rest::binary>> = state.buffer
        step(state, {from, ref, m, f, args}, apply(m, f, [cb, chunk | args]), rest)

      state.eof? ->
        step(state, {from, ref, m, f, args}, apply(m, f, [cb, :eof | args]), "")

      true ->
        state
    end
  end

  defp step(state, {from, ref, _m, _f, _args}, {:done, result, rest}, remaining) do
    send(from, {:io_reply, ref, result})
    leftover = if rest == :eof, do: "", else: IO.chardata_to_string(rest)
    feed(%{state | waiting: nil, buffer: leftover <> remaining})
  end

  defp step(state, {from, ref, m, f, args}, {:more, cb}, remaining),
    do: feed(%{state | waiting: {from, ref, m, f, args, cb}, buffer: remaining})

  def sink(test, opts \\ []) do
    spawn_link(fn -> sink_loop(test, "", Keyword.get(opts, :block, false)) end)
  end

  defp sink_loop(test, buffer, block?) do
    receive do
      {:io_request, from, ref, {:put_chars, _encoding, chars}} ->
        if block? do
          send(test, {:sink_blocked, self()})
          receive do: (:release -> :ok)
        end

        text = buffer <> IO.chardata_to_string(chars)
        parts = String.split(text, "\n")

        for line <- Enum.drop(parts, -1),
            line != "",
            do: send(test, {:acp_out, Jason.decode!(line)})

        send(from, {:io_reply, ref, :ok})
        sink_loop(test, List.last(parts), false)

      {:io_request, from, ref, _other} ->
        send(from, {:io_reply, ref, {:error, :enotsup}})
        sink_loop(test, buffer, block?)
    end
  end
end
