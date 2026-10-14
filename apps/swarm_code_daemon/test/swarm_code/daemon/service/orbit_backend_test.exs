defmodule SwarmCode.Daemon.Service.OrbitBackendTest do
  @moduledoc """
  orbit: the persisted service's Home half. S3 `conversation.search` (the
  projection), S4 the two wire operations through a backend, S5 the debounced
  `home_stale` push, S8 the guard that opening a conversation never marks it
  seen. Setup follows `Pass70ConversationTest`; no client DTO is referenced.
  """
  use ExUnit.Case, async: false
  import Ecto.Query

  alias SwarmCode.Daemon.Service
  alias SwarmCode.Daemon.Service.LiveBackend
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Daemon.Service.PersistedProjection
  alias SwarmCode.Domain.{Cache, Conversations, Projects, Repo}
  alias SwarmCode.Domain.Conversations.{Conversation, Message, Run}
  alias SwarmCode.Protocol.{Envelope, Frame, Scope, ServiceRequest}
  alias SwarmCode.Protocol.Message, as: Wire

  setup_all do
    path = Path.join(System.tmp_dir!(), "orbit-backend-#{System.unique_integer([:positive])}")
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

  @tables ~w(nodes runs messages conversations scheduled_tasks projects settings)

  # Every test starts from an empty database (the fixture file is shared) and
  # owns its project.
  setup c do
    Cache.clear()
    for table <- @tables, do: Repo.query!("DELETE FROM #{table}")
    on_exit(fn -> for table <- @tables, do: Repo.query!("DELETE FROM #{table}") end)
    root = Path.join(c.path, "project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    {:ok, project} = Projects.create(%{name: "Orbit", root_path: root})
    {:ok, project} = Projects.update(project, %{approval_mode: "auto"})
    %{project: project, root: root}
  end

  defp conversation!(project, title, updated_at \\ ~U[2026-10-01 00:00:00.000000Z]) do
    {:ok, conversation} = Conversations.create(project.id)

    Repo.update_all(from(c in Conversation, where: c.id == ^conversation.id),
      set: [title: title, updated_at: updated_at]
    )

    conversation
  end

  # The overview leaves out a conversation nothing was said in (D11), so the
  # overview tests use conversations that have one prompt.
  defp used!(project, title, updated_at) do
    conversation = conversation!(project, title, updated_at)
    say!(conversation, "work on #{title}")
    conversation
  end

  defp say!(conversation, text, attrs \\ %{}) do
    {:ok, message} =
      Conversations.create_message(
        Map.merge(%{conversation_id: conversation.id, role: "user", content: text}, attrs)
      )

    message
  end

  describe "S3 conversation search (projection)" do
    defp titles(project, query, limit \\ 50) do
      {:ok, rows, false} = PersistedProjection.conversation_search(project.id, query, limit)
      Enum.map(rows, & &1.title)
    end

    test "a title hit and a prompt hit, newest first, with the list's row shape", c do
      by_title = conversation!(c.project, "Rate limit chip", ~U[2026-10-01 00:00:01.000000Z])
      by_prompt = conversation!(c.project, "Untouched", ~U[2026-10-01 00:00:02.000000Z])
      miss = conversation!(c.project, "Other work", ~U[2026-10-01 00:00:03.000000Z])
      say!(by_prompt, "why does the rate limit retry twice?")
      say!(miss, "unrelated prompt")

      assert {:ok, [first, second], false} =
               PersistedProjection.conversation_search(c.project.id, "rate limit", 50)

      assert {first.id, second.id} == {by_prompt.id, by_title.id}

      assert first |> Map.keys() |> Enum.sort() ==
               ~w(id inserted_at last_prompt last_seen_at stats title updated_at)a
               |> Enum.sort()

      assert first.last_prompt == "why does the rate limit retry twice?"
      assert first.stats == {0, nil}
    end

    test "a superseded prompt is not a hit; an assistant message is not either", c do
      edited = conversation!(c.project, "Edited")
      said = conversation!(c.project, "Assistant")
      say!(edited, "needle in the old prompt", %{superseded_at: DateTime.utc_now()})
      say!(edited, "the new prompt")
      say!(said, "needle in the answer", %{role: "assistant"})

      assert titles(c.project, "needle") == []
      assert titles(c.project, "new prompt") == ["Edited"]
    end

    test "another project's and a research conversation are excluded", c do
      foreign_root = Path.join(c.root, "foreign")
      File.mkdir_p!(foreign_root)
      {:ok, other} = Projects.create(%{name: "Other", root_path: foreign_root})

      mine = conversation!(c.project, "shared word")
      theirs = conversation!(other, "shared word")
      research = conversation!(c.project, "shared word research")

      Repo.query!("PRAGMA foreign_keys = OFF")

      Repo.update_all(from(x in Conversation, where: x.id == ^research.id),
        set: [research_id: 3]
      )

      Repo.query!("PRAGMA foreign_keys = ON")

      {:ok, rows, false} = PersistedProjection.conversation_search(c.project.id, "shared", 50)
      assert Enum.map(rows, & &1.id) == [mine.id]
      refute theirs.id in Enum.map(rows, & &1.id)
    end

    test "% _ and \\ match themselves", c do
      conversation!(c.project, "100% done", ~U[2026-10-01 00:00:01.000000Z])
      conversation!(c.project, "snake_case", ~U[2026-10-01 00:00:02.000000Z])
      conversation!(c.project, "back\\slash", ~U[2026-10-01 00:00:03.000000Z])
      conversation!(c.project, "1000 done", ~U[2026-10-01 00:00:04.000000Z])
      conversation!(c.project, "snakeXcase", ~U[2026-10-01 00:00:05.000000Z])

      assert titles(c.project, "0% d") == ["100% done"]
      assert titles(c.project, "%") == ["100% done"]
      assert titles(c.project, "e_c") == ["snake_case"]
      assert titles(c.project, "_") == ["snake_case"]
      assert titles(c.project, "k\\s") == ["back\\slash"]
      assert titles(c.project, "\\") == ["back\\slash"]
    end

    test "case-insensitive for ASCII; the limit applies after the order", c do
      for i <- 1..5 do
        conversation!(c.project, "Alpha #{i}", DateTime.add(~U[2026-10-01 00:00:00.000000Z], i))
      end

      assert length(titles(c.project, "ALPHA")) == 5
      assert length(titles(c.project, "aLpHa")) == 5
      assert titles(c.project, "alpha", 2) == ["Alpha 5", "Alpha 4"]
      assert titles(c.project, "no such thing") == []
    end

    test "a multi-byte title is found by its multi-byte query", c do
      conversation!(c.project, "Überlauf im Cache")
      assert titles(c.project, "überlauf") == []
      assert titles(c.project, "Überlauf") == ["Überlauf im Cache"]
      assert titles(c.project, "cache") == ["Überlauf im Cache"]
    end

    test "conversations/3 still answers as before, with the same row shape", c do
      first = conversation!(c.project, "First", ~U[2026-10-01 00:00:01.000000Z])
      second = conversation!(c.project, "Second", ~U[2026-10-01 00:00:02.000000Z])
      say!(first, "hello there")

      assert {:ok, [a, b], false} = PersistedProjection.conversations(c.project.id, nil, 10)
      assert {a.id, b.id} == {second.id, first.id}
      assert b.last_prompt == "hello there"
      assert a.stats == {0, nil}
      assert a |> Map.keys() |> Enum.sort() == first_keys()

      assert {:ok, [only], true} = PersistedProjection.conversations(c.project.id, nil, 1)
      assert only.id == second.id
    end

    defp first_keys,
      do: Enum.sort(~w(id inserted_at last_prompt last_seen_at stats title updated_at)a)

    test "a deleted prompt is no longer a hit", c do
      conversation = conversation!(c.project, "Quiet")
      message = say!(conversation, "temporary phrase")
      assert titles(c.project, "temporary phrase") == ["Quiet"]
      Repo.delete_all(from(m in Message, where: m.id == ^message.id))
      assert titles(c.project, "temporary phrase") == []
    end
  end

  ## S4: the two operations through a persisted backend

  defp global, do: %Scope{kind: :global, id: nil, generation: 0}
  defp conversation_scope(id), do: %Scope{kind: :conversation, id: id, generation: 1}

  defp overview_request(overrides \\ %{}),
    do: %ServiceRequest{
      operation: :home_overview,
      timeout_ms: 5000,
      params:
        Map.merge(%{"projects" => 6, "per_project" => 12, "byte_limit" => 131_072}, overrides)
    }

  defp search_request(query, overrides \\ %{}),
    do: %ServiceRequest{
      operation: :conversation_search,
      timeout_ms: 5000,
      params: Map.merge(%{"query" => query, "limit" => 50, "byte_limit" => 262_144}, overrides)
    }

  # The command ledger is durable per project: every request names its own.
  defp request(backend, name, scope, request, id \\ nil),
    do:
      GenServer.call(
        backend,
        {:service_request, id || "#{name}-#{System.unique_integer([:positive])}", scope, request},
        10_000
      )

  defp start_backend!(c, conversation) do
    start_supervised!(
      {Backend,
       mode: :persisted,
       repo: Repo,
       project_root: c.root,
       project_id: c.project.id,
       conversation_id: conversation.id,
       source_epoch: Ecto.UUID.generate()}
    )
  end

  describe "S4 home.overview and conversation.search" do
    setup c do
      older = used!(c.project, "Older work", ~U[2026-10-01 00:00:01.000000Z])
      current = used!(c.project, "Current work", ~U[2026-10-01 00:00:02.000000Z])
      %{older: older, current: current, backend: start_backend!(c, current)}
    end

    test "home.overview answers the body of Appendix C, current project first", c do
      assert {:ok, %{"op" => "result", "response_kind" => "home_overview", "value" => body}} =
               request(c.backend, "home", global(), overview_request(), "req-home-1")

      assert body["request_id"] == "req-home-1"
      assert body["state"] == "ready"
      assert body["error"] == nil
      assert body["revision"] == 0
      assert body["project_id"] == c.project.id
      assert [%{"current" => true, "id" => id, "name" => "Orbit"} = row | _] = body["projects"]
      assert id == c.project.id
      assert row["conversation_count"] == 2
      assert Enum.map(row["conversations"], & &1["title"]) == ["Current work", "Older work"]
      assert body["live_runs"] == [] and body["live_overflow"] == 0

      assert body |> Map.keys() |> Enum.sort() ==
               Enum.sort(~w(request_id state error revision project_id projects live_runs
                            live_overflow waiting_total month next_scheduled))

      assert %{"spend_usd" => spend, "budget_usd" => nil} = body["month"]
      assert is_float(spend)

      # The same answer from the open conversation's scope.
      assert {:ok, %{"response_kind" => "home_overview"}} =
               request(c.backend, "home", conversation_scope(c.current.id), overview_request())

      # The JSON the wire carries round-trips unchanged.
      assert body |> Jason.encode!() |> Jason.decode!() == body
    end

    test "the month is read once and served from the backend's cache for 10 seconds", c do
      assert {:ok, %{"value" => first}} = request(c.backend, "home", global(), overview_request())
      assert {at, month} = :sys.get_state(c.backend).home_month
      assert is_integer(at) and month == first["month"]

      # Served from the cache: the stamp does not move.
      assert {:ok, %{"value" => _}} = request(c.backend, "home", global(), overview_request())
      assert {^at, ^month} = :sys.get_state(c.backend).home_month

      # Past 10 seconds the next answer reads it again and stamps anew.
      :sys.replace_state(c.backend, fn state ->
        %{state | home_month: {at - 11_000, %{"spend_usd" => 99.0, "budget_usd" => nil}}}
      end)

      assert {:ok, %{"value" => body}} = request(c.backend, "home", global(), overview_request())
      assert body["month"] == month
      assert {fresh, ^month} = :sys.get_state(c.backend).home_month
      assert fresh > at - 11_000
    end

    test "a small byte_limit drops conversations from the back; none left is capacity_exceeded",
         c do
      for i <- 1..20 do
        used!(
          c.project,
          String.duplicate("t", 150) <> "#{i}",
          DateTime.add(~U[2026-10-02 00:00:00.000000Z], i)
        )
      end

      assert {:ok, %{"value" => full}} = request(c.backend, "home", global(), overview_request())
      assert length(hd(full["projects"])["conversations"]) == 12

      # A limit that holds the skeleton and about three conversations.
      [first | _] = hd(full["projects"])["conversations"]
      bare = put_in(full, ["projects", Access.at(0), "conversations"], [])
      limit = byte_size(Jason.encode!(bare)) + 3 * byte_size(Jason.encode!(first))

      assert {:ok, %{"value" => small}} =
               request(c.backend, "home", global(), overview_request(%{"byte_limit" => limit}))

      row = hd(small["projects"])
      assert byte_size(Jason.encode!(small)) <= limit
      assert length(row["conversations"]) in 1..3
      assert row["conversation_count"] == 22
      # What is kept is the newest.
      assert Enum.map(row["conversations"], & &1["title"]) ==
               full["projects"]
               |> hd()
               |> Map.get("conversations")
               |> Enum.take(length(row["conversations"]))
               |> Enum.map(& &1["title"])

      assert {:error, %{"op" => "error", "code" => "capacity_exceeded"}} =
               request(c.backend, "home", global(), overview_request(%{"byte_limit" => 1}))
    end

    test "a newer overview replaces an older one in flight", c do
      owner = self()
      calls = :counters.new(1, [])

      # The first reading blocks until it is killed; later ones answer at once.
      build = fn _project, _options, _month, revision ->
        :counters.add(calls, 1, 1)
        number = :counters.get(calls, 1)
        send(owner, {:building, number, self()})

        if number == 1 do
          receive do
            :never -> :ok
          end
        end

        %{
          "revision" => revision,
          "project_id" => nil,
          "projects" => [],
          "live_runs" => [],
          "live_overflow" => 0,
          "waiting_total" => 0,
          "month" => nil,
          "next_scheduled" => nil
        }
      end

      backend =
        start_supervised!(
          {Backend,
           mode: :persisted,
           repo: Repo,
           project_root: c.root,
           project_id: c.project.id,
           conversation_id: c.current.id,
           source_epoch: Ecto.UUID.generate(),
           work: %{home_overview: build}},
          id: :injected_backend
        )

      first = make_ref()
      second = make_ref()

      send(
        backend,
        {:"$gen_call", {self(), first},
         {:service_request, "overview-1", global(), overview_request()}}
      )

      assert_receive {:building, 1, running}, 5_000
      monitor = Process.monitor(running)

      send(
        backend,
        {:"$gen_call", {self(), second},
         {:service_request, "overview-2", global(), overview_request()}}
      )

      assert_receive {^first, {:error, %{"op" => "error", "code" => "stale_revision"}}}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^running, _reason}, 5_000

      assert_receive {^second, {:ok, %{"response_kind" => "home_overview", "value" => body}}},
                     5_000

      assert body["request_id"] == "overview-2"
      assert :sys.get_state(backend).jobs == %{}
    end

    test "conversation.search answers a conversation_list body, project-filtered", c do
      other_root = Path.join(c.root, "other")
      File.mkdir_p!(other_root)
      {:ok, other} = Projects.create(%{name: "Other", root_path: other_root})
      conversation!(other, "Rate limit elsewhere")
      hit = conversation!(c.project, "Rate limit chip", ~U[2026-10-03 00:00:00.000000Z])
      by_prompt = conversation!(c.project, "Untitled", ~U[2026-10-04 00:00:00.000000Z])
      say!(by_prompt, "what is the rate limit?")

      assert {:ok, %{"op" => "result", "response_kind" => "conversation_list", "value" => body}} =
               request(
                 c.backend,
                 "search",
                 global(),
                 search_request("RATE LIMIT"),
                 "req-search-1"
               )

      assert body["request_id"] == "req-search-1"
      assert Enum.map(body["items"], & &1["id"]) == [by_prompt.id, hit.id]
      assert body["before_cursor"] == nil and body["after_cursor"] == nil
      assert body["current_id"] == c.current.id
      assert body["project"] == "Orbit"
      assert body["covered_ids"] == [by_prompt.id, hit.id]
      assert hd(body["items"])["last_prompt"] == "what is the rate limit?"

      assert {:ok, %{"value" => none}} =
               request(c.backend, "search", global(), search_request("zzz-nothing"))

      assert none["items"] == []

      assert {:ok, %{"value" => one}} =
               request(c.backend, "search", global(), search_request("rate", %{"limit" => 1}))

      assert Enum.map(one["items"], & &1["id"]) == [by_prompt.id]

      assert {:error, %{"code" => "capacity_exceeded"}} =
               request(
                 c.backend,
                 "search",
                 global(),
                 search_request("rate", %{"byte_limit" => 1})
               )
    end

    test "a request the encoder refuses is not run", c do
      bad = %{
        overview_request()
        | params: %{"projects" => 99, "per_project" => 12, "byte_limit" => 1}
      }

      assert {:error, %{"code" => "not_allowed"}} = request(c.backend, "home", global(), bad)

      run_scope = %Scope{kind: :run, id: Ecto.UUID.generate(), generation: 0}

      assert {:error, %{"code" => "not_allowed"}} =
               request(c.backend, "home", run_scope, overview_request())
    end
  end

  describe "S4 the unsaved session and the capability" do
    test "the live backend refuses both as reads", c do
      root = Path.join(c.root, "live")
      File.mkdir_p!(root)

      {:ok, provider} =
        SwarmCode.Providers.Provider.new(
          name: "live",
          base_url: "http://127.0.0.1:9/v1",
          api_key: "secret",
          default_model: "fixture"
        )

      conversation_id = "22222222-2222-4222-8222-222222222222"

      backend =
        start_supervised!(
          {LiveBackend,
           mode: :transient,
           provider: provider,
           project_root: root,
           project_id: "33333333-3333-4333-8333-333333333333",
           conversation_id: conversation_id,
           source_epoch: "44444444-4444-4444-8444-444444444444"}
        )

      for request <- [overview_request(), search_request("anything")] do
        assert {:error, %{"op" => "error", "code" => "not_allowed"}} =
                 request(backend, "live", global(), request)
      end

      assert Process.alive?(backend)
    end

    test "home is a default capability and the handshake lists it" do
      assert :home in Service.default_capabilities()
      assert length(Service.default_capabilities()) == 24

      assert length(Service.default_capabilities()) ==
               length(Enum.uniq(Service.default_capabilities()))
    end
  end

  describe "S4 the connection" do
    @nonce String.duplicate("A", 43)
    @epoch "33333333-3333-4333-8333-333333333333"
    @hello_id "11111111-1111-4111-8111-111111111111"

    setup do
      dir = Path.join(System.tmp_dir!(), "orbit-conn-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o700)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "both operations ride the home capability and a deadline is a typed read error", c do
      {socket, backend, hello_ok} = connected(c.dir, Service.default_capabilities())
      assert "home" in hello_ok.body["capabilities"]

      send_frame(socket, home_frame(uuid(1), "home.overview", overview_body(5_000)))

      assert %Wire{type: :response, request_id: id, body: %{"response_kind" => "home_overview"}} =
               receive_frame(socket)

      assert id == uuid(1)

      send_frame(socket, home_frame(uuid(2), "conversation.search", search_body(5_000)))

      assert %Wire{
               type: :response,
               request_id: id,
               body: %{"response_kind" => "conversation_list"}
             } = receive_frame(socket)

      assert id == uuid(2)

      # A slow read past its deadline is an error frame, never `outcome_unknown`.
      send(backend, :hold)
      send_frame(socket, home_frame(uuid(3), "home.overview", overview_body(300)))

      assert %Wire{type: :error, request_id: id, body: %{"code" => "deadline_expired"}} =
               receive_frame(socket, 3_000)

      assert id == uuid(3)

      send_frame(socket, home_frame(uuid(4), "conversation.search", search_body(300)))

      assert %Wire{type: :error, request_id: id, body: %{"code" => "deadline_expired"}} =
               receive_frame(socket, 3_000)

      assert id == uuid(4)
      send(backend, :release)
    end

    test "a session without the home capability is closed on either operation", c do
      for {op, body} <- [
            {"home.overview", overview_body(5_000)},
            {"conversation.search", search_body(5_000)}
          ] do
        {socket, _backend, hello_ok} =
          connected(c.dir, Service.default_capabilities() -- [:home])

        refute "home" in hello_ok.body["capabilities"]
        send_frame(socket, home_frame(uuid(5), op, body))
        assert {:error, :closed} = :gen_tcp.recv(socket, 4, 2_000)
        :gen_tcp.close(socket)
      end
    end

    defp overview_body(timeout),
      do: %{
        "op" => "home.overview",
        "timeout_ms" => timeout,
        "projects" => 6,
        "per_project" => 12,
        "byte_limit" => 131_072
      }

    defp search_body(timeout),
      do: %{
        "op" => "conversation.search",
        "timeout_ms" => timeout,
        "query" => "rate",
        "limit" => 50,
        "byte_limit" => 262_144
      }

    defp home_frame(id, _op, body),
      do: %Wire{
        version: 1,
        type: :request,
        request_id: id,
        nonce: @nonce,
        scope: global(),
        sequence: nil,
        occurred_at: nil,
        body: body
      }

    # A real Service and Connection over a unix socket, with a fake backend
    # that answers every read (or holds it until released).
    defp connected(dir, capabilities) do
      path = Path.join(dir, "d-#{System.unique_integer([:positive])}.sock")
      owner = self()
      backend = spawn_link(fn -> fake_backend(%{owner: owner, hold: false, held: []}) end)

      start_supervised!(
        %{
          id: {:orbit_service, System.unique_integer([:positive])},
          start:
            {Supervisor, :start_link,
             [
               [
                 {Service,
                  socket_path: path,
                  nonce: @nonce,
                  source_epoch: @epoch,
                  backend: backend,
                  capabilities: capabilities}
               ],
               [strategy: :one_for_one]
             ]}
        },
        restart: :temporary
      )

      {:ok, socket} =
        :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :raw], 1000)

      send_frame(socket, %Wire{
        version: 1,
        type: :hello,
        request_id: @hello_id,
        nonce: @nonce,
        scope: nil,
        sequence: nil,
        occurred_at: nil,
        body: %{"op" => "hello", "client" => "swarm-code-cli", "body_version" => 1}
      })

      assert %Wire{type: :hello_ok} = hello_ok = receive_frame(socket)
      {socket, backend, hello_ok}
    end

    defp fake_backend(state) do
      receive do
        :hold ->
          fake_backend(%{state | hold: true})

        :release ->
          fake_backend(%{state | hold: false, held: []})

        {:"$gen_call", from, {:service_request, id, _scope, request}} ->
          unless state.hold do
            kind =
              if request.operation == :home_overview,
                do: "home_overview",
                else: "conversation_list"

            GenServer.reply(
              from,
              {:ok,
               %{"op" => "result", "response_kind" => kind, "value" => %{"request_id" => id}}}
            )
          end

          fake_backend(state)

        _ ->
          fake_backend(state)
      end
    end

    defp uuid(n) do
      hex = n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0")
      "bbbbbbbb-bbbb-4bbb-8bbb-" <> hex
    end

    defp send_frame(socket, message), do: :gen_tcp.send(socket, Frame.encode!(message))

    defp receive_frame(socket, timeout \\ 2000) do
      {:ok, <<size::32>>} = :gen_tcp.recv(socket, 4, timeout)
      {:ok, bytes} = :gen_tcp.recv(socket, size, timeout)
      {:ok, message} = Envelope.decode(bytes)
      message
    end
  end

  ## S5: the debounced home_stale push

  defp watch!(backend, slot, scope, ref) do
    request = %ServiceRequest{
      operation: :watch,
      timeout_ms: 1000,
      params: %{"watch_ref" => ref, "slot" => slot, "page_size" => 20, "byte_limit" => 262_144}
    }

    assert {:watch, 0, _, _, _} =
             GenServer.call(backend, {:service_watch, self(), "watch-#{ref}", scope, request})

    send(backend, {:service_ready, self(), ref})
  end

  describe "S5 home_stale" do
    setup c do
      current = conversation!(c.project, "Current work", ~U[2026-10-01 00:00:02.000000Z])
      backend = start_backend!(c, current)
      watch!(backend, "shell", global(), "shell")
      %{current: current, backend: backend}
    end

    test "ten triggers inside a window are one push, then a quiet shell", c do
      for _ <- 1..10, do: send(c.backend, {:waiting_changed})

      assert_receive {:service_delta, _, "shell", %{"kind" => "home_stale"} = delta}, 3_000

      assert delta["body"] == %{"revision" => 1}
      assert delta["entity_id"] == nil and delta["run_id"] == nil
      assert delta["conversation_id"] == c.current.id
      assert delta["channel"] == nil and delta["attempt_id"] == nil and delta["text"] == nil

      assert delta |> Map.keys() |> Enum.sort() ==
               Enum.sort(~w(kind entity_id run_id conversation_id channel attempt_id text body
                            sequence revision))

      assert is_integer(delta["revision"])
      # One event, not ten; the timer is spent and the revision is the push's.
      refute_receive {:service_delta, _, "shell", %{"kind" => "home_stale"}}, 800
      assert %{home_timer: nil, home_revision: 1} = :sys.get_state(c.backend)
    end

    test "a second burst later is the next revision", c do
      send(c.backend, {:waiting_changed})
      assert_receive {:service_delta, _, "shell", %{"body" => %{"revision" => 1}}}, 3_000

      for _ <- 1..3, do: send(c.backend, {:waiting_changed})

      assert_receive {:service_delta, _, "shell",
                      %{"kind" => "home_stale", "body" => %{"revision" => 2}}},
                     3_000

      refute_receive {:service_delta, _, "shell", %{"kind" => "home_stale"}}, 800
    end

    test "without a trigger the shell hears nothing", c do
      refute_receive {:service_delta, _, _, %{"kind" => "home_stale"}}, 1_000
      assert %{home_timer: nil, home_revision: 0} = :sys.get_state(c.backend)
    end

    test "a workspace watch never hears it", c do
      watch!(c.backend, "workspace", conversation_scope(c.current.id), "workspace")
      send(c.backend, {:waiting_changed})

      assert_receive {:service_delta, _, "shell", %{"kind" => "home_stale"}}, 3_000
      refute_receive {:service_delta, _, "workspace", %{"kind" => "home_stale"}}, 300
    end

    test "a run changing in the open conversation arms it", c do
      assert {:ok, _run} =
               Conversations.create_run(%{
                 conversation_id: c.current.id,
                 kind: "chat",
                 status: "running",
                 started_at: DateTime.utc_now()
               })

      assert_receive {:service_delta, _, "shell", %{"kind" => "run_update"}}, 3_000
      assert_receive {:service_delta, _, "shell", %{"kind" => "home_stale"}}, 3_000
    end

    test "conversation.new, conversation.open and project.update each arm it", c do
      other = conversation!(c.project, "Other work", ~U[2026-10-01 00:00:01.000000Z])

      assert {:ok, %{"value" => %{"status" => "accepted"}}} =
               request(c.backend, "open", global(), %ServiceRequest{
                 operation: :conversation_open,
                 timeout_ms: 5000,
                 params: %{"conversation_id" => other.id}
               })

      assert %{home_timer: timer} = :sys.get_state(c.backend)
      assert is_reference(timer)

      # The open dropped the global watches (the client re-watches); watch again.
      assert_receive {:service_resync, _, "shell"}, 2_000
      watch!(c.backend, "shell", global(), "shell")

      assert_receive {:service_delta, _, "shell",
                      %{"kind" => "home_stale", "body" => %{"revision" => 1}}},
                     3_000

      assert {:ok, %{"value" => %{"status" => "accepted"}}} =
               request(c.backend, "new", global(), %ServiceRequest{
                 operation: :conversation_new,
                 timeout_ms: 5000,
                 params: %{}
               })

      assert is_reference(:sys.get_state(c.backend).home_timer)
      assert_receive {:service_resync, _, "shell"}, 2_000
      watch!(c.backend, "shell", global(), "shell")

      assert_receive {:service_delta, _, "shell",
                      %{"kind" => "home_stale", "body" => %{"revision" => 2}}},
                     3_000

      assert {:ok, %{"value" => %{"status" => "accepted"}}} =
               request(c.backend, "project", global(), %ServiceRequest{
                 operation: :project_update,
                 timeout_ms: 5000,
                 params: %{"approval_mode" => "read_only", "trusted" => nil}
               })

      assert_receive {:service_delta, _, "shell",
                      %{"kind" => "home_stale", "body" => %{"revision" => 3}}},
                     3_000
    end

    # orbit int (lane S issue 6): runs of conversations the backend does not
    # have open end without a `run_update` here; the global notices still move
    # Home. An info notice or a workflow library change does not.
    test "a run finishing anywhere, and research or workflow runs changing, arm it", c do
      for event <- [
            {:notification, :finished, "Swarm finished: elsewhere"},
            {:workflow_runs_changed},
            {:research_runs_changed}
          ] do
        before = :sys.get_state(c.backend).home_revision
        send(c.backend, event)

        assert_receive {:service_delta, _, "shell", %{"kind" => "home_stale"} = delta}, 3_000
        assert delta["body"] == %{"revision" => before + 1}
      end

      send(c.backend, {:notification, :info, "just a note"})
      send(c.backend, {:workflows_changed})
      refute_receive {:service_delta, _, "shell", %{"kind" => "home_stale"}}, 800
      assert :sys.get_state(c.backend).home_timer == nil
    end

    test "stopping the backend cancels a pending timer", c do
      send(c.backend, {:waiting_changed})
      timer = :sys.get_state(c.backend).home_timer
      assert is_reference(timer)
      assert is_integer(Process.read_timer(timer))

      :ok = stop_supervised(Backend)
      assert Process.read_timer(timer) == false
    end
  end

  ## S8: opening a conversation never marks it seen (decision D12)

  describe "S8 opening never marks seen" do
    @seen ~U[2026-10-01 09:00:00.000000Z]
    @finished ~U[2026-10-01 10:00:00.000000Z]

    # A conversation with a run that finished after it was last seen.
    defp unread_conversation!(c, title) do
      conversation = conversation!(c.project, title, ~U[2026-10-01 10:00:00.000000Z])

      assert {:ok, run} =
               Conversations.create_run(%{
                 conversation_id: conversation.id,
                 kind: "chat",
                 status: "done",
                 started_at: ~U[2026-10-01 09:30:00.000000Z],
                 finished_at: @finished
               })

      Repo.update_all(from(x in Conversation, where: x.id == ^conversation.id),
        set: [last_seen_at: @seen]
      )

      {conversation, run}
    end

    defp assert_untouched(conversation, run) do
      assert DateTime.compare(Repo.get!(Conversation, conversation.id).last_seen_at, @seen) == :eq
      assert Repo.get!(Run, run.id).seen_at == nil
    end

    defp unread_rows(backend, conversation) do
      assert {:ok, %{"value" => overview}} =
               request(backend, "home", global(), overview_request())

      overview_row =
        overview["projects"]
        |> hd()
        |> Map.get("conversations")
        |> Enum.find(&(&1["id"] == conversation.id))

      assert {:ok, %{"value" => list}} =
               request(backend, "list", global(), %ServiceRequest{
                 operation: :conversation_list,
                 timeout_ms: 5000,
                 params: %{"cursor" => nil, "page_size" => 50, "byte_limit" => 262_144}
               })

      list_row = Enum.find(list["items"], &(&1["id"] == conversation.id))
      {overview_row["unread"], list_row["unread"]}
    end

    test "a backend started on it, its workspace watched and opened again: still unread", c do
      {target, run} = unread_conversation!(c, "Finished work")
      backend = start_backend!(c, target)

      watch!(backend, "workspace", conversation_scope(target.id), "workspace")

      assert {:ok, %{"value" => %{"status" => "accepted"}}} =
               request(backend, "open", global(), %ServiceRequest{
                 operation: :conversation_open,
                 timeout_ms: 5000,
                 params: %{"conversation_id" => target.id}
               })

      assert {true, true} = unread_rows(backend, target)
      assert_untouched(target, run)
    end

    test "switching to it from another conversation does not mark it either", c do
      {target, run} = unread_conversation!(c, "Finished work")
      current = conversation!(c.project, "Current work", ~U[2026-10-01 11:00:00.000000Z])
      backend = start_backend!(c, current)

      assert {:ok, %{"value" => %{"status" => "accepted"}}} =
               request(backend, "open", global(), %ServiceRequest{
                 operation: :conversation_open,
                 timeout_ms: 5000,
                 params: %{"conversation_id" => target.id}
               })

      watch!(backend, "workspace", conversation_scope(target.id), "workspace")
      assert {true, true} = unread_rows(backend, target)
      assert_untouched(target, run)

      # Only the explicit operation marks it seen.
      assert {:ok, %{"value" => %{"status" => "accepted"}}} =
               request(backend, "seen", global(), %ServiceRequest{
                 operation: :mark_seen,
                 timeout_ms: 5000,
                 params: %{"kind" => "conversation", "id" => target.id, "revision" => 1}
               })

      assert DateTime.compare(Repo.get!(Conversation, target.id).last_seen_at, @seen) == :gt
      assert {false, false} = unread_rows(backend, target)
    end
  end
end
