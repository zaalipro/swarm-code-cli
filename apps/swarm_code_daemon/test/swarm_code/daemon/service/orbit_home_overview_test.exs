defmodule SwarmCode.Daemon.Service.OrbitHomeOverviewTest do
  @moduledoc """
  orbit S2: `HomeOverview.build/4`, the bounded reads behind `home.overview`.
  The body is compared with Appendix C of the orbit spec by key set; no client
  DTO is referenced (they live in the other lane).
  """
  use ExUnit.Case, async: false
  import Ecto.Query

  alias SwarmCode.Daemon.Service.HomeOverview
  alias SwarmCode.Daemon.Service.Settings.Usage
  alias SwarmCode.Domain.{Cache, Projects, Repo, Scheduled, Settings}
  alias SwarmCode.Domain.Conversations
  alias SwarmCode.Domain.Conversations.{Conversation, Node, Run}
  alias SwarmCode.Domain.Engine.Questions

  @opts %{projects: 6, per_project: 12}

  setup_all do
    path =
      Path.join(System.tmp_dir!(), "orbit-overview-#{System.unique_integer([:positive])}")

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

  # Every test starts from an empty database (the fixture file is shared).
  setup c do
    Cache.clear()

    for table <- ~w(nodes runs messages conversations scheduled_tasks projects settings) do
      Repo.query!("DELETE FROM #{table}")
    end

    on_exit(fn ->
      for table <- ~w(nodes runs messages conversations scheduled_tasks projects settings),
          do: Repo.query!("DELETE FROM #{table}")
    end)

    %{root: c.path}
  end

  defp project!(c, name, opts \\ []) do
    root = Path.join(c.root, "p-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create(%{name: name, root_path: root})

    case opts[:last_opened_at] do
      nil -> project
      at -> Repo.update!(Ecto.Changeset.change(project, last_opened_at: at))
    end
  end

  # `title` is stamped past the changeset's 120-character limit, and the
  # research / scheduled-task ids past their foreign keys (the rows they name
  # live in other tables this test does not need).
  defp conversation!(project, title, updated_at, opts \\ []) do
    {:ok, conversation} = Conversations.create(project.id)

    # The overview leaves out a conversation nothing was said in (D11), so a
    # fixture conversation says one thing unless the test wants an empty one.
    unless opts[:empty] do
      {:ok, _} =
        Conversations.create_message(%{
          conversation_id: conversation.id,
          role: "user",
          content: "work on #{title}"
        })
    end

    changes =
      [title: title, updated_at: updated_at] ++
        Keyword.take(opts, [:research_id, :scheduled_task_id])

    Repo.query!("PRAGMA foreign_keys = OFF")

    try do
      Repo.update_all(from(c in Conversation, where: c.id == ^conversation.id), set: changes)
    after
      Repo.query!("PRAGMA foreign_keys = ON")
    end

    conversation
  end

  defp run!(conversation, attrs) do
    {:ok, run} =
      Conversations.create_run(
        Map.merge(
          %{
            conversation_id: conversation.id,
            kind: "chat",
            status: "running",
            started_at: DateTime.utc_now()
          },
          attrs
        )
      )

    run
  end

  # A running run: a root node with a progress, and a registry entry owned by
  # the test process (so it vanishes with it).
  defp live!(conversation, kind, started_at, progress \\ nil, attrs \\ %{}) do
    run = run!(conversation, Map.merge(%{kind: kind, started_at: started_at}, attrs))

    node =
      Repo.insert!(%Node{
        run_id: run.id,
        kind: "agent",
        status: "running",
        progress: progress,
        started_at: started_at
      })

    Repo.update_all(from(r in Run, where: r.id == ^run.id), set: [root_node_id: node.id])

    {:ok, _} =
      Registry.register(SwarmCode.Domain.Registry, {:run, run.id}, {conversation.id, kind})

    run
  end

  defp build(project, opts \\ @opts, month \\ %{"spend_usd" => 0.0, "budget_usd" => nil}),
    do: HomeOverview.build(project.id, opts, month, 7)

  defp project_body(body, project), do: Enum.find(body["projects"], &(&1["id"] == project.id))

  test "projects: the current one first, then by last opened (never-opened last), no scratch" do
    c = %{root: System.tmp_dir!()}
    current = project!(c, "current", last_opened_at: ~U[2026-01-01 00:00:00.000000Z])
    recent = project!(c, "recent", last_opened_at: ~U[2026-10-01 00:00:00.000000Z])
    older = project!(c, "older", last_opened_at: ~U[2026-09-01 00:00:00.000000Z])
    zeta = project!(c, "zeta")
    alpha = project!(c, "alpha")
    scratch = Projects.scratch!()

    body = build(current)

    assert Enum.map(body["projects"], & &1["id"]) ==
             [current.id, recent.id, older.id, alpha.id, zeta.id]

    assert Enum.map(body["projects"], & &1["current"]) == [true, false, false, false, false]
    refute scratch.id in Enum.map(body["projects"], & &1["id"])
    assert body["project_id"] == current.id
    assert body["revision"] == 7

    first = hd(body["projects"])
    assert first["last_opened_at"] == DateTime.to_unix(~U[2026-01-01 00:00:00Z], :millisecond)
    assert first["root_path"] == current.root_path
    assert first["name"] == "current"
    assert project_body(body, zeta)["last_opened_at"] == nil

    # The limit keeps the current project and takes the most recent others.
    limited = build(current, %{projects: 3, per_project: 12})
    assert Enum.map(limited["projects"], & &1["id"]) == [current.id, recent.id, older.id]

    one = build(current, %{projects: 1, per_project: 12})
    assert Enum.map(one["projects"], & &1["id"]) == [current.id]
  end

  test "a scratch current project still comes first" do
    c = %{root: System.tmp_dir!()}
    scratch = Projects.scratch!()
    other = project!(c, "other")

    body = build(scratch)

    assert Enum.map(body["projects"], &{&1["id"], &1["current"]}) == [
             {scratch.id, true},
             {other.id, false}
           ]
  end

  test "conversations: the newest per_project, the full count, research and scheduled left out",
       c do
    project = project!(c, "busy")

    for i <- 1..15 do
      conversation!(
        project,
        "work #{String.pad_leading("#{i}", 2, "0")}",
        DateTime.add(~U[2026-10-01 00:00:00.000000Z], i * 60)
      )
    end

    conversation!(project, "research one", ~U[2026-11-01 00:00:00.000000Z], research_id: 7)

    conversation!(project, "scheduled one", ~U[2026-11-02 00:00:00.000000Z],
      scheduled_task_id: Ecto.UUID.generate()
    )

    body = build(project)
    row = project_body(body, project)

    assert row["conversation_count"] == 15
    titles = Enum.map(row["conversations"], & &1["title"])
    assert length(titles) == 12
    assert hd(titles) == "work 15"
    assert List.last(titles) == "work 04"
    refute "research one" in titles
    refute "scheduled one" in titles

    updated = Enum.map(row["conversations"], & &1["updated_at"])
    assert updated == Enum.sort(updated, :desc)

    assert hd(row["conversations"]) |> Map.keys() |> Enum.sort() ==
             ~w(id live live_kind title unread updated_at waiting)

    small = build(project, %{projects: 2, per_project: 1})
    assert [%{"title" => "work 15"}] = project_body(small, project)["conversations"]
    assert project_body(small, project)["conversation_count"] == 15
  end

  test "an empty conversation is not on the map: no count, no row (D11, first run)", c do
    # What `SessionSelection.open(root, :latest)` leaves in a project nothing
    # was said in: one conversation with no run and no user message.
    fresh = project!(c, "fresh", last_opened_at: ~U[2026-10-02 00:00:00.000000Z])
    conversation!(fresh, "New conversation", ~U[2026-10-02 00:00:01.000000Z], empty: true)

    used = project!(c, "used", last_opened_at: ~U[2026-10-01 00:00:00.000000Z])
    conversation!(used, "real work", ~U[2026-10-01 00:00:01.000000Z])
    conversation!(used, "New conversation", ~U[2026-10-01 00:00:02.000000Z], empty: true)

    # A conversation with only a run (no user message row) is not empty, and a
    # superseded (edited) prompt does not count as one.
    ran = conversation!(used, "ran", ~U[2026-10-01 00:00:03.000000Z], empty: true)
    run!(ran, %{status: "done"})

    edited = conversation!(used, "edited", ~U[2026-10-01 00:00:04.000000Z], empty: true)

    {:ok, said} =
      Conversations.create_message(%{conversation_id: edited.id, role: "user", content: "old"})

    Repo.update_all(from(m in Conversations.Message, where: m.id == ^said.id),
      set: [superseded_at: ~U[2026-10-01 00:00:05.000000Z]]
    )

    body = build(fresh)

    assert {0, 0} = counts(project_body(body, fresh))
    assert project_body(body, fresh)["conversations"] == []

    row = project_body(body, used)
    assert row["conversation_count"] == 2
    assert Enum.map(row["conversations"], & &1["title"]) == ["ran", "real work"]
  end

  test "the window is per project", c do
    first = project!(c, "first", last_opened_at: ~U[2026-10-02 00:00:00.000000Z])
    second = project!(c, "second", last_opened_at: ~U[2026-10-01 00:00:00.000000Z])

    for i <- 1..3,
        do: conversation!(first, "a#{i}", DateTime.add(~U[2026-10-01 00:00:00.000000Z], i))

    for i <- 1..20,
        do: conversation!(second, "b#{i}", DateTime.add(~U[2026-10-01 00:00:00.000000Z], i))

    body = build(first)

    assert {3, 3} = counts(project_body(body, first))
    assert {20, 12} = counts(project_body(body, second))
  end

  defp counts(row), do: {row["conversation_count"], length(row["conversations"])}

  test "titles are clipped to 256 bytes on a character boundary", c do
    project = project!(c, "clip")
    conversation!(project, String.duplicate("é", 200), ~U[2026-10-01 00:00:00.000000Z])

    [%{"title" => title}] = project_body(build(project), project)["conversations"]
    assert byte_size(title) <= 256
    assert String.valid?(title)
    assert title == String.duplicate("é", 128)
  end

  test "live runs: oldest first, the presentation kind, the root node's progress", c do
    project = project!(c, "live")
    chat = conversation!(project, "chat work", ~U[2026-10-01 00:00:03.000000Z])
    swarm = conversation!(project, "swarm work", ~U[2026-10-01 00:00:02.000000Z])
    idle = conversation!(project, "idle work", ~U[2026-10-01 00:00:01.000000Z])

    goal =
      live!(chat, "chat", ~U[2026-10-01 12:00:02.000000Z], 40, %{goal_id: Ecto.UUID.generate()})

    older = live!(swarm, "swarm", ~U[2026-10-01 12:00:01.000000Z], 60)
    compact = live!(idle, "compact", ~U[2026-10-01 12:00:03.000000Z], 250)

    body = build(project)

    assert Enum.map(body["live_runs"], &{&1["id"], &1["kind"], &1["progress"]}) == [
             {older.id, "swarm", 60},
             {goal.id, "goal", 40},
             {compact.id, "chat", 100}
           ]

    assert body["live_overflow"] == 0

    assert hd(body["live_runs"]) == %{
             "id" => older.id,
             "project_id" => project.id,
             "conversation_id" => swarm.id,
             "kind" => "swarm",
             "progress" => 60,
             "started_at" => DateTime.to_unix(~U[2026-10-01 12:00:01Z], :millisecond)
           }

    by_title = Map.new(project_body(body, project)["conversations"], &{&1["title"], &1})
    assert %{"live" => true, "live_kind" => "swarm"} = by_title["swarm work"]
    assert %{"live" => true, "live_kind" => "goal"} = by_title["chat work"]
    assert %{"live" => true, "live_kind" => "chat"} = by_title["idle work"]
    assert project_body(body, project)["live"] == 3
  end

  test "a conversation with two live runs counts once and shows its newest run's kind", c do
    project = project!(c, "two")
    conversation = conversation!(project, "busy", ~U[2026-10-01 00:00:00.000000Z])
    live!(conversation, "chat", ~U[2026-10-01 12:00:01.000000Z])
    live!(conversation, "swarm", ~U[2026-10-01 12:00:02.000000Z])

    body = build(project)
    assert length(body["live_runs"]) == 2
    assert project_body(body, project)["live"] == 1
    assert [%{"live_kind" => "swarm"}] = project_body(body, project)["conversations"]
  end

  test "a consensus run is a consensus bar; a registry entry without a run row is ignored", c do
    project = project!(c, "consensus")
    conversation = conversation!(project, "judged", ~U[2026-10-01 00:00:00.000000Z])
    run = live!(conversation, "chat", ~U[2026-10-01 12:00:01.000000Z], nil, %{consensus: true})

    {:ok, _} =
      Registry.register(
        SwarmCode.Domain.Registry,
        {:run, Ecto.UUID.generate()},
        {conversation.id, nil}
      )

    assert [%{"id" => id, "kind" => "consensus", "progress" => nil}] = build(project)["live_runs"]
    assert id == run.id
  end

  test "seven live runs: five bars and an overflow of two", c do
    project = project!(c, "seven")
    conversation = conversation!(project, "many", ~U[2026-10-01 00:00:00.000000Z])

    runs =
      for i <- 1..7,
          do: live!(conversation, "swarm", DateTime.add(~U[2026-10-01 12:00:00.000000Z], i))

    body = build(project)
    assert Enum.map(body["live_runs"], & &1["id"]) == runs |> Enum.take(5) |> Enum.map(& &1.id)
    assert body["live_overflow"] == 2
  end

  test "waiting: per conversation, per project (including one outside the page) and in total",
       c do
    project = project!(c, "waits")
    elsewhere = project!(c, "elsewhere")

    old = conversation!(project, "oldest", ~U[2026-09-01 00:00:00.000000Z])

    for i <- 1..12,
        do: conversation!(project, "new #{i}", DateTime.add(~U[2026-10-01 00:00:00.000000Z], i))

    near = conversation!(project, "newest", ~U[2026-10-02 00:00:00.000000Z])
    far = conversation!(elsewhere, "far", ~U[2026-10-01 00:00:00.000000Z])

    for conversation <- [old, near, far] do
      run = Ecto.UUID.generate()
      on_exit(fn -> Questions.delete_run(run) end)
      Questions.put(conversation.id, run, Ecto.UUID.generate(), :approval)
    end

    extra = Ecto.UUID.generate()
    on_exit(fn -> Questions.delete_run(extra) end)
    Questions.put(near.id, extra, Ecto.UUID.generate(), :question)

    body = build(project)

    assert body["waiting_total"] == 4
    row = project_body(body, project)
    assert row["waiting"] == 3
    assert project_body(body, elsewhere)["waiting"] == 1

    by_title = Map.new(row["conversations"], &{&1["title"], &1["waiting"]})
    assert by_title["newest"] == 2
    # "oldest" is outside the 12 newest: counted for the project, not listed.
    refute Map.has_key?(by_title, "oldest")
  end

  test "unread: a finished run after the conversation was last seen", c do
    project = project!(c, "unread")
    unseen = conversation!(project, "unseen", ~U[2026-10-01 00:00:03.000000Z])
    stale = conversation!(project, "stale", ~U[2026-10-01 00:00:02.000000Z])
    fresh = conversation!(project, "fresh", ~U[2026-10-01 00:00:01.000000Z])
    _quiet = conversation!(project, "quiet", ~U[2026-10-01 00:00:00.000000Z])

    finished = ~U[2026-10-01 10:00:00.000000Z]

    for conversation <- [unseen, stale, fresh],
        do: run!(conversation, %{status: "done", finished_at: finished})

    Repo.update_all(from(x in Conversation, where: x.id == ^stale.id),
      set: [last_seen_at: ~U[2026-10-01 09:00:00.000000Z]]
    )

    Repo.update_all(from(x in Conversation, where: x.id == ^fresh.id),
      set: [last_seen_at: ~U[2026-10-01 11:00:00.000000Z]]
    )

    by_title =
      Map.new(
        project_body(build(project), project)["conversations"],
        &{&1["title"], &1["unread"]}
      )

    assert by_title == %{"unseen" => true, "stale" => true, "fresh" => false, "quiet" => false}
  end

  describe "month" do
    test "no budget reads nil; a budget reads a float; only this month's runs are summed", c do
      project = project!(c, "spend")
      conversation = conversation!(project, "costly", ~U[2026-10-01 00:00:00.000000Z])
      now = DateTime.utc_now()
      last_month = DateTime.add(now, -45 * 86_400)

      run!(conversation, %{status: "done", started_at: now, cost_usd: 1.25})
      run!(conversation, %{status: "done", started_at: now, cost_usd: 2.25})
      run!(conversation, %{status: "done", started_at: last_month, cost_usd: 99.0})

      assert %{"month" => %{"spend_usd" => spend, "budget_usd" => nil}} =
               HomeOverview.build(project.id, @opts, nil, 0)

      assert is_float(spend)

      assert_in_delta spend,
                      3.5,
                      1.0e-9 +
                        if(Date.beginning_of_month(Date.utc_today()) == Date.utc_today(),
                          do: 0,
                          else: 0
                        )

      {:ok, _} = Settings.update(%{monthly_budget_usd: 60.0})
      Cache.clear()

      assert %{"month" => %{"budget_usd" => budget}} =
               HomeOverview.build(project.id, @opts, nil, 0)

      assert budget === 60.0

      # A cached pair is used as given.
      cached = %{"spend_usd" => 1.5, "budget_usd" => 9.0}
      assert %{"month" => ^cached} = HomeOverview.build(project.id, @opts, cached, 0)
    end

    test "Usage.month/0 is two floats; body/0 keeps its integer budget" do
      {:ok, _} = Settings.update(%{monthly_budget_usd: 50.0})
      assert %{"spend_usd" => spend, "budget_usd" => 50.0} = Usage.month()
      assert spend === 0.0
      assert Usage.body()["month"]["budget_usd"] === 50

      {:ok, _} = Settings.update(%{monthly_budget_usd: nil})
      assert %{"budget_usd" => nil} = Usage.month()
    end
  end

  describe "next_scheduled" do
    test "an enabled future task is returned; a disabled or past one is not", c do
      project = project!(c, "scheduled")

      assert build(project)["next_scheduled"] == nil

      {:ok, task} =
        Scheduled.create(%{
          name: "nightly deps audit",
          prompt: "audit",
          kind: "chat",
          project_id: project.id,
          schedule_kind: "daily",
          time_of_day: "03:30",
          timezone: "UTC"
        })

      body = build(project)["next_scheduled"]

      assert body == %{
               "id" => task.id,
               "name" => "nightly deps audit",
               "project_id" => project.id,
               "project_name" => "scheduled",
               "next_run_at" => DateTime.to_unix(task.next_run_at, :millisecond)
             }

      {:ok, _} = Scheduled.toggle(task)
      assert build(project)["next_scheduled"] == nil

      {:ok, task} = Scheduled.toggle(Scheduled.get!(task.id))

      Repo.update_all(from(t in Scheduled.Task, where: t.id == ^task.id),
        set: [next_run_at: DateTime.add(DateTime.utc_now(), -3600) |> DateTime.truncate(:second)]
      )

      assert build(project)["next_scheduled"] == nil
    end
  end

  # Appendix C of the orbit spec: the shared fixture. These are its key sets at
  # every level, and the daemon's body (plus the backend's request_id/state/error
  # wrapper) must equal them.
  @appendix_c %{
    top:
      ~w(request_id state error revision project_id projects live_runs live_overflow waiting_total month next_scheduled),
    project:
      ~w(id name root_path current last_opened_at conversation_count live waiting conversations),
    conversation: ~w(id title updated_at live live_kind waiting unread),
    run: ~w(id project_id conversation_id kind progress started_at),
    month: ~w(spend_usd budget_usd),
    scheduled: ~w(id name project_id project_name next_run_at)
  }

  test "the body's key sets equal Appendix C at every level", c do
    project = project!(c, "contract")
    other = project!(c, "other", last_opened_at: ~U[2026-10-01 00:00:00.000000Z])
    one = conversation!(project, "one", ~U[2026-10-01 00:00:00.000000Z])
    conversation!(other, "two", ~U[2026-10-01 00:00:00.000000Z])
    live!(one, "swarm", ~U[2026-10-01 12:00:00.000000Z], 10)

    {:ok, _} =
      Scheduled.create(%{
        name: "n",
        prompt: "p",
        kind: "chat",
        project_id: project.id,
        schedule_kind: "daily",
        time_of_day: "03:30",
        timezone: "UTC"
      })

    body =
      project
      |> build(@opts, %{"spend_usd" => 38.4, "budget_usd" => 60.0})
      |> Map.merge(%{"request_id" => "req-1", "state" => "ready", "error" => nil})

    assert sorted(body) == sorted_keys(@appendix_c.top)
    assert length(body["projects"]) == 2
    for p <- body["projects"], do: assert(sorted(p) == sorted_keys(@appendix_c.project))

    for p <- body["projects"], conv <- p["conversations"] do
      assert sorted(conv) == sorted_keys(@appendix_c.conversation)
    end

    assert [run] = body["live_runs"]
    assert sorted(run) == sorted_keys(@appendix_c.run)
    assert sorted(body["month"]) == sorted_keys(@appendix_c.month)
    assert sorted(body["next_scheduled"]) == sorted_keys(@appendix_c.scheduled)

    # The body survives a JSON round trip unchanged (what the wire does).
    assert body |> Jason.encode!() |> Jason.decode!() == body
  end

  test "an empty month and nothing scheduled still has every top-level key", c do
    project = project!(c, "bare")
    body = build(project)

    assert sorted(body) ==
             sorted_keys(@appendix_c.top -- ~w(request_id state error))

    assert body["live_runs"] == [] and body["live_overflow"] == 0
    assert body["waiting_total"] == 0 and body["next_scheduled"] == nil
    assert [%{"conversations" => []}] = body["projects"]
  end

  test "six projects with conversations, live runs and waits cost at most eight queries", c do
    projects =
      for i <- 1..6,
          do:
            project!(c, "p#{i}", last_opened_at: DateTime.add(~U[2026-10-01 00:00:00.000000Z], i))

    for project <- projects,
        i <- 1..4,
        do: conversation!(project, "c#{i}", DateTime.add(~U[2026-10-01 00:00:00.000000Z], i))

    current = hd(projects)
    [first | _] = Repo.all(from(x in Conversation, where: x.project_id == ^current.id))
    live!(first, "swarm", ~U[2026-10-01 12:00:00.000000Z], 5)
    run = Ecto.UUID.generate()
    on_exit(fn -> Questions.delete_run(run) end)
    Questions.put(first.id, run, Ecto.UUID.generate(), :approval)

    {:ok, _} =
      Scheduled.create(%{
        name: "n",
        prompt: "p",
        kind: "chat",
        project_id: current.id,
        schedule_kind: "daily",
        time_of_day: "03:30",
        timezone: "UTC"
      })

    test_pid = self()
    handler = "orbit-queries-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:swarm_code, :domain, :repo, :query],
      &__MODULE__.handle_query/4,
      test_pid
    )

    body =
      try do
        build(current, %{projects: 6, per_project: 12})
      after
        :telemetry.detach(handler)
      end

    assert length(body["projects"]) == 6
    queries = drain_queries(0)
    assert queries in 1..8, "expected at most 8 queries, ran #{queries}"
  end

  @doc false
  def handle_query(_event, _measurements, _metadata, pid), do: send(pid, :query)

  defp drain_queries(count) do
    receive do
      :query -> drain_queries(count + 1)
    after
      0 -> count
    end
  end

  defp sorted(map), do: map |> Map.keys() |> Enum.sort()
  defp sorted_keys(keys), do: Enum.sort(keys)
end
