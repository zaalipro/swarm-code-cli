defmodule SwarmCodeCLI.Release.ConfigCommand do
  @moduledoc """
  `swarmcode config` (pass 74, spec §3.10.3): settings from scripts, dotfiles,
  SSH and CI with the TUI's registry, validators, text parser, service and
  compare-and-set.

  cli.json keys need no database (they work while the desktop app or a
  session runs). Database keys and records boot the foundation only
  (`PersistedSession.with_foundation/2`: log, lease, verified migrations).
  Secrets never come from argv: `config secret … --stdin` reads one line.
  Output never holds a secret.

  Exit codes: 0 done (also unchanged), 1 anything else, 2 usage or an invalid
  value, 3 startup refused, 4 conflict.
  """

  # The daemon is not a compile-time dependency of the terminal client: its
  # structs are built with `struct/2` and matched by `__struct__`.
  @compile {:no_warn_undefined,
            [
              SwarmCode.Daemon.Service.Settings,
              SwarmCode.Daemon.Service.Settings.Headless,
              SwarmCode.Daemon.Service.Settings.Transfer,
              SwarmCode.Daemon.Service.Settings.Values,
              SwarmCode.Domain.Providers
            ]}

  alias SwarmCode.Daemon.Service.Settings
  alias SwarmCode.Daemon.Service.Settings.Headless

  @command SwarmCode.Daemon.Service.Settings.Command
  @result SwarmCode.Daemon.Service.Settings.Result
  @error SwarmCode.Daemon.Service.Settings.Error
  alias SwarmCode.Settings.{CliFile, Entry, RecordKind, Registry, Sections, TextValue}
  alias SwarmCodeCLI.Release.PersistedSession

  @ok 0
  @failed 1
  @usage_code 2
  @refused 3
  @conflict 4

  @usage """
  Usage: swarmcode config COMMAND [ARGS]

    list [SECTION] [--modified] [--json]
    get KEY [--json]
    set KEY VALUE [--project DIR] [--conversation ID|latest] [--expect VALUE]
    reset KEY [--project DIR] [--conversation ID|latest]
    keys [--json]
    path
    records KIND [--project DIR] [--json]
    record get KIND:NAME[.FIELD] [--json]
    record set KIND:NAME.FIELD VALUE [--expect VALUE]
    record add provider --preset NAME [--name N]
    record add mcp_server NAME --stdio CMD [ARGS...] | --http URL
    record delete KIND:NAME [--yes]
    secret KIND:NAME[.SLOT] --stdin [--no-test]
    search enable|disable KIND
    search order KIND,KIND,...
    mcp toggle NAME | mcp reconnect NAME
    export FILE [--no-terminal] [--no-project] [--include-records] [--mcp-plain-values]
    import FILE [--apply]
    doctor [--json]

  VALUE is typed as in Settings: on/off, 30m, 90s, default, null, a,b,c,
  provider/model, #RRGGBB. Secrets are read from stdin, never from arguments.
  Exit codes: 0 done, 1 failed, 2 usage or invalid value, 3 startup refused,
  4 changed elsewhere.
  """

  @stdin_words "Secrets are read from stdin so they never reach your shell history: " <>
                 "swarmcode config secret <KIND:NAME[.SLOT]> --stdin"

  @value_flags ~w(--project --conversation --expect --name --preset --http)
  @bool_flags ~w(--json --modified --stdin --no-test --yes --apply --no-terminal --no-project
                 --include-records --mcp-plain-values)

  @kinds %{
    "provider" => {"providers", "name", "provider"},
    "search_provider" => {"search_providers", "kind", "search"},
    "mcp_server" => {"mcp_servers", "name", "mcp"},
    "pricing_row" => {"pricing_rows", "model", "pricing"}
  }

  @doc "The usage text."
  @spec usage() :: String.t()
  def usage, do: @usage

  @doc """
  Run `swarmcode config ARGS`; returns the exit code. Options (tests):
  `:foundation` (`fun -> {:ok, value} | {:error, failure}`), `:cli_path`,
  `:stdin` (an IO device), `:cwd`.
  """
  @spec run([String.t()], keyword()) :: 0 | 1 | 2 | 3 | 4
  def run(args, opts \\ []) do
    env = %{
      foundation: Keyword.get(opts, :foundation, &PersistedSession.with_foundation(&1)),
      cli_path: Keyword.get_lazy(opts, :cli_path, &SwarmCodeCLI.Release.preferences_path/0),
      stdin: Keyword.get(opts, :stdin, :stdio),
      cwd:
        Keyword.get_lazy(opts, :cwd, fn -> System.get_env("SWARM_PROJECT_ROOT") || File.cwd!() end)
    }

    case parse_flags(args) do
      {:ok, words, flags} -> dispatch(words, flags, env)
      {:error, words} -> usage_error(words)
    end
  rescue
    exception ->
      require Logger
      Logger.error("config failed: #{inspect(exception.__struct__)}")
      err("that did not work; cli.log has the details.")
      @failed
  end

  ## ------------------------------------------------------------------ flags

  defp parse_flags(args), do: parse_flags(args, [], %{})

  defp parse_flags([], words, flags), do: {:ok, Enum.reverse(words), flags}

  defp parse_flags(["--stdio" | rest], words, flags) do
    case rest do
      [command | args] -> {:ok, Enum.reverse(words), Map.put(flags, "--stdio", [command | args])}
      [] -> {:error, "--stdio needs a command."}
    end
  end

  defp parse_flags([flag | rest], words, flags) when flag in @value_flags do
    case rest do
      [value | rest] -> parse_flags(rest, words, Map.put(flags, flag, value))
      [] -> {:error, "#{flag} needs a value."}
    end
  end

  defp parse_flags([flag | rest], words, flags) when flag in @bool_flags,
    do: parse_flags(rest, words, Map.put(flags, flag, true))

  defp parse_flags([flag | rest], words, flags) when flag in ["--help", "-h"],
    do: parse_flags(rest, ["help" | words], flags)

  defp parse_flags(["--" <> _ = flag | _], _words, _flags) when flag != "--",
    do: {:error, "unknown option '#{flag}'."}

  defp parse_flags([word | rest], words, flags), do: parse_flags(rest, [word | words], flags)

  ## --------------------------------------------------------------- dispatch

  defp dispatch([], _flags, _env), do: usage_error("name a command.")

  defp dispatch([word], _flags, _env) when word in ["help", "-h", "--help"] do
    IO.write(@usage)
    @ok
  end

  defp dispatch(["keys"], flags, _env), do: keys(flags)
  defp dispatch(["path"], _flags, env), do: path(env)

  defp dispatch(["list" | section], flags, env) when length(section) <= 1,
    do: list(section, flags, env)

  defp dispatch(["get", key], flags, env), do: get(key, flags, env)
  defp dispatch(["set", key, value], flags, env), do: set(key, {:text, value}, flags, env)

  defp dispatch(["set", key | _], _flags, _env),
    do: usage_error("set #{key} needs one VALUE (quote it).")

  defp dispatch(["reset", key], flags, env), do: set(key, :reset, flags, env)
  defp dispatch(["records", kind], flags, env), do: records(kind, flags, env)
  defp dispatch(["record", "get", ref], flags, env), do: record_get(ref, flags, env)
  defp dispatch(["record", "set", ref, value], flags, env), do: record_set(ref, value, flags, env)
  defp dispatch(["record", "delete", ref], flags, env), do: record_delete(ref, flags, env)
  defp dispatch(["record", "add" | rest], flags, env), do: record_add(rest, flags, env)
  defp dispatch(["secret", ref], flags, env), do: secret(ref, flags, env)

  defp dispatch(["search", verb, kind], _flags, env) when verb in ["enable", "disable"],
    do: search_toggle(kind, verb == "enable", env)

  defp dispatch(["search", "order", order], _flags, env), do: search_order(order, env)
  defp dispatch(["mcp", "toggle", name], _flags, env), do: mcp(name, "mcp.toggle", env)
  defp dispatch(["mcp", "reconnect", name], _flags, env), do: mcp(name, "mcp.reconnect", env)
  defp dispatch(["export", file], flags, env), do: export(file, flags, env)
  defp dispatch(["import", file], flags, env), do: import_file(file, flags, env)
  defp dispatch(["doctor"], flags, env), do: doctor(flags, env)

  defp dispatch([command | _], _flags, _env),
    do: usage_error("unknown config command '#{command}'.")

  ## -------------------------------------------------------------- key/value

  defp keys(flags) do
    entries = for e <- Registry.all(), Entry.scalar?(e), do: e

    if flags["--json"] do
      entries
      |> Enum.map(
        &%{
          "key" => &1.key,
          "section" => Atom.to_string(&1.section),
          "scope" => Atom.to_string(&1.scope),
          "type" => Atom.to_string(&1.type),
          "default" => &1.default
        }
      )
      |> print_json()
    else
      table(
        for e <- entries,
            do: [
              e.key,
              Atom.to_string(e.section),
              Atom.to_string(e.scope),
              Atom.to_string(e.type),
              TextValue.format(e, e.default)
            ]
      )
    end

    @ok
  end

  defp path(env) do
    home = fn path -> if is_binary(path), do: home(path), else: "-" end
    root = env.cwd

    table([
      ["cli.json", home.(env.cli_path)],
      ["log", home.(PersistedSession.log_path(nil))],
      ["project file", home.(Path.join([root, ".swarm_code", "config.json"]))],
      ["MEMORY.md", home.(Path.join([root, ".swarm_code", "MEMORY.md"]))],
      ["instructions", home.(Path.join(root, "AGENTS.md"))]
    ])

    @ok
  end

  defp list(section, flags, env) do
    with {:ok, section} <- section_filter(section) do
      cli = cli_rows(env)

      case with_db(env, fn -> db_rows(env, flags) end) do
        {:ok, {:ok, db}} ->
          print_rows(filter(cli ++ db, section, flags), flags)
          @ok

        {:ok, {:error, code}} ->
          code

        {:error, %{code: :data_lease_held}} ->
          unavailable =
            for e <- Registry.all(), Entry.scalar?(e), e.scope != :cli, do: unavailable_row(e)

          print_rows(filter(cli ++ unavailable, section, flags), flags)
          @ok

        {:error, failure} ->
          PersistedSession.report(failure)
      end
    end
  end

  defp get(text, flags, env) do
    with {:ok, entry} <- resolve(text) do
      if entry.scope == :cli do
        print_rows(Enum.filter(cli_rows(env), &(&1.entry.key == entry.key)), flags)
        @ok
      else
        case with_db(env, fn -> db_rows(env, flags) end) do
          {:ok, {:ok, rows}} ->
            print_rows(Enum.filter(rows, &(&1.entry.key == entry.key)), flags)
            @ok

          {:ok, {:error, code}} ->
            code

          {:error, %{code: :data_lease_held}} ->
            print_rows([unavailable_row(entry)], flags)
            @ok

          {:error, failure} ->
            PersistedSession.report(failure)
        end
      end
    end
  end

  defp set(text, value, flags, env) do
    with :ok <- not_secret_ref(text),
         {:ok, entry} <- resolve(text),
         :ok <- not_secret(entry) do
      if entry.scope == :cli,
        do: set_cli(entry, value, flags, env),
        else: set_db(entry, value, flags, env)
    end
  end

  defp not_secret(%Entry{secret: true}), do: secret_in_argv()
  defp not_secret(_entry), do: :ok

  # A13: a record's secret named as a setting (`provider.DeepSeek.api_key`,
  # `search.tavily.api_key`, `mcp:github.env.GITHUB_TOKEN`) gets the stdin
  # sentence, before the unknown-key message.
  @secret_kinds ~w(provider providers search search_provider mcp mcp_server)
  @secret_fields ~w(api_key key token secret)

  defp not_secret_ref(text) do
    parts = text |> String.replace(":", ".") |> String.split(".")

    cond do
      length(parts) < 3 -> :ok
      hd(parts) not in @secret_kinds -> :ok
      List.last(parts) in @secret_fields -> secret_in_argv()
      Enum.at(parts, 2) in ["env", "headers"] -> secret_in_argv()
      true -> :ok
    end
  end

  defp secret_in_argv do
    IO.puts(:stderr, @stdin_words)
    @usage_code
  end

  defp set_cli(%Entry{storage: {:cli, name}} = entry, value, flags, env) do
    with {:ok, wire} <- cli_value(entry, value),
         {:ok, expect} <- expectation(entry, flags) do
      change = if value == :reset, do: :remove, else: wire
      expectations = %{name => if(expect == :any, do: :any, else: expect)}

      case CliFile.write_changes(env.cli_path, %{name => change}, expectations) do
        {:ok, _snapshot} ->
          IO.puts("#{entry.key} = #{TextValue.format(entry, wire)}")
          @ok

        {:conflict, current} ->
          err("#{entry.key} changed: now #{format_current(entry, current[name])}.")
          @conflict

        {:error, :invalid, messages} ->
          err("#{entry.key}: #{messages |> Map.values() |> List.first()}")
          @usage_code

        {:error, reason} ->
          err(CliFile.words(reason))
          @failed
      end
    end
  end

  defp cli_value(entry, :reset), do: {:ok, TextValue.reset_value(entry)}

  defp cli_value(entry, {:text, text}) do
    case TextValue.parse(entry, text) do
      {:ok, value} -> {:ok, value}
      {:error, message} -> invalid(entry, message)
    end
  end

  defp expectation(entry, flags) do
    case flags["--expect"] do
      nil ->
        {:ok, :any}

      text ->
        case TextValue.parse(entry, text) do
          {:ok, value} -> {:ok, value}
          {:error, message} -> invalid(entry, message)
        end
    end
  end

  defp set_db(entry, value, flags, env) do
    work = fn ->
      with {:ok, ctx, target} <- db_target(entry, flags, env),
           {:ok, wire} <- db_value(entry, value),
           {:ok, expected} <- db_expected(entry, flags) do
        change = %{"key" => entry.key, "value" => wire, "target" => target}

        command =
          struct(@command, %{
            action: "values.patch",
            attributes: %{"changes" => [change]},
            expected: %{entry.key => expected}
          })

        {:done, Settings.command(command, ctx), names()}
      end
    end

    case with_db(env, work) do
      {:ok, {:done, {:ok, %{__struct__: @result} = result}, names}} ->
        value_result(entry, result, names)

      {:ok, {:done, {:error, %{__struct__: @error} = error}, _}} ->
        error_code(entry.key, error)

      {:ok, code} when is_integer(code) ->
        code

      {:error, failure} ->
        refused(failure)
    end
  end

  defp db_value(entry, :reset),
    do: {:ok, SwarmCode.Daemon.Service.Settings.Values.reset_value(entry)}

  defp db_value(entry, {:text, text}), do: parse_db(entry, text)

  defp db_expected(entry, flags) do
    case flags["--expect"] do
      nil -> {:ok, %{"$any" => true}}
      text -> parse_db(entry, text)
    end
  end

  # A model is typed provider/model; the provider is found by its name.
  defp parse_db(entry, text) do
    case TextValue.parse(entry, text) do
      {:ok, {:model_ref, provider, model}} ->
        case Enum.find(
               SwarmCode.Domain.Providers.list(),
               &(String.downcase(&1.name) == String.downcase(provider))
             ) do
          nil -> invalid(entry, "no provider named #{provider}")
          found -> {:ok, %{"provider_id" => found.id, "model" => model}}
        end

      {:ok, value} ->
        {:ok, value}

      {:error, message} ->
        invalid(entry, message)
    end
  end

  defp db_target(%Entry{home: :session}, flags, env) do
    with {:ok, project} <- project(flags, env) do
      case flags["--conversation"] do
        nil ->
          err("this is a conversation's setting; name one with --conversation ID|latest.")
          @usage_code

        which ->
          case Headless.conversation(project, which) do
            {:ok, conversation} ->
              {:ok, Headless.context(project, conversation),
               %{"conversation_id" => conversation.id}}

            {:error, _} ->
              err(
                if which == "latest",
                  do: "No conversation in this project yet.",
                  else: "No such conversation in this project."
              )

              @usage_code
          end
      end
    end
  end

  defp db_target(%Entry{home: :project}, flags, env) do
    with {:ok, project} <- project(flags, env),
         do: {:ok, Headless.context(project, nil), %{"project_id" => project.id}}
  end

  defp db_target(_entry, flags, env) do
    project =
      case project(flags, env, quiet: true) do
        {:ok, project} -> project
        _ -> nil
      end

    {:ok, Headless.context(project, nil), nil}
  end

  defp project(flags, env, opts \\ []) do
    dir = flags["--project"] || env.cwd

    case Headless.project(dir) do
      {:ok, project} ->
        {:ok, project}

      {:error, _} ->
        unless opts[:quiet], do: err("This folder is not a SwarmCode project yet.")
        @usage_code
    end
  end

  defp value_result(entry, %{__struct__: @result, status: status, results: rows}, names) do
    row = List.first(rows) || %{value: nil, current: nil, message: nil}

    case status do
      :accepted ->
        IO.puts("#{entry.key} = #{TextValue.format(entry, row.value, providers: names)}")
        @ok

      :unchanged ->
        IO.puts("#{entry.key} is already #{TextValue.format(entry, row.value, providers: names)}")
        @ok

      :conflict ->
        err(
          "#{entry.key} changed: now #{TextValue.format(entry, row.current, providers: names)}."
        )

        @conflict

      _ ->
        err("#{entry.key}: #{row.message || "was not saved"}")
        @usage_code
    end
  end

  ## ---------------------------------------------------------------- rows

  defp cli_rows(env) do
    snapshot = CliFile.read_all(env.cli_path)

    for %Entry{storage: {:cli, name}} = entry <- Registry.cli_entries() do
      case Map.fetch(snapshot.values, name) do
        {:ok, value} -> %{entry: entry, value: value, layer: "cli", text: nil}
        :error -> %{entry: entry, value: entry.default, layer: "default", text: nil}
      end
    end
  end

  defp db_rows(env, flags) do
    ctx =
      case project(flags, env, quiet: true) do
        {:ok, project} ->
          conversation =
            case flags["--conversation"] &&
                   Headless.conversation(project, flags["--conversation"]) do
              {:ok, conversation} -> conversation
              _ -> nil
            end

          Headless.context(project, conversation)

        _ ->
          Headless.context(nil, nil)
      end

    names = names()

    case Settings.query("values", %{}, ctx) do
      {:ok, %{"values" => values}} ->
        {:ok,
         for value <- values, {:ok, entry} = Registry.fetch(value["key"]) do
           %{
             entry: entry,
             value: value["value"],
             layer: value["winner"],
             text: TextValue.format(entry, value["value"], providers: names)
           }
         end}

      {:error, error} ->
        err(error.message)
        {:error, @failed}
    end
  end

  defp unavailable_row(entry),
    do: %{entry: entry, value: nil, layer: nil, text: "(unavailable while a session is open)"}

  defp filter(rows, section, flags) do
    rows
    |> Enum.filter(&(section == nil or &1.entry.section == section))
    |> Enum.filter(&(flags["--modified"] != true or &1.layer not in ["default", nil]))
  end

  defp print_rows(rows, flags) do
    if flags["--json"] do
      rows
      |> Enum.map(
        &%{
          "key" => &1.entry.key,
          "value" => &1.value,
          "layer" => &1.layer,
          "default" => &1.entry.default,
          "section" => Atom.to_string(&1.entry.section)
        }
      )
      |> print_json()
    else
      table(
        for row <- rows do
          text = row.text || TextValue.format(row.entry, row.value)
          [row.entry.key, text, if(row.layer, do: "(#{row.layer})", else: "")]
        end
      )
    end
  end

  defp section_filter([]), do: {:ok, nil}

  defp section_filter([text]) do
    case Sections.fetch(text) do
      {:ok, section} -> {:ok, section}
      :error -> usage_error("no section '#{text}'.")
    end
  end

  defp resolve(text) do
    case Registry.resolve(text) do
      {:key, key} ->
        entry = Registry.fetch!(key)
        if Entry.scalar?(entry), do: {:ok, entry}, else: usage_error("#{text}: not a setting.")

      _ ->
        usage_error("#{text}: not a setting; 'swarmcode config keys' lists them.")
    end
  end

  ## -------------------------------------------------------------- records

  defp records(kind, flags, env) do
    case with_db(env, fn -> fetch_records(kind, flags, env) end) do
      {:ok, {:ok, items}} ->
        if flags["--json"],
          do: print_json(Enum.map(items, &masked/1)),
          else: table(Enum.map(items, &[&1["id"] || "", summary(&1["fields"])]))

        @ok

      {:ok, code} when is_integer(code) ->
        code

      {:error, failure} ->
        refused(failure)
    end
  end

  defp fetch_records(kind, flags, env) do
    ctx =
      case project(flags, env, quiet: true) do
        {:ok, project} -> Headless.context(project, nil)
        _ -> Headless.context(nil, nil)
      end

    case Settings.query("records", %{"kind" => kind, "page_size" => 200}, ctx) do
      {:ok, %{"items" => items}} ->
        {:ok, items}

      {:error, error} ->
        err(error.message)
        if error.code in [:not_found, :invalid], do: @usage_code, else: @failed
    end
  end

  defp record_get(ref, flags, env) do
    with {:ok, kind, name, field} <- parse_ref(ref) do
      {plural, key, _prefix} = @kinds[kind]

      case with_db(env, fn -> find_record(plural, key, name, flags, env) end) do
        {:ok, {:ok, item}} ->
          fields = masked(item)["fields"]

          cond do
            field == nil and flags["--json"] -> print_json(fields)
            field == nil -> table(Enum.map(fields, fn {k, v} -> [k, show(v)] end))
            flags["--json"] -> print_json(fields[field])
            true -> IO.puts(show(fields[field]))
          end

          @ok

        {:ok, code} when is_integer(code) ->
          code

        {:error, failure} ->
          refused(failure)
      end
    end
  end

  defp find_record(plural, key, name, flags, env) do
    with {:ok, items} <- fetch_records(plural, flags, env) do
      case Enum.find(items, &(get_in(&1, ["fields", key]) == name)) do
        nil ->
          err("no #{plural} entry named #{name}.")
          @usage_code

        item ->
          {:ok, item}
      end
    end
  end

  defp record_set(ref, text, flags, env) do
    with {:ok, kind, name, field} when is_binary(field) <- parse_ref(ref),
         {:ok, record_kind} <- record_kind(kind),
         %{} = spec <-
           RecordKind.field(record_kind, field) || usage_error("#{kind} has no field #{field}."),
         :ok <- if(spec.secret, do: secret_in_argv(), else: :ok),
         {:ok, value} <- parse_field(spec, text, ref) do
      {plural, key, prefix} = @kinds[kind]

      run_record(env, flags, plural, key, name, fn item, ctx ->
        current = get_in(item, ["fields", field])

        expected =
          if flags["--expect"],
            do: elem(parse_field(spec, flags["--expect"], ref), 1),
            else: current

        record_command(
          prefix,
          "update",
          item,
          kind,
          %{field => value},
          %{"fields" => %{field => expected}},
          ctx
        )
      end)
    else
      {:ok, _kind, _name, nil} -> usage_error("name the field: KIND:NAME.FIELD.")
      code when is_integer(code) -> code
    end
  end

  defp record_delete(ref, flags, env) do
    with {:ok, kind, name, nil} <- parse_ref(ref) do
      {plural, key, prefix} = @kinds[kind]

      if flags["--yes"] do
        run_record(env, flags, plural, key, name, fn item, ctx ->
          record_command(
            prefix,
            "delete",
            item,
            kind,
            %{},
            %{"updated_at" => get_in(item, ["fields", "updated_at"])},
            ctx
          )
        end)
      else
        IO.puts("This would delete #{kind} #{name}. Add --yes to delete it.")
        @usage_code
      end
    else
      {:ok, _, _, _} -> usage_error("record delete takes KIND:NAME.")
      code when is_integer(code) -> code
    end
  end

  defp record_add(["provider"], flags, env) do
    attributes =
      %{"preset" => flags["--preset"], "name" => flags["--name"]}
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()

    if attributes["preset"],
      do: plain_command(env, flags, "provider.create", nil, attributes, nil),
      else: usage_error("record add provider needs --preset NAME.")
  end

  defp record_add(["mcp_server", name], flags, env) do
    fields =
      cond do
        is_list(flags["--stdio"]) ->
          [command | args] = flags["--stdio"]
          %{"name" => name, "transport" => "stdio", "command" => command, "args" => args}

        is_binary(flags["--http"]) ->
          %{"name" => name, "transport" => "http", "url" => flags["--http"]}

        true ->
          nil
      end

    if fields,
      do: plain_command(env, flags, "mcp.create", nil, fields, nil),
      else: usage_error("record add mcp_server NAME needs --stdio CMD or --http URL.")
  end

  defp record_add(_rest, _flags, _env),
    do: usage_error("record add takes provider --preset NAME, or mcp_server NAME --stdio|--http.")

  defp secret(ref, flags, env) do
    with {:ok, kind, name, slot} <- parse_ref(ref),
         true <- flags["--stdin"] == true || usage_error("secrets are read with --stdin."),
         {:ok, value} <- read_secret(env) do
      {plural, key, _prefix} = @kinds[kind]

      {action, target_extra, secret_slot} =
        case {kind, slot} do
          {"provider", _} ->
            {"provider.set_key", %{}, "api_key"}

          {"search_provider", _} ->
            {"search.set_key", %{}, "api_key"}

          {"mcp_server", "env." <> var} ->
            {"mcp.set_secret", %{"map" => "env", "name" => var}, "value"}

          {"mcp_server", "headers." <> var} ->
            {"mcp.set_secret", %{"map" => "headers", "name" => var}, "value"}

          _ ->
            {nil, nil, nil}
        end

      if action do
        run_record(env, flags, plural, key, name, fn item, ctx ->
          target = Map.merge(target_of(kind, item), target_extra)

          command =
            struct(@command, %{
              action: action,
              target: target,
              attributes:
                if(action == "mcp.set_secret",
                  do: %{},
                  else: %{"test_first" => flags["--no-test"] != true}
                ),
              expected: %{"key" => get_in(item, ["fields", "api_key"])},
              secrets: [%{slot: secret_slot, value: value}]
            })

          Headless.command(command, ctx)
        end)
      else
        usage_error(
          "name the secret: provider:NAME, search_provider:KIND or mcp_server:NAME.env.VAR."
        )
      end
    end
  end

  defp read_secret(env) do
    case IO.gets(env.stdin, "") do
      line when is_binary(line) ->
        value = String.trim_trailing(line, "\n") |> String.trim_trailing("\r")

        cond do
          byte_size(value) > 8_192 -> usage_error("that is too long to be a key.")
          String.trim(value) == "" -> usage_error("nothing was read from stdin.")
          true -> {:ok, value}
        end

      _ ->
        usage_error("nothing was read from stdin.")
    end
  end

  defp search_toggle(kind, enabled?, env) do
    run_record(env, %{}, "search_providers", "kind", kind, fn item, ctx ->
      record_command(
        "search",
        "update",
        item,
        "search_provider",
        %{"enabled" => enabled?},
        %{"fields" => %{"enabled" => get_in(item, ["fields", "enabled"])}},
        ctx
      )
    end)
  end

  defp search_order(order, env) do
    wanted = String.split(order, ",", trim: true) |> Enum.map(&String.trim/1)

    work = fn ->
      with {:ok, items} <- fetch_records("search_providers", %{}, env) do
        steps(Enum.map(items, &get_in(&1, ["fields", "kind"])), wanted, env)
      end
    end

    case with_db(env, work) do
      {:ok, code} when is_integer(code) -> code
      {:error, failure} -> refused(failure)
    end
  end

  # One `search.move` per step, until the order is the wanted one.
  defp steps(current, wanted, env, guard \\ 64)
  defp steps(_current, _wanted, _env, 0), do: @failed

  defp steps(current, wanted, env, guard) do
    wanted = Enum.filter(wanted, &(&1 in current))
    target = wanted ++ Enum.reject(current, &(&1 in wanted))

    case Enum.find_index(Enum.zip(current, target), fn {a, b} -> a != b end) do
      nil ->
        IO.puts("search order: #{Enum.join(current, ", ")}")
        @ok

      index ->
        kind = Enum.at(target, index)
        from = Enum.find_index(current, &(&1 == kind))

        command =
          struct(@command, %{
            action: "search.move",
            target: %{"kind" => kind},
            attributes: %{"dir" => -1},
            expected: %{"order" => current}
          })

        case Settings.command(command, Headless.context(nil, nil)) do
          {:ok, %{__struct__: @result, status: status}} when status in [:accepted, :unchanged] ->
            moved = current |> List.delete_at(from) |> List.insert_at(from - 1, kind)
            steps(moved, wanted, env, guard - 1)

          other ->
            answer_code(other, "search order")
        end
    end
  end

  defp mcp(name, action, env) do
    run_record(env, %{}, "mcp_servers", "name", name, fn item, ctx ->
      attributes =
        if action == "mcp.toggle",
          do: %{"enabled" => get_in(item, ["fields", "enabled"]) != true},
          else: %{}

      Headless.command(
        struct(@command, %{action: action, target: %{"id" => item["id"]}, attributes: attributes}),
        ctx
      )
    end)
  end

  defp run_record(env, flags, plural, key, name, fun) do
    work = fn ->
      with {:ok, item} <- find_record(plural, key, name, flags, env) do
        ctx =
          case project(flags, env, quiet: true) do
            {:ok, project} -> Headless.context(project, nil)
            _ -> Headless.context(nil, nil)
          end

        {:done, fun.(item, ctx)}
      end
    end

    case with_db(env, work) do
      {:ok, {:done, answer}} -> answer_code(answer, name)
      {:ok, code} when is_integer(code) -> code
      {:error, failure} -> refused(failure)
    end
  end

  defp record_command(prefix, verb, item, kind, attributes, expected, ctx) do
    Headless.command(
      struct(@command, %{
        action: "#{prefix}.#{verb}",
        target: target_of(kind, item),
        attributes: attributes,
        expected: expected
      }),
      ctx
    )
  end

  defp target_of("search_provider", item), do: %{"kind" => get_in(item, ["fields", "kind"])}
  defp target_of(_kind, item), do: %{"id" => item["id"]}

  defp plain_command(env, flags, action, target, attributes, expected) do
    work = fn ->
      ctx =
        case project(flags, env, quiet: true) do
          {:ok, project} -> Headless.context(project, nil)
          _ -> Headless.context(nil, nil)
        end

      {:done,
       Headless.command(
         struct(@command, %{
           action: action,
           target: target,
           attributes: attributes,
           expected: expected
         }),
         ctx
       )}
    end

    case with_db(env, work) do
      {:ok, {:done, answer}} -> answer_code(answer, action)
      {:error, failure} -> refused(failure)
    end
  end

  defp answer_code({:ok, %{__struct__: @result, status: status, message: message}}, name) do
    case status do
      s when s in [:accepted, :unchanged] ->
        IO.puts(message || "#{name}: #{status}")
        @ok

      :conflict ->
        err("#{name} changed: #{message || "reload and try again"}.")
        @conflict

      _ ->
        err("#{name}: #{message || "was not saved"}")
        @usage_code
    end
  end

  defp answer_code({:task, _result, {:ok, value}}, name) do
    IO.puts("#{name}: done#{task_words(value)}")
    @ok
  end

  defp answer_code({:task, _result, {:error, words}}, name) do
    err("#{name}: #{words}")
    @failed
  end

  defp answer_code({:error, %{__struct__: @error} = error}, name), do: error_code(name, error)
  defp answer_code(code, _name) when is_integer(code), do: code

  defp task_words(%{"status" => status}) when is_binary(status), do: " (#{status})"
  defp task_words(_), do: ""

  defp error_code(name, %{__struct__: @error, code: code, message: message}) do
    err("#{name}: #{message}")

    case code do
      :conflict -> @conflict
      c when c in [:invalid, :not_found] -> @usage_code
      _ -> @failed
    end
  end

  defp parse_ref(ref) do
    with [kind, rest] <- String.split(ref, ":", parts: 2),
         true <- Map.has_key?(@kinds, kind) do
      case String.split(rest, ".", parts: 2) do
        [name] -> {:ok, kind, name, nil}
        [name, field] -> {:ok, kind, name, field}
      end
    else
      _ -> usage_error("name a record as KIND:NAME (#{Enum.join(Map.keys(@kinds), ", ")}).")
    end
  end

  defp record_kind(kind) do
    case RecordKind.fetch(kind) do
      {:ok, record_kind} -> {:ok, record_kind}
      _ -> usage_error("#{kind} has no fields here.")
    end
  end

  defp parse_field(field, text, ref) do
    case TextValue.parse(field, text) do
      {:ok, value} ->
        {:ok, value}

      {:error, message} ->
        err("#{ref}: #{message}")
        @usage_code
    end
  end

  ## ------------------------------------------------------ export and import

  defp export(file, flags, env) do
    scopes =
      Settings.Transfer.scopes()
      |> Enum.reject(&(&1 == "terminal" and flags["--no-terminal"]))
      |> Enum.reject(&(&1 == "project" and flags["--no-project"]))
      |> Enum.reject(
        &(&1 in ~w(providers search mcp pricing) and flags["--include-records"] != true)
      )

    terminal = CliFile.read_all(env.cli_path).values

    attributes = %{
      "scopes" => scopes,
      "terminal" => terminal,
      "mcp_plain_values" => flags["--mcp-plain-values"] == true
    }

    work = fn ->
      ctx =
        case project(flags, env, quiet: true) do
          {:ok, project} -> Headless.context(project, nil)
          _ -> Headless.context(nil, nil)
        end

      {:done,
       Headless.command(
         struct(@command, %{
           action: "export",
           target: %{"path" => Path.expand(file, env.cwd)},
           attributes: attributes
         }),
         ctx
       )}
    end

    case with_db(env, work) do
      {:ok, {:done, {:task, _, {:ok, %{"path" => path, "bytes" => bytes}}}}} ->
        IO.puts("Exported to #{path} (#{bytes} bytes).")
        @ok

      {:ok, {:done, answer}} ->
        answer_code(answer, "export")

      {:error, failure} ->
        refused(failure)
    end
  end

  defp import_file(file, flags, env) do
    path = Path.expand(file, env.cwd)

    work = fn ->
      ctx =
        case project(flags, env, quiet: true) do
          {:ok, project} -> Headless.context(project, nil)
          _ -> Headless.context(nil, nil)
        end

      case Headless.command(
             struct(@command, %{action: "import.preview", target: %{"path" => path}}),
             ctx
           ) do
        {:task, _, {:ok, %{"rows" => rows} = preview}} ->
          print_plan(rows)

          if flags["--apply"],
            do: {:applied, apply_import(preview, ctx)},
            else: {:planned, rows}

        other ->
          {:done, other}
      end
    end

    case with_db(env, work) do
      {:ok, {:planned, _rows}} ->
        IO.puts("Nothing was changed; add --apply to import.")
        @ok

      {:ok, {:applied, {:ok, %{"rows" => results, "terminal" => terminal}}}} ->
        cli = apply_terminal(terminal, env)
        failed = Enum.count(results, &(&1["status"] in ["rejected", "conflict"]))

        IO.puts(
          "Imported: #{Enum.count(results, &(&1["status"] == "accepted"))} changed, #{failed} not."
        )

        if failed > 0 or cli != @ok, do: max(cli, @failed), else: @ok

      {:ok, {:applied, other}} ->
        answer_code(other, "import")

      {:ok, {:done, answer}} ->
        answer_code(answer, "import")

      {:error, failure} ->
        refused(failure)
    end
  end

  defp apply_import(preview, ctx) do
    ids = for row <- preview["rows"], row["status"] == "change", do: row["id"]

    ctx = %{
      ctx
      | task_results: %{{"import.preview", "headless"} => %{state: "done", result: preview}}
    }

    case Headless.command(
           struct(@command, %{
             action: "import.apply",
             attributes: %{"preview_id" => "headless", "rows" => ids}
           }),
           ctx
         ) do
      {:task, _, answer} -> answer
      other -> other
    end
  end

  defp print_plan(rows) do
    table(
      for row <- rows do
        [
          row["status"],
          row["scope"],
          row["key_or_record"],
          show(row["now"]) <> " -> " <> show(row["after"])
        ]
      end
    )
  end

  defp apply_terminal(terminal, _env) when terminal == %{}, do: @ok

  defp apply_terminal(terminal, env) do
    case CliFile.write_changes(
           env.cli_path,
           terminal,
           Map.new(terminal, fn {k, _} -> {k, :any} end)
         ) do
      {:ok, _} ->
        @ok

      {:error, :invalid, messages} ->
        err("cli.json: #{messages |> Map.values() |> List.first()}")
        @usage_code

      {:error, reason} ->
        err(CliFile.words(reason))
        @failed

      {:conflict, _} ->
        @conflict
    end
  end

  ## ---------------------------------------------------------------- doctor

  defp doctor(flags, env) do
    work = fn ->
      ctx =
        case project(flags, env, quiet: true) do
          {:ok, project} -> Headless.context(project, nil)
          _ -> Headless.context(nil, nil)
        end

      Headless.command(struct(@command, %{action: "doctor"}), ctx)
    end

    case with_db(env, work) do
      {:ok, {:task, _, {:ok, %{"rows" => rows}}}} ->
        rows = rows ++ client_checks(env)

        if flags["--json"],
          do: print_json(rows),
          else:
            table(Enum.map(rows, &[if(&1["ok"], do: "ok", else: "!!"), &1["id"], &1["message"]]))

        if Enum.all?(rows, & &1["ok"]), do: @ok, else: @failed

      {:ok, answer} ->
        answer_code(answer, "doctor")

      {:error, failure} ->
        refused(failure)
    end
  end

  defp client_checks(env) do
    cli =
      case CliFile.read_all(env.cli_path).status do
        status when status in [:ok, :absent] ->
          %{"id" => "cli.json", "ok" => true, "message" => home(env.cli_path || "-")}

        status ->
          %{"id" => "cli.json", "ok" => false, "message" => CliFile.words(status)}
      end

    log = PersistedSession.log_path(nil)
    [cli, %{"id" => "log", "ok" => true, "message" => home(log)}]
  end

  ## --------------------------------------------------------------- helpers

  defp with_db(env, fun), do: env.foundation.(fun)

  defp names, do: Map.new(SwarmCode.Domain.Providers.list(), &{&1.id, &1.name})

  defp refused(%{code: :data_lease_held}) do
    err(PersistedSession.lease_words(nil, :config))
    @refused
  end

  defp refused(failure), do: PersistedSession.report(failure)

  defp invalid(entry, message) do
    err("#{entry.key}: #{message}")
    @usage_code
  end

  defp usage_error(words) do
    IO.puts(:stderr, "swarmcode: #{words} Run 'swarmcode config help'.")
    @usage_code
  end

  defp err(words), do: IO.puts(:stderr, "swarmcode: " <> words)

  defp format_current(_entry, :absent), do: "not set"
  defp format_current(entry, value), do: TextValue.format(entry, value)

  defp masked(%{"fields" => fields} = item),
    do: %{item | "fields" => Map.new(fields, fn {k, v} -> {k, mask(v)} end)}

  defp masked(item), do: item

  defp mask(%{"set" => set, "hint" => hint}) when map_size(%{"set" => set, "hint" => hint}) == 2,
    do: if(set, do: "set · ends #{hint || "…"}", else: "not set")

  defp mask(value), do: value

  defp summary(fields) when is_map(fields) do
    fields
    |> Map.take(~w(name kind model base_url enabled transport))
    |> Enum.map_join("  ", fn {k, v} -> "#{k}=#{show(v)}" end)
  end

  defp summary(_), do: ""

  defp show(nil), do: "-"
  defp show(value) when is_binary(value), do: value
  defp show(%{"set" => _, "hint" => _} = secret), do: mask(secret)
  defp show(value), do: Jason.encode!(value)

  defp print_json(value), do: IO.puts(Jason.encode!(value, pretty: true))

  defp table(rows) do
    widths =
      rows
      |> Enum.flat_map(&Enum.with_index/1)
      |> Enum.reduce(%{}, fn {cell, i}, acc ->
        Map.update(acc, i, String.length(cell), &max(&1, String.length(cell)))
      end)

    for row <- rows do
      last = length(row) - 1

      row
      |> Enum.with_index()
      |> Enum.map_join("  ", fn {cell, i} ->
        if i == last, do: cell, else: String.pad_trailing(cell, widths[i])
      end)
      |> String.trim_trailing()
      |> IO.puts()
    end

    :ok
  end

  defp home(path) do
    home = System.user_home() || ""

    if home != "" and String.starts_with?(path, home <> "/"),
      do: "~" <> String.replace_prefix(path, home, ""),
      else: path
  end
end
