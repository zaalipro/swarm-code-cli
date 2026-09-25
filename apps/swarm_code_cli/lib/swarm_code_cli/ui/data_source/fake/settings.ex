defmodule SwarmCodeCLI.UI.DataSource.Fake.Settings do
  @moduledoc """
  pass74 §3.6 (S1): the fake source's settings store, seeded with the spec's
  Appendix A. It answers the generic views (`values`, `overview`, `facts`, `usage`,
  `open`, `task`, `records`/`record` of the seeded kinds — `projects`) and the
  generic actions (`values.patch`, `values.reset`, `profile.apply`, `task.cancel`)
  with the service's rules: registry validators, the `provider_exists` and
  `effort_of_model` service checks, compare-and-set against the stored value, all
  or nothing per request, `dry_run`.

  Every other action and view goes to `Fake.SettingsIntegrations` (U2) when that
  module is loaded (its state lives here under `:integrations`), else answers
  `unsupported`. Tasks follow one generic lifecycle: `running` when started,
  `done` at the next `step/1` (at once with `auto_tasks: true`), results read with
  `view=task`; `hold_task/2` keeps a task running until `release_task/3`.

  Answers are built as wire maps (what the daemon would put on the socket) and
  decoded by the client DTOs, so the fake exercises the codec's decoding rules.
  A pasted secret is never kept: `secret_writes/1` has its SHA-256 only.

  The pure functions (`seed/1`, `query/2`, `command/2`, `control/3`) are called
  by `Fake.Source`, which owns the state; the test controls call the source.
  """
  alias SwarmCode.Settings.{Entry, RecordKind, Registry, Sections, TextValue, Validate}
  alias SwarmCode.Settings.WireValue
  alias SwarmCodeCLI.UI.DataSource.{DTO, Request}

  @integrations SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations

  @ailogic "11111111-1111-4111-8111-111111111111"
  @notes "22222222-2222-4222-8222-222222222222"
  @conversation "4f2a0000-0000-4000-8000-000000000001"
  @deepseek "0d5e0000-0000-4000-8000-000000000001"
  @anthropic "0d5e0000-0000-4000-8000-000000000002"
  @ollama "0d5e0000-0000-4000-8000-000000000003"
  @openrouter "0d5e0000-0000-4000-8000-000000000004"
  @github "3c9a0000-0000-4000-8000-000000000001"

  @models %{
    @deepseek => ["deepseek-v4-pro", "deepseek-v4-flash"],
    @anthropic => ["claude-sonnet-5", "claude-opus-5"],
    @ollama => ["qwen3-coder"],
    @openrouter => []
  }
  @classic ~w(low medium high max)
  @not_cancellable ~w(storage.run storage.vacuum storage.apply_retention)
  @order ~w(accepted unchanged needs_confirmation conflict not_found rejected)
  @max_log 200
  @page 200

  @type state :: map()

  ## ------------------------------------------------------------------ ids

  @doc "The Appendix A ids (projects, conversation, providers)."
  @spec ids() :: %{atom() => String.t()}
  def ids,
    do: %{
      ailogic: @ailogic,
      notes: @notes,
      conversation: @conversation,
      deepseek: @deepseek,
      anthropic: @anthropic,
      ollama: @ollama,
      openrouter: @openrouter,
      github: @github
    }

  ## ------------------------------------------------------------ test controls

  @doc """
  A change made elsewhere: `key` (a registry key: the global, session or project
  value of the context) or `{kind, id, field}` (a record field), then one
  `settings_update` delta with origin `elsewhere`. `fake` is the source (or the
  client adapter bound to it).
  """
  def put(fake, key_or_path, value), do: call(fake, :put, [key_or_path, value])

  @doc "The next command of `action` answers `%{status, message, field_errors}` and writes nothing."
  def fail_next(fake, action, reply), do: call(fake, :fail_next, [action, reply])

  @doc "Tasks of `action` started from now stay running until `release_task/3`."
  def hold_task(fake, action), do: call(fake, :hold_task, [action])

  @doc "Finish the held tasks of `action` with `result` (a summary map) or `{:error, message}`."
  def release_task(fake, action, result), do: call(fake, :release_task, [action, result])

  @doc "The next settings command is answered with an `outcome` reply of `status` (§3.4.2)."
  def reply_outcome_next(fake, status), do: call(fake, :reply_outcome_next, [status])

  @doc """
  Script `action` (an action the fake does not simulate): `reply` is a
  `settings_result` value (string or atom keys; missing keys take the defaults),
  `{:task, summary}` / `{:task, summary, rows}` (a task that finishes with them),
  or a function of the command's params returning either.
  """
  def stub_reply(fake, action, reply), do: call(fake, :stub_reply, [action, reply])

  @doc "The settings requests received, oldest first (secrets as `[REDACTED]`)."
  def requests(fake), do: call(fake, :requests, [])

  @doc "`[{action, slot, sha256 hex}]` of every secret a command carried; never the value."
  def secret_writes(fake), do: call(fake, :secret_writes, [])

  @doc "Finish every running task that is not held."
  def step(fake), do: call(fake, :step, [])

  @doc "The whole settings state (for assertions)."
  def state(fake), do: call(fake, :state, [])

  defp call(fake, op, args) do
    source = GenServer.call(fake, :settings_source)
    GenServer.call(source, {:settings_control, op, args})
  end

  ## ------------------------------------------------------------------ seed

  @doc """
  The Appendix A store. Options: `:now` (ISO-8601), `:auto_tasks` (default false),
  `:integrations` (default true: seed `Fake.SettingsIntegrations` when loaded),
  `:env` (the environment the service sees), `:flag_model` (the `--model` overlay,
  nil for none).
  """
  @spec seed(keyword()) :: state()
  def seed(opts \\ []) do
    now = Keyword.get(opts, :now, "2026-09-25T18:40:00Z")

    integrations = if Keyword.get(opts, :integrations, true), do: integrations_seed(now)

    %{
      now: now,
      revision: 1,
      auto_tasks: Keyword.get(opts, :auto_tasks, false),
      project_id: @ailogic,
      conversation_id: @conversation,
      global: seed_global(),
      session: seed_session(),
      records: %{"project" => seed_projects(now)},
      project_file: %{@ailogic => %{"effort" => "high"}, @notes => %{}},
      profiles: %{@ailogic => %{"fast" => %{"effort" => "low"}}, @notes => %{}},
      env: Keyword.get(opts, :env, %{"SWARM_THEME" => "light", "VISUAL" => "hx"}),
      flag_model:
        Keyword.get(opts, :flag_model, %{"provider_id" => @deepseek, "model" => "deepseek-v4-pro"}),
      tasks: %{},
      task_seq: 0,
      last_results: %{},
      holds: MapSet.new(),
      fail_next: %{},
      outcome_next: nil,
      stubs: %{},
      requests: [],
      secret_writes: [],
      integrations: integrations
    }
  end

  # U2's simulation of the integration handlers (`integrations: false` leaves
  # it out: every S2 action then answers `unsupported`).
  defp integrations_seed(now), do: @integrations.seed(now: now)

  defp seed_global do
    base =
      for entry <- Registry.all(), entry.home == :global and Entry.scalar?(entry), into: %{} do
        {entry.key, entry.default}
      end

    Map.merge(base, %{
      "models.chat" => %{"provider_id" => @deepseek, "model" => "deepseek-v4-pro"},
      "models.sub_agent" => %{"provider_id" => @deepseek, "model" => "deepseek-v4-flash"},
      "limits.max_concurrent_agents" => 6,
      "limits.max_agent_depth" => 2,
      "limits.max_agent_turns" => 60,
      "limits.sub_agent_timeout" => 1_800,
      "research.max_live" => 12,
      "web.reader" => "web_fetch",
      "budget.monthly_usd" => 50,
      "storage.retention_days" => nil,
      "desktop.mode" => "light"
    })
  end

  defp seed_session do
    base =
      for entry <- Registry.all(), entry.home == :session, into: %{} do
        {entry.key, if(entry.nullable, do: nil, else: entry.default)}
      end

    Map.merge(base, %{
      "session.model" => %{"provider_id" => @deepseek, "model" => "deepseek-v4-pro"},
      "session.effort" => "high",
      "session.title" => "Refactor the parser"
    })
  end

  defp seed_projects(now) do
    %{
      @ailogic => %{
        "id" => @ailogic,
        "name" => "ailogic",
        "root" => "/Users/dev/ailogic",
        "approval_mode" => "auto",
        "trusted" => true,
        "trusted_at" => "2026-09-01T10:00:00Z",
        "prefixes" => ["mix test", "git status", "rg", "ls", "mix format"],
        "scratch" => false,
        "last_opened_at" => now,
        "current" => true
      },
      @notes => %{
        "id" => @notes,
        "name" => "notes",
        "root" => "/Users/dev/notes",
        "approval_mode" => "read_only",
        "trusted" => false,
        "trusted_at" => nil,
        "prefixes" => [],
        "scratch" => false,
        "last_opened_at" => "2026-09-20T09:00:00Z",
        "current" => false
      }
    }
  end

  ## ----------------------------------------------------------------- queries

  @doc """
  Answer a `settings.query` request: `{state, body, deltas}` where `body` is the
  decoded `DTO.SettingsSnapshot` (or `{:settings_failed, id, words}` when the
  answer fails the client's decoding rules) and `deltas` are
  `{:settings_update | :settings_task, body}` facts.
  """
  @spec query(state(), Request.t()) :: {state(), term(), list()}
  def query(state, %Request{kind: {:settings_query, params}} = request) do
    state = log(state, "settings.query", params)
    view = params["view"]

    value =
      case view_body(state, view, params) do
        {:ok, body} -> snapshot(view, body, state.revision, request.request_id)
        {:error, message} -> unavailable(view, message, state.revision, request.request_id)
      end

    {state, decode_snapshot(value, request), []}
  end

  defp view_body(state, "values", params), do: {:ok, values_body(state, params)}
  defp view_body(state, "overview", _params), do: {:ok, overview_body(state)}
  defp view_body(_state, "facts", _params), do: {:ok, facts_body()}
  defp view_body(_state, "usage", _params), do: {:ok, usage_body()}

  defp view_body(state, "open", params) do
    {:ok, projects} =
      view_body(state, "records", %{"kind" => "projects", "page_size" => @page, "cursor" => nil})

    {:ok,
     %{
       "values" => values_body(state, Map.merge(params, %{"sections" => nil, "keys" => nil})),
       "overview" => overview_body(state),
       "facts" => facts_body(),
       "projects" => projects
     }}
  end

  defp view_body(state, "task", params), do: task_view(state, params)

  defp view_body(state, view, params) when view in ["records", "record", "file"] do
    case integration_query(state, params) do
      {:ok, body} -> {:ok, body}
      {:error, _status, message} -> {:error, message}
      :unsupported -> local_records(state, view, params)
    end
  end

  defp view_body(_state, _view, _params), do: {:error, "Settings can't show that here."}

  defp integration_query(%{integrations: nil}, _params), do: :unsupported

  defp integration_query(%{integrations: int}, params), do: @integrations.query(int, params)

  defp local_records(state, "records", params) do
    kind = RecordKind.for_query_kind(params["kind"])

    items =
      state.records
      |> Map.get(kind, %{})
      |> Map.values()
      |> sort_records(kind)
      |> Enum.map(&record(kind, &1))

    {:ok, page(params["kind"], items, params)}
  end

  defp local_records(state, "record", params) do
    kind = RecordKind.for_query_kind(params["kind"])

    case get_in(state.records, [kind, params["id"]]) do
      nil -> {:error, "That no longer exists."}
      fields -> {:ok, record(kind, fields)}
    end
  end

  defp local_records(_state, _view, _params), do: {:error, "Settings can't show that here."}

  defp sort_records(items, "project"),
    do: Enum.sort_by(items, &{not &1["current"], &1["last_opened_at"] || ""}, &sort_desc/2)

  defp sort_records(items, _kind), do: Enum.sort_by(items, &(&1["id"] || ""))

  defp sort_desc({a_current, a_at}, {b_current, b_at}),
    do: a_current < b_current or (a_current == b_current and a_at >= b_at)

  defp record(kind, fields), do: %{"kind" => kind, "id" => fields["id"], "fields" => fields}

  defp page(kind, items, params) do
    size = min(params["page_size"] || @page, @page)
    start = cursor(params["cursor"])
    slice = items |> Enum.drop(start) |> Enum.take(size)
    next = if start + size < length(items), do: Integer.to_string(start + size)
    %{"kind" => kind, "items" => slice, "next_cursor" => next, "total" => length(items)}
  end

  defp cursor(nil), do: 0

  defp cursor(text) when is_binary(text) do
    case Integer.parse(text) do
      {n, ""} when n >= 0 -> n
      _ -> 0
    end
  end

  defp cursor(_text), do: 0

  ## ------------------------------------------------------------------ values

  defp values_body(state, params) do
    project_id = params["project_id"] || state.project_id
    sections = section_filter(params["sections"])
    keys = params["keys"]

    values =
      for entry <- Registry.all(),
          Entry.scalar?(entry),
          entry.scope != :cli,
          is_nil(sections) or entry.section in sections,
          is_nil(keys) or entry.key in keys,
          do: setting_value(state, entry, project_id)

    %{"values" => values, "project_id" => project_id, "conversation_id" => state.conversation_id}
  end

  defp section_filter(nil), do: nil
  defp section_filter(list), do: Enum.map(list, &Sections.from_wire/1)

  @doc false
  def setting_value(state, entry, project_id) do
    layers = Enum.map(entry.layers, &layer(state, entry, &1, project_id))
    winner = Enum.find(layers, &(&1["set"] and not &1["ignored"]))
    value = if winner, do: winner["value"]
    base = home_value(state, entry, project_id)
    typed? = WireValue.type_ok?(entry, WireValue.normalize(entry, value))

    {status, value, note} =
      if typed?,
        do: {"ok", value, nil},
        else:
          {"invalid", nil,
           "the stored value #{short_json(base)} is not valid here; choose a new one"}

    %{
      "key" => entry.key,
      "value" => value,
      "layers" => layers,
      "winner" => if(winner, do: winner["layer"]),
      "writable" => if(Entry.writable?(entry), do: [Atom.to_string(entry.home)], else: []),
      "base" => base,
      "choices" => choices(state, entry, project_id),
      "state" => status,
      "note" => note
    }
  end

  defp layer(state, entry, :flag, _project_id) do
    if entry.key in ["session.model", "session.sub_agent_model"] and state.flag_model,
      do:
        wire_layer(:flag, state.flag_model, true, source: "--model", note: "for this launch only"),
      else: wire_layer(:flag, nil, false)
  end

  defp layer(state, entry, :env, _project_id) do
    case Enum.find(entry.env, &Map.has_key?(state.env, &1)) do
      nil ->
        wire_layer(:env, nil, false)

      name ->
        raw = Map.fetch!(state.env, name)

        case TextValue.parse(entry, raw) do
          {:ok, value} when not is_tuple(value) ->
            if WireValue.type_ok?(entry, value),
              do: wire_layer(:env, value, true, source: name),
              else: ignored_layer(:env, raw, name, "not a valid value here; ignored")

          _ ->
            ignored_layer(:env, raw, name, "not a valid value here; ignored")
        end
    end
  end

  defp layer(state, entry, :session, _project_id) do
    value = Map.get(state.session, entry.key)

    set? =
      if entry.key == "session.mode",
        do: value not in [nil, "build"],
        else: value != nil and (entry.nullable or value != entry.default)

    wire_layer(:session, value, set?)
  end

  defp layer(state, entry, :project, project_id),
    do: wire_layer(:project, project_value(state, entry, project_id), true)

  defp layer(state, %Entry{home: :global} = entry, :global, _project_id) do
    value = Map.get(state.global, entry.key)
    set? = if entry.nullable, do: value != nil, else: value != entry.default
    wire_layer(:global, value, set?)
  end

  defp layer(state, %Entry{follows: follows}, :global, _project_id) when is_binary(follows) do
    value = Map.get(state.global, follows)
    wire_layer(:global, value, value != nil)
  end

  defp layer(_state, _entry, :global, _project_id), do: wire_layer(:global, nil, false)

  defp layer(state, entry, :project_file, project_id) do
    file = Map.get(state.project_file, project_id, %{})

    case {entry.storage, entry.ignored_layers} do
      {{:project_file_key, key}, _} when is_binary(key) ->
        wire_layer(:project_file, Map.get(file, key), Map.has_key?(file, key))

      {_, ignored} ->
        case Enum.find(ignored, fn {layer, key} ->
               layer == :project_file and Map.has_key?(file, key)
             end) do
          {_, key} ->
            ignored_layer(
              :project_file,
              Jason.encode!(file[key]),
              nil,
              "SwarmCode ignores this key"
            )

          nil ->
            wire_layer(:project_file, nil, false)
        end
    end
  end

  defp layer(_state, entry, :default, _project_id), do: wire_layer(:default, entry.default, true)
  defp layer(_state, _entry, layer, _project_id), do: wire_layer(layer, nil, false)

  defp wire_layer(layer, value, set, opts \\ []) do
    %{
      "layer" => Atom.to_string(layer),
      "value" => if(set, do: value),
      "set" => set,
      "ignored" => false,
      "raw" => nil,
      "source" => Keyword.get(opts, :source),
      "note" => Keyword.get(opts, :note)
    }
  end

  defp ignored_layer(layer, raw, source, note) do
    %{
      "layer" => Atom.to_string(layer),
      "value" => nil,
      "set" => true,
      "ignored" => true,
      "raw" => String.slice(to_string(raw), 0, 200),
      "source" => source,
      "note" => note
    }
  end

  defp home_value(state, %Entry{home: :global} = entry, _p), do: Map.get(state.global, entry.key)

  defp home_value(state, %Entry{home: :session} = entry, _p),
    do: Map.get(state.session, entry.key)

  defp home_value(state, %Entry{home: :project} = entry, p), do: project_value(state, entry, p)
  defp home_value(_state, _entry, _project_id), do: nil

  @project_fields %{
    "project.approval_mode" => "approval_mode",
    "project.trusted" => "trusted",
    "project.allow" => "prefixes",
    "project.name" => "name"
  }

  defp project_value(state, entry, project_id) do
    with field when is_binary(field) <- Map.get(@project_fields, entry.key),
         %{} = project <- get_in(state.records, ["project", project_id]) do
      Map.get(project, field)
    else
      _ -> nil
    end
  end

  defp choices(state, %Entry{dynamic_choices: {:effort_of, source}} = entry, project_id) do
    levels = levels(effort_model(state, source, project_id))
    levels = if entry.home == :global, do: Enum.uniq(levels ++ @classic), else: levels
    Enum.map(levels, &%{"value" => &1, "label" => &1, "hint" => nil})
  end

  defp choices(_state, _entry, _project_id), do: nil

  @effort_sources %{
    chat_default: "models.chat",
    swarm_default: "models.sub_agent",
    scheduled_default: "models.scheduled",
    workflow_default: "models.workflow",
    implementer_default: "models.implementer",
    research_lead: "research.lead_model",
    research_worker: "research.worker_model",
    research_reporter: "research.reporter_model",
    session_chat: "session.model",
    session_swarm: "session.sub_agent_model",
    session_judge: "session.judge_model",
    session_implementer: "session.implementer_model"
  }

  defp effort_model(state, source, project_id) do
    key = Map.get(@effort_sources, source, "models.chat")

    model =
      case Registry.fetch(key) do
        {:ok, entry} ->
          state |> setting_value_raw(entry, project_id)

        _ ->
          nil
      end

    model || Map.get(state.global, "models.chat")
  end

  defp setting_value_raw(state, entry, project_id) do
    entry.layers
    |> Enum.map(&layer(state, entry, &1, project_id))
    |> Enum.find(&(&1["set"] and not &1["ignored"]))
    |> case do
      nil -> nil
      layer -> layer["value"]
    end
  end

  defp levels(%{"model" => "claude-" <> _}), do: ~w(low medium high xhigh max)
  defp levels(_model), do: ~w(low medium high)

  ## ---------------------------------------------------- overview, facts, usage

  defp overview_body(state) do
    global = state.global
    project = get_in(state.records, ["project", state.project_id]) || %{}

    %{
      "attention" => [
        %{
          "id" => "mcp_failed:github",
          "severity" => "error",
          "section" => "mcp",
          "target" => %{"kind" => "mcp_server", "id" => @github},
          "title" => "github MCP server failed to start",
          "reason" => "command not found: github-mcp-server"
        },
        %{
          "id" => "unpriced_models",
          "severity" => "warning",
          "section" => "pricing",
          "target" => %{"kind" => "unpriced_models", "id" => nil},
          "title" => "2 models in use have no price",
          "reason" => "claude-sonnet-5, qwen3-coder"
        },
        %{
          "id" => "project_file_ignored:#{@ailogic}",
          "severity" => "warning",
          "section" => "project_file",
          "target" => %{"kind" => "project_config", "id" => @ailogic},
          "title" => "ailogic's project file has entries SwarmCode ignores",
          "reason" => "effort, hooks.post_edit, profiles.fast.mode"
        }
      ],
      "glance" => %{
        "providers" => %{"count" => 4, "usable" => 3, "chat" => "DeepSeek · deepseek-v4-pro"},
        "search" => %{"enabled" => 2, "total" => 6, "first" => "Tavily"},
        "mcp" => %{"servers" => 3, "failed" => 1, "tools" => 41},
        "agents" => %{
          "max_concurrent" => global["limits.max_concurrent_agents"],
          "max_depth" => global["limits.max_agent_depth"],
          "max_turns" => global["limits.max_agent_turns"]
        },
        "approvals" => %{
          "mode" => project["approval_mode"],
          "trusted" => project["trusted"],
          "allowed" => length(project["prefixes"] || [])
        },
        "storage" => %{"database_bytes" => 1_800_000_000, "sessions" => 214, "cleanup_days" => 12},
        "budget" => %{"spend_usd" => 38.2, "budget_usd" => global["budget.monthly_usd"]}
      }
    }
  end

  defp facts_body do
    %{
      "paths" => %{
        "database" => "~/Library/Application Support/SwarmCode/swarm_code.db",
        "config_dir" => "~/.config/swarmcode",
        "research_root" => "~/SwarmCode/research",
        "project_dir" => "/Users/dev/ailogic/.swarm_code",
        "user_agents" => "~/.swarm_code/agents",
        "user_skills" => "~/.swarm_code/skills",
        "user_commands" => "~/.swarm_code/commands",
        "user_workflows" => "~/.swarm_code/workflows"
      },
      "database_bytes" => 1_800_000_000,
      "env" => [
        %{
          "name" => "SWARM_THEME",
          "set" => true,
          "value" => "light",
          "secret" => false,
          "feeds" => "terminal.theme"
        },
        %{
          "name" => "VISUAL",
          "set" => true,
          "value" => "hx",
          "secret" => false,
          "feeds" => "terminal.editor"
        },
        %{
          "name" => "LLMOTIONS_API_KEY",
          "set" => false,
          "value" => nil,
          "secret" => true,
          "feeds" => nil
        }
      ],
      "versions" => %{
        "service" => "0.1.0",
        "protocol" => 1,
        "otp" => "28",
        "elixir" => "1.18.4"
      },
      "research_levels" => [
        %{"key" => "low", "label" => "Fastest", "steps" => 3, "fanout" => 3, "median_ms" => nil},
        %{
          "key" => "medium",
          "label" => "Balanced",
          "steps" => 5,
          "fanout" => 4,
          "median_ms" => 240_000
        }
      ],
      "scheduler" => "desktop_only"
    }
  end

  defp usage_body do
    %{
      "month" => %{"spend_usd" => 38.2, "budget_usd" => 50},
      "by_model" => [
        %{
          "model" => "deepseek-v4-pro",
          "input_tokens" => 21_400_000,
          "output_tokens" => 3_100_000,
          "cost_usd" => 30.1
        },
        %{
          "model" => "claude-opus-5",
          "input_tokens" => 310_000,
          "output_tokens" => 46_000,
          "cost_usd" => 8.1
        },
        %{
          "model" => "claude-sonnet-5",
          "input_tokens" => 120_000,
          "output_tokens" => 18_000,
          "cost_usd" => nil
        }
      ]
    }
  end

  ## -------------------------------------------------------------------- tasks

  defp task_view(state, params) do
    task =
      case params["id"] do
        id when is_binary(id) ->
          Map.get(state.tasks, id)

        nil ->
          options = params["options"] || %{}

          case Map.get(state.last_results, {options["action"], options["target"]}) do
            nil -> nil
            id -> Map.get(state.tasks, id)
          end
      end

    case task do
      nil -> {:error, "that result is gone; run it again"}
      task -> {:ok, task_body(task, params)}
    end
  end

  defp task_body(task, params) do
    result =
      if task.state == "running",
        do: nil,
        else: task_result(task, params)

    %{
      "task_id" => task.id,
      "action" => task.action,
      "target" => task.target,
      "state" => task.state,
      "elapsed_ms" => task.elapsed_ms,
      "message" => task.message,
      "result" => result
    }
  end

  defp task_result(task, params) do
    rows = task.rows || []
    size = min(params["page_size"] || @page, @page)
    start = cursor(params["cursor"])
    slice = rows |> Enum.drop(start) |> Enum.take(size)
    next = if start + size < length(rows), do: Integer.to_string(start + size)
    %{"summary" => task.summary, "rows" => slice, "next_cursor" => next, "total" => length(rows)}
  end

  defp start_task(state, action, target, attributes, origin) do
    seq = state.task_seq + 1
    id = "7a5c0000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(seq), 12, "0")

    origin =
      case origin do
        {:integrations, wire} -> {:integrations, Map.put(wire, "task_id", id)}
        other -> other
      end

    task = %{
      id: id,
      action: action,
      target: target,
      attributes: attributes,
      origin: origin,
      cancellable: cancellable?(state, action),
      state: "running",
      elapsed_ms: 0,
      message: nil,
      summary: nil,
      rows: []
    }

    state = %{
      state
      | task_seq: seq,
        tasks: Map.put(state.tasks, id, task),
        last_results: Map.put(state.last_results, {action, target}, id)
    }

    running = task_delta(task)

    if state.auto_tasks and not MapSet.member?(state.holds, action) do
      {state, done} = finish(state, id, :run)
      {state, id, [running | done]}
    else
      {state, id, [running]}
    end
  end

  defp cancellable?(%{integrations: int}, action) when int != nil,
    do: @integrations.cancellable?(action)

  defp cancellable?(_state, action), do: action not in @not_cancellable

  defp finish(state, id, outcome) do
    task = Map.fetch!(state.tasks, id)

    {result, state} =
      case task.origin do
        {:integrations, wire_task} ->
          {result, int} = @integrations.run_task(state.integrations, wire_task, outcome)
          {result, %{state | integrations: int}}

        {:stub, summary, rows} ->
          case outcome do
            {:error, message} -> {{:failed, message}, state}
            {:ok, scripted} -> {{:done, Map.merge(summary, scripted), rows}, state}
            :run -> {{:done, summary, rows}, state}
          end
      end

    task =
      case result do
        {:done, summary, rows} ->
          %{task | state: "done", elapsed_ms: 412, summary: summary, rows: rows}

        {:failed, message} ->
          %{task | state: "failed", elapsed_ms: 412, message: message}
      end

    {%{state | tasks: Map.put(state.tasks, id, task)}, [task_delta(task)]}
  end

  defp task_delta(task) do
    {:settings_task,
     %{
       "task_id" => task.id,
       "action" => task.action,
       "target" => task.target,
       "state" => task.state,
       "elapsed_ms" => task.elapsed_ms,
       "progress" => nil,
       "summary" => if(task.state == "running", do: nil, else: small_summary(task.summary)),
       "message" => task.message
     }}
  end

  defp small_summary(nil), do: nil

  defp small_summary(summary) do
    case Jason.encode(summary) do
      {:ok, json} when byte_size(json) <= 16_384 -> summary
      _ -> %{"truncated" => true}
    end
  end

  defp running(state, pred) do
    state.tasks
    |> Map.values()
    |> Enum.filter(&(&1.state == "running" and pred.(&1)))
    |> Enum.sort_by(& &1.id)
  end

  ## ----------------------------------------------------------------- commands

  @doc """
  Answer a `settings.command` request: `{state, body, deltas}` with `body` a
  decoded `DTO.SettingsResult` (or the typed failure).
  """
  @spec command(state(), Request.t()) :: {state(), term(), list()}
  def command(state, %Request{kind: {:settings_command, params}} = request) do
    state = state |> log("settings.command", params) |> note_secrets(params)
    action = params["action"]

    cond do
      state.outcome_next != nil ->
        status = state.outcome_next

        {%{state | outcome_next: nil},
         DTO.SettingsResult.from_outcome(%{"status" => to_string(status)}, request.request_id),
         []}

      Map.has_key?(state.fail_next, action) ->
        {reply, fail} = Map.pop(state.fail_next, action)
        value = result_value(reply, state.revision, request.request_id)
        {%{state | fail_next: fail}, decode_result(value, request), []}

      Map.has_key?(state.stubs, action) ->
        stubbed(state, Map.fetch!(state.stubs, action), params, request)

      true ->
        {state, value, deltas} = run(state, action, params)

        value =
          Map.merge(value, %{"request_id" => request.request_id, "revision" => state.revision})

        {state, decode_result(value, request), deltas}
    end
  end

  defp stubbed(state, stub, params, request) do
    reply = if is_function(stub, 1), do: stub.(params), else: stub

    case reply do
      {:task, summary} ->
        stubbed(state, fn _ -> {:task, summary, []} end, params, request)

      {:task, summary, rows} ->
        {state, id, deltas} =
          start_task(
            state,
            params["action"],
            params["target"],
            params["attributes"],
            {:stub, summary, rows}
          )

        value =
          result_value(
            %{"status" => "accepted", "task" => %{"task_id" => id, "action" => params["action"]}},
            state.revision,
            request.request_id
          )

        {state, decode_result(value, request), deltas}

      reply when is_map(reply) ->
        {state, decode_result(result_value(reply, state.revision, request.request_id), request),
         []}
    end
  end

  defp run(state, "values.patch", params), do: patch(state, params)
  defp run(state, "values.reset", params), do: reset(state, params)
  defp run(state, "profile.apply", params), do: profile(state, params)
  defp run(state, "task.cancel", params), do: cancel(state, params)
  defp run(state, _action, params), do: integration_command(state, params)

  defp integration_command(%{integrations: nil} = state, _params),
    do: {state, result("unsupported", message: "Settings can't do that here yet."), []}

  defp integration_command(state, params) do
    case @integrations.command(state.integrations, params) do
      {{:ok, value}, int} ->
        state = %{state | integrations: int}
        {bump(state, value), value, update_delta(state, value, params)}

      {{:task, task, value}, int} ->
        state = %{state | integrations: int}

        {state, id, deltas} =
          start_task(
            state,
            task["action"],
            task["target"],
            task["attributes"],
            {:integrations, task}
          )

        value = Map.put(value, "task", %{"task_id" => id, "action" => task["action"]})
        {state, value, deltas}

      :unsupported ->
        {state, result("unsupported", message: "Settings can't do that here yet."), []}
    end
  end

  defp bump(state, %{"status" => "accepted"}), do: %{state | revision: state.revision + 1}
  defp bump(state, _value), do: state

  defp update_delta(state, %{"status" => "accepted"}, params) do
    section = action_section(params["action"])

    [
      {:settings_update,
       %{"revision" => state.revision + 1, "sections" => section, "origin" => "settings"}}
    ]
  end

  defp update_delta(_state, _value, _params), do: []

  defp action_section("provider." <> _), do: ["providers"]
  defp action_section("efforts." <> _), do: ["models_effort"]
  defp action_section("pricing." <> _), do: ["pricing"]
  defp action_section("search." <> _), do: ["search_web"]
  defp action_section("mcp." <> _), do: ["mcp"]
  defp action_section("storage." <> _), do: ["storage"]
  defp action_section("lsp." <> _), do: ["language_servers"]
  defp action_section("file." <> _), do: ["memory", "library"]
  defp action_section("workflow." <> _), do: ["library"]
  defp action_section("project_config." <> _), do: ["project_file"]
  defp action_section(_action), do: []

  # values.patch (§3.3.4): per change registry, scope, target, validation, then
  # CAS and write for all or nothing.
  defp patch(state, params) do
    attributes = params["attributes"] || %{}
    changes = attributes["changes"]

    if is_list(changes) and changes != [] and length(changes) <= 256 do
      apply_changes(state, changes, params["expected"] || %{}, params["dry_run"] == true)
    else
      {state, result("rejected", message: "changes must list 1 to 256 settings"), []}
    end
  end

  defp apply_changes(state, changes, expected, dry_run?) do
    checked = Enum.map(changes, &check_change(state, &1, expected))

    failed? = Enum.any?(checked, &match?({:error, _, _}, &1))

    rows =
      Enum.map(checked, fn
        {:error, key, row} -> Map.put(row, "target", key)
        {:ok, change} -> if failed?, do: row(change.key, "skipped"), else: ok_row(change)
      end)

    status = worst(rows)

    cond do
      failed? or dry_run? ->
        {state, result(status, results: rows, message: first_message(rows)), []}

      status == "unchanged" ->
        {state, result("unchanged", results: rows), []}

      true ->
        written = for {:ok, change} <- checked, not change.unchanged, do: change
        state = Enum.reduce(written, state, &write/2)
        sections = written |> Enum.map(&Atom.to_string(&1.entry.section)) |> Enum.uniq()
        state = %{state | revision: state.revision + 1}

        {state, result(status, results: rows),
         [
           {:settings_update,
            %{"revision" => state.revision, "sections" => sections, "origin" => "settings"}}
         ]}
    end
  end

  defp check_change(state, change, expected) when is_map(change) do
    key = change["key"]
    target = change["target"] || %{}

    with {:entry, {:ok, entry}} <- {:entry, Registry.fetch(key || "")},
         :ok <- scope_ok(entry),
         {:ok, target} <- resolve_target(state, entry, target),
         {:expected, {:ok, want}} <- {:expected, Map.fetch(expected, key)},
         value = Validate.normalise(entry, change["value"]),
         :ok <- Validate.check(entry, value),
         :ok <- svc_checks(state, entry, value, target) do
      current = WireValue.canonical(home_value(state, entry, target[:project_id]))

      cond do
        want != %{"$any" => true} and not WireValue.equal?(current, want) ->
          {:error, key, row(key, "conflict", current: current)}

        WireValue.equal?(current, value) ->
          {:ok, %{key: key, entry: entry, value: value, target: target, unchanged: true}}

        true ->
          {:ok, %{key: key, entry: entry, value: value, target: target, unchanged: false}}
      end
    else
      {:entry, _} ->
        {:error, key, row(to_string(key), "rejected", message: "not a setting: #{key}")}

      {:expected, :error} ->
        {:error, key, row(key, "rejected", message: "expected is missing for #{key}")}

      {:error, status, message} ->
        {:error, key, row(key, status, message: message)}

      {:error, message} ->
        {:error, key, row(key, "rejected", message: message)}
    end
  end

  defp check_change(_state, _change, _expected),
    do: {:error, "?", row("?", "rejected", message: "not a setting: ?")}

  defp scope_ok(%Entry{scope: :cli}),
    do: {:error, "rejected", "this setting lives in cli.json and is written by the terminal"}

  defp scope_ok(entry),
    do: if(Entry.writable?(entry), do: :ok, else: {:error, "rejected", "read-only"})

  defp resolve_target(state, %Entry{home: :session}, target) do
    case target["conversation_id"] || state.conversation_id do
      id when id == state.conversation_id ->
        {:ok, %{conversation_id: id, project_id: state.project_id}}

      _ ->
        {:error, "rejected", "only this session's conversation can be changed here"}
    end
  end

  defp resolve_target(state, %Entry{home: :project}, target) do
    id = target["project_id"] || state.project_id

    if get_in(state.records, ["project", id]),
      do: {:ok, %{project_id: id}},
      else: {:error, "not_found", "That project no longer exists"}
  end

  defp resolve_target(state, _entry, _target), do: {:ok, %{project_id: state.project_id}}

  defp svc_checks(state, entry, value, target) do
    Enum.reduce_while(Validate.svc_checks(entry), :ok, fn check, :ok ->
      case svc_check(state, entry, check, value, target) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp svc_check(state, _entry, :provider_exists, %{"provider_id" => id}, _target) do
    if Map.has_key?(providers(state), id),
      do: :ok,
      else: {:error, "that provider no longer exists"}
  end

  defp svc_check(
         state,
         %Entry{dynamic_choices: {:effort_of, source}},
         :effort_of_model,
         value,
         target
       )
       when is_binary(value) do
    model = effort_model(state, source, target[:project_id] || state.project_id)
    levels = levels(model)

    if value in levels,
      do: :ok,
      else: {:error, "is not a level of #{model["model"]}: #{Enum.join(levels, ", ")}"}
  end

  defp svc_check(_state, _entry, _check, _value, _target), do: :ok

  defp providers(%{integrations: %{providers: providers}}) when is_map(providers), do: providers
  defp providers(_state), do: @models

  defp write(%{entry: %Entry{home: :global} = entry, value: value}, state),
    do: put_in(state.global[entry.key], value)

  defp write(%{entry: %Entry{home: :session} = entry, value: value}, state) do
    state = put_in(state.session[entry.key], value)

    if entry.key in ["session.model", "session.sub_agent_model"],
      do: %{state | flag_model: nil},
      else: state
  end

  defp write(%{entry: %Entry{home: :project} = entry, value: value, target: target}, state) do
    field = Map.fetch!(@project_fields, entry.key)
    id = target.project_id

    update_in(state.records["project"][id], fn project ->
      project = Map.put(project, field, value)

      case {field, value} do
        {"trusted", true} ->
          Map.put(project, "trusted_at", state.now)

        {"trusted", false} ->
          Map.merge(project, %{"trusted_at" => nil, "approval_mode" => "read_only"})

        _ ->
          project
      end
    end)
  end

  # values.reset: a patch whose values are the reset values (§3.3.4).
  defp reset(state, params) do
    attributes = params["attributes"] || %{}

    entries =
      cond do
        is_list(attributes["keys"]) ->
          for key <- attributes["keys"], {:ok, entry} <- [Registry.fetch(key)], do: entry

        is_binary(attributes["section"]) ->
          Registry.for_section(Sections.from_wire(attributes["section"]))

        attributes["scope"] == "all" ->
          Registry.all()

        true ->
          []
      end

    changes =
      for entry <- entries,
          Entry.writable?(entry),
          entry.resettable,
          do: %{"key" => entry.key, "value" => reset_value(entry), "target" => nil}

    if changes == [] do
      {state, result("unchanged"), []}
    else
      apply_changes(state, changes, params["expected"] || %{}, params["dry_run"] == true)
    end
  end

  defp reset_value(%Entry{key: "session.mode"}), do: "build"
  defp reset_value(%Entry{nullable: true}), do: nil
  defp reset_value(%Entry{default: default}), do: default

  # profile.apply: the project file's profile onto this conversation.
  @profile_keys %{
    "effort" => "session.effort",
    "swarm_effort" => "session.sub_agent_effort",
    "model" => "session.model",
    "swarm_model" => "session.sub_agent_model"
  }

  defp profile(state, params) do
    name = get_in(params, ["attributes", "name"])
    profiles = Map.get(state.profiles, state.project_id, %{})

    case Map.fetch(profiles, name || "") do
      {:ok, profile} ->
        changes =
          for {field, key} <- @profile_keys, Map.has_key?(profile, field) do
            %{"key" => key, "value" => profile[field], "target" => nil}
          end

        expected = Map.new(changes, &{&1["key"], %{"$any" => true}})
        apply_changes(state, changes, expected, params["dry_run"] == true)

      :error ->
        available = profiles |> Map.keys() |> Enum.sort() |> Enum.join(", ")

        {state,
         result("rejected", message: "Unknown profile \"#{name}\" — available: #{available}"), []}
    end
  end

  defp cancel(state, params) do
    id = get_in(params, ["target", "task_id"])

    case Map.get(state.tasks, id || "") do
      nil ->
        {state, result("not_found", message: "that task is not running"), []}

      %{state: "running", cancellable: false} ->
        {state, result("rejected", message: "this task can't be stopped"), []}

      %{state: "running"} = task ->
        task = %{task | state: "cancelled", message: "cancelled"}
        {put_in(state.tasks[id], task), result("accepted"), [task_delta(task)]}

      _task ->
        {state, result("unchanged"), []}
    end
  end

  ## -------------------------------------------------------------- controls

  @doc false
  @spec control(state(), atom(), list()) :: {term(), state(), list()}
  def control(state, :put, [key, value]) when is_binary(key) do
    case Registry.fetch(key) do
      {:ok, entry} when entry.home in [:global, :session] or is_map_key(@project_fields, key) ->
        change = %{entry: entry, value: value, target: %{project_id: state.project_id}}
        state = write(change, state)
        elsewhere(state, [Atom.to_string(entry.section)])

      _ ->
        {{:error, :unknown_key}, state, []}
    end
  end

  def control(state, :put, [{kind, id, field}, value]) do
    state =
      update_in(state.records, fn records ->
        Map.update(records, kind, %{id => %{"id" => id, field => value}}, fn items ->
          Map.update(items, id, %{"id" => id, field => value}, &Map.put(&1, field, value))
        end)
      end)

    elsewhere(state, [])
  end

  def control(state, :fail_next, [action, reply]),
    do: {:ok, put_in(state.fail_next[action], reply), []}

  def control(state, :hold_task, [action]),
    do: {:ok, %{state | holds: MapSet.put(state.holds, action)}, []}

  def control(state, :release_task, [action, result]) do
    outcome = if match?({:error, _}, result), do: result, else: {:ok, result || %{}}
    state = %{state | holds: MapSet.delete(state.holds, action)}

    {state, deltas} =
      state
      |> running(&(&1.action == action))
      |> Enum.reduce({state, []}, fn task, {acc, deltas} ->
        {acc, more} = finish(acc, task.id, outcome)
        {acc, deltas ++ more}
      end)

    {:ok, state, deltas}
  end

  def control(state, :reply_outcome_next, [status]),
    do: {:ok, %{state | outcome_next: status}, []}

  def control(state, :stub_reply, [action, reply]),
    do: {:ok, put_in(state.stubs[action], reply), []}

  def control(state, :requests, []), do: {Enum.reverse(state.requests), state, []}
  def control(state, :secret_writes, []), do: {Enum.reverse(state.secret_writes), state, []}
  def control(state, :state, []), do: {state, state, []}

  def control(state, :step, []) do
    {state, deltas} =
      state
      |> running(&(not MapSet.member?(state.holds, &1.action)))
      |> Enum.reduce({state, []}, fn task, {acc, deltas} ->
        {acc, more} = finish(acc, task.id, :run)
        {acc, deltas ++ more}
      end)

    {:ok, state, deltas}
  end

  def control(state, _op, _args), do: {{:error, :unknown_control}, state, []}

  defp elsewhere(state, sections) do
    state = %{state | revision: state.revision + 1}

    {:ok, state,
     [
       {:settings_update,
        %{"revision" => state.revision, "sections" => sections, "origin" => "elsewhere"}}
     ]}
  end

  ## ------------------------------------------------------------------ wire

  defp snapshot(view, body, revision, request_id),
    do: %{
      "request_id" => request_id,
      "view" => view,
      "revision" => revision,
      "available" => true,
      "message" => nil,
      "body" => body
    }

  defp unavailable(view, message, revision, request_id),
    do: %{
      "request_id" => request_id,
      "view" => view,
      "revision" => revision,
      "available" => false,
      "message" => message,
      "body" => nil
    }

  defp result(status, opts \\ []) do
    %{
      "status" => status,
      "results" => Keyword.get(opts, :results, []),
      "record" => Keyword.get(opts, :record),
      "task" => nil,
      "message" => Keyword.get(opts, :message),
      "confirm" => nil,
      "field_errors" => Keyword.get(opts, :field_errors, [])
    }
  end

  defp result_value(reply, revision, request_id) do
    reply = Map.new(reply, fn {k, v} -> {to_string(k), wire_atom(v)} end)

    "status"
    |> result()
    |> Map.merge(%{"status" => "accepted", "request_id" => request_id, "revision" => revision})
    |> Map.merge(reply)
    |> Map.update!("field_errors", fn errors ->
      Enum.map(errors || [], fn error -> Map.new(error, fn {k, v} -> {to_string(k), v} end) end)
    end)
  end

  defp wire_atom(value) when is_atom(value) and value not in [nil, true, false],
    do: Atom.to_string(value)

  defp wire_atom(value), do: value

  defp row(target, status, opts \\ []),
    do: %{
      "target" => target,
      "status" => status,
      "value" => Keyword.get(opts, :value),
      "current" => Keyword.get(opts, :current),
      "message" => Keyword.get(opts, :message)
    }

  defp ok_row(%{key: key, value: value, unchanged: true}), do: row(key, "unchanged", value: value)
  defp ok_row(%{key: key, value: value}), do: row(key, "accepted", value: value)

  defp worst(rows) do
    statuses = for %{"status" => s} <- rows, s != "skipped", do: s

    case Enum.max_by(statuses, &Enum.find_index(@order, fn o -> o == &1 end), fn ->
           "unchanged"
         end) do
      "unchanged" ->
        if Enum.all?(statuses, &(&1 == "unchanged")), do: "unchanged", else: "accepted"

      status ->
        status
    end
  end

  defp first_message(rows), do: Enum.find_value(rows, & &1["message"])

  defp decode_snapshot(value, request) do
    case DTO.SettingsSnapshot.decode(value) do
      {:ok, dto} -> %{dto | request_id: request.request_id}
      {:error, _} -> {:settings_failed, request.request_id, "Couldn't read settings right now."}
    end
  end

  defp decode_result(value, request) do
    case DTO.SettingsResult.decode(value) do
      {:ok, dto} -> %{dto | request_id: request.request_id}
      {:error, _} -> {:settings_failed, request.request_id, "Couldn't read settings right now."}
    end
  end

  defp short_json(value) do
    case Jason.encode(value) do
      {:ok, json} -> String.slice(json, 0, 40)
      _ -> "?"
    end
  end

  ## ------------------------------------------------------------ the logs

  defp log(state, op, params) do
    params =
      case params do
        %{"secrets" => secrets} when is_list(secrets) ->
          %{params | "secrets" => Enum.map(secrets, &Map.put(&1, "value", "[REDACTED]"))}

        params ->
          params
      end

    %{state | requests: Enum.take([Map.put(params, "op", op) | state.requests], @max_log)}
  end

  defp note_secrets(state, params) do
    writes =
      for %{"slot" => slot, "value" => value} <- params["secrets"] || [] do
        {params["action"], slot, :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)}
      end

    %{state | secret_writes: Enum.take(Enum.reverse(writes) ++ state.secret_writes, @max_log)}
  end
end
