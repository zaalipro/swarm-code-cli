defmodule SwarmCode.Daemon.Service.Settings.Providers do
  @moduledoc """
  LLM providers in settings (pass 74 §3.5.1): the provider records, their
  writes with compare-and-set, keys (a replaced key is tested before it is
  written), deletion with replacements for the defaults it serves, and the
  connection test and model fetch as backend-owned tasks.

  A key never leaves the service: records carry `api_key: {set, hint}` and a
  task message is redacted with the provider's keys.
  """

  @behaviour SwarmCode.Daemon.Service.Settings.Handler

  import Ecto.Query, warn: false, except: [update: 2]

  alias SwarmCode.Daemon.Service.Settings.{Kit, Secrets}
  alias SwarmCode.Domain.{Cache, LLM, Providers, Repo, Settings}
  alias SwarmCode.Domain.Conversations.Conversation
  alias SwarmCode.Domain.LLM.{Efforts, ProviderCaps}
  alias SwarmCode.Domain.Providers.Provider
  alias SwarmCode.Domain.Scheduled.Task, as: ScheduledTask
  alias SwarmCode.Domain.Settings.Setting

  @compile {:no_warn_undefined, [SwarmCode.Settings.Registry]}

  @actions ~w(provider.create provider.update provider.set_key provider.clear_key
              provider.delete provider.test provider.fetch_models provider.apply_models
              provider.fetch_all provider.forget_caps)

  # The registry keys of every settings pair that names a provider (§2.2,
  # §2.6), with their columns — the fallback when the core registry is not
  # loaded; `pair_columns/1` asks the registry first.
  @pairs [
    {"models.chat", :default_chat_provider_id, :default_chat_model},
    {"models.sub_agent", :default_swarm_provider_id, :default_swarm_model},
    {"models.scheduled", :default_scheduled_provider_id, :default_scheduled_model},
    {"models.workflow", :default_workflow_provider_id, :default_workflow_model},
    {"models.implementer", :default_implementer_provider_id, :default_implementer_model},
    {"research.lead_model", :research_lead_provider_id, :research_lead_model},
    {"research.worker_model", :research_worker_provider_id, :research_worker_model},
    {"research.reporter_model", :research_reporter_provider_id, :research_reporter_model}
  ]

  @editable ~w(name kind base_url models default_model fallbacks)
  @creatable @editable ++ ~w(effort_levels model_effort_levels)
  @max_models 2_000
  @test_ms 15_000
  @fetch_ms 30_000
  @fetch_all_ms 120_000

  @doc false
  def actions, do: @actions

  @doc false
  def views, do: [{"records", "providers"}, {"record", "provider"}]

  @doc false
  def cache_reads(view) when view in ["records:providers", "record:provider", "overview"],
    do: [{"provider.test", :all}, {"provider.fetch_models", :all}]

  def cache_reads("provider.apply_models"),
    do: [{"provider.fetch_models", {:param, "fetch_task_id"}}]

  def cache_reads(_other), do: []

  @doc "The registry keys of the model pairs and their settings columns."
  @spec pairs() :: [{String.t(), atom(), atom()}]
  def pairs, do: Enum.map(@pairs, fn {key, _, _} = pair -> put_columns(pair, key) end)

  defp put_columns({key, pf, mf}, key) do
    case pair_columns(key) do
      {p, m} -> {key, p, m}
      nil -> {key, pf, mf}
    end
  end

  defp pair_columns(key) do
    registry = SwarmCode.Settings.Registry

    with true <- Code.ensure_loaded?(registry),
         true <- function_exported?(registry, :fetch, 1),
         {:ok, entry} <- registry.fetch(key),
         {:setting_pair, pf, mf} <- Map.get(entry, :storage) do
      {pf, mf}
    else
      _ -> nil
    end
  end

  ## ------------------------------------------------------------ queries

  @doc false
  def query("records", "providers", params, ctx) do
    items = for p <- Providers.list(), do: Kit.record("provider", p.id, summary(p, ctx))
    {:ok, Kit.records_body("provider", items, params)}
  end

  def query("record", "provider", params, ctx) do
    case Providers.get(Kit.get(params, "id") || "") do
      nil -> gone()
      provider -> {:ok, record(provider, ctx)}
    end
  end

  def query(_view, _kind, _params, _ctx), do: unsupported()

  @doc "The `record` view of one provider (also every write's `record`)."
  @spec record(Provider.t(), map()) :: map()
  def record(%Provider{} = p, ctx) do
    fields =
      p
      |> summary(ctx)
      |> Map.merge(%{
        "models" => p.models || [],
        "effort_levels" => p.effort_levels,
        "model_effort_levels" => p.model_effort_levels || %{},
        "builtin_levels" => Efforts.defaults(p.kind, nil),
        "presets" => presets(p.kind),
        "used_by" => used_by(p.id),
        "caps" => caps(p)
      })

    Kit.record("provider", p.id, fields)
  end

  defp summary(%Provider{} = p, ctx) do
    %{
      "id" => p.id,
      "name" => p.name,
      "kind" => p.kind,
      "base_url" => p.base_url,
      "api_key" => Secrets.mask(p.api_key),
      "default_model" => p.default_model,
      "fallbacks" => p.fallbacks,
      "updated_at" => Kit.iso(p.updated_at),
      "usable" => usable?(p),
      "models_count" => length(p.models || []),
      "last_test" => ctx |> Kit.task_entry("provider.test", p.id) |> Kit.last_run(),
      "last_fetch" => ctx |> Kit.task_entry("provider.fetch_models", p.id) |> Kit.last_run()
    }
  end

  @doc "The presets of `Efforts.presets/0` whose kinds include `kind`."
  @spec presets(String.t()) :: [map()]
  def presets(kind) do
    for preset <- Efforts.presets(), kind in preset.kinds do
      %{
        "id" => preset.id,
        "name" => preset.name,
        "kinds" => preset.kinds,
        "levels" => preset.levels
      }
    end
  end

  @doc """
  Where a provider is used: the defaults and research tiers that name it
  (registry keys), and how many conversations and scheduled tasks do.
  """
  @spec used_by(String.t()) :: map()
  def used_by(id) do
    settings = settings_row()

    keys =
      for {key, pf, _mf} <- pairs(), Map.get(settings, pf) == id, do: key

    conversations =
      Repo.aggregate(
        from(c in Conversation,
          where:
            c.chat_provider_id == ^id or c.swarm_provider_id == ^id or
              c.judge_provider_id == ^id or c.implementer_provider_id == ^id
        ),
        :count,
        :id
      )

    %{
      "defaults" => Enum.filter(keys, &String.starts_with?(&1, "models.")),
      "research" => Enum.filter(keys, &String.starts_with?(&1, "research.")),
      "conversations" => conversations,
      "scheduled_tasks" =>
        Repo.aggregate(from(t in ScheduledTask, where: t.provider_id == ^id), :count, :id)
    }
  end

  defp caps(p) do
    if :ets.whereis(ProviderCaps) == :undefined do
      %{
        "effort_rejected" => false,
        "prefix_cache_rejected" => false,
        "fallbacks_rejected" => false
      }
    else
      %{
        "effort_rejected" => not ProviderCaps.effort?(p),
        "prefix_cache_rejected" => not ProviderCaps.cache_key?(p),
        "fallbacks_rejected" => not ProviderCaps.fallbacks?(p)
      }
    end
  end

  @doc """
  D11's predicate: a non-blank key, or a base URL on a private host
  (`SessionConfiguration.usable?/1` when it is public, the same rule
  otherwise).
  """
  @spec usable?(Provider.t()) :: boolean()
  def usable?(provider) do
    config = SwarmCode.Daemon.Service.SessionConfiguration

    if Code.ensure_loaded?(config) and function_exported?(config, :usable?, 1) do
      apply(config, :usable?, [provider])
    else
      (is_binary(provider.api_key) and String.trim(provider.api_key) != "") or
        (is_binary(provider.base_url) and
           SwarmCode.Domain.Tools.WebFetch.private_host?(provider.base_url))
    end
  end

  @doc "The settings row, read fresh; never inserts (D24)."
  @spec settings_row() :: Setting.t()
  def settings_row do
    Repo.one(from(s in Setting, order_by: s.inserted_at, limit: 1)) || %Setting{}
  end

  ## ------------------------------------------------------------ commands

  @doc false
  def command(%{action: action} = cmd, ctx) do
    case action do
      "provider.create" -> create(cmd, ctx)
      "provider.update" -> update(cmd, ctx)
      "provider.set_key" -> set_key(cmd, ctx)
      "provider.clear_key" -> clear_key(cmd, ctx)
      "provider.delete" -> delete(cmd)
      "provider.test" -> test(cmd)
      "provider.fetch_models" -> fetch_models(cmd)
      "provider.apply_models" -> apply_models(cmd, ctx)
      "provider.fetch_all" -> fetch_all()
      "provider.forget_caps" -> forget_caps(cmd, ctx)
      _ -> unsupported()
    end
  end

  # -- create ---------------------------------------------------------------

  defp create(cmd, ctx) do
    with {:ok, attrs} <- attributes(Kit.cmd(cmd, :attributes), @creatable),
         {:ok, key} <- optional_key(cmd) do
      attrs = Map.put(attrs, "api_key", key || "")

      if Map.get(cmd, :dry_run) do
        changeset = Provider.changeset(%Provider{}, attrs)
        if changeset.valid?, do: Kit.ok(), else: Kit.changeset_error(changeset)
      else
        case Providers.create(attrs) do
          {:ok, provider} ->
            Kit.ok(record: record(provider, ctx), message: "#{provider.name} added")

          {:error, changeset} ->
            Kit.changeset_error(changeset)
        end
      end
    end
  end

  # -- update ---------------------------------------------------------------

  defp update(cmd, ctx) do
    id = Kit.get(Kit.cmd(cmd, :target), "id")

    with {:ok, attrs} <- attributes(Kit.cmd(cmd, :attributes), @editable),
         {:ok, _expected} <- expected(cmd, "fields") do
      write(id, cmd, ctx, fn fresh ->
        if unchanged?(fresh, attrs), do: :unchanged, else: {:update, attrs}
      end)
    end
  end

  defp unchanged?(fresh, attrs) do
    current = wire_fields(fresh)
    Enum.all?(attrs, fn {k, v} -> Kit.same?(v, Map.get(current, k)) end)
  end

  # The fields a client compares against (§3.3.5): the record's own fields,
  # the key as `{set, hint}`.
  defp wire_fields(%Provider{} = p) do
    %{
      "name" => p.name,
      "kind" => p.kind,
      "base_url" => p.base_url,
      "api_key" => Secrets.mask(p.api_key),
      "models" => p.models || [],
      "default_model" => p.default_model,
      "fallbacks" => p.fallbacks,
      "effort_levels" => p.effort_levels,
      "model_effort_levels" => p.model_effort_levels || %{},
      "updated_at" => Kit.iso(p.updated_at)
    }
  end

  # One compare-and-set write of a provider row: `decide` sees the fresh row
  # inside the transaction and answers `:unchanged`, `{:update, attrs}` or
  # `{:conflict, current}`; `expected["fields"]` is compared first.
  defp write(id, cmd, ctx, decide, message \\ nil) do
    expected = Kit.cmd(cmd, :expected)

    outcome =
      Repo.retry(:settings_provider, fn ->
        Repo.transaction(fn ->
          fresh = Repo.get(Provider, id || "") || Repo.rollback(:not_found)

          case Kit.check_fields(expected, wire_fields(fresh)) do
            {:conflict, fields} ->
              Repo.rollback({:conflict, fresh, fields})

            :ok ->
              case decide.(fresh) do
                :unchanged ->
                  {:unchanged, fresh}

                {:conflict, current, target} ->
                  Repo.rollback({:conflict_value, fresh, current, target})

                {:update, attrs} ->
                  if Map.get(cmd, :dry_run),
                    do: {:dry_run, fresh},
                    else: update_or_rollback(fresh, attrs)
              end
          end
        end)
      end)

    answer(outcome, ctx, message)
  end

  defp update_or_rollback(fresh, attrs) do
    case Providers.update(fresh, attrs) do
      {:ok, provider} -> {:updated, provider}
      {:error, changeset} -> Repo.rollback({:invalid, changeset})
    end
  end

  defp answer({:ok, {:updated, provider}}, ctx, message) do
    # §3.3.5: the writers broadcast inside the transaction; again after COMMIT.
    Providers.broadcast()
    Kit.ok(record: record(provider, ctx), message: message && message.(provider))
  end

  defp answer({:ok, {:unchanged, fresh}}, ctx, _message),
    do: Kit.ok(:unchanged, record: record(fresh, ctx))

  defp answer({:ok, {:dry_run, fresh}}, ctx, _message),
    do: Kit.ok(record: record(fresh, ctx))

  defp answer({:error, :not_found}, _ctx, _message), do: gone()

  defp answer({:error, {:conflict, fresh, fields}}, ctx, _message) do
    current = wire_fields(fresh)

    Kit.ok(:conflict,
      results: for(f <- fields, do: Kit.row(f, :conflict, current: Map.get(current, f))),
      record: record(fresh, ctx),
      message: "#{fresh.name} changed while you edited it."
    )
  end

  defp answer({:error, {:conflict_value, fresh, current, target}}, ctx, _message) do
    Kit.ok(:conflict,
      results: [Kit.row(target, :conflict, current: current)],
      record: record(fresh, ctx),
      message: "#{fresh.name} changed while you edited it."
    )
  end

  defp answer({:error, {:invalid, changeset}}, _ctx, _message), do: Kit.changeset_error(changeset)
  defp answer({:error, :database_busy}, _ctx, _message), do: busy()
  defp answer({:error, other}, _ctx, _message), do: Kit.error(:unavailable, couldnt(other))

  # -- keys -----------------------------------------------------------------

  defp set_key(cmd, ctx) do
    id = Kit.get(Kit.cmd(cmd, :target), "id")
    test_first? = Kit.get(Kit.cmd(cmd, :attributes), "test_first") == true

    with {:ok, pasted} <- required_key(cmd),
         {:ok, expected_key} <- expected(cmd, "key"),
         %Provider{} = fresh <- Providers.get(id || "") || :gone do
      new = Secrets.normalise(pasted)

      cond do
        fresh.api_key == new ->
          Kit.ok(:unchanged,
            record: record(fresh, ctx),
            message: "#{fresh.name} already has that key"
          )

        not Kit.same?(expected_key, Secrets.mask(fresh.api_key)) ->
          Kit.ok(:conflict,
            results: [Kit.row("api_key", :conflict, current: Secrets.mask(fresh.api_key))],
            record: record(fresh, ctx),
            message: "#{fresh.name}'s key changed while you edited it."
          )

        test_first? ->
          test_first_task(fresh, expected_key, new)

        true ->
          write_key(id, expected_key, new, cmd, ctx, fn p -> "#{p.name} API key saved" end)
      end
    else
      :gone -> gone()
      other -> other
    end
  end

  defp write_key(id, expected_key, new, cmd, ctx, message) do
    write(
      id,
      cmd,
      ctx,
      fn fresh ->
        current = Secrets.mask(fresh.api_key)

        cond do
          not Kit.same?(expected_key, current) -> {:conflict, current, "api_key"}
          fresh.api_key == new -> :unchanged
          true -> {:update, %{"api_key" => new}}
        end
      end,
      message
    )
  end

  # §3.5.1: a replaced key is tested first; only a key the endpoint accepts is
  # written, in one compare-and-set against the key the user saw.
  defp test_first_task(%Provider{} = fresh, expected_key, new) do
    id = fresh.id
    name = fresh.name
    old = fresh.api_key

    run = fn _report ->
      started = System.monotonic_time(:millisecond)

      case LLM.list_models(%{fresh | api_key: new}) do
        {:ok, ids} ->
          ms = Kit.since(started)

          case store_tested_key(id, expected_key, new) do
            :ok -> {:ok, %{"saved" => true, "count" => length(ids), "ms" => ms, "name" => name}}
            {:error, message} -> {:error, message}
          end

        {:error, message} ->
          {:error, "The new key was refused (#{refusal(Kit.redact(message, [new, old]), name)})."}
      end
    end

    Kit.task(
      action: "provider.set_key",
      key: id,
      timeout_ms: @test_ms,
      cancellable?: true,
      kind: :plain,
      run: run,
      summary: & &1,
      redact: Enum.filter([new, old], &(is_binary(&1) and &1 != ""))
    )
  end

  defp store_tested_key(id, expected_key, new) do
    outcome =
      Repo.retry(:settings_provider, fn ->
        Repo.transaction(fn ->
          fresh = Repo.get(Provider, id) || Repo.rollback(:not_found)

          unless Kit.same?(expected_key, Secrets.mask(fresh.api_key)),
            do: Repo.rollback(:conflict)

          update_or_rollback(fresh, %{"api_key" => new})
        end)
      end)

    case outcome do
      {:ok, _} ->
        Providers.broadcast()
        :ok

      {:error, :not_found} ->
        {:error, "That provider no longer exists; nothing was saved."}

      {:error, :conflict} ->
        {:error, "The key changed while the new one was being checked; nothing was saved."}

      {:error, _other} ->
        {:error, "Couldn't save the new key right now."}
    end
  end

  @doc false
  # The words inside `The new key was refused (…).`: the status for 401 and
  # 403, else the domain's words without the provider's name.
  def refusal(message, name) do
    case Regex.run(~r/\((40[13])\)/, message) do
      [_, status] ->
        status

      nil ->
        message
        |> String.replace_prefix("#{name} ", "")
        |> String.replace(~r/\s*\((\d{3})\)/, ", \\1")
        |> String.slice(0, 200)
    end
  end

  defp clear_key(cmd, ctx) do
    id = Kit.get(Kit.cmd(cmd, :target), "id")

    with {:ok, expected_key} <- expected(cmd, "key") do
      write(
        id,
        cmd,
        ctx,
        fn fresh ->
          current = Secrets.mask(fresh.api_key)

          cond do
            not Kit.same?(expected_key, current) -> {:conflict, current, "api_key"}
            current["set"] == false -> :unchanged
            true -> {:update, %{"api_key" => ""}}
          end
        end,
        fn p -> "#{p.name} key removed" end
      )
    end
  end

  # -- delete ---------------------------------------------------------------

  defp delete(cmd) do
    id = Kit.get(Kit.cmd(cmd, :target), "id") || ""
    replacements = Kit.get(Kit.cmd(cmd, :attributes), "replacements") || %{}

    with {:ok, expected_at} <- expected(cmd, "updated_at"),
         {:ok, attrs} <- replacement_attrs(replacements, id) do
      if Map.get(cmd, :dry_run),
        do: Kit.ok(),
        else: delete_row(id, expected_at, attrs, replacements)
    end
  end

  defp delete_row(id, expected_at, attrs, replacements) do
    outcome =
      Repo.retry(:settings_provider_delete, fn ->
        Repo.transaction(fn ->
          fresh = Repo.get(Provider, id) || Repo.rollback(:not_found)

          unless Kit.same?(expected_at, Kit.iso(fresh.updated_at)),
            do: Repo.rollback({:conflict, fresh})

          if attrs != %{} do
            case Settings.update(attrs) do
              {:ok, _} -> :ok
              {:error, changeset} -> Repo.rollback({:invalid, changeset})
            end
          end

          {:ok, _} = Providers.delete(fresh)
          fresh
        end)
      end)

    case outcome do
      {:ok, deleted} ->
        Cache.delete(:settings)
        Providers.broadcast()

        last? = Providers.list() == []

        Kit.ok(
          record: nil,
          message:
            "#{deleted.name} deleted" <>
              if(last?,
                do: " · SwarmCode will have no model to talk to until you add one",
                else: ""
              ),
          results:
            for(
              {key, value} <- Enum.sort(replacements),
              do: Kit.row(key, :accepted, value: value)
            )
        )

      {:error, :not_found} ->
        gone()

      {:error, {:conflict, fresh}} ->
        Kit.ok(:conflict,
          results: [
            Kit.row("updated_at", :conflict,
              current: %{"updated_at" => Kit.iso(fresh.updated_at), "summary" => fresh.name}
            )
          ],
          message: "#{fresh.name} changed while you looked at it."
        )

      {:error, {:invalid, changeset}} ->
        Kit.changeset_error(changeset)

      {:error, :database_busy} ->
        busy()

      {:error, other} ->
        Kit.error(:unavailable, couldnt(other))
    end
  end

  # `{"models.chat": {"provider_id", "model"} | null}` → the pair columns.
  defp replacement_attrs(replacements, deleted_id) when is_map(replacements) do
    columns = Map.new(pairs(), fn {key, pf, mf} -> {key, {pf, mf}} end)

    Enum.reduce_while(replacements, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      key = to_string(key)

      case {Map.fetch(columns, key), value} do
        {:error, _} ->
          {:halt,
           Kit.error(:invalid, "not a model setting: #{key}", [
             Kit.field_error(key, "not a model setting")
           ])}

        {{:ok, {pf, mf}}, nil} ->
          {:cont, {:ok, acc |> Map.put(pf, nil) |> Map.put(mf, nil)}}

        {{:ok, {pf, mf}}, %{} = pair} ->
          provider_id = Kit.get(pair, "provider_id")
          model = Kit.string(pair, "model")

          cond do
            provider_id == deleted_id or is_nil(Providers.get(provider_id || "")) ->
              {:halt, replacement_error(key, "that provider no longer exists")}

            model in [nil, ""] ->
              {:halt, replacement_error(key, "pick a model")}

            true ->
              {:cont, {:ok, acc |> Map.put(pf, provider_id) |> Map.put(mf, model)}}
          end

        _ ->
          {:halt, replacement_error(key, "pick a model")}
      end
    end)
  end

  defp replacement_attrs(_other, _id), do: Kit.error(:invalid, "replacements must be a map")

  defp replacement_error(key, message),
    do: Kit.error(:invalid, "#{key}: #{message}", [Kit.field_error(key, message)])

  # -- test and fetch -------------------------------------------------------

  defp test(cmd) do
    target = Kit.cmd(cmd, :target)
    draft? = Kit.get(target, "draft") == true

    with {:ok, provider} <-
           test_subject(draft?, Kit.get(target, "id"), Kit.cmd(cmd, :attributes)),
         {:ok, key} <- optional_key(cmd) do
      provider = if key, do: %{provider | api_key: key}, else: provider
      secrets = Enum.filter([provider.api_key], &(is_binary(&1) and &1 != ""))

      run = fn _report ->
        started = System.monotonic_time(:millisecond)

        case LLM.list_models(provider) do
          {:ok, ids} -> {:ok, %{"count" => length(ids), "ms" => Kit.since(started)}}
          {:error, message} -> {:error, Kit.redact(message, secrets)}
        end
      end

      Kit.task(
        action: "provider.test",
        key: if(draft?, do: "draft", else: provider.id),
        timeout_ms: @test_ms,
        cancellable?: true,
        kind: :plain,
        run: run,
        summary: & &1,
        redact: secrets
      )
    end
  end

  defp test_subject(true, _id, attrs) do
    changeset =
      Provider.changeset(%Provider{}, %{
        "name" => Kit.string(attrs, "name") || "the new provider",
        "kind" => Kit.string(attrs, "kind") || "openai_compatible",
        "base_url" => Kit.string(attrs, "base_url") || ""
      })

    if changeset.valid?,
      do: {:ok, Ecto.Changeset.apply_changes(changeset)},
      else: Kit.changeset_error(changeset)
  end

  defp test_subject(false, id, _attrs) do
    case Providers.get(id || "") do
      nil -> gone()
      provider -> {:ok, provider}
    end
  end

  defp fetch_models(cmd) do
    case Providers.get(Kit.get(Kit.cmd(cmd, :target), "id") || "") do
      nil ->
        gone()

      provider ->
        Kit.task(
          action: "provider.fetch_models",
          key: provider.id,
          timeout_ms: @fetch_ms,
          cancellable?: true,
          kind: :plain,
          run: fn _report -> fetch_one(provider) end,
          summary: &Map.drop(&1, ["rows", "models"]),
          redact: Secrets.redaction_list(provider)
        )
    end
  end

  @doc false
  # Lists a provider's models and computes the difference with its stored
  # list; writes nothing (D25).
  def fetch_one(%Provider{} = provider) do
    started = System.monotonic_time(:millisecond)

    case LLM.list_models(provider) do
      {:ok, ids} -> {:ok, difference(provider, ids, Kit.since(started))}
      {:error, message} -> {:error, Kit.redact(message, Secrets.redaction_list(provider))}
    end
  end

  @doc false
  def difference(%Provider{} = provider, ids, ms) do
    listed = ids |> Enum.filter(&is_binary/1) |> Enum.uniq() |> Enum.sort()
    kept = Enum.take(listed, @max_models)
    current = provider.models || []
    listed_set = MapSet.new(listed)
    current_set = MapSet.new(current)
    added = Enum.reject(kept, &MapSet.member?(current_set, &1))
    removed = Enum.reject(current, &MapSet.member?(listed_set, &1))
    same = Enum.filter(kept, &MapSet.member?(current_set, &1))
    in_use = model_use(provider.id)

    rows =
      Enum.map(added, &diff_row(&1, "new", 0)) ++
        Enum.map(Enum.sort(removed), &diff_row(&1, "gone", Map.get(in_use, &1, 0))) ++
        Enum.map(same, &diff_row(&1, "same", Map.get(in_use, &1, 0)))

    %{
      "provider_id" => provider.id,
      "host" => host(provider.base_url),
      "listed" => length(listed),
      "kept" => length(kept),
      "truncated" => length(listed) > @max_models,
      "added" => length(added),
      "removed" => length(removed),
      "unchanged" => length(same),
      "removed_in_use" => Enum.reduce(removed, 0, &(&2 + Map.get(in_use, &1, 0))),
      "ms" => ms,
      "rows" => rows,
      "models" => kept
    }
  end

  defp diff_row(model, change, conversations),
    do: %{"model" => model, "change" => change, "conversations" => conversations}

  # How many conversations name each model of this provider, in any of the
  # four model columns (a conversation counts once per model).
  defp model_use(id) do
    from(c in Conversation,
      where:
        c.chat_provider_id == ^id or c.swarm_provider_id == ^id or
          c.judge_provider_id == ^id or c.implementer_provider_id == ^id,
      select:
        {c.chat_provider_id, c.chat_model, c.swarm_provider_id, c.swarm_model,
         c.judge_provider_id, c.judge_model, c.implementer_provider_id, c.implementer_model}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {cp, cm, sp, sm, jp, jm, ip, im} ->
      [{cp, cm}, {sp, sm}, {jp, jm}, {ip, im}]
      |> Enum.filter(fn {p, m} -> p == id and is_binary(m) end)
      |> Enum.map(&elem(&1, 1))
      |> Enum.uniq()
    end)
    |> Enum.frequencies()
  end

  defp host(url) when is_binary(url), do: URI.parse(url).host || url
  defp host(_url), do: nil

  defp apply_models(cmd, ctx) do
    id = Kit.get(Kit.cmd(cmd, :target), "id")
    attrs = Kit.cmd(cmd, :attributes)
    mode = Kit.get(attrs, "mode")

    with {:ok, _} <- expected(cmd, "fields"),
         {:ok, fetched} <- fetched(ctx, Kit.get(attrs, "fetch_task_id"), id),
         :ok <- mode_ok(mode, fetched) do
      models = fetched["models"] || []

      write(
        id,
        cmd,
        ctx,
        fn fresh ->
          current = fresh.models || []
          next = if mode == "replace", do: models, else: add_new(current, models)
          if next == current, do: :unchanged, else: {:update, %{"models" => next}}
        end,
        fn p -> applied_message(p, mode, models) end
      )
    end
  end

  defp mode_ok("replace", %{"truncated" => true}),
    do: Kit.ok(:rejected, message: "the list was longer than 2 000; add new ones instead")

  defp mode_ok(mode, _fetched) when mode in ["replace", "add"], do: :ok
  defp mode_ok(_mode, _fetched), do: Kit.error(:invalid, "mode must be replace or add")

  defp add_new(current, fetched) do
    set = MapSet.new(current)
    new = Enum.reject(fetched, &MapSet.member?(set, &1))
    current ++ Enum.take(new, max(@max_models - length(current), 0))
  end

  defp applied_message(provider, "add", fetched) do
    stored = MapSet.new(provider.models || [])
    left = Enum.count(fetched, &(not MapSet.member?(stored, &1)))

    if left > 0,
      do: "#{provider.name}: #{left} not added: 2 000 models at most",
      else: "#{provider.name}: models updated"
  end

  defp applied_message(provider, _mode, _fetched), do: "#{provider.name}: models updated"

  # The fetched list of a `provider.fetch_models` (or one provider of a
  # `provider.fetch_all`) task, from the declared cache entry (§3.3.2).
  defp fetched(ctx, task_id, id) when is_binary(task_id) do
    entry =
      Kit.task_entry(ctx, "provider.fetch_models", task_id) ||
        Kit.task_entry(ctx, "provider.fetch_all", task_id)

    result = entry && entry.result

    cond do
      is_map(result) and Kit.get(result, "provider_id") == id ->
        {:ok, stringify(result)}

      is_map(result) and is_list(Kit.get(result, "providers")) ->
        case Enum.find(Kit.get(result, "providers"), &(Kit.get(&1, "id") == id)) do
          %{} = row -> {:ok, stringify(row)}
          nil -> fetch_again()
        end

      true ->
        fetch_again()
    end
  end

  defp fetched(_ctx, _task_id, _id), do: fetch_again()

  defp stringify(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  defp fetch_again, do: Kit.error(:not_found, "fetch again first")

  defp fetch_all do
    providers = Providers.list()

    run = fn report ->
      total = length(providers)
      report.(%{"done" => 0, "total" => total})

      rows =
        providers
        |> Task.async_stream(&fetch_one/1,
          max_concurrency: 4,
          timeout: @fetch_ms,
          on_timeout: :kill_task,
          ordered: true
        )
        |> Stream.zip(providers)
        |> Stream.with_index(1)
        |> Enum.map(fn {{outcome, provider}, done} ->
          report.(%{"done" => done, "total" => total})
          fetch_all_row(provider, outcome)
        end)

      {:ok,
       %{
         "providers" => rows,
         "count" => total,
         "changed" => Enum.count(rows, &(&1["added"] > 0 or &1["removed"] > 0))
       }}
    end

    Kit.task(
      action: "provider.fetch_all",
      key: "all",
      timeout_ms: @fetch_all_ms,
      cancellable?: true,
      kind: :plain,
      run: run,
      summary: fn result ->
        Map.update(result, "providers", [], fn rows ->
          Enum.map(rows, &Map.drop(&1, ["models"]))
        end)
      end,
      redact: Enum.flat_map(providers, &Secrets.redaction_list/1)
    )
  end

  defp fetch_all_row(provider, {:ok, {:ok, diff}}) do
    %{
      "id" => provider.id,
      "name" => provider.name,
      "state" => "done",
      "count" => diff["listed"],
      "added" => diff["added"],
      "removed" => diff["removed"],
      "truncated" => diff["truncated"],
      "message" => nil,
      "models" => diff["models"]
    }
  end

  defp fetch_all_row(provider, {:ok, {:error, message}}),
    do: failed_row(provider, "failed", message)

  defp fetch_all_row(provider, {:exit, :timeout}),
    do: failed_row(provider, "timeout", "no answer in 30 s")

  defp fetch_all_row(provider, {:exit, _reason}),
    do: failed_row(provider, "failed", "the fetch stopped")

  defp failed_row(provider, state, message) do
    %{
      "id" => provider.id,
      "name" => provider.name,
      "state" => state,
      "count" => 0,
      "added" => 0,
      "removed" => 0,
      "truncated" => false,
      "message" => Kit.redact(message, Secrets.redaction_list(provider))
    }
  end

  defp forget_caps(cmd, ctx) do
    case Providers.get(Kit.get(Kit.cmd(cmd, :target), "id") || "") do
      nil ->
        gone()

      provider ->
        if :ets.whereis(ProviderCaps) != :undefined, do: ProviderCaps.forget(provider)

        Kit.ok(
          record: record(provider, ctx),
          message: "#{provider.name}: this session forgot what it learned"
        )
    end
  end

  ## ------------------------------------------------------------ attention

  @doc "AT2 and AT3 (§2.1)."
  @spec attention(map()) :: [map()]
  def attention(ctx) do
    providers = Providers.list()
    settings = settings_row()

    failed =
      for p <- providers, entry = last_check(ctx, p.id), entry.state in ["failed", "timeout"] do
        %{
          id: "AT2:" <> p.id,
          severity: "error",
          section: "providers",
          target: %{"kind" => "provider", "id" => p.id},
          title: "#{p.name} did not answer its last test",
          reason: Kit.redact(entry.message || "no answer", Secrets.redaction_list(p))
        }
      end

    default_ids =
      for {"models." <> _, pf, _} <- pairs(),
          id = Map.get(settings, pf),
          is_binary(id),
          into: MapSet.new(),
          do: id

    keyless =
      for p <- providers, MapSet.member?(default_ids, p.id), not usable?(p) do
        %{
          id: "AT3:" <> p.id,
          severity: "warning",
          section: "providers",
          target: %{"kind" => "provider", "id" => p.id},
          title: "#{p.name} has no key",
          reason: "a default model uses it"
        }
      end

    failed ++ keyless
  end

  defp last_check(ctx, id) do
    [Kit.task_entry(ctx, "provider.test", id), Kit.task_entry(ctx, "provider.fetch_models", id)]
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&at_key/1, fn -> nil end)
  end

  defp at_key(%{at: %DateTime{} = at}), do: DateTime.to_unix(at, :microsecond)

  defp at_key(%{at: at}) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :microsecond)
      _ -> 0
    end
  end

  defp at_key(_entry), do: 0

  @doc "The providers glance line (§2.1)."
  @spec glance(map()) :: map()
  def glance(ctx) do
    providers = Providers.list()
    tests = Enum.map(providers, &Kit.task_entry(ctx, "provider.test", &1.id))

    %{
      "providers" => %{
        "count" => length(providers),
        "usable" => Enum.count(providers, &usable?/1),
        "answered" => Enum.count(tests, &(&1 && &1.state == "done")),
        "failed" => Enum.count(tests, &(&1 && &1.state in ["failed", "timeout"])),
        "never_tested" => Enum.count(tests, &is_nil/1)
      }
    }
  end

  ## ------------------------------------------------------------ inputs

  defp attributes(attrs, allowed) when is_map(attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    cond do
      Map.has_key?(attrs, "api_key") ->
        Kit.error(:invalid, "a key is pasted, not typed", [
          Kit.field_error("api_key", "paste the key instead")
        ])

      true ->
        attrs = Map.take(attrs, allowed)

        case Map.fetch(attrs, "models") do
          {:ok, models} ->
            with {:ok, models} <- normalise_models(models),
                 do: {:ok, Map.put(attrs, "models", models)}

          :error ->
            {:ok, attrs}
        end
    end
  end

  defp attributes(_attrs, _allowed), do: Kit.error(:invalid, "attributes must be a map")

  @doc false
  def normalise_models(models) when is_list(models) do
    if Enum.all?(models, &is_binary/1) do
      list = models |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
      duplicate = list |> Enum.frequencies() |> Enum.find(fn {_m, n} -> n > 1 end)

      cond do
        duplicate ->
          {m, _} = duplicate

          Kit.error(:invalid, "#{m}: already in the list", [
            Kit.field_error("models", "already in the list")
          ])

        length(list) > @max_models ->
          Kit.error(:invalid, "2 000 models at most", [
            Kit.field_error("models", "2 000 models at most")
          ])

        true ->
          {:ok, list}
      end
    else
      Kit.error(:invalid, "models must be a list of model ids", [
        Kit.field_error("models", "must be a list of model ids")
      ])
    end
  end

  def normalise_models(_other),
    do:
      Kit.error(:invalid, "models must be a list", [
        Kit.field_error("models", "must be a list of model ids")
      ])

  defp optional_key(cmd) do
    case Secrets.take(cmd, "api_key") do
      :error ->
        {:ok, nil}

      {:ok, value} ->
        case Secrets.check_paste(value) do
          :ok -> {:ok, Secrets.normalise(value)}
          {:error, message} -> Kit.error(:invalid, message, [Kit.field_error("api_key", message)])
        end
    end
  end

  defp required_key(cmd) do
    case Secrets.take(cmd, "api_key") do
      :error ->
        Kit.error(:invalid, "paste the key", [Kit.field_error("api_key", "paste the key")])

      {:ok, value} ->
        case Secrets.check_paste(value) do
          :ok -> {:ok, value}
          {:error, message} -> Kit.error(:invalid, message, [Kit.field_error("api_key", message)])
        end
    end
  end

  defp expected(cmd, key) do
    expected = Kit.cmd(cmd, :expected)

    if Kit.has?(expected, key),
      do: {:ok, Kit.get(expected, key)},
      else: Kit.error(:invalid, "expected is missing for #{key}")
  end

  defp gone, do: Kit.error(:not_found, "That provider no longer exists.")
  defp busy, do: Kit.error(:busy, "Settings is busy; try again in a moment.")
  defp couldnt(_reason), do: "Couldn't save that provider right now."

  defp unsupported,
    do: Kit.error(:unsupported, "This part of settings is not available in this build.")
end
