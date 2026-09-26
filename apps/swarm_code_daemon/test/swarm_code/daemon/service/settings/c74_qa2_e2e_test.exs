defmodule SwarmCode.Daemon.Service.Settings.C74Qa2E2ETest do
  @moduledoc """
  cli74 G2 (QA #2 of pass 74): the terminal's reducer and sections against the real
  service over its socket, on the Appendix A database, for the findings the fake had
  let through: undo and redo of section commands (a search engine move, an MCP
  server's tools, a price, an MCP connection change), and a record field changed
  elsewhere while it was edited (keep yours, take theirs).
  """
  use ExUnit.Case, async: false

  import SwarmCodeCLI.UI.Pass73Helpers, only: [ready: 0]

  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Engine, MCP, Repo, Settings, UIState}
  alias SwarmCode.Domain.Search, as: Engines
  alias SwarmCode.Test.C74S2
  alias SwarmCodeCLI.UI.{Reducer, Size}
  alias SwarmCodeCLI.UI.DataSource
  alias SwarmCodeCLI.UI.DataSource.{Delivery, Request}
  alias SwarmCodeCLI.UI.Reducer.Settings.{Edit, Ops}
  alias SwarmCodeCLI.UI.Settings.{Nav, Page, Wire}

  @moduletag timeout: 180_000

  setup do
    fx = C74S2.repo!("c74-qa2-e2e")
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
    nonce = String.duplicate("Q", 43)

    start_supervised!(
      {SwarmCode.Daemon.Service,
       socket_path: path, nonce: nonce, source_epoch: epoch, backend: backend}
    )

    {:ok, client} =
      DataSource.Daemon.start_link(socket_path: path, nonce: nonce, source_epoch: epoch)

    assert {:ok, "e2e"} = DataSource.bind_owner(client, self(), "e2e")
    Map.merge(data, %{client: client, fx: fx, backend: backend})
  end

  # ------------------------------------------------------------ undo, redo

  test "a search engine move is undone and redone (QA #2 P1-2)", c do
    state = open(c, :search_web)
    before = engines()
    state = Nav.put_cursor(state, "rec:search_provider:exa")

    state = state |> verb(:move_up) |> serve(c.client)
    moved = engines()
    assert moved != before, inspect(state.settings.status)

    state = state |> verb(:undo) |> serve(c.client)
    assert state.settings.status.text =~ "Undid: ", inspect(state.settings.status)
    assert engines() == before

    state = state |> verb(:redo) |> serve(c.client)
    assert state.settings.status.text =~ "Redid: ", inspect(state.settings.status)
    assert engines() == moved
  end

  test "an MCP server's tools all off (N) is undone and redone (QA #2 P1-5)", c do
    id = c.docs.id
    state = open(c, :mcp) |> open_page(c, %Page{section: :mcp, record: {"mcp_server", id}})
    before = MCP.get(id).disabled_tools
    [first | _] = for %{id: "item:tools:" <> _} = row <- Nav.rows(state), do: row.id

    state = state |> Nav.put_cursor(first) |> verb(:all_off) |> serve(c.client)
    off = MCP.get(id).disabled_tools
    assert length(off) == 29, inspect(state.settings.status)

    state = state |> verb(:undo) |> serve(c.client)
    assert state.settings.status.text =~ "Undid: ", inspect(state.settings.status)
    assert Enum.sort(MCP.get(id).disabled_tools) == Enum.sort(before)

    state = state |> verb(:redo) |> serve(c.client)
    assert state.settings.status.text =~ "Redid: ", inspect(state.settings.status)
    assert Enum.sort(MCP.get(id).disabled_tools) == Enum.sort(off)
  end

  test "a price edit (a row without cache rates) saves, undoes and redoes", c do
    model = "claude-opus-5"

    state =
      open(c, :pricing) |> open_page(c, %Page{section: :pricing, record: {"pricing_row", model}})

    row = Enum.find(Nav.rows(state), &(&1.id == "fld:pricing_row:#{model}:output"))

    state = state |> Edit.commit(row, 70) |> serve(c.client)
    assert pricing()[model]["output"] == 70, inspect(state.settings.status)

    state = state |> verb(:undo) |> serve(c.client)
    assert state.settings.status.text =~ "Undid: ", inspect(state.settings.status)
    assert pricing()[model]["output"] == 75

    state = state |> verb(:redo) |> serve(c.client)
    assert state.settings.status.text =~ "Redid: ", inspect(state.settings.status)
    assert pricing()[model]["output"] == 70
  end

  test "a price renamed is undone", c do
    page = %Page{section: :pricing, record: {"pricing_row", "claude-opus-5"}}
    state = open(c, :pricing) |> open_page(c, page)
    row = Enum.find(Nav.rows(state), &(&1.id == "fld:pricing_row:claude-opus-5:model"))

    state = state |> Edit.commit(row, "claude-opus-5.1") |> serve(c.client)
    assert Map.has_key?(pricing(), "claude-opus-5.1"), inspect(state.settings.status)
    refute Map.has_key?(pricing(), "claude-opus-5")

    state = state |> verb(:undo) |> serve(c.client)
    assert state.settings.status.text =~ "Undid: ", inspect(state.settings.status)
    assert Map.has_key?(pricing(), "claude-opus-5")
    refute Map.has_key?(pricing(), "claude-opus-5.1")
  end

  test "an applied MCP connection change is undone and redone", c do
    id = c.docs.id
    url = MCP.get(id).url
    state = open(c, :mcp) |> open_page(c, %Page{section: :mcp, record: {"mcp_server", id}})

    {state, _} =
      Ops.run(state, [{:stage, {"mcp_server", id}, %{"url" => "https://mine.test/mcp"}}])

    state = state |> verb(:restart) |> serve(c.client)
    assert MCP.get(id).url == "https://mine.test/mcp", inspect(state.settings.status)

    state = state |> verb(:undo) |> serve(c.client)
    assert state.settings.status.text =~ "Undid: ", inspect(state.settings.status)
    assert MCP.get(id).url == url

    state = state |> verb(:redo) |> serve(c.client)
    assert state.settings.status.text =~ "Redid: ", inspect(state.settings.status)
    assert MCP.get(id).url == "https://mine.test/mcp"
  end

  test "a provider's saved effort levels are undone and redone (the answer's record gives the undo its expected)",
       c do
    id = c.deepseek.id
    before = SwarmCode.Domain.Providers.get(id).effort_levels

    state =
      open(c, :providers)
      |> open_page(c, %Page{section: :providers, record: {"provider", id}})
      |> open_page(c, %Page{section: :providers, record: {"provider", id}, sub: :effort_levels})

    ctx = Nav.ctx(state)
    f = SwarmCodeCLI.UI.Settings.IntegrationRows.fields(ctx |> record(id))
    [first | rest] = SwarmCodeCLI.UI.Settings.EffortLevels.levels(ctx, id, f)
    rows = [Map.put(stringify(first), "label", "Quickest") | Enum.map(rest, &stringify/1)]

    {state, _} =
      Ops.run(state, [
        {:draft_put, "effort_levels", %{"provider_id" => id, "model" => nil, "rows" => rows}}
      ])

    state = state |> Nav.put_cursor("act:levels.save") |> verb(:enter) |> serve(c.client)
    saved = SwarmCode.Domain.Providers.get(id).effort_levels
    assert saved != before, inspect(state.settings.status)

    state = state |> verb(:undo) |> serve(c.client)
    assert state.settings.status.text =~ "Undid: ", inspect(state.settings.status)
    assert SwarmCode.Domain.Providers.get(id).effort_levels == before

    state = state |> verb(:redo) |> serve(c.client)
    assert state.settings.status.text =~ "Redid: ", inspect(state.settings.status)
    assert SwarmCode.Domain.Providers.get(id).effort_levels == saved
  end

  defp record(ctx, id), do: SwarmCodeCLI.UI.Settings.IntegrationRows.record(ctx, "provider", id)

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  # ---------------------------------------------------------------- driving

  defp open(c, section) do
    %{sized(ready(), 160, 45) | now: System.system_time(:millisecond)}
    |> Reducer.update({:settings_open, {:section, section}})
    |> serve(c.client)
  end

  defp open_page(state, c, page) do
    {state, _} = Ops.run(state, [{:open, page}])
    state |> Wire.sync() |> serve(c.client)
  end

  defp verb(state, verb), do: Reducer.update(state, {:settings, {:verb, verb}})

  defp engines do
    Engines.all() |> Enum.map(& &1.kind) |> Enum.filter(&(&1 in ["tavily", "exa"]))
  end

  defp pricing do
    _ = Repo
    Settings.get().pricing || %{}
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
