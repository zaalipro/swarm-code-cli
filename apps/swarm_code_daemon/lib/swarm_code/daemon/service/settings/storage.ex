defmodule SwarmCode.Daemon.Service.Settings.Storage do
  @moduledoc """
  Storage in settings (pass 74 §3.5.5): the measure task (overview, preset
  previews and the sessions the backend keeps as the sessions store), the
  sessions page over that store, the cleanup plan (cached under its task id),
  the cleanup run subscribed before it starts and monitored, VACUUM and the
  retention sweep — both inside the `:storage_cleanup` registration that
  `Storage.run/1` uses, so only one cleanup ever runs.
  """

  @behaviour SwarmCode.Daemon.Service.Settings.Handler

  alias SwarmCode.Daemon.Service.Settings.Kit
  alias SwarmCode.Daemon.Service.Settings.Providers, as: ProviderSettings
  alias SwarmCode.Domain.Settings
  alias SwarmCode.Domain.Storage, as: Store

  @measure_ms 120_000
  @plan_ms 60_000
  @run_ms 1_800_000
  @retention_ms 600_000
  @max_session_ids 2_048
  @title 120
  @busy "A cleanup is already running."
  # §2.18's wizard keys → the domain's selection keys (a closed table: no
  # atom is made from input)
  @selection %{
    "older_than_days" => :older_than_days,
    "session_ids" => :session_ids,
    "include_pinned" => :include_pinned,
    "empty_sessions" => :empty_sessions,
    "prune_days" => :prune_days,
    "checkpoint_days" => :checkpoint_days,
    "journal_days" => :journal_days,
    "research_days" => :research_days,
    "vacuum" => :vacuum
  }

  @doc false
  def actions,
    do: ~w(storage.measure storage.plan storage.run storage.vacuum storage.apply_retention)

  @doc false
  def views, do: [{"records", "storage_sessions"}]

  @doc false
  def cache_reads("records:storage_sessions"), do: [{"storage.measure", :sessions_store}]
  def cache_reads("storage.plan"), do: [{"storage.measure", :sessions_store}]
  def cache_reads("storage.run"), do: [{"storage.plan", {:param, "plan_id"}}]
  def cache_reads(_other), do: []

  ## ------------------------------------------------------------ sessions page

  @doc false
  def query("records", "storage_sessions", params, ctx) do
    case store(ctx) do
      nil ->
        Kit.error(:not_found, "measure first")

      rows ->
        options = Kit.options(params)
        filter = options |> Kit.get("filter") |> to_string() |> String.downcase() |> String.trim()

        items =
          rows
          |> Enum.map(&session_fields/1)
          |> Enum.filter(&matches?(&1, filter))
          |> sort(Kit.get(options, "sort"))
          |> Enum.map(&Kit.record("storage_session", &1["id"], &1))

        {:ok, Kit.records_body("storage_session", items, params)}
    end
  end

  def query(_view, _kind, _params, _ctx), do: Kit.unsupported()

  defp store(ctx) do
    case Kit.ctx(ctx, :sessions_store) do
      rows when is_list(rows) -> rows
      _ -> nil
    end
  end

  defp matches?(_row, ""), do: true

  defp matches?(row, filter) do
    String.contains?(String.downcase(row["title"] || ""), filter) or
      String.contains?(String.downcase(row["project"] || ""), filter)
  end

  defp sort(rows, "date"), do: Enum.sort_by(rows, &(&1["updated_at"] || ""), :desc)
  defp sort(rows, "title"), do: Enum.sort_by(rows, &(&1["title"] || ""))
  defp sort(rows, _bytes), do: Enum.sort_by(rows, &(&1["bytes"] || 0), :desc)

  @doc "A sessions-store row (atom or string keys) as the wire's `storage_session` fields."
  @spec session_fields(map()) :: map()
  def session_fields(row) do
    %{
      "id" => Kit.get(row, "id"),
      "title" => row |> Kit.get("title") |> clip(),
      "project" => row |> Kit.get("project") |> clip(),
      "updated_at" => Kit.iso(Kit.get(row, "updated_at")),
      "messages" => Kit.get(row, "messages") || 0,
      "runs" => Kit.get(row, "runs") || 0,
      "bytes" => Kit.get(row, "bytes") || 0,
      "running" => flag(row, "running"),
      "open" => flag(row, "open"),
      "pinned" => flag(row, "pinned"),
      "deletable" => flag(row, "deletable"),
      "reason" => row |> Kit.get("reason") |> reason()
    }
  end

  # the domain's `running?` or the store's `running`
  defp flag(row, name), do: (Kit.get(row, name) || Kit.get(row, name <> "?")) == true

  defp reason(nil), do: nil
  defp reason(reason), do: to_string(reason)

  defp clip(nil), do: nil
  defp clip(text), do: text |> to_string() |> String.slice(0, @title)

  ## ------------------------------------------------------------ commands

  @doc false
  def command(%{action: "storage.measure"}, _ctx) do
    Kit.task(
      action: "storage.measure",
      key: "measure",
      timeout_ms: @measure_ms,
      cancellable?: true,
      kind: :plain,
      run: fn _report -> {:ok, measure()} end,
      summary: &Map.delete(&1, "sessions"),
      redact: []
    )
  end

  def command(%{action: "storage.plan"} = cmd, ctx) do
    with {:ok, selection} <- selection(Kit.get(Kit.cmd(cmd, :attributes), "selection")) do
      stored = store(ctx)

      Kit.task(
        action: "storage.plan",
        key: :wizard,
        timeout_ms: @plan_ms,
        cancellable?: true,
        kind: :plain,
        run: fn _report -> {:ok, plan(selection, stored)} end,
        summary: &Map.drop(&1, ["rows", "plan"]),
        redact: []
      )
    end
  end

  def command(%{action: "storage.run"} = cmd, ctx) do
    plan_id = Kit.get(Kit.cmd(cmd, :attributes), "plan_id")

    with {:ok, plan} <- cached_plan(ctx, plan_id),
         true <- not Store.running?() || Kit.error(:busy, @busy) do
      Kit.task(
        action: "storage.run",
        key: "cleanup",
        timeout_ms: @run_ms,
        cancellable?: false,
        kind: :plain,
        run: fn report -> run(plan, report) end,
        summary: & &1,
        redact: []
      )
    end
  end

  def command(%{action: "storage.vacuum"}, _ctx) do
    if Store.running?() do
      Kit.error(:busy, @busy)
    else
      Kit.task(
        action: "storage.vacuum",
        key: "cleanup",
        timeout_ms: @run_ms,
        cancellable?: false,
        kind: :plain,
        run: fn _report -> vacuum() end,
        summary: & &1,
        redact: []
      )
    end
  end

  def command(%{action: "storage.apply_retention"}, _ctx) do
    settings = ProviderSettings.settings_row()

    selection =
      %{}
      |> put_days(:older_than_days, settings.storage_retention_days)
      |> put_days(:prune_days, settings.storage_prune_days)

    cond do
      selection == %{} ->
        Kit.ok(:rejected, message: "set a retention first")

      Store.running?() ->
        Kit.error(:busy, @busy)

      true ->
        Kit.task(
          action: "storage.apply_retention",
          key: "cleanup",
          timeout_ms: @retention_ms,
          cancellable?: false,
          kind: :plain,
          run: fn report -> retention(selection, report) end,
          summary: & &1,
          redact: []
        )
    end
  end

  def command(_cmd, _ctx), do: Kit.unsupported()

  ## ------------------------------------------------------------ measure

  @doc false
  # The measure task: overview, the presets with their previews, and the
  # sessions (the backend keeps `"sessions"` as the sessions store and drops
  # it from the summary).
  def measure do
    sessions = Store.sessions(sort: :bytes)

    %{
      "overview" => overview(Store.overview()),
      "presets" => Enum.map(Store.previews(sessions), &preset/1),
      "sessions" => Enum.map(sessions, &session_fields/1),
      "measured_at" => Kit.iso(DateTime.utc_now())
    }
  end

  defp overview(o) do
    %{
      "db_bytes" => o.db_bytes,
      "wal_bytes" => o.wal_bytes,
      "total_bytes" => o.total_bytes,
      "reclaimable_bytes" => o.reclaimable_bytes,
      "free_disk_bytes" => o.free_disk_bytes,
      "isolation_dirs" => o.isolation_dirs,
      "isolation_bytes" => o.isolation_bytes,
      "sessions" => o.sessions,
      "kinds" =>
        Enum.map(o.kinds, fn k ->
          %{"key" => to_string(k.key), "label" => k.label, "count" => k.count, "bytes" => k.bytes}
        end),
      "measured_at" => Kit.iso(o.measured_at)
    }
  end

  defp preset(p) do
    %{
      "key" => p.key,
      "title" => p.title,
      "note" => p.note,
      "selection" => Map.new(p.selection, fn {k, v} -> {to_string(k), v} end),
      "preview" => plan_summary(p.plan)
    }
  end

  ## ------------------------------------------------------------ plan

  defp selection(selection) when is_map(selection) do
    keys = Map.keys(selection) |> Enum.map(&to_string/1)
    unknown = keys -- Map.keys(@selection)

    cond do
      unknown != [] ->
        Kit.error(:invalid, "#{hd(unknown)} is not a cleanup choice")

      length(List.wrap(Kit.get(selection, "session_ids"))) > @max_session_ids ->
        Kit.error(:invalid, "#{@max_session_ids} sessions at most in one cleanup")

      true ->
        {:ok,
         for {key, atom} <- @selection, Kit.has?(selection, key), into: %{} do
           {atom, Kit.get(selection, key)}
         end}
    end
  end

  defp selection(_other), do: Kit.error(:invalid, "choose what to clean up")

  @doc false
  # The plan task: the domain plan over the measured sessions (their running
  # and open flags refreshed now), JSON-safe for the task cache.
  def plan(selection, stored) do
    sessions = if stored, do: sessions_from(stored), else: nil
    plan = Store.plan(selection, sessions)

    plan_summary(plan)
    |> Map.put("rows", Enum.map(plan.items, &item/1))
    |> Map.put("plan", encode_plan(plan))
  end

  defp plan_summary(plan) do
    %{
      "items" => Enum.map(plan.items, &item/1),
      "skipped" =>
        plan.skipped
        |> Enum.frequencies_by(&to_string(&1.reason))
        |> Enum.sort()
        |> Enum.map(fn {reason, count} -> %{"reason" => reason, "count" => count} end),
      "total_count" => plan.total_count,
      "total_bytes" => plan.total_bytes,
      "vacuum" => plan.vacuum
    }
  end

  defp item(i), do: %{"label" => i.label, "count" => i.count, "bytes" => i.bytes}

  # The store's rows back into the domain's session shape.
  defp sessions_from(rows) do
    running = MapSet.new(Store.running_conversation_ids())
    open = MapSet.new(Store.open_conversation_ids())

    for row <- rows, id = Kit.get(row, "id"), is_binary(id) do
      running? = MapSet.member?(running, id)
      open? = MapSet.member?(open, id)
      pinned? = flag(row, "pinned")

      %{
        id: id,
        title: Kit.get(row, "title"),
        bytes: Kit.get(row, "bytes") || 0,
        updated_at: datetime(Kit.get(row, "updated_at")),
        messages: Kit.get(row, "messages") || 0,
        runs: Kit.get(row, "runs") || 0,
        running?: running?,
        open?: open?,
        pinned?: pinned?,
        deletable?: not running? and not open?
      }
    end
  end

  defp datetime(%DateTime{} = at), do: at

  defp datetime(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _} -> at
      _ -> DateTime.utc_now()
    end
  end

  defp datetime(_other), do: DateTime.utc_now()

  @plan_keys ~w(session_ids prune_days checkpoint_days journal_days research_ids total_count
                total_bytes vacuum include_pinned)a

  defp encode_plan(plan) do
    plan
    |> Map.take(@plan_keys)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
    |> Map.put("planned_at", Kit.iso(plan.planned_at))
    |> Map.put("items", Enum.map(plan.items, &item/1))
  end

  defp decode_plan(json) do
    base = for key <- @plan_keys, into: %{}, do: {key, Kit.get(json, Atom.to_string(key))}

    base
    |> Map.merge(%{
      session_ids: base.session_ids || [],
      research_ids: base.research_ids || [],
      total_count: base.total_count || 0,
      total_bytes: base.total_bytes || 0,
      vacuum: base.vacuum == true,
      include_pinned: base.include_pinned == true,
      planned_at: datetime(Kit.get(json, "planned_at")),
      items: [],
      skipped: []
    })
  end

  defp cached_plan(ctx, plan_id) when is_binary(plan_id) do
    with %{} = entry <- Kit.task_entry(ctx, "storage.plan", plan_id),
         %{} = result <- entry.result,
         %{} = plan <- Kit.get(result, "plan") do
      {:ok, decode_plan(plan)}
    else
      _ -> Kit.error(:not_found, "That plan is gone; review the cleanup again.")
    end
  end

  defp cached_plan(_ctx, _plan_id), do: Kit.error(:invalid, "plan_id: review the cleanup first")

  ## ------------------------------------------------------------ run

  @doc false
  # §3.3.8 rule 4: subscribe first, then start, then follow the cleanup's
  # pid until it says done or failed (or dies without a word).
  def run(plan, report) do
    :ok = Store.subscribe()

    case Store.run(plan) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        follow(ref, report)

      {:error, :busy} ->
        {:error, @busy}

      {:error, _reason} ->
        {:error, "The cleanup could not start."}
    end
  end

  defp follow(ref, report) do
    receive do
      {:storage_progress, progress} ->
        report.(progress(progress))
        follow(ref, report)

      {:storage_done, result} ->
        Process.demonitor(ref, [:flush])
        {:ok, done(result)}

      {:storage_failed, :busy} ->
        Process.demonitor(ref, [:flush])
        {:error, @busy}

      {:storage_failed, _reason} ->
        Process.demonitor(ref, [:flush])
        {:error, "The cleanup failed; what was already removed stays removed."}

      {:DOWN, ^ref, :process, _pid, _reason} ->
        {:error, "the cleanup stopped without a result"}
    end
  end

  defp progress(p) do
    %{
      "done" => p.done,
      "total" => p.total,
      "bytes_freed" => p.bytes_freed,
      "step" => p.step
    }
  end

  defp done(result) do
    %{
      "freed_bytes" => result.bytes_freed,
      "items" => result.count,
      "vacuum" => vacuum_words(result.vacuum),
      "db_bytes_after" => result.after,
      "reclaimable_after" => result.reclaimable,
      "errors" => length(result.errors || [])
    }
  end

  defp vacuum_words({:ok, %{before: before, after: after_bytes}}),
    do: %{"before" => before, "after" => after_bytes}

  defp vacuum_words(_other), do: nil

  ## ------------------------------------------------------------ vacuum and retention

  @doc false
  def vacuum do
    guarded(fn ->
      case Store.vacuum() do
        {:ok, %{before: before, after: after_bytes} = r} ->
          {:ok, %{"before" => before, "after" => after_bytes, "freed" => Map.get(r, :freed, 0)}}

        {:error, :runs_active} ->
          {:error, "a run is live; stop it first"}

        {:error, {:disk, needed, free}} ->
          {:error, "needs #{Kit.bytes(needed)} free, #{Kit.bytes(free)} free"}
      end
    end)
  end

  @doc false
  # The retention sweep now: only the policies that are set, the open and
  # running sessions kept back by the plan, then the stamp.
  def retention(selection, report) do
    guarded(fn ->
      plan = Store.plan(selection, Store.sessions([]))

      result =
        Store.run_sync(plan, fn
          {:storage_progress, p} -> report.(progress(p))
          _other -> :ok
        end)

      Settings.update_quiet(%{storage_last_cleanup_at: DateTime.utc_now()})
      {:ok, done(result)}
    end)
  end

  # The single-run guard `Storage.run/1` holds, taken in this process.
  defp guarded(fun) do
    case Registry.register(SwarmCode.Domain.Registry, :storage_cleanup, nil) do
      {:ok, _} ->
        try do
          fun.()
        after
          Registry.unregister(SwarmCode.Domain.Registry, :storage_cleanup)
        end

      {:error, {:already_registered, _}} ->
        {:error, @busy}
    end
  end

  defp put_days(selection, _key, nil), do: selection
  defp put_days(selection, key, days) when is_integer(days), do: Map.put(selection, key, days)
  defp put_days(selection, _key, _days), do: selection

  ## ------------------------------------------------------------ glance

  @doc "The Overview's storage glance (no measuring: the settings row only)."
  @spec glance(map()) :: map()
  def glance(ctx) do
    settings = ProviderSettings.settings_row()

    %{
      "storage" => %{
        "retention_days" => settings.storage_retention_days,
        "prune_days" => settings.storage_prune_days,
        "last_sweep" => Kit.iso(settings.storage_last_cleanup_at),
        "sessions_measured" => ctx |> store() |> then(&(&1 && length(&1))),
        "cleanup_running" => Store.running?()
      }
    }
  end
end
