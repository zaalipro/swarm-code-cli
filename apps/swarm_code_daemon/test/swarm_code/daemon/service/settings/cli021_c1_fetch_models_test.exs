defmodule SwarmCode.Daemon.Service.Settings.Cli021C1FetchModelsTest do
  @moduledoc """
  cli021 C1: the owner's gateway renamed its models (`ms/glm-5.2`, `nv/glm-5.3`)
  and a fetch from Settings left the old list in place. The reproduction runs
  the same daemon task the settings screen starts (`provider.fetch_models` and
  `provider.fetch_all`) through the terminal's reducer, the real service
  socket and the persisted backend, against a loopback `/v1/models`.
  """
  use ExUnit.Case, async: false

  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0]

  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Engine, Providers, UIState}
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCode.Test.C74S2
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP
  alias SwarmCodeCLI.UI.{DataSource, Reducer, Size}
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Request}
  alias SwarmCodeCLI.UI.Reducer.Settings.{Ops, Responses}
  alias SwarmCodeCLI.UI.Settings.{Nav, Page}
  alias SwarmCodeCLI.UI.Settings.Sections.Providers, as: ProvidersPage

  @moduletag timeout: 120_000
  @renamed ["ms/glm-5.2", "ms/deepseek-v4.1flash", "nv/glm-5.3", "plain-model"]

  setup do
    fx = C74S2.repo!("cli021-c1")
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
    nonce = String.duplicate("F", 43)

    start_supervised!(
      {SwarmCode.Daemon.Service,
       socket_path: path, nonce: nonce, source_epoch: epoch, backend: backend}
    )

    {:ok, client} =
      DataSource.Daemon.start_link(socket_path: path, nonce: nonce, source_epoch: epoch)

    assert {:ok, "c1"} = DataSource.bind_owner(client, self(), "c1")

    prior = Application.get_env(:swarm_code_daemon, :llm_providers)

    Application.put_env(:swarm_code_daemon, :llm_providers, %{
      "openai_compatible" => SwarmCode.Domain.LLM.OpenAI
    })

    on_exit(fn ->
      if prior,
        do: Application.put_env(:swarm_code_daemon, :llm_providers, prior),
        else: Application.delete_env(:swarm_code_daemon, :llm_providers)
    end)

    server =
      HTTP.start(fn socket, _request, _n ->
        body = Jason.encode!(%{"data" => Enum.map(@renamed, &%{"id" => &1})})
        HTTP.respond(socket, 200, body, [{"content-type", "application/json"}])
      end)

    on_exit(fn -> HTTP.stop(server) end)

    {:ok, _} =
      Providers.update(data.deepseek, %{
        base_url: server.url <> "/v1",
        models: ["ms/glm-5.1", "old-model"]
      })

    Map.merge(data, %{client: client, backend: backend})
  end

  test "fetching one provider saves the renamed ids and says what changed", c do
    id = c.deepseek.id
    watch = shell_watch(c.backend)

    state =
      open_provider(c, id)
      |> Ops.run([{:task, "provider.fetch_models", %{"id" => id}, %{}}])
      |> serve(c.client)
      |> settle(watch, c.client)

    assert Providers.get(id).models == Enum.sort(@renamed)
    task = only_task(state, "provider.fetch_models")
    assert task["state"] in ["done", :done]
    assert task["summary"]["words"] == "4 models · 4 new · 2 removed"
    assert task["summary"]["saved"] == true

    # The open page learns of the saved list by itself (the providers change
    # reaches the shell watch as a settings update) and shows the new ids.
    state =
      refresh_until(state, watch, c.client, fn state ->
        row = Enum.find(Nav.rows(state), &(&1.id == "fld:provider:#{id}:models"))
        row != nil and Enum.any?(row.lines, &(inspect(&1) =~ "ms/glm-5.2"))
      end)

    assert Enum.find(Nav.rows(state), &(&1.id == "fld:provider:#{id}:models"))
  end

  test "a gateway list over 2 000 is added up to the ceiling, never replaced", c do
    id = c.deepseek.id
    watch = shell_watch(c.backend)
    big = for n <- 1..2_500, do: "gw/model-#{String.pad_leading(Integer.to_string(n), 4, "0")}"

    server =
      HTTP.start(fn socket, _request, _n ->
        body = Jason.encode!(%{"data" => Enum.map(big, &%{"id" => &1})})
        HTTP.respond(socket, 200, body, [{"content-type", "application/json"}])
      end)

    on_exit(fn -> HTTP.stop(server) end)
    {:ok, _} = Providers.update(Providers.get(id), %{base_url: server.url <> "/v1"})

    state =
      open_provider(c, id)
      |> Ops.run([{:task, "provider.fetch_models", %{"id" => id}, %{}}])
      |> serve(c.client)
      |> settle(watch, c.client)

    stored = Providers.get(id).models
    assert length(stored) == 2_000
    assert Enum.take(stored, 2) == ["ms/glm-5.1", "old-model"]

    assert only_task(state, "provider.fetch_models")["summary"]["words"] ==
             "2500 models · 2000 new · 2000 of 2500 kept"
  end

  test "fetching every provider saves each list and names the result per provider", c do
    watch = shell_watch(c.backend)

    state =
      %{sized(ready(), 160, 45) | now: System.system_time(:millisecond)}
      |> Reducer.update({:settings_open, {:section, :providers}})
      |> serve(c.client)
      |> Ops.run([{:task, "provider.fetch_all", nil, %{}}])
      |> serve(c.client)
      |> settle(watch, c.client)

    assert Providers.get(c.deepseek.id).models == Enum.sort(@renamed)
    task = only_task(state, "provider.fetch_all")
    row = Enum.find(task["summary"]["providers"], &(&1["id"] == c.deepseek.id))
    assert row["state"] == "done" and row["saved"] == true
    assert row["message"] == "4 models · 4 new · 2 removed"
    assert task["summary"]["saved"] >= 1
  end

  test "apply none keeps the preview: nothing is written until apply_models", c do
    id = c.deepseek.id
    watch = shell_watch(c.backend)

    state =
      open_provider(c, id)
      |> Ops.run([{:task, "provider.fetch_models", %{"id" => id}, %{"apply" => "none"}}])
      |> serve(c.client)
      |> settle(watch, c.client)

    assert Providers.get(id).models == ["ms/glm-5.1", "old-model"]
    assert only_task(state, "provider.fetch_models")["summary"]["saved"] == false

    row = Enum.find(Nav.rows(state), &(&1.id == "fld:provider:#{id}:models"))
    state = state |> Ops.run(ProvidersPage.act(Nav.ctx(state), row, :add)) |> serve(c.client)
    assert Providers.get(id).models == Enum.sort(@renamed)
    assert state.settings.status.text == "Applied the fetched list"
  end

  test "apply add keeps hand-added models and a second fetch says no change", c do
    id = c.deepseek.id
    watch = shell_watch(c.backend)

    state =
      open_provider(c, id)
      |> Ops.run([{:task, "provider.fetch_models", %{"id" => id}, %{"apply" => "add"}}])
      |> serve(c.client)
      |> settle(watch, c.client)

    assert Providers.get(id).models == ["ms/glm-5.1", "old-model"] ++ Enum.sort(@renamed)
    assert only_task(state, "provider.fetch_models")["summary"]["words"] == "4 models · 4 new"
    {:ok, _} = Providers.update(Providers.get(id), %{models: Enum.sort(@renamed)})

    state =
      %{state | settings: %{state.settings | tasks: %{}}}
      |> Ops.run([{:task, "provider.fetch_models", %{"id" => id}, %{}}])
      |> serve(c.client)
      |> settle(watch, c.client)

    assert only_task(state, "provider.fetch_models")["summary"]["words"] ==
             "4 models · no change"
  end

  test "a refused key leaves the list alone and the task says why", c do
    id = c.deepseek.id
    watch = shell_watch(c.backend)

    refused =
      HTTP.start(fn socket, _request, _n ->
        HTTP.respond(socket, 401, ~s({"error":{"message":"bad key"}}), [
          {"content-type", "application/json"}
        ])
      end)

    on_exit(fn -> HTTP.stop(refused) end)
    {:ok, _} = Providers.update(Providers.get(id), %{base_url: refused.url <> "/v1"})

    state =
      open_provider(c, id)
      |> Ops.run([{:task, "provider.fetch_models", %{"id" => id}, %{}}])
      |> serve(c.client)
      |> settle(watch, c.client)

    assert Providers.get(id).models == ["ms/glm-5.1", "old-model"]
    task = only_task(state, "provider.fetch_models")
    assert task["state"] in ["failed", :failed]
    assert task["message"] =~ "Unauthorized (401)"
  end

  # ---------------------------------------------------------------- driving

  defp only_task(state, action) do
    [task] = for {_id, t} <- state.settings.tasks, t["action"] == action, do: t
    task
  end

  defp open_provider(c, id) do
    %{sized(ready(), 160, 45) | now: System.system_time(:millisecond)}
    |> Reducer.update({:settings_open, {:section, :providers}})
    |> serve(c.client)
    |> Ops.run([{:open, %Page{section: :providers, record: {"provider", id}}}])
    |> serve(c.client)
  end

  # Feeds shell-watch deltas to the reducer until the page satisfies `done?`.
  defp refresh_until(state, ref, client, done?) do
    if done?.(state) do
      state
    else
      receive do
        {:service_delta, backend, ^ref, delta} ->
          send(backend, {:service_credit, self(), ref, delta["sequence"]})
          {:ok, decoded} = DataSource.Delta.decode(delta)

          decoded.body
          |> then(&Responses.delta(state, &1))
          |> serve(client)
          |> refresh_until(ref, client, done?)
      after
        5_000 -> flunk("the page never showed the saved list")
      end
    end
  end

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

  # Feeds the shell watch's task deltas to the reducer until no task runs.
  defp settle(state, ref, client) do
    running? = fn s ->
      Enum.any?(Map.values(s.settings.tasks), &(&1["state"] in ["running", :running]))
    end

    if running?.(state) or map_size(state.settings.tasks) == 0 do
      receive do
        {:service_delta, backend, ^ref, delta} ->
          send(backend, {:service_credit, self(), ref, delta["sequence"]})
          {:ok, decoded} = DataSource.Delta.decode(delta)
          {state, effects} = Responses.delta(state, decoded.body)
          {state, effects} |> serve(client) |> settle(ref, client)
      after
        15_000 -> flunk("the task never ended: #{inspect(state.settings.tasks)}")
      end
    else
      state
    end
  end

  defp sized(state, columns, rows),
    do: elem(Reducer.update(state, {:resize, %Size{columns: columns, rows: rows}}), 0)

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
end
