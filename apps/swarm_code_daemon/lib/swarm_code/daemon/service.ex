defmodule SwarmCode.Daemon.Service do
  @moduledoc """
  Owned local-service listener for an already admitted backend.

  Starting this component does not open canonical storage or grant foundation
  admission. The caller supplies a private runtime directory and a fresh secret
  nonce, and starts it below the same owner as the admitted backend.
  """
  use GenServer
  import Bitwise
  alias SwarmCode.Daemon.Service.Connection
  alias SwarmCode.Protocol.{Frame, Message, ServiceHandshake}

  def start_link(opts) do
    if validate(opts) == :ok,
      do: GenServer.start_link(__MODULE__, opts),
      else: {:error, :service_unavailable}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with :ok <- validate(opts),
         {:ok, socket} <-
           :gen_tcp.listen(0, [
             :binary,
             {:ifaddr, {:local, opts[:socket_path]}},
             active: false,
             packet: :raw,
             backlog: 16,
             send_timeout: 2000,
             send_timeout_close: true
           ]) do
      case File.lstat(opts[:socket_path]) do
        {:ok, expected} when band(expected.mode, 0o170000) == 0o140000 ->
          case initialize_endpoint(socket, opts, expected) do
            {:ok, _state} = success ->
              success

            _ ->
              :gen_tcp.close(socket)
              cleanup(opts[:socket_path], expected)
              {:stop, {:shutdown, :service_unavailable}}
          end

        _ ->
          :gen_tcp.close(socket)
          {:stop, {:shutdown, :service_unavailable}}
      end
    else
      _ -> {:stop, {:shutdown, :service_unavailable}}
    end
  end

  defp initialize_endpoint(socket, opts, expected) do
    with :ok <- File.chmod(opts[:socket_path], 0o600),
         {:ok, stat} <- File.lstat(opts[:socket_path]),
         true <- same_endpoint?(stat, expected) and band(stat.mode, 0o7777) == 0o600,
         {:ok, clients} <- DynamicSupervisor.start_link(strategy: :one_for_one, max_children: 32) do
      config =
        Map.new(opts)
        |> Map.put_new(:capabilities, [
          :query,
          :detail,
          :watch,
          :conversation_open,
          :conversation_list,
          :conversation_new,
          :mark_seen,
          :project_update,
          :dispatch_send,
          :run_pause,
          :run_continue,
          :run_stop,
          :run_steer,
          :approval_resolve,
          :feature_command,
          :question_answer
        ])

      owner = self()
      acceptor = spawn_link(fn -> accept(socket, clients, config) end)
      # Covers untrappable listener death. Namespace replacement is preserved.
      spawn(fn ->
        ref = Process.monitor(owner)

        receive do
          {:DOWN, ^ref, :process, ^owner, _} -> cleanup(opts[:socket_path], stat)
        end
      end)

      {:ok,
       %{
         socket: socket,
         path: opts[:socket_path],
         stat: stat,
         clients: clients,
         acceptor: acceptor,
         backend_monitor: Process.monitor(opts[:backend])
       }}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, %{backend_monitor: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:EXIT, pid, _}, %{acceptor: pid} = state), do: {:stop, :normal, state}
  def handle_info({:EXIT, pid, _}, %{clients: pid} = state), do: {:stop, :normal, state}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    :gen_tcp.close(state.socket)
    if Process.alive?(state.acceptor), do: Process.exit(state.acceptor, :shutdown)
    if Process.alive?(state.clients), do: Supervisor.stop(state.clients, :normal, 5000)
    cleanup(state.path, state.stat)
  end

  @impl true
  def format_status(status), do: %{status | state: %{status: :listening}}

  defp accept(listener, clients, config) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        case DynamicSupervisor.start_child(clients, {Connection, config}) do
          {:ok, client} ->
            case :gen_tcp.controlling_process(socket, client) do
              :ok ->
                send(client, {:socket, socket})

              _ ->
                :gen_tcp.close(socket)
                DynamicSupervisor.terminate_child(clients, client)
            end

          _ ->
            :gen_tcp.close(socket)
        end

        accept(listener, clients, config)

      _ ->
        :ok
    end
  end

  defp validate(opts) do
    with true <- Keyword.keyword?(opts),
         true <-
           Enum.sort(Keyword.keys(opts)) in [
             Enum.sort([:socket_path, :nonce, :source_epoch, :backend]),
             Enum.sort([:socket_path, :nonce, :source_epoch, :backend, :capabilities])
           ],
         path when is_binary(path) <- opts[:socket_path],
         true <- Path.type(path) == :absolute and byte_size(path) < 104,
         {:error, :enoent} <- File.lstat(path),
         {:ok, %{type: :directory, mode: mode}} <- File.lstat(Path.dirname(path)),
         true <- band(mode, 0o7777) == 0o700,
         true <- is_pid(opts[:backend]) and node(opts[:backend]) == node(),
         {:ok, _} <-
           Frame.encode(%Message{
             version: 1,
             type: :hello,
             request_id: opts[:source_epoch],
             nonce: opts[:nonce],
             scope: nil,
             sequence: nil,
             occurred_at: nil,
             body: ServiceHandshake.hello()
           }) do
      :ok
    else
      _ -> :error
    end
  end

  defp cleanup(path, expected) do
    case File.lstat(path) do
      {:ok, stat} ->
        if same_endpoint?(stat, expected), do: File.rm(path), else: :ok

      _ ->
        :ok
    end
  end

  defp same_endpoint?(stat, expected) do
    band(stat.mode, 0o170000) == 0o140000 and stat.inode == expected.inode and
      stat.major_device == expected.major_device and stat.minor_device == expected.minor_device and
      stat.uid == expected.uid
  end
end
