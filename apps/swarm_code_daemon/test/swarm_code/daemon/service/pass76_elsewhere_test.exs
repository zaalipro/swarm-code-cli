defmodule SwarmCode.Daemon.Service.Pass76ElsewhereTest do
  @moduledoc """
  pass76 cli-quit-attention: the persisted service tells the shell watch what
  the session holds (every live run, and the live runs, approvals and
  questions waiting in the other conversations), in the shell snapshot and as
  an `elsewhere` delta whenever it changes; the quit's list of stopped runs
  names each run's conversation. The count comes from the run registry, never
  from the rows a client cached.
  """
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.Elsewhere
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Projects, Repo}
  alias SwarmCode.Domain.Engine.Questions
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCodeCLI.UI.DataSource.{Delta, DTO}

  setup_all do
    path = Path.join(System.tmp_dir!(), "pass76-elsewhere-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    prior = Application.get_env(:swarm_code_daemon, :domain_config_dir)
    Application.put_env(:swarm_code_daemon, :domain_config_dir, Path.join(path, "config"))

    on_exit(fn ->
      Cache.clear()

      if prior,
        do: Application.put_env(:swarm_code_daemon, :domain_config_dir, prior),
        else: Application.delete_env(:swarm_code_daemon, :domain_config_dir)

      File.rm_rf!(path)
    end)

    start_supervised!(
      {Repo,
       database: Path.join(path, "fixture.db"),
       domain_fixture: true,
       pool_size: 1,
       journal_mode: :wal,
       log: false}
    )

    Ecto.Migrator.run(
      Repo,
      Application.app_dir(:swarm_code_daemon, "priv/domain_repo/migrations"),
      :up,
      all: true,
      log: false
    )

    %{path: path}
  end

  setup c do
    Cache.clear()
    root = Path.join(c.path, "project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create(%{name: "Elsewhere", root_path: root})
    {:ok, shown} = Conversations.create(project.id)
    {:ok, other} = Conversations.create(project.id)
    {:ok, third} = Conversations.create(project.id)
    {:ok, shown} = Conversations.update(shown, %{title: "Shown work"})
    {:ok, other} = Conversations.update(other, %{title: "Other work"})
    {:ok, third} = Conversations.update(third, %{title: "Third work"})

    backend =
      start_supervised!(
        {Backend,
         mode: :persisted,
         repo: Repo,
         project_root: root,
         project_id: project.id,
         conversation_id: shown.id,
         source_epoch: Ecto.UUID.generate()}
      )

    # The launch listing of the project's commands (C-FEAT-1/8) is a metadata
    # delta of its own: let it land before a test counts deltas.
    SwarmCode.Test.C020Backend.settle_slash_extras(backend)

    %{backend: backend, project: project, shown: shown, other: other, third: third}
  end

  defp global, do: %Scope{kind: :global, id: nil, generation: 0}
  defp conversation(id), do: %Scope{kind: :conversation, id: id, generation: 1}

  # Stands in for a RunServer: registered like one until told to end.
  defp live_run(conversation_id, kind \\ "chat") do
    test = self()
    run_id = Ecto.UUID.generate()

    pid =
      spawn_link(fn ->
        {:ok, _} =
          Registry.register(SwarmCode.Domain.Registry, {:run, run_id}, {conversation_id, kind})

        send(test, {:registered, self()})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:registered, ^pid}
    on_exit(fn -> if Process.alive?(pid), do: send(pid, :finish) end)
    {run_id, pid}
  end

  defp finish(pid) do
    ref = Process.monitor(pid)
    send(pid, :finish)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  # Another conversation's run changed status: what the engine broadcasts.
  defp status_changed(conversation_id, status \\ "running"),
    do:
      SwarmCode.Domain.PubSub.broadcast(
        SwarmCode.Domain.PubSub,
        "runs",
        {:run_status, conversation_id, status}
      )

  defp watch!(backend, slot, scope, ref) do
    request = %ServiceRequest{
      operation: :watch,
      timeout_ms: 1000,
      params: %{"watch_ref" => ref, "slot" => slot, "page_size" => 20, "byte_limit" => 262_144}
    }

    assert {:watch, 0, _, kind, body} =
             GenServer.call(backend, {:service_watch, self(), "watch-#{ref}", scope, request})

    send(backend, {:service_ready, self(), ref})
    {kind, body}
  end

  # A watch sends a few deltas at a time and the client acknowledges them.
  defp elsewhere!(timeout \\ 3000) do
    assert_receive {:service_delta, backend, "shell", %{"kind" => "elsewhere"} = delta}, timeout
    send(backend, {:service_credit, self(), "shell", delta["sequence"]})
    assert {:ok, %Delta{body: %DTO.Elsewhere{} = body}} = Delta.decode(delta)
    body
  end

  defp snapshot_fact(body) do
    assert {:ok, %DTO.ShellSnapshot{elsewhere: %DTO.Elsewhere{} = fact}} =
             DTO.ShellSnapshot.decode(body)

    fact
  end

  describe "the facts" do
    test "count the live runs and list the waits of every conversation but the shown one", c do
      assert Elsewhere.facts(c.shown.id) == %{total: 0, live: 0, waiting: []}

      {_mine, _} = live_run(c.shown.id)
      {run_a, _} = live_run(c.other.id)
      {_run_b, _} = live_run(c.other.id, "swarm")
      {_run_c, _} = live_run(c.third.id)
      node = Ecto.UUID.generate()
      Questions.put(c.other.id, run_a, node, :approval)
      on_exit(fn -> Questions.delete_run(run_a) end)

      mine = Ecto.UUID.generate()
      Questions.put(c.shown.id, mine, Ecto.UUID.generate(), :approval)
      on_exit(fn -> Questions.delete_run(mine) end)

      assert %{total: 4, live: 3, waiting: [wait]} = Elsewhere.facts(c.shown.id)

      assert %{id: ^node, run_id: ^run_a, kind: :approval, since: since} = wait
      assert wait.conversation_id == c.other.id
      assert is_integer(since) and since > 0

      # Seen from the other conversation, the shown one's run and wait count.
      assert %{total: 4, live: 2, waiting: [%{kind: :approval, conversation_id: shown}]} =
               Elsewhere.facts(c.other.id)

      assert shown == c.shown.id
    end

    test "are bounded to the newest 32 waits while the run count stays exact", c do
      runs =
        for _ <- 1..40 do
          {run, _} = live_run(c.other.id)
          Questions.put(c.other.id, run, Ecto.UUID.generate(), :question)
          run
        end

      on_exit(fn -> Enum.each(runs, &Questions.delete_run/1) end)

      assert %{total: 40, live: 40, waiting: waiting} = Elsewhere.facts(c.shown.id)
      assert length(waiting) == 32
      assert Enum.all?(waiting, &(&1.kind == :question))

      # Newest first from the tail: `since` never goes backwards along the list.
      assert Enum.map(waiting, & &1.since) == waiting |> Enum.map(& &1.since) |> Enum.sort()
    end

    test "count every registered run of the session, whatever the rows say", c do
      # The shown conversation's runs count in the total and not in `live`.
      {_a, _} = live_run(c.shown.id)
      {_b, _} = live_run(c.shown.id, "swarm")
      assert %{total: 2, live: 0} = Elsewhere.facts(c.shown.id)

      # Runs that finished left rows, not registry entries: any number of them
      # (the client's runs page is the newest 200) changes nothing.
      for n <- 1..201 do
        {:ok, _run} =
          Conversations.insert_run_row(%{
            conversation_id: c.shown.id,
            kind: "chat",
            prompt: "done #{n}",
            status: "done",
            started_at: DateTime.utc_now()
          })
      end

      assert %{total: 2, live: 0} = Elsewhere.facts(c.shown.id)

      # Without a shown conversation every run is elsewhere.
      assert %{total: 2, live: 2} = Elsewhere.facts(nil)
    end

    test "go on the wire with the conversation's title", c do
      run = Ecto.UUID.generate()
      node = Ecto.UUID.generate()
      Questions.put(c.other.id, run, node, :question)
      on_exit(fn -> Questions.delete_run(run) end)

      {_mine, _} = live_run(c.shown.id)
      body = c.shown.id |> Elsewhere.facts() |> Elsewhere.body()

      assert {:ok, %DTO.Elsewhere{total: 1, live: 0, waiting: [wait]}} =
               DTO.Elsewhere.decode(body)

      assert {wait.id, wait.run_id, wait.conversation_id, wait.kind, wait.title} ==
               {node, run, c.other.id, :question, "Other work"}

      assert wait.since > 0
    end
  end

  describe "the shell watch" do
    test "its snapshot carries the fact", c do
      {_run, _} = live_run(c.other.id)
      run = Ecto.UUID.generate()
      Questions.put(c.third.id, run, Ecto.UUID.generate(), :approval)
      on_exit(fn -> Questions.delete_run(run) end)

      {"shell_snapshot", body} = watch!(c.backend, "shell", global(), "shell")

      assert %DTO.Elsewhere{total: 1, live: 1, waiting: [%DTO.ElsewhereWait{title: "Third work"}]} =
               snapshot_fact(body)
    end

    test "its total counts a live run that the runs page leaves out", c do
      {_run, _} = live_run(c.shown.id)

      # The run is the oldest of the conversation: 210 newer finished rows
      # push it out of the newest-200 page a client loads.
      for n <- 1..210 do
        {:ok, _} =
          Conversations.insert_run_row(%{
            conversation_id: c.shown.id,
            kind: "chat",
            prompt: "done #{n}",
            status: "done",
            started_at: DateTime.utc_now()
          })
      end

      {"shell_snapshot", body} = watch!(c.backend, "shell", global(), "shell")

      assert %DTO.Elsewhere{total: 1, live: 0} = snapshot_fact(body)
    end

    test "a run starting and ending in another conversation moves it", c do
      watch!(c.backend, "shell", global(), "shell")

      {_run, pid} = live_run(c.other.id)
      status_changed(c.other.id)
      assert %DTO.Elsewhere{total: 1, live: 1, waiting: []} = elsewhere!()

      finish(pid)
      status_changed(c.other.id, "done")
      assert %DTO.Elsewhere{total: 0, live: 0, waiting: []} = elsewhere!()

      # Nothing changed, so nothing more is said.
      status_changed(c.other.id, "done")
      refute_receive {:service_delta, _, "shell", %{"kind" => "elsewhere"}}, 600
    end

    test "a run starting and ending in the shown conversation moves the total alone", c do
      watch!(c.backend, "shell", global(), "shell")

      {_run, pid} = live_run(c.shown.id)
      status_changed(c.shown.id)
      assert %DTO.Elsewhere{total: 1, live: 0, waiting: []} = elsewhere!()

      finish(pid)
      status_changed(c.shown.id, "done")
      assert %DTO.Elsewhere{total: 0, live: 0, waiting: []} = elsewhere!()
    end

    test "a wait appearing and clearing elsewhere is told, naming where", c do
      watch!(c.backend, "shell", global(), "shell")
      {run, pid} = live_run(c.other.id)
      node = Ecto.UUID.generate()
      on_exit(fn -> Questions.delete_run(run) end)

      Questions.put(c.other.id, run, node, :approval)

      assert %DTO.Elsewhere{total: 1, live: 1, waiting: [wait]} = elsewhere!()
      assert {wait.id, wait.run_id, wait.kind, wait.title} == {node, run, :approval, "Other work"}

      Questions.delete(run, node)
      finish(pid)
      assert %DTO.Elsewhere{total: 0, live: 0, waiting: []} = elsewhere!()
    end

    test "a wait in the shown conversation is not elsewhere", c do
      watch!(c.backend, "shell", global(), "shell")
      run = Ecto.UUID.generate()
      on_exit(fn -> Questions.delete_run(run) end)

      Questions.put(c.shown.id, run, Ecto.UUID.generate(), :approval)
      refute_receive {:service_delta, _, "shell", %{"kind" => "elsewhere"}}, 600
    end

    test "a run that ended without another event is corrected by the recheck", c do
      watch!(c.backend, "shell", global(), "shell")
      {_run, pid} = live_run(c.other.id)
      status_changed(c.other.id)
      assert %DTO.Elsewhere{live: 1} = elsewhere!()

      # The process leaves after the last status event: nothing triggers the
      # next reading but the owned recheck timer.
      finish(pid)
      assert %DTO.Elsewhere{total: 0, live: 0} = elsewhere!(5000)
    end

    test "a run of the shown conversation that ended without an event is corrected too", c do
      watch!(c.backend, "shell", global(), "shell")
      {_run, pid} = live_run(c.shown.id)
      status_changed(c.shown.id)
      assert %DTO.Elsewhere{total: 1, live: 0} = elsewhere!()

      finish(pid)
      assert %DTO.Elsewhere{total: 0, live: 0} = elsewhere!(5000)
    end

    test "only the shell watch hears it", c do
      watch!(c.backend, "workspace", conversation(c.shown.id), "workspace")
      watch!(c.backend, "shell", global(), "shell")
      {_run, _} = live_run(c.other.id)
      status_changed(c.other.id)

      assert %DTO.Elsewhere{total: 1, live: 1} = elsewhere!()
      refute_receive {:service_delta, _, "workspace", %{"kind" => "elsewhere"}}, 300
    end

    test "opening another conversation re-snapshots with that one excluded", c do
      {_run, _} = live_run(c.other.id)
      {_run, _} = live_run(c.other.id)
      {_run, _} = live_run(c.shown.id)

      {"shell_snapshot", body} = watch!(c.backend, "shell", global(), "shell")
      assert %DTO.Elsewhere{total: 3, live: 2} = snapshot_fact(body)

      assert {:ok, %{"value" => %{"status" => "accepted"}}} =
               request(c.backend, "open", global(), %ServiceRequest{
                 operation: :conversation_open,
                 timeout_ms: 5000,
                 params: %{"conversation_id" => c.other.id}
               })

      assert_receive {:service_resync, _, "shell"}, 2000
      {"shell_snapshot", body} = watch!(c.backend, "shell", global(), "shell")
      assert %DTO.Elsewhere{total: 3, live: 1} = snapshot_fact(body)
    end

    test "no timer runs, and nothing is read, without a shell watch", c do
      {_run, _} = live_run(c.other.id)
      status_changed(c.other.id)
      assert :sys.get_state(c.backend).elsewhere_timer == nil

      watch!(c.backend, "shell", global(), "shell")
      state = :sys.get_state(c.backend)
      assert state.elsewhere == %{total: 1, live: 1, waiting: []}

      send(c.backend, {:service_unwatch, self(), "shell"})
      state = :sys.get_state(c.backend)
      assert {state.elsewhere, state.elsewhere_timer} == {nil, nil}
    end
  end

  # The command ledger is durable per project: every request names its own.
  defp request(backend, name, scope, request),
    do:
      GenServer.call(
        backend,
        {:service_request, "#{name}-#{System.unique_integer([:positive])}", scope, request},
        10_000
      )
end
