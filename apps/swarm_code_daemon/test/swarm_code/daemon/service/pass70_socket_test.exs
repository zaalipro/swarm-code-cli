defmodule SwarmCode.Daemon.Service.Pass70SocketTest do
  @moduledoc """
  pass70 C: socket acceptance of every operation this pass added. Each request
  is built as the terminal builds it (`DataSource.Request`), encoded by the
  client codec, sent through the real service socket to the persisted
  backend, and its response decoded by the client codec again.
  """
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Projects, Repo}
  alias SwarmCode.Domain.Checkpoints.Checkpoint
  alias SwarmCode.Protocol.{Envelope, Frame, Message, Scope, ServiceHandshake}
  alias SwarmCodeCLI.UI.DataSource.{DTO, Request}
  alias SwarmCodeCLI.UI.DataSource.Daemon.Codec

  setup_all do
    path = Path.join(System.tmp_dir!(), "p70s-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
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
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/app.ex"), "defmodule App do\nend\n")
    {:ok, project} = Projects.create(%{name: "Socket", root_path: root})
    {:ok, project} = Projects.update(project, %{approval_mode: "auto"})
    {:ok, conv} = Conversations.create(project.id)
    epoch = Ecto.UUID.generate()

    backend =
      start_supervised!(
        {Backend,
         mode: :persisted,
         repo: Repo,
         project_root: root,
         project_id: project.id,
         conversation_id: conv.id,
         source_epoch: epoch}
      )

    socket_path = Path.join(c.path, "s#{System.unique_integer([:positive])}.sock")
    nonce = String.duplicate("C", 43)

    start_supervised!(
      {SwarmCode.Daemon.Service,
       socket_path: socket_path, nonce: nonce, source_epoch: epoch, backend: backend}
    )

    {:ok, socket} =
      :gen_tcp.connect({:local, socket_path}, 0, [:binary, active: false, packet: :raw], 1000)

    on_exit(fn -> :gen_tcp.close(socket) end)

    hello = %Message{
      version: 1,
      type: :hello,
      request_id: Ecto.UUID.generate(),
      nonce: nonce,
      scope: nil,
      sequence: nil,
      occurred_at: nil,
      body: ServiceHandshake.hello()
    }

    :ok = :gen_tcp.send(socket, Frame.encode!(hello))
    assert frame(socket).type == :hello_ok

    %{socket: socket, nonce: nonce, project: project, conv: conv, root: root}
  end

  test "conversation list, new and open travel the socket", c do
    assert {:ok, %DTO.ConversationList{current_id: current, items: [_]}} =
             roundtrip(c, {:conversation_list, nil, 50, 262_144}, {:conversation, :list},
               expected: :conversation_list
             )

    assert current == c.conv.id

    assert {:ok, %DTO.Outcome{status: :accepted, identifiers: [new_id]}} =
             roundtrip(c, {:conversation_new}, {:conversation, :new})

    assert {:ok, %DTO.ConversationList{current_id: ^new_id, items: [_, _]}} =
             roundtrip(c, {:conversation_list, nil, 50, 262_144}, {:conversation, :list},
               expected: :conversation_list
             )

    assert {:ok, %DTO.Outcome{status: :accepted, identifiers: [back]}} =
             roundtrip(c, {:conversation_open, c.conv.id}, {:conversation, :open})

    assert back == c.conv.id
  end

  test "approval mode, trust and seen marks travel the socket", c do
    assert {:ok, %DTO.Outcome{status: :accepted, feedback: %DTO.Feedback{kind: :notice}}} =
             roundtrip(c, {:project_update, :full_access, nil}, {:project, :update})

    assert Projects.get(c.project.id).approval_mode == "full_access"

    assert {:ok, %DTO.Outcome{status: :accepted}} =
             roundtrip(c, {:project_update, nil, true}, {:project, :update})

    assert Projects.trusted?(Projects.get(c.project.id))

    scope = %Scope{kind: :conversation, id: c.conv.id, generation: 2}

    assert {:ok, %DTO.Outcome{status: :accepted}} =
             roundtrip(
               c,
               {:mark_seen, :conversation, c.conv.id, 1},
               {:seen, :conversation, c.conv.id, 1},
               scope: scope
             )

    assert %DateTime{} = Conversations.get(c.conv.id).last_seen_at
  end

  test "@path completion and a change's diff travel the socket", c do
    scope = %Scope{kind: :conversation, id: c.conv.id, generation: 2}

    assert {:ok, %DTO.LibrarySnapshot{feature: :files, items: [%{title: "lib/app.ex"} | _]}} =
             roundtrip(c, {:feature_query, :files, "app", nil, 20, 65_536}, {:feature, :files},
               expected: :library_snapshot,
               scope: scope
             )

    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: c.conv.id,
        kind: "chat",
        prompt: "edit",
        status: "done",
        started_at: DateTime.utc_now()
      })

    file = Path.join(c.root, "lib/app.ex")

    checkpoint =
      %Checkpoint{conversation_id: c.conv.id, run_id: run.id, node_id: nil}
      |> Checkpoint.changeset(%{
        path: file,
        previous_content: "defmodule Old do\nend\n",
        restorable: true,
        inserted_at: DateTime.utc_now()
      })
      |> Checkpoint.validate()
      |> Repo.insert!()

    # pass71 S2: the change's facts come from a job; ask until they are there.
    change = settled_change(c, scope, 200)

    assert change.id == checkpoint.id and change.diff_ref.id == checkpoint.id <> ":diff"

    assert {:ok, %DTO.DetailWindow{state: :idle, text: text, detail_ref: ref}} =
             roundtrip(c, {:query_detail, change.diff_ref.id, 0, 16_384}, {:query, :detail},
               expected: :detail_window,
               scope: scope
             )

    assert ref == change.diff_ref
    assert text =~ "-defmodule Old do" and text =~ "+defmodule App do"
  end

  defp settled_change(c, scope, tries) do
    assert {:ok, %DTO.WorkspaceSnapshot{changes: [change]}} =
             roundtrip(c, {:query, :workspace, nil, :before, 50, 1_048_576}, {:query, :workspace},
               expected: :workspace_snapshot,
               scope: scope
             )

    cond do
      change.diff_ref != nil ->
        change

      tries > 0 ->
        receive do
        after
          10 -> settled_change(c, scope, tries - 1)
        end

      true ->
        flunk("the change never got its diff")
    end
  end

  defp roundtrip(c, kind, origin, opts \\ []) do
    scope = opts[:scope] || %Scope{kind: :global, id: nil, generation: 1}

    request = %Request{
      request_id: "req-#{System.unique_integer([:positive])}",
      kind: kind,
      scope: scope,
      generation: scope.generation,
      origin: origin,
      deadline: 30_000,
      expected_response: opts[:expected] || :outcome
    }

    {:ok, wire} = Codec.request(request, Ecto.UUID.generate(), c.nonce, 0)
    :ok = :gen_tcp.send(c.socket, Frame.encode!(wire))
    response = frame(c.socket)
    assert response.type == :response, inspect(response.body)

    case Codec.response(response, request, wire.request_id, c.nonce) do
      {:ok, %SwarmCodeCLI.UI.DataSource.Delivery{kind: :response, body: body}} -> {:ok, body}
      other -> other
    end
  end

  defp frame(socket) do
    {:ok, <<length::32>>} = :gen_tcp.recv(socket, 4, 5000)
    {:ok, bytes} = :gen_tcp.recv(socket, length, 5000)
    {:ok, message} = Envelope.decode(bytes)
    message
  end
end
