defmodule SwarmCode.Daemon.Service.Pass70ChangesTest do
  @moduledoc """
  pass70 C8 (ux 2.5, 3.3): "Full detail" loads (the window's total is the one
  the item promised), a finished run's changes carry line counts and a diff
  that loads through detail, an edit op points at its own diff, Changes lists
  the conversation's changed files instead of the Git tree, and `@path`
  completion ranks the project's files.
  """
  use ExUnit.Case, async: false
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Projects, Repo}
  alias SwarmCode.Domain.Checkpoints.Checkpoint
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCodeCLI.UI.DataSource.DTO

  setup_all do
    path = Path.join(System.tmp_dir!(), "pass70-changes-#{System.unique_integer([:positive])}")
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
    File.mkdir_p!(Path.join(root, "lib"))
    {:ok, project} = Projects.create(%{name: "Changes", root_path: root})
    {:ok, conv} = Conversations.create(project.id)

    backend =
      start_supervised!(
        {Backend,
         mode: :persisted,
         repo: Repo,
         project_root: root,
         project_id: project.id,
         conversation_id: conv.id,
         source_epoch: Ecto.UUID.generate()}
      )

    %{
      backend: backend,
      conv: conv,
      root: root,
      scope: %Scope{kind: :conversation, id: conv.id, generation: 1}
    }
  end

  defp run!(c, status) do
    {:ok, run} =
      Conversations.create_run(%{
        conversation_id: c.conv.id,
        kind: "chat",
        prompt: "Change the file",
        status: status,
        started_at: DateTime.utc_now()
      })

    {:ok, agent} =
      Conversations.insert_node(%{
        run_id: run.id,
        kind: "agent",
        role: "lead",
        name: "assistant",
        status: status
      })

    {:ok, op} =
      Conversations.insert_node(%{
        run_id: run.id,
        kind: "op",
        op_type: "edit_file",
        parent_id: agent.id,
        name: "edit_file",
        title: "edit lib/x.ex",
        status: "done",
        input: Jason.encode!(%{"path" => "lib/x.ex"})
      })

    {run, agent, op}
  end

  defp checkpoint!(c, run, op, path, before) do
    %Checkpoint{conversation_id: c.conv.id, run_id: run.id, node_id: op.id}
    |> Checkpoint.changeset(%{
      path: path,
      previous_content: before,
      restorable: true,
      inserted_at: DateTime.utc_now()
    })
    |> Checkpoint.validate()
    |> Repo.insert!()
  end

  test "Full detail of an agent's long result loads the size its item promised", c do
    {run, agent, _op} = run!(c, "done")
    long = String.duplicate("line of the report\n", 400)

    Repo.update!(Ecto.Changeset.change(agent, result: long))

    refresh!(c.backend)
    {:ok, %{"value" => workspace}} = query(c, "workspace")
    item = Enum.find(workspace["transcript"]["items"], &(&1["id"] == agent.id))
    assert %{"id" => ref, "total_bytes" => total} = item["detail_ref"]

    window = detail!(c, %{c.scope | kind: :run, id: run.id}, ref, 0, 16_384)
    assert {window.state, window.detail_ref.total_bytes} == {:idle, total}
    assert window.text == String.trim(long)
    assert total == byte_size(String.trim(long)) and window.next_offset == nil
  end

  test "a finished run's change has counts and a diff; the edit op points at it", c do
    {run, _agent, op} = run!(c, "done")
    file = Path.join(c.root, "lib/x.ex")
    File.write!(file, "one\nTWO\nthree\nfour\n")
    change = checkpoint!(c, run, op, file, "one\ntwo\nthree\n")
    refresh!(c.backend)

    {:ok, %{"value" => workspace}} = query(c, "workspace")

    assert {:ok, %DTO.WorkspaceSnapshot{changes: [body], transcript: transcript}} =
             DTO.WorkspaceSnapshot.decode(workspace)

    assert {body.id, body.path, body.op_id} == {change.id, "lib/x.ex", op.id}
    assert {body.file_state, body.added, body.removed} == {:modified, 2, 1}
    assert body.diff_ref.id == change.id <> ":diff"

    window = detail!(c, c.scope, body.diff_ref.id, 0, 16_384)
    assert window.state == :idle and window.detail_ref.total_bytes == body.diff_ref.total_bytes
    assert window.text =~ "--- a/lib/x.ex\n+++ b/lib/x.ex\n"
    assert window.text =~ "-two\n" and window.text =~ "+TWO\n" and window.text =~ "+four\n"

    # A small window pages: the second starts where the first stopped.
    first = detail!(c, c.scope, body.diff_ref.id, 0, 10)
    second = detail!(c, c.scope, body.diff_ref.id, first.next_offset, 10)
    assert first.text <> second.text == binary_part(window.text, 0, 20)

    tool = Enum.find(transcript.items, &(&1.id == op.id)).tool
    assert {tool.added, tool.removed, tool.diff_ref.id} == {2, 1, op.id <> ":diff"}
    op_window = detail!(c, c.scope, tool.diff_ref.id, 0, 16_384)
    assert op_window.text == window.text and op_window.detail_ref == tool.diff_ref
  end

  test "a live run's change waits for the run before it offers a diff", c do
    {run, _agent, op} = run!(c, "running")
    file = Path.join(c.root, "lib/live.ex")
    File.write!(file, "b\n")
    checkpoint!(c, run, op, file, "a\n")
    refresh!(c.backend)

    {:ok, %{"value" => workspace}} = query(c, "workspace")

    assert [%{"diff_ref" => nil, "added" => nil, "file_state" => "unknown"}] =
             workspace["changes"]
  end

  test "Changes in a conversation are its runs' files, each with its diff", c do
    {run, _agent, op} = run!(c, "done")
    file = Path.join(c.root, "lib/x.ex")
    File.write!(file, "new\n")
    change = checkpoint!(c, run, op, file, nil)
    # An unrelated file in the working tree is not this conversation's change.
    File.write!(Path.join(c.root, "unrelated.txt"), "x")

    {:ok, %{"value" => page}} = feature(c, c.scope, "changes", nil)
    assert [%{"id" => id, "title" => "lib/x.ex", "status" => "created"}] = page["items"]
    assert id == change.id

    {:ok, %{"value" => one}} = feature(c, c.scope, "changes", change.id)
    assert [%{"detail" => detail}] = one["items"]
    assert detail =~ "+new"
  end

  test "@path completion ranks the project's files and says what matched", c do
    for file <- ["lib/swarm.ex", "lib/other.ex", "README.md", "lib/deep/sw/x.ex"] do
      File.mkdir_p!(Path.dirname(Path.join(c.root, file)))
      File.write!(Path.join(c.root, file), "x")
    end

    {:ok, %{"value" => page}} = feature(c, c.scope, "files", "swarm")

    assert {:ok, %DTO.LibrarySnapshot{feature: :files, items: [best | _]}} =
             DTO.LibrarySnapshot.decode(page)

    assert best.title == "lib/swarm.ex"
    assert best.matches == [4, 5, 6, 7, 8]

    {:ok, %{"value" => all}} = feature(c, c.scope, "files", nil)
    assert hd(all["items"])["title"] == "README.md"
  end

  # pass71 S2: change facts come from a facts job; wait until it settled.
  defp refresh!(backend, tries \\ 200) do
    send(backend, :refresh_projection)
    state = :sys.get_state(backend)

    cond do
      state.facts_job == nil and state.facts_missing == [] ->
        state

      tries > 0 ->
        receive do
        after
          10 -> refresh!(backend, tries - 1)
        end

      true ->
        flunk("the change facts never settled")
    end
  end

  defp query(c, slot),
    do:
      call(c, c.scope, %ServiceRequest{
        operation: :query,
        timeout_ms: 5000,
        params: %{
          "slot" => slot,
          "cursor" => nil,
          "direction" => "before",
          "page_size" => 50,
          "byte_limit" => 1_048_576
        }
      })

  defp detail!(c, scope, ref, offset, bytes) do
    {:ok, %{"value" => body}} =
      call(c, scope, %ServiceRequest{
        operation: :detail,
        timeout_ms: 5000,
        params: %{"detail_ref" => ref, "offset" => offset, "bytes" => bytes}
      })

    {:ok, window} = DTO.DetailWindow.decode(body)
    window
  end

  defp feature(c, scope, name, id),
    do:
      call(c, scope, %ServiceRequest{
        operation: :feature_query,
        timeout_ms: 5000,
        params: %{
          "feature" => name,
          "id" => id,
          "cursor" => nil,
          "page_size" => 20,
          "byte_limit" => 262_144
        }
      })

  defp call(c, scope, request),
    do:
      GenServer.call(
        c.backend,
        {:service_request, "r-#{System.unique_integer([:positive])}", scope, request},
        10_000
      )
end
