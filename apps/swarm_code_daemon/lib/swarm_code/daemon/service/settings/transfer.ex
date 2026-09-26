defmodule SwarmCode.Daemon.Service.Settings.Transfer do
  @moduledoc """
  Settings export and import (pass 74, spec §3.3.7), three tasks:

  - `export` writes the v1 document (`format: "swarmcode-settings"`) with
    mode 0600 through a temporary file in the same directory (created
    exclusively, fsynced, renamed; removed on every failure path — the task
    traps exits so a cancel still runs its `after`). No secret is ever
    written: API keys are `"<secret: set>"`, MCP env/header values too unless
    *include plain MCP values* is on, and a secret-looking one always.
  - `import.preview` reads a file (≤ 1 MiB), refuses one that carries a
    secret, and lists what would change as rows (≤ 2 000); the parsed file
    stays in the task cache for 10 minutes.
  - `import.apply` applies the ticked rows: providers, search, MCP servers and
    pricing first (records matched by name or kind), then the scalars in one
    `values.patch` whose `expected` are the preview's `now` values; terminal
    rows go back to the client.

  A model value travels as `{"provider": name, "model"}` in the file (provider
  ids differ between databases) and is resolved by name when applied.
  """
  @behaviour SwarmCode.Daemon.Service.Settings.Handler

  alias SwarmCode.Daemon.Service.Settings.{Command, Context, Error, Result, TaskSpec, Values}
  alias SwarmCode.Domain.{MCP, Providers, Search}
  alias SwarmCode.Settings.{Entry, Registry, SecretPattern, Validate, WireValue}

  @format "swarmcode-settings"
  @version 1
  @secret "<secret: set>"
  @scopes ~w(global terminal project providers search mcp pricing lsp desktop_keys)
  @max_file 1_048_576
  @max_rows 2_000

  @impl true
  def actions, do: ~w(export import.preview import.apply)

  @impl true
  def views, do: []

  @impl true
  def query(_view, _kind, _params, _ctx), do: {:error, Error.unsupported()}

  @impl true
  def cache_reads("import.apply"), do: [{"import.preview", {:param, "preview_id"}}]
  def cache_reads(_), do: []

  @doc "The scopes of an export, in file order."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  ## ---------------------------------------------------------------- commands

  @impl true
  def command(%Command{action: "export"} = command, %Context{} = ctx) do
    attributes = command.attributes || %{}

    with {:ok, path} <- export_path(command.target, attributes["overwrite"] == true),
         {:ok, scopes} <- requested_scopes(attributes["scopes"]) do
      terminal = terminal_values(attributes["terminal"])
      plain? = attributes["mcp_plain_values"] == true
      run = fn _report -> export_run(path, scopes, terminal, plain?, ctx) end

      spec =
        TaskSpec.new("export", {"export", path}, run,
          target: %{"path" => home_relative(path)},
          summary: & &1
        )

      {:task, spec, %Result{status: :accepted}}
    end
  end

  def command(%Command{action: "import.preview"} = command, %Context{} = ctx) do
    with {:ok, path} <- import_path(command.target) do
      run = fn _report -> preview_run(path, ctx) end

      spec =
        TaskSpec.new("import.preview", {"import.preview", path}, run,
          target: %{"path" => home_relative(path)},
          # The parsed file stays 10 minutes (the purge timer of §3.3.8 rule 7a).
          holds_secrets?: true,
          summary: fn result ->
            %{"counts" => result["counts"], "rows" => length(result["rows"])}
          end
        )

      {:task, spec, %Result{status: :accepted}}
    end
  end

  def command(%Command{action: "import.apply"} = command, %Context{} = ctx) do
    attributes = command.attributes || %{}
    preview_id = attributes["preview_id"]
    ids = attributes["rows"]

    case ctx.task_results[{"import.preview", preview_id}] do
      %{state: "done", result: %{"rows" => rows, "_document" => document}}
      when is_list(ids) and length(ids) <= @max_rows ->
        chosen = MapSet.new(ids)
        run = fn _report -> apply_run(rows, document, chosen, ctx) end

        spec =
          TaskSpec.new("import.apply", {"import.apply", preview_id}, run,
            target: nil,
            summary: fn result -> %{"counts" => result["counts"]} end
          )

        {:task, spec, %Result{status: :accepted}}

      %{state: "done"} ->
        {:error, Error.new(:invalid, "choose the rows to import")}

      _ ->
        {:error, Error.new(:not_found, "that preview is gone; preview the file again")}
    end
  end

  def command(_command, _ctx), do: {:error, Error.unsupported()}

  ## ------------------------------------------------------------------ export

  defp export_path(%{"path" => path}, overwrite?) when is_binary(path) and path != "" do
    path = Path.expand(path)
    dir = Path.dirname(path)

    cond do
      not File.dir?(dir) ->
        {:error, Error.new(:invalid, "the folder does not exist: #{home_relative(dir)}")}

      File.exists?(path) and not overwrite? ->
        {:error,
         Error.new(:invalid, "that file exists; choose another name or allow replacing it")}

      File.dir?(path) ->
        {:error, Error.new(:invalid, "that is a folder; name a file")}

      true ->
        {:ok, path}
    end
  end

  defp export_path(_target, _overwrite?), do: {:error, Error.new(:invalid, "name a file")}

  defp requested_scopes(nil), do: {:ok, @scopes}

  defp requested_scopes(scopes) when is_list(scopes) do
    if scopes != [] and Enum.all?(scopes, &(&1 in @scopes)),
      do: {:ok, Enum.filter(@scopes, &(&1 in scopes))},
      else: {:error, Error.new(:invalid, "choose what to export")}
  end

  defp requested_scopes(_), do: {:error, Error.new(:invalid, "choose what to export")}

  defp terminal_values(%{} = terminal) do
    names = cli_names()
    for {key, value} <- terminal, MapSet.member?(names, key), into: %{}, do: {key, value}
  end

  defp terminal_values(_), do: %{}

  # The cli.json names (`panel`, `theme`): the terminal scope is the file's.
  defp cli_names,
    do: MapSet.new(for(%Entry{storage: {:cli, name}} <- Registry.cli_entries(), do: name))

  defp export_run(path, scopes, terminal, plain?, ctx) do
    Process.flag(:trap_exit, true)
    json = Jason.encode!(document(scopes, terminal, plain?, ctx), pretty: true)

    case write_private(path, json) do
      :ok -> {:ok, %{"path" => home_relative(path), "bytes" => byte_size(json)}}
      {:error, words} -> {:error, words}
    end
  end

  @doc "The v1 export document of `scopes` (never a secret)."
  @spec document([String.t()], map(), boolean(), Context.t()) :: map()
  def document(scopes, terminal, plain?, %Context{} = ctx) do
    row = Values.settings_row()
    names = provider_names()

    body = %{
      "format" => @format,
      "version" => @version,
      "exported_at" => now(),
      "scopes" => scopes
    }

    Enum.reduce(scopes, body, fn scope, acc ->
      case scope do
        "global" -> Map.put(acc, "global", global_values(ctx, names))
        "terminal" -> Map.put(acc, "terminal", terminal)
        "project" -> Map.put(acc, "project", project_values(ctx))
        "providers" -> Map.put(acc, "providers", Enum.map(Providers.list(), &provider_out/1))
        "search" -> Map.put(acc, "search_providers", Enum.map(Search.list(), &search_out/1))
        "mcp" -> Map.put(acc, "mcp_servers", Enum.map(MCP.list(), &mcp_out(&1, plain?)))
        "pricing" -> Map.put(acc, "pricing", (row && row.pricing) || %{})
        "lsp" -> Map.put(acc, "lsp", (row && row.lsp_servers) || %{})
        "desktop_keys" -> Map.put(acc, "desktop_keys", (row && row.keybindings) || %{})
      end
    end)
  end

  # Every global scalar whose global layer is set, except lsp.*, desktop.keys.*
  # and pricing (their own scopes).
  defp global_values(ctx, names) do
    for value <- layered(ctx, global_entries()), into: %{} do
      entry = Registry.fetch!(value["key"])
      {entry.key, to_file(entry, layer_value(value, "global"), names)}
    end
    |> Enum.reject(fn {_key, value} -> value == :unset end)
    |> Map.new()
  end

  defp global_entries do
    for %Entry{} = entry <- Registry.all(),
        Entry.writable?(entry),
        entry.home == :global,
        not String.starts_with?(entry.key, ["lsp.", "desktop.keys."]),
        do: entry
  end

  defp layered(ctx, entries) do
    ctx = %{ctx | conversation: nil}
    %{"values" => values} = Values.body(ctx, entries)
    values
  end

  defp layer_value(value, layer) do
    case Enum.find(value["layers"], &(&1["layer"] == layer)) do
      %{"set" => true, "value" => stored} -> stored
      _ -> :unset
    end
  end

  defp project_values(%Context{project: %{} = project}) do
    %{
      "root" => home_relative(project.root_path),
      "approval_mode" => project.approval_mode,
      "allow" => project.auto_approve_prefixes || []
    }
  end

  defp project_values(_ctx), do: nil

  defp provider_out(p) do
    %{
      "name" => p.name,
      "kind" => p.kind,
      "base_url" => p.base_url,
      "models" => p.models || [],
      "default_model" => p.default_model,
      "fallbacks" => p.fallbacks,
      "effort_levels" => p.effort_levels,
      "model_effort_levels" => p.model_effort_levels || %{},
      "api_key" => if(blank?(p.api_key), do: nil, else: @secret)
    }
  end

  defp search_out(s) do
    %{
      "kind" => s.kind,
      "enabled" => s.enabled,
      "base_url" => s.base_url,
      "position" => s.position,
      "api_key" => if(blank?(s.api_key), do: nil, else: @secret)
    }
  end

  defp mcp_out(server, plain?) do
    %{
      "name" => server.name,
      "transport" => server.transport,
      "command" => server.command,
      "args" => server.args || [],
      "env" => masked_kv(server.env, plain?),
      "url" => server.url,
      "headers" => masked_kv(server.headers, plain?),
      "enabled" => server.enabled,
      "scope" => if(server.project_id, do: "project", else: "global"),
      "disabled_tools" => server.disabled_tools || []
    }
  end

  defp masked_kv(map, plain?) do
    for {name, value} <- map || %{}, into: %{} do
      if plain? and not SecretPattern.secret_kv?(name, value),
        do: {name, value},
        else: {name, @secret}
    end
  end

  ## ------------------------------------------------------------------ import

  defp import_path(%{"path" => path}) when is_binary(path) and path != "",
    do: {:ok, Path.expand(path)}

  defp import_path(_target), do: {:error, Error.new(:invalid, "name a file")}

  defp preview_run(path, ctx) do
    Process.flag(:trap_exit, true)

    with {:ok, document} <- read_document(path),
         :ok <- no_secrets(document) do
      rows = preview_rows(document, ctx)
      {:ok, %{"rows" => rows, "counts" => counts(rows), "_document" => document}}
    end
  end

  @doc "Read and check a settings file: `{:ok, document}` or `{:error, words}`."
  @spec read_document(String.t()) :: {:ok, map()} | {:error, String.t()}
  def read_document(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(path),
         true <- size <= @max_file || {:error, "the file is larger than 1 MiB"},
         {:ok, text} <- File.read(path),
         {:ok, %{} = document} <- Jason.decode(text) do
      case document do
        %{"format" => @format, "version" => @version} ->
          {:ok, document}

        %{"format" => @format, "version" => version} when is_integer(version) and version > 1 ->
          {:error, "made by a newer SwarmCode (version #{version})"}

        _ ->
          {:error, "not a SwarmCode settings file"}
      end
    else
      {:error, words} when is_binary(words) -> {:error, words}
      {:ok, %File.Stat{}} -> {:error, "not a file"}
      {:error, :enoent} -> {:error, "no such file: #{home_relative(path)}"}
      _ -> {:error, "not a SwarmCode settings file"}
    end
  end

  @doc "`:ok`, or the words of the first secret the document carries (§3.11.8)."
  @spec no_secrets(map()) :: :ok | {:error, String.t()}
  def no_secrets(document) do
    fields =
      Enum.flat_map(List.wrap(document["providers"]), fn p ->
        secret_field(p, "api_key", "providers.#{name_of(p)}.api_key")
      end) ++
        Enum.flat_map(List.wrap(document["search_providers"]), fn s ->
          secret_field(s, "api_key", "search_providers.#{name_of(s, "kind")}.api_key")
        end) ++
        Enum.flat_map(List.wrap(document["mcp_servers"]), fn server ->
          for part <- ["env", "headers"],
              {name, value} <- map_or_empty(server[part]),
              value != @secret and SecretPattern.secret_kv?(name, value),
              do: "mcp_servers.#{name_of(server)}.#{part}.#{name}"
        end)

    case fields do
      [] ->
        :ok

      [field | _] ->
        {:error, "the file contains a secret for #{field}; secrets are pasted, not imported"}
    end
  end

  defp secret_field(%{} = record, key, label) do
    case record[key] do
      nil -> []
      "" -> []
      @secret -> []
      _value -> [label]
    end
  end

  defp secret_field(_record, _key, _label), do: []

  defp preview_rows(document, ctx) do
    names = provider_names()
    file_providers = for %{"name" => name} <- List.wrap(document["providers"]), do: name
    # `names` is id → name; a model value names its provider.
    known = MapSet.new(Map.values(names) ++ file_providers)
    values = Map.new(layered(ctx, scalar_entries()), &{&1["key"], &1})

    scalar_rows =
      for {scope, key, after_value} <- scalar_pairs(document) do
        scalar_row(scope, key, after_value, values, names, known)
      end

    rows =
      scalar_rows ++
        terminal_rows(document["terminal"]) ++
        provider_rows(document["providers"]) ++
        search_rows(document["search_providers"]) ++
        mcp_rows(document["mcp_servers"]) ++ pricing_rows(document["pricing"])

    rows
    |> Enum.take(@max_rows)
    |> Enum.with_index(1)
    |> Enum.map(fn {row, i} -> Map.put(row, "id", "r#{i}") end)
  end

  defp scalar_entries do
    for %Entry{} = entry <- Registry.all(),
        Entry.writable?(entry),
        entry.home in [:global, :project],
        do: entry
  end

  defp scalar_pairs(document) do
    global = for {key, value} <- map_or_empty(document["global"]), do: {"global", key, value}
    lsp = for {lang, value} <- map_or_empty(document["lsp"]), do: {"lsp", "lsp." <> lang, value}

    keys =
      for {action, value} <- map_or_empty(document["desktop_keys"]),
          do: {"desktop_keys", "desktop.keys." <> action, value}

    project =
      case document["project"] do
        %{} = p ->
          for {field, key} <- [
                {"approval_mode", "project.approval_mode"},
                {"allow", "project.allow"}
              ],
              Map.has_key?(p, field),
              do: {"project", key, p[field]}

        _ ->
          []
      end

    global ++ lsp ++ keys ++ project
  end

  defp scalar_row(scope, key, after_value, values, names, known) do
    base = %{"scope" => scope, "key_or_record" => key, "after" => after_value, "message" => nil}

    with {:ok, entry} <- Registry.fetch(key),
         true <- Entry.writable?(entry) and entry.home in [:global, :project],
         %{} = value <- values[key] do
      layer = if entry.home == :project, do: "project", else: "global"
      now = to_file(entry, layer_value(value, layer), names)
      now = if now == :unset, do: to_file(entry, value["value"], names), else: now

      case check_value(entry, after_value, known) do
        :ok ->
          status = if WireValue.equal?(now, after_value), do: "same", else: "change"
          Map.merge(base, %{"now" => now, "status" => status})

        {:error, words} ->
          Map.merge(base, %{"now" => now, "status" => "invalid", "message" => words})
      end
    else
      _ ->
        Map.merge(base, %{
          "now" => nil,
          "status" => "invalid",
          "message" => "not a setting this file can set"
        })
    end
  end

  defp check_value(%Entry{type: :model}, %{"provider" => name, "model" => model}, known)
       when is_binary(name) and is_binary(model) do
    if MapSet.member?(known, name), do: :ok, else: {:error, "no provider named #{name}"}
  end

  defp check_value(%Entry{type: :model} = entry, nil, _known), do: Validate.check(entry, nil)
  defp check_value(%Entry{type: :model}, _value, _known), do: {:error, "not a model"}
  defp check_value(entry, value, _known), do: Validate.check(entry, value)

  defp terminal_rows(%{} = terminal) do
    names = cli_names()

    for {key, value} <- terminal do
      if MapSet.member?(names, key),
        do: row("terminal", key, nil, value, "change"),
        else: row("terminal", key, nil, value, "invalid", "not a terminal setting")
    end
  end

  defp terminal_rows(_), do: []

  defp provider_rows(providers) do
    existing = Map.new(Providers.list(), &{&1.name, provider_out(&1)})

    Enum.flat_map(List.wrap(providers), fn
      %{"name" => name} = p when is_binary(name) and name != "" ->
        now = existing[name] && Map.delete(existing[name], "api_key")

        after_value =
          p |> Map.take(Map.keys(provider_out(%Providers.Provider{}))) |> Map.delete("api_key")

        status = if now == after_value, do: "same", else: "change"
        main = row("providers", "provider:" <> name, now, after_value, status)

        if p["api_key"] == @secret and
             (existing[name] == nil or existing[name]["api_key"] == nil),
           do: [main, secret_row("providers", "provider:#{name}.api_key")],
           else: [main]

      other ->
        [row("providers", "provider", nil, other, "invalid", "a provider needs a name")]
    end)
  end

  defp search_rows(rows) do
    existing = Map.new(Search.list(), &{&1.kind, search_out(&1)})
    kinds = Search.engine_kinds() ++ Search.reader_kinds()

    Enum.flat_map(List.wrap(rows), fn
      %{"kind" => kind} = s when is_binary(kind) ->
        if kind in kinds do
          now = existing[kind] && Map.delete(existing[kind], "api_key")

          after_value =
            s |> Map.take(~w(kind enabled base_url position)) |> Map.put_new("kind", kind)

          status = if now == after_value, do: "same", else: "change"
          main = row("search", "search:" <> kind, now, after_value, status)

          if s["api_key"] == @secret and
               (existing[kind] == nil or existing[kind]["api_key"] == nil),
             do: [main, secret_row("search", "search:#{kind}.api_key")],
             else: [main]
        else
          [row("search", "search:" <> kind, nil, s, "invalid", "not a search provider")]
        end

      other ->
        [row("search", "search", nil, other, "invalid", "a search provider needs a kind")]
    end)
  end

  defp mcp_rows(servers) do
    existing = Map.new(MCP.list(), &{&1.name, &1})

    Enum.flat_map(List.wrap(servers), fn
      %{"name" => name} = s when is_binary(name) and name != "" ->
        current = existing[name]
        now = current && mcp_out(current, false)
        after_value = Map.take(s, Map.keys(mcp_out(%MCP.Server{}, false)))
        status = if now == after_value, do: "same", else: "change"

        secrets =
          for part <- ["env", "headers"],
              {key, @secret} <- map_or_empty(s[part]),
              current == nil or not Map.has_key?(saved_kv(current, part), key),
              do: secret_row("mcp", "mcp:#{name}.#{part}.#{key}")

        [row("mcp", "mcp:" <> name, now, after_value, status) | secrets]

      other ->
        [row("mcp", "mcp", nil, other, "invalid", "a server needs a name")]
    end)
  end

  defp saved_kv(server, "env"), do: server.env || %{}
  defp saved_kv(server, "headers"), do: server.headers || %{}

  defp pricing_rows(%{} = pricing) do
    current = (Values.settings_row() || %{pricing: %{}}).pricing || %{}

    for {model, price} <- pricing do
      now = current[model]

      cond do
        not price?(price) ->
          row(
            "pricing",
            "pricing:" <> model,
            now,
            price,
            "invalid",
            "a price needs input and output"
          )

        now == price ->
          row("pricing", "pricing:" <> model, now, price, "same")

        true ->
          row("pricing", "pricing:" <> model, now, price, "change")
      end
    end
  end

  defp pricing_rows(_), do: []

  defp price?(%{"input" => i, "output" => o}) when is_number(i) and is_number(o),
    do: i >= 0 and o >= 0

  defp price?(_), do: false

  defp row(scope, key, now, after_value, status, message \\ nil),
    do: %{
      "scope" => scope,
      "key_or_record" => key,
      "now" => now,
      "after" => after_value,
      "status" => status,
      "message" => message
    }

  defp secret_row(scope, key),
    do: row(scope, key, nil, nil, "secret_skipped", "paste the key after import")

  defp counts(rows), do: Enum.frequencies_by(rows, & &1["status"])

  ## ------------------------------------------------------------------- apply

  defp apply_run(rows, document, chosen, ctx) do
    Process.flag(:trap_exit, true)
    ticked = Enum.filter(rows, &(MapSet.member?(chosen, &1["id"]) and &1["status"] == "change"))
    {records, rest} = Enum.split_with(ticked, &(&1["scope"] in ~w(providers search mcp pricing)))
    {terminal, scalars} = Enum.split_with(rest, &(&1["scope"] == "terminal"))

    record_results = Enum.map(records, &safe_apply(&1, document))
    scalar_results = apply_scalars(scalars, ctx)

    terminal_results =
      Enum.map(terminal, &%{"id" => &1["id"], "status" => "accepted", "message" => nil})

    skipped =
      for row <- rows,
          MapSet.member?(chosen, row["id"]),
          row["status"] != "change",
          do: %{"id" => row["id"], "status" => "skipped", "message" => row["message"]}

    results = record_results ++ scalar_results ++ terminal_results ++ skipped

    {:ok,
     %{
       "rows" => results,
       "counts" => Enum.frequencies_by(results, & &1["status"]),
       "terminal" => Map.new(terminal, &{&1["key_or_record"], &1["after"]})
     }}
  end

  defp safe_apply(row, document) do
    apply_record(row, document)
  rescue
    _ -> %{"id" => row["id"], "status" => "rejected", "message" => "could not be saved"}
  catch
    :exit, _ -> %{"id" => row["id"], "status" => "rejected", "message" => "could not be saved"}
  end

  defp apply_record(%{"scope" => "providers", "after" => attrs} = row, _document) do
    fields =
      Map.take(
        attrs,
        ~w(name kind base_url models default_model fallbacks effort_levels model_effort_levels)
      )

    result =
      case Enum.find(Providers.list(), &(&1.name == attrs["name"])) do
        nil -> Providers.create(fields)
        provider -> Providers.update(provider, fields)
      end

    record_result(row, result)
  end

  # A search provider that needs a key stays off until one is pasted.
  defp apply_record(%{"scope" => "search", "after" => attrs} = row, _document) do
    fields = Map.take(attrs, ~w(enabled base_url position))
    enabling? = fields["enabled"] == true

    case Search.upsert(attrs["kind"], fields) do
      {:error, _changeset} when enabling? ->
        case Search.upsert(attrs["kind"], Map.put(fields, "enabled", false)) do
          {:ok, _} ->
            %{
              "id" => row["id"],
              "status" => "accepted",
              "message" => "paste the key after import, then turn it on"
            }

          other ->
            record_result(row, other)
        end

      result ->
        record_result(row, result)
    end
  end

  defp apply_record(%{"scope" => "mcp", "after" => attrs} = row, _document) do
    current = Enum.find(MCP.list(), &(&1.name == attrs["name"]))
    {env, dropped_env} = keep_secrets(attrs["env"], current && current.env)
    {headers, dropped_headers} = keep_secrets(attrs["headers"], current && current.headers)

    fields =
      attrs
      |> Map.take(~w(name transport command args url enabled disabled_tools))
      |> Map.merge(%{"env" => env, "headers" => headers})

    result =
      case current do
        nil -> MCP.create(fields)
        server -> MCP.update(server, fields)
      end

    dropped = dropped_env ++ dropped_headers

    case record_result(row, result) do
      %{"status" => "accepted"} = ok when dropped != [] ->
        %{ok | "message" => "paste #{Enum.join(dropped, ", ")} after import"}

      other ->
        other
    end
  end

  defp apply_record(%{"scope" => "pricing", "key_or_record" => "pricing:" <> model} = row, _doc) do
    current = (Values.settings_row() || %{pricing: %{}}).pricing || %{}

    record_result(
      row,
      SwarmCode.Domain.Settings.update(%{pricing: Map.put(current, model, row["after"])})
    )
  end

  # `<secret: set>` keeps the saved value of that name, or leaves the entry out.
  defp keep_secrets(values, saved) do
    saved = saved || %{}

    Enum.reduce(map_or_empty(values), {%{}, []}, fn
      {name, @secret}, {acc, dropped} ->
        case Map.fetch(saved, name) do
          {:ok, value} -> {Map.put(acc, name, value), dropped}
          :error -> {acc, dropped ++ [name]}
        end

      {name, value}, {acc, dropped} ->
        {Map.put(acc, name, value), dropped}
    end)
  end

  defp record_result(row, {:ok, _}),
    do: %{"id" => row["id"], "status" => "accepted", "message" => nil}

  defp record_result(row, {:error, %Ecto.Changeset{} = changeset}) do
    message =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
      |> Enum.map_join("; ", fn {field, messages} -> "#{field} #{Enum.join(messages, ", ")}" end)

    %{"id" => row["id"], "status" => "rejected", "message" => message}
  end

  defp record_result(row, _other),
    do: %{"id" => row["id"], "status" => "rejected", "message" => "could not be saved"}

  defp apply_scalars([], _ctx), do: []

  defp apply_scalars(rows, ctx) do
    ids = provider_ids()

    {changes, expected} =
      Enum.reduce(rows, {[], %{}}, fn row, {changes, expected} ->
        entry = Registry.fetch!(row["key_or_record"])

        change = %{
          "key" => entry.key,
          "value" => from_file(entry, row["after"], ids),
          "target" => nil
        }

        {changes ++ [change], Map.put(expected, entry.key, from_file(entry, row["now"], ids))}
      end)

    by_key = Map.new(rows, &{&1["key_or_record"], &1["id"]})

    changes
    |> Enum.chunk_every(Registry.max_patch())
    |> Enum.flat_map(fn chunk ->
      keys = Enum.map(chunk, & &1["key"])

      command = %Command{
        action: "values.patch",
        attributes: %{"changes" => chunk},
        expected: Map.take(expected, keys),
        request_id: ctx.request_id
      }

      case Values.command(command, ctx) do
        {:ok, %Result{results: results}} ->
          for r <- results,
              do: %{
                "id" => by_key[r.target],
                "status" => Atom.to_string(r.status),
                "message" => r.message
              }

        {:error, %Error{message: message}} ->
          for key <- keys,
              do: %{"id" => by_key[key], "status" => "rejected", "message" => message}
      end
    end)
  end

  ## ------------------------------------------------------------------ values

  # A model value goes to the file with its provider's name (ids are local).
  defp to_file(_entry, :unset, _names), do: :unset

  defp to_file(%Entry{type: :model}, %{"provider_id" => id, "model" => model}, names),
    do: %{"provider" => names[id] || id, "model" => model}

  defp to_file(_entry, value, _names), do: value

  defp from_file(%Entry{type: :model}, %{"provider" => name, "model" => model}, ids),
    do: %{"provider_id" => ids[name] || name, "model" => model}

  defp from_file(_entry, value, _ids), do: value

  defp provider_names, do: Map.new(Providers.list(), &{&1.id, &1.name})
  defp provider_ids, do: Map.new(Providers.list(), &{&1.name, &1.id})

  ## ------------------------------------------------------------------ files

  @doc """
  Write `data` to `path` with mode 0600 through a same-directory temporary
  file (exclusive, fsynced, renamed), removing it on every failure path.
  """
  @spec write_private(String.t(), iodata()) :: :ok | {:error, String.t()}
  def write_private(path, data) do
    temp =
      Path.join(
        Path.dirname(path),
        ".#{Path.basename(path)}.#{System.unique_integer([:positive])}.tmp"
      )

    try do
      with {:ok, io} <- File.open(temp, [:write, :binary, :exclusive]),
           :ok <- File.chmod(temp, 0o600),
           :ok <- fill(io, data),
           :ok <- File.rename(temp, path) do
        :ok
      else
        {:error, reason} -> {:error, "could not write the file (#{format_error(reason)})"}
      end
    after
      File.rm(temp)
    end
  end

  defp fill(io, data) do
    with :ok <- IO.binwrite(io, data), do: :file.sync(io)
  after
    File.close(io)
  end

  defp format_error(reason) when is_atom(reason),
    do: reason |> :file.format_error() |> to_string()

  defp format_error(reason), do: inspect(reason)

  ## ---------------------------------------------------------------- helpers

  defp home_relative(nil), do: nil

  defp home_relative(path) do
    home = System.user_home() || ""

    if home != "" and String.starts_with?(path, home <> "/"),
      do: "~" <> String.replace_prefix(path, home, ""),
      else: path
  end

  defp map_or_empty(%{} = map), do: map
  defp map_or_empty(_), do: %{}

  defp name_of(record, key \\ "name")
  defp name_of(%{} = record, key), do: to_string(record[key] || "?")
  defp name_of(_record, _key), do: "?"

  defp blank?(value), do: value in [nil, ""] or (is_binary(value) and String.trim(value) == "")

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
