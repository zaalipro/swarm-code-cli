defmodule SwarmCode.Daemon.Service.Settings.C74ClientE2ETest do
  @moduledoc """
  cli74 F: every settings section end to end — the terminal's reducer and
  sections, its own transport (`DataSource.Daemon`) over the real service
  socket, the persisted backend and the real handlers on the Appendix A
  fixture database. Each section opens, every request the page sends is
  answered by the daemon (never the fake), and the page draws rows with no
  "not available" words, no raw `nil` and no crash.
  """
  use ExUnit.Case, async: false

  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0]

  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Engine, UIState}
  alias SwarmCode.Test.C74S2
  alias SwarmCodeCLI.UI.{Projector, Reducer, SafeText, Size}
  alias SwarmCodeCLI.UI.DataSource
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Request}
  alias SwarmCode.Domain.Providers
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP
  alias SwarmCodeCLI.UI.Reducer.Settings.{Ops, Responses}
  alias SwarmCodeCLI.UI.Settings.{Nav, Page, Row, Sections}
  alias SwarmCodeCLI.UI.Settings.Sections.Providers, as: ProvidersPage

  @moduletag timeout: 180_000
  @out System.get_env("C74_E2E_OUT")

  setup do
    fx = C74S2.repo!("c74-f-e2e")
    unless Process.whereis(UIState), do: start_supervised!(UIState)
    data = C74S2.appendix_a!(fx)
    epoch = Ecto.UUID.generate()

    backend =
      start_supervised!(
        {Backend,
         mode: :persisted,
         repo: SwarmCode.Domain.Repo,
         project_root: data.ailogic.root_path,
         project_id: data.ailogic.id,
         conversation_id: data.conversation.id,
         source_epoch: epoch}
      )

    on_exit(fn -> Engine.stop_all(data.conversation.id) end)

    socket_dir = Path.join(fx.dir, "sock")
    File.mkdir_p!(socket_dir)
    File.chmod!(socket_dir, 0o700)
    path = Path.join(socket_dir, "s")
    nonce = String.duplicate("E", 43)

    start_supervised!(
      {SwarmCode.Daemon.Service,
       socket_path: path, nonce: nonce, source_epoch: epoch, backend: backend}
    )

    {:ok, client} =
      DataSource.Daemon.start_link(socket_path: path, nonce: nonce, source_epoch: epoch)

    assert {:ok, "e2e"} = DataSource.bind_owner(client, self(), "e2e")
    Map.merge(data, %{client: client, fx: fx, backend: backend})
  end

  test "every section opens on the daemon's data and draws its page", c do
    state = sized(ready(), 160, 45)

    {pages, _state} =
      Enum.map_reduce(Sections.all(), state, fn %{id: id}, state ->
        # One session: request ids keep counting across the sections.
        opened =
          %{state | now: System.system_time(:millisecond)}
          |> Reducer.update({:settings_open, {:section, id}})
          |> serve(c.client)

        rows = Nav.rows(opened)
        text = Enum.map_join(rows, "\n", &row_words/1)
        screen = screen(opened)

        assert rows != [], "#{id}: no rows"
        status = opened.settings.status && opened.settings.status.text
        refute status in ["Couldn't read settings right now."], "#{id}: #{status}"
        refute text =~ "not available in this build", "#{id}:\n#{text}"
        refute text =~ "Couldn't read settings", "#{id}:\n#{text}"
        refute screen =~ ~r/\bnil\b/, "#{id}:\n#{screen}"
        {{id, text, screen}, opened}
      end)

    if @out do
      File.mkdir_p!(@out)

      for {id, text, screen} <- pages do
        File.write!(Path.join(@out, "#{id}.rows.txt"), text)
        File.write!(Path.join(@out, "#{id}.screen.txt"), screen)
      end
    end
  end

  # cli74 F12 (A43, found in the sandbox): replacing a stored key sends the
  # command with the pasted bytes and `test_first`; the daemon tests the new
  # key against the endpoint and writes it only when it answers.
  test "a replaced provider key is tested first, then saved", c do
    server =
      HTTP.start(fn socket, _request, _n ->
        body = Jason.encode!(%{"data" => [%{"id" => "stub-a"}, %{"id" => "stub-b"}]})
        HTTP.respond(socket, 200, body, [{"content-type", "application/json"}])
      end)

    prior = Application.get_env(:swarm_code_daemon, :llm_providers)

    Application.put_env(:swarm_code_daemon, :llm_providers, %{
      "openai_compatible" => SwarmCode.Domain.LLM.OpenAI
    })

    on_exit(fn ->
      if prior,
        do: Application.put_env(:swarm_code_daemon, :llm_providers, prior),
        else: Application.delete_env(:swarm_code_daemon, :llm_providers)
    end)

    {:ok, _} = Providers.update(c.deepseek, %{base_url: server.url <> "/v1"})
    key = "sk-e2e-replacement-0000000wxyz"
    id = c.deepseek.id
    watch = shell_watch(c.backend)

    state =
      %{sized(ready(), 160, 45) | now: System.system_time(:millisecond)}
      |> Reducer.update({:settings_open, {:section, :providers}})
      |> serve(c.client)

    state =
      state
      |> Ops.run([{:open, %Page{section: :providers, record: {"provider", id}}}])
      |> serve(c.client)

    state = %{state | capabilities: %{state.capabilities | paste: :supported}}
    row = Enum.find(Nav.rows(state), &(&1.id == "fld:provider:#{id}:api_key"))
    assert %Row{} = row, inspect(Enum.map(Nav.rows(state), & &1.id))
    [{:paste, target}] = ProvidersPage.act(Nav.ctx(state), row, :open_row)
    assert target.set? == true
    {state, _} = Ops.run(state, [{:paste, target}])
    {state, _} = Reducer.update(state, {:settings, {:paste, key}})

    state =
      state
      |> Reducer.update({:settings, {:verb, :paste_commit}})
      |> serve(c.client)

    assert is_binary(state.settings.paste.pending_task), inspect(state.settings.status)
    state = settle_task(state, watch)

    assert state.settings.paste == nil, inspect(state.settings.tasks)
    assert state.settings.status.text == "DeepSeek API key replaced · the new key listed 2 models"
    assert Providers.get(id).api_key == key
    HTTP.stop(server)
  end

  # ---------------------------------------------------------------- driving

  # The session's shell watch, where the service reports its settings tasks.
  defp shell_watch(backend) do
    watch = %ServiceRequest{
      operation: :watch,
      timeout_ms: 1_000,
      params: %{"watch_ref" => "sh", "slot" => "shell", "page_size" => 20, "byte_limit" => 65_536}
    }

    scope = %Scope{kind: :global, id: nil, generation: 1}

    assert {:watch, 0, _, _kind, _body} =
             GenServer.call(backend, {:service_watch, self(), "w-sh", scope, watch})

    send(backend, {:service_ready, self(), "sh"})
    "sh"
  end

  # Feeds the watch's settings deltas to the reducer until the paste's check
  # settles.
  defp settle_task(state, ref) do
    receive do
      {:service_delta, backend, ^ref, delta} ->
        send(backend, {:service_credit, self(), ref, delta["sequence"]})
        {:ok, decoded} = SwarmCodeCLI.UI.DataSource.Delta.decode(delta)
        {state, _effects} = Responses.delta(state, decoded.body)

        case state.settings.paste do
          %{pending_task: task} when is_binary(task) -> settle_task(state, ref)
          _ -> state
        end
    after
      15_000 -> flunk("the key check never ended")
    end
  end

  defp sized(state, columns, rows),
    do: elem(Reducer.update(state, {:resize, %Size{columns: columns, rows: rows}}), 0)

  # Sends every settings request of `effects` through the real transport and
  # feeds the answers back to the reducer, until the page asks for nothing
  # more (bounded: a page settles in a few rounds).
  defp serve({state, effects}, client), do: serve(state, effects, client, 8)

  defp serve(state, _effects, _client, 0), do: state

  defp serve(state, effects, client, rounds) do
    case requests(effects) do
      [] ->
        state

      requests ->
        {state, more} =
          Enum.reduce(requests, {state, []}, fn {kind, request}, {acc, more} ->
            assert :ok = apply(DataSource, kind, [client, request])
            delivery = await(client, request.request_id)
            {acc, next} = Reducer.update(acc, {:data, delivery})
            {acc, more ++ next}
          end)

        serve(state, more, client, rounds - 1)
    end
  end

  defp requests(effects),
    do: for({kind, %Request{} = r} <- effects, kind in [:query, :command], do: {kind, r})

  defp await(client, request_id) do
    receive do
      {:swarm_code_ui_data, _, receipt, %Delivery{request_id: ^request_id} = delivery} ->
        :ok = DataSource.consume(client, receipt, :applied)
        delivery

      {:swarm_code_ui_data, _, receipt, %Delivery{}} ->
        :ok = DataSource.consume(client, receipt, :applied)
        await(client, request_id)

      {:swarm_code_ui_closed, _, reason} ->
        flunk("the data source closed: #{inspect(reason)}")
    after
      15_000 -> flunk("no answer to #{request_id}")
    end
  end

  # ---------------------------------------------------------------- reading

  defp row_words(%Row{} = row) do
    [row.label, words(row.value), words(row.tag)]
    |> Kernel.++(Enum.map(row.lines, &words/1))
    |> Kernel.++(Enum.map(row.columns || [], &elem(&1, 0)))
    |> Enum.join(" ")
  end

  defp words(segments) when is_list(segments),
    do: Enum.map_join(segments, "", fn {text, _} -> to_string(text) end)

  defp words(_), do: ""

  defp screen(state) do
    {scene, _actions} = Projector.project(state)

    scene.regions
    |> Enum.flat_map(& &1.blocks)
    |> Enum.map_join("\n", fn block ->
      Enum.map_join(block.spans, "", &SafeText.value(&1.text))
    end)
  end
end
