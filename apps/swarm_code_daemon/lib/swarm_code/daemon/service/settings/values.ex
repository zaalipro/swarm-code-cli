defmodule SwarmCode.Daemon.Service.Settings.Values do
  @moduledoc """
  The scalar settings (pass 74, spec §3.3.3–3.3.4): the `values` view and the
  `values.patch`, `values.reset` and `profile.apply` commands.

  A snapshot reads once per request, fresh: the settings row (never
  `Settings.get/0`, which inserts a missing row — D24; no row reads as the
  defaults), the context conversation, the page's project, its project file and
  the session environment. Every scalar entry except the terminal's own becomes a
  SettingValue with its layers (ignored ones included, D40), winner, base (the
  compare-and-set token: the stored value, raw when it is not valid here — D34)
  and choices.

  A write is all or nothing per request: every change is checked (registry,
  scope, target, validators, service checks), then one `Repo.transaction`
  re-reads, compares each change with the fresh stored value and writes through
  the domain changesets. Caches are invalidated again after the commit (M2): a
  reader that cached the old row between the domain's own invalidation and the
  commit would keep it otherwise.
  """
  @behaviour SwarmCode.Daemon.Service.Settings.Handler

  import Ecto.Query, only: [from: 2]
  require Logger

  alias SwarmCode.Daemon.Service.SessionConfiguration
  alias SwarmCode.Daemon.Service.Settings.{Command, Context, Error, Layers, Result}
  alias SwarmCode.Domain.{Cache, Conversations, Projects, Providers, Repo, Research, Settings}
  alias SwarmCode.Domain.Conversations.Conversation
  alias SwarmCode.Domain.LLM.Efforts
  alias SwarmCode.Domain.Settings.Setting
  alias SwarmCode.Domain.Tools.CommandSafety
  alias SwarmCode.Settings.{Entry, Registry, Sections, SecretPattern, TextValue, Validate}
  alias SwarmCode.Settings.WireValue

  @project_config SwarmCode.Daemon.Service.Settings.ProjectConfig
  @compile {:no_warn_undefined, [@project_config]}

  @config_file ".swarm_code/config.json"
  @file_limit 1_048_576
  @max_changes 256
  @unavailable "This part of settings is not available in this build."
  @session_only "only this session's conversation can be changed here"
  @project_gone "That project no longer exists"

  @impl true
  def actions, do: ~w(values.patch values.reset profile.apply)

  @impl true
  def views, do: [{"values", nil}]

  ## ------------------------------------------------------------------ query

  @impl true
  def query("values", _kind, params, %Context{} = ctx) do
    project_id = params["project_id"] || context_project_id(ctx)
    sections = section_filter(params["sections"])
    keys = params["keys"]

    entries =
      for entry <- snapshot_entries(),
          is_nil(sections) or entry.section in sections,
          is_nil(keys) or entry.key in keys,
          do: entry

    {:ok, body(ctx, entries, project_id)}
  end

  def query(_view, _kind, _params, _ctx), do: {:error, Error.unsupported()}

  @doc "The values body of `entries` (every snapshot entry by default) for `project_id`."
  @spec body(Context.t(), [Entry.t()] | :all, String.t() | nil) :: map()
  def body(ctx, entries \\ :all, project_id \\ nil) do
    entries = if entries == :all, do: snapshot_entries(), else: entries
    project_id = project_id || context_project_id(ctx)
    reads = read(ctx, project_id)

    %{
      "values" => Enum.map(entries, &setting_value(&1, reads)),
      "project_id" => reads.project && reads.project.id,
      "conversation_id" => reads.conversation && reads.conversation.id
    }
  end

  @doc "The entries a values snapshot carries: every scalar except the terminal's (cli.json) own."
  @spec snapshot_entries() :: [Entry.t()]
  def snapshot_entries, do: for(e <- Registry.all(), Entry.scalar?(e), e.scope != :cli, do: e)

  defp section_filter(nil), do: nil
  defp section_filter(list) when is_list(list), do: Enum.map(list, &Sections.from_wire/1)

  defp context_project_id(%Context{project: %{id: id}}), do: id
  defp context_project_id(_ctx), do: nil

  ## ------------------------------------------------------------------ reads

  @doc false
  def read(ctx, project_id) do
    row = settings_row()
    conversation = fresh_conversation(ctx)

    project =
      case project_id do
        id when is_binary(id) -> Projects.get(id)
        _ -> nil
      end

    %{
      row: row,
      setting: row || %Setting{},
      conversation: conversation,
      project: project,
      file: project_file(project),
      env: ctx.env || %{},
      override: ctx.override
    }
  end

  @doc "The settings row, fresh; nil when there is none (never inserted on a read, D24)."
  @spec settings_row() :: Setting.t() | nil
  def settings_row, do: Repo.one(from(s in Setting, order_by: s.inserted_at, limit: 1))

  defp fresh_conversation(%Context{conversation: %{id: id}}) when is_binary(id),
    do: Conversations.get(id)

  defp fresh_conversation(_ctx), do: nil

  @doc "The project file's top-level JSON object (nil when absent or unreadable)."
  @spec project_file(struct() | nil) :: map() | nil
  def project_file(%{root_path: root}) when is_binary(root) do
    path = Path.join(root, @config_file)

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @file_limit <-
           File.stat(path),
         {:ok, data} <- File.read(path),
         {:ok, map} when is_map(map) <- Jason.decode(data) do
      map
    else
      _ -> nil
    end
  end

  def project_file(_project), do: nil

  ## ------------------------------------------------------------- the values

  @doc false
  def setting_value(%Entry{} = entry, reads) do
    {stored, available?} = stored(entry, reads)
    stored = if available?, do: WireValue.normalize(entry, wire(stored)), else: nil
    invalid? = available? and stored != nil and not WireValue.type_ok?(entry, stored)

    layers = Enum.map(entry.layers, &layer(entry, &1, stored, invalid?, reads))
    choices = choices(entry, reads)
    {state, note} = state(entry, stored, invalid?, choices, reads)

    opts = [base: if(entry.home, do: stored), choices: choices, state: state, note: note]
    opts = if invalid?, do: Keyword.put(opts, :invalid_raw, stored), else: opts
    Layers.setting_value(entry, layers, opts)
  end

  # The stored wire value of an entry at its home, and whether its home exists
  # (a session entry without a conversation, a project entry without a project).
  defp stored(%Entry{storage: {:setting, field}}, reads),
    do: {Map.get(reads.setting, field), true}

  defp stored(%Entry{storage: {:setting_pair, pf, mf}}, reads),
    do: {pair(Map.get(reads.setting, pf), Map.get(reads.setting, mf)), true}

  defp stored(%Entry{storage: {:setting_map, field, key}}, reads),
    do: {Map.get(Map.get(reads.setting, field) || %{}, key), true}

  defp stored(%Entry{home: :session}, %{conversation: nil}), do: {nil, false}

  defp stored(%Entry{storage: {:conversation, field}}, reads),
    do: {Map.get(reads.conversation, field), true}

  defp stored(%Entry{storage: {:conversation_pair, pf, mf}}, reads),
    do: {pair(Map.get(reads.conversation, pf), Map.get(reads.conversation, mf)), true}

  defp stored(%Entry{storage: :conversation_pinned}, reads),
    do: {reads.conversation.pinned_at != nil, true}

  defp stored(%Entry{storage: {:conversation_mode}}, reads),
    do: {current_mode(reads.conversation), true}

  defp stored(%Entry{home: :project}, %{project: nil}), do: {nil, false}

  defp stored(%Entry{storage: {:project, field}}, reads),
    do: {Map.get(reads.project, field), true}

  defp stored(%Entry{storage: :project_trust}, reads), do: {reads.project.trusted_at != nil, true}

  defp stored(%Entry{storage: {:project_file_key, :denied}}, %{file: file}) when is_map(file) do
    denied = SwarmCode.Settings.Registry.ProjectFile.denied_keys()
    {Enum.filter(Map.keys(file), &(&1 in denied)) |> Enum.sort(), true}
  end

  defp stored(%Entry{storage: {:project_file_key, key}}, %{file: file}) when is_map(file),
    do: {Map.get(file, key), Map.has_key?(file, key)}

  defp stored(_entry, _reads), do: {nil, false}

  defp pair(nil, _model), do: nil
  defp pair(_provider, nil), do: nil
  defp pair(provider, model), do: %{"provider_id" => provider, "model" => model}

  defp wire(value), do: SwarmCode.Daemon.Service.Settings.Wire.json(value)

  @doc "The mode of a conversation, in `current_mode/1`'s order (D35)."
  @spec current_mode(struct()) :: String.t()
  def current_mode(conversation) do
    cond do
      conversation.consensus -> "consensus"
      conversation.ultra -> "ultra"
      conversation.authoring_workflow -> "workflow"
      conversation.mode == "plan" -> "plan"
      true -> "build"
    end
  end

  @doc "The four mode columns of a mode (`CommandDispatcher.mode_fields/1`, copied by value)."
  @spec mode_fields(String.t()) :: map()
  def mode_fields(mode),
    do: %{
      mode: if(mode == "plan", do: "plan", else: "build"),
      ultra: mode == "ultra",
      consensus: mode == "consensus",
      authoring_workflow: mode == "workflow"
    }

  ## ----------------------------------------------------------------- layers

  defp layer(%Entry{} = entry, :flag, _stored, _invalid?, reads) do
    case reads.override do
      %{provider_id: id, model: model}
      when entry.key in ["session.model", "session.sub_agent_model"] ->
        Layers.layer(:flag, %{"provider_id" => id, "model" => model},
          source: "--model",
          note: "for this launch only"
        )

      _ ->
        Layers.unset(:flag)
    end
  end

  defp layer(%Entry{} = entry, :env, _stored, _invalid?, reads) do
    case Enum.find(entry.env, &Map.has_key?(reads.env, &1)) do
      nil ->
        Layers.unset(:env)

      name ->
        raw = Map.fetch!(reads.env, name)

        cond do
          SecretPattern.secret_name?(name) ->
            Layers.layer(:env, nil, source: name)

          true ->
            case TextValue.parse(entry, raw) do
              {:ok, value} when not is_tuple(value) ->
                if WireValue.type_ok?(entry, value) and Validate.check(entry, value) == :ok,
                  do: Layers.layer(:env, value, source: name),
                  else: Layers.ignored(:env, raw, "not a valid value here; ignored", source: name)

              _ ->
                Layers.ignored(:env, raw, "not a valid value here; ignored", source: name)
            end
        end
    end
  end

  defp layer(%Entry{home: home} = entry, layer, stored, invalid?, reads)
       when layer == home and layer in [:session, :project, :global] do
    cond do
      invalid? -> Layers.invalid(layer, stored)
      home_set?(entry, stored, reads) -> Layers.layer(layer, stored)
      true -> Layers.unset(layer)
    end
  end

  # A session entry's global layer is the default it follows (§2.2).
  defp layer(%Entry{follows: follows}, :global, _stored, _invalid?, reads)
       when is_binary(follows) do
    with {:ok, followed} <- Registry.fetch(follows),
         {value, true} <- stored(followed, reads),
         value when value != nil <- WireValue.normalize(followed, wire(value)) do
      Layers.layer(:global, value)
    else
      _ -> Layers.unset(:global)
    end
  end

  defp layer(%Entry{storage: {:project_file_key, _}}, :project_file, stored, _invalid?, reads) do
    if is_map(reads.file) and stored != nil,
      do: Layers.layer(:project_file, stored, source: @config_file),
      else: Layers.unset(:project_file)
  end

  defp layer(%Entry{ignored_layers: ignored}, :project_file, _stored, _invalid?, reads) do
    file = reads.file || %{}

    case Enum.find(ignored, fn {layer, key} ->
           layer == :project_file and Map.has_key?(file, key)
         end) do
      {_, key} ->
        Layers.ignored(:project_file, Map.get(file, key), "SwarmCode ignores this key",
          source: @config_file
        )

      nil ->
        Layers.unset(:project_file)
    end
  end

  defp layer(%Entry{default: default}, :default, _stored, _invalid?, _reads),
    do: Layers.layer(:default, default)

  defp layer(_entry, layer, _stored, _invalid?, _reads), do: Layers.unset(layer)

  # §3.3.3: global when the column differs from the default (nullable: non-nil;
  # map entries: present); session when the column is non-nil (mode: not build;
  # pinned: pinned); project always.
  defp home_set?(%Entry{home: :project}, _stored, %{project: project}), do: project != nil
  defp home_set?(%Entry{home: :session}, _stored, %{conversation: nil}), do: false
  defp home_set?(%Entry{key: "session.mode"}, stored, _reads), do: stored not in [nil, "build"]
  defp home_set?(%Entry{storage: :conversation_pinned}, stored, _reads), do: stored == true
  defp home_set?(%Entry{home: :session}, stored, _reads), do: stored != nil
  defp home_set?(%Entry{storage: {:setting_map, _, _}}, stored, _reads), do: stored != nil
  defp home_set?(%Entry{nullable: true}, stored, _reads), do: stored != nil

  defp home_set?(%Entry{} = entry, stored, _reads),
    do: not WireValue.equal?(stored, entry.default)

  ## ---------------------------------------------------------------- choices

  defp choices(%Entry{dynamic_choices: {:effort_of, source}} = entry, reads) do
    {provider, model} = effort_model(source, reads)

    levels =
      for level <- Efforts.levels(provider, model),
          do: %{"value" => level["key"], "label" => level["label"], "hint" => level["hint"]}

    levels =
      if entry.home == :global do
        classic =
          for {value, label, hint} <- Settings.efforts(),
              do: %{"value" => value, "label" => label, "hint" => hint}

        Enum.uniq_by(levels ++ classic, & &1["value"])
      else
        levels
      end

    levels
  end

  defp choices(%Entry{key: "research.level"} = entry, _reads) do
    estimates = safe(fn -> Research.estimates() end, %{})

    for choice <- entry.choices do
      hint =
        case Map.get(estimates, choice.value) do
          %{ms: ms} when is_integer(ms) ->
            "median #{max(1, round(ms / 60_000))} min on this machine"

          _ ->
            "not measured yet"
        end

      %{"value" => choice.value, "label" => choice.label, "hint" => hint}
    end
  end

  defp choices(_entry, _reads), do: nil

  @global_models %{
    chat_default: {:default_chat_provider_id, :default_chat_model, :chat},
    swarm_default: {:default_swarm_provider_id, :default_swarm_model, :swarm},
    scheduled_default: {:default_scheduled_provider_id, :default_scheduled_model, :chat},
    workflow_default: {:default_workflow_provider_id, :default_workflow_model, :chat},
    implementer_default: {:default_implementer_provider_id, :default_implementer_model, :chat},
    research_lead: {:research_lead_provider_id, :research_lead_model, :chat},
    research_worker: {:research_worker_provider_id, :research_worker_model, :chat},
    research_reporter: {:research_reporter_provider_id, :research_reporter_model, :chat}
  }
  @session_models %{
    session_chat: :chat,
    session_swarm: :swarm,
    session_judge: :judge,
    session_implementer: :implementer
  }

  # {provider struct | nil, model | nil} of the model an effort belongs to.
  defp effort_model(source, reads) do
    case {Map.get(@global_models, source), Map.get(@session_models, source)} do
      {{pf, mf, kind}, _} ->
        resolve(Map.get(reads.setting, pf), Map.get(reads.setting, mf)) ||
          default_model(kind, reads)

      {nil, kind} when is_atom(kind) and kind != nil ->
        session_model(kind, reads)

      _ ->
        default_model(:chat, reads)
    end
    |> case do
      {provider, model} -> {provider, model}
      nil -> {nil, nil}
    end
  end

  defp resolve(provider_id, model) when is_binary(provider_id) and is_binary(model) do
    case Providers.get(provider_id) do
      nil -> nil
      provider -> {provider, model}
    end
  end

  defp resolve(_provider_id, _model), do: nil

  # Never `Providers.fallback/0`, and never on a missing settings row: the
  # domain's `effective_model/2` reads `Settings.get_cached/0`, which would
  # insert the row (D24).
  defp default_model(kind, %{row: row, setting: setting}) do
    {pf, mf} =
      if kind == :swarm,
        do: {:default_swarm_provider_id, :default_swarm_model},
        else: {:default_chat_provider_id, :default_chat_model}

    resolve(Map.get(setting, pf), Map.get(setting, mf)) ||
      if row, do: effective(%Conversation{}, kind), else: nil
  end

  defp session_model(_kind, %{conversation: nil} = reads), do: default_model(:chat, reads)

  defp session_model(kind, %{row: nil} = reads) do
    conversation = overlay(reads.conversation, reads.override)

    {pf, mf} =
      case kind do
        :chat -> {:chat_provider_id, :chat_model}
        :swarm -> {:swarm_provider_id, :swarm_model}
        :judge -> {:judge_provider_id, :judge_model}
        :implementer -> {:implementer_provider_id, :implementer_model}
      end

    resolve(Map.get(conversation, pf), Map.get(conversation, mf)) || default_model(:chat, reads)
  end

  defp session_model(kind, reads),
    do:
      effective(overlay(reads.conversation, reads.override), kind) || default_model(:chat, reads)

  defp overlay(conversation, %{provider_id: id, model: model}),
    do: %{
      conversation
      | chat_provider_id: id,
        chat_model: model,
        swarm_provider_id: id,
        swarm_model: model
    }

  defp overlay(conversation, _override), do: conversation

  defp effective(conversation, kind) do
    case safe(fn -> Providers.effective_model(conversation, kind) end, nil) do
      {:ok, %{provider: provider, model: model}} -> {provider, model}
      %{provider: provider, model: model} -> {provider, model}
      _ -> nil
    end
  end

  ## ------------------------------------------------------------------ state

  @pair_entries ~w(models.chat models.sub_agent models.scheduled models.workflow models.implementer
                   research.lead_model research.worker_model research.reporter_model)

  defp state(_entry, _stored, true, _choices, _reads), do: {"invalid", nil}

  # AT4: a default model whose provider is gone.
  defp state(%Entry{key: key} = entry, %{"provider_id" => id}, false, _choices, _reads)
       when key in @pair_entries do
    if Providers.get(id) == nil,
      do: {"attention", "The #{String.downcase(entry.label)} points to a provider that is gone"},
      else: {"ok", scheduler_note(entry)}
  end

  # AT16: an effort that is not a level of its model.
  defp state(%Entry{dynamic_choices: {:effort_of, source}} = entry, stored, false, choices, reads)
       when is_binary(stored) and is_list(choices) do
    if Enum.any?(choices, &(&1["value"] == stored)) do
      {"ok", scheduler_note(entry)}
    else
      {provider, model} = effort_model(source, reads)
      used = Efforts.normalise_key(stored, provider, model)
      {"attention", "#{stored} is not a level of #{model || "the model"}; turns use #{used}"}
    end
  end

  defp state(entry, _stored, false, _choices, _reads), do: {"ok", scheduler_note(entry)}

  defp scheduler_note(%Entry{scheduler_only: true}),
    do: "schedules run only while the desktop app runs"

  defp scheduler_note(_entry), do: nil

  ## --------------------------------------------------------------- commands

  @impl true
  def command(%Command{action: "values.patch"} = cmd, %Context{} = ctx) do
    changes = get(cmd.attributes, "changes")

    if is_list(changes) and changes != [] and length(changes) <= @max_changes do
      apply_changes(changes, cmd.expected || %{}, cmd.dry_run, ctx)
    else
      {:error, Error.new(:invalid, "changes must list 1 to #{@max_changes} settings")}
    end
  end

  def command(%Command{action: "values.reset"} = cmd, %Context{} = ctx) do
    entries =
      case cmd.attributes do
        %{"keys" => keys} when is_list(keys) ->
          for key <- keys, {:ok, entry} <- [Registry.fetch(key)], do: entry

        %{"section" => section} when is_binary(section) ->
          case Sections.from_wire(section) do
            nil -> []
            id -> Registry.for_section(id)
          end

        %{"scope" => "all"} ->
          Registry.all()

        _ ->
          []
      end

    changes =
      for entry <- entries,
          entry.scope != :cli,
          Entry.writable?(entry),
          entry.resettable,
          do: %{"key" => entry.key, "value" => reset_value(entry), "target" => nil}

    cond do
      changes == [] -> {:ok, %Result{status: :unchanged}}
      length(changes) > @max_changes -> {:error, Error.new(:invalid, "too many settings")}
      true -> apply_changes(changes, cmd.expected || %{}, cmd.dry_run, ctx)
    end
  end

  def command(%Command{action: "profile.apply"} = cmd, %Context{} = ctx) do
    name = get(cmd.attributes, "name")
    conversation = fresh_conversation(ctx)
    wanted = get(cmd.target, "conversation_id")

    cond do
      conversation == nil or (wanted != nil and wanted != conversation.id) ->
        {:error, Error.new(:invalid, @session_only)}

      true ->
        profiles = profiles(ctx.project)

        case Map.fetch(profiles, name || "") do
          {:ok, profile} -> apply_profile(conversation, profile, cmd.dry_run)
          :error -> {:error, Error.new(:invalid, unknown_profile(name, profiles))}
        end
    end
  end

  def command(_cmd, _ctx), do: {:error, Error.unsupported()}

  @doc "The reset value of an entry (§3.3.4)."
  @spec reset_value(Entry.t()) :: term()
  def reset_value(%Entry{key: "session.mode"}), do: "build"
  def reset_value(%Entry{nullable: true}), do: nil
  def reset_value(%Entry{default: default}), do: default

  defp unknown_profile(name, profiles) do
    available = profiles |> Map.keys() |> Enum.sort() |> Enum.join(", ")
    ~s(Unknown profile "#{name}" — available: #{available})
  end

  ## -------------------------------------------------------- change checking

  defp apply_changes(changes, expected, dry_run?, ctx) do
    with :ok <- expected_listed(changes, expected) do
      checked = Enum.map(changes, &check_change(&1, ctx))

      if Enum.any?(checked, &match?({:error, _}, &1)) do
        {:ok, failed_result(checked)}
      else
        prepared = for {:ok, change} <- checked, do: change

        {db, file} =
          Enum.split_with(prepared, &(not match?({:project_file_key, _}, &1.entry.storage)))

        write(db, file, expected, dry_run?, ctx)
      end
    end
  end

  defp expected_listed(changes, expected) when is_map(expected) do
    case Enum.find(changes, &(not Map.has_key?(expected, get(&1, "key")))) do
      nil -> :ok
      change -> {:error, Error.new(:invalid, "expected is missing for #{get(change, "key")}")}
    end
  end

  defp expected_listed(_changes, _expected),
    do: {:error, Error.new(:invalid, "expected must be a map")}

  defp check_change(change, ctx) when is_map(change) do
    key = get(change, "key")

    with {:ok, entry} <- fetch_entry(key),
         :ok <- scope_ok(entry, get(change, "value")),
         {:ok, target} <- resolve_target(entry, get(change, "target") || %{}, ctx),
         value = Validate.normalise(entry, get(change, "value")),
         :ok <- validate(entry, value),
         :ok <- svc_checks(entry, value, target, ctx) do
      {:ok, %{key: key, entry: entry, value: value, target: target}}
    else
      {:error, status, message} -> {:error, Result.row(to_string(key), status, message: message)}
    end
  end

  defp check_change(_change, _ctx),
    do: {:error, Result.row("?", :rejected, message: "not a setting: ?")}

  defp fetch_entry(key) when is_binary(key) do
    case Registry.fetch(key) do
      {:ok, entry} -> {:ok, entry}
      _ -> {:error, :rejected, "not a setting: #{key}"}
    end
  end

  defp fetch_entry(key), do: {:error, :rejected, "not a setting: #{inspect(key)}"}

  defp scope_ok(%Entry{scope: :cli}, _value),
    do: {:error, :rejected, "this setting lives in cli.json and is written by the terminal"}

  # The project file's keys can only be removed (S2 `ProjectConfig`).
  defp scope_ok(%Entry{storage: {:project_file_key, key}}, nil) when is_binary(key), do: :ok

  defp scope_ok(%Entry{storage: {:project_file_key, _}}, _value),
    do: {:error, :rejected, "read-only"}

  defp scope_ok(entry, _value),
    do: if(Entry.writable?(entry), do: :ok, else: {:error, :rejected, "read-only"})

  defp resolve_target(%Entry{home: :session}, target, ctx) do
    case {fresh_conversation(ctx), get(target, "conversation_id")} do
      {nil, _} -> {:error, :rejected, @session_only}
      {conversation, id} when id in [nil, conversation.id] -> {:ok, %{conversation: conversation}}
      _ -> {:error, :rejected, @session_only}
    end
  end

  defp resolve_target(%Entry{home: :project}, target, ctx),
    do: project_target(get(target, "project_id") || context_project_id(ctx), ctx)

  defp resolve_target(%Entry{storage: {:project_file_key, _}}, target, ctx),
    do: project_target(get(target, "project_id") || context_project_id(ctx), ctx)

  defp resolve_target(_entry, _target, _ctx), do: {:ok, %{}}

  defp project_target(id, ctx) when is_binary(id) do
    case Projects.get(id) do
      %{scratch: true} = project ->
        if id == context_project_id(ctx),
          do: {:ok, %{project: project}},
          else: {:error, :not_found, @project_gone}

      nil ->
        {:error, :not_found, @project_gone}

      project ->
        {:ok, %{project: project}}
    end
  end

  defp project_target(_id, _ctx), do: {:error, :not_found, @project_gone}

  defp validate(entry, value) do
    case Validate.check(entry, value) do
      :ok -> :ok
      {:error, message} -> {:error, :rejected, message}
    end
  end

  defp svc_checks(entry, value, target, ctx) do
    Enum.reduce_while(Validate.svc_checks(entry), :ok, fn check, :ok ->
      case svc_check(check, entry, value, target, ctx) do
        :ok -> {:cont, :ok}
        {:error, message} -> {:halt, {:error, :rejected, message}}
      end
    end)
  end

  defp svc_check(:provider_exists, entry, %{"provider_id" => id}, _target, _ctx) do
    if Providers.get(id), do: :ok, else: {:error, message(entry, :provider_exists)}
  end

  defp svc_check(
         :effort_of_model,
         %Entry{dynamic_choices: {:effort_of, _}} = entry,
         value,
         target,
         ctx
       )
       when is_binary(value) do
    reads =
      read(
        %{ctx | conversation: Map.get(target, :conversation, ctx.conversation)},
        context_project_id(ctx)
      )

    levels = entry |> choices(reads) |> Enum.map(& &1["value"])

    if value in levels do
      :ok
    else
      {_provider, model} = effort_model(elem(entry.dynamic_choices, 1), reads)
      {:error, "is not a level of #{model || "the model"}: #{Enum.join(levels, ", ")}"}
    end
  end

  defp svc_check(:executable_path, entry, path, _target, _ctx) when is_binary(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, mode: mode}} ->
        if Bitwise.band(mode, 0o111) != 0,
          do: :ok,
          else: {:error, message(entry, :executable_path)}

      _ ->
        {:error, Map.get(entry.messages, :not_a_file, "is not a file on this machine")}
    end
  end

  defp svc_check(:known_checks, entry, checks, _target, _ctx) when is_list(checks) do
    known = Enum.map(entry.choices, & &1.value)

    case Enum.find(checks, &(&1 not in known)) do
      nil -> :ok
      key -> {:error, String.replace(message(entry, :known_checks), "{key}", to_string(key))}
    end
  end

  defp svc_check(:not_dangerous, entry, commands, _target, _ctx) when is_list(commands) do
    if Enum.any?(commands, &(CommandSafety.classify(&1) == :dangerous)),
      do: {:error, message(entry, :not_dangerous)},
      else: :ok
  end

  defp svc_check(:not_scratch, entry, commands, %{project: %{scratch: true}}, _ctx)
       when is_list(commands) and commands != [],
       do: {:error, message(entry, :not_scratch)}

  defp svc_check(:combo_conflict, entry, combo, _target, _ctx) when is_binary(combo) do
    bindings = Settings.effective_keybindings(settings_row() || %Setting{})
    {:setting_map, _field, action} = entry.storage

    case Enum.find(bindings, fn {other, bound} -> other != action and bound == combo end) do
      nil ->
        :ok

      {other, _} ->
        {:error,
         message(entry, :combo_conflict)
         |> String.replace("{a}", action)
         |> String.replace("{b}", to_string(other))
         |> String.replace("{combo}", combo)}
    end
  end

  defp svc_check(_check, _entry, _value, _target, _ctx), do: :ok

  defp message(%Entry{messages: messages}, key), do: Map.get(messages, key, "is invalid")

  defp failed_result(checked) do
    rows =
      Enum.map(checked, fn
        {:error, row} -> row
        {:ok, change} -> Result.row(change.key, :skipped)
      end)

    %Result{status: Result.worst(rows), results: rows, message: first_message(rows)}
  end

  defp first_message(rows), do: Enum.find_value(rows, & &1.message)

  ## ------------------------------------------------------------------ write

  defp write(db, file, expected, dry_run?, ctx) do
    tx =
      Repo.retry(:settings_values, fn ->
        Repo.transaction(fn -> write_in_transaction(db, expected, dry_run?, ctx) end)
      end)

    case tx do
      {:ok, %{rows: rows, written: written}} ->
        after_commit(written, db, dry_run?)
        file_rows = write_file(file, expected, dry_run?)
        rows = rows ++ file_rows
        {:ok, %Result{status: Result.worst(rows), results: rows, message: first_message(rows)}}

      {:error, {:conflict, rows}} ->
        {:ok, %Result{status: :conflict, results: rows, message: "changed elsewhere; reloading"}}

      {:error, {:rejected, rows}} ->
        {:ok, %Result{status: :rejected, results: rows, message: first_message(rows)}}

      {:error, :database_busy} ->
        {:error, Error.new(:busy, "The database is busy; try again.")}

      {:error, _other} ->
        {:error, Error.unavailable()}
    end
  end

  defp write_in_transaction(db, expected, dry_run?, ctx) do
    reads = read(ctx, context_project_id(ctx))

    compared =
      Enum.map(db, fn change ->
        current = current_value(change, reads)
        want = Map.get(expected, change.key)

        cond do
          not any?(want) and not WireValue.equal?(current, want) ->
            {:conflict, change, current}

          WireValue.equal?(current, change.value) ->
            {:unchanged, change, current}

          true ->
            {:write, change, current}
        end
      end)

    if Enum.any?(compared, &match?({:conflict, _, _}, &1)) do
      rows =
        Enum.map(compared, fn
          {:conflict, change, current} -> Result.row(change.key, :conflict, current: current)
          {_, change, _} -> Result.row(change.key, :skipped)
        end)

      Repo.rollback({:conflict, rows})
    end

    writes = for {:write, change, _} <- compared, do: change
    rows = Enum.map(compared, &compared_row/1)

    written =
      if dry_run? or writes == [] do
        []
      else
        case persist(writes) do
          {:ok, written} ->
            test_seam()
            written

          {:error, key_errors} ->
            Repo.rollback({:rejected, rejected_rows(compared, key_errors)})
        end
      end

    %{rows: rows, written: written}
  end

  defp compared_row({:unchanged, change, _}),
    do: Result.row(change.key, :unchanged, value: change.value)

  defp compared_row({:write, change, _}),
    do: Result.row(change.key, :accepted, value: change.value)

  defp rejected_rows(compared, key_errors) do
    Enum.map(compared, fn {_, change, _} ->
      case Map.fetch(key_errors, change.key) do
        {:ok, message} -> Result.row(change.key, :rejected, message: message)
        :error -> Result.row(change.key, :skipped)
      end
    end)
  end

  defp any?(%{"$any" => true}), do: true
  defp any?(_), do: false

  # The fresh stored value of a change's home (raw when it is not valid here).
  defp current_value(%{entry: entry, target: target}, reads) do
    reads =
      case target do
        %{conversation: %{id: id}} -> %{reads | conversation: Conversations.get(id)}
        %{project: %{id: id}} -> %{reads | project: Projects.get(id)}
        _ -> reads
      end

    case stored(entry, reads) do
      {value, true} -> WireValue.canonical(WireValue.normalize(entry, wire(value)))
      {_, false} -> nil
    end
  end

  # Groups the writes by storage target and writes each through its domain function.
  defp persist(writes) do
    groups = Enum.group_by(writes, &group_of/1)

    Enum.reduce_while(groups, {:ok, []}, fn {group, changes}, {:ok, written} ->
      case persist_group(group, changes) do
        :ok -> {:cont, {:ok, [group | written]}}
        {:error, errors} -> {:halt, {:error, errors}}
      end
    end)
  end

  defp group_of(%{entry: %Entry{home: :global}}), do: :settings
  defp group_of(%{target: %{conversation: %{id: id}}}), do: {:conversation, id}
  defp group_of(%{target: %{project: %{id: id}}}), do: {:project, id}

  defp persist_group(:settings, changes) do
    row = settings_row() || %Setting{}

    attrs =
      Enum.reduce(changes, %{}, fn %{entry: entry, value: value}, attrs ->
        case entry.storage do
          {:setting, field} ->
            Map.put(attrs, field, value)

          {:setting_pair, pf, mf} ->
            attrs
            |> Map.put(pf, value && value["provider_id"])
            |> Map.put(mf, value && value["model"])

          {:setting_map, field, key} ->
            map = Map.get(attrs, field) || Map.get(row, field) || %{}
            map = if value == nil, do: Map.delete(map, key), else: Map.put(map, key, value)
            Map.put(attrs, field, map)
        end
      end)

    case Settings.update(attrs) do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, key_errors(changeset, changes)}
    end
  end

  defp persist_group({:conversation, _id}, [%{target: %{conversation: _}} | _] = changes) do
    conversation = Conversations.get(hd(changes).target.conversation.id)

    attrs =
      Enum.reduce(changes, %{}, fn %{entry: entry, value: value}, attrs ->
        case entry.storage do
          {:conversation, field} ->
            Map.put(attrs, field, value)

          {:conversation_pair, pf, mf} ->
            attrs
            |> Map.put(pf, value && value["provider_id"])
            |> Map.put(mf, value && value["model"])

          :conversation_pinned ->
            Map.put(attrs, :pinned_at, if(value, do: DateTime.utc_now()))

          {:conversation_mode} ->
            Map.merge(attrs, mode_fields(value))
        end
      end)

    case Conversations.update(conversation, attrs) do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, key_errors(changeset, changes)}
    end
  end

  defp persist_group({:project, _id}, [%{target: %{project: _}} | _] = changes) do
    project = Projects.get(hd(changes).target.project.id)
    {trust, fields} = Enum.split_with(changes, &(&1.entry.storage == :project_trust))

    with {:ok, project} <- trust(project, trust),
         {:ok, _} <- update_project(project, fields) do
      :ok
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, key_errors(changeset, changes)}
      {:error, _} -> {:error, Map.new(changes, &{&1.key, "is invalid"})}
    end
  end

  defp trust(project, []), do: {:ok, project}
  defp trust(project, [%{value: true} | _]), do: Projects.trust(project)

  # D13: untrusting also returns the project to read-only.
  defp trust(project, [%{value: false} | _]),
    do:
      project
      |> Ecto.Changeset.change(trusted_at: nil, approval_mode: "read_only")
      |> Repo.update()

  defp update_project(project, []), do: {:ok, project}

  defp update_project(project, fields) do
    attrs =
      Map.new(fields, fn %{entry: %{storage: {:project, field}}, value: value} ->
        {field, value}
      end)

    Projects.update(project, attrs)
  end

  # A changeset error mapped back to the registry keys of the changed columns.
  defp key_errors(changeset, changes) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Enum.reduce(opts, message, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    Enum.reduce(changes, %{}, fn change, acc ->
      message =
        change.entry
        |> columns()
        |> Enum.find_value(fn column -> errors |> Map.get(column) |> first() end)

      if message, do: Map.put(acc, change.key, message), else: acc
    end)
    |> case do
      empty when map_size(empty) == 0 -> Map.new(changes, &{&1.key, "is invalid"})
      mapped -> mapped
    end
  end

  defp first([message | _]), do: message
  defp first(_), do: nil

  defp columns(%Entry{storage: {:setting, f}}), do: [f]
  defp columns(%Entry{storage: {:setting_pair, pf, mf}}), do: [pf, mf]
  defp columns(%Entry{storage: {:setting_map, f, _}}), do: [f]
  defp columns(%Entry{storage: {:conversation, f}}), do: [f]
  defp columns(%Entry{storage: {:conversation_pair, pf, mf}}), do: [pf, mf]
  defp columns(%Entry{storage: :conversation_pinned}), do: [:pinned_at]

  defp columns(%Entry{storage: {:conversation_mode}}),
    do: [:mode, :ultra, :consensus, :authoring_workflow]

  defp columns(%Entry{storage: {:project, f}}), do: [f]
  defp columns(%Entry{storage: :project_trust}), do: [:trusted_at, :approval_mode]
  defp columns(_entry), do: []

  # §3.3.4 step 5 (M2), outside the transaction: a reader that cached the old
  # row between the domain's own invalidation and the commit is corrected here.
  defp after_commit(_written, _changes, true), do: :ok

  defp after_commit(written, changes, false) do
    if :settings in written do
      Cache.delete(:settings)
      Providers.broadcast()
    end

    if Enum.any?(written, &match?({:project, _}, &1)), do: Projects.broadcast()

    # As `/model` and `/swarm_model` do: an explicit choice ends the --model override.
    if Enum.any?(changes, &(&1.key in ["session.model", "session.sub_agent_model"])),
      do: SessionConfiguration.clear_override()

    :ok
  end

  defp test_seam do
    case Application.get_env(:swarm_code_daemon, :settings_values_seam) do
      fun when is_function(fun, 0) -> fun.()
      _ -> :ok
    end
  end

  # The project file's keys are removed by S2's `ProjectConfig` (file CAS on
  # `expected["$file"]`), after the database changes.
  defp write_file([], _expected, _dry_run?), do: []

  defp write_file([%{target: %{project: project}} | _] = changes, expected, dry_run?) do
    keys = Enum.map(changes, fn %{entry: %{storage: {:project_file_key, key}}} -> key end)

    cond do
      dry_run? ->
        Enum.map(changes, &Result.row(&1.key, :accepted))

      not Code.ensure_loaded?(@project_config) ->
        Enum.map(changes, &Result.row(&1.key, :rejected, message: @unavailable))

      true ->
        case @project_config.remove_top_level(project, keys, Map.get(expected, "$file")) do
          {:ok, _} ->
            Enum.map(changes, &Result.row(&1.key, :accepted))

          {:conflict, current} ->
            Enum.map(changes, &Result.row(&1.key, :conflict, current: current))

          {:error, message} ->
            Enum.map(changes, &Result.row(&1.key, :rejected, message: message))
        end
    end
  end

  ## ---------------------------------------------------------------- profiles

  @profile_columns %{
    "effort" => {:effort, "session.effort"},
    "swarm_effort" => {:swarm_effort, "session.sub_agent_effort"},
    "model" => {:chat_model, "session.model"},
    "swarm_model" => {:swarm_model, "session.sub_agent_model"}
  }

  # name => %{"effort" => …} from S2's ProjectConfig when present, else the file.
  defp profiles(project) do
    listed =
      if project && Code.ensure_loaded?(@project_config),
        do: safe(fn -> @project_config.profiles(project) end, nil)

    case listed do
      list when is_list(list) ->
        Map.new(list, fn profile ->
          profile = Map.new(profile, fn {k, v} -> {to_string(k), v} end)
          {profile["name"], Map.delete(profile, "name")}
        end)

      _ ->
        case project_file(project) do
          %{"profiles" => profiles} when is_map(profiles) ->
            for {name, profile} <- profiles, is_map(profile), into: %{}, do: {name, profile}

          _ ->
            %{}
        end
    end
  end

  defp apply_profile(conversation, profile, dry_run?) do
    fields =
      for {field, {column, key}} <- @profile_columns,
          value = profile[field],
          is_binary(value),
          do: {column, key, value}

    rows =
      Enum.map(fields, fn {_column, key, value} -> Result.row(key, :accepted, value: value) end)

    cond do
      fields == [] ->
        {:ok, %Result{status: :unchanged}}

      dry_run? ->
        {:ok, %Result{status: :accepted, results: rows}}

      true ->
        attrs = Map.new(fields, fn {column, _key, value} -> {column, value} end)

        case Repo.retry(:settings_values, fn -> Conversations.update(conversation, attrs) end) do
          {:ok, _} ->
            {:ok, %Result{status: :accepted, results: rows}}

          {:error, %Ecto.Changeset{}} ->
            {:error, Error.new(:invalid, "that profile has values this conversation can't take")}

          {:error, _} ->
            {:error, Error.unavailable()}
        end
    end
  end

  ## ------------------------------------------------------ attention, hygiene

  @doc """
  S1's value attention items (§2.1): AT4 (a default model's provider is gone),
  AT16 (an effort that is not a level of its model), AT18 (a stored value this
  CLI does not understand), from a values body.
  """
  @spec attention(Context.t()) :: [map()]
  @impl true
  def attention(%Context{} = ctx) do
    %{"values" => values} = body(ctx)

    for value <- values, value["state"] in ["attention", "invalid"] do
      {:ok, entry} = Registry.fetch(value["key"])

      title =
        if value["state"] == "invalid",
          do: "#{entry.label} holds a value this CLI does not understand",
          else: value["note"]

      %{
        "id" => "value:" <> entry.key,
        "severity" => "warning",
        "section" => Atom.to_string(entry.section),
        "target" => %{"key" => entry.key},
        "title" => title,
        "reason" => if(value["state"] == "invalid", do: "r resets it", else: nil)
      }
    end
  end

  @doc """
  Cache hygiene (§3.3.3): the newest `updated_at` of the settings row, providers,
  search providers and projects. When one moved since `ctx.seen` (a writer that
  sent no PubSub message), the matching cache is invalidated. Returns the new marks
  (the backend keeps them for the next snapshot).
  """
  @spec hygiene(Context.t()) :: map()
  def hygiene(%Context{seen: seen}) do
    marks = marks()
    seen = seen || %{}

    for {name, mark} <- marks, Map.get(seen, name) != nil, Map.get(seen, name) != mark do
      invalidate(name)
    end

    marks
  end

  @doc "The newest `updated_at` of each cached table."
  @spec marks() :: map()
  def marks do
    %{
      settings: max_updated(Setting),
      providers: max_updated(SwarmCode.Domain.Providers.Provider),
      search_providers: max_updated(SwarmCode.Domain.Search.SearchProvider),
      projects: max_updated(SwarmCode.Domain.Projects.Project)
    }
  end

  defp max_updated(schema), do: Repo.one(from(r in schema, select: max(r.updated_at)))

  defp invalidate(:settings), do: Cache.delete(:settings)
  defp invalidate(:providers), do: Providers.broadcast()
  defp invalidate(:search_providers), do: Cache.delete(:search_providers)
  defp invalidate(:projects), do: Projects.broadcast()

  ## --------------------------------------------------------------- helpers

  defp get(map, key) when is_map(map), do: Map.get(map, key)
  defp get(_map, _key), do: nil

  defp safe(fun, fallback) do
    fun.()
  rescue
    _ -> fallback
  catch
    :exit, _ -> fallback
  end
end
