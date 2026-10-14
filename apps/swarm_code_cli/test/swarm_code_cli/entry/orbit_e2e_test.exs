defmodule SwarmCodeCLI.Release.OrbitE2ETest do
  @moduledoc """
  orbit §8.2: Home end to end, with nothing fake on the wire. The persisted
  backend on a fixture database, the service's Unix socket, the terminal's own
  transport (`DataSource.Daemon`) and codec, and for the session tests the real
  `SessionRuntime` and reducer started the way `PersistedSession.run_ui/3`
  starts them (selection from `tui_selection/0`, `home?` from the opening).

    * the wire: `home.overview` decodes into U's `DTO.HomeOverview` with the
      exact shape check, `conversation.search` into `DTO.ConversationList`, a
      body over its byte limit is a typed `capacity_exceeded` failure that keeps
      the connection (S issue 1), and `home_stale` arrives on the shell watch as
      `%Delta{kind: :home_stale}` whose body names the home revision, not the
      envelope's (U issue 1);
    * the session: no flag and no cli.json open Home on the first frame, the
      overview arrives, a burst of triggers is one push and one re-query, and
      Esc lands on the project's latest conversation;
    * `-c` (`SWARM_CONVERSATION=latest`) and an explicit cli.json `latest` open
      no Home and ask for no overview.

  The overview builder is S's own (`HomeOverview.build/4`), wrapped only to
  tell this test each time it ran.
  """
  use ExUnit.Case, async: false
  import Ecto.Query

  alias SwarmCode.Daemon.Service.{HomeOverview, SessionSelection}
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Repo, UIState}
  alias SwarmCode.Domain.Conversations.Conversation
  alias SwarmCode.Protocol.Scope
  alias SwarmCodeCLI.Release.PersistedSession
  alias SwarmCodeCLI.UI.{Capabilities, Home, Init, Projector, SessionRuntime, Size}
  alias SwarmCodeCLI.UI.DataSource
  alias SwarmCodeCLI.UI.DataSource.{AdmissionError, Delivery, Delta, DTO, Request, Watch}

  @moduletag timeout: 120_000
  @env ~w(SWARM_CONVERSATION SWARM_SETTINGS_ONLY SWARM_RESUME_PICKER SWARM_SETTINGS_OPEN)
  @global %Scope{kind: :global, id: nil, generation: 0}

  setup do
    base = Path.join(System.tmp_dir!(), "orbit-e2e-#{System.unique_integer([:positive])}")
    config = Path.join(base, "config")
    File.mkdir_p!(config)
    File.chmod!(base, 0o700)
    File.chmod!(config, 0o700)

    saved_env = Map.new(@env, &{&1, System.get_env(&1)})
    Enum.each(@env, &System.delete_env/1)
    prior = Application.get_env(:swarm_code_daemon, :domain_config_dir)
    # cli.json (`Release.preferences_path/0`) lives here, never in the real one.
    Application.put_env(:swarm_code_daemon, :domain_config_dir, config)

    on_exit(fn ->
      Cache.clear()

      if prior,
        do: Application.put_env(:swarm_code_daemon, :domain_config_dir, prior),
        else: Application.delete_env(:swarm_code_daemon, :domain_config_dir)

      Enum.each(saved_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      File.rm_rf!(base)
    end)

    start_supervised!(
      {Repo,
       database: Path.join(base, "fixture.db"),
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

    Cache.clear()
    unless Process.whereis(UIState), do: start_supervised!(UIState)

    {:ok, root_a} = real_dir(Path.join(base, "orbit-a"))
    {:ok, root_b} = real_dir(Path.join(base, "orbit-b"))

    # The projects come from the launcher's own selection (as a first launch in
    # each folder makes them); the conversations get prompts, titles and ages.
    {:ok, %{project: project_b, conversation: elsewhere}} =
      SessionSelection.open(root_b, conversation: :new)

    {:ok, %{project: project_a, conversation: oldest}} =
      SessionSelection.open(root_a, conversation: :new)

    {:ok, %{conversation: middle}} = SessionSelection.open(root_a, conversation: :new)
    {:ok, %{conversation: latest}} = SessionSelection.open(root_a, conversation: :new)

    now = DateTime.utc_now()
    worked!(elsewhere, "other project task", DateTime.add(now, -3600, :second))
    worked!(oldest, "first task", DateTime.add(now, -2 * 86_400, :second))
    worked!(middle, "second task", DateTime.add(now, -3 * 3600, :second))
    worked!(latest, "third task", DateTime.add(now, -120, :second))

    %{
      base: base,
      root_a: root_a,
      project_a: project_a,
      project_b: project_b,
      latest: latest,
      middle: middle,
      oldest: oldest,
      elsewhere: elsewhere
    }
  end

  defp real_dir(path) do
    File.mkdir_p!(path)
    SwarmCode.Domain.Tools.Path.real_path(path)
  end

  defp worked!(conversation, prompt, at) do
    {:ok, _} =
      Conversations.create_message(%{
        conversation_id: conversation.id,
        role: "user",
        content: prompt
      })

    Repo.update_all(from(c in Conversation, where: c.id == ^conversation.id),
      set: [title: prompt, updated_at: at]
    )
  end

  # ------------------------------------------------------------- the stack

  # The backend, the socket service and the terminal's transport, as
  # `run_ui/3` starts them. `home_overview` is S's builder, reporting each run.
  defp stack!(c, session, name) do
    test = self()
    epoch = Ecto.UUID.generate()
    socket_dir = Path.join(c.base, "sock-#{name}")
    File.mkdir_p!(socket_dir)
    File.chmod!(socket_dir, 0o700)
    path = Path.join(socket_dir, "s")
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    built = fn project, options, month, revision ->
      send(test, {:home_built, revision})
      HomeOverview.build(project, options, month, revision)
    end

    backend =
      start_supervised!(
        {Backend,
         mode: :persisted,
         repo: Repo,
         project_root: session.project.root_path,
         project_id: session.project.id,
         conversation_id: session.conversation.id,
         source_epoch: epoch,
         work: %{home_overview: built}},
        id: {:backend, name}
      )

    start_supervised!(
      {SwarmCode.Daemon.Service,
       socket_path: path, nonce: nonce, source_epoch: epoch, backend: backend},
      id: {:service, name}
    )

    client =
      start_supervised!(
        {DataSource.Daemon,
         socket_path: path, nonce: nonce, source_epoch: epoch, timeout: 30_000},
        id: {:client, name}
      )

    %{backend: backend, client: client, epoch: epoch}
  end

  # ------------------------------------------------------------- the wire

  defp request(id, kind, expected),
    do: %Request{
      request_id: id,
      kind: kind,
      scope: @global,
      generation: 0,
      origin: if(expected == :home_overview, do: {:home, :overview}, else: {:home, :search}),
      deadline: System.system_time(:millisecond) + 20_000,
      expected_response: expected
    }

  defp answer(client, id) do
    receive do
      {:swarm_code_ui_data, _, receipt, %Delivery{kind: :response, request_id: ^id} = delivery} ->
        :ok = DataSource.consume(client, receipt, :applied)
        delivery.body

      # The transport hands out one delivery at a time: a shell delta that
      # came first is consumed so the answer can follow.
      {:swarm_code_ui_data, _, receipt, %Delivery{}} ->
        :ok = DataSource.consume(client, receipt, :applied)
        answer(client, id)

      {:swarm_code_ui_closed, _, reason} ->
        flunk("the data source closed: #{inspect(reason)}")
    after
      10_000 -> flunk("no answer to #{id}")
    end
  end

  defp next_delta(client, kind) do
    receive do
      {:swarm_code_ui_data, _, receipt, %Delivery{kind: :delta, body: %Delta{kind: ^kind}} = d} ->
        :ok = DataSource.consume(client, receipt, :applied)
        d

      {:swarm_code_ui_data, _, receipt, %Delivery{}} ->
        :ok = DataSource.consume(client, receipt, :applied)
        next_delta(client, kind)

      {:swarm_code_ui_closed, _, reason} ->
        flunk("the data source closed: #{inspect(reason)}")
    after
      10_000 -> flunk("no #{kind} delta")
    end
  end

  test "the wire: overview, search, too large and home_stale through the socket and the codec",
       c do
    {:ok, session} = SessionSelection.open(c.root_a)
    stack = stack!(c, session, :wire)
    assert {:ok, "orbit"} = DataSource.bind_owner(stack.client, self(), "orbit")

    shell = %Watch{
      watch_ref: "shell",
      slot: :shell,
      scope: @global,
      generation: 0,
      page_size: 20,
      byte_limit: 262_144
    }

    assert :ok = DataSource.watch(stack.client, shell)

    assert_receive {:swarm_code_ui_data, _, ready, %Delivery{kind: :watch_ready}}, 10_000
    assert :ok = DataSource.consume(stack.client, ready, :applied)

    # home.overview decodes into U's DTO (the codec's exact-shape check ran).
    overview = request("home-1", {:home_overview, 6, 12, 131_072}, :home_overview)
    assert :ok = DataSource.query(stack.client, overview)
    assert %DTO.HomeOverview{state: :ready} = body = answer(stack.client, "home-1")
    assert_receive {:home_built, 0}
    assert body.request_id == "home-1"
    assert body.project_id == c.project_a.id

    assert [%DTO.HomeProject{current: true} = mine, %DTO.HomeProject{current: false} = theirs] =
             body.projects

    assert {mine.id, mine.name, mine.conversation_count} == {c.project_a.id, "orbit-a", 3}

    assert {theirs.id, theirs.name, theirs.root_path} ==
             {c.project_b.id, "orbit-b", c.project_b.root_path}

    assert Enum.map(mine.conversations, & &1.title) == ["third task", "second task", "first task"]
    assert Enum.map(theirs.conversations, & &1.title) == ["other project task"]
    assert body.live_runs == [] and body.waiting_total == 0
    assert %DTO.HomeMonth{spend_usd: spend} = body.month
    assert is_float(spend)

    # conversation.search decodes into the list's DTO, project-filtered.
    search = request("home-2", {:conversation_search, "second", 50, 262_144}, :conversation_list)
    assert :ok = DataSource.query(stack.client, search)

    # A list body's state is the list's own (`:idle`), never `:error` here.
    assert %DTO.ConversationList{state: :idle, items: [hit], project: "orbit-a"} =
             answer(stack.client, "home-2")

    assert {hit.id, hit.title, hit.last_prompt} == {c.middle.id, "second task", "second task"}

    foreign =
      request("home-3", {:conversation_search, "other project", 50, 262_144}, :conversation_list)

    assert :ok = DataSource.query(stack.client, foreign)
    assert %DTO.ConversationList{state: :idle, items: []} = answer(stack.client, "home-3")

    # S issue 1: a body over its byte limit is the closed `capacity_exceeded`
    # code; the client takes it as a typed failure and the connection stays.
    tight = request("home-4", {:home_overview, 6, 12, 64}, :home_overview)
    assert :ok = DataSource.query(stack.client, tight)

    assert %DTO.HomeOverview{
             state: :error,
             request_id: "home-4",
             error: %AdmissionError{code: :capacity_exceeded}
           } = answer(stack.client, "home-4")

    assert :sys.get_state(stack.client).phase == :bound

    # U issue 1: a burst of triggers is one `home_stale` on the shell watch;
    # its body names the backend's home revision (1, the first push), the
    # envelope the watch's own revision. The codec accepts the pair.
    for _ <- 1..5, do: send(stack.backend, {:waiting_changed})

    assert %Delivery{body: %Delta{body: %DTO.HomeStale{revision: 1}} = delta} =
             next_delta(stack.client, :home_stale)

    assert delta.revision == :sys.get_state(stack.backend).revision
    refute_receive {:swarm_code_ui_data, _, _, %Delivery{body: %Delta{kind: :home_stale}}}, 800

    # A second burst is the next home revision while the watch's revision has
    # not moved: the two disagree (2 against 1), which the codec's
    # `body_revision?/2` would refuse (closing the session) but for Home's
    # exemption.
    for _ <- 1..3, do: send(stack.backend, {:waiting_changed})

    assert %Delivery{body: %Delta{body: %DTO.HomeStale{revision: 2}} = second} =
             next_delta(stack.client, :home_stale)

    assert second.revision == :sys.get_state(stack.backend).revision
    assert second.revision != second.body.revision
    assert :sys.get_state(stack.client).phase == :bound

    # The next overview reflects it.
    again = request("home-5", {:home_overview, 6, 12, 131_072}, :home_overview)
    assert :ok = DataSource.query(stack.client, again)
    assert %DTO.HomeOverview{state: :ready, revision: 2} = answer(stack.client, "home-5")
    refute_received {:swarm_code_ui_closed, _, _}
  end

  # ---------------------------------------------------------- the session

  @size %Size{columns: 120, rows: 36}

  # `run_ui/3`: the selection the launcher made, the opening from cli.json or
  # the environment, the Init through the same `struct/2`.
  defp session!(c, name) do
    {selection, opening} = PersistedSession.tui_selection()
    {:ok, session} = SessionSelection.open(c.root_a, conversation: selection)
    stack = stack!(c, session, name)
    caps = %Capabilities{size: @size, full_screen?: true}

    init = %Init{
      focus: "composer",
      size: @size,
      capabilities: caps,
      source_epoch: stack.epoch,
      destination: {:conversation, session.conversation.id},
      now: System.system_time(:millisecond),
      launch_facts: %{cli_version: "0.2.2", project_root: c.root_a, home: c.base}
    }

    init = struct(init, resume_picker?: opening == :picker, home?: opening == :home)

    runtime =
      start_supervised!(
        {SessionRuntime, init: init, data_source: stack.client, frame_ms: 60_000},
        id: {:runtime, name}
      )

    {:ok, _slot} = SessionRuntime.register_terminal(runtime, self(), 1, caps)
    until(runtime, fn _ui -> SessionRuntime.status(runtime).phase == :running end)
    Map.merge(stack, %{runtime: runtime, session: session, opening: opening})
  end

  # Polls the runtime's state until `check` holds, for at most 15 s (each poll
  # is a call into the runtime; nothing sleeps).
  defp until(runtime, check),
    do: until(runtime, check, System.monotonic_time(:millisecond) + 15_000)

  defp until(runtime, check, deadline) do
    ui = SessionRuntime.snapshot(runtime)

    cond do
      check.(ui) -> ui
      System.monotonic_time(:millisecond) > deadline -> flunk("never: #{inspect(ui.home)}")
      true -> until(runtime, check, deadline)
    end
  end

  defp first_region(ui) do
    {scene, _actions} = Projector.project(ui)
    hd(scene.regions).id
  end

  defp settled?(ui),
    do:
      match?(
        %{home: %Home{overview: %DTO.HomeOverview{state: :ready}, overview_request: nil}},
        ui
      )

  defp drain_builds(acc) do
    receive do
      {:home_built, revision} -> drain_builds([revision | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "no flag: Home on the first frame, the overview, one re-query per push, Esc to the latest",
       c do
    s = session!(c, :home)
    assert s.opening == :home
    assert s.session.conversation.id == c.latest.id

    # Home is on the very first frame, before the shell watch answers.
    ui = SessionRuntime.snapshot(s.runtime)
    assert %Home{} = ui.home
    assert first_region(ui) == "home"

    # The overview arrives over the socket.
    ui = until(s.runtime, &settled?/1)

    assert [%DTO.HomeProject{current: true, name: "orbit-a"}, %DTO.HomeProject{name: "orbit-b"}] =
             ui.home.overview.projects

    assert first_region(ui) == "home"
    assert [_ | _] = drain_builds([])

    # The resume list is the project's conversations, newest first.
    ui = until(s.runtime, &match?(%{conversations: %DTO.ConversationList{items: [_ | _]}}, &1))
    assert Enum.map(Home.rows(ui), & &1.title) == ["third task", "second task", "first task"]

    # A burst of triggers: one push, one re-query (single flight, 500 ms debounce).
    held = ui.read_model.home_revision
    for _ <- 1..5, do: send(s.backend, {:waiting_changed})
    assert_receive {:home_built, revision}, 5_000
    assert revision == held + 1
    refute_receive {:home_built, _}, 1_000

    ui = until(s.runtime, &(settled?(&1) and &1.home.seen_revision == held + 1))
    assert ui.read_model.home_revision == held + 1
    assert ui.home.overview.revision == held + 1

    # Esc in the composer: Home goes, the conversation underneath is the latest.
    :ok = SessionRuntime.action(s.runtime, {:home, :escape})
    ui = until(s.runtime, &(&1.home == nil))
    assert ui.destination == {:conversation, c.latest.id}
    refute first_region(ui) == "home"

    # Closed, Home asks for nothing; Alt-O opens it again and it asks once.
    send(s.backend, {:waiting_changed})
    refute_receive {:home_built, _}, 1_000
    :ok = SessionRuntime.action(s.runtime, :open_home)
    assert_receive {:home_built, _}, 5_000
    ui = until(s.runtime, &settled?/1)
    assert first_region(ui) == "home"
    assert ui.home.opened_over == {:conversation, c.latest.id}
  end

  test "-c and an explicit cli.json latest open no Home and ask for no overview", c do
    System.put_env("SWARM_CONVERSATION", "latest")
    s = session!(c, :continue)
    assert s.opening == nil
    assert s.session.conversation.id == c.latest.id
    ui = until(s.runtime, &match?(%{watches: %{shell: %{status: :ready}}}, &1))
    assert ui.home == nil
    refute first_region(ui) == "home"
    refute_receive {:home_built, _}, 500

    System.delete_env("SWARM_CONVERSATION")
    cli = SwarmCodeCLI.Release.preferences_path()
    assert Path.dirname(cli) == Path.join(c.base, "config")
    File.write!(cli, Jason.encode!(%{"startup_conversation" => "latest"}))
    File.chmod!(cli, 0o600)
    assert PersistedSession.startup_selection(cli) == {:latest, nil}

    s = session!(c, :latest)
    assert s.opening == nil
    ui = until(s.runtime, &match?(%{watches: %{shell: %{status: :ready}}}, &1))
    assert ui.home == nil
    refute first_region(ui) == "home"
    refute_receive {:home_built, _}, 500
  end
end
