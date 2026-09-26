defmodule SwarmCode.Daemon.Service.Settings.Search do
  @moduledoc """
  Web search and page-reader providers in settings (pass 74 §3.5.3): one
  record per kind — the stored rows plus in-memory placeholders for the kinds
  never saved (reading writes nothing, D24) — with on/off and base URL
  writes, pasted keys (tested first when one is replaced), key removal, the
  engines' fallback order and the Test task. AT6, AT15, AT17.
  """

  @behaviour SwarmCode.Daemon.Service.Settings.Handler

  import Ecto.Query, warn: false, only: [from: 2]

  alias SwarmCode.Daemon.Service.Settings.{Kit, Secrets}
  alias SwarmCode.Daemon.Service.Settings.Providers, as: ProviderSettings
  alias SwarmCode.Domain.{Cache, Repo}
  alias SwarmCode.Domain.Search, as: Engines
  alias SwarmCode.Domain.Search.SearchProvider

  @test_ms 20_000

  @doc false
  def actions, do: ~w(search.update search.set_key search.clear_key search.move search.test)

  @doc false
  def views, do: [{"records", "search_providers"}, {"record", "search_provider"}]

  @doc false
  def cache_reads(view)
      when view in ["records:search_providers", "record:search_provider", "overview"],
      do: [{"search.test", :all}]

  def cache_reads(_other), do: []

  @doc "Every kind in the canonical order: engines, then readers."
  @spec kinds() :: [String.t()]
  def kinds, do: Engines.engine_kinds() ++ Engines.reader_kinds()

  ## ------------------------------------------------------------ queries

  @doc false
  def query("records", "search_providers", params, ctx) do
    items = Enum.map(rows(), fn {row, persisted?} -> record(row, persisted?, ctx) end)
    {:ok, Kit.records_body("search_provider", items, params)}
  end

  def query("record", "search_provider", params, ctx) do
    kind = Kit.get(params, "id")

    case Enum.find(rows(), fn {row, _} -> row.kind == kind end) do
      nil -> no_kind()
      {row, persisted?} -> {:ok, record(row, persisted?, ctx)}
    end
  end

  def query(_view, _kind, _params, _ctx), do: Kit.unsupported()

  @doc """
  The rows as the page shows them: `{row, persisted?}` for every kind, the
  missing kinds as disabled placeholders at their canonical index, sorted by
  `{position, canonical index}` (the order `Search.all/0` gives, without its
  inserts).
  """
  @spec rows() :: [{SearchProvider.t(), boolean()}]
  def rows do
    existing = Map.new(Engines.list(), &{&1.kind, &1})
    kinds = kinds()

    kinds
    |> Enum.with_index()
    |> Enum.map(fn {kind, index} ->
      case Map.fetch(existing, kind) do
        {:ok, row} -> {row, true}
        :error -> {placeholder(kind, index), false}
      end
    end)
    |> Enum.sort_by(fn {row, _} -> {row.position, index(row.kind)} end)
  end

  defp placeholder(kind, index),
    do: %SearchProvider{kind: kind, enabled: false, api_key: "", position: index}

  defp index(kind), do: Enum.find_index(kinds(), &(&1 == kind)) || 99

  @doc "The wire fields of a row (the key as `{set, hint}`)."
  @spec fields(SearchProvider.t(), boolean(), map()) :: map()
  def fields(row, persisted?, ctx) do
    %{
      "kind" => row.kind,
      "role" => role(row.kind),
      "label" => Engines.label(row.kind),
      "hint" => Engines.hint(row.kind),
      "enabled" => row.enabled == true,
      "api_key" => Secrets.mask(row.api_key),
      "needs_key" => SearchProvider.needs_key?(row.kind),
      "base_url" => row.base_url,
      "default_base_url" => default_base_url(row.kind),
      "position" => row.position,
      "persisted" => persisted?,
      "last_test" => Kit.last_run(Kit.task_entry(ctx, "search.test", row.kind))
    }
  end

  defp record(row, persisted?, ctx),
    do: Kit.record("search_provider", row.kind, fields(row, persisted?, ctx))

  defp fresh_record(kind, ctx) do
    case Enum.find(rows(), fn {row, _} -> row.kind == kind end) do
      {row, persisted?} -> record(row, persisted?, ctx)
      nil -> nil
    end
  end

  # §4.7: `Moved Exa above Brave` (QA F-21 said `Exa moved down`).
  defp moved_words(order, kind, dir) do
    engines = Enum.filter(order, &(role(&1) == "engine"))
    index = Enum.find_index(engines, &(&1 == kind))
    other = Enum.at(engines, index - dir)

    cond do
      other == nil -> "Moved #{Engines.label(kind)}"
      dir < 0 -> "Moved #{Engines.label(kind)} above #{Engines.label(other)}"
      true -> "Moved #{Engines.label(kind)} below #{Engines.label(other)}"
    end
  end

  defp role(kind), do: if(kind in Engines.engine_kinds(), do: "engine", else: "reader")

  defp default_base_url(kind) do
    module = Engines.module(kind)

    if module && Code.ensure_loaded?(module) && function_exported?(module, :default_base_url, 0),
      do: module.default_base_url()
  end

  ## ------------------------------------------------------------ commands

  @doc false
  def command(%{action: action} = cmd, ctx) do
    kind = Kit.get(Kit.cmd(cmd, :target), "kind")

    if kind in kinds() do
      run(action, kind, cmd, ctx)
    else
      no_kind()
    end
  end

  defp run("search.update", kind, cmd, ctx), do: update(kind, cmd, ctx)
  defp run("search.set_key", kind, cmd, ctx), do: set_key(kind, cmd, ctx)
  defp run("search.clear_key", kind, cmd, ctx), do: clear_key(kind, cmd, ctx)
  defp run("search.move", kind, cmd, ctx), do: move(kind, cmd, ctx)
  defp run("search.test", kind, cmd, _ctx), do: test(kind, cmd)
  defp run(_action, _kind, _cmd, _ctx), do: Kit.unsupported()

  # -- update ---------------------------------------------------------------

  defp update(kind, cmd, ctx) do
    attrs = Kit.cmd(cmd, :attributes)
    expected = Kit.cmd(cmd, :expected)

    with {:ok, changes} <- update_attrs(attrs),
         true <- Kit.has?(expected, "fields") || Kit.expected(cmd, "fields") do
      write(kind, cmd, ctx, fn fresh, persisted? ->
        current = fields(fresh, persisted?, ctx)

        cond do
          match?({:conflict, _}, Kit.check_fields(expected, current)) ->
            {:conflict_fields, Kit.check_fields(expected, current), current}

          Enum.all?(changes, fn {k, v} -> Map.get(current, k) == v end) ->
            :unchanged

          Map.get(changes, "enabled") == true and SearchProvider.needs_key?(kind) and
              blank?(fresh.api_key) ->
            {:refused, "enabled", "is needed to enable #{kind}",
             "Paste #{Engines.label(kind)}'s key first: a key is needed to turn it on."}

          true ->
            {:upsert, changes, update_message(kind, changes)}
        end
      end)
    end
  end

  defp update_attrs(attrs) when is_map(attrs) do
    allowed = Map.take(stringify(attrs), ["enabled", "base_url"])

    cond do
      allowed == %{} or map_size(allowed) != map_size(attrs) ->
        Kit.error(:invalid, "only enabled and base_url change here")

      Map.has_key?(allowed, "enabled") and not is_boolean(allowed["enabled"]) ->
        Kit.error(:invalid, "enabled: must be true or false", [
          Kit.field_error("enabled", "must be true or false")
        ])

      true ->
        with {:ok, url} <- base_url(allowed) do
          {:ok,
           if(Map.has_key?(allowed, "base_url"),
             do: %{allowed | "base_url" => url},
             else: allowed
           )}
        end
    end
  end

  defp update_attrs(_attrs), do: Kit.error(:invalid, "only enabled and base_url change here")

  defp base_url(%{"base_url" => url}) when is_nil(url), do: {:ok, nil}

  defp base_url(%{"base_url" => url}) when is_binary(url) do
    case url |> String.trim() |> String.trim_trailing("/") do
      "" ->
        {:ok, nil}

      trimmed ->
        if String.starts_with?(trimmed, ["http://", "https://"]),
          do: {:ok, trimmed},
          else: bad_url()
    end
  end

  defp base_url(%{"base_url" => _other}), do: bad_url()
  defp base_url(_attrs), do: {:ok, nil}

  defp bad_url,
    do:
      Kit.error(:invalid, "base_url: must start with http:// or https://", [
        Kit.field_error("base_url", "must start with http:// or https://")
      ])

  defp update_message(kind, changes) do
    label = Engines.label(kind)

    case changes do
      %{"enabled" => true} -> "#{label} on"
      %{"enabled" => false} -> "#{label} off"
      %{"base_url" => nil} -> "#{label} uses its default address"
      _ -> "#{label} address saved"
    end
  end

  # -- keys -----------------------------------------------------------------

  defp set_key(kind, cmd, ctx) do
    test_first? = Kit.get(Kit.cmd(cmd, :attributes), "test_first") == true

    with {:ok, pasted} <- Secrets.required(cmd, "api_key"),
         {:ok, expected_key} <- Kit.expected(cmd, "key") do
      new = Secrets.normalise(pasted)
      {fresh, persisted?} = row(kind)
      label = Engines.label(kind)

      cond do
        fresh.api_key == new ->
          Kit.ok(:unchanged,
            record: record(fresh, persisted?, ctx),
            message: "#{label} already has that key"
          )

        not Kit.same?(expected_key, Secrets.mask(fresh.api_key)) ->
          key_conflict(fresh, persisted?, ctx)

        test_first? ->
          test_first_task(kind, expected_key, new, fresh.api_key)

        true ->
          write(kind, cmd, ctx, fn fresh, persisted? ->
            cond do
              not Kit.same?(expected_key, Secrets.mask(fresh.api_key)) ->
                {:conflict_key, fresh, persisted?}

              fresh.api_key == new ->
                :unchanged

              true ->
                {:upsert, %{"api_key" => new}, "#{label} key saved"}
            end
          end)
      end
    end
  end

  # §3.5.3: a replaced key is tested first; only a key the endpoint accepts
  # is written, in one compare-and-set against the key the user saw.
  defp test_first_task(kind, expected_key, new, old) do
    label = Engines.label(kind)
    secrets = Enum.reject([new, old], &blank?/1)

    run = fn _report ->
      case Engines.test(kind, %{api_key: new}) do
        {:ok, count, ms} ->
          case store_tested_key(kind, expected_key, new) do
            :ok ->
              {:ok,
               test_result(kind, count, ms) |> Map.merge(%{"saved" => true, "name" => label})}

            {:error, message} ->
              {:error, message}
          end

        {:error, words} ->
          {:error,
           "The new key was refused (#{ProviderSettings.refusal(Kit.redact(words, secrets), label)})."}
      end
    end

    Kit.task(
      action: "search.set_key",
      key: kind,
      timeout_ms: @test_ms,
      cancellable?: true,
      kind: :plain,
      run: run,
      summary: & &1,
      redact: secrets
    )
  end

  defp store_tested_key(kind, expected_key, new) do
    outcome =
      Repo.retry(:settings_search, fn ->
        Repo.transaction(fn ->
          {fresh, _} = fresh_row(kind)

          unless Kit.same?(expected_key, Secrets.mask(fresh.api_key)),
            do: Repo.rollback(:conflict)

          upsert_or_rollback(kind, fresh, %{"api_key" => new})
        end)
      end)

    case outcome do
      {:ok, _} ->
        Cache.delete(:search_providers)
        :ok

      {:error, :conflict} ->
        {:error, "The key changed while the new one was being checked; nothing was saved."}

      {:error, _other} ->
        {:error, "Couldn't save the new key right now."}
    end
  end

  defp clear_key(kind, cmd, ctx) do
    label = Engines.label(kind)

    with {:ok, expected_key} <- Kit.expected(cmd, "key") do
      write(kind, cmd, ctx, fn fresh, persisted? ->
        cond do
          not Kit.same?(expected_key, Secrets.mask(fresh.api_key)) ->
            {:conflict_key, fresh, persisted?}

          blank?(fresh.api_key) ->
            :unchanged

          fresh.enabled and SearchProvider.needs_key?(kind) ->
            {:upsert, %{"api_key" => "", "enabled" => false},
             "#{label} key removed · #{label} is off: it needs a key"}

          true ->
            {:upsert, %{"api_key" => ""}, "#{label} key removed"}
        end
      end)
    end
  end

  defp key_conflict(fresh, persisted?, ctx) do
    Kit.ok(:conflict,
      results: [Kit.row("api_key", :conflict, current: Secrets.mask(fresh.api_key))],
      record: record(fresh, persisted?, ctx),
      message: "#{Engines.label(fresh.kind)}'s key changed while you edited it."
    )
  end

  # -- move -----------------------------------------------------------------

  defp move(kind, cmd, ctx) do
    dir = Kit.get(Kit.cmd(cmd, :attributes), "dir")

    with {:ok, expected_order} <- Kit.expected(cmd, "order"),
         true <- dir in [-1, 1] || Kit.error(:invalid, "dir: -1 or 1"),
         true <- role(kind) == "engine" || Kit.error(:invalid, "readers have no order") do
      outcome =
        Repo.retry(:settings_search, fn ->
          Repo.transaction(fn ->
            order = Enum.map(rows(), fn {row, _} -> row.kind end)
            # cli74 F13: engines move among engines; the last one never
            # trades places with a reader.
            engines = Enum.filter(order, &(role(&1) == "engine"))
            target = Enum.find_index(engines, &(&1 == kind)) + dir

            cond do
              not Kit.same?(expected_order, order) -> Repo.rollback({:conflict_order, order})
              target < 0 or target >= length(engines) -> :unchanged
              Map.get(cmd, :dry_run) -> :dry_run
              true -> Engines.move(kind, dir)
            end
          end)
        end)

      case outcome do
        {:ok, :ok} ->
          Cache.delete(:search_providers)
          order = Enum.map(rows(), fn {row, _} -> row.kind end)

          Kit.ok(
            results: [Kit.row("order", :accepted, value: order)],
            record: fresh_record(kind, ctx),
            message: moved_words(order, kind, dir)
          )

        {:ok, :dry_run} ->
          Kit.ok(record: fresh_record(kind, ctx))

        {:ok, :unchanged} ->
          Kit.ok(:unchanged, record: fresh_record(kind, ctx))

        {:error, {:conflict_order, order}} ->
          Kit.ok(:conflict,
            results: [Kit.row("order", :conflict, current: order)],
            message: "The search order changed while you moved #{Engines.label(kind)}."
          )

        {:error, _other} ->
          Kit.busy()
      end
    end
  end

  # -- test -----------------------------------------------------------------

  defp test(kind, cmd) do
    attrs = Kit.cmd(cmd, :attributes)

    with {:ok, key} <- Secrets.optional(cmd, "api_key"),
         {:ok, url} <- base_url(Map.take(stringify(attrs), ["base_url"])) do
      {row, _} = row(kind)
      secrets = Enum.reject([key, row.api_key], &blank?/1)
      overrides = %{api_key: key, base_url: url}

      run = fn _report ->
        case Engines.test(kind, overrides) do
          {:ok, count, ms} -> {:ok, test_result(kind, count, ms)}
          {:error, words} -> {:error, Kit.redact(words, secrets)}
        end
      end

      Kit.task(
        action: "search.test",
        key: kind,
        timeout_ms: @test_ms,
        cancellable?: true,
        kind: :plain,
        run: run,
        summary: & &1,
        redact: secrets
      )
    end
  end

  defp test_result(kind, count, ms) do
    if role(kind) == "engine",
      do: %{"count" => count, "ms" => ms},
      else: %{"read" => "example.com", "ms" => ms}
  end

  ## ------------------------------------------------------------ writes

  # One compare-and-set write of a kind's row: `decide` sees the fresh row
  # (or its placeholder) inside the transaction.
  defp write(kind, cmd, ctx, decide) do
    outcome =
      Repo.retry(:settings_search, fn ->
        Repo.transaction(fn ->
          {fresh, persisted?} = fresh_row(kind)

          case decide.(fresh, persisted?) do
            {:conflict_fields, {:conflict, moved}, current} ->
              Repo.rollback({:conflict_fields, moved, current})

            {:conflict_key, fresh, persisted?} ->
              Repo.rollback({:conflict_key, fresh, persisted?})

            {:refused, field, reason, message} ->
              Repo.rollback({:refused, field, reason, message})

            :unchanged ->
              :unchanged

            {:upsert, _changes, _message} when cmd.dry_run == true ->
              :dry_run

            {:upsert, changes, message} ->
              upsert_or_rollback(kind, fresh, changes)
              {:written, message}
          end
        end)
      end)

    case outcome do
      {:ok, {:written, message}} ->
        Cache.delete(:search_providers)
        Kit.ok(record: fresh_record(kind, ctx), message: message)

      {:ok, :dry_run} ->
        Kit.ok(record: fresh_record(kind, ctx))

      {:ok, :unchanged} ->
        Kit.ok(:unchanged, record: fresh_record(kind, ctx))

      {:error, {:conflict_fields, moved, current}} ->
        Kit.ok(:conflict,
          results: Enum.map(moved, &Kit.row(&1, :conflict, current: Map.get(current, &1))),
          record: fresh_record(kind, ctx),
          message: "#{Engines.label(kind)} changed while you edited it."
        )

      {:error, {:conflict_key, fresh, persisted?}} ->
        key_conflict(fresh, persisted?, ctx)

      {:error, {:refused, field, reason, message}} ->
        Kit.error(:invalid, message, [Kit.field_error(field, reason)])

      {:error, {:invalid, changeset}} ->
        Kit.changeset_error(changeset)

      {:error, _other} ->
        Kit.busy()
    end
  end

  defp upsert_or_rollback(kind, fresh, changes) do
    # a placeholder is created at its canonical position
    changes =
      if fresh.id,
        do: changes,
        else: Map.put_new(changes, "position", fresh.position)

    case Engines.upsert(kind, changes) do
      {:ok, row} -> row
      {:error, changeset} -> Repo.rollback({:invalid, changeset})
    end
  end

  defp row(kind) do
    case Engines.get(kind) do
      nil -> {placeholder(kind, index(kind)), false}
      row -> {row, true}
    end
  end

  defp fresh_row(kind) do
    case Repo.one(from(p in SearchProvider, where: p.kind == ^kind)) do
      nil -> {placeholder(kind, index(kind)), false}
      row -> {row, true}
    end
  end

  ## ------------------------------------------------------------ overview

  @doc "AT6, AT15, AT17 (§2.1)."
  @spec attention(map()) :: [map()]
  def attention(ctx) do
    rows = rows()
    engines = for {row, _} <- rows, row.kind in Engines.engine_kinds(), do: row
    on = Enum.filter(engines, & &1.enabled)
    reader = ProviderSettings.settings_row().research_reader

    at6 =
      if on == [] do
        [
          item("AT6", "Agents cannot search the web", "no search engine is on", hd(engines).kind)
        ]
      else
        []
      end

    firecrawl = Enum.find_value(rows, fn {row, _} -> row.kind == "firecrawl" && row end)

    at15 =
      if reader == "firecrawl" and blank?(firecrawl.api_key) do
        [
          item(
            "AT15",
            "Page reader is Firecrawl but it has no key",
            "pages use the plain fetch",
            "firecrawl"
          )
        ]
      else
        []
      end

    at17 =
      for row <- on,
          entry = Kit.task_entry(ctx, "search.test", row.kind),
          entry && entry.state in ["failed", "timeout"] do
        item(
          "AT17",
          "#{Engines.label(row.kind)} did not answer its last test",
          entry.message || "the test failed",
          row.kind
        )
      end

    at6 ++ at15 ++ at17
  end

  defp item(id, title, reason, kind) do
    %{
      id: id,
      severity: "warning",
      section: "search_web",
      target: %{"kind" => "search_provider", "id" => kind},
      title: title,
      reason: reason
    }
  end

  @doc "The Overview's search glance."
  @spec glance(map()) :: map()
  def glance(ctx) do
    rows = Enum.map(rows(), &elem(&1, 0))
    engines = Enum.filter(rows, &(&1.kind in Engines.engine_kinds()))
    on = Enum.filter(engines, & &1.enabled)

    failed =
      Enum.count(on, fn row ->
        entry = Kit.task_entry(ctx, "search.test", row.kind)
        entry && entry.state in ["failed", "timeout"]
      end)

    %{
      "search" =>
        Kit.glance(%{
          "engines" => length(engines),
          "on" => length(on),
          "first" => on |> List.first() |> then(&(&1 && Engines.label(&1.kind))),
          "reader" => ProviderSettings.settings_row().research_reader || "web_fetch",
          "failed" => failed
        })
    }
  end

  ## ------------------------------------------------------------ small

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_other), do: %{}

  defp no_kind, do: Kit.error(:not_found, "no such search provider")
end
