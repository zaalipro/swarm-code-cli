defmodule SwarmCodeCLI.Companion.HubTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.Companion.Hub
  alias SwarmCodeCLI.UI.{Action, Capabilities, Fixtures, Size}

  defmodule RuntimeStub do
    use GenServer
    def start_link(test), do: GenServer.start_link(__MODULE__, test)
    def init(test), do: {:ok, test}

    def handle_call({:action, action}, _from, test) do
      send(test, {:action, action})
      {:reply, :ok, test}
    end

    def handle_call(:snapshot, _from, test), do: {:reply, :none, test}
  end

  @size %Size{columns: 100, rows: 30}
  @caps %Capabilities{size: @size}

  defp fixture(kind \\ :swarm), do: Fixtures.representative(kind, @size, @caps)
  defp noticed(state, text), do: %{state | notice: {:command_feedback, text}}

  defp decode(json), do: Jason.decode!(json)

  test "starts with an empty view at revision 1 that already has every key" do
    hub = start_supervised!({Hub, runtime: nil, interval_ms: 0})
    assert {:ok, 1, json} = Hub.view(hub)
    view = decode(json)
    assert view["revision"] == 1 and view["tabs"] == [] and view["run"]["id"] == nil
    assert Map.has_key?(view, "needs") and Map.has_key?(view, "focus")
  end

  test "a pushed state bumps the revision once; the same state again does not" do
    hub = start_supervised!({Hub, runtime: nil, interval_ms: 0})
    send(hub, {:companion_state, fixture()})
    assert {:ok, 2, json} = Hub.view(hub)
    assert [%{"id" => "fixture-run"}] = decode(json)["tabs"]

    send(hub, {:companion_state, fixture()})
    assert {:ok, 2, _} = Hub.view(hub)

    send(hub, {:companion_state, noticed(fixture(), "changed")})
    assert {:ok, 3, json} = Hub.view(hub)
    assert decode(json)["notice"] == "changed"
  end

  test "view_since answers unchanged for the current revision only" do
    hub = start_supervised!({Hub, runtime: nil, interval_ms: 0})
    send(hub, {:companion_state, fixture()})
    assert {:ok, 2, _} = Hub.view(hub)
    assert Hub.view_since(hub, 2) == :unchanged
    assert {:ok, 2, _} = Hub.view_since(hub, 1)
    assert {:ok, 2, _} = Hub.view_since(hub, 0)
  end

  test "subscribers get the current view, then at most ten changes a second" do
    hub = start_supervised!({Hub, runtime: nil, interval_ms: 100})
    assert {:ok, 1, _} = Hub.subscribe(hub)

    for n <- 1..40, do: send(hub, {:companion_state, noticed(fixture(), "n#{n}")})

    messages = collect(300)
    assert length(messages) in 1..4
    {last_revision, last_json} = List.last(messages)
    assert decode(last_json)["notice"] == "n40"
    assert {:ok, ^last_revision, ^last_json} = Hub.view(hub)
    assert Enum.map(messages, &elem(&1, 0)) == Enum.sort(Enum.map(messages, &elem(&1, 0)))
  end

  test "unsubscribe stops the fan-out" do
    hub = start_supervised!({Hub, runtime: nil, interval_ms: 0})
    assert {:ok, 1, _} = Hub.subscribe(hub)
    assert :ok = Hub.unsubscribe(hub)
    send(hub, {:companion_state, fixture()})
    assert {:ok, 2, _} = Hub.view(hub)
    refute_receive {:companion_view, _, _}, 50
  end

  test "actions_for maps focus kinds onto existing, valid actions" do
    ui = fixture()

    assert {:ok, [{:focus_region, "composer"}]} = Hub.actions_for(ui, "composer", nil)
    assert {:ok, [{:navigate, {:run, "r1"}}]} = Hub.actions_for(ui, "run", "r1")
    assert {:ok, [{:navigate, {:conversation, "c1"}}]} = Hub.actions_for(ui, "conversation", "c1")

    assert {:ok, [{:navigate, {:run, "fixture-run"}}, {:set_tab, :agents}]} =
             Hub.actions_for(ui, "agent", "agent-2")

    assert {:ok,
            [{:navigate, {:run, "fixture-run"}}, {:focus_region, "main"}, {:expand, "001", true}]} =
             Hub.actions_for(ui, "item", "001")

    for {kind, id} <- [{"composer", nil}, {"run", "r1"}, {"agent", "agent-2"}, {"item", "001"}] do
      {:ok, actions} = Hub.actions_for(ui, kind, id)
      assert Enum.all?(actions, &match?({:ok, _}, Action.validate(&1)))
    end

    assert {:error, :invalid} = Hub.actions_for(ui, "run", "")
    assert {:error, :invalid} = Hub.actions_for(ui, "run", nil)
    assert {:error, :invalid} = Hub.actions_for(ui, "agent", "nobody")
    assert {:error, :invalid} = Hub.actions_for(ui, "item", "nothing")
    assert {:error, :invalid} = Hub.actions_for(nil, "agent", "agent-2")
    assert {:error, :unsupported} = Hub.actions_for(ui, "verdict", "x")
    assert {:error, :unsupported} = Hub.actions_for(ui, 42, "x")
  end

  test "focus is unavailable without a runtime and unsupported for unknown kinds" do
    hub = start_supervised!({Hub, runtime: nil, interval_ms: 0})
    assert {:error, :unavailable} = Hub.focus(hub, "composer", nil)
    assert {:error, :unsupported} = Hub.focus(hub, "bogus", nil)
    assert {:error, :invalid} = Hub.focus(hub, "agent", "agent-2")
  end

  test "an attached runtime receives the focus actions in order" do
    hub = start_supervised!({Hub, runtime: nil, interval_ms: 0})
    {:ok, stub} = RuntimeStub.start_link(self())
    assert :ok = Hub.attach(hub, stub)
    send(hub, {:companion_state, fixture()})
    assert {:ok, 2, _} = Hub.view(hub)

    assert :ok = Hub.focus(hub, "agent", "agent-2")
    assert_receive {:action, {:navigate, {:run, "fixture-run"}}}
    assert_receive {:action, {:set_tab, :agents}}

    assert :ok = Hub.focus(hub, "composer", nil)
    assert_receive {:action, {:focus_region, "composer"}}

    GenServer.stop(stub)
    assert {:error, :unavailable} = Hub.focus(hub, "composer", nil)
  end

  defp collect(timeout_ms, acc \\ []) do
    receive do
      {:companion_view, revision, json} -> collect(timeout_ms, [{revision, json} | acc])
    after
      timeout_ms -> Enum.reverse(acc)
    end
  end
end
