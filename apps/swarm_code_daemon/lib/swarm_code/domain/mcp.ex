defmodule SwarmCode.Domain.MCP do
  @moduledoc """
  Model Context Protocol servers: configuration, the client registry and the tool
  table every agent reads through `SwarmCode.Domain.Tools`.
  """
  import Ecto.Query, warn: false, except: [update: 2, update: 3]

  alias SwarmCode.Domain.MCP.{Client, Server}
  alias SwarmCode.Domain.Repo
  alias SwarmCode.Domain.Tools.Ref

  @tools_table :swarm_code_mcp_tools
  @status_table :swarm_code_mcp_status

  def tools_table, do: @tools_table
  def status_table, do: @status_table

  ## ------------------------------------------------------------- persistence

  def list do
    Repo.all(from(s in Server, order_by: [asc: s.name]))
  end

  def list_enabled do
    Repo.all(from(s in Server, where: s.enabled == true, order_by: [asc: s.name]))
  end

  def get(id), do: Repo.get(Server, id)
  def get!(id), do: Repo.get!(Server, id)

  def change(%Server{} = server, attrs \\ %{}), do: Server.changeset(server, attrs)

  def create(attrs) do
    case %Server{} |> Server.changeset(attrs) |> reject_slug_collision(nil) |> Repo.insert() do
      {:ok, server} ->
        if server.enabled, do: start_client(server)
        broadcast()
        {:ok, server}

      {:error, cs} ->
        {:error, cs}
    end
  end

  def update(%Server{} = server, attrs) do
    case server |> Server.changeset(attrs) |> reject_slug_collision(server.id) |> Repo.update() do
      {:ok, updated} ->
        stop_client(updated.id)
        if updated.enabled, do: start_client(updated)
        broadcast()
        {:ok, updated}

      {:error, cs} ->
        {:error, cs}
    end
  end

  # spec 60 T15 (spec 55 A21): one slug = one `mcp__<slug>__` prefix in the tools table.
  defp reject_slug_collision(%Ecto.Changeset{valid?: false} = cs, _id), do: cs

  defp reject_slug_collision(cs, id) do
    slug = cs |> Ecto.Changeset.get_field(:name) |> Server.slug()

    case Enum.find(list(), &(&1.id != id and Server.slug(&1) == slug)) do
      nil ->
        cs

      other ->
        Ecto.Changeset.add_error(
          cs,
          :name,
          "shares the tool prefix mcp__#{slug}__ with \"#{other.name}\""
        )
    end
  end

  def delete(%Server{} = server) do
    stop_client(server.id)
    result = Repo.delete(server)
    broadcast()
    result
  end

  def toggle(%Server{} = server), do: update(server, %{enabled: !server.enabled})

  def subscribe, do: SwarmCode.Domain.PubSub.subscribe(SwarmCode.Domain.PubSub, "mcp")

  def broadcast,
    do: SwarmCode.Domain.PubSub.broadcast(SwarmCode.Domain.PubSub, "mcp", {:mcp_changed})

  def broadcast_status(id, status),
    do:
      SwarmCode.Domain.PubSub.broadcast(SwarmCode.Domain.PubSub, "mcp", {:mcp_status, id, status})

  ## ------------------------------------------------------------------ clients

  def via(id), do: {:via, Registry, {SwarmCode.Domain.Registry, {:mcp, id}}}

  def start_client(%Server{} = server) do
    DynamicSupervisor.start_child(SwarmCode.Domain.MCP.ClientSup, {Client, server})
  end

  def stop_client(id) do
    case Registry.lookup(SwarmCode.Domain.Registry, {:mcp, id}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(SwarmCode.Domain.MCP.ClientSup, pid)
      [] -> :ok
    end

    forget(id)
    :ok
  end

  def reconnect(id) do
    case Registry.lookup(SwarmCode.Domain.Registry, {:mcp, id}) do
      [{pid, _}] ->
        send(pid, :connect)

      [] ->
        case get(id) do
          %Server{enabled: true} = s -> start_client(s)
          _ -> :ok
        end
    end

    :ok
  end

  @doc "Starts a client for every enabled server (called at boot)."
  def start_all do
    Enum.reduce_while(list_enabled(), :ok, fn server, :ok ->
      case start_client(server) do
        {:ok, _pid} -> {:cont, :ok}
        {:error, {:already_started, _pid}} -> {:cont, :ok}
        :ignore -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {server.id, reason}}}
      end
    end)
  end

  ## ------------------------------------------------------------- tool registry

  @doc "Creates the ETS tables if they do not exist yet."
  def ensure_tables do
    if :ets.whereis(@tools_table) == :undefined do
      :ets.new(@tools_table, [:named_table, :public, :set, read_concurrency: true])
    end

    if :ets.whereis(@status_table) == :undefined do
      :ets.new(@status_table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc "Replaces the tool rows of one server."
  def put_tools(%Server{} = server, tools) do
    ensure_tables()
    forget_tools(server.id)
    prefix = "mcp__" <> Server.slug(server) <> "__"

    Enum.each(tools, fn tool ->
      name = prefix <> to_string(tool["name"])
      read_only? = get_in(tool, ["annotations", "readOnlyHint"]) == true

      :ets.insert(
        @tools_table,
        {name, server.id, server.project_id, tool, read_only?, server.name}
      )
    end)

    :ok
  end

  def forget_tools(server_id) do
    if :ets.whereis(@tools_table) != :undefined do
      :ets.match_delete(@tools_table, {:_, server_id, :_, :_, :_, :_})
    end

    :ok
  end

  def forget(server_id) do
    forget_tools(server_id)

    if :ets.whereis(@status_table) != :undefined do
      :ets.delete(@status_table, server_id)
    end

    :ok
  end

  @doc "Every tool of the global servers plus the ones of `project_id`."
  @spec tools_for(String.t() | nil) :: [Ref.t()]
  def tools_for(project_id) do
    if :ets.whereis(@tools_table) == :undefined do
      []
    else
      @tools_table
      |> :ets.tab2list()
      |> Enum.filter(fn {_n, _sid, pid, _t, _ro, _sn} -> pid == nil or pid == project_id end)
      |> Enum.sort_by(fn {n, _, _, _, _, _} -> n end)
      |> Enum.map(&to_ref/1)
    end
  end

  @spec lookup(String.t()) :: {:ok, Ref.t()} | :error
  def lookup(name) do
    if :ets.whereis(@tools_table) == :undefined do
      :error
    else
      case :ets.lookup(@tools_table, name) do
        [row] -> {:ok, to_ref(row)}
        [] -> :error
      end
    end
  end

  defp to_ref({name, server_id, _project_id, tool, read_only?, server_name}) do
    %Ref{
      name: name,
      description: to_string(tool["description"] || tool["title"] || name),
      parameters: tool["inputSchema"] || %{"type" => "object", "properties" => %{}},
      kind: :mcp,
      server_id: server_id,
      server_name: server_name,
      tool_name: to_string(tool["name"]),
      read_only?: read_only?
    }
  end

  @doc "The tools of one server, for the Settings list."
  def tools_of(server_id) do
    if :ets.whereis(@tools_table) == :undefined do
      []
    else
      @tools_table
      |> :ets.tab2list()
      |> Enum.filter(fn {_n, sid, _p, _t, _ro, _sn} -> sid == server_id end)
      |> Enum.sort_by(fn {n, _, _, _, _, _} -> n end)
      |> Enum.map(&to_ref/1)
    end
  end

  ## ----------------------------------------------------------------- status

  def put_status(server_id, status) do
    ensure_tables()
    :ets.insert(@status_table, {server_id, status})
    broadcast_status(server_id, status)
    :ok
  end

  @spec status(String.t()) :: :connecting | :ready | {:error, String.t()} | :stopped
  def status(server_id) do
    if :ets.whereis(@status_table) == :undefined do
      :stopped
    else
      case :ets.lookup(@status_table, server_id) do
        [{^server_id, status}] -> status
        [] -> :stopped
      end
    end
  end

  ## ------------------------------------------------------------------- calls

  @doc "Calls `tool_name` on `server_id`. Returns the joined text content."
  @spec call(String.t(), String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def call(server_id, tool_name, args, opts \\ []) do
    timeout = opts[:timeout] || 120_000

    case Registry.lookup(SwarmCode.Domain.Registry, {:mcp, server_id}) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, {:call_tool, tool_name, args, timeout}, timeout + 5_000)
        catch
          :exit, _ -> {:error, "MCP server is not connected"}
        end

      [] ->
        name = (get(server_id) || %{}) |> Map.get(:name, server_id)
        {:error, "MCP server #{name} is not connected"}
    end
  end
end
