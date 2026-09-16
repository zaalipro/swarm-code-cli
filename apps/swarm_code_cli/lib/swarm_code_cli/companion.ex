defmodule SwarmCodeCLI.Companion do
  @moduledoc """
  The visual companion: a loopback web page that mirrors the session live.

  One process per session, registered as `SwarmCodeCLI.Companion` so the
  runtime can ask for the URL without holding a pid. It owns a `Hub` (the
  view) and a `Server` (`:inets` httpd). With `SWARM_COMPANION=0`, or when the
  listener cannot start, it runs disabled and answers `:unavailable`; a crash
  in either child degrades it the same way instead of ending the session.

  The URL carries the one-time token, so it is only ever handed out through
  `url/1`; nothing here prints it.
  """
  use GenServer

  alias SwarmCodeCLI.Companion.{Hub, Server}

  @name __MODULE__
  @open_wait_ms 1_000

  @doc """
  Options: `runtime:` (pid or nil, attachable later), `port:` (default 0, a
  random port), `enabled?:` (default: `SWARM_COMPANION` is not `"0"`),
  `project:` (header display name), `name:` (registration; `nil` for none) and
  `opener:` (a `url -> :ok | {:error, term}` function; default `open` on macOS,
  `xdg-open` elsewhere).
  """
  def start_link(opts) do
    case Keyword.get(opts, :name, @name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec url(GenServer.server()) :: {:ok, String.t()} | :unavailable
  def url(server \\ @name) do
    GenServer.call(server, :url)
  catch
    :exit, _ -> :unavailable
  end

  @doc "The process the runtime should send `{:companion_state, ui}` to, or nil when disabled."
  @spec sink(GenServer.server()) :: pid() | nil
  def sink(server \\ @name) do
    GenServer.call(server, :sink)
  catch
    :exit, _ -> nil
  end

  @doc "Opens the page in the user's browser; never blocks the caller beyond one second."
  @spec open(GenServer.server()) :: :ok | {:error, term()}
  def open(server \\ @name) do
    case GenServer.call(server, :opener) do
      {:ok, url, opener} -> launch(opener, url)
      :unavailable -> {:error, :unavailable}
    end
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    enabled? = Keyword.get(opts, :enabled?, System.get_env("SWARM_COMPANION") != "0")

    state = %{
      hub: nil,
      server: nil,
      url: nil,
      reason: :disabled,
      opener: Keyword.get(opts, :opener, &__MODULE__.default_opener/1)
    }

    {:ok, if(enabled?, do: start_children(state, opts), else: state)}
  end

  @impl true
  def handle_call(:url, _from, %{url: nil} = state), do: {:reply, :unavailable, state}
  def handle_call(:url, _from, state), do: {:reply, {:ok, state.url}, state}
  def handle_call(:sink, _from, state), do: {:reply, state.hub, state}
  def handle_call(:opener, _from, %{url: nil} = state), do: {:reply, :unavailable, state}

  def handle_call(:opener, _from, state),
    do: {:reply, {:ok, state.url, state.opener}, state}

  @impl true
  def handle_info({:EXIT, pid, reason}, %{hub: hub, server: server} = state)
      when pid == hub or pid == server do
    other = if pid == hub, do: server, else: hub
    if other && Process.alive?(other), do: Process.exit(other, :shutdown)
    {:noreply, %{state | hub: nil, server: nil, url: nil, reason: {:crashed, reason}}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    for pid <- [state.server, state.hub], pid != nil, Process.alive?(pid) do
      safe(fn -> GenServer.stop(pid, :shutdown, 5_000) end)
    end

    :ok
  end

  defp start_children(state, opts) do
    with {:ok, hub} <-
           Hub.start_link(
             runtime: Keyword.get(opts, :runtime),
             project: Keyword.get(opts, :project),
             started_at: Keyword.get(opts, :started_at, System.system_time(:millisecond))
           ),
         {:ok, server} <- start_server(hub, opts) do
      %{state | hub: hub, server: server, url: Server.url(server), reason: nil}
    else
      {:error, reason} -> %{state | reason: reason}
    end
  end

  defp start_server(hub, opts) do
    server_opts =
      opts
      |> Keyword.take([:port, :ping_ms, :index])
      |> Keyword.put(:hub, hub)

    case Server.start_link(server_opts) do
      {:ok, server} ->
        {:ok, server}

      {:error, reason} ->
        safe(fn -> GenServer.stop(hub, :shutdown, 5_000) end)
        {:error, reason}
    end
  end

  # The opener runs in its own unlinked process: a browser that misbehaves can
  # neither block nor crash the session runtime that asked.
  defp launch(opener, url) do
    parent = self()
    ref = make_ref()

    {:ok, _} =
      Task.start(fn ->
        result =
          try do
            opener.(url)
          rescue
            error -> {:error, error}
          catch
            :exit, reason -> {:error, reason}
          end

        send(parent, {ref, result})
      end)

    receive do
      {^ref, :ok} -> :ok
      {^ref, {:error, reason}} -> {:error, reason}
      {^ref, _other} -> :ok
    after
      @open_wait_ms -> :ok
    end
  end

  @doc false
  def default_opener(url) do
    command = if match?({:unix, :darwin}, :os.type()), do: "open", else: "xdg-open"

    case System.find_executable(command) do
      nil ->
        {:error, :no_opener}

      path ->
        case System.cmd(path, [url], stderr_to_stdout: true) do
          {_, 0} -> :ok
          {_, status} -> {:error, {:exit_status, status}}
        end
    end
  end

  defp safe(fun) do
    fun.()
  catch
    _, _ -> :ok
  end
end
