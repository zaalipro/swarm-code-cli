defmodule SwarmCodeCLI.Companion.ServerTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Companion.{Hub, Server}
  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Size}

  defmodule RuntimeStub do
    use GenServer
    def start_link(test), do: GenServer.start_link(__MODULE__, test)
    def init(test), do: {:ok, test}

    def handle_call({:action, action}, _from, test) do
      send(test, {:action, action})
      {:reply, :ok, test}
    end
  end

  @keys ~w(revision session header tabs run agents transcript needs changes timeline verdict artifacts focus notice)
  @size %Size{columns: 100, rows: 30}
  @caps %Capabilities{size: @size}

  setup do
    {:ok, _} = Application.ensure_all_started(:inets)
    hub = start_supervised!({Hub, runtime: nil, interval_ms: 0})
    server = start_supervised!({Server, hub: hub, port: 0, ping_ms: 150})
    %{hub: hub, server: server, url: Server.url(server)}
  end

  defp get(url, http_opts \\ []) do
    {:ok, {{_, status, _}, headers, body}} =
      :httpc.request(:get, {String.to_charlist(url), []}, http_opts, body_format: :binary)

    {status, headers(headers), body}
  end

  defp post(url, body) do
    {:ok, {{_, status, _}, headers, reply}} =
      :httpc.request(
        :post,
        {String.to_charlist(url), [], ~c"application/json", body},
        [],
        body_format: :binary
      )

    {status, headers(headers), reply}
  end

  defp headers(list), do: Map.new(list, fn {k, v} -> {to_string(k), to_string(v)} end)

  test "the URL is loopback with a 43-character url-safe token", %{url: url} do
    assert url =~ ~r"^http://127\.0\.0\.1:\d+/c/[A-Za-z0-9_-]{43}$"
  end

  test "any path without the exact token answers an empty 404", %{url: url} do
    base = String.replace(url, ~r"/c/.*$", "")
    wrong = base <> "/c/" <> String.duplicate("x", 43)
    assert {404, headers, ""} = get(wrong <> "/view")
    assert headers["cache-control"] == "no-store"
    assert {404, _, ""} = get(base <> "/c/short/view")
    assert {404, _, ""} = get(base <> "/view")
    assert {404, _, ""} = get(base <> "/")
    assert {404, _, ""} = get(url <> "/nothing")
  end

  test "/view answers the JSON view with every key and no-store", %{url: url} do
    assert {200, headers, body} = get(url <> "/view")
    assert headers["content-type"] == "application/json"
    assert headers["cache-control"] == "no-store"
    view = Jason.decode!(body)
    assert Enum.sort(Map.keys(view)) == Enum.sort(@keys)
    assert is_integer(view["revision"])
  end

  test "/view?since answers 204 when unchanged and the view when stale", %{url: url, hub: hub} do
    {200, _, body} = get(url <> "/view")
    revision = Jason.decode!(body)["revision"]
    assert {204, _, ""} = get(url <> "/view?since=#{revision}")
    assert {200, _, _} = get(url <> "/view?since=#{revision - 1}")
    assert {200, _, _} = get(url <> "/view?since=nonsense")

    send(hub, {:companion_state, Fixtures.representative(:chat, @size, @caps)})
    assert {200, _, body} = get(url <> "/view?since=#{revision}")
    assert Jason.decode!(body)["revision"] == revision + 1
    assert [%{"id" => "fixture-run"}] = Jason.decode!(body)["tabs"]
  end

  test "/ serves HTML and the slash-less base redirects to it", %{url: url} do
    assert {200, headers, body} = get(url <> "/")
    assert headers["content-type"] =~ ~r"^text/html"
    assert body =~ "<"
    assert {302, headers, ""} = get(url, autoredirect: false)
    assert String.ends_with?(headers["location"], "/c/" <> Path.basename(url) <> "/")
  end

  test "/focus answers 503 without a runtime, then 204 through one", %{url: url, hub: hub} do
    assert {503, _, ""} = post(url <> "/focus", ~s({"kind":"composer"}))
    {:ok, stub} = RuntimeStub.start_link(self())
    :ok = Hub.attach(hub, stub)
    assert {204, _, ""} = post(url <> "/focus", ~s({"kind":"composer"}))
    assert_receive {:action, {:focus_region, "composer"}}
    assert {204, _, ""} = post(url <> "/focus", ~s({"kind":"run","id":"run-1"}))
    assert_receive {:action, {:navigate, {:run, "run-1"}}}
  end

  test "/focus rejects bad bodies, unknown kinds and oversize payloads", %{url: url} do
    assert {400, _, ""} = post(url <> "/focus", "{not json")
    assert {400, _, ""} = post(url <> "/focus", ~s({"id":"x"}))
    assert {400, _, ""} = post(url <> "/focus", ~s({"kind":"run","id":""}))
    assert {501, _, ""} = post(url <> "/focus", ~s({"kind":"verdict","id":"x"}))
    assert {413, _, _} = post(url <> "/focus", String.duplicate("x", 70_000))
  end

  test "/act is not implemented and known routes reject other methods", %{url: url} do
    assert {501, _, ""} = post(url <> "/act", ~s({"action":"approve","id":"x","revision":1}))
    assert {405, _, ""} = post(url <> "/view", "{}")
    assert {405, _, ""} = get(url <> "/focus")
  end

  test "/events streams the view, each change, and keep-alive pings", %{url: url, hub: hub} do
    {:ok, ref} =
      :httpc.request(:get, {String.to_charlist(url <> "/events"), []}, [],
        sync: false,
        stream: :self
      )

    assert_receive {:http, {^ref, :stream_start, headers}}, 2_000
    headers = headers(headers)
    assert headers["content-type"] == "text/event-stream"
    assert headers["cache-control"] == "no-store"

    buffer = collect(ref, "", ~r/event: view\ndata: \{.*"tabs":\[\].*\n\n/s)
    send(hub, {:companion_state, Fixtures.representative(:swarm, @size, @caps)})
    buffer = collect(ref, buffer, ~r/event: view\ndata: \{.*fixture-run.*\n\n/s)
    collect(ref, buffer, ~r/event: ping\ndata: \{\}\n\n/)
    :httpc.cancel_request(ref)
  end

  test "stopping the server frees the port", %{url: url} do
    assert {200, _, _} = get(url <> "/view")
    :ok = stop_supervised!(Server)
    assert {:error, _} = :httpc.request(:get, {String.to_charlist(url <> "/view"), []}, [], [])
  end

  defp collect(ref, buffer, pattern) do
    if buffer =~ pattern do
      buffer
    else
      receive do
        {:http, {^ref, :stream, chunk}} -> collect(ref, buffer <> chunk, pattern)
      after
        2_000 -> flunk("no chunk matching #{inspect(pattern)}; buffer: #{inspect(buffer)}")
      end
    end
  end
end
