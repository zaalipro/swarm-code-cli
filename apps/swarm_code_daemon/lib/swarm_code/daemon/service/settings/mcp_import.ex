defmodule SwarmCode.Daemon.Service.Settings.MCPImport do
  @moduledoc """
  Importing MCP servers from a `.mcp.json` (pass 74 §3.5.4, §2.7): the read
  task parses `<page project root>/.mcp.json` or a typed path inside the
  user's home into drafts — masked rows for the client, the parsed values
  (secrets included) kept only in the task cache under the task id for ten
  minutes — and `mcp.import.apply` creates the ticked servers, filling each
  `${NAME}` reference from the shell, a pasted slot or the literal text.
  """

  @behaviour SwarmCode.Daemon.Service.Settings.Handler

  alias SwarmCode.Daemon.Service.Settings.{Kit, Result, Secrets}
  alias SwarmCode.Domain.{MCP, Projects, Repo}
  alias SwarmCode.Domain.MCP.Server
  alias SwarmCode.Domain.Tools.Path, as: Confined

  @max_bytes 1_048_576
  @max_drafts 200
  @max_entries 64
  @read_ms 10_000
  @variable ~r/^(?:\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*))$/
  @sse "SSE servers are not supported; use the server's streamable http URL"

  @doc false
  def actions, do: ~w(mcp.import.read mcp.import.apply)

  @doc false
  def views, do: []

  @doc false
  def cache_reads("mcp.import.apply"), do: [{"mcp.import.read", {:param, "import_id"}}]
  def cache_reads(_other), do: []

  @doc false
  def query(_view, _kind, _params, _ctx), do: Kit.unsupported()

  ## ------------------------------------------------------------ read

  @doc false
  def command(%{action: "mcp.import.read"} = cmd, ctx) do
    path = Kit.get(Kit.cmd(cmd, :attributes), "path")
    root = project_root(ctx)

    with {:ok, file} <- file(path, root) do
      Kit.task(
        action: "mcp.import.read",
        key: "import",
        timeout_ms: @read_ms,
        cancellable?: true,
        kind: :plain,
        run: fn _report -> read(file) end,
        summary: &Map.drop(&1, ["rows", "drafts"]),
        redact: [],
        holds_secrets?: true
      )
    end
  end

  def command(%{action: "mcp.import.apply"} = cmd, ctx), do: apply_import(cmd, ctx)
  def command(_cmd, _ctx), do: Kit.unsupported()

  defp project_root(ctx) do
    case Kit.ctx(ctx, :project) do
      %{root_path: root} when is_binary(root) -> root
      _ -> nil
    end
  end

  # Which file: the page project's `.mcp.json`, or a typed path confined to
  # the user's home (after symlinks).
  defp file(nil, nil),
    do: Kit.error(:invalid, "open a project first, or type the path of a .mcp.json")

  defp file(nil, root) do
    case Confined.resolve(root, ".mcp.json") do
      {:ok, path} -> {:ok, path}
      {:error, _} -> Kit.error(:invalid, ".mcp.json points outside the project")
    end
  end

  defp file(path, _root) when is_binary(path) do
    home = Kit.home()
    typed = String.trim(path)

    expanded =
      cond do
        typed == "~" -> home
        String.starts_with?(typed, "~/") -> Path.join(home, String.slice(typed, 2..-1//1))
        true -> typed
      end

    cond do
      typed == "" or is_nil(home) ->
        Kit.error(:invalid, "type the path of a .mcp.json")

      Path.type(expanded) != :absolute ->
        Kit.error(:invalid, "type a full path or one starting with ~/")

      true ->
        case Confined.resolve(home, expanded) do
          {:ok, resolved} -> {:ok, resolved}
          {:error, _} -> Kit.error(:invalid, "only files inside your home folder can be read")
        end
    end
  end

  defp file(_path, _root), do: Kit.error(:invalid, "type the path of a .mcp.json")

  @doc false
  # The read task: at most 1 MiB, JSON `{"mcpServers": {...}}` → drafts.
  def read(path) do
    with {:ok, text} <- bounded_read(path),
         {:ok, json} <- decode(text),
         {:ok, servers} <- servers(json) do
      existing = MapSet.new(Repo.all(Server), & &1.name)
      entries = Enum.sort_by(servers, &elem(&1, 0))
      kept = Enum.take(entries, @max_drafts)
      parsed = Enum.map(kept, fn {name, cfg} -> parse(to_string(name), cfg) end)
      rows = Enum.map(parsed, &row(&1, existing))

      {:ok,
       %{
         "path" => Kit.tilde(path),
         "count" => length(rows),
         "total" => length(entries),
         "truncated" => length(entries) > @max_drafts,
         "conflicts" => Enum.count(rows, & &1["conflict"]),
         "unsupported" => Enum.count(rows, & &1["unsupported"]),
         "rows" => rows,
         # the values as written, secrets included — never sent (only `rows`
         # are paged); Base64 so a string-walking redaction leaves them whole
         "drafts" =>
           parsed |> Map.new(&{&1.name, stored(&1)}) |> Jason.encode!() |> Base.encode64()
       }}
    end
  end

  defp bounded_read(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        try do
          case IO.binread(io, @max_bytes + 1) do
            data when is_binary(data) and byte_size(data) > @max_bytes ->
              {:error, "#{Kit.tilde(path)} is over 1 MiB"}

            data when is_binary(data) ->
              {:ok, data}

            :eof ->
              {:ok, ""}

            {:error, reason} ->
              {:error, "Couldn't read #{Kit.tilde(path)}: #{:file.format_error(reason)}"}
          end
        after
          File.close(io)
        end

      {:error, :enoent} ->
        {:error, "#{Kit.tilde(path)} does not exist"}

      {:error, :eisdir} ->
        {:error, "#{Kit.tilde(path)} is a folder"}

      {:error, reason} ->
        {:error, "Couldn't read #{Kit.tilde(path)}: #{:file.format_error(reason)}"}
    end
  end

  defp decode(text) do
    case Jason.decode(text) do
      {:ok, json} ->
        {:ok, json}

      {:error, %Jason.DecodeError{position: position}} ->
        {line, column} = line_column(text, position)
        {:error, "not valid JSON: line #{line}, column #{column}"}
    end
  end

  defp line_column(text, position) do
    before = binary_part(text, 0, min(position, byte_size(text)))
    lines = String.split(before, "\n")
    {length(lines), String.length(List.last(lines)) + 1}
  end

  defp servers(%{"mcpServers" => servers}) when is_map(servers), do: {:ok, servers}
  defp servers(_json), do: {:error, "no \"mcpServers\" object in that file"}

  # One entry as written: its transport, values and variable references.
  defp parse(name, cfg) when is_map(cfg) do
    type = cfg["type"]
    url = string(cfg["url"])

    {transport, unsupported, message} =
      cond do
        type == "sse" -> {"http", true, @sse}
        is_binary(url) or type in ["http", "streamable-http"] -> {"http", false, nil}
        true -> {"stdio", false, nil}
      end

    env = kv(cfg["env"])
    headers = kv(cfg["headers"])

    {unsupported, message} =
      cond do
        unsupported -> {true, message}
        map_size(env) > @max_entries -> {true, "more than #{@max_entries} environment entries"}
        map_size(headers) > @max_entries -> {true, "more than #{@max_entries} headers"}
        true -> {false, nil}
      end

    %{
      name: name,
      transport: transport,
      command: string(cfg["command"]),
      args: cfg |> Map.get("args") |> args(),
      env: env,
      url: url,
      headers: headers,
      unsupported: unsupported,
      message: message,
      variables: variables("env", env) ++ variables("headers", headers)
    }
  end

  defp parse(name, _cfg),
    do: %{
      name: name,
      transport: "stdio",
      command: nil,
      args: [],
      env: %{},
      url: nil,
      headers: %{},
      unsupported: true,
      message: "not a server entry",
      variables: []
    }

  defp string(value) when is_binary(value), do: value
  defp string(_value), do: nil

  defp args(list) when is_list(list), do: list |> Enum.map(&to_string/1) |> Enum.take(64)
  defp args(_other), do: []

  defp kv(map) when is_map(map),
    do:
      Map.new(map, fn {k, v} ->
        {to_string(k), if(is_binary(v), do: v, else: Jason.encode!(v))}
      end)

  defp kv(_other), do: %{}

  defp variables(map, entries) do
    for {name, value} <- Enum.sort(entries), ref = reference(value), ref != nil do
      %{"map" => map, "name" => name, "ref" => ref, "in_shell" => System.get_env(ref) != nil}
    end
  end

  defp reference(value) do
    case Regex.run(@variable, value) do
      [_, ref] -> ref
      [_, "", ref] -> ref
      _ -> nil
    end
  end

  # The masked row the client pages (mcp_import_draft).
  defp row(draft, existing) do
    %{
      "name" => draft.name,
      "transport" => draft.transport,
      "command" => draft.command,
      "args" => draft.args,
      "env" => Secrets.masked_entries(draft.env),
      "url" => draft.url,
      "headers" => Secrets.masked_entries(draft.headers),
      "conflict" => MapSet.member?(existing, draft.name),
      "unsupported" => draft.unsupported,
      "message" => draft.message,
      "variables" => draft.variables
    }
  end

  defp stored(draft) do
    %{
      "transport" => draft.transport,
      "command" => draft.command,
      "args" => draft.args,
      "env" => draft.env,
      "url" => draft.url,
      "headers" => draft.headers,
      "unsupported" => draft.unsupported,
      "message" => draft.message,
      "variables" => draft.variables
    }
  end

  ## ------------------------------------------------------------ apply

  defp apply_import(cmd, ctx) do
    attrs = Kit.cmd(cmd, :attributes)
    import_id = Kit.get(attrs, "import_id")
    names = Kit.get(attrs, "names")
    renames = Kit.get(attrs, "rename") || %{}
    values = Kit.get(attrs, "values") || %{}

    with true <-
           (is_list(names) and names != [] and Enum.all?(names, &is_binary/1)) ||
             Kit.error(:invalid, "tick the servers to add"),
         true <-
           (is_map(renames) and is_map(values)) ||
             Kit.error(:invalid, "rename and values are maps"),
         {:ok, project_id} <- project(Kit.get(attrs, "project_id")),
         {:ok, drafts} <- drafts(ctx, import_id) do
      rows =
        names
        |> Enum.uniq()
        |> Enum.map(fn name ->
          apply_one(name, Map.get(drafts, name), renames, values, project_id, cmd)
        end)

      added = Enum.count(rows, &(&1.status == :accepted))
      left = length(rows) - added

      Kit.ok(Result.worst(rows),
        results: rows,
        message:
          case {added, left} do
            {n, 0} -> "#{n} #{servers_word(n)} added"
            {0, m} -> "no server added · #{m} not added"
            {n, m} -> "#{n} #{servers_word(n)} added · #{m} not added"
          end
      )
    end
  end

  defp servers_word(1), do: "server"
  defp servers_word(_), do: "servers"

  defp project(nil), do: {:ok, nil}

  defp project(id) when is_binary(id) do
    case Projects.get(id) do
      nil ->
        Kit.error(:invalid, "no such project", [Kit.field_error("project_id", "no such project")])

      _ ->
        {:ok, id}
    end
  rescue
    Ecto.Query.CastError ->
      Kit.error(:invalid, "no such project", [Kit.field_error("project_id", "no such project")])
  end

  defp project(_id), do: Kit.error(:invalid, "no such project")

  # The cached parse of `import_id` (declared cache read); gone after ten minutes.
  defp drafts(ctx, import_id) when is_binary(import_id) do
    with %{} = entry <- Kit.task_entry(ctx, "mcp.import.read", import_id),
         %{} = result <- entry.result,
         encoded when is_binary(encoded) <- Kit.get(result, "drafts"),
         {:ok, json} <- Base.decode64(encoded),
         {:ok, drafts} when is_map(drafts) <- Jason.decode(json) do
      {:ok, drafts}
    else
      _ -> expired()
    end
  end

  defp drafts(_ctx, _import_id), do: expired()

  defp expired,
    do:
      Kit.error(
        :not_found,
        "That import has expired (they last ten minutes); read the file again."
      )

  defp apply_one(name, nil, _renames, _values, _project_id, _cmd),
    do: Kit.row(name, :rejected, message: "#{name} is not in that file")

  defp apply_one(name, draft, renames, values, project_id, cmd) do
    final = renames |> Map.get(name, name) |> to_string() |> String.trim()

    with :ok <- supported(draft),
         {:ok, env} <- fill(name, "env", draft["env"], draft["variables"], values, cmd),
         {:ok, headers} <-
           fill(name, "headers", draft["headers"], draft["variables"], values, cmd) do
      attrs = %{
        name: final,
        transport: draft["transport"],
        command: draft["command"],
        args: draft["args"] || [],
        env: env,
        url: draft["url"],
        headers: headers,
        enabled: true,
        project_id: project_id
      }

      if Map.get(cmd, :dry_run) do
        changeset = Server.changeset(%Server{}, attrs)

        if changeset.valid?,
          do: Kit.row(name, :accepted, value: final),
          else: Kit.row(name, :rejected, message: first_error(changeset))
      else
        case MCP.create(attrs) do
          {:ok, server} ->
            Kit.row(name, :accepted, value: server.name, message: "#{server.name} added")

          {:error, changeset} ->
            Kit.row(name, :rejected, message: first_error(changeset))
        end
      end
    else
      {:rejected, message} -> Kit.row(name, :rejected, message: message)
    end
  end

  defp supported(%{"unsupported" => true} = draft),
    do: {:rejected, draft["message"] || "this server cannot be imported"}

  defp supported(_draft), do: :ok

  # Each variable of `map` by its choice: the shell now, a pasted slot, or
  # the text as written.
  defp fill(server, map, entries, variables, values, cmd) do
    choices = Map.get(values, server) || %{}
    prefix = if map == "headers", do: "header", else: "env"

    (variables || [])
    |> Enum.filter(&(&1["map"] == map))
    |> Enum.reduce_while({:ok, entries || %{}}, fn var, {:ok, acc} ->
      entry = var["name"]

      case Map.get(choices, "#{prefix}.#{entry}") do
        "shell" ->
          case System.get_env(var["ref"]) do
            nil -> {:halt, {:rejected, "#{var["ref"]} is not set in this shell"}}
            value -> {:cont, {:ok, Map.put(acc, entry, value)}}
          end

        "paste" ->
          case Secrets.take(cmd, "import:#{server}:#{prefix}:#{entry}") do
            {:ok, value} when is_binary(value) and value != "" ->
              {:cont, {:ok, Map.put(acc, entry, value)}}

            _ ->
              {:halt, {:rejected, "paste #{entry}"}}
          end

        "literal" ->
          {:cont, {:ok, acc}}

        _ ->
          {:halt, {:rejected, "choose shell, paste or literal for #{entry}"}}
      end
    end)
  end

  defp first_error(changeset) do
    case Kit.changeset_errors(changeset) do
      [%{target: target, message: message} | _] -> "#{target} #{message}"
      [] -> "Couldn't add that server."
    end
  end
end
