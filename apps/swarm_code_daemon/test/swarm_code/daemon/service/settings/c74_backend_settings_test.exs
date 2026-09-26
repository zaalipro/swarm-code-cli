defmodule SwarmCode.Daemon.Service.Settings.C74BackendSettingsTest do
  @moduledoc """
  pass74 S1-10 (§3.3.9, §3.3.10): settings requests through a PersistedBackend
  on a fixture database — the settings job pool, command jobs and the ledger
  (secrets, every settle path, the 120 KiB guard), query keys, the coalesced
  `settings_update`, the workspace metadata re-projection, the open
  conversation kept back from retention, the dispatch refusal without a usable
  provider (D11), no secret in a log, tasks on the shell watch, and the
  LiveBackend's answers.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]

  alias SwarmCode.Daemon.Service.{LiveBackend, PersistedBackend}
  alias SwarmCode.Daemon.Service.Settings.{Result, TaskSpec, Wire}
  alias SwarmCode.Domain.{Conversations, Engine, Providers, Repo, Storage, UIState}
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCode.Test.C74S1

  @moduletag timeout: 120_000
  @scope %Scope{kind: :global, id: nil, generation: 3}
  @unknown "Couldn't tell whether that was saved; reloading."

  setup context do
    %{dir: dir} = C74S1.repo!("c74-s1-backend")
    unless Process.whereis(UIState), do: start_supervised!(UIState)

    on_exit(fn ->
      Application.delete_env(:swarm_code_daemon, :settings_job_seam)
      Application.delete_env(:swarm_code_daemon, :settings_values_seam)
    end)

    fixture =
      if context[:fresh] do
        prior = System.get_env("LLMOTIONS_API_KEY")
        System.delete_env("LLMOTIONS_API_KEY")
        on_exit(fn -> if prior, do: System.put_env("LLMOTIONS_API_KEY", prior) end)
        :ok = Providers.seed_defaults()
        project = C74S1.project!(dir, "fresh")
        %{ailogic: project, conversation: C74S1.conversation!(project)}
      else
        C74S1.appendix_a!(dir)
      end

    opts = [
      mode: :persisted,
      repo: Repo,
      project_root: fixture.ailogic.root_path,
      project_id: fixture.ailogic.id,
      conversation_id: fixture.conversation.id,
      source_epoch: Ecto.UUID.generate()
    ]

    backend = start_supervised!({PersistedBackend, opts})
    on_exit(fn -> Engine.stop_all(fixture.conversation.id) end)
    Map.merge(fixture, %{backend: backend, opts: opts, dir: dir})
  end

  ## ---------------------------------------------------------------- helpers

  defp query_params(params) do
    Map.merge(
      Map.new(SwarmCode.Settings.WireBounds.param_keys(:settings_query), &{&1, nil}),
      params
    )
  end

  defp command_params(action, params \\ %{}) do
    Map.merge(
      %{
        "action" => action,
        "target" => nil,
        "attributes" => %{},
        "expected" => nil,
        "secrets" => [],
        "dry_run" => false
      },
      params
    )
  end

  defp call(backend, id, operation, params, timeout_ms \\ 15_000) do
    request = %ServiceRequest{operation: operation, timeout_ms: timeout_ms, params: params}
    GenServer.call(backend, {:service_request, id, @scope, request}, 30_000)
  end

  defp query(backend, id, params), do: call(backend, id, :settings_query, query_params(params))

  defp command(backend, id, params, timeout \\ 15_000),
    do: call(backend, id, :settings_command, params, timeout)

  defp patch(value, expected, extra \\ %{}) do
    command_params(
      "values.patch",
      Map.merge(
        %{
          "attributes" => %{
            "changes" => [
              %{"key" => "limits.max_concurrent_agents", "value" => value, "target" => nil}
            ]
          },
          "expected" => %{"limits.max_concurrent_agents" => expected}
        },
        extra
      )
    )
  end

  defp uuid, do: Ecto.UUID.generate()

  defp ledger(id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT status, response_json FROM cli_command_ledger WHERE request_id = ?",
      [id]
    ).rows
  end

  # Hold every job of `kind` (optionally only when `match?.(params)`) until
  # its pid is sent `:release`.
  defp hold(kind, match? \\ fn _ -> true end) do
    me = self()

    Application.put_env(:swarm_code_daemon, :settings_job_seam, fn job_kind, params ->
      if job_kind == kind and match?.(params) do
        send(me, {:held, self(), params})

        receive do
          :release -> :continue
        end
      else
        :continue
      end
    end)
  end

  defp held do
    assert_receive {:held, pid, params}, 5_000
    {pid, params}
  end

  defp shell_watch(backend, ref) do
    watch = %ServiceRequest{
      operation: :watch,
      timeout_ms: 1_000,
      params: %{"watch_ref" => ref, "slot" => "shell", "page_size" => 20, "byte_limit" => 65_536}
    }

    assert {:watch, 0, _, _kind, _body} =
             GenServer.call(backend, {:service_watch, self(), "w-" <> ref, @scope, watch})

    send(backend, {:service_ready, self(), ref})
    ref
  end

  defp settings_deltas(ref, kind, wait) do
    receive do
      {:service_delta, backend, ^ref, %{"kind" => ^kind} = delta} ->
        send(backend, {:service_credit, self(), ref, delta["sequence"]})
        [delta | settings_deltas(ref, kind, wait)]

      {:service_delta, backend, ^ref, delta} ->
        send(backend, {:service_credit, self(), ref, delta["sequence"]})
        settings_deltas(ref, kind, wait)
    after
      wait -> []
    end
  end

  defp eventually(fun, tries \\ 100) do
    if fun.() or tries == 0 do
      assert fun.()
    else
      receive after: (20 -> :ok)
      eventually(fun, tries - 1)
    end
  end

  ## ------------------------------------------------------------------ tests

  test "a query answers a settings_snapshot; view=task of an unknown id says it is gone", c do
    assert {:ok, %{"response_kind" => "settings_snapshot", "value" => snapshot}} =
             query(c.backend, uuid(), %{
               "view" => "values",
               "keys" => ["limits.max_concurrent_agents"]
             })

    assert %{"available" => true, "view" => "values", "body" => %{"values" => [value]}} = snapshot
    assert value["value"] == 6

    assert {:ok, %{"value" => %{"available" => false, "message" => message}}} =
             query(c.backend, uuid(), %{"view" => "task", "id" => uuid()})

    assert message == "that result is gone; run it again"
  end

  test "a command with secrets leaves no ledger row; a retry re-runs it and answers unchanged",
       c do
    id = uuid()
    params = patch(7, 6, %{"secrets" => [%{"slot" => "api_key", "value" => C74S1.canary()}]})

    assert {:ok, %{"response_kind" => "settings_result", "value" => %{"status" => "accepted"}}} =
             command(c.backend, id, params)

    assert ledger(id) == []

    assert {:ok, %{"value" => %{"status" => "unchanged"} = value}} =
             command(c.backend, id, params)

    refute Jason.encode!(value) =~ C74S1.canary()
    assert ledger(id) == []

    # A durable command is ledgered and replays.
    durable = uuid()

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             command(c.backend, durable, patch(8, 7))

    assert [["completed", json]] = ledger(durable)
    assert json =~ "accepted"

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             command(c.backend, durable, patch(8, 7))
  end

  test "a command job killed, timed out or stopped with the service completes its ledger row",
       c do
    hold(:command)

    killed = uuid()
    task = Task.async(fn -> command(c.backend, killed, patch(7, 6)) end)
    {pid, _} = held()
    Process.exit(pid, :kill)

    assert {:ok, %{"value" => %{"status" => "unavailable", "message" => @unknown}}} =
             Task.await(task)

    assert [["completed", json]] = ledger(killed)
    assert json =~ "unavailable"

    timed_out = uuid()
    task = Task.async(fn -> command(c.backend, timed_out, patch(7, 6), 2_000) end)
    held()

    assert {:ok, %{"value" => %{"status" => "unavailable", "message" => @unknown}}} =
             Task.await(task, 10_000)

    assert [["completed", _]] = ledger(timed_out)

    stopped = uuid()
    task = Task.async(fn -> command(c.backend, stopped, patch(7, 6)) end)
    held()
    stop_supervised!(PersistedBackend)

    assert {:ok, %{"value" => %{"status" => "unavailable", "message" => @unknown}}} =
             Task.await(task)

    assert [["completed", _]] = ledger(stopped)
  end

  test "a fifth settings job is refused before the ledger admits it", c do
    hold(:command)
    ids = for _ <- 1..4, do: uuid()
    tasks = for id <- ids, do: Task.async(fn -> command(c.backend, id, patch(7, 6)) end)
    pids = for _ <- 1..4, do: elem(held(), 0)

    fifth = uuid()

    assert {:ok, %{"value" => %{"status" => "busy", "message" => words}}} =
             command(c.backend, fifth, patch(7, 6))

    assert words == "Settings is busy; try again in a moment."
    assert ledger(fifth) == []

    assert {:error, %{"code" => "capacity_exceeded"}} =
             query(c.backend, uuid(), %{"view" => "facts"})

    Enum.each(pids, &send(&1, :release))
    for task <- tasks, do: assert({:ok, %{"value" => %{"status" => _}}} = Task.await(task))
  end

  test "reads with different ids run side by side; the same key replaces the older one", c do
    hold(:query, &(&1["view"] == "file"))

    a = Task.async(fn -> query(c.backend, uuid(), %{"view" => "file", "id" => "ref-a"}) end)
    {pa, _} = held()
    replaced = Process.monitor(pa)
    b = Task.async(fn -> query(c.backend, uuid(), %{"view" => "file", "id" => "ref-b"}) end)
    {pb, _} = held()

    again = Task.async(fn -> query(c.backend, uuid(), %{"view" => "file", "id" => "ref-a"}) end)
    {pa2, _} = held()
    assert {:error, %{"code" => "stale_revision"}} = Task.await(a)

    Enum.each([pb, pa2], &send(&1, :release))
    assert {:ok, %{"response_kind" => "settings_snapshot"}} = Task.await(b)
    assert {:ok, %{"response_kind" => "settings_snapshot"}} = Task.await(again)
    assert_receive {:DOWN, ^replaced, :process, ^pa, _}, 2_000
  end

  test "a result over the ledger guard keeps its status, the backend lives, the ledger replays",
       c do
    rows =
      for i <- 1..300 do
        Result.row("row#{i}", :conflict, value: "x", current: String.duplicate("c", 1_000))
      end

    Application.put_env(:swarm_code_daemon, :settings_job_seam, fn
      :command, _ -> {:answer, {:ok, %Result{status: :conflict, results: rows}}}
      _, _ -> :continue
    end)

    id = uuid()

    assert {:ok, %{"value" => %{"status" => "conflict", "results" => []} = value}} =
             command(c.backend, id, patch(7, 6))

    assert value["message"] == "The answer was too large to keep; reloading."
    assert Wire.ledger_guard() < 131_072
    assert [["completed", _]] = ledger(id)

    stop_supervised!(PersistedBackend)
    restarted = start_supervised!({PersistedBackend, c.opts})
    assert {:ok, %{"value" => ^value}} = command(restarted, id, patch(7, 6))
  end

  test "a desktop-side change makes one settings_update from elsewhere; a command's is own", c do
    ref = shell_watch(c.backend, "shell")
    {:ok, _} = SwarmCode.Domain.Settings.update(%{max_concurrent_agents: 5})

    assert [delta] = settings_deltas(ref, "settings_update", 400)
    assert %{"origin" => "elsewhere", "sections" => sections, "revision" => 1} = delta["body"]
    assert "agents_limits" in sections
    assert delta["conversation_id"] == nil
    assert {:ok, decoded} = SwarmCodeCLI.UI.DataSource.Delta.decode(delta)
    assert decoded.body.origin == :elsewhere

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             command(c.backend, uuid(), patch(7, 5))

    assert [own] = settings_deltas(ref, "settings_update", 400)
    assert %{"origin" => "settings", "revision" => 2} = own["body"]
  end

  # cli74 G1 (QA F-8): a server created or deleted (`MCP.broadcast/0`) made no
  # settings_update, so a deleted server stayed on an open MCP page until Ctrl-R.
  test "an MCP server added, changed or deleted makes a settings_update for mcp", c do
    ref = shell_watch(c.backend, "shell")
    SwarmCode.Domain.MCP.broadcast()

    assert [delta] = settings_deltas(ref, "settings_update", 400)
    assert "mcp" in delta["body"]["sections"]
    assert "overview" in delta["body"]["sections"]
  end

  test "the workspace metadata re-projects a new default chat model", c do
    {:ok, _} =
      Conversations.update(c.conversation, %{chat_provider_id: nil, chat_model: nil})

    watch = %ServiceRequest{
      operation: :watch,
      timeout_ms: 1_000,
      params: %{
        "watch_ref" => "ws",
        "slot" => "workspace",
        "page_size" => 20,
        "byte_limit" => 262_144
      }
    }

    scope = %Scope{kind: :conversation, id: c.conversation.id, generation: 3}

    assert {:watch, 0, _, _, _} =
             GenServer.call(c.backend, {:service_watch, self(), "w-ws", scope, watch})

    send(c.backend, {:service_ready, self(), "ws"})
    {:ok, _} = SwarmCode.Domain.Settings.update(%{default_chat_model: "deepseek-v4-flash"})

    assert Enum.any?(settings_deltas("ws", "workspace_metadata", 1_000), fn delta ->
             delta["body"]["chat_model"] == "deepseek-v4-flash"
           end)
  end

  test "the backend's conversation survives a retention sweep that removes an older one", c do
    other = C74S1.conversation!(c.ailogic, %{title: "old one"})
    old = DateTime.add(DateTime.utc_now(), -10 * 86_400, :second)

    Repo.update_all(
      from(v in SwarmCode.Domain.Conversations.Conversation,
        where: v.id in ^[c.conversation.id, other.id]
      ),
      set: [updated_at: old, inserted_at: old]
    )

    {:ok, _} = SwarmCode.Domain.Settings.update(%{storage_retention_days: 7})
    eventually(fn -> c.conversation.id in UIState.open_conversation_ids() end)

    assert :ok = Storage.apply_retention(DateTime.utc_now())
    assert Conversations.get(c.conversation.id)
    refute Conversations.get(other.id)
  end

  @tag :fresh
  test "a send on a fresh database whose seeded provider has no key is refused (D11)", c do
    request = %ServiceRequest{
      operation: :dispatch_send,
      timeout_ms: 30_000,
      params: %{
        "action" => "send",
        "text" => "hello",
        "target" => %{"kind" => "main", "id" => nil},
        "attachment_refs" => []
      }
    }

    scope = %Scope{kind: :conversation, id: c.conversation.id, generation: 3}

    assert {:ok, %{"value" => %{"status" => "rejected", "reason" => reason}}} =
             GenServer.call(c.backend, {:service_request, uuid(), scope, request}, 30_000)

    assert reason == %{
             "code" => "provider_required",
             "text" =>
               "No model provider can answer: llmotions has no key. Add one in /settings providers."
           }

    assert Conversations.list_runs(c.conversation.id) == []
  end

  test "a handler raising on a command with a secret leaves the secret out of the log", c do
    Application.put_env(:swarm_code_daemon, :settings_values_seam, fn ->
      raise ArgumentError, "boom"
    end)

    params = patch(7, 6, %{"secrets" => [%{"slot" => "api_key", "value" => C74S1.canary()}]})

    log =
      capture_log(fn ->
        assert {:ok, %{"value" => %{"status" => "unavailable"}}} =
                 command(c.backend, uuid(), params)
      end)

    assert log =~ "settings request failed: values.patch"
    refute log =~ C74S1.canary()
    refute inspect(:sys.get_status(c.backend)) =~ C74S1.canary()
  end

  test "a task started by a command reports on the shell watch, is read and cancelled", c do
    ref = shell_watch(c.backend, "tasks")
    me = self()

    Application.put_env(:swarm_code_daemon, :settings_job_seam, fn
      :command, %{"action" => "doctor"} ->
        rows = for i <- 1..450, do: %{"check" => "c#{i}", "ok" => true}
        spec = TaskSpec.new("doctor", :doctor, fn _ -> {:ok, %{"rows" => rows}} end)
        {:answer, {:task, spec, %Result{status: :accepted}}}

      :command, %{"action" => "lsp.check"} ->
        run = fn _ ->
          send(me, {:task_pid, self()})
          receive do: (:never -> {:ok, %{}})
        end

        {:answer, {:task, TaskSpec.new("lsp.check", "erlang", run), %Result{status: :accepted}}}

      _, _ ->
        :continue
    end)

    assert {:ok, %{"value" => %{"status" => "accepted", "task" => %{"task_id" => id}}}} =
             command(c.backend, uuid(), command_params("doctor"))

    deltas = settings_deltas(ref, "settings_task", 500)
    assert Enum.all?(deltas, &(&1["entity_id"] == id and &1["conversation_id"] == nil))
    assert List.last(deltas)["body"]["state"] == "done"
    assert {:ok, _} = SwarmCodeCLI.UI.DataSource.Delta.decode(List.last(deltas))

    assert {:ok, %{"value" => %{"body" => %{"result" => page}}}} =
             query(c.backend, uuid(), %{"view" => "task", "id" => id, "cursor" => "400"})

    assert %{"total" => 450, "next_cursor" => nil, "rows" => rows} = page
    assert length(rows) == 50

    assert {:ok, %{"value" => %{"task" => %{"task_id" => held}}}} =
             command(c.backend, uuid(), command_params("lsp.check"))

    assert_receive {:task_pid, pid}, 5_000
    monitor = Process.monitor(pid)

    assert {:ok, %{"value" => %{"status" => "accepted"}}} =
             command(
               c.backend,
               uuid(),
               command_params("task.cancel", %{"target" => %{"task_id" => held}})
             )

    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2_000

    assert Enum.any?(settings_deltas(ref, "settings_task", 500), fn delta ->
             delta["body"]["state"] == "cancelled"
           end)

    assert {:ok, %{"value" => %{"status" => "unchanged"}}} =
             command(
               c.backend,
               uuid(),
               command_params("task.cancel", %{"target" => %{"task_id" => held}})
             )
  end

  test "the LiveBackend answers that saved settings live in a saved session" do
    words =
      "Saved settings are available in a saved session (swarmcode). This session runs from SWARM_* variables."

    query = %ServiceRequest{
      operation: :settings_query,
      timeout_ms: 15_000,
      params: query_params(%{"view" => "values"})
    }

    assert {:reply, {:ok, %{"response_kind" => "settings_snapshot", "value" => snapshot}}, _} =
             LiveBackend.handle_call({:service_request, "q", @scope, query}, nil, %{opts: []})

    assert %{"available" => false, "message" => ^words, "body" => nil} = snapshot

    command = %ServiceRequest{
      operation: :settings_command,
      timeout_ms: 15_000,
      params: patch(7, 6, %{"secrets" => [%{"slot" => "k", "value" => C74S1.canary()}]})
    }

    assert {:reply, {:ok, %{"response_kind" => "settings_result", "value" => result}}, state} =
             LiveBackend.handle_call({:service_request, "c", @scope, command}, nil, %{opts: []})

    assert %{"status" => "unavailable", "message" => ^words} = result
    refute inspect(state) =~ C74S1.canary()
  end
end
