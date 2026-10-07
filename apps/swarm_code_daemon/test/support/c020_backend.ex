defmodule SwarmCode.Test.C020Backend do
  @moduledoc """
  cli020 lane C: the shared fixture of the persisted-backend tests (a fixture
  database under `tmp_dir`, a git project, a loopback model server). Nothing
  here reaches a remote provider or the real data folder.
  """
  import ExUnit.Callbacks, only: [start_supervised!: 1, on_exit: 1]
  alias SwarmCode.Daemon.Service.PersistedBackend, as: Backend
  alias SwarmCode.Domain.{Cache, Conversations, Projects, Providers, Repo}
  alias SwarmCode.Protocol.{Scope, ServiceRequest}
  alias SwarmCode.Test.LoopbackHTTP, as: HTTP

  @doc "A fixture database with every migration, a git project and private dirs."
  def setup_world(name, opts \\ []) do
    path = Path.join(System.tmp_dir!(), "c020-#{name}-#{System.unique_integer([:positive])}")
    root = Path.join(path, "project")
    File.mkdir_p!(root)
    System.cmd("git", ["init", "-q", root])
    prior = Application.get_env(:swarm_code_daemon, :domain_config_dir)
    old_llm = Application.get_env(:swarm_code_daemon, :llm_providers)

    Application.put_env(:swarm_code_daemon, :llm_providers, %{
      "openai_compatible" => SwarmCode.Domain.LLM.OpenAI
    })

    Application.put_env(:swarm_code_daemon, :domain_config_dir, Path.join(path, "config"))

    on_exit(fn ->
      Cache.clear()
      restore(:llm_providers, old_llm)
      restore(:domain_config_dir, prior)
      File.rm_rf!(path)
    end)

    unless Process.whereis(SwarmCode.Domain.Hooks.TaskSupervisor),
      do: start_supervised!({Task.Supervisor, name: SwarmCode.Domain.Hooks.TaskSupervisor})

    start_supervised!(
      {Repo,
       database: Path.join(path, "fixture.db"),
       domain_fixture: true,
       pool_size: Keyword.get(opts, :pool_size, 1),
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

    {:ok, project} = Projects.create(%{name: name, root_path: root})
    {:ok, project} = Projects.update(project, %{approval_mode: Keyword.get(opts, :mode, "auto")})
    %{path: path, root: root, project: project}
  end

  defp restore(key, nil), do: Application.delete_env(:swarm_code_daemon, key)
  defp restore(key, value), do: Application.put_env(:swarm_code_daemon, key, value)

  @doc "Start the persisted backend on `conversation` (supervised by the test)."
  def start_backend(world, conversation, extra \\ []) do
    opts =
      [
        mode: :persisted,
        repo: Repo,
        project_root: world.root,
        project_id: world.project.id,
        conversation_id: conversation.id,
        source_epoch: Ecto.UUID.generate()
      ] ++ extra

    start_supervised!(%{
      id: make_ref(),
      start: {Backend, :start_link, [opts]},
      restart: :temporary
    })
  end

  def scope(conversation), do: %Scope{kind: :conversation, id: conversation.id, generation: 3}

  @doc "A provider on a loopback server; `reply` is a function of the turn number."
  def provider!(world, conversation, reply) do
    server = HTTP.start(fn socket, _request, turn -> answer(socket, reply.(turn)) end)
    on_exit(fn -> HTTP.stop(server) end)

    {:ok, provider} =
      Providers.create(%{
        name: "c020-#{System.unique_integer([:positive])}",
        kind: "openai_compatible",
        base_url: server.url <> "/v1",
        models: ["fixture"],
        default_model: "fixture"
      })

    {:ok, conversation} =
      Conversations.update(conversation, %{chat_provider_id: provider.id, chat_model: "fixture"})

    _ = world
    {conversation, provider, server}
  end

  @doc "A tool call (run_command) on the first turn, then a plain reply."
  def command_then_text(command) do
    fn
      1 -> {:tool, "run_command", %{"command" => command, "justification" => "A test marker."}}
      _ -> {:text, "Command finished."}
    end
  end

  defp answer(socket, {:status, code}) do
    :gen_tcp.send(
      socket,
      "HTTP/1.1 #{code} Error\r\ncontent-type: application/json\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}"
    )
  end

  defp answer(socket, {:text, text}), do: stream(socket, %{"content" => text}, "stop")

  defp answer(socket, {:tool, name, args}) do
    delta = %{
      "tool_calls" => [
        %{
          "index" => 0,
          "id" => "call-#{System.unique_integer([:positive])}",
          "type" => "function",
          "function" => %{"name" => name, "arguments" => Jason.encode!(args)}
        }
      ]
    }

    stream(socket, delta, "tool_calls")
  end

  defp stream(socket, delta, finish) do
    HTTP.stream(socket, [
      HTTP.sse(%{
        "choices" => [%{"index" => 0, "delta" => delta, "finish_reason" => finish}]
      })
    ])
  end

  def request(backend, id, scope, %ServiceRequest{} = request),
    do: GenServer.call(backend, {:service_request, id(id), scope, request}, 15_000)

  def command(backend, id, scope, operation, params),
    do:
      request(backend, id, scope, %ServiceRequest{
        operation: operation,
        timeout_ms: 5000,
        params: params
      })

  def send_text(backend, scope, text, action \\ "send"),
    do:
      command(backend, "send", scope, :dispatch_send, %{
        "action" => action,
        "text" => text,
        "target" => %{"kind" => "main", "id" => nil},
        "attachment_refs" => []
      })

  def query(backend, scope, slot),
    do:
      command(backend, "query", scope, :query, %{
        "slot" => slot,
        "cursor" => nil,
        "direction" => "before",
        "page_size" => 50,
        "byte_limit" => 1_048_576
      })

  def workspace(backend, scope) do
    {:ok, %{"value" => value}} = query(backend, scope, "workspace")
    value
  end

  def pending_approvals(backend, scope) do
    {:ok, %{"value" => %{"items" => items}}} = query(backend, scope, "pending")
    Enum.filter(items, &(&1["kind"] == "approval"))
  end

  # The command ledger is durable per project: every request names its own id.
  def id(name), do: "#{name}-#{System.unique_integer([:positive])}"

  def eventually(fun, n \\ 400)
  def eventually(fun, 0), do: fun.()

  def eventually(fun, n) do
    if fun.() do
      true
    else
      receive do
      after
        20 -> eventually(fun, n - 1)
      end
    end
  end
end
