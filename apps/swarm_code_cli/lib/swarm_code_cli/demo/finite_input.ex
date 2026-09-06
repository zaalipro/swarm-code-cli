defmodule SwarmCodeCLI.Demo.FiniteInput do
  @moduledoc "One released synthetic line at a time, exposed as a bounded Erlang IO device."
  use GenServer
  @derive {Inspect, only: []}
  defstruct line: "",
            waiter: nil,
            waiter_monitor: nil,
            eof?: false,
            max_lines: 100,
            max_bytes: 16_385,
            lines: 0

  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options)
  def device(server), do: server
  def release_line(server, line), do: GenServer.call(server, {:line, line})
  def eof(server), do: GenServer.call(server, :eof)

  @impl true
  def init(options) do
    state = struct!(__MODULE__, options)

    if is_integer(state.max_lines) and state.max_lines in 1..1000 and
         is_integer(state.max_bytes) and state.max_bytes in 1..16_385,
       do: {:ok, state},
       else: {:stop, :invalid_input_limits}
  end

  @impl true
  def handle_call({:line, line}, _from, state) do
    cond do
      state.eof? ->
        {:reply, {:error, :closed}, state}

      state.line != "" ->
        {:reply, {:error, :busy}, state}

      state.lines >= state.max_lines ->
        {:reply, {:error, :capacity_exceeded}, state}

      not is_binary(line) or byte_size(line) > state.max_bytes or not String.valid?(line) ->
        {:reply, {:error, :invalid_line}, state}

      not String.ends_with?(line, "\n") or
          String.contains?(binary_part(line, 0, byte_size(line) - 1), "\n") ->
        {:reply, {:error, :invalid_line}, state}

      true ->
        {:reply, :ok, deliver(%{state | line: line, lines: state.lines + 1})}
    end
  end

  def handle_call(:eof, _from, state), do: {:reply, :ok, deliver(%{state | eof?: true})}

  @impl true
  def handle_info({:io_request, from, ref, {:get_chars, :unicode, _prompt, 1}}, state) do
    if state.waiter do
      send(from, {:io_reply, ref, {:error, :busy}})
      {:noreply, state}
    else
      {:noreply, deliver(%{state | waiter: {from, ref}, waiter_monitor: Process.monitor(from)})}
    end
  end

  def handle_info({:io_request, from, ref, _}, state) do
    send(from, {:io_reply, ref, {:error, :enotsup}})
    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, _},
        %{waiter: {pid, _}, waiter_monitor: monitor} = state
      ),
      do: {:noreply, %{state | waiter: nil, waiter_monitor: nil}}

  def handle_info(_, state), do: {:noreply, state}

  defp deliver(%{waiter: nil} = state), do: state
  defp deliver(%{line: "", eof?: false} = state), do: state

  defp deliver(%{line: "", eof?: true, waiter: {from, ref}} = state) do
    send(from, {:io_reply, ref, :eof})
    clear_waiter(state)
  end

  defp deliver(%{waiter: {from, ref}} = state) do
    {character, rest} = String.next_codepoint(state.line)
    send(from, {:io_reply, ref, character})
    clear_waiter(%{state | line: rest})
  end

  defp clear_waiter(state) do
    if state.waiter_monitor, do: Process.demonitor(state.waiter_monitor, [:flush])
    %{state | waiter: nil, waiter_monitor: nil}
  end

  @impl true
  def format_status(status),
    do: %{status | state: :redacted, message: :redacted, reason: :redacted, log: []}
end
