defmodule SwarmCodeCLI.UI.Settings.Sections.ProjectFile do
  @moduledoc """
  pass74 U3-8 (spec §2.11, sketch §4.15, D14, D15): the project's
  `.swarm_code/config.json`, for the page's project. The header says the
  path and whether it was read (`✓ read`, `✗ not valid JSON (line L, column
  C)`, `no file yet`). Then the keys SwarmCode ignores (the four top-level
  keys, D15) and the keys a project file may not set, each with `x remove`;
  the hooks table (`event · matcher · command · timeout`; `a` adds, Enter
  edits, `x` deletes, `J`/`K` order; a new or changed command in a trusted
  project asks first, D14); the entries the domain drops or bends when it
  reads the file (`ignored entries`, `x remove`); the profiles table. `e`
  edits the whole file in the editor: the service checks the fingerprint and
  asks before hooks the edit adds start running.
  """

  use SwarmCodeCLI.UI.Settings.Section, id: :project_file

  alias SwarmCodeCLI.UI.Settings.{Confirm, Page, Picker, Row}
  alias SwarmCodeCLI.UI.Settings.Editors

  @events ~w[session_start pre_tool_use post_tool_use]

  @impl true
  def loads(ctx) do
    case project_id(ctx) do
      nil -> []
      id -> [{:record, "project_config", id}, {:file, ref(id)}]
    end
  end

  @impl true
  def rows(ctx) do
    case {project_id(ctx), config(ctx)} do
      {nil, _} ->
        [
          Row.info(
            "no-project",
            "There is no project in this session. Approvals & trust picks one."
          )
        ]

      {_id, nil} ->
        [Row.info("loading", "…", role: :text_faint)]

      {id, config} ->
        [header(config, ctx)] ++
          ignored_keys(config, id) ++
          hooks(config, ctx, id) ++
          ignored_entries(config, id) ++ profiles(config, id)
    end
  end

  @impl true
  def title(ctx) do
    case config(ctx) do
      nil -> "Project file"
      config -> "Project file · #{get(config, :path) || ".swarm_code/config.json"}"
    end
  end

  @impl true
  def attention(_ctx), do: []

  # --------------------------------------------------------------- actions

  @impl true
  def act(ctx, %Row{target: {:remove_key, key}}, :delete),
    do: [command(ctx, "project_config.remove_key", %{"key" => key}, %{}, "Removed #{key}")]

  def act(ctx, %Row{target: {:entry, path}}, :delete),
    do: [command(ctx, "project_config.remove_entry", %{"path" => path}, %{}, "Removed #{path}")]

  def act(ctx, %Row{target: {:hook, event, index}} = row, verb) do
    case verb do
      :delete ->
        [
          {:confirm,
           %Confirm{
             id: "delete-hook",
             title: "Delete this hook?",
             lines: [Enum.map_join(row.columns || [], "  ", &elem(&1, 0))],
             safe: "Keep it",
             danger: "D  Delete",
             letter: "D",
             opener: row.id
           },
           then: [
             command(
               ctx,
               "project_config.delete_hook",
               %{"event" => event, "index" => index},
               %{},
               "Deleted the hook"
             )
           ]}
        ]

      :move_up ->
        [
          command(
            ctx,
            "project_config.move_hook",
            %{"event" => event, "index" => index},
            %{"dir" => -1},
            "Moved the hook up"
          )
        ]

      :move_down ->
        [
          command(
            ctx,
            "project_config.move_hook",
            %{"event" => event, "index" => index},
            %{"dir" => 1},
            "Moved the hook down"
          )
        ]

      v when v in [:open, :enter, :open_row] ->
        [{:open, %Page{section: :project_file, record: {"hook", "#{event}:#{index}"}}}]

      :add ->
        new_hook(row)

      _ ->
        :default
    end
  end

  def act(ctx, %Row{target: {:profile, name}}, :delete),
    do: [
      command(
        ctx,
        "project_config.delete_profile",
        %{"name" => name},
        %{},
        "Deleted profile #{name}"
      )
    ]

  def act(ctx, _row, verb) when verb in [:edit_external, :external] do
    external_edit(ctx)
  end

  def act(_ctx, row, :add), do: new_hook(row)

  def act(ctx, _row, :restart), do: Enum.map(loads(ctx), &{:load, &1})

  def act(_ctx, %Row{target: {:section, id}}, verb)
      when verb in [:open, :enter, :open_row, :goto],
      do: [{:section, id}]

  def act(_ctx, _row, _verb), do: :default

  defp new_hook(row) do
    [
      {:picker,
       %Picker{
         id: "hook-event",
         title: "When does the new hook run?",
         options: Enum.map(@events, &%{value: &1, label: &1, hint: event_hint(&1)}),
         current: "post_tool_use",
         on_pick: {:section, :project_file, :new_hook},
         opener: row && row.id
       }}
    ]
  end

  @doc false
  @impl true
  def picked(_ctx, :new_hook, event) when event in @events,
    do: [{:open, %Page{section: :project_file, record: {"hook", "new:" <> event}}}]

  def picked(_ctx, _tag, _value), do: []

  defp event_hint("session_start"), do: "once, when a session starts"
  defp event_hint("pre_tool_use"), do: "before each tool call"
  defp event_hint("post_tool_use"), do: "after each tool call"

  # ------------------------------------------------------ the hook's page

  @impl true
  def record_rows(ctx, "hook", id) do
    case config(ctx) do
      nil ->
        [Row.info("loading", "…", role: :text_faint)]

      config ->
        hook = find_hook(config, id)
        event = hook_event(id, hook)
        field_id = fn name -> "fld:hook:#{id}:#{name}" end

        [
          %Row{
            id: field_id.("event"),
            kind: :field,
            label: "Event",
            value: [{event, :text_primary}],
            state: :readonly,
            target: {:hook_field, id, "event"}
          },
          %Row{
            id: field_id.("command"),
            kind: :field,
            label: "Command",
            value: [{get(hook, :command) || "", :text_primary}],
            lines: [[{"a new or changed command asks first in a trusted project", :text_faint}]],
            editor: {Editors.Text, %{value: get(hook, :command) || "", max: 4_096}},
            target: {:hook_field, id, "command"}
          },
          %Row{
            id: field_id.("matcher"),
            kind: :field,
            label: "Matcher",
            value: matcher_value(get(hook, :matcher)),
            lines: [[{"a regular expression over tool names; blank = every tool", :text_faint}]],
            editor: {Editors.Text, %{value: get(hook, :matcher) || "", nullable: true}},
            target: {:hook_field, id, "matcher"}
          },
          %Row{
            id: field_id.("timeout_ms"),
            kind: :field,
            label: "Timeout",
            value: [{timeout_words(get(hook, :timeout_ms)), :text_primary}],
            editor:
              {Editors.Number,
               %{value: get(hook, :timeout_ms) || 10_000, min: 1, max: 30_000, unit: :ms}},
            target: {:hook_field, id, "timeout_ms"}
          },
          %Row{
            id: field_id.("output_cap"),
            kind: :field,
            label: "Output cap",
            value: [{"#{get(hook, :output_cap) || 4_096} bytes", :text_primary}],
            editor:
              {Editors.Number, %{value: get(hook, :output_cap) || 4_096, min: 1, max: 16_384}},
            target: {:hook_field, id, "output_cap"}
          }
        ]
    end
  end

  def record_rows(_ctx, _kind, _id), do: []

  @impl true
  def commit(ctx, %Row{target: {:hook_field, id, "matcher"}}, value) when is_binary(value) do
    case Regex.compile(value) do
      {:ok, _} -> put_hook(ctx, id, %{"matcher" => blank_nil(value)})
      {:error, {reason, _at}} -> [{:toast, "not a valid regular expression: #{reason}", :error}]
    end
  end

  def commit(ctx, %Row{target: {:hook_field, id, "command"}}, value) when is_binary(value) do
    if String.trim(value) == "",
      do: [{:toast, "can't be blank", :error}],
      else: put_hook(ctx, id, %{"command" => value})
  end

  def commit(ctx, %Row{target: {:hook_field, id, field}}, value) when is_integer(value),
    do: put_hook(ctx, id, %{field => value})

  def commit(ctx, %Row{target: {:hook_field, id, "matcher"}}, nil),
    do: put_hook(ctx, id, %{"matcher" => nil})

  def commit(_ctx, _row, _value), do: :default

  @doc """
  The `project_config.put_hook` for a changed field of hook `id` (`"new:<event>"`
  or `"<event>:<index>"`): the hook's other fields as they are, and in a trusted
  project a new or changed command asks first (D14), then writes with
  `confirmed: true`.
  """
  @spec put_hook(map(), String.t(), map()) :: [term()]
  def put_hook(ctx, id, changes) do
    config = config(ctx) || %{}
    hook = find_hook(config, id)
    event = hook_event(id, hook)

    index =
      case {id, hook} do
        {_, nil} -> nil
        {_, hook} -> get(hook, :index) || id |> String.split(":") |> List.last() |> to_int()
      end

    attrs =
      Map.merge(
        %{
          "command" => get(hook, :command),
          "matcher" => get(hook, :matcher),
          "timeout_ms" => get(hook, :timeout_ms) || 10_000,
          "output_cap" => get(hook, :output_cap) || 4_096
        },
        changes
      )

    target = %{"event" => event, "index" => index}
    write = command(ctx, "project_config.put_hook", target, attrs, "Saved the hook")
    changed? = Map.has_key?(changes, "command") and changes["command"] != get(hook, :command)

    cond do
      not is_binary(attrs["command"]) or attrs["command"] == "" ->
        [{:toast, "type the hook's command first", :warning}]

      changed? ->
        confirmed =
          command(
            ctx,
            "project_config.put_hook",
            target,
            Map.put(attrs, "confirmed", true),
            "Saved the hook"
          )

        case hook_confirm(config, project_name(ctx), event, attrs, [confirmed]) do
          nil -> [write]
          confirm -> [confirm]
        end

      true ->
        [write]
    end
  end

  @doc """
  The answer to a `file.save` of config.json that came back
  `needs_confirmation` (`confirm.items`): the D14 dialog whose confirm
  re-sends the same content and `expected` with `confirmed_hooks: true`.
  """
  @spec confirm_external(map(), map(), [String.t()]) :: term()
  @impl true
  def confirm_external(ctx, %{content: content, fingerprint: fingerprint}, items) do
    id = project_id(ctx)

    resend =
      {:command, "file.save", %{"ref" => ref(id)},
       %{"content" => content, "confirmed_hooks" => true},
       %{
         expected: %{"fingerprint" => fingerprint},
         write_key: {:file, ref(id)},
         toast: "Saved the file"
       }}

    hooks =
      Enum.map(items, fn item ->
        case String.split(to_string(item), ": ", parts: 2) do
          [event, command] -> %{event: event, command: command}
          [command] -> %{event: "hook", command: command}
        end
      end)

    external_hooks_confirm(project_name(ctx), hooks, [resend])
  end

  @doc """
  The confirmation a hook command asks for before it is saved (D14), or nil
  when none is needed (untrusted projects: it will not run until trusted).
  """
  @spec hook_confirm(map(), String.t(), String.t(), map(), [term()]) :: nil | term()
  def hook_confirm(config, project_name, event, hook, then) do
    if get(config, :trusted) == true do
      {:confirm,
       %Confirm{
         id: "hook",
         title: "Run this on your machine?",
         lines: ["In #{project_name}, whenever #{event}: #{get(hook, :command)}"],
         safe: "Cancel",
         danger: "S  Save the hook",
         letter: "S"
       }, then: then}
    end
  end

  @doc "The D14 dialog for hooks an external edit adds (from `needs_confirmation`)."
  @spec external_hooks_confirm(String.t(), [map()], [term()]) :: term()
  def external_hooks_confirm(project_name, items, then) do
    lines =
      ["In #{project_name}, the file now runs:"] ++
        Enum.map(items, fn item -> "  #{get(item, :event)} · #{get(item, :command)}" end)

    {:confirm,
     %Confirm{
       id: "external-hooks",
       title: "Run these on your machine?",
       lines: lines,
       safe: "Cancel",
       danger: "S  Save the file",
       letter: "S"
     }, then: then}
  end

  defp external_edit(ctx) do
    id = project_id(ctx)

    case id && file(ctx, ref(id)) do
      nil ->
        [{:toast, "Reading the file…", :info} | Enum.map(loads(ctx), &{:load, &1})]

      file ->
        [
          {:external_edit,
           %{
             ref: ref(id),
             content: get(file, :content) || "{}\n",
             fingerprint: get(file, :fingerprint),
             suffix: ".json"
           }}
        ]
    end
  end

  # ------------------------------------------------------------------ rows

  defp header(config, _ctx) do
    {words, role} =
      case get(config, :parse) do
        "ok" -> {"✓ read", :success}
        "missing" -> {"no file yet", :text_ghost}
        "invalid" -> {"✗ not valid JSON (#{get(config, :error) || "?"})", :error}
        _ -> {"…", :text_faint}
      end

    %Row{
      id: "head:file",
      kind: :action,
      label: get(config, :path) || ".swarm_code/config.json",
      value: [{words, role}],
      tag: [{"e edit the whole file", :text_faint}],
      keys: [{"e", :edit_external, "edit the whole file"}, {"Ctrl-R", :restart, "reload"}]
    }
  end

  defp ignored_keys(config, _id) do
    top =
      case get(config, :top_level) do
        map when is_map(map) -> Enum.sort_by(map, &to_string(elem(&1, 0)))
        _ -> []
      end

    denied =
      case get(config, :denied) do
        list when is_list(list) -> list
        map when is_map(map) -> Map.keys(map)
        _ -> []
      end

    top_rows =
      for {key, value} <- top do
        key = to_string(key)

        %Row{
          id: "pf:" <> key,
          kind: :setting,
          key: "project_file." <> key,
          label: key,
          value: [{short(value), :text_primary}, {" · SwarmCode ignores this key", :text_faint}],
          tag: [{"x remove", :text_faint}],
          state: :readonly,
          target: {:remove_key, key},
          keys: [{"x", :delete, "remove it"}]
        }
      end

    denied_rows =
      for key <- denied do
        key = to_string(key)

        %Row{
          id: "pf-denied:" <> key,
          kind: :info,
          label: key,
          value: [{"a project file may not set this · it is stripped when read", :warning}],
          tag: [{"x remove", :text_faint}],
          target: {:remove_key, key},
          keys: [{"x", :delete, "remove it"}]
        }
      end

    case top_rows ++ denied_rows do
      [] -> []
      rows -> [Row.heading("keys SwarmCode ignores") | rows]
    end
  end

  defp hooks(config, ctx, _id) do
    trusted? = get(config, :trusted) == true
    name = project_name(ctx)

    heading =
      Row.heading("hooks", [
        {"run only in trusted projects · #{name} is #{if trusted?, do: "trusted", else: "not trusted"}",
         if(trusted?, do: :text_faint, else: :warning)}
      ])

    rows = hook_rows(config)

    untrusted =
      if trusted?,
        do: [],
        else: [
          %Row{
            id: "info:untrusted",
            kind: :link,
            label: "",
            value: [{"Hooks run only in trusted projects. #{name} is not trusted.", :warning}],
            tag: [{"Enter Approvals & trust", :text_faint}],
            target: {:section, :approvals},
            keys: [{"Enter", :enter, "open Approvals & trust"}]
          }
        ]

    table_head = %Row{
      id: "hooks-head",
      kind: :heading,
      label: "",
      columns: [
        {"event", :text_faint, 1},
        {"matcher", :text_faint, 3},
        {"command", :text_faint, 2},
        {"timeout", :text_faint, 4}
      ]
    }

    empty =
      if rows == [],
        do: [Row.info("hooks-none", "no hooks · a adds one", keys: [{"a", :add, "add a hook"}])],
        else: [table_head]

    [heading] ++ untrusted ++ empty ++ rows
  end

  @doc false
  def hook_rows(config) do
    hooks = get(config, :hooks)

    for event <- @events,
        {hook, position} <- Enum.with_index(event_hooks(hooks, event)) do
      index = get(hook, :index) || position
      matcher = get(hook, :matcher)
      timeout = get(hook, :timeout_ms)

      %Row{
        id: "hook:#{event}:#{index}",
        kind: :record,
        label: event,
        value: [{get(hook, :command) || "", :text_primary}],
        columns: [
          {event, :text_primary, 1},
          {if(is_binary(matcher), do: matcher, else: "every tool"),
           if(is_binary(matcher), do: :text_primary, else: :text_faint), 3},
          {get(hook, :command) || "", :text_primary, 2},
          {timeout_words(timeout), :text_muted, 4}
        ],
        target: {:hook, event, index},
        keys: [
          {"Enter", :enter, "edit"},
          {"a", :add, "add a hook"},
          {"x", :delete, "delete"},
          {"J", :move_down, "later"},
          {"K", :move_up, "earlier"}
        ]
      }
    end
  end

  defp event_hooks(hooks, event) when is_map(hooks) do
    case Map.get(hooks, event, Enum.find_value(hooks, &atom_key(&1, event))) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp event_hooks(hooks, event) when is_list(hooks),
    do: Enum.filter(hooks, &(get(&1, :event) == event))

  defp event_hooks(_hooks, _event), do: []

  defp atom_key({key, value}, event) when is_atom(key),
    do: if(Atom.to_string(key) == event, do: value)

  defp atom_key(_pair, _event), do: nil

  defp ignored_entries(config, _id) do
    case get(config, :ignored_entries) do
      [_ | _] = entries ->
        rows =
          for entry <- entries do
            path = get(entry, :path) || "?"
            error? = get(entry, :severity) in ["error", :error]

            %Row{
              id: "ignored:" <> path,
              kind: :info,
              label: "",
              value: [
                {if(error?, do: "✗ ", else: "! "), if(error?, do: :error, else: :warning)},
                {"#{path} · #{get(entry, :reason) || ""}", :text_primary}
              ],
              tag: [{"x remove", :text_faint}],
              target: {:entry, path},
              keys: [{"x", :delete, "remove it"}]
            }
          end

        [Row.heading("ignored entries") | rows]

      _ ->
        []
    end
  end

  defp profiles(config, _id) do
    list =
      case get(config, :profiles) do
        map when is_map(map) ->
          Enum.map(map, fn {name, fields} -> Map.put(fields || %{}, :name, to_string(name)) end)

        list when is_list(list) ->
          list

        _ ->
          []
      end

    case list do
      [] ->
        []

      profiles ->
        head = %Row{
          id: "profiles-head",
          kind: :heading,
          label: "",
          columns: [
            {"name", :text_faint, 1},
            {"model", :text_faint, 3},
            {"effort", :text_faint, 2},
            {"sub-agent effort", :text_faint, 4}
          ]
        }

        rows =
          for p <- profiles do
            name = get(p, :name)

            %Row{
              id: "profile:" <> name,
              kind: :record,
              label: name,
              columns: [
                {name, :text_primary, 1},
                {get(p, :model) || "—", :text_muted, 3},
                {get(p, :effort) || "—", :text_muted, 2},
                {get(p, :swarm_effort) || "—", :text_muted, 4}
              ],
              target: {:profile, name},
              keys: [{"x", :delete, "delete"}]
            }
          end

        [Row.heading("profiles"), head | rows]
    end
  end

  # ---------------------------------------------------------------- helpers

  defp find_hook(_config, "new:" <> _event), do: nil

  defp find_hook(config, id) do
    case String.split(id, ":", parts: 2) do
      [event, index] ->
        config
        |> get(:hooks)
        |> event_hooks(event)
        |> Enum.with_index()
        |> Enum.find_value(fn {hook, position} ->
          if to_string(get(hook, :index) || position) == index, do: hook
        end)

      _ ->
        nil
    end
  end

  defp hook_event("new:" <> event, _hook), do: event
  defp hook_event(id, _hook), do: id |> String.split(":", parts: 2) |> hd()

  defp matcher_value(matcher) when is_binary(matcher) and matcher != "",
    do: [{matcher, :text_primary}]

  defp matcher_value(_), do: [{"every tool", :text_faint}]

  defp blank_nil(""), do: nil
  defp blank_nil(value), do: value

  defp to_int(text) do
    case Integer.parse(to_string(text)) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp command(ctx, action, target, attributes, toast) do
    id = project_id(ctx)
    fingerprint = ctx |> config() |> get(:fingerprint)

    {:command, action, Map.put(target, "project_id", id), attributes,
     %{expected: %{"fingerprint" => fingerprint}, write_key: {:file, ref(id)}, toast: toast}}
  end

  @doc "The file ref of a project's config.json (§3.4.5)."
  @spec ref(String.t()) :: String.t()
  def ref(project_id), do: "project_config:project:#{project_id}:config"

  defp timeout_words(ms) when is_integer(ms) and rem(ms, 1000) == 0, do: "#{div(ms, 1000)} s"
  defp timeout_words(ms) when is_integer(ms), do: "#{ms} ms"
  defp timeout_words(_), do: "10 s"

  defp short(value) when is_binary(value), do: value
  defp short(value), do: value |> inspect() |> String.slice(0, 40)

  defp config(ctx) do
    with id when is_binary(id) <- project_id(ctx),
         record when not is_nil(record) <-
           ctx.data |> Map.get(:record, %{}) |> Map.get({"project_config", id}) do
      Map.get(record, :fields, record)
    else
      _ -> nil
    end
  end

  defp file(ctx, ref), do: ctx.data |> Map.get(:files, %{}) |> Map.get(ref)

  # The page's project: the picker's choice, else the session's (§2.10, D12).
  defp project(ctx) do
    items = projects(ctx)
    chosen = ctx.layer && Map.get(ctx.layer, :page_project_id)
    session = ctx.data && Map.get(ctx.data, :project_id)

    Enum.find(items, &(chosen != nil and get(&1, :id) == chosen)) ||
      Enum.find(items, &(get(&1, :current) == true)) ||
      Enum.find(items, &(session != nil and get(&1, :id) == session)) ||
      Enum.find(items, &(ctx.project != nil and ctx.project in [get(&1, :name), get(&1, :root)]))
  end

  defp project_id(ctx) do
    case project(ctx) do
      nil ->
        chosen = ctx.layer && Map.get(ctx.layer, :page_project_id)
        chosen || (ctx.data && Map.get(ctx.data, :project_id))

      p ->
        get(p, :id)
    end
  end

  defp projects(ctx) do
    case ctx.data && Map.get(ctx.data, :projects) do
      %{items: items} when is_list(items) -> Enum.map(items, &fields/1)
      items when is_list(items) -> Enum.map(items, &fields/1)
      _ -> []
    end
  end

  defp fields(%{fields: fields}) when is_map(fields), do: fields
  defp fields(other), do: other

  defp project_name(ctx) do
    case project(ctx) do
      nil -> "this project"
      p -> get(p, :name) || "this project"
    end
  end

  defp get(nil, _key), do: nil
  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp get(_other, _key), do: nil
end
