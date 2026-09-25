defmodule SwarmCode.Daemon.Service.Settings.MCP do
  @moduledoc """
  MCP servers in settings (pass 74 §3.5.4): records with the supervisor's
  status and tools, environment and headers in the masked wire form (secret by
  `SecretPattern.secret_kv?/2`, values pasted into `env:<NAME>` /
  `header:<Name>` slots), compare-and-set writes whose client restart happens
  after the commit, the tool checklist in one row write, the reconnect task
  (subscribed before it asks) and the probe. AT1.
  """

  @behaviour SwarmCode.Daemon.Service.Settings.Handler

  import Ecto.Query, warn: false, only: [from: 2]

  alias SwarmCode.Daemon.Service.Settings.{Kit, Secrets}
  alias SwarmCode.Domain.{MCP, Projects, Repo}
  alias SwarmCode.Domain.MCP.{Client, Server}

  @max_name 64
  @max_entries 64
  @max_args 64
  @max_tools 512
  @max_value 8_192
  @probe_names 64
  @reconnect_ms 35_000
  @probe_ms 65_000
  @env_name ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @header_name ~r/^[A-Za-z0-9-]+$/
  @editable ~w(name transport command args env url headers enabled project_id)

  @doc false
  def actions,
    do:
      ~w(mcp.create mcp.update mcp.set_secret mcp.toggle mcp.set_tools mcp.reconnect mcp.test mcp.delete)

  @doc false
  def views, do: [{"records", "mcp_servers"}, {"record", "mcp_server"}]

  @doc false
  def cache_reads(_action_or_view), do: []

  ## ------------------------------------------------------------ queries

  @doc false
  def query("records", "mcp_servers", params, ctx) do
    project_id = Kit.get(Kit.options(params), "project_id") || project_id(ctx)

    items =
      project_id
      |> servers()
      |> Enum.map(&Kit.record("mcp_server", &1.id, summary(&1)))

    {:ok, Kit.records_body("mcp_server", items, params)}
  end

  def query("record", "mcp_server", params, _ctx) do
    case MCP.get(Kit.get(params, "id") || "") do
      nil -> gone()
      server -> {:ok, record(server)}
    end
  end

  def query(_view, _kind, _params, _ctx), do: Kit.unsupported()

  @doc "The global servers and those of `project_id`: global first, then by name."
  @spec servers(String.t() | nil) :: [Server.t()]
  def servers(project_id) do
    from(s in Server,
      where: is_nil(s.project_id) or s.project_id == ^(project_id || ""),
      order_by: [asc: s.name]
    )
    |> Repo.all()
    |> Enum.sort_by(&{not is_nil(&1.project_id), String.downcase(&1.name || "")})
  end

  @doc "A server's summary fields (a records page row)."
  @spec summary(Server.t()) :: map()
  def summary(%Server{} = server) do
    {status, message} = status(server)
    tools = MCP.tools_of(server.id)

    %{
      "id" => server.id,
      "updated_at" => Kit.iso(server.updated_at),
      "name" => server.name,
      "enabled" => server.enabled == true,
      "project_id" => server.project_id,
      "scope" => if(server.project_id, do: "project", else: "global"),
      "transport" => server.transport,
      "command" => server.command,
      "url" => server.url,
      "status" => status,
      "status_message" => message,
      "slug" => Server.slug(server),
      "tools_total" => length(tools),
      "tools_enabled" => Enum.count(tools, & &1.enabled?)
    }
  end

  @doc "A server's record (the record view): everything, secrets masked."
  @spec record(Server.t()) :: map()
  def record(%Server{} = server) do
    secrets = Secrets.redaction_list(server)

    fields =
      server
      |> summary()
      |> Map.merge(%{
        "args" => server.args || [],
        "env" => Secrets.masked_entries(server.env || %{}),
        "headers" => Secrets.masked_entries(server.headers || %{}),
        "disabled_tools" => Enum.take(server.disabled_tools || [], @max_tools),
        "tools" => server.id |> MCP.tools_of() |> Enum.take(@max_tools) |> Enum.map(&tool/1),
        "output" =>
          server.id
          |> MCP.recent_output()
          |> Enum.take(-20)
          |> Enum.map(&Kit.redact(&1, secrets))
      })

    Kit.record("mcp_server", server.id, fields)
  end

  defp tool(ref) do
    %{
      "name" => ref.tool_name,
      "published_name" => ref.name,
      "description" => ref.description |> to_string() |> String.slice(0, 512),
      "enabled" => ref.enabled? == true,
      "read_only" => ref.read_only? == true
    }
  end

  @doc "The wire status of a server and its (redacted) message."
  @spec status(Server.t()) :: {String.t(), String.t() | nil}
  def status(%Server{} = server) do
    case MCP.status(server.id) do
      :ready ->
        {"ready", nil}

      :connecting ->
        {"connecting", nil}

      {:error, reason} ->
        {"error", Kit.redact(to_string(reason), Secrets.redaction_list(server))}

      _stopped ->
        {"stopped", nil}
    end
  end

  defp project_id(ctx) do
    case Kit.ctx(ctx, :project) do
      %{id: id} -> id
      _ -> nil
    end
  end

  ## ------------------------------------------------------------ commands

  @doc false
  def command(%{action: "mcp.create"} = cmd, _ctx), do: create(cmd)
  def command(%{action: "mcp.update"} = cmd, _ctx), do: update(cmd)
  def command(%{action: "mcp.set_secret"} = cmd, _ctx), do: set_secret(cmd)
  def command(%{action: "mcp.toggle"} = cmd, _ctx), do: toggle(cmd)
  def command(%{action: "mcp.set_tools"} = cmd, _ctx), do: set_tools(cmd)
  def command(%{action: "mcp.reconnect"} = cmd, _ctx), do: reconnect(cmd)
  def command(%{action: "mcp.test"} = cmd, _ctx), do: test(cmd)
  def command(%{action: "mcp.delete"} = cmd, _ctx), do: delete(cmd)
  def command(_cmd, _ctx), do: Kit.unsupported()

  # -- create ---------------------------------------------------------------

  defp create(cmd) do
    attrs = Kit.cmd(cmd, :attributes)

    with {:ok, changes} <- attributes(attrs, cmd, %Server{}, true) do
      cond do
        Map.get(cmd, :dry_run) ->
          changeset = Server.changeset(%Server{}, changes)
          if changeset.valid?, do: Kit.ok(), else: Kit.changeset_error(changeset)

        true ->
          case MCP.create(changes) do
            {:ok, server} ->
              Kit.ok(record: record(server), message: "#{server.name} added")

            {:error, changeset} ->
              Kit.changeset_error(changeset)
          end
      end
    end
  end

  # -- update ---------------------------------------------------------------

  defp update(cmd) do
    id = Kit.get(Kit.cmd(cmd, :target), "id") || ""
    attrs = Kit.cmd(cmd, :attributes)
    expected = Kit.cmd(cmd, :expected)

    with true <- Kit.has?(expected, "fields") || Kit.expected(cmd, "fields"),
         %Server{} = current <- MCP.get(id) || :gone,
         {:ok, _} <- attributes(attrs, cmd, current, false) do
      write(id, cmd, fn fresh ->
        fields = record(fresh)["fields"]

        with :ok <- conflict(Kit.check_fields(expected, fields), fields),
             {:ok, changes} <- attributes(attrs, cmd, fresh, false) do
          {:update, changes, "#{fresh.name} saved"}
        end
      end)
    else
      :gone -> gone()
      other -> other
    end
  end

  # -- set_secret -----------------------------------------------------------

  defp set_secret(cmd) do
    target = Kit.cmd(cmd, :target)
    id = Kit.get(target, "id") || ""
    map = Kit.get(target, "map")
    name = Kit.get(target, "name")
    prefix = if map == "headers", do: "header", else: "env"

    with true <- map in ["env", "headers"] || Kit.error(:invalid, "map: env or headers"),
         true <- (is_binary(name) and name != "") || Kit.error(:invalid, "name the entry"),
         :ok <- entry_name(prefix, name),
         {:ok, expected_key} <- Kit.expected(cmd, "key"),
         {:ok, value} <- one_secret(cmd, "#{prefix}:#{name}") do
      write(id, cmd, fn fresh ->
        entries = Map.get(fresh, String.to_existing_atom(map)) || %{}
        current = Secrets.mask(Map.get(entries, name))

        cond do
          not Kit.same?(expected_key, current) ->
            {:conflict, [Kit.row("#{map}.#{name}", :conflict, current: current)]}

          Map.get(entries, name) == value ->
            :unchanged

          true ->
            {:update, %{String.to_existing_atom(map) => Map.put(entries, name, value)},
             "#{fresh.name}: #{name} saved"}
        end
      end)
    end
  end

  # -- toggle ---------------------------------------------------------------

  defp toggle(cmd) do
    id = Kit.get(Kit.cmd(cmd, :target), "id") || ""
    enabled = Kit.get(Kit.cmd(cmd, :attributes), "enabled")
    expected = Kit.cmd(cmd, :expected)

    with true <- is_boolean(enabled) || Kit.error(:invalid, "enabled: must be true or false"),
         true <- Kit.has?(expected, "fields") || Kit.expected(cmd, "fields") do
      write(id, cmd, fn fresh ->
        fields = %{"enabled" => fresh.enabled == true}

        with :ok <- conflict(Kit.check_fields(expected, fields), fields) do
          if fresh.enabled == enabled,
            do: :unchanged,
            else:
              {:update, %{enabled: enabled}, "#{fresh.name} #{if enabled, do: "on", else: "off"}"}
        end
      end)
    end
  end

  # -- set_tools ------------------------------------------------------------

  defp set_tools(cmd) do
    id = Kit.get(Kit.cmd(cmd, :target), "id") || ""
    tools = Kit.get(Kit.cmd(cmd, :attributes), "tools")

    with true <-
           valid_tools?(tools) ||
             Kit.error(
               :invalid,
               "tools: a map of tool name to true or false (#{@max_tools} at most)"
             ),
         {:ok, expected} <- Kit.expected(cmd, "disabled_tools") do
      outcome =
        Repo.retry(:settings_mcp, fn ->
          Repo.transaction(fn ->
            fresh = Repo.get(Server, id) || Repo.rollback(:not_found)
            current = fresh.disabled_tools || []

            unless match?(%{"$any" => true}, expected) or
                     (is_list(expected) and MapSet.new(expected) == MapSet.new(current)),
                   do: Repo.rollback({:conflict_tools, fresh})

            next = next_disabled(current, tools)

            cond do
              next == current ->
                {:unchanged, fresh}

              Map.get(cmd, :dry_run) ->
                {:unchanged, fresh}

              true ->
                case fresh |> Server.changeset(%{disabled_tools: next}) |> Repo.update() do
                  {:ok, updated} -> {:updated, updated, changed(current, next)}
                  {:error, changeset} -> Repo.rollback({:invalid, changeset})
                end
            end
          end)
        end)

      case outcome do
        {:ok, {:updated, updated, {tool, enabled?}}} ->
          # republish the tool table once (idempotent: the list is already written)
          MCP.set_tool_enabled(updated.id, tool, enabled?)

          Kit.ok(
            record: record(MCP.get(updated.id) || updated),
            message: tools_message(updated, tools)
          )

        {:ok, {:unchanged, fresh}} ->
          Kit.ok(:unchanged, record: record(fresh))

        {:error, {:conflict_tools, fresh}} ->
          Kit.ok(:conflict,
            results: [Kit.row("disabled_tools", :conflict, current: fresh.disabled_tools || [])],
            record: record(fresh),
            message: "#{fresh.name}'s tools changed while you edited them."
          )

        {:error, :not_found} ->
          gone()

        {:error, {:invalid, changeset}} ->
          Kit.changeset_error(changeset)

        {:error, _other} ->
          Kit.busy()
      end
    end
  end

  defp valid_tools?(tools) when is_map(tools) and map_size(tools) in 1..@max_tools,
    do: Enum.all?(tools, fn {name, on?} -> is_binary(name) and is_boolean(on?) end)

  defp valid_tools?(_tools), do: false

  @doc false
  # The final `disabled_tools`: the current order kept, newly disabled tools
  # appended in name order.
  def next_disabled(current, tools) do
    on = for {name, true} <- tools, into: MapSet.new(), do: name
    off = for {name, false} <- tools, name not in current, do: name
    Enum.reject(current, &MapSet.member?(on, &1)) ++ Enum.sort(off)
  end

  defp changed(current, next) do
    case next -- current do
      [tool | _] -> {tool, false}
      [] -> {hd(current -- next), true}
    end
  end

  defp tools_message(server, tools) when map_size(tools) == 1 do
    [{name, on?}] = Map.to_list(tools)
    "#{server.name}: #{name} #{if on?, do: "on", else: "off"}"
  end

  defp tools_message(server, tools) do
    off = Enum.count(tools, fn {_, v} -> v == false end)
    on = map_size(tools) - off
    "#{server.name}: #{on} tools on, #{off} off"
  end

  # -- reconnect ------------------------------------------------------------

  defp reconnect(cmd) do
    case MCP.get(Kit.get(Kit.cmd(cmd, :target), "id") || "") do
      nil ->
        gone()

      %Server{enabled: false} = server ->
        Kit.ok(:rejected, record: record(server), message: "turn it on first")

      %Server{} = server ->
        Kit.task(
          action: "mcp.reconnect",
          key: server.id,
          timeout_ms: @reconnect_ms,
          cancellable?: true,
          kind: :plain,
          run: fn _report -> reconnect_run(server, &MCP.reconnect/1) end,
          summary: & &1,
          redact: Secrets.redaction_list(server)
        )
    end
  end

  @doc false
  # §3.3.8 rule 4: subscribe first, then ask, then wait for the status — a
  # status broadcast while `reconnect` runs is already in the mailbox.
  def reconnect_run(%Server{id: id} = server, reconnect, wait_ms \\ @reconnect_ms - 1_000) do
    :ok = MCP.subscribe()
    reconnect.(id)
    deadline = System.monotonic_time(:millisecond) + wait_ms
    await_status(server, deadline)
  end

  defp await_status(%Server{id: id} = server, deadline) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:mcp_status, ^id, :ready} ->
        tools = MCP.tools_of(id)

        {:ok,
         %{
           "status" => "ready",
           "tools_total" => length(tools),
           "tools_enabled" => Enum.count(tools, & &1.enabled?)
         }}

      {:mcp_status, ^id, {:error, reason}} ->
        {:error, Kit.redact(to_string(reason), Secrets.redaction_list(server))}

      {:mcp_status, ^id, _other} ->
        await_status(server, deadline)
    after
      left -> {:error, "no answer in #{div(@reconnect_ms, 1_000)} s"}
    end
  end

  # -- test -----------------------------------------------------------------

  defp test(cmd) do
    target = Kit.cmd(cmd, :target)
    attrs = Kit.cmd(cmd, :attributes) || %{}
    draft? = Kit.get(target, "draft") == true

    base =
      if draft?,
        do: %Server{},
        else: MCP.get(Kit.get(target, "id") || "")

    with %Server{} = base <- base || :gone,
         {:ok, changes} <- attributes(attrs, cmd, base, draft?),
         changeset = Server.changeset(base, changes),
         true <- changeset.valid? || Kit.changeset_error(changeset) do
      server = %{Ecto.Changeset.apply_changes(changeset) | id: Ecto.UUID.generate()}

      secrets =
        Secrets.redaction_list(server) ++ Enum.map(Kit.cmd(cmd, :secrets) || [], & &1.value)

      run = fn _report ->
        case Client.probe(server) do
          {:ok, tools} ->
            names = tools |> Enum.map(&to_string(&1["name"])) |> Enum.sort()
            {:ok, %{"tools" => Enum.take(names, @probe_names), "count" => length(names)}}

          {:error, reason} ->
            {:error, Kit.redact(to_string(reason), secrets)}
        end
      end

      Kit.task(
        action: "mcp.test",
        key: if(draft?, do: "draft", else: base.id),
        timeout_ms: @probe_ms,
        cancellable?: true,
        kind: :probe,
        run: run,
        summary: & &1,
        redact: Enum.uniq(secrets)
      )
    else
      :gone -> gone()
      other -> other
    end
  end

  # -- delete ---------------------------------------------------------------

  defp delete(cmd) do
    id = Kit.get(Kit.cmd(cmd, :target), "id") || ""

    with {:ok, expected_at} <- Kit.expected(cmd, "updated_at") do
      outcome =
        Repo.retry(:settings_mcp, fn ->
          Repo.transaction(fn ->
            fresh = Repo.get(Server, id) || Repo.rollback(:not_found)

            unless Kit.same?(expected_at, Kit.iso(fresh.updated_at)),
              do: Repo.rollback({:conflict, fresh})

            if Map.get(cmd, :dry_run) do
              {:dry_run, fresh}
            else
              case Repo.delete(fresh) do
                {:ok, _} -> {:deleted, fresh}
                {:error, changeset} -> Repo.rollback({:invalid, changeset})
              end
            end
          end)
        end)

      case outcome do
        {:ok, {:deleted, server}} ->
          tools = length(MCP.tools_of(server.id))
          # what MCP.delete/1 does besides the row, after the commit
          MCP.stop_client(server.id)
          MCP.broadcast()
          Kit.ok(message: "#{server.name} deleted · agents lose its #{tools} tools")

        {:ok, {:dry_run, _}} ->
          Kit.ok()

        {:error, {:conflict, fresh}} ->
          Kit.ok(:conflict,
            results: [Kit.row("updated_at", :conflict, current: Kit.iso(fresh.updated_at))],
            record: record(fresh),
            message: "#{fresh.name} changed since you opened it."
          )

        {:error, :not_found} ->
          Kit.ok(:unchanged, message: "That server is already gone.")

        {:error, {:invalid, changeset}} ->
          Kit.changeset_error(changeset)

        {:error, _other} ->
          Kit.busy()
      end
    end
  end

  ## ------------------------------------------------------------ writes

  # One compare-and-set write of a server row; the client restart (what
  # `MCP.update/2` does besides the row) happens after the commit.
  defp write(id, cmd, decide) do
    outcome =
      Repo.retry(:settings_mcp, fn ->
        Repo.transaction(fn ->
          fresh = Repo.get(Server, id) || Repo.rollback(:not_found)

          case decide.(fresh) do
            {:conflict, rows} ->
              Repo.rollback({:conflict, rows, fresh})

            {:error, _} = error ->
              Repo.rollback({:refused, error})

            :unchanged ->
              {:unchanged, fresh}

            {:update, _changes, _message} when cmd.dry_run == true ->
              {:unchanged, fresh}

            {:update, changes, message} ->
              changeset =
                fresh
                |> Server.changeset(changes)
                |> reject_slug_collision(fresh.id)

              if map_size(changeset.changes) == 0 do
                {:unchanged, fresh}
              else
                case Repo.update(changeset) do
                  {:ok, updated} -> {:updated, updated, message}
                  {:error, changeset} -> Repo.rollback({:invalid, changeset})
                end
              end
          end
        end)
      end)

    case outcome do
      {:ok, {:updated, server, message}} ->
        MCP.stop_client(server.id)
        if server.enabled, do: MCP.start_client(server)
        MCP.broadcast()
        Kit.ok(record: record(server), message: message)

      {:ok, {:unchanged, fresh}} ->
        Kit.ok(:unchanged, record: record(fresh))

      {:error, {:conflict, rows, fresh}} ->
        Kit.ok(:conflict,
          results: rows,
          record: record(fresh),
          message: "#{fresh.name} changed while you edited it."
        )

      {:error, {:refused, error}} ->
        error

      {:error, :not_found} ->
        gone()

      {:error, {:invalid, changeset}} ->
        Kit.changeset_error(changeset)

      {:error, _other} ->
        Kit.busy()
    end
  end

  defp conflict(:ok, _fields), do: :ok

  defp conflict({:conflict, moved}, fields),
    do: {:conflict, Enum.map(moved, &Kit.row(&1, :conflict, current: Map.get(fields, &1)))}

  # the domain's rule (MCP.update/2), checked on the row the transaction reads
  defp reject_slug_collision(%Ecto.Changeset{valid?: false} = changeset, _id), do: changeset

  defp reject_slug_collision(changeset, id) do
    slug = changeset |> Ecto.Changeset.get_field(:name) |> Server.slug()

    case Enum.find(Repo.all(Server), &(&1.id != id and Server.slug(&1) == slug)) do
      nil ->
        changeset

      other ->
        Ecto.Changeset.add_error(
          changeset,
          :name,
          "shares the tool prefix mcp__#{slug}__ with \"#{other.name}\""
        )
    end
  end

  ## ------------------------------------------------------------ attributes

  @doc false
  # The changes of `attrs` against `base` (create: every field; update: only
  # the ones present — `project_id` only when it is in `attrs`, R7), with
  # env/headers merged from the desired lists, `keep` entries and slots.
  def attributes(attrs, cmd, %Server{} = base, create?) when is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    unknown = Map.keys(attrs) -- @editable

    cond do
      unknown != [] ->
        Kit.error(:invalid, "#{hd(unknown)} cannot be set here")

      true ->
        steps = [
          &name/3,
          &transport/3,
          &command_attr/3,
          &args/3,
          &url/3,
          &enabled/3,
          &project/3,
          &kv(&1, &2, &3, "env"),
          &kv(&1, &2, &3, "headers")
        ]

        Enum.reduce_while(steps, {:ok, %{}}, fn step, {:ok, acc} ->
          case step.(attrs, {cmd, base, create?}, acc) do
            {:ok, acc} -> {:cont, {:ok, acc}}
            {:error, _} = error -> {:halt, error}
          end
        end)
    end
  end

  def attributes(_attrs, _cmd, _base, _create?),
    do: Kit.error(:invalid, "attributes must be a map")

  defp name(%{"name" => name}, _env, acc) when is_binary(name) do
    name = String.trim(name)

    if String.length(name) > @max_name,
      do: invalid("name", "should be at most #{@max_name} character(s)"),
      else: {:ok, Map.put(acc, :name, name)}
  end

  defp name(%{"name" => _}, _env, _acc), do: invalid("name", "can't be blank")
  defp name(_attrs, _env, acc), do: {:ok, acc}

  defp transport(%{"transport" => t}, _env, acc) when is_binary(t),
    do: {:ok, Map.put(acc, :transport, t)}

  defp transport(%{"transport" => _}, _env, _acc), do: invalid("transport", "is invalid")
  defp transport(_attrs, _env, acc), do: {:ok, acc}

  defp command_attr(%{"command" => c}, _env, acc) when is_binary(c) or is_nil(c),
    do: {:ok, Map.put(acc, :command, c && String.trim(c))}

  defp command_attr(%{"command" => _}, _env, _acc), do: invalid("command", "must be text")
  defp command_attr(_attrs, _env, acc), do: {:ok, acc}

  defp args(%{"args" => args}, _env, acc) when is_list(args) do
    cond do
      length(args) > @max_args -> invalid("args", "#{@max_args} arguments at most")
      Enum.all?(args, &is_binary/1) -> {:ok, Map.put(acc, :args, args)}
      true -> invalid("args", "every argument is text")
    end
  end

  defp args(%{"args" => _}, _env, _acc), do: invalid("args", "a list of arguments")
  defp args(_attrs, _env, acc), do: {:ok, acc}

  defp url(%{"url" => u}, _env, acc) when is_binary(u) or is_nil(u),
    do: {:ok, Map.put(acc, :url, u && String.trim(u))}

  defp url(%{"url" => _}, _env, _acc), do: invalid("url", "must start with http:// or https://")
  defp url(_attrs, _env, acc), do: {:ok, acc}

  defp enabled(%{"enabled" => e}, _env, acc) when is_boolean(e),
    do: {:ok, Map.put(acc, :enabled, e)}

  defp enabled(%{"enabled" => _}, _env, _acc), do: invalid("enabled", "must be true or false")
  defp enabled(_attrs, _env, acc), do: {:ok, acc}

  defp project(%{"project_id" => nil}, _env, acc), do: {:ok, Map.put(acc, :project_id, nil)}

  defp project(%{"project_id" => id}, _env, acc) when is_binary(id) do
    case Projects.get(id) do
      nil -> invalid("project_id", "no such project")
      _project -> {:ok, Map.put(acc, :project_id, id)}
    end
  rescue
    Ecto.Query.CastError -> invalid("project_id", "no such project")
  end

  defp project(%{"project_id" => _}, _env, _acc), do: invalid("project_id", "no such project")
  defp project(_attrs, _env, acc), do: {:ok, acc}

  defp kv(attrs, {cmd, base, create?}, acc, field) do
    prefix = if field == "headers", do: "header", else: "env"
    stored = Map.get(base, String.to_existing_atom(field)) || %{}
    slots = slot_values(cmd, prefix)

    case Map.fetch(attrs, field) do
      :error when create? or map_size(slots) > 0 ->
        # no list: only the pasted slots (create), or slots added to the stored map
        with {:ok, map} <- merge_entries([], stored, slots, prefix, field, not create?) do
          {:ok,
           if(map == stored and not create?,
             do: acc,
             else: Map.put(acc, String.to_existing_atom(field), map)
           )}
        end

      :error ->
        {:ok, acc}

      {:ok, list} when is_list(list) and length(list) <= @max_entries ->
        with {:ok, map} <- merge_entries(list, stored, slots, prefix, field, false) do
          {:ok, Map.put(acc, String.to_existing_atom(field), map)}
        end

      {:ok, _other} ->
        invalid(field, "a list of at most #{@max_entries} entries")
    end
  end

  # The desired entries: `{name, value}` a shown value, `{name, keep: true}`
  # the stored value, a slot `env:<NAME>` a new secret; a stored name missing
  # from the list is deleted (unless `keep_rest?`).
  defp merge_entries(list, stored, slots, prefix, field, keep_rest?) do
    start = if keep_rest?, do: stored, else: %{}

    result =
      list
      |> Enum.with_index()
      |> Enum.reduce_while({:ok, start, MapSet.new()}, fn {entry, i}, {:ok, map, seen} ->
        name = entry_field(entry, "name")

        cond do
          not is_binary(name) or entry_name(prefix, name) != :ok ->
            {:halt, entry_name_error(prefix, field, i)}

          MapSet.member?(seen, name) ->
            {:halt, invalid("#{field}[#{i}]", "already in the list")}

          Map.has_key?(slots, name) ->
            {:cont, {:ok, Map.put(map, name, slots[name]), MapSet.put(seen, name)}}

          entry_field(entry, "keep") == true ->
            case Map.fetch(stored, name) do
              {:ok, value} -> {:cont, {:ok, Map.put(map, name, value), MapSet.put(seen, name)}}
              :error -> {:halt, invalid("#{field}[#{i}]", "#{name}: paste its value")}
            end

          is_binary(entry_field(entry, "value")) ->
            value = entry_field(entry, "value")

            if byte_size(value) > @max_value or String.contains?(value, ["\n", "\r", <<0>>]),
              do: {:halt, invalid("#{field}[#{i}]", "#{name}: one line of at most 8 192 bytes")},
              else: {:cont, {:ok, Map.put(map, name, value), MapSet.put(seen, name)}}

          true ->
            {:halt, invalid("#{field}[#{i}]", "#{name}: paste its value")}
        end
      end)

    with {:ok, map, seen} <- result do
      # slots whose names the list does not carry are added
      map =
        Enum.reduce(slots, map, fn {name, value}, acc ->
          if MapSet.member?(seen, name), do: acc, else: Map.put(acc, name, value)
        end)

      if map_size(map) > @max_entries,
        do: invalid(field, "#{@max_entries} entries at most"),
        else: {:ok, map}
    end
  end

  defp entry_field(entry, key) when is_map(entry), do: Kit.get(entry, key)
  defp entry_field(_entry, _key), do: nil

  defp entry_name("env", name), do: if(name =~ @env_name, do: :ok, else: :bad)
  defp entry_name("header", name), do: if(name =~ @header_name, do: :ok, else: :bad)

  defp entry_name_error("env", field, i),
    do: invalid("#{field}[#{i}]", "use a variable name: A–Z, 0–9 and _")

  defp entry_name_error("header", field, i), do: invalid("#{field}[#{i}]", "not a header name")

  # `env:<NAME>` / `header:<Name>` slots of the command → name => value
  defp slot_values(cmd, prefix) do
    for %{slot: slot, value: value} <- Kit.cmd(cmd, :secrets) || [],
        is_binary(slot),
        [^prefix, name] <- [String.split(slot, ":", parts: 2)],
        entry_name(prefix, name) == :ok,
        into: %{},
        do: {name, value}
  end

  defp one_secret(cmd, slot) do
    case Kit.cmd(cmd, :secrets) || [] do
      [%{slot: ^slot, value: value}] -> secret_value(value)
      [%{slot: "value", value: value}] -> secret_value(value)
      _ -> Kit.error(:invalid, "paste the value", [Kit.field_error("value", "paste the value")])
    end
  end

  defp secret_value(value) when is_binary(value) do
    cond do
      String.trim(value) == "" -> invalid("value", "paste the value")
      byte_size(value) > @max_value -> invalid("value", "that is too long")
      String.contains?(value, ["\n", "\r", <<0>>]) -> invalid("value", "paste one line")
      true -> {:ok, value}
    end
  end

  defp secret_value(_value), do: invalid("value", "paste the value")

  defp invalid(field, message),
    do: Kit.error(:invalid, "#{field}: #{message}", [Kit.field_error(field, message)])

  ## ------------------------------------------------------------ overview

  @doc "AT1 (§2.1): an enabled server of this page whose client failed."
  @spec attention(map()) :: [map()]
  def attention(ctx) do
    for server <- servers(project_id(ctx)),
        server.enabled,
        {"error", message} <- [status(server)] do
      %{
        id: "AT1",
        severity: "error",
        section: "mcp",
        target: %{"kind" => "mcp_server", "id" => server.id},
        title: "#{server.name} MCP server failed to start",
        reason: message || "the server stopped"
      }
    end
  end

  @doc "The Overview's MCP glance."
  @spec glance(map()) :: map()
  def glance(ctx) do
    servers = servers(project_id(ctx))
    statuses = Enum.map(servers, &elem(status(&1), 0))

    tools =
      servers
      |> Enum.filter(& &1.enabled)
      |> Enum.map(fn s -> Enum.count(MCP.tools_of(s.id), & &1.enabled?) end)
      |> Enum.sum()

    %{
      "mcp" => %{
        "servers" => length(servers),
        "on" => Enum.count(servers, & &1.enabled),
        "ready" => Enum.count(statuses, &(&1 == "ready")),
        "failed" =>
          Enum.count(Enum.zip(servers, statuses), fn {s, st} -> s.enabled and st == "error" end),
        "tools" => tools
      }
    }
  end

  defp gone, do: Kit.error(:not_found, "That MCP server no longer exists.")
end
