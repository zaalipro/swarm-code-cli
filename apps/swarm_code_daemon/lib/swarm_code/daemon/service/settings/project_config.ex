defmodule SwarmCode.Daemon.Service.Settings.ProjectConfig do
  @moduledoc """
  A project's `.swarm_code/config.json` in settings (pass 74 §3.5.8): the
  record (parse state with line and column, hooks and profiles as written,
  the ignored top-level keys, denied and unknown keys, and every entry the
  domain's parser drops or bends), and structured writes that keep every
  unknown key in order — read ordered, compare the file fingerprint, modify,
  encode pretty, replace atomically, then `Projects.broadcast/0` so the
  engine's hook cache re-reads. AT7, AT8, AT9.
  """

  @behaviour SwarmCode.Daemon.Service.Settings.Handler

  alias Jason.OrderedObject, as: Obj
  alias SwarmCode.Daemon.Service.Settings.Kit
  alias SwarmCode.Domain.{AtomicFile, Projects}
  alias SwarmCode.Domain.Projects.Workspace

  @max_bytes 1_048_576
  @events ~w(session_start pre_tool_use post_tool_use)
  @top_level ~w(effort swarm_effort model swarm_model)
  @profile_keys ~w(effort swarm_effort model swarm_model)
  @denylist ~w(tavily_api_key default_chat_provider_id default_swarm_provider_id
               default_scheduled_provider_id default_workflow_provider_id
               monthly_budget_usd workflow_budget)
  @known @top_level ++ ["hooks", "profiles"] ++ @denylist
  @invalid "the file is not valid JSON; fix it first (e opens it)"

  @doc false
  def actions,
    do: ~w(project_config.put_hook project_config.delete_hook project_config.move_hook
         project_config.put_profile project_config.delete_profile project_config.remove_key
         project_config.remove_entry)

  @doc false
  def views, do: [{"record", "project_config"}]

  @doc false
  def cache_reads(_action_or_view), do: []

  ## ------------------------------------------------------------ reading

  @doc """
  The file as read: `%{path, exists, text, fingerprint, parse, error, line,
  column, json}` — `json` the ordered object (nil unless `parse == "ok"`).
  """
  @spec read(map()) :: map()
  def read(%{root_path: root}) do
    path = path(root)
    base = %{path: path, exists: false, text: nil, fingerprint: %{"missing" => true}}

    with {:ok, real} <- AtomicFile.target(root, path),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(real) do
      if size > @max_bytes do
        Map.merge(base, %{
          exists: true,
          fingerprint: %{"size" => size, "sha256" => nil},
          parse: "invalid",
          error: "the file is over 1 MiB",
          line: nil,
          column: nil,
          json: nil
        })
      else
        text = File.read!(real)
        decoded(Map.merge(base, %{exists: true, text: text, fingerprint: fingerprint(text)}))
      end
    else
      _ -> Map.merge(base, %{parse: "missing", error: nil, line: nil, column: nil, json: nil})
    end
  end

  defp decoded(%{text: text} = file) do
    case Jason.decode(text, objects: :ordered_objects) do
      {:ok, %Obj{} = json} ->
        Map.merge(file, %{parse: "ok", error: nil, line: nil, column: nil, json: json})

      {:ok, _other} ->
        Map.merge(file, %{
          parse: "invalid",
          error: "line 1, column 1: the file must hold one JSON object",
          line: 1,
          column: 1,
          json: nil
        })

      {:error, %Jason.DecodeError{position: position}} ->
        {line, column} = line_column(text, position)

        reason =
          if position >= byte_size(text), do: "unexpected end", else: "unexpected character"

        Map.merge(file, %{
          parse: "invalid",
          error: "line #{line}, column #{column}: #{reason}",
          line: line,
          column: column,
          json: nil
        })
    end
  end

  defp line_column(text, position) do
    before = binary_part(text, 0, min(position, byte_size(text)))
    lines = String.split(before, "\n")
    {length(lines), String.length(List.last(lines)) + 1}
  end

  defp path(root), do: Path.join([root, ".swarm_code", "config.json"])

  defp fingerprint(text),
    do: %{
      "sha256" => :crypto.hash(:sha256, text) |> Base.encode16(case: :lower),
      "size" => byte_size(text)
    }

  ## ------------------------------------------------------------ the record

  @doc false
  def query("record", "project_config", params, ctx) do
    case project(Kit.get(params, "id") || page_project_id(ctx)) do
      nil -> Kit.error(:not_found, "no such project")
      project -> {:ok, record(project)}
    end
  end

  def query(_view, _kind, _params, _ctx), do: Kit.unsupported()

  defp page_project_id(ctx) do
    case Kit.ctx(ctx, :project) do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp project(nil), do: nil
  defp project(id), do: Projects.get(id)

  @doc "A project's `project_config` record."
  @spec record(map()) :: map()
  def record(project) do
    file = read(project)
    json = file.json

    fields = %{
      "id" => project.id,
      "path" => Kit.tilde(file.path),
      "exists" => file.exists,
      "parse" => file.parse,
      "error" => file.error,
      "line" => file.line,
      "column" => file.column,
      "fingerprint" => file.fingerprint,
      "trusted" => project.trusted_at != nil,
      "hooks" => hooks_of(json),
      "profiles" => profiles_of(json),
      "top_level" => top_level_of(json),
      "denied" => Enum.filter(@denylist, &has?(json, &1)),
      "unknown_keys" => if(json, do: Enum.reject(keys(json), &(&1 in @known)), else: []),
      "ignored_entries" =>
        json |> ignored() |> Enum.take(64) |> Enum.map(&Map.delete(&1, "location"))
    }

    Kit.record("project_config", project.id, fields)
  end

  defp hooks_of(nil), do: Map.new(@events, &{&1, []})

  defp hooks_of(json) do
    hooks = get(json, "hooks")

    Map.new(@events, fn event ->
      list = if match?(%Obj{}, hooks), do: get(hooks, event), else: nil

      rows =
        if is_list(list) do
          for {%Obj{} = hook, i} <- Enum.with_index(list) do
            %{
              "event" => event,
              "index" => i,
              "command" => plain(get(hook, "command")),
              "matcher" => plain(get(hook, "matcher")),
              "timeout_ms" => plain(get(hook, "timeout_ms")),
              "output_cap" => plain(get(hook, "output_cap"))
            }
          end
        else
          []
        end

      {event, rows}
    end)
  end

  defp profiles_of(nil), do: []

  defp profiles_of(json) do
    case get(json, "profiles") do
      %Obj{} = profiles ->
        for {name, %Obj{} = profile} <- profiles.values, profile_name?(name) do
          Map.new(["name" | @profile_keys], fn
            "name" -> {"name", name}
            key -> {key, plain(get(profile, key))}
          end)
        end
        |> Enum.take(64)

      _ ->
        []
    end
  end

  defp top_level_of(nil), do: %{}

  defp top_level_of(json),
    do: for(key <- @top_level, has?(json, key), into: %{}, do: {key, plain(get(json, key))})

  @doc """
  Every entry the domain's parser drops or bends (§3.5.8): `%{"path",
  "reason", "severity", "location"}` — `location` is the key/index path
  `remove_entry` removes (never sent).
  """
  @spec ignored(Obj.t() | nil) :: [map()]
  def ignored(nil), do: []

  def ignored(json) do
    hook_entries(get(json, "hooks"), has?(json, "hooks")) ++
      profile_entries(get(json, "profiles"), has?(json, "profiles"))
  end

  defp hook_entries(_hooks, false), do: []

  defp hook_entries(%Obj{values: values}, true) do
    Enum.flat_map(values, fn {event, list} ->
      cond do
        event not in @events ->
          [entry("hooks.#{event}", "unknown event #{event}", "error", ["hooks", event])]

        not is_list(list) ->
          [entry("hooks.#{event}", "not a hook", "error", ["hooks", event])]

        true ->
          list
          |> Enum.with_index()
          |> Enum.flat_map(fn {hook, i} -> hook_problems(event, hook, i) end)
      end
    end)
  end

  defp hook_entries(_other, true), do: [entry("hooks", "not a hook", "error", ["hooks"])]

  defp hook_problems(event, %Obj{} = hook, i) do
    at = "hooks.#{event}[#{i}]"
    location = ["hooks", event, i]
    command = get(hook, "command")

    if not is_binary(command) or command == "" do
      [entry(at, "no command · dropped", "error", location)]
    else
      matcher(at, location, hook) ++
        number(at, location, hook, "timeout_ms", "timeout", 30_000, 10_000) ++
        number(at, location, hook, "output_cap", "output cap", 16_384, 4_096)
    end
  end

  defp hook_problems(event, _other, i),
    do: [entry("hooks.#{event}[#{i}]", "not a hook", "error", ["hooks", event, i])]

  defp matcher(at, location, hook) do
    case get(hook, "matcher") do
      nil ->
        []

      m when is_binary(m) ->
        case Regex.compile(m) do
          {:ok, _} -> []
          {:error, _} -> [bad_matcher(at, location, m)]
        end

      other ->
        [bad_matcher(at, location, other)]
    end
  end

  defp bad_matcher(at, location, value),
    do:
      entry(
        "#{at}.matcher",
        "matcher #{shown(value)} is not a regular expression · runs for every tool",
        "warning",
        location ++ ["matcher"]
      )

  # the domain's clamp: an integer out of range is clamped, anything else is the default
  defp number(at, location, hook, key, label, max, default) do
    if has?(hook, key) do
      value = get(hook, key)

      used =
        if is_integer(value), do: value |> max(1) |> min(max), else: default

      if is_integer(value) and value == used,
        do: [],
        else: [
          entry(
            "#{at}.#{key}",
            "#{label} #{shown(value)} · used as #{used}",
            "warning",
            location ++ [key]
          )
        ]
    else
      []
    end
  end

  defp profile_entries(_profiles, false), do: []

  defp profile_entries(%Obj{values: values}, true) do
    Enum.flat_map(values, fn {name, profile} ->
      cond do
        not profile_name?(name) or not match?(%Obj{}, profile) ->
          [entry("profiles.#{name}", "not a profile name · dropped", "error", ["profiles", name])]

        true ->
          for {key, _} <- profile.values, key not in @profile_keys do
            entry(
              "profiles.#{name}.#{key}",
              "not a profile key",
              "warning",
              ["profiles", name, key]
            )
          end
      end
    end)
  end

  defp profile_entries(_other, true),
    do: [entry("profiles", "not a profile name · dropped", "error", ["profiles"])]

  defp entry(path, reason, severity, location),
    do: %{"path" => path, "reason" => reason, "severity" => severity, "location" => location}

  defp profile_name?(name),
    do: is_binary(name) and byte_size(name) in 1..32 and Regex.match?(~r/\A[\w-]+\z/, name)

  defp shown(value) when is_binary(value), do: Jason.encode!(value)
  defp shown(value), do: value |> plain() |> Jason.encode!()

  ## ------------------------------------------------------------ exports (S1 Values)

  @doc "The four top-level keys a project file may hold (shown, ignored — D40)."
  @spec read_top_level(map()) :: map()
  def read_top_level(project), do: project |> read() |> Map.get(:json) |> top_level_of()

  @doc "The project's profiles as written (`[%{name, effort, swarm_effort, model, swarm_model}]`)."
  @spec profiles(map()) :: [map()]
  def profiles(project), do: project |> read() |> Map.get(:json) |> profiles_of()

  @doc """
  Removes top-level `keys` (the four ignored ones or denylisted ones) with
  CAS on the file fingerprint; broadcasts after the write.
  `{:ok, %{fingerprint}}`, `{:conflict, current_fingerprint}` or `{:error, message}`.
  """
  @spec remove_top_level(map(), [String.t()], map()) ::
          {:ok, map()} | {:conflict, map()} | {:error, String.t()}
  def remove_top_level(project, keys, expected) do
    case write(project, expected, false, fn json ->
           if Enum.all?(keys, &(&1 in (@top_level ++ @denylist))) do
             present = Enum.filter(keys, &has?(json, &1))

             if present == [],
               do: :unchanged,
               else: {:ok, delete_keys(json, present), "#{Enum.join(present, ", ")} removed"}
           else
             {:error, "only the ignored or denied top-level keys can be removed"}
           end
         end) do
      {:written, file, _message} -> {:ok, %{fingerprint: file.fingerprint}}
      {:unchanged, file} -> {:ok, %{fingerprint: file.fingerprint}}
      {:conflict, current} -> {:conflict, current}
      {:error, %{message: message}} -> {:error, message}
      {:error, message} -> {:error, message}
      {:confirm, _items} -> {:error, "a hook needs confirming"}
      {:rejected, message} -> {:error, message}
      {:dry_run, file} -> {:ok, %{fingerprint: file.fingerprint}}
    end
  end

  ## ------------------------------------------------------------ commands

  @doc false
  def command(%{action: action} = cmd, _ctx) do
    target = Kit.cmd(cmd, :target)

    with %{} = project <- project(Kit.get(target, "project_id")) || gone_project(),
         {:ok, expected} <- Kit.expected(cmd, "fingerprint") do
      confirmed? = Kit.get(Kit.cmd(cmd, :attributes), "confirmed") == true

      case change(action, target, Kit.cmd(cmd, :attributes), project) do
        {:error, _} = error ->
          error

        fun when is_function(fun, 1) ->
          project
          |> write(expected, Map.get(cmd, :dry_run) == true, fun, confirmed?)
          |> answer(project)
      end
    end
  end

  defp gone_project, do: Kit.error(:not_found, "no such project")

  defp answer({:written, _file, message}, project),
    do: Kit.ok(record: record(project), message: message)

  defp answer({:dry_run, _file}, project), do: Kit.ok(record: record(project))
  defp answer({:unchanged, _file}, project), do: Kit.ok(:unchanged, record: record(project))

  defp answer({:conflict, current}, project) do
    Kit.ok(:conflict,
      results: [Kit.row("fingerprint", :conflict, current: current)],
      record: record(project),
      message: ".swarm_code/config.json changed on disk since you opened it."
    )
  end

  defp answer({:confirm, items}, project) do
    Kit.ok(:needs_confirmation,
      confirm: %{kind: "hooks", items: Enum.take(items, 32)},
      record: record(project),
      message: "a new hook command will run in #{project.name}"
    )
  end

  defp answer({:rejected, message}, project),
    do: Kit.ok(:rejected, record: record(project), message: message)

  defp answer({:error, _} = error, _project), do: error

  # -- the changes ----------------------------------------------------------------

  defp change("project_config.put_hook", target, attrs, project) do
    event = Kit.get(target, "event")
    index = Kit.get(target, "index")

    with :ok <- event_ok(event),
         {:ok, fields} <- hook_fields(attrs) do
      fn json ->
        hooks = get(json, "hooks") || Obj.new([])
        list = if is_list(get(hooks, event)), do: get(hooks, event), else: []

        cond do
          not match?(%Obj{}, hooks) ->
            {:error, "hooks is not an object; fix it first"}

          is_integer(index) and (index < 0 or index >= length(list)) ->
            {:error, "that hook is gone"}

          true ->
            old = if is_integer(index), do: Enum.at(list, index)
            hook = merge_object(if(match?(%Obj{}, old), do: old, else: Obj.new([])), fields)

            list =
              if is_integer(index), do: List.replace_at(list, index, hook), else: list ++ [hook]

            old_command = old && match?(%Obj{}, old) && get(old, "command")

            new_command? =
              project.trusted_at != nil and old_command != fields["command"]

            {:ok, put(json, "hooks", put(hooks, event, list)), "#{event} hook saved",
             if(new_command?, do: ["#{event}: #{fields["command"]}"], else: [])}
        end
      end
    end
  end

  defp change("project_config.delete_hook", target, _attrs, _project) do
    event = Kit.get(target, "event")
    index = Kit.get(target, "index")

    with :ok <- event_ok(event), :ok <- index_ok(index) do
      fn json ->
        with {:ok, hooks, list} <- hook_list(json, event, index) do
          {:ok, put(json, "hooks", put(hooks, event, List.delete_at(list, index))),
           "#{event} hook removed"}
        end
      end
    end
  end

  defp change("project_config.move_hook", target, attrs, _project) do
    event = Kit.get(target, "event")
    index = Kit.get(target, "index")
    dir = Kit.get(attrs, "dir")

    with :ok <- event_ok(event),
         :ok <- index_ok(index),
         true <- dir in [-1, 1] || Kit.error(:invalid, "dir: -1 or 1") do
      fn json ->
        with {:ok, hooks, list} <- hook_list(json, event, index) do
          other = index + dir

          if other < 0 or other >= length(list) do
            :unchanged
          else
            swapped =
              list
              |> List.replace_at(index, Enum.at(list, other))
              |> List.replace_at(other, Enum.at(list, index))

            {:ok, put(json, "hooks", put(hooks, event, swapped)),
             "#{event} hook moved #{if dir < 0, do: "up", else: "down"}"}
          end
        end
      end
    end
  end

  defp change("project_config.put_profile", target, attrs, _project) do
    old_name = Kit.get(target, "name")

    with {:ok, name, fields} <- profile_fields(attrs) do
      fn json ->
        profiles = get(json, "profiles") || Obj.new([])

        cond do
          not match?(%Obj{}, profiles) ->
            {:error, "profiles is not an object; fix it first"}

          name != old_name and has?(profiles, name) ->
            Kit.error(:invalid, "name: already used", [Kit.field_error("name", "already used")])

          is_binary(old_name) and not has?(profiles, old_name) ->
            {:error, "that profile is gone"}

          true ->
            old = if is_binary(old_name), do: get(profiles, old_name)
            profile = merge_object(if(match?(%Obj{}, old), do: old, else: Obj.new([])), fields)

            profiles =
              if is_binary(old_name),
                do: rename(profiles, old_name, name, profile),
                else: put(profiles, name, profile)

            {:ok, put(json, "profiles", profiles), "profile #{name} saved"}
        end
      end
    end
  end

  defp change("project_config.delete_profile", target, _attrs, _project) do
    name = Kit.get(target, "name")

    fn json ->
      profiles = get(json, "profiles")

      if match?(%Obj{}, profiles) and has?(profiles, name),
        do:
          {:ok, put(json, "profiles", delete_keys(profiles, [name])), "profile #{name} removed"},
        else: :unchanged
    end
  end

  defp change("project_config.remove_key", target, _attrs, _project) do
    key = Kit.get(target, "key")

    if key in (@top_level ++ @denylist) do
      fn json ->
        if has?(json, key),
          do: {:ok, delete_keys(json, [key]), "#{key} removed"},
          else: :unchanged
      end
    else
      Kit.error(:invalid, "only the ignored or denied top-level keys can be removed here")
    end
  end

  defp change("project_config.remove_entry", target, _attrs, _project) do
    path = Kit.get(target, "path")

    fn json ->
      case Enum.find(ignored(json), &(&1["path"] == path)) do
        nil -> {:error, "#{path} is not an ignored entry"}
        %{"location" => location} -> {:ok, remove_at(json, location), "#{path} removed"}
      end
    end
  end

  defp change(_action, _target, _attrs, _project), do: Kit.unsupported()

  defp event_ok(event) when event in @events, do: :ok

  defp event_ok(_event),
    do: Kit.error(:invalid, "event: session_start, pre_tool_use or post_tool_use")

  defp index_ok(index) when is_integer(index) and index >= 0, do: :ok
  defp index_ok(_index), do: Kit.error(:invalid, "index: which hook")

  defp hook_list(json, event, index) do
    hooks = get(json, "hooks")
    list = if match?(%Obj{}, hooks), do: get(hooks, event)

    if is_list(list) and index < length(list),
      do: {:ok, hooks, list},
      else: {:error, "that hook is gone"}
  end

  defp hook_fields(attrs) do
    command = attrs |> Kit.get("command") |> to_string_or_nil()
    matcher = attrs |> Kit.get("matcher") |> to_string_or_nil()
    timeout = Kit.get(attrs, "timeout_ms")
    cap = Kit.get(attrs, "output_cap")

    errors =
      [
        {"command", if(command in [nil, ""], do: "can't be blank")},
        {"matcher", matcher_error(matcher)},
        {"timeout_ms", range_error(timeout, 30_000)},
        {"output_cap", range_error(cap, 16_384)}
      ]
      |> Enum.reject(fn {_, message} -> is_nil(message) end)
      |> Enum.map(fn {field, message} -> Kit.field_error(field, message) end)

    case errors do
      [] ->
        {:ok,
         %{
           "command" => command,
           "matcher" => if(matcher == "", do: nil, else: matcher),
           "timeout_ms" => timeout,
           "output_cap" => cap
         }}

      [%{target: t, message: m} | _] ->
        Kit.error(:invalid, "#{t}: #{m}", errors)
    end
  end

  defp to_string_or_nil(nil), do: nil
  defp to_string_or_nil(value) when is_binary(value), do: String.trim(value)
  defp to_string_or_nil(value), do: to_string(value)

  defp matcher_error(nil), do: nil
  defp matcher_error(""), do: nil

  defp matcher_error(matcher) do
    case Regex.compile(matcher) do
      {:ok, _} -> nil
      {:error, {reason, _at}} -> "not a valid regular expression: #{reason}"
    end
  end

  defp range_error(nil, _max), do: nil
  defp range_error(n, max) when is_integer(n) and n >= 1 and n <= max, do: nil
  defp range_error(_n, max), do: "must be between 1 and #{max}"

  defp profile_fields(attrs) do
    name = attrs |> Kit.get("name") |> to_string_or_nil()

    errors =
      [
        {"name",
         cond do
           not profile_name?(name || "") -> "1 to 32 letters, digits, _ or -"
           true -> nil
         end},
        {"effort", effort_error(Kit.get(attrs, "effort"))},
        {"swarm_effort", effort_error(Kit.get(attrs, "swarm_effort"))},
        {"model", string_error(Kit.get(attrs, "model"))},
        {"swarm_model", string_error(Kit.get(attrs, "swarm_model"))}
      ]
      |> Enum.reject(fn {_, message} -> is_nil(message) end)
      |> Enum.map(fn {field, message} -> Kit.field_error(field, message) end)

    case errors do
      [] ->
        {:ok, name, Map.new(@profile_keys, &{&1, blank_nil(Kit.get(attrs, &1))})}

      [%{target: t, message: m} | _] ->
        Kit.error(:invalid, "#{t}: #{m}", errors)
    end
  end

  defp effort_error(nil), do: nil
  defp effort_error(""), do: nil

  defp effort_error(value) when is_binary(value),
    do: if(value =~ ~r/^[a-z0-9_-]{1,24}$/, do: nil, else: "has invalid format")

  defp effort_error(_value), do: "has invalid format"

  defp string_error(nil), do: nil
  defp string_error(value) when is_binary(value) and byte_size(value) <= 256, do: nil
  defp string_error(_value), do: "has invalid format"

  defp blank_nil(""), do: nil
  defp blank_nil(value), do: value

  ## ------------------------------------------------------------ the write

  # read ordered → compare the fingerprint → change → encode pretty →
  # replace atomically (the fingerprint re-checked in the same call) →
  # broadcast (outside any transaction)
  defp write(project, expected, dry_run?, fun, confirmed? \\ true) do
    file = read(project)

    cond do
      not Kit.same?(expected, file.fingerprint) ->
        {:conflict, file.fingerprint}

      file.parse == "invalid" ->
        {:rejected, @invalid}

      true ->
        json = file.json || Obj.new([])

        case fun.(json) do
          :unchanged ->
            {:unchanged, file}

          {:error, message} when is_binary(message) ->
            {:rejected, message}

          {:error, _} = error ->
            error

          {:ok, new_json, message} ->
            commit(project, file, new_json, message, dry_run?)

          {:ok, new_json, message, []} ->
            commit(project, file, new_json, message, dry_run?)

          {:ok, _new_json, _message, items} when not confirmed? ->
            {:confirm, items}

          {:ok, new_json, message, _items} ->
            commit(project, file, new_json, message, dry_run?)
        end
    end
  end

  defp commit(_project, file, _json, _message, true), do: {:dry_run, file}

  defp commit(project, file, json, message, false) do
    root = project.root_path
    text = Jason.encode!(json, pretty: true) <> "\n"

    if file.exists and text == file.text do
      {:unchanged, file}
    else
      unless file.exists, do: Workspace.ensure!(root)

      result =
        if file.exists do
          AtomicFile.update(root, file.path, fn current ->
            if fingerprint(current) == file.fingerprint,
              do: {:ok, text},
              else: {:error, "changed"}
          end)
        else
          if File.exists?(file.path),
            do: {:error, "changed"},
            else: AtomicFile.replace(root, file.path, text)
        end

      case result do
        :ok ->
          Projects.broadcast()
          {:written, %{file | text: text, fingerprint: fingerprint(text)}, message}

        {:error, reason} when reason in ["changed", :enoent] ->
          {:conflict, read(project).fingerprint}

        {:error, reason} ->
          Kit.error(:invalid, "Couldn't save config.json: #{AtomicFile.format_error(reason)}")
      end
    end
  end

  ## ------------------------------------------------------------ ordered objects

  defp get(%Obj{values: values}, key) do
    case List.keyfind(values, key, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp get(_other, _key), do: nil

  defp has?(%Obj{values: values}, key), do: List.keymember?(values, key, 0)
  defp has?(_other, _key), do: false

  defp keys(%Obj{values: values}), do: Enum.map(values, &elem(&1, 0))

  # replace in place, or append at the end
  defp put(%Obj{values: values} = obj, key, value) do
    if List.keymember?(values, key, 0),
      do: %{obj | values: List.keyreplace(values, key, 0, {key, value})},
      else: %{obj | values: values ++ [{key, value}]}
  end

  defp delete_keys(%Obj{values: values} = obj, keys),
    do: %{obj | values: Enum.reject(values, fn {k, _} -> k in keys end)}

  defp rename(%Obj{values: values} = obj, old, new, value),
    do: %{
      obj
      | values: Enum.map(values, fn {k, v} -> if k == old, do: {new, value}, else: {k, v} end)
    }

  # set the known fields of an object in place (nil drops the key), unknown keys kept
  defp merge_object(%Obj{} = obj, fields) do
    Enum.reduce(fields, obj, fn
      {key, nil}, acc -> delete_keys(acc, [key])
      {key, value}, acc -> put(acc, key, value)
    end)
  end

  defp remove_at(%Obj{} = obj, [key]), do: delete_keys(obj, [key])

  defp remove_at(%Obj{} = obj, [key | rest]),
    do: put(obj, key, remove_at(get(obj, key), rest))

  defp remove_at(list, [index]) when is_list(list) and is_integer(index),
    do: List.delete_at(list, index)

  defp remove_at(list, [index | rest]) when is_list(list) and is_integer(index),
    do: List.replace_at(list, index, remove_at(Enum.at(list, index), rest))

  defp remove_at(other, _location), do: other

  # an ordered object (and everything inside it) as plain maps and lists
  defp plain(%Obj{values: values}), do: Map.new(values, fn {k, v} -> {k, plain(v)} end)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(value), do: value

  ## ------------------------------------------------------------ attention

  @doc "AT7, AT8, AT9 (§2.1) for the page's project."
  @spec attention(map()) :: [map()]
  def attention(ctx) do
    case project(page_project_id(ctx)) do
      nil -> []
      project -> project_attention(project)
    end
  end

  defp project_attention(project) do
    file = read(project)
    target = %{"kind" => "project_config", "id" => project.id}

    case file.parse do
      "invalid" ->
        [
          %{
            id: "AT7",
            severity: "error",
            section: "project_file",
            target: target,
            title: ".swarm_code/config.json is not valid JSON",
            reason:
              if(file.line, do: "line #{file.line}, column #{file.column}", else: file.error)
          }
        ]

      "ok" ->
        json = file.json

        items =
          Enum.filter(@top_level, &has?(json, &1)) ++
            Enum.filter(@denylist, &has?(json, &1)) ++
            Enum.map(ignored(json), & &1["path"])

        at8 =
          if items == [],
            do: [],
            else: [
              %{
                id: "AT8",
                severity: "warning",
                section: "project_file",
                target: target,
                title: "#{project.name}'s project file has entries SwarmCode ignores",
                reason: listed(items)
              }
            ]

        hooks? = json |> hooks_of() |> Map.values() |> Enum.any?(&(&1 != []))

        at9 =
          if hooks? and project.trusted_at == nil,
            do: [
              %{
                id: "AT9",
                severity: "warning",
                section: "approvals",
                target: %{"key" => "project.trusted"},
                title: "Hooks will not run until you trust #{project.name}",
                reason: "a hook is a shell command from the project"
              }
            ],
            else: []

        at8 ++ at9

      _missing ->
        []
    end
  end

  defp listed(items) when length(items) <= 3, do: Enum.join(items, ", ")
  defp listed(items), do: Enum.join(Enum.take(items, 3), ", ") <> " +#{length(items) - 3}"
end
