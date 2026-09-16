defmodule SwarmCodeCLI.Companion.Server do
  @moduledoc """
  Loopback HTTP for the companion page on OTP's own `httpd`; no hex packages.

  Binds 127.0.0.1 on a random port, mints a 32-byte url-safe token and serves
  every route under `/c/<token>/`. The token is compared in constant time and
  any other path answers an empty 404. `/events` streams server-sent events as
  HTTP/1.1 chunks straight from the request handler process, so no
  `erl_script_timeout` applies; a client that is not HTTP/1.1 gets a 404 there
  and the page falls back to polling `/view`.
  """
  use GenServer

  @max_body 65_536
  @ping_ms 15_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "The base URL, token included; never log it."
  @spec url(GenServer.server()) :: String.t()
  def url(server), do: GenServer.call(server, :url)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    hub = Keyword.fetch!(opts, :hub)
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    root = String.to_charlist(System.tmp_dir!())

    config = [
      server_name: ~c"swarm-companion",
      server_root: root,
      document_root: root,
      bind_address: {127, 0, 0, 1},
      ipfamily: :inet,
      port: Keyword.get(opts, :port, 0),
      modules: [SwarmCodeCLI.Companion.Server.Handler],
      max_body_size: @max_body,
      max_header_size: 16_384,
      max_keep_alive_request: 100_000,
      keep_alive_timeout: 75,
      server_tokens: :none,
      companion: %{
        token: token,
        hub: hub,
        ping_ms: Keyword.get(opts, :ping_ms, @ping_ms),
        index: Keyword.get(opts, :index)
      }
    ]

    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, sup} <- :inets.start(:httpd, config, :stand_alone),
         {:ok, port} <- bound_port(sup) do
      {:ok, %{sup: sup, port: port, token: token}}
    else
      {:error, reason} -> {:stop, {:httpd, reason}}
    end
  end

  @impl true
  def handle_call(:url, _from, state),
    do: {:reply, "http://127.0.0.1:#{state.port}/c/#{state.token}", state}

  # The only links are the owner and the listener; either one going away ends
  # the server, and `terminate/2` releases the port in both cases.
  @impl true
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}
  def handle_info(_message, state), do: {:noreply, state}

  # Stopping httpd is asynchronous end to end: the supervisor goes down first
  # and the process holding the listen socket only afterwards. "Stopped" here
  # means the port refuses connections again, bounded so a wedged listener
  # cannot hold the session's shutdown.
  @impl true
  def terminate(_reason, %{sup: sup, port: port}) do
    if Process.alive?(sup) do
      monitor = Process.monitor(sup)
      :inets.stop(:stand_alone, sup)

      receive do
        {:DOWN, ^monitor, :process, ^sup, _} -> :ok
      after
        5_000 -> :ok
      end

      await_release(port, 50)
    end

    :ok
  catch
    _, _ -> :ok
  end

  defp await_release(_port, 0), do: :ok

  defp await_release(port, attempts) do
    case :gen_tcp.connect({127, 0, 0, 1}, port, [active: false], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        Process.sleep(20)
        await_release(port, attempts - 1)

      {:error, _} ->
        :ok
    end
  end

  # With `port: 0` httpd names the instance after the port it really bound.
  defp bound_port(sup) do
    Enum.find_value(Supervisor.which_children(sup), {:error, :port_unknown}, fn
      {{:httpd_instance_sup, _address, port, _profile}, _, _, _} -> {:ok, port}
      _ -> nil
    end)
  end

  defmodule Handler do
    @moduledoc false
    require Record
    Record.defrecordp(:mod, Record.extract(:mod, from_lib: "inets/include/httpd.hrl"))

    alias SwarmCodeCLI.Companion.Hub

    @max_body 65_536
    @routes ["/", "/view", "/events", "/focus", "/act"]
    @source_index Path.expand("../../../priv/companion/index.html", __DIR__)
    @placeholder "<!doctype html><meta charset=\"utf-8\"><title>SwarmCode companion</title>" <>
                   "<p>Companion page not installed yet.</p>\n"

    # `do` is a keyword in Elixir, hence the unquote; httpd calls `Module:do/1`.
    def unquote(:do)(data) do
      companion = :httpd_util.lookup(mod(data, :config_db), :companion)

      try do
        handle(data, companion)
      rescue
        _ -> respond(500, nil, "")
      catch
        :exit, _ -> respond(503, nil, "")
      end
    end

    defp handle(data, %{token: token} = companion) do
      method = to_string(mod(data, :method))
      {path, query} = split_uri(to_string(mod(data, :request_uri)))

      with "/c/" <> rest <- path,
           {given, subpath} <- split_token(rest),
           true <- token?(given, token) do
        route(method, subpath, query, data, companion)
      else
        _ -> not_found()
      end
    end

    defp split_uri(uri) do
      case :binary.split(uri, "?") do
        [path] -> {path, ""}
        [path, query] -> {path, query}
      end
    end

    defp split_token(rest) do
      case :binary.split(rest, "/") do
        [token] -> {token, ""}
        [token, more] -> {token, "/" <> more}
      end
    end

    defp token?(given, token),
      do: byte_size(given) == byte_size(token) and :crypto.hash_equals(given, token)

    # Relative fetches on the page need the trailing slash to resolve.
    defp route("GET", "", _query, _data, %{token: token}) do
      headers = [code: 302, location: ~c"/c/#{token}/", cache_control: ~c"no-store"]
      {:proceed, [{:response, {:response, headers ++ [content_length: ~c"0"], ""}}]}
    end

    defp route("GET", "/", _query, _data, companion),
      do: respond(200, "text/html; charset=utf-8", index(companion))

    defp route("GET", "/view", query, _data, %{hub: hub}) do
      since = query |> URI.decode_query() |> Map.get("since") |> integer()
      result = if since, do: Hub.view_since(hub, since), else: Hub.view(hub)

      case result do
        :unchanged -> respond(204, nil, "")
        {:ok, _revision, json} -> respond(200, "application/json", json)
      end
    end

    defp route("GET", "/events", _query, data, %{hub: hub, ping_ms: ping_ms}),
      do: stream(data, hub, ping_ms)

    defp route("POST", "/focus", _query, data, %{hub: hub}) do
      with {:ok, body} <- body(data),
           {:ok, %{"kind" => kind} = params} when is_binary(kind) <- Jason.decode(body) do
        case Hub.focus(hub, kind, Map.get(params, "id")) do
          :ok -> respond(204, nil, "")
          {:error, :invalid} -> respond(400, nil, "")
          {:error, :unsupported} -> respond(501, nil, "")
          {:error, :unavailable} -> respond(503, nil, "")
        end
      else
        {:error, :too_large} -> respond(413, nil, "")
        _ -> respond(400, nil, "")
      end
    end

    defp route("POST", "/act", _query, data, _companion) do
      case body(data) do
        {:ok, _} -> respond(501, nil, "")
        {:error, :too_large} -> respond(413, nil, "")
      end
    end

    defp route(_method, path, _query, _data, _companion) when path in @routes,
      do: respond(405, nil, "")

    defp route(_method, _path, _query, _data, _companion), do: not_found()

    defp not_found, do: respond(404, nil, "")

    defp respond(code, type, body) do
      headers =
        [code: code, cache_control: ~c"no-store"] ++
          if(type, do: [content_type: String.to_charlist(type)], else: []) ++
          if(code in [204, 304],
            do: [],
            else: [content_length: Integer.to_charlist(byte_size(body))]
          )

      {:proceed, [{:response, {:response, headers, body}}]}
    end

    defp body(data) do
      body =
        case mod(data, :entity_body) do
          value when is_binary(value) or is_list(value) -> IO.iodata_to_binary(value)
          _ -> ""
        end

      if byte_size(body) > @max_body, do: {:error, :too_large}, else: {:ok, body}
    end

    defp integer(nil), do: nil

    defp integer(text) do
      case Integer.parse(text) do
        {value, ""} when value >= 0 -> value
        _ -> nil
      end
    end

    # The page another agent ships in priv; until it exists, one honest line.
    defp index(%{index: override}) do
      [override, app_index(), @source_index]
      |> Enum.reject(&is_nil/1)
      |> Enum.find_value(@placeholder, fn path ->
        case File.read(path) do
          {:ok, html} -> html
          _ -> nil
        end
      end)
    end

    defp app_index do
      Application.app_dir(:swarm_code_cli, "priv/companion/index.html")
    rescue
      _ -> nil
    end

    # Server-sent events written as HTTP/1.1 chunks from this request handler
    # process. The socket is switched to active-once so a client that goes away
    # ends the loop at once instead of at the next ping.
    defp stream(data, hub, ping_ms) do
      if to_string(mod(data, :http_version)) == "HTTP/1.1" do
        {:ok, _revision, json} = Hub.subscribe(hub)

        headers = [
          {~c"content-type", ~c"text/event-stream"},
          {~c"cache-control", ~c"no-store"},
          {~c"transfer-encoding", ~c"chunked"},
          {~c"x-accel-buffering", ~c"no"}
        ]

        socket = mod(data, :socket)

        with :ok <- :httpd_response.send_header(data, 200, headers),
             :ok <- chunk(data, event("view", json)) do
          :inet.setopts(socket, active: :once)
          loop(data, socket, ping_ms)
        end

        Hub.unsubscribe(hub)
        drain()
        {:proceed, [{:response, {:already_sent, 200, 0}}]}
      else
        not_found()
      end
    end

    defp loop(data, socket, ping_ms) do
      receive do
        {:companion_view, _revision, json} ->
          continue(chunk(data, event("view", json)), data, socket, ping_ms)

        {:tcp_closed, ^socket} ->
          :closed

        {:tcp_error, ^socket, _reason} ->
          :closed

        {:tcp, ^socket, _ignored} ->
          :inet.setopts(socket, active: :once)
          loop(data, socket, ping_ms)
      after
        ping_ms -> continue(chunk(data, "event: ping\ndata: {}\n\n"), data, socket, ping_ms)
      end
    end

    defp continue(:ok, data, socket, ping_ms), do: loop(data, socket, ping_ms)
    defp continue(_closed, _data, _socket, _ping_ms), do: :closed

    defp chunk(data, payload),
      do: :httpd_response.send_chunk(data, IO.iodata_to_binary(payload), false)

    defp event(name, json), do: ["event: ", name, "\ndata: ", json, "\n\n"]

    defp drain do
      receive do
        {:companion_view, _, _} -> drain()
      after
        0 -> :ok
      end
    end
  end
end
