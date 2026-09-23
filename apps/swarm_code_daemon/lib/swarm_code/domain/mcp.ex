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
  # spec 67 T28 (G37): the last lines a server said about itself, mirrored out
  # of the client's state so Settings can read them while the client is busy
  # with a two-minute `tools/call`.
  @output_table :swarm_code_mcp_output

  def tools_table, do: @tools_table
  def status_table, do: @status_table
  def output_table, do: @output_table

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

    if :ets.whereis(@output_table) == :undefined do
      :ets.new(@output_table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  end

  @doc """
  Stores this server's recent output, newest first (spec 67 T28, G37).

  Called by `SwarmCode.Domain.MCP.Client` only; the ring buffer itself lives in the
  client's state and this is the copy anyone else may read.
  """
  @spec put_output(String.t(), [String.t()]) :: :ok
  def put_output(server_id, lines) when is_list(lines) do
    ensure_tables()
    :ets.insert(@output_table, {server_id, lines})
    :ok
  end

  @doc """
  The last lines `server_id` wrote about itself — `notifications/message` and,
  on stdio, its stderr — oldest first, at most twenty (spec 67 T28, G37).
  """
  @spec recent_output(String.t()) :: [String.t()]
  def recent_output(server_id) do
    if :ets.whereis(@output_table) == :undefined do
      []
    else
      case :ets.lookup(@output_table, server_id) do
        [{^server_id, lines}] -> Enum.reverse(lines)
        _other -> []
      end
    end
  end

  @doc """
  Replaces the tool rows of one server.

  spec 62 T2: every tool of the server is published — the Settings card lists
  them all — but each row carries whether the owner left it on. A reconnect
  republishes from the persisted set, not from the struct the client cached at
  boot, so switching a tool off survives one.
  """
  def put_tools(%Server{} = server, tools) do
    ensure_tables()
    forget_tools(server.id)
    prefix = "mcp__" <> Server.slug(server) <> "__"
    disabled = disabled_tools(server)

    # spec 67 T13 (G34): two real names that sanitise to one published name
    # (`search.web`, `search_web`) both take the hashed form — it hashes the
    # real pair, and the pick does not depend on the order the server lists them.
    # A tool listed twice (a repeating cursor) is one name, not a clash.
    plain =
      tools
      |> Enum.map(&to_string(&1["name"]))
      |> Enum.uniq()
      |> Enum.map(&tool_name(server, prefix, &1))

    clashes = for {name, n} <- Enum.frequencies(plain), n > 1, into: MapSet.new(), do: name

    Enum.each(tools, fn tool ->
      raw = to_string(tool["name"])
      plain_name = tool_name(server, prefix, raw)

      name =
        if MapSet.member?(clashes, plain_name),
          do: tool_name(server, prefix, raw, hashed: true),
          else: plain_name

      read_only? = get_in(tool, ["annotations", "readOnlyHint"]) == true

      :ets.insert(
        @tools_table,
        {name, server.id, server.project_id, tool, read_only?, server.name, raw not in disabled}
      )
    end)

    :ok
  end

  # The persisted set wins over the (possibly stale) struct; a busy or missing
  # row falls back to what the caller handed us.
  defp disabled_tools(%Server{id: id} = server) when is_binary(id) do
    case Repo.retry(:mcp_disabled_tools, fn -> Repo.get(Server, id) end) do
      %Server{disabled_tools: list} when is_list(list) -> list
      _other -> server.disabled_tools || []
    end
  end

  defp disabled_tools(%Server{} = server), do: server.disabled_tools || []

  @doc """
  Switches one tool of a server on or off (spec 62 T1). The change reaches the
  agents at once: the rows already in the tool table are flipped, and the
  connected client is handed the new row so a later republish keeps the set.
  """
  @spec set_tool_enabled(String.t(), String.t(), boolean()) ::
          {:ok, %Server{}} | {:error, term()}
  def set_tool_enabled(server_id, tool_name, enabled?) do
    case get(server_id) do
      nil ->
        {:error, :not_found}

      %Server{} = server ->
        current = server.disabled_tools || []

        next =
          if enabled?,
            do: Enum.reject(current, &(&1 == tool_name)),
            else: Enum.uniq(current ++ [tool_name])

        write =
          Repo.retry(:mcp_set_tool_enabled, fn ->
            server |> Server.changeset(%{disabled_tools: next}) |> Repo.update()
          end)

        case write do
          {:ok, updated} ->
            republish_tools(updated)
            broadcast()
            {:ok, updated}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # spec 62 T1: no reconnect — the published rows are flipped in place, and the
  # running client gets the new set for its next `put_tools/2`.
  defp republish_tools(%Server{} = server) do
    disabled = server.disabled_tools || []

    case Registry.lookup(SwarmCode.Domain.Registry, {:mcp, server.id}) do
      [{pid, _}] -> send(pid, {:tools_toggled, disabled})
      [] -> :ok
    end

    if :ets.whereis(@tools_table) != :undefined do
      # spec 68 T13: fetch only this server's rows instead of scanning all.
      @tools_table
      |> :ets.match_object({:_, server.id, :_, :_, :_, :_, :_})
      |> Enum.each(fn {name, sid, project_id, tool, read_only?, server_name, _enabled?} ->
        :ets.insert(
          @tools_table,
          {name, sid, project_id, tool, read_only?, server_name,
           to_string(tool["name"]) not in disabled}
        )
      end)
    end

    :ok
  end

  # spec 61 T10: Anthropic and OpenAI both refuse a function name over 64 chars,
  # and an MCP server is free to publish a 90-char tool. The shortened name is
  # deterministic (same server + tool = same name across restarts) and carries a
  # hash of the pair, so two long names of one server never collide. Dispatch is
  # unaffected: the ETS row keeps the real `tool["name"]`, which is what
  # `to_ref/1` hands the client.
  #
  # spec 67 T13 (G34): the name goes to the provider verbatim, and Anthropic
  # takes only `^[a-zA-Z0-9_-]{1,64}$` (OpenAI the same characters). An MCP
  # server is free to publish `search.web`, and one that did made every request
  # 400 for as long as it was enabled. Every other character becomes `_` before
  # the length rule; the server half was already safe (`Server.slug/1` keeps
  # `[a-z0-9_]`). `hashed: true` forces the suffixed form — `put_tools/2` uses it
  # when two real names sanitise alike.
  @max_tool_name 64
  @tool_name_unsafe ~r/[^a-zA-Z0-9_-]/u

  @doc false
  def tool_name(%Server{} = server, prefix, tool, opts \\ []) do
    safe = String.replace(tool, @tool_name_unsafe, "_")
    full = prefix <> safe

    if byte_size(full) <= @max_tool_name and not Keyword.get(opts, :hashed, false) do
      full
    else
      # The hash is of the real pair, so `search.web` and `search_web` stay apart.
      hash = :erlang.phash2({server.name, tool}) |> Integer.to_string(16) |> String.downcase()
      suffix = "_" <> String.slice(String.pad_leading(hash, 6, "0"), 0, 6)
      short_prefix = "mcp__" <> String.slice(Server.slug(server), 0, 16) <> "__"
      room = @max_tool_name - byte_size(short_prefix) - byte_size(suffix)
      short_prefix <> clip_bytes(safe, max(room, 0)) <> suffix
    end
  end

  defp clip_bytes(text, max) when byte_size(text) <= max, do: text

  defp clip_bytes(text, max),
    do: text |> String.slice(0, max(String.length(text) - 1, 0)) |> clip_bytes(max)

  def forget_tools(server_id) do
    if :ets.whereis(@tools_table) != :undefined do
      :ets.match_delete(@tools_table, {:_, server_id, :_, :_, :_, :_, :_})
    end

    :ok
  end

  def forget(server_id) do
    forget_tools(server_id)

    if :ets.whereis(@status_table) != :undefined do
      :ets.delete(@status_table, server_id)
    end

    if :ets.whereis(@output_table) != :undefined do
      :ets.delete(@output_table, server_id)
    end

    :ok
  end

  @doc "Every tool of the global servers plus the ones of `project_id`."
  @spec tools_for(String.t() | nil) :: [Ref.t()]
  def tools_for(project_id) do
    if :ets.whereis(@tools_table) == :undefined do
      []
    else
      # spec 68 T12: filter at the ETS level with :ets.select instead of
      # tab2list + Enum.filter.
      ms = [
        {{:"$1", :_, nil, :_, :_, :_, true}, [], [:"$_"]},
        {{:"$1", :_, project_id, :_, :_, :_, true}, [], [:"$_"]}
      ]

      @tools_table
      |> :ets.select(ms)
      |> Enum.sort_by(fn {n, _, _, _, _, _, _} -> n end)
      |> Enum.map(&to_ref/1)
    end
  end

  @spec lookup(String.t()) :: {:ok, Ref.t()} | :error
  def lookup(name) do
    if :ets.whereis(@tools_table) == :undefined do
      :error
    else
      case :ets.lookup(@tools_table, name) do
        # spec 62 T2: a disabled tool is not callable either — a model that
        # guesses the name gets the unknown-tool error.
        [{_n, _sid, _p, _t, _ro, _sn, true} = row] -> {:ok, to_ref(row)}
        _other -> :error
      end
    end
  end

  defp to_ref({name, server_id, _project_id, tool, read_only?, server_name, enabled?}) do
    %Ref{
      name: name,
      description: to_string(tool["description"] || tool["title"] || name),
      parameters: tool["inputSchema"] || %{"type" => "object", "properties" => %{}},
      kind: :mcp,
      server_id: server_id,
      server_name: server_name,
      tool_name: to_string(tool["name"]),
      read_only?: read_only?,
      enabled?: enabled?
    }
  end

  @doc """
  The tools of one server, for the Settings list — the disabled ones included,
  each ref carrying its `enabled?` (spec 62 T2).
  """
  def tools_of(server_id) do
    if :ets.whereis(@tools_table) == :undefined do
      []
    else
      # spec 68 T12: filter at the ETS level with match_object.
      @tools_table
      |> :ets.match_object({:_, server_id, :_, :_, :_, :_, :_})
      |> Enum.sort_by(fn {n, _, _, _, _, _, _} -> n end)
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

  # spec 67 T34 (G35): where the images of the call that just ran wait for
  # `Engine.Operation` to pick them up. The tool result travels as a string
  # through `Tools.run/4` (owner D1's file this pass, and a `{:ok, text, images}`
  # return would break its `case`), so the bytes ride the op task's own process
  # dictionary for the two stack frames between here and there instead.
  @images_key :swarm_code_mcp_images

  @doc "Calls `tool_name` on `server_id` and returns `{:ok, text, images}` (spec 67 T34)."
  @spec call_with_images(String.t(), String.t(), map(), keyword()) ::
          {:ok, String.t(), [map()]} | {:error, String.t()}
  def call_with_images(server_id, tool_name, args, opts \\ []) do
    timeout = opts[:timeout] || 120_000

    case Registry.lookup(SwarmCode.Domain.Registry, {:mcp, server_id}) do
      [{pid, _}] ->
        try do
          case GenServer.call(pid, {:call_tool, tool_name, args, timeout}, timeout + 5_000) do
            {:ok, text, images} -> {:ok, text, images}
            {:ok, text} -> {:ok, text, []}
            {:error, reason} -> {:error, reason}
          end
        catch
          :exit, _ -> {:error, "MCP server is not connected"}
        end

      [] ->
        name = (get(server_id) || %{}) |> Map.get(:name, server_id)
        {:error, "MCP server #{name} is not connected"}
    end
  end

  @doc """
  Calls `tool_name` on `server_id`. Returns the joined text content.

  Any `image` blocks of the result are left for `take_images/0` (spec 67 T34).
  """
  @spec call(String.t(), String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def call(server_id, tool_name, args, opts \\ []) do
    Process.delete(@images_key)

    case call_with_images(server_id, tool_name, args, opts) do
      {:ok, text, []} ->
        {:ok, text}

      {:ok, text, images} ->
        Process.put(@images_key, images)
        {:ok, text}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "The images the last `call/4` of this process returned, once (spec 67 T34)."
  @spec take_images() :: [map()]
  def take_images, do: Process.delete(@images_key) || []
end
