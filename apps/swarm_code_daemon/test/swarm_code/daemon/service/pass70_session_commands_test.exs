defmodule SwarmCode.Daemon.Service.Pass70SessionCommandsTest do
  @moduledoc """
  pass70 C7: the session basics as slash commands, through the dispatcher and
  the persisted service that answers them — new, clear, resume, approval,
  trust, diff, cost, search, export, agents, help and quit.
  """
  use ExUnit.Case, async: false
  import Ecto.Query
  alias SwarmCode.Daemon.Service.CommandDispatcher, as: Dispatcher
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Projects, Repo}
  alias SwarmCode.Domain.Conversations.Conversation
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCodeCLI.UI.DataSource.DTO

  setup_all do
    path = Path.join(System.tmp_dir!(), "pass70-commands-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(path, "downloads"))
    prior = Application.get_env(:swarm_code_daemon, :domain_config_dir)
    Application.put_env(:swarm_code_daemon, :domain_config_dir, Path.join(path, "config"))
    Application.put_env(:swarm_code_daemon, :export_dir, Path.join(path, "downloads"))

    on_exit(fn ->
      Cache.clear()
      Application.delete_env(:swarm_code_daemon, :export_dir)

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
    {:ok, project} = Projects.create(%{name: "Commands", root_path: root})
    {:ok, project} = Projects.update(project, %{approval_mode: "auto"})
    {:ok, older} = Conversations.create(project.id)
    {:ok, older} = Conversations.update(older, %{title: "Parser rewrite"})
    {:ok, current} = Conversations.create(project.id)
    {:ok, current} = Conversations.update(current, %{title: "Current work"})

    Repo.update_all(from(x in Conversation, where: x.id == ^older.id),
      set: [updated_at: ~U[2026-09-20 10:00:00.000000Z]]
    )

    backend =
      start_supervised!(
        {Backend,
         mode: :persisted,
         repo: Repo,
         project_root: root,
         project_id: project.id,
         conversation_id: current.id,
         source_epoch: Ecto.UUID.generate()}
      )

    %{backend: backend, project: project, older: older, current: current, root: root}
  end

  test "/new and /clear create and open a conversation; the reply says which", c do
    for command <- ["/new", "/clear"] do
      before = current(c)

      assert {:ok, %{"status" => "accepted", "identifiers" => [id], "feedback" => feedback}} =
               send_command(c, before, command)

      assert %{project_id: project} = Conversations.get(id)
      assert project == c.project.id and id != before
      assert {feedback["kind"], feedback["feature"]} == {"navigate", "conversations"}
      assert {:ok, %DTO.Feedback{feature: :conversations}} = DTO.Feedback.decode(feedback)
      assert current(c) == id
    end
  end

  test "/resume opens the picker; /resume <title words or id prefix> opens one", c do
    assert {:ok, %{"identifiers" => [], "feedback" => %{"feature" => "conversations"}}} =
             send_command(c, c.current.id, "/resume")

    assert {:ok, %{"status" => "accepted", "identifiers" => [older]}} =
             send_command(c, c.current.id, "/resume parser")

    assert older == c.older.id and current(c) == older

    assert {:ok, %{"identifiers" => [back]}} =
             send_command(c, older, "/resume " <> String.slice(c.current.id, 0, 8))

    assert back == c.current.id

    assert {:ok, %{"status" => "rejected"}} = send_command(c, back, "/resume no such thing")

    # Two titles with the words and neither exactly them: ambiguous. The exact
    # title wins over a longer one.
    {:ok, other} = Conversations.create(c.project.id)
    {:ok, _} = Conversations.update(other, %{title: "Current work 2"})
    assert {:error, :ambiguous_conversation} = Dispatcher.dispatch(back, "/resume current")

    assert {:ok, %{type: :conversation, conversation_id: exact}} =
             Dispatcher.dispatch(back, "/resume current work")

    assert exact == c.current.id
  end

  test "/approval reports and changes the mode; /trust trusts", c do
    assert {:ok, %{"feedback" => %{"kind" => "report", "text" => text}}} =
             send_command(c, c.current.id, "/approval")

    assert text =~ "Approval mode: auto" and text =~ "Trusted: no"

    assert {:ok, %{"status" => "accepted", "feedback" => %{"text" => "Approval mode: read-only"}}} =
             send_command(c, c.current.id, "/approval read-only")

    assert Projects.get(c.project.id).approval_mode == "read_only"

    assert {:ok, %{"feedback" => %{"text" => "Project trusted; approval mode auto"}}} =
             send_command(c, c.current.id, "/trust")

    assert Projects.trusted?(Projects.get(c.project.id))
    assert {:ok, %{"status" => "rejected"}} = send_command(c, c.current.id, "/approval yolo")
  end

  test "/diff navigates to the changes; /help lists the commands; /quit is the client's", c do
    assert {:ok, %{"feedback" => %{"kind" => "navigate", "feature" => "changes"}}} =
             send_command(c, c.current.id, "/diff")

    assert {:ok, %{"feedback" => %{"kind" => "report", "text" => help}}} =
             send_command(c, c.current.id, "/help")

    assert help =~ "/new — Start a new conversation"
    assert help =~ "/resume-run — Resume the last stopped run"
    assert {:error, :client_only} = Dispatcher.dispatch(c.current.id, "/quit")
  end

  test "/cost sums the conversation's runs by model", c do
    for {model, cost, tokens} <- [
          {"m-large", 0.5, 12_000},
          {"m-large", 0.25, 3_000},
          {"m-small", 0.004, 900}
        ] do
      {:ok, _} =
        Conversations.create_run(%{
          conversation_id: c.current.id,
          kind: "chat",
          prompt: "x",
          status: "done",
          model: model,
          cost_usd: cost,
          tokens_in: tokens,
          tokens_out: 100,
          started_at: DateTime.utc_now()
        })
    end

    assert {:ok, %{"feedback" => %{"title" => "Cost of this conversation", "text" => text}}} =
             send_command(c, c.current.id, "/cost")

    assert text =~ "$0.75 for 3 runs: 15.9k tokens in, 300 out."
    assert text =~ "- m-large: 2 runs, 15.0k in, 200 out, $0.75"
    assert text =~ "- m-small: 1 run, 900 in, 100 out, <$0.01"
  end

  test "/search finds this project's conversations by their messages", c do
    {:ok, _} =
      Conversations.create_message(%{
        conversation_id: c.older.id,
        role: "user",
        content: "the tokenizer drops unicode quotes"
      })

    assert {:ok, %{"feedback" => %{"kind" => "report", "text" => text}}} =
             send_command(c, c.current.id, "/search tokenizer")

    assert text =~ "Parser rewrite"
    assert text =~ "/resume " <> String.slice(c.older.id, 0, 8)

    assert {:ok, %{"feedback" => %{"text" => nothing}}} =
             send_command(c, c.current.id, "/search zebra")

    assert nothing =~ "Nothing in this project"
  end

  test "/export writes Markdown atomically and never over a file", c do
    {:ok, _} =
      Conversations.create_message(%{
        conversation_id: c.current.id,
        role: "user",
        content: "Export me"
      })

    assert {:ok, %{"feedback" => %{"title" => "Exported", "text" => text}}} =
             send_command(c, c.current.id, "/export")

    [_, first] = String.split(text, "\n")
    assert Path.dirname(first) == Application.get_env(:swarm_code_daemon, :export_dir)
    assert File.read!(first) =~ "Export me"

    assert {:ok, %{"feedback" => %{"text" => again}}} = send_command(c, c.current.id, "/export")
    [_, second] = String.split(again, "\n")
    assert second != first and String.ends_with?(second, "-2.md")

    assert {:ok, %{"feedback" => %{"text" => named}}} =
             send_command(c, c.current.id, "/export notes.md")

    assert named =~ Path.join(c.root, "notes.md") or named =~ "notes.md"
    assert {:ok, %{"status" => "rejected"}} = send_command(c, c.current.id, "/export ../out.md")
    assert {:ok, %{"status" => "rejected"}} = send_command(c, c.current.id, "/export notes.exe")
  end

  test "/agents lists the definitions a swarm can use", c do
    assert {:ok, %{"feedback" => %{"title" => "Agents", "text" => text}}} =
             send_command(c, c.current.id, "/agents")

    assert text != ""
  end

  defp current(c) do
    {:ok, %{"value" => body}} =
      GenServer.call(
        c.backend,
        {:service_request, "list-#{System.unique_integer([:positive])}",
         %Scope{kind: :global, id: nil, generation: 0},
         %ServiceRequest{
           operation: :conversation_list,
           timeout_ms: 5000,
           params: %{"cursor" => nil, "page_size" => 50, "byte_limit" => 262_144}
         }},
        10_000
      )

    body["current_id"]
  end

  defp send_command(c, conversation, text) do
    {:ok, %{"value" => value}} =
      GenServer.call(
        c.backend,
        {:service_request, "cmd-#{System.unique_integer([:positive])}",
         %Scope{kind: :conversation, id: conversation, generation: 1},
         %ServiceRequest{
           operation: :dispatch_send,
           timeout_ms: 5000,
           params: %{
             "action" => "send",
             "text" => text,
             "target" => %{"kind" => "main", "id" => nil},
             "attachment_refs" => []
           }
         }},
        10_000
      )

    {:ok, value}
  end
end
