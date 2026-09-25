defmodule SwarmCode.Daemon.Service.Settings.C74RouterTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Daemon.Service.Settings
  alias SwarmCode.Daemon.Service.Settings.{Cas, Command, Context, Error, Layers, Result, Router}
  alias SwarmCode.Daemon.Service.Settings.{TaskCache, TaskSpec, Wire}
  alias SwarmCode.Settings.{Registry, WireBounds}

  @canary "sk-canary-7Q2X-DO-NOT-SHOW"

  test "every action of the closed list routes to its table module or the backend" do
    for action <- WireBounds.actions() do
      module = Router.action_module(action)
      assert module != nil, action

      case Router.action(action) do
        {:ok, routed} -> assert routed == module
        {:error, %Error{code: :unsupported}} -> refute Code.ensure_loaded?(module)
      end
    end

    assert Router.action_module("task.cancel") == :backend
    assert Router.action_module("mcp.import.read") == Settings.MCPImport
    assert Router.action_module("mcp.toggle") == Settings.MCP
    assert Router.action_module("workflow.smoke") == Settings.Library
    assert Router.action_module("values.patch") == Settings.Values
  end

  test "an unknown action is refused before any module is looked up" do
    assert {:error, %Error{code: :invalid}} = Router.action("provider.show_key")
    assert {:error, %Error{code: :invalid}} = Router.action("Elixir.System.halt")
    assert {:error, %Error{code: :invalid}} = Router.action(nil)

    assert {:error, %Error{code: :invalid}} =
             Settings.command(%Command{action: "values.nope"}, Context.new())
  end

  test "views route by view and kind; unknown kinds are not found" do
    assert {:error, %Error{code: :not_found}} = Router.view("records", "users")
    assert Router.view("task", nil) == {:ok, :backend}
    assert "records:providers" in Router.view_keys()
  end

  test "cache reads: the table's declarations" do
    assert Router.cache_reads("provider.apply_models") ==
             [{"provider.fetch_models", {:param, "fetch_task_id"}}]

    assert {"search.test", :all} in Router.cache_reads("records:search_providers")
    assert Router.cache_reads("values") == []
  end

  test "a handler that raises is unavailable and the log names the action only" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, %Error{code: :unavailable, message: "Couldn't read settings right now."}} =
                 Settings.guarded("provider.set_key", fn -> raise "boom #{@canary}" end)
      end)

    assert log =~ "settings request failed: provider.set_key"
    refute log =~ @canary
  end

  test "inspect of a command, a context and a task spec never shows a secret" do
    command = %Command{
      action: "provider.set_key",
      target: %{"id" => "x"},
      secrets: [%{slot: "api_key", value: @canary}]
    }

    refute inspect(command) =~ @canary
    assert inspect(command) =~ "1 redacted"
    assert {:ok, @canary} = Command.secret(command, "api_key")

    ctx = %Context{env: %{"SWARM_API_KEY" => @canary}, task_results: %{{"x", 1} => %{v: @canary}}}
    refute inspect(ctx) =~ @canary

    spec =
      TaskSpec.new("provider.test", {"provider.test", "x"}, fn _ -> {:ok, %{}} end,
        redact: [@canary]
      )

    refute inspect(spec) =~ @canary
    assert spec.timeout_ms == 15_000 and spec.cancellable? and spec.kind == :plain
    assert TaskSpec.defaults("storage.run") == {1_800_000, false, :plain}
    assert TaskSpec.defaults("mcp.test") == {65_000, true, :probe}
  end

  test "context env keeps only list-B and developer names" do
    env =
      Context.env_from(%{"SWARM_THEME" => "light", "HOME" => "/Users/x", "AWS_SECRET" => @canary})

    assert env == %{"SWARM_THEME" => "light"}
  end

  test "task cache: least recently used out by count and by bytes" do
    cache = TaskCache.new(max_entries: 3)

    {cache, []} = TaskCache.put(cache, {"a", 1}, %{task_id: "1", state: "done"})
    {cache, []} = TaskCache.put(cache, {"a", 2}, %{task_id: "2", state: "done"})
    {cache, []} = TaskCache.put(cache, {"a", 3}, %{task_id: "3", state: "done"})
    cache = TaskCache.touch(cache, {"a", 1})
    {cache, [{"a", 2}]} = TaskCache.put(cache, {"a", 4}, %{task_id: "4", state: "done"})
    assert TaskCache.get(cache, {"a", 1})
    assert {{"a", 3}, _} = TaskCache.find_task(cache, "3")

    small = TaskCache.new(max_bytes: 300)
    big = %{task_id: "b", state: "done", result: String.duplicate("x", 200)}
    {small, []} = TaskCache.put(small, {"b", 1}, big)
    {small, [{"b", 1}]} = TaskCache.put(small, {"b", 2}, %{big | task_id: "c"})
    assert {1, bytes} = TaskCache.size(small)
    assert bytes > 200

    refute inspect(small) =~ "xxxx"
  end

  test "task cache: a purge timer drops only its own entry" do
    ref = make_ref()

    {cache, _} =
      TaskCache.put(TaskCache.new(), {"mcp.import.read", "p"}, %{
        task_id: "t",
        state: "done",
        purge_ref: ref,
        result: %{secret: @canary}
      })

    assert TaskCache.purge_refs(cache) == [ref]

    assert TaskCache.get(
             TaskCache.purge(cache, {"mcp.import.read", "p"}, make_ref()),
             {"mcp.import.read", "p"}
           )

    refute TaskCache.get(
             TaskCache.purge(cache, {"mcp.import.read", "p"}, ref),
             {"mcp.import.read", "p"}
           )

    refute inspect(cache) =~ @canary
  end

  test "task cache: the sessions store keeps the largest rows" do
    rows = for i <- 1..5, do: %{id: "s#{i}", bytes: i * 10}
    {cache, false} = TaskCache.put_sessions(TaskCache.new(), rows)
    assert Enum.map(TaskCache.sessions(cache), & &1.id) == ~w(s5 s4 s3 s2 s1)
  end

  test "cas: values, fields and files" do
    assert Cas.compare(50, 50.0) == :ok
    assert Cas.compare(6, Cas.any()) == :ok
    assert Cas.compare(6, 4) == {:conflict, 6}
    assert Cas.fields(%{"name" => "A", "x" => 1}, %{"fields" => %{"name" => "A"}}) == :ok

    assert Cas.fields(%{"name" => "B"}, %{"fields" => %{"name" => "A"}}) ==
             {:conflict, %{"name" => "B"}}

    assert Cas.fingerprint("abc")["size"] == 3
    assert Cas.file_fingerprint("/nonexistent/c74") == %{"missing" => true}
  end

  test "layers: ignored layers never win; invalid stored values keep their raw base" do
    entry = Registry.fetch!("efforts.default")

    layers = [
      Layers.layer(:global, "high"),
      Layers.ignored(:project_file, "high", "SwarmCode ignores this key"),
      Layers.layer(:default, "medium")
    ]

    value = Layers.setting_value(entry, layers)
    assert value["winner"] == "global" and value["value"] == "high"

    only_ignored = [Layers.unset(:global), Enum.at(layers, 1), Enum.at(layers, 2)]
    assert Layers.setting_value(entry, only_ignored)["winner"] == "default"

    theme = Registry.fetch!("desktop.theme")

    invalid =
      Layers.setting_value(
        theme,
        [Layers.invalid(:global, "nord"), Layers.layer(:default, "carbon")],
        invalid_raw: "nord"
      )

    assert invalid["state"] == "invalid" and invalid["value"] == nil and invalid["base"] == "nord"
    assert invalid["note"] == ~s(the stored value "nord" is not valid here; choose a new one)
  end

  test "wire: results, errors and the ledger guard" do
    result = %Result{
      status: :accepted,
      results: [Result.row("limits.max_concurrent_agents", :accepted, value: 6)]
    }

    encoded = Wire.result(result, "r1", 4)
    assert encoded["status"] == "accepted" and encoded["revision"] == 4

    assert [%{"target" => "limits.max_concurrent_agents", "status" => "accepted", "value" => 6}] =
             encoded["results"]

    assert Wire.result(Error.new(:invalid, "bad"), "r", 1)["status"] == "rejected"
    assert Wire.result(Error.unsupported(), "r", 1)["status"] == "unsupported"

    huge = %{encoded | "record" => %{"x" => String.duplicate("y", 200_000)}}
    guarded = Wire.guard(huge)
    assert guarded["status"] == "accepted" and guarded["record"] == nil
    assert guarded["message"] == "The answer was too large to keep; reloading."
    assert byte_size(Jason.encode!(guarded)) < Wire.ledger_guard()
    assert Wire.ledger_guard() < 131_072
  end

  test "result status: the worst row wins" do
    assert Result.worst([Result.row("a", :accepted), Result.row("b", :conflict)]) == :conflict
    assert Result.worst([Result.row("a", :unchanged)]) == :unchanged
    assert Result.worst([Result.row("a", :accepted), Result.row("b", :unchanged)]) == :accepted
    assert Result.worst([Result.row("a", :rejected), Result.row("b", :skipped)]) == :rejected
  end
end
