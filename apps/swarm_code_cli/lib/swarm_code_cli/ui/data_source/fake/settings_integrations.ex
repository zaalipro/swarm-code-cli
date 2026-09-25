defmodule SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations do
  @moduledoc """
  The fake's simulation of the integration handlers (spec 74 §3.5, U2-1): providers,
  efforts, models, pricing, search, MCP (with `.mcp.json` import), storage, language
  servers, files, the library and the project file.

  Pure data in, data out. `Fake.Settings` (S1) holds the state this module returns and
  dispatches every action it does not simulate itself to `command/2`; queries it does
  not answer go to `query/2`; the generic task lifecycle calls `run_task/3` when a task
  this module started finishes (`:run`), or is released by a test with a scripted
  outcome (`{:ok, summary}` / `{:error, message}`).

  Answers are wire-shaped maps with string keys (what the service would put on the
  socket before the client codec decodes it), so the client exercises the same
  decoding and secret-shape rules as against the daemon. A stored secret is never kept:
  only `{set, hint}` is, computed when the paste arrives (§3.2.5: the last 4 characters
  when the secret is at least 12 characters long).
  """

  @ailogic "11111111-1111-4111-8111-111111111111"
  @notes "22222222-2222-4222-8222-222222222222"
  @conversation "4f2a0000-0000-4000-8000-000000000001"

  @deepseek "0d5e0000-0000-4000-8000-000000000001"
  @anthropic "0d5e0000-0000-4000-8000-000000000002"
  @ollama "0d5e0000-0000-4000-8000-000000000003"
  @openrouter "0d5e0000-0000-4000-8000-000000000004"

  @github "3c9a0000-0000-4000-8000-000000000001"
  @fs "3c9a0000-0000-4000-8000-000000000002"
  @docs "3c9a0000-0000-4000-8000-000000000003"

  @readers ~w(jina firecrawl)
  @key_optional ~w(jina)
  @default_base_urls %{
    "tavily" => "https://api.tavily.com",
    "exa" => "https://api.exa.ai",
    "brave" => "https://api.search.brave.com/res/v1",
    "serper" => "https://google.serper.dev",
    "jina" => "https://r.jina.ai",
    "firecrawl" => "https://api.firecrawl.dev/v1"
  }

  @session_fields ~w(id title project updated_at messages runs bytes running open pinned deletable reason)

  @languages ~w(elixir erlang typescript javascript python rust go c cpp ruby java swift zig)
  @lsp_defaults %{
    "elixir" => "elixir-ls --stdio",
    "erlang" => nil,
    "typescript" => "typescript-language-server --stdio",
    "javascript" => "typescript-language-server --stdio",
    "python" => "pyright-langserver --stdio",
    "rust" => "rust-analyzer",
    "go" => "gopls serve",
    "c" => "clangd --log=error",
    "cpp" => "clangd --log=error",
    "ruby" => "solargraph stdio",
    "java" => "jdtls",
    "swift" => "sourcekit-lsp",
    "zig" => "zls"
  }
  @lsp_extensions %{
    "elixir" => ".ex .exs",
    "erlang" => ".erl .hrl",
    "typescript" => ".ts .tsx",
    "javascript" => ".js .jsx .mjs .cjs",
    "python" => ".py",
    "rust" => ".rs",
    "go" => ".go",
    "c" => ".c .h",
    "cpp" => ".cpp .cxx .cc .hpp",
    "ruby" => ".rb .rake",
    "java" => ".java",
    "swift" => ".swift",
    "zig" => ".zig"
  }

  @max_models 2_000
  @max_tools 512
  @page 200
  @key_format ~r/^[a-z0-9][a-z0-9_-]{0,23}$/
  @variable ~r/^(?:\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*))$/
  @env_name ~r/^[A-Za-z_][A-Za-z0-9_]*$/
  @header_name ~r/^[A-Za-z0-9-]+$/
  @command_name ~r/^[a-z0-9._-]{1,64}$/
  @agent_name ~r/^[a-z0-9][a-z0-9_-]{0,23}$/
  @skill_name ~r/^[A-Za-z0-9._-]{1,64}$/

  @actions ~w(provider.create provider.update provider.set_key provider.clear_key provider.delete
              provider.test provider.fetch_models provider.apply_models provider.fetch_all
              provider.forget_caps efforts.save efforts.remove_override pricing.put_row
              pricing.delete_row search.update search.set_key search.clear_key search.move
              search.test mcp.create mcp.update mcp.set_secret mcp.toggle mcp.set_tools
              mcp.reconnect mcp.test mcp.delete mcp.import.read mcp.import.apply storage.measure
              storage.plan storage.run storage.vacuum storage.apply_retention lsp.check lsp.stop
              lsp.remove_key file.save file.create file.delete file.clear workflow.smoke
              project_config.put_hook project_config.delete_hook project_config.move_hook
              project_config.put_profile project_config.delete_profile project_config.remove_key
              project_config.remove_entry)

  @record_kinds ~w(providers provider model_options effort_presets pricing_rows unpriced_models
                   search_providers search_provider mcp_servers mcp_server storage_sessions
                   memory_files commands agent_defs skills workflows project_config)

  @not_cancellable ~w(storage.run storage.vacuum storage.apply_retention)

  @type state :: map()
  @type result :: %{required(String.t()) => term()}
  @type task :: %{required(String.t()) => term()}

  @doc "The Appendix A ids, for tests and `Fake.Settings`' seed."
  def ids do
    %{
      ailogic: @ailogic,
      notes: @notes,
      conversation: @conversation,
      deepseek: @deepseek,
      anthropic: @anthropic,
      ollama: @ollama,
      openrouter: @openrouter,
      github: @github,
      fs: @fs,
      docs: @docs
    }
  end

  @doc "Every action this module simulates (the S2 actions of §3.4.3)."
  @spec actions() :: [String.t()]
  def actions, do: @actions

  @doc "Whether `action` is simulated here."
  def handles?(action), do: action in @actions

  @doc "The record kinds `query/2` answers (`records`/`record` views)."
  def record_kinds, do: @record_kinds

  @doc "Whether a task of `action` may be cancelled (§3.3.8)."
  def cancellable?(action), do: action not in @not_cancellable

  @doc """
  The Appendix A integration state. Options: `:now` (ISO-8601 string used for `at`
  stamps and `updated_at`), `:env` (the environment `mcp.import` reads, default
  `%{"GITHUB_TOKEN" => "set"}` — only presence matters), `:defaults` (the `models.*`
  pairs that point at providers, `key => {provider_id, model}`).
  """
  @spec seed(keyword()) :: state()
  def seed(opts \\ []) do
    now = Keyword.get(opts, :now, "2026-09-25T18:40:00Z")

    %{
      now: now,
      revision: 1,
      env: Keyword.get(opts, :env, %{"GITHUB_TOKEN" => "set"}),
      defaults:
        Keyword.get(opts, :defaults, %{
          "models.chat" => {@deepseek, "deepseek-v4-pro"},
          "models.sub_agent" => {@deepseek, "deepseek-v4-flash"}
        }),
      providers: seed_providers(now),
      fetches: %{},
      caps: %{
        @anthropic => %{
          "effort_rejected" => false,
          "prefix_cache_rejected" => true,
          "fallbacks_rejected" => false
        }
      },
      provider_tests: %{},
      pricing: %{
        "deepseek-v4-pro" => %{"input" => 0.27, "output" => 1.1},
        "deepseek-v4-flash" => %{"input" => 0.07, "output" => 0.28},
        "claude-opus-5" => %{"input" => 15, "output" => 75, "context_window" => 200_000}
      },
      unpriced_usage: %{"claude-sonnet-5" => 14, "qwen3-coder" => 3},
      search: seed_search(),
      search_tests: %{},
      mcp: seed_mcp(now),
      imports: %{},
      storage: %{
        measured: false,
        sessions: seed_sessions(),
        plans: %{},
        last_cleanup_at: "2026-09-13T09:00:00Z",
        running: false
      },
      retention: %{retention_days: nil, prune_days: nil},
      lsp_servers: %{"erlang" => "erlang_ls", "kotlin" => "kotlin-language-server"},
      files: seed_files(),
      library: seed_library(),
      project_config: %{@ailogic => seed_project_config(), @notes => nil},
      trusted: %{@ailogic => true, @notes => false},
      smoke: %{
        "workflow:user:-:nightly" => "ok",
        "workflow:project:#{@ailogic}:broken" => "calls System.os_time/0"
      }
    }
  end

  # ---------------------------------------------------------------- queries

  @doc """
  Answers a `settings.query` of the views this module owns: `records`/`record` of the
  kinds in `record_kinds/0` and `file`. Returns `{:ok, body}`, `{:error, status,
  message}` or `:unsupported` (a view or kind `Fake.Settings` answers itself).
  """
  @spec query(state(), map()) :: {:ok, map()} | {:error, String.t(), String.t()} | :unsupported
  def query(state, params) do
    view = get(params, "view")
    kind = get(params, "kind")
    options = get(params, "options") || %{}

    case {view, kind} do
      {"records", kind} when kind in @record_kinds ->
        records(state, kind, params, options)

      {"record", kind} when kind in @record_kinds ->
        record(state, kind, get(params, "id"), options)

      {"file", _} ->
        file_view(state, get(params, "id") || get(options, "ref"))

      _ ->
        :unsupported
    end
  end

  defp records(state, "providers", params, _options),
    do: page("providers", Enum.map(provider_list(state), &provider_summary(state, &1)), params)

  defp records(state, "model_options", params, options) do
    only = get(options, "provider_id")

    items =
      state
      |> provider_list()
      |> Enum.filter(&(only in [nil, &1["id"]]))
      |> Enum.flat_map(fn p ->
        models = Enum.sort(Enum.uniq(p["models"] ++ List.wrap(p["default_model"])))
        fetched = fetched_models(state, p["id"])

        for m <- models do
          row = Map.get(state.pricing, m)

          fields = %{
            "provider_id" => p["id"],
            "provider_name" => p["name"],
            "provider_kind" => p["kind"],
            "model" => m,
            "price" => row && price(row),
            "context_window" => row && row["context_window"],
            "in_last_fetch" => if(fetched, do: m in fetched, else: nil),
            "provider_default" => m == p["default_model"]
          }

          rec("model_option", "#{p["id"]}:#{m}", fields)
        end
      end)

    page("model_options", items, params)
  end

  defp records(_state, "effort_presets", params, options) do
    kind = get(options, "kind")

    items =
      for p <- presets(), kind in [nil | p["kinds"]] do
        rec("effort_preset", p["id"], p)
      end

    page("effort_presets", items, params)
  end

  defp records(state, "pricing_rows", params, _options) do
    items =
      state.pricing
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {model, row} -> rec("pricing_row", model, pricing_fields(model, row)) end)

    page("pricing_rows", items, params)
  end

  defp records(state, "unpriced_models", params, _options) do
    page("unpriced_models", unpriced(state), params)
  end

  defp records(state, "search_providers", params, _options),
    do: page("search_providers", Enum.map(search_list(state), &search_record(state, &1)), params)

  defp records(state, "mcp_servers", params, options) do
    project = get(options, "project_id") || @ailogic

    items =
      state.mcp
      |> Map.values()
      |> Enum.filter(&(&1["project_id"] in [nil, project]))
      |> Enum.sort_by(&{&1["project_id"] != nil, &1["name"]})
      |> Enum.map(&mcp_record(&1, false))

    page("mcp_servers", items, params)
  end

  defp records(state, "storage_sessions", params, options) do
    if state.storage.measured do
      filter = String.downcase(get(options, "filter") || "")

      items =
        state.storage.sessions
        |> Enum.filter(fn s ->
          filter == "" or
            String.contains?(String.downcase(s["title"] <> " " <> s["project"]), filter)
        end)
        |> sort_sessions(get(options, "sort") || "bytes")
        |> Enum.map(&rec("storage_session", &1["id"], Map.take(&1, @session_fields)))

      page("storage_sessions", items, params)
    else
      {:error, "not_found", "measure first"}
    end
  end

  defp records(state, "memory_files", params, options) do
    project = get(options, "project_id") || @ailogic

    refs = [
      "memory_project:project:#{project}:MEMORY",
      "memory_global:global:-:MEMORY",
      "instructions:project:#{project}:AGENTS"
    ]

    items = Enum.map(refs, &rec("file", &1, file_meta(state, &1)))
    page("memory_files", items, params)
  end

  defp records(state, kind, params, options)
       when kind in ~w(commands agent_defs skills workflows) do
    project = get(options, "project_id") || @ailogic

    items =
      state.library
      |> Map.get(kind, [])
      |> Enum.filter(&(&1["project_id"] in [nil, project]))
      |> Enum.map(fn item ->
        fields = Map.delete(item, "project_id")

        fields =
          if kind == "workflows",
            do: Map.put(fields, "smoke", Map.get(state.smoke, item["ref"])),
            else: fields

        rec(singular(kind), item["ref"], Map.delete(fields, "ref"))
      end)

    page(kind, items, params)
  end

  defp records(_state, _kind, _params, _options), do: :unsupported

  defp record(state, "provider", id, _options) do
    case Map.get(state.providers, id) do
      nil -> {:error, "not_found", "that provider no longer exists"}
      p -> {:ok, %{"kind" => "provider", "id" => id, "fields" => provider_full(state, p)}}
    end
  end

  defp record(state, "search_provider", kind, _options) do
    case Enum.find(search_list(state), &(&1["kind"] == kind)) do
      nil -> {:error, "not_found", "no such search provider"}
      row -> {:ok, search_record(state, row)}
    end
  end

  defp record(state, "mcp_server", id, _options) do
    case Map.get(state.mcp, id) do
      nil -> {:error, "not_found", "that server no longer exists"}
      s -> {:ok, mcp_record(s, true)}
    end
  end

  defp record(state, "project_config", id, _options) do
    case Map.fetch(state.project_config, id) do
      :error ->
        {:error, "not_found", "no such project"}

      {:ok, config} ->
        {:ok,
         %{
           "kind" => "project_config",
           "id" => id,
           "fields" => project_config_fields(state, id, config)
         }}
    end
  end

  defp record(_state, _kind, _id, _options), do: :unsupported

  defp file_view(state, ref) do
    case Map.fetch(state.files, ref || "") do
      {:ok, file} ->
        meta = file_meta(state, ref)
        content = if meta["too_large"], do: nil, else: file.content
        {:ok, %{"file" => Map.put(meta, "content", content)}}

      :error ->
        if is_binary(ref) and String.starts_with?(ref, "instructions:") do
          {:ok, %{"file" => Map.put(file_meta(state, ref), "content", nil)}}
        else
          {:error, "not_found", "that file does not exist"}
        end
    end
  end

  # --------------------------------------------------------------- commands

  @doc """
  Runs one `settings.command` (string-keyed: `action`, `target`, `attributes`,
  `expected`, `secrets`, `dry_run`). Returns `{{:ok, result}, state}` or
  `{{:task, task, result}, state}` — a task the caller starts (its lifecycle is the
  caller's) and finishes later with `run_task/3`. `:unsupported` for an action this
  module does not simulate.
  """
  @spec command(state(), map()) ::
          {{:ok, result()} | {:task, task(), result()}, state()} | :unsupported
  def command(state, cmd) do
    action = get(cmd, "action")

    if action in @actions do
      run(action, normalize(cmd), state)
    else
      :unsupported
    end
  end

  defp normalize(cmd) do
    %{
      action: get(cmd, "action"),
      target: get(cmd, "target") || %{},
      attributes: get(cmd, "attributes") || %{},
      expected: get(cmd, "expected"),
      secrets: get(cmd, "secrets") || [],
      dry_run: get(cmd, "dry_run") == true
    }
  end

  # providers

  defp run("provider.create", c, state) do
    attrs = c.attributes

    fields = %{
      "name" => trim(get(attrs, "name")),
      "kind" => get(attrs, "kind") || "openai_compatible",
      "base_url" => normalize_url(get(attrs, "base_url")),
      "models" => clean_models(get(attrs, "models") || []),
      "default_model" => blank_nil(get(attrs, "default_model")),
      "fallbacks" => get(attrs, "fallbacks") == true,
      "effort_levels" => get(attrs, "effort_levels"),
      "model_effort_levels" => %{}
    }

    errors = provider_errors(state, fields, nil)

    secret_error =
      case secret(c, "api_key") do
        nil -> nil
        value -> check_paste(value)
      end

    cond do
      errors != [] ->
        {{:ok, result("rejected", field_errors: errors, message: first_message(errors))}, state}

      secret_error ->
        {{:ok,
          result("rejected",
            field_errors: [%{"target" => "api_key", "message" => secret_error}],
            message: secret_error
          )}, state}

      c.dry_run ->
        {{:ok, result("accepted")}, state}

      true ->
        id = new_id(state, "0d5e0000-0000-4000-9000-")
        key = secret_mask(secret(c, "api_key"))

        provider =
          fields
          |> Map.merge(%{"id" => id, "api_key" => key, "updated_at" => stamp(state)})

        state = bump(%{state | providers: Map.put(state.providers, id, provider)})

        {{:ok,
          result("accepted",
            record: rec("provider", provider["id"], provider_full(state, provider)),
            message: "Added #{fields["name"]}"
          )}, state}
    end
  end

  defp run("provider.update", c, state) do
    with_provider(state, c, fn p ->
      attrs =
        Map.take(
          stringify(c.attributes),
          ~w(name kind base_url models default_model fallbacks effort_levels model_effort_levels)
        )

      attrs = normalize_provider_attrs(attrs)

      with :ok <- cas_fields(p, c.expected),
           [] <- provider_errors(state, Map.merge(p, attrs), p["id"]) do
        if c.dry_run do
          {{:ok, result("accepted")}, state}
        else
          updated =
            p
            |> Map.merge(attrs)
            |> Map.put("updated_at", stamp(state))

          tests =
            if Map.has_key?(attrs, "base_url") and attrs["base_url"] != p["base_url"],
              do: Map.delete(state.provider_tests, p["id"]),
              else: state.provider_tests

          caps = Map.delete(state.caps, p["id"])

          state =
            bump(%{
              state
              | providers: Map.put(state.providers, p["id"], updated),
                provider_tests: tests,
                caps: caps
            })

          status = if Map.take(p, Map.keys(attrs)) == attrs, do: "unchanged", else: "accepted"

          {{:ok,
            result(status,
              record: rec("provider", updated["id"], provider_full(state, updated)),
              results: field_results(attrs)
            )}, state}
        end
      else
        {:conflict, rows} ->
          {{:ok, result("conflict", results: rows, message: "changed while you edited")}, state}

        errors when is_list(errors) ->
          {{:ok, result("rejected", field_errors: errors, message: first_message(errors))}, state}
      end
    end)
  end

  defp run("provider.set_key", c, state) do
    with_provider(state, c, fn p ->
      value = secret(c, "api_key")

      cond do
        value == nil ->
          {{:ok, result("rejected", message: "paste the key first")}, state}

        msg = check_paste(value) ->
          {{:ok,
            result("rejected",
              field_errors: [%{"target" => "api_key", "message" => msg}],
              message: msg
            )}, state}

        (conflict = cas_key(p["api_key"], c.expected)) != :ok ->
          {{:ok, result("conflict", results: [conflict], message: "changed while you edited")},
           state}

        c.dry_run ->
          {{:ok, result("accepted")}, state}

        get(c.attributes, "test_first") == true ->
          task = task("provider.set_key", %{"id" => p["id"]}, %{"hint" => secret_mask(value)})
          {{:task, task, result("accepted", message: "checking the new key")}, state}

        true ->
          updated = %{p | "api_key" => secret_mask(value), "updated_at" => stamp(state)}
          state = bump(put_in(state.providers[p["id"]], updated))

          {{:ok,
            result("accepted",
              record: rec("provider", updated["id"], provider_full(state, updated)),
              message: "#{p["name"]} API key saved#{ends(updated["api_key"])}"
            )}, state}
      end
    end)
  end

  defp run("provider.clear_key", c, state) do
    with_provider(state, c, fn p ->
      case cas_key(p["api_key"], c.expected) do
        :ok ->
          updated = %{
            p
            | "api_key" => %{"set" => false, "hint" => nil},
              "updated_at" => stamp(state)
          }

          state = bump(put_in(state.providers[p["id"]], updated))

          {{:ok,
            result("accepted",
              record: rec("provider", updated["id"], provider_full(state, updated)),
              message: "#{p["name"]} API key removed"
            )}, state}

        conflict ->
          {{:ok, result("conflict", results: [conflict], message: "changed while you edited")},
           state}
      end
    end)
  end

  defp run("provider.delete", c, state) do
    with_provider(state, c, fn p ->
      expected = get(c.expected || %{}, "updated_at")
      serves = serves(state, p["id"])
      replacements = get(c.attributes, "replacements") || %{}
      missing = Enum.reject(serves, &Map.has_key?(replacements, &1))

      cond do
        expected not in [nil, p["updated_at"]] ->
          {{:ok,
            result("conflict",
              results: [
                %{"target" => "updated_at", "status" => "conflict", "current" => p["updated_at"]}
              ],
              message: "changed while you edited"
            )}, state}

        missing != [] ->
          {{:ok,
            result("rejected",
              field_errors:
                Enum.map(missing, &%{"target" => &1, "message" => "pick a replacement"}),
              message: "pick a replacement for every default it serves"
            )}, state}

        true ->
          defaults =
            Enum.reduce(replacements, state.defaults, fn {key, value}, acc ->
              case value do
                %{"provider_id" => pid, "model" => m} -> Map.put(acc, key, {pid, m})
                nil -> Map.delete(acc, key)
                _ -> acc
              end
            end)

          results =
            for {key, value} <- replacements,
                do: %{"target" => key, "status" => "accepted", "value" => value}

          state =
            bump(%{
              state
              | providers: Map.delete(state.providers, p["id"]),
                defaults: defaults,
                provider_tests: Map.delete(state.provider_tests, p["id"])
            })

          {{:ok, result("accepted", results: results, message: "#{p["name"]} deleted")}, state}
      end
    end)
  end

  defp run("provider.test", c, state) do
    if get(c.target, "draft") == true do
      {{:task,
        task("provider.test", %{"draft" => true}, %{"base_url" => get(c.attributes, "base_url")}),
        result("accepted")}, state}
    else
      with_provider(state, c, fn p ->
        {{:task, task("provider.test", %{"id" => p["id"]}), result("accepted")}, state}
      end)
    end
  end

  defp run("provider.fetch_models", c, state) do
    # `attributes.listed` is a test hook: the list the simulated server answers
    listed = get(c.attributes, "listed")
    attrs = if is_list(listed), do: %{"listed" => listed}, else: %{}

    with_provider(state, c, fn p ->
      {{:task, task("provider.fetch_models", %{"id" => p["id"]}, attrs), result("accepted")},
       state}
    end)
  end

  defp run("provider.fetch_all", _c, state),
    do: {{:task, task("provider.fetch_all", nil), result("accepted")}, state}

  defp run("provider.apply_models", c, state) do
    with_provider(state, c, fn p ->
      fetch = Map.get(state.fetches, get(c.attributes, "fetch_task_id"))
      mode = get(c.attributes, "mode")

      cond do
        fetch == nil or fetch.provider_id != p["id"] ->
          {{:ok, result("not_found", message: "fetch again first")}, state}

        cas_fields(p, c.expected) != :ok ->
          {:conflict, rows} = cas_fields(p, c.expected)
          {{:ok, result("conflict", results: rows, message: "changed while you edited")}, state}

        mode == "replace" and fetch.truncated ->
          {{:ok,
            result("rejected", message: "the list was longer than 2 000; add new ones instead")},
           state}

        mode not in ["replace", "add"] ->
          {{:ok, result("rejected", message: "is invalid")}, state}

        true ->
          {models, message} =
            if mode == "replace" do
              {fetch.listed, nil}
            else
              new = Enum.reject(fetch.listed, &(&1 in p["models"]))
              room = max(@max_models - length(p["models"]), 0)
              added = Enum.take(new, room)
              left = length(new) - length(added)
              {p["models"] ++ added, if(left > 0, do: "#{left} not added: 2 000 models at most")}
            end

          updated = %{p | "models" => models, "updated_at" => stamp(state)}
          state = bump(put_in(state.providers[p["id"]], updated))

          {{:ok,
            result("accepted",
              record: rec("provider", updated["id"], provider_full(state, updated)),
              message: message || "#{p["name"]} now lists #{length(models)} models"
            )}, state}
      end
    end)
  end

  defp run("provider.forget_caps", c, state) do
    with_provider(state, c, fn p ->
      state = %{state | caps: Map.delete(state.caps, p["id"])}

      {{:ok,
        result("accepted",
          record: rec("provider", p["id"], provider_full(state, p)),
          message: "Forgot what this session learned about #{p["name"]}"
        )}, state}
    end)
  end

  # efforts

  defp run("efforts.save", c, state) do
    with_provider(state, c, fn p ->
      model = get(c.target, "model")
      rows = get(c.attributes, "rows") || []

      current =
        if model, do: get(p["model_effort_levels"] || %{}, model), else: p["effort_levels"]

      with :ok <- cas_value(current, get(c.expected || %{}, "levels"), "levels"),
           {:ok, levels} <- effort_rows(rows) do
        updated =
          if model do
            mel = p["model_effort_levels"] || %{}
            mel = if levels == [], do: Map.delete(mel, model), else: Map.put(mel, model, levels)
            %{p | "model_effort_levels" => mel}
          else
            %{p | "effort_levels" => if(levels == [], do: nil, else: levels)}
          end

        updated = %{updated | "updated_at" => stamp(state)}
        state = bump(put_in(state.providers[p["id"]], updated))

        {{:ok,
          result("accepted",
            record: rec("provider", updated["id"], provider_full(state, updated)),
            message: "Saved #{length(levels)} effort levels"
          )}, state}
      else
        {:conflict, row} ->
          {{:ok, result("conflict", results: [row], message: "changed while you edited")}, state}

        {:error, errors} ->
          {{:ok, result("rejected", field_errors: errors, message: first_message(errors))}, state}
      end
    end)
  end

  defp run("efforts.remove_override", c, state) do
    with_provider(state, c, fn p ->
      model = get(c.target, "model")
      mel = p["model_effort_levels"] || %{}

      case cas_value(Map.get(mel, model), get(c.expected || %{}, "levels"), "levels") do
        :ok ->
          updated = %{
            p
            | "model_effort_levels" => Map.delete(mel, model),
              "updated_at" => stamp(state)
          }

          state = bump(put_in(state.providers[p["id"]], updated))

          {{:ok,
            result("accepted",
              record: rec("provider", updated["id"], provider_full(state, updated)),
              message: "#{model} uses the provider's levels again"
            )}, state}

        {:conflict, row} ->
          {{:ok, result("conflict", results: [row], message: "changed while you edited")}, state}
      end
    end)
  end

  # pricing

  defp run("pricing.put_row", c, state) do
    attrs = c.attributes
    model = trim(get(attrs, "model"))
    rename_from = get(attrs, "rename_from")
    old = Map.get(state.pricing, rename_from || model)
    expected = c.expected || %{}

    errors = pricing_errors(state, model, rename_from, attrs)

    cond do
      model == "" ->
        {{:ok,
          result("rejected",
            field_errors: [%{"target" => "model", "message" => "can't be blank"}],
            message: "can't be blank"
          )}, state}

      Map.has_key?(expected, "row") and not same?(pricing_wire(old), get(expected, "row")) ->
        {{:ok,
          result("conflict",
            results: [
              %{
                "target" => rename_from || model,
                "status" => "conflict",
                "current" => pricing_wire(old)
              }
            ],
            message: "changed while you edited"
          )}, state}

      errors != [] ->
        {{:ok, result("rejected", field_errors: errors, message: first_message(errors))}, state}

      true ->
        row =
          %{
            "input" => get(attrs, "input"),
            "output" => get(attrs, "output"),
            "cache_read" => get(attrs, "cache_read"),
            "cache_write" => get(attrs, "cache_write"),
            "context_window" => get(attrs, "context_window")
          }
          |> Enum.reject(fn {_, v} -> v == nil end)
          |> Map.new()

        pricing = state.pricing |> Map.delete(rename_from) |> Map.put(model, row)
        state = bump(%{state | pricing: pricing})

        {{:ok,
          result("accepted",
            record: rec("pricing_row", model, pricing_fields(model, row)),
            message: "Priced #{model}"
          )}, state}
    end
  end

  defp run("pricing.delete_row", c, state) do
    model = get(c.target, "model")

    case Map.fetch(state.pricing, model || "") do
      :error ->
        {{:ok, result("not_found", message: "#{model} has no price")}, state}

      {:ok, row} ->
        if Map.has_key?(c.expected || %{}, "row") and
             not same?(pricing_wire(row), get(c.expected, "row")) do
          {{:ok,
            result("conflict",
              results: [
                %{"target" => model, "status" => "conflict", "current" => pricing_wire(row)}
              ],
              message: "changed while you edited"
            )}, state}
        else
          state = bump(%{state | pricing: Map.delete(state.pricing, model)})
          {{:ok, result("accepted", message: "Removed the price of #{model}")}, state}
        end
    end
  end

  # search

  defp run("search.update", c, state) do
    with_search(state, c, fn row ->
      attrs = Map.take(stringify(c.attributes), ~w(enabled base_url))

      attrs =
        if Map.has_key?(attrs, "base_url"),
          do: Map.put(attrs, "base_url", blank_nil(normalize_url(attrs["base_url"]))),
          else: attrs

      cond do
        cas_fields(row, c.expected) != :ok ->
          {:conflict, rows} = cas_fields(row, c.expected)
          {{:ok, result("conflict", results: rows, message: "changed while you edited")}, state}

        attrs["enabled"] == true and needs_key?(row["kind"]) and not row["api_key"]["set"] ->
          {{:ok,
            result("rejected",
              field_errors: [
                %{"target" => "enabled", "message" => "is needed to enable #{row["kind"]}"}
              ],
              message: "is needed to enable #{row["kind"]}"
            )}, state}

        is_binary(attrs["base_url"]) and not url?(attrs["base_url"]) ->
          {{:ok,
            result("rejected",
              field_errors: [
                %{"target" => "base_url", "message" => "must start with http:// or https://"}
              ],
              message: "must start with http:// or https://"
            )}, state}

        true ->
          updated = Map.merge(row, attrs)
          state = bump(put_in(state.search[row["kind"]], updated))
          status = if Map.take(row, Map.keys(attrs)) == attrs, do: "unchanged", else: "accepted"

          {{:ok,
            result(status, record: search_record(state, updated), results: field_results(attrs))},
           state}
      end
    end)
  end

  defp run("search.set_key", c, state) do
    with_search(state, c, fn row ->
      value = secret(c, "api_key")

      cond do
        value == nil ->
          {{:ok, result("rejected", message: "paste the key first")}, state}

        msg = check_paste(value) ->
          {{:ok,
            result("rejected",
              field_errors: [%{"target" => "api_key", "message" => msg}],
              message: msg
            )}, state}

        (conflict = cas_key(row["api_key"], c.expected)) != :ok ->
          {{:ok, result("conflict", results: [conflict], message: "changed while you edited")},
           state}

        get(c.attributes, "test_first") == true ->
          {{:task,
            task("search.set_key", %{"kind" => row["kind"]}, %{"hint" => secret_mask(value)}),
            result("accepted", message: "checking the new key")}, state}

        true ->
          updated = %{row | "api_key" => secret_mask(value)}
          state = bump(put_in(state.search[row["kind"]], updated))

          {{:ok,
            result("accepted",
              record: search_record(state, updated),
              message: "#{search_label(row["kind"])} API key saved#{ends(updated["api_key"])}"
            )}, state}
      end
    end)
  end

  defp run("search.clear_key", c, state) do
    with_search(state, c, fn row ->
      case cas_key(row["api_key"], c.expected) do
        :ok ->
          off = row["enabled"] and needs_key?(row["kind"])

          updated = %{
            row
            | "api_key" => %{"set" => false, "hint" => nil},
              "enabled" => row["enabled"] and not off
          }

          state = bump(put_in(state.search[row["kind"]], updated))

          words =
            "#{search_label(row["kind"])} API key removed" <>
              if(off, do: " · turned off", else: "")

          {{:ok, result("accepted", record: search_record(state, updated), message: words)},
           state}

        conflict ->
          {{:ok, result("conflict", results: [conflict], message: "changed while you edited")},
           state}
      end
    end)
  end

  defp run("search.move", c, state) do
    with_search(state, c, fn row ->
      order = engine_order(state)
      dir = get(c.attributes, "dir")
      index = Enum.find_index(order, &(&1 == row["kind"]))
      expected = get(c.expected || %{}, "order")

      cond do
        row["role"] != "engine" ->
          {{:ok, result("rejected", message: "readers have no order")}, state}

        expected != nil and expected != order ->
          {{:ok,
            result("conflict",
              results: [%{"target" => "order", "status" => "conflict", "current" => order}],
              message: "changed while you edited"
            )}, state}

        dir not in [-1, 1] ->
          {{:ok, result("rejected", message: "is invalid")}, state}

        index + dir < 0 or index + dir >= length(order) ->
          {{:ok,
            result("unchanged",
              results: [%{"target" => "order", "status" => "unchanged", "value" => order}]
            )}, state}

        true ->
          other = Enum.at(order, index + dir)

          new_order =
            order |> List.replace_at(index, other) |> List.replace_at(index + dir, row["kind"])

          search =
            new_order
            |> Enum.with_index()
            |> Enum.reduce(state.search, fn {kind, i}, acc -> put_in(acc[kind]["position"], i) end)

          state = bump(%{state | search: search})
          {above, below} = if dir == -1, do: {row["kind"], other}, else: {other, row["kind"]}

          {{:ok,
            result("accepted",
              results: [%{"target" => "order", "status" => "accepted", "value" => new_order}],
              message: "Moved #{search_label(above)} above #{search_label(below)}"
            )}, state}
      end
    end)
  end

  defp run("search.test", c, state) do
    with_search(state, c, fn row ->
      {{:task, task("search.test", %{"kind" => row["kind"]}), result("accepted")}, state}
    end)
  end

  # mcp

  defp run("mcp.create", c, state) do
    attrs = stringify(c.attributes)

    with {:ok, server} <-
           mcp_build(
             state,
             %{
               "enabled" => true,
               "transport" => "stdio",
               "project_id" => nil,
               "args" => [],
               "env" => %{},
               "headers" => %{},
               "disabled_tools" => []
             },
             attrs,
             c,
             nil
           ) do
      id = new_id(state, "3c9a0000-0000-4000-9000-")

      server =
        Map.merge(server, %{
          "id" => id,
          "updated_at" => stamp(state),
          "status" => if(server["enabled"], do: "connecting", else: "stopped"),
          "status_message" => nil,
          "tools" => [],
          "output" => []
        })

      state = bump(%{state | mcp: Map.put(state.mcp, id, server)})

      {{:ok,
        result("accepted", record: mcp_record(server, true), message: "Added #{server["name"]}")},
       state}
    else
      {:error, errors} ->
        {{:ok, result("rejected", field_errors: errors, message: first_message(errors))}, state}
    end
  end

  defp run("mcp.update", c, state) do
    with_mcp(state, c, fn s ->
      attrs = stringify(c.attributes)

      with :ok <- cas_fields(mcp_wire(s), c.expected),
           {:ok, updated} <- mcp_build(state, s, attrs, c, s["id"]) do
        updated = %{
          updated
          | "updated_at" => stamp(state),
            "status" => if(updated["enabled"], do: "connecting", else: "stopped")
        }

        state = bump(put_in(state.mcp[s["id"]], updated))

        {{:ok,
          result("accepted",
            record: mcp_record(updated, true),
            results: field_results(attrs),
            message: "restarts #{updated["name"]}"
          )}, state}
      else
        {:conflict, rows} ->
          {{:ok, result("conflict", results: rows, message: "changed while you edited")}, state}

        {:error, errors} ->
          {{:ok, result("rejected", field_errors: errors, message: first_message(errors))}, state}
      end
    end)
  end

  defp run("mcp.set_secret", c, state) do
    with_mcp(state, c, fn s ->
      map = get(c.target, "map")
      name = get(c.target, "name")
      field = if map == "headers", do: "headers", else: "env"
      slot = if field == "env", do: "env:#{name}", else: "header:#{name}"
      value = secret(c, slot) || secret(c, "value")
      current = Map.get(s[field], name)

      current_key =
        if current,
          do: %{"set" => true, "hint" => hint(current)},
          else: %{"set" => false, "hint" => nil}

      cond do
        value == nil ->
          {{:ok, result("rejected", message: "paste the value first")}, state}

        (conflict = cas_key(current_key, c.expected)) != :ok ->
          {{:ok, result("conflict", results: [conflict], message: "changed while you edited")},
           state}

        true ->
          # the fake keeps a placeholder of the same hint, never the pasted bytes
          updated = put_in(s[field][name], placeholder(value))
          state = bump(put_in(state.mcp[s["id"]], updated))

          {{:ok,
            result("accepted",
              record: mcp_record(updated, true),
              message: "#{name} saved · restarts #{s["name"]}"
            )}, state}
      end
    end)
  end

  defp run("mcp.toggle", c, state) do
    with_mcp(state, c, fn s ->
      enabled = get(c.attributes, "enabled") == true

      case cas_fields(%{"enabled" => s["enabled"]}, c.expected) do
        :ok ->
          status = if enabled, do: "connecting", else: "stopped"
          updated = %{s | "enabled" => enabled, "status" => status, "status_message" => nil}
          state = bump(put_in(state.mcp[s["id"]], updated))
          words = if enabled, do: "#{s["name"]} on", else: "#{s["name"]} off · stopped"
          st = if enabled == s["enabled"], do: "unchanged", else: "accepted"
          {{:ok, result(st, record: mcp_record(updated, true), message: words)}, state}

        {:conflict, rows} ->
          {{:ok, result("conflict", results: rows, message: "changed while you edited")}, state}
      end
    end)
  end

  defp run("mcp.set_tools", c, state) do
    with_mcp(state, c, fn s ->
      changes = get(c.attributes, "tools") || %{}
      expected = get(c.expected || %{}, "disabled_tools")

      cond do
        map_size(changes) > @max_tools ->
          {{:ok, result("rejected", message: "#{@max_tools} tools at most")}, state}

        expected != nil and Enum.sort(expected) != Enum.sort(s["disabled_tools"]) ->
          {{:ok,
            result("conflict",
              results: [
                %{
                  "target" => "disabled_tools",
                  "status" => "conflict",
                  "current" => s["disabled_tools"]
                }
              ],
              message: "changed while you edited"
            )}, state}

        true ->
          disabled =
            Enum.reduce(changes, MapSet.new(s["disabled_tools"]), fn {name, on}, acc ->
              if on, do: MapSet.delete(acc, name), else: MapSet.put(acc, name)
            end)

          known = MapSet.new(s["tools"], & &1["name"])
          disabled = disabled |> MapSet.intersection(known) |> Enum.sort()
          updated = %{s | "disabled_tools" => disabled}
          state = bump(put_in(state.mcp[s["id"]], updated))
          on = length(s["tools"]) - length(disabled)

          {{:ok,
            result("accepted",
              record: mcp_record(updated, true),
              message: "#{s["name"]}: #{on} of #{length(s["tools"])} tools on"
            )}, state}
      end
    end)
  end

  defp run("mcp.reconnect", c, state) do
    with_mcp(state, c, fn s ->
      if s["enabled"] do
        {{:task, task("mcp.reconnect", %{"id" => s["id"]}), result("accepted")}, state}
      else
        {{:ok, result("rejected", message: "turn it on first")}, state}
      end
    end)
  end

  defp run("mcp.test", c, state) do
    if get(c.target, "draft") == true do
      attrs = stringify(c.attributes)

      case mcp_build(
             state,
             %{
               "enabled" => true,
               "transport" => "stdio",
               "project_id" => nil,
               "args" => [],
               "env" => %{},
               "headers" => %{},
               "disabled_tools" => []
             },
             attrs,
             c,
             :draft
           ) do
        {:ok, draft} ->
          {{:task,
            task("mcp.test", %{"draft" => true}, %{
              "name" => draft["name"],
              "command" => draft["command"]
            }), result("accepted")}, state}

        {:error, errors} ->
          {{:ok, result("rejected", field_errors: errors, message: first_message(errors))}, state}
      end
    else
      with_mcp(state, c, fn s ->
        {{:task, task("mcp.test", %{"id" => s["id"]}), result("accepted")}, state}
      end)
    end
  end

  defp run("mcp.delete", c, state) do
    with_mcp(state, c, fn s ->
      expected = get(c.expected || %{}, "updated_at")

      if expected in [nil, s["updated_at"]] do
        state = bump(%{state | mcp: Map.delete(state.mcp, s["id"])})
        {{:ok, result("accepted", message: "Deleted #{s["name"]}")}, state}
      else
        {{:ok,
          result("conflict",
            results: [
              %{"target" => "updated_at", "status" => "conflict", "current" => s["updated_at"]}
            ],
            message: "changed while you edited"
          )}, state}
      end
    end)
  end

  defp run("mcp.import.read", c, state) do
    path = get(c.attributes, "path")

    {{:task, task("mcp.import.read", nil, %{"path" => path}),
      result("accepted", message: "reading .mcp.json")}, state}
  end

  defp run("mcp.import.apply", c, state) do
    attrs = c.attributes
    import = Map.get(state.imports, get(attrs, "import_id"))

    if import == nil do
      {{:ok, result("not_found", message: "that preview is gone; read the file again")}, state}
    else
      names = get(attrs, "names") || []
      renames = get(attrs, "rename") || %{}
      choices = get(attrs, "values") || %{}
      project = get(attrs, "project_id")

      {results, state} =
        Enum.map_reduce(names, state, fn name, st ->
          case Enum.find(import.drafts, &(&1.name == name)) do
            nil ->
              {%{"target" => name, "status" => "not_found", "message" => "not in the file"}, st}

            draft ->
              import_one(
                st,
                draft,
                Map.get(renames, name, name),
                Map.get(choices, name, %{}),
                project,
                c
              )
          end
        end)

      created = Enum.count(results, &(&1["status"] == "accepted"))
      status = if created > 0, do: "accepted", else: "rejected"

      {{:ok,
        result(status,
          results: results,
          message: "Imported #{created} of #{length(names)} servers"
        )}, state}
    end
  end

  # storage

  defp run("storage.measure", _c, state),
    do: {{:task, task("storage.measure", nil), result("accepted")}, state}

  defp run("storage.plan", c, state) do
    if state.storage.measured do
      {{:task,
        task("storage.plan", %{"slot" => "wizard"}, %{
          "selection" => get(c.attributes, "selection") || %{}
        }), result("accepted")}, state}
    else
      {{:ok, result("not_found", message: "measure first")}, state}
    end
  end

  defp run("storage.run", c, state) do
    plan = Map.get(state.storage.plans, get(c.attributes, "plan_id"))

    cond do
      plan == nil ->
        {{:ok, result("not_found", message: "plan again first")}, state}

      state.storage.running ->
        {{:ok, result("busy", message: "A cleanup is already running.")}, state}

      true ->
        {{:task, task("storage.run", nil, %{"plan_id" => get(c.attributes, "plan_id")}),
          result("accepted")}, put_in(state.storage.running, true)}
    end
  end

  defp run("storage.vacuum", _c, state) do
    if state.storage.running,
      do: {{:ok, result("busy", message: "A cleanup is already running.")}, state},
      else:
        {{:task, task("storage.vacuum", nil), result("accepted")},
         put_in(state.storage.running, true)}
  end

  defp run("storage.apply_retention", _c, state) do
    cond do
      state.retention.retention_days == nil and state.retention.prune_days == nil ->
        {{:ok, result("rejected", message: "set a retention first")}, state}

      state.storage.running ->
        {{:ok, result("busy", message: "A cleanup is already running.")}, state}

      true ->
        {{:task, task("storage.apply_retention", nil), result("accepted")},
         put_in(state.storage.running, true)}
    end
  end

  # language servers

  defp run("lsp.check", _c, state),
    do: {{:task, task("lsp.check", nil), result("accepted")}, state}

  defp run("lsp.stop", c, state) do
    words =
      if get(c.target, "all") == true,
        do: "Stopped the language servers of every project",
        else: "Stopped the language servers of this project"

    {{:ok, result("accepted", message: words)}, state}
  end

  defp run("lsp.remove_key", c, state) do
    key = get(c.target, "key")

    cond do
      key in @languages or not Map.has_key?(state.lsp_servers, key || "") ->
        {{:ok,
          result("rejected",
            message: "only a key that is not a known language can be removed here"
          )}, state}

      Map.has_key?(c.expected || %{}, "value") and
          get(c.expected, "value") != state.lsp_servers[key] ->
        {{:ok,
          result("conflict",
            results: [
              %{"target" => key, "status" => "conflict", "current" => state.lsp_servers[key]}
            ],
            message: "changed while you edited"
          )}, state}

      true ->
        state = bump(%{state | lsp_servers: Map.delete(state.lsp_servers, key)})

        {{:ok,
          result("accepted",
            results: [
              %{"target" => "lsp_servers", "status" => "accepted", "value" => state.lsp_servers}
            ],
            message: "Removed #{key}"
          )}, state}
    end
  end

  # files and library

  defp run("file.save", c, state) do
    ref = get(c.target, "ref")
    content = get(c.attributes, "content")
    expected = get(c.expected || %{}, "fingerprint")

    cond do
      not is_binary(ref) or not valid_ref?(ref) ->
        {{:ok, result("not_found", message: "that file does not exist")}, state}

      not is_binary(content) or byte_size(content) > 262_144 ->
        {{:ok, result("rejected", message: "that is too long to save here")}, state}

      String.contains?(ref, ":bundled:") or String.contains?(ref, ":builtin:") ->
        {{:ok,
          result("rejected",
            message: "a built-in file cannot be changed; make a user copy to override it"
          )}, state}

      expected != nil and expected != fingerprint(Map.get(state.files, ref)) ->
        {{:ok,
          result("conflict",
            results: [
              %{
                "target" => ref,
                "status" => "conflict",
                "current" => %{"fingerprint" => fingerprint(Map.get(state.files, ref))}
              }
            ],
            message: "The file changed while you edited."
          )}, state}

      String.starts_with?(ref, "project_config:") and
          hooks_need_confirmation?(state, ref, content, c.attributes) ->
        items = new_hook_commands(state, ref, content)

        {{:ok,
          result("needs_confirmation",
            confirm: %{"kind" => "hooks", "items" => items},
            message: "new hook commands need your confirmation"
          )}, state}

      true ->
        {ref, state} = save_file(state, ref, content)
        meta = file_meta(state, ref)

        {{:ok,
          result("accepted",
            record: rec("file", ref, meta),
            message: "Saved #{Path.basename(meta["path"])} (#{meta["lines"]} lines)"
          )}, state}
    end
  end

  defp run("file.clear", c, state) do
    ref = get(c.target, "ref")
    expected = get(c.expected || %{}, "fingerprint")

    cond do
      not (is_binary(ref) and String.starts_with?(ref, "memory_")) ->
        {{:ok, result("rejected", message: "only a memory file can be cleared")}, state}

      expected != nil and expected != fingerprint(Map.get(state.files, ref)) ->
        {{:ok,
          result("conflict",
            results: [
              %{
                "target" => ref,
                "status" => "conflict",
                "current" => %{"fingerprint" => fingerprint(Map.get(state.files, ref))}
              }
            ],
            message: "The file changed while you edited."
          )}, state}

      true ->
        {ref, state} = save_file(state, ref, "")

        {{:ok,
          result("accepted",
            record: rec("file", ref, file_meta(state, ref)),
            message: "Cleared #{Path.basename(file_meta(state, ref)["path"])}"
          )}, state}
    end
  end

  defp run("file.create", c, state) do
    kind = get(c.target, "kind")
    scope = get(c.target, "scope")
    project = get(c.target, "project_id")
    name = get(c.target, "name") || ""

    {rule, template, library_kind} =
      case kind do
        "command" ->
          {@command_name, command_template(name), "commands"}

        "agent" ->
          {@agent_name, agent_template(name), "agent_defs"}

        "skill" ->
          {@skill_name, "# #{name}\n\nDescribe what this skill does in the first line.\n",
           "skills"}

        _ ->
          {nil, nil, nil}
      end

    ref = "#{kind}:#{scope}:#{if scope == "project", do: project || @ailogic, else: "-"}:#{name}"

    cond do
      rule == nil or scope not in ~w(project global user) ->
        {{:ok, result("rejected", message: "is invalid")}, state}

      not Regex.match?(rule, name) ->
        {{:ok,
          result("rejected",
            field_errors: [%{"target" => "name", "message" => name_rule_words(kind)}],
            message: name_rule_words(kind)
          )}, state}

      Enum.any?(
        Map.get(state.library, library_kind, []),
        &(&1["name"] == name and &1["scope"] == scope)
      ) ->
        {{:ok,
          result("rejected",
            field_errors: [%{"target" => "name", "message" => "already exists"}],
            message: "already exists"
          )}, state}

      true ->
        {ref, state} = save_file(state, ref, template)
        item = library_item(kind, name, scope, project, ref)

        state = %{
          state
          | library: Map.update(state.library, library_kind, [item], &(&1 ++ [item]))
        }

        {{:ok,
          result("accepted",
            record: rec("file", ref, file_meta(state, ref)),
            message: "Created #{name}"
          )}, state}
    end
  end

  defp run("file.delete", c, state) do
    ref = get(c.target, "ref") || ""

    cond do
      String.contains?(ref, ":bundled:") or String.contains?(ref, ":builtin:") ->
        {{:ok,
          result("rejected",
            message: "a built-in file cannot be deleted; make a user copy to override it"
          )}, state}

      String.starts_with?(ref, "instructions:") ->
        {{:ok,
          result("rejected", message: "edit it instead; delete the file yourself if you mean to")},
         state}

      not Map.has_key?(state.files, ref) ->
        {{:ok, result("not_found", message: "that file does not exist")}, state}

      get(c.expected || %{}, "fingerprint") not in [nil, fingerprint(state.files[ref])] ->
        {{:ok,
          result("conflict",
            results: [
              %{
                "target" => ref,
                "status" => "conflict",
                "current" => %{"fingerprint" => fingerprint(state.files[ref])}
              }
            ],
            message: "The file changed while you edited."
          )}, state}

      true ->
        library =
          Map.new(state.library, fn {k, items} -> {k, Enum.reject(items, &(&1["ref"] == ref))} end)

        state =
          bump(%{
            state
            | files: Map.delete(state.files, ref),
              library: library,
              smoke: Map.delete(state.smoke, ref)
          })

        {{:ok, result("accepted", message: "Deleted #{ref |> String.split(":") |> List.last()}")},
         state}
    end
  end

  defp run("workflow.smoke", c, state) do
    {{:task, task("workflow.smoke", c.target, %{"ref" => get(c.target, "ref")}),
      result("accepted")}, state}
  end

  # project config (U3's pages send these; simulated here so the fake answers them)

  defp run("project_config." <> op, c, state) do
    project = get(c.target, "project_id") || @ailogic

    case Map.fetch(state.project_config, project) do
      :error ->
        {{:ok, result("not_found", message: "no such project")}, state}

      {:ok, config} ->
        config = config || %{}
        expected = get(c.expected || %{}, "fingerprint")

        cond do
          expected != nil and expected != config_fingerprint(config) ->
            {{:ok,
              result("conflict",
                results: [
                  %{
                    "target" => "config",
                    "status" => "conflict",
                    "current" => %{"fingerprint" => config_fingerprint(config)}
                  }
                ],
                message: "The file changed while you edited."
              )}, state}

          true ->
            case project_config_op(op, c, config, Map.get(state.trusted, project, false)) do
              {:ok, next, message} ->
                state = bump(put_in(state.project_config[project], next))

                {{:ok,
                  result("accepted",
                    record: %{
                      "kind" => "project_config",
                      "id" => project,
                      "fields" => project_config_fields(state, project, next)
                    },
                    message: message
                  )}, state}

              {:confirm, items} ->
                {{:ok,
                  result("needs_confirmation",
                    confirm: %{"kind" => "hooks", "items" => items},
                    message: "new hook commands need your confirmation"
                  )}, state}

              {:error, message} ->
                {{:ok, result("rejected", message: message)}, state}
            end
        end
    end
  end

  # ------------------------------------------------------------------ tasks

  @doc """
  Finishes a task started by `command/2`. `outcome` is `:run` (the simulated result,
  Appendix A), `{:ok, summary}` (a test's scripted success) or `{:error, message}` (a
  scripted failure). Returns `{{:done, summary, rows} | {:failed, message}, state}`;
  `rows` are the paged result rows (`view=task`).
  """
  @spec run_task(state(), task(), :run | {:ok, map()} | {:error, String.t()}) ::
          {{:done, map(), [map()]} | {:failed, String.t()}, state()}
  def run_task(state, task, outcome \\ :run)

  def run_task(state, %{"action" => action} = task, {:error, message}) do
    state = if action in @not_cancellable, do: put_in(state.storage.running, false), else: state
    state = remember_test(state, task, "failed", message)

    words =
      if action in ~w(provider.set_key search.set_key),
        do: "The new key was refused (#{message}).",
        else: message

    {{:failed, words}, state}
  end

  def run_task(state, task, {:ok, scripted}) do
    case finish(task["action"], task, state) do
      {{:done, summary, rows}, state} -> {{:done, Map.merge(summary, scripted), rows}, state}
      {{:failed, _message}, state} -> {{:done, scripted, []}, state}
    end
  end

  def run_task(state, task, :run), do: finish(task["action"], task, state)

  defp finish("provider.test", %{"target" => %{"draft" => true}}, state),
    do: {{:done, %{"count" => 2, "ms" => 300}, []}, state}

  defp finish("provider.test", %{"target" => %{"id" => id}} = task, state) do
    case Map.get(state.providers, id) do
      nil ->
        {{:failed, "that provider no longer exists"}, state}

      p ->
        if usable?(p) do
          count = if id == @deepseek, do: 2, else: length(p["models"])
          ms = if id == @deepseek, do: 412, else: 300
          state = remember_test(state, task, "done", nil, %{"count" => count, "ms" => ms})
          {{:done, %{"count" => count, "ms" => ms}, []}, state}
        else
          state = remember_test(state, task, "failed", "the key was refused (401)")
          {{:failed, "the key was refused (401)"}, state}
        end
    end
  end

  defp finish(
         "provider.set_key",
         %{"target" => %{"id" => id}, "attributes" => %{"hint" => mask}},
         state
       ) do
    case Map.get(state.providers, id) do
      nil ->
        {{:failed, "that provider no longer exists"}, state}

      p ->
        updated = %{p | "api_key" => mask, "updated_at" => stamp(state)}
        state = bump(put_in(state.providers[id], updated))
        count = if id == @deepseek, do: 2, else: length(p["models"])
        {{:done, %{"saved" => true, "count" => count, "ms" => 412}, []}, state}
    end
  end

  defp finish("provider.fetch_models", %{"target" => %{"id" => id}} = task, state) do
    case Map.get(state.providers, id) do
      nil ->
        {{:failed, "that provider no longer exists"}, state}

      p ->
        listed = Map.get(task["attributes"] || %{}, "listed") || listed_models(p)
        truncated = length(listed) > @max_models
        kept = Enum.take(listed, @max_models)
        old = p["models"]

        rows =
          (Enum.map(kept, fn m ->
             %{
               "model" => m,
               "change" => if(m in old, do: "same", else: "new"),
               "conversations" => 0
             }
           end) ++
             Enum.map(old -- kept, fn m ->
               %{"model" => m, "change" => "gone", "conversations" => used_by_model(m)}
             end))
          |> Enum.sort_by(&{change_order(&1["change"]), &1["model"]})

        summary = %{
          "listed" => length(listed),
          "kept" => length(kept),
          "truncated" => truncated,
          "added" => Enum.count(rows, &(&1["change"] == "new")),
          "removed" => Enum.count(rows, &(&1["change"] == "gone")),
          "unchanged" => Enum.count(rows, &(&1["change"] == "same")),
          "ms" => 380
        }

        fetches =
          Map.put(state.fetches, task["task_id"], %{
            provider_id: id,
            listed: kept,
            truncated: truncated
          })

        state =
          remember_test(%{state | fetches: fetches}, task, "done", nil, %{
            "count" => length(listed),
            "ms" => 380
          })

        {{:done, summary, rows}, state}
    end
  end

  defp finish("provider.fetch_all", _task, state) do
    rows =
      for p <- provider_list(state) do
        if usable?(p) do
          listed = listed_models(p)

          %{
            "id" => p["id"],
            "name" => p["name"],
            "state" => "done",
            "count" => length(listed),
            "added" => length(listed -- p["models"]),
            "removed" => length(p["models"] -- listed),
            "message" => nil
          }
        else
          %{
            "id" => p["id"],
            "name" => p["name"],
            "state" => "failed",
            "count" => 0,
            "added" => 0,
            "removed" => 0,
            "message" => "the key was refused (401)"
          }
        end
      end

    changed = Enum.count(rows, &(&1["added"] + &1["removed"] > 0))
    {{:done, %{"providers" => rows, "total" => length(rows), "changed" => changed}, rows}, state}
  end

  defp finish("search.test", %{"target" => %{"kind" => kind}} = task, state) do
    row = state.search[kind]

    cond do
      needs_key?(kind) and not row["api_key"]["set"] ->
        state = remember_search(state, kind, "failed", "no key")
        {{:failed, "no key"}, state}

      kind in @readers ->
        state = remember_search(state, kind, "done", nil, %{"ms" => 500})
        {{:done, %{"read" => "example.com", "ms" => 500}, []}, state}

      true ->
        _ = task
        state = remember_search(state, kind, "done", nil, %{"count" => 3, "ms" => 612})
        {{:done, %{"count" => 3, "ms" => 612}, []}, state}
    end
  end

  defp finish(
         "search.set_key",
         %{"target" => %{"kind" => kind}, "attributes" => %{"hint" => mask}},
         state
       ) do
    state = bump(put_in(state.search[kind]["api_key"], mask))
    {{:done, %{"saved" => true, "count" => 3, "ms" => 612}, []}, state}
  end

  defp finish("mcp.reconnect", %{"target" => %{"id" => id}}, state) do
    case Map.get(state.mcp, id) do
      nil ->
        {{:failed, "that server no longer exists"}, state}

      %{"id" => @github} = s ->
        state =
          put_in(state.mcp[id], %{
            s
            | "status" => "error",
              "status_message" => "command not found: github-mcp-server"
          })

        {{:failed, "command not found: github-mcp-server"}, state}

      s ->
        s = %{s | "status" => "ready", "status_message" => nil}
        state = put_in(state.mcp[id], s)
        total = length(s["tools"])

        {{:done,
          %{
            "status" => "ready",
            "tools_total" => total,
            "tools_enabled" => total - length(s["disabled_tools"])
          }, []}, state}
    end
  end

  defp finish("mcp.test", %{"target" => %{"draft" => true}}, state),
    do: {{:done, %{"tools" => ["echo"], "count" => 1}, []}, state}

  defp finish("mcp.test", %{"target" => %{"id" => id}}, state) do
    case Map.get(state.mcp, id) do
      %{"id" => @github} ->
        {{:failed, "command not found: github-mcp-server"}, state}

      nil ->
        {{:failed, "that server no longer exists"}, state}

      s ->
        {{:done,
          %{
            "tools" => Enum.take(Enum.map(s["tools"], & &1["name"]), 64),
            "count" => length(s["tools"])
          }, []}, state}
    end
  end

  defp finish("mcp.import.read", task, state) do
    drafts = import_drafts(state)
    import = %{drafts: drafts}
    state = %{state | imports: Map.put(state.imports, task["task_id"], import)}
    rows = Enum.map(drafts, &draft_wire/1)

    {{:done,
      %{
        "import_id" => task["task_id"],
        "path" => "~/dev/ailogic/.mcp.json",
        "count" => length(drafts)
      }, rows}, state}
  end

  defp finish("storage.measure", _task, state) do
    state = put_in(state.storage.measured, true)
    {{:done, storage_overview(state), []}, state}
  end

  defp finish("storage.plan", task, state) do
    selection = get(task["attributes"] || %{}, "selection") || %{}
    {items, skipped, vacuum} = plan(state, selection)
    plan = %{items: items, selection: selection, vacuum: vacuum}
    plan_id = task["task_id"]
    state = put_in(state.storage.plans[plan_id], plan)

    summary = %{
      "plan_id" => plan_id,
      "items" => items,
      "skipped" => skipped,
      "total_count" => Enum.sum(Enum.map(items, & &1["count"])),
      "total_bytes" => Enum.sum(Enum.map(items, & &1["bytes"])),
      "vacuum" => vacuum
    }

    {{:done, summary, Enum.map(items, &Map.take(&1, ~w(label count bytes)))}, state}
  end

  defp finish("storage.run", task, state) do
    plan =
      Map.get(state.storage.plans, get(task["attributes"] || %{}, "plan_id"), %{
        items: [],
        selection: %{},
        vacuum: false
      })

    ids = MapSet.new(plan_session_ids(state, plan.selection))
    freed = Enum.sum(Enum.map(plan.items, & &1["bytes"]))
    sessions = Enum.reject(state.storage.sessions, &MapSet.member?(ids, &1["id"]))

    storage = %{state.storage | sessions: sessions, running: false}
    state = %{state | storage: storage}

    summary = %{
      "freed_bytes" => freed,
      "items" => Enum.sum(Enum.map(plan.items, & &1["count"])),
      "vacuum" =>
        if(plan.vacuum, do: %{"before" => 1_800_000_000, "after" => 1_800_000_000 - freed}),
      "db_bytes_after" => 1_800_000_000,
      "reclaimable_after" => freed
    }

    {{:done, summary, []}, state}
  end

  defp finish("storage.vacuum", _task, state) do
    state = put_in(state.storage.running, false)
    {{:done, %{"before" => 1_800_000_000, "after" => 1_200_000_000}, []}, state}
  end

  defp finish("storage.apply_retention", _task, state) do
    days = state.retention.retention_days

    {old, keep} =
      Enum.split_with(
        state.storage.sessions,
        &(days != nil and &1["age_days"] > days and &1["deletable"])
      )

    storage = %{state.storage | sessions: keep, running: false, last_cleanup_at: state.now}
    state = %{state | storage: storage}

    {{:done,
      %{
        "freed_bytes" => Enum.sum(Enum.map(old, & &1["bytes"])),
        "items" => length(old),
        "deleted" => length(old),
        "pruned" => 0,
        "vacuum" => nil
      }, []}, state}
  end

  defp finish("lsp.check", _task, state) do
    rows =
      for lang <- @languages do
        override = Map.get(state.lsp_servers, lang)
        effective = if override == "off", do: nil, else: override || @lsp_defaults[lang]
        exe = effective && effective |> String.split() |> List.first()

        %{
          "language" => lang,
          "extensions" => @lsp_extensions[lang],
          "default" => @lsp_defaults[lang],
          "override" => override,
          "effective" => effective,
          "installed" => if(exe, do: lang == "elixir"),
          "executable" => exe,
          "running" =>
            if(lang == "elixir", do: [%{"project" => "ailogic", "count" => 1}], else: [])
        }
      end

    unknown =
      for {k, v} <- state.lsp_servers, k not in @languages, do: %{"key" => k, "value" => v}

    {{:done, %{"unknown_keys" => unknown}, rows}, state}
  end

  defp finish("workflow.smoke", task, state) do
    ref = get(task["attributes"] || %{}, "ref")

    refs =
      if ref,
        do: [ref],
        else:
          state.library
          |> Map.get("workflows", [])
          |> Enum.reject(&(&1["scope"] == "builtin"))
          |> Enum.map(& &1["ref"])

    rows =
      for r <- refs do
        smoke = Map.get(state.smoke, r, "ok")
        %{"ref" => r, "name" => r |> String.split(":") |> List.last(), "smoke" => smoke}
      end

    {{:done, %{"checked" => length(rows), "failed" => Enum.count(rows, &(&1["smoke"] != "ok"))},
      rows}, state}
  end

  defp finish(_action, _task, state), do: {{:done, %{}, []}, state}

  # ---------------------------------------------------------------- helpers

  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, atom_key(key)))
  defp get(_other, _key), do: nil

  # only the fixed wire key names of §3.4.1 are ever looked up as atoms
  @atom_keys Map.new(
               ~w(action target attributes expected secrets dry_run view kind id options slot value
                        name kind base_url models default_model fallbacks effort_levels test_first draft
                        replacements fetch_task_id mode rows model levels input output cache_read
                        cache_write context_window rename_from row enabled dir order map tools path
                        import_id names project_id rename values selection plan_id key all ref content
                        fingerprint confirmed_hooks confirmed scope event index command matcher timeout_ms
                        output_cap swarm_effort effort swarm_model sort filter updated_at provider_id
                        transport args env url headers disabled_tools),
               &{&1, String.to_atom(&1)}
             )
  defp atom_key(key), do: Map.get(@atom_keys, key, key)

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)
  defp stringify(_), do: %{}

  defp result(status, opts \\ []) do
    %{
      "status" => status,
      "results" => Keyword.get(opts, :results, []),
      "record" => Keyword.get(opts, :record),
      "task" => nil,
      "message" => Keyword.get(opts, :message),
      "confirm" => Keyword.get(opts, :confirm),
      "field_errors" => Keyword.get(opts, :field_errors, [])
    }
  end

  defp task(action, target, attributes \\ %{}) do
    %{
      "action" => action,
      "target" => target,
      "attributes" => attributes,
      "cancellable" => action not in @not_cancellable
    }
  end

  defp rec(kind, id, fields), do: %{"kind" => kind, "id" => id, "fields" => fields}

  defp page(kind, items, params) do
    size = min(get(params, "page_size") || @page, @page)
    start = decode_cursor(get(params, "cursor"))
    slice = items |> Enum.drop(start) |> Enum.take(size)
    next = if start + size < length(items), do: Integer.to_string(start + size)
    {:ok, %{"kind" => kind, "items" => slice, "next_cursor" => next, "total" => length(items)}}
  end

  defp decode_cursor(nil), do: 0

  defp decode_cursor(cursor) when is_binary(cursor) do
    case Integer.parse(cursor) do
      {n, ""} when n >= 0 -> n
      _ -> 0
    end
  end

  defp decode_cursor(_), do: 0

  defp singular("commands"), do: "command"
  defp singular("agent_defs"), do: "agent_def"
  defp singular("skills"), do: "skill"
  defp singular("workflows"), do: "workflow"

  defp trim(nil), do: ""
  defp trim(v) when is_binary(v), do: String.trim(v)
  defp trim(v), do: to_string(v)

  defp blank_nil(nil), do: nil
  defp blank_nil(v) when is_binary(v), do: if(String.trim(v) == "", do: nil, else: String.trim(v))
  defp blank_nil(v), do: v

  defp normalize_url(nil), do: nil
  defp normalize_url(v) when is_binary(v), do: v |> String.trim() |> String.trim_trailing("/")
  defp normalize_url(v), do: v

  defp url?(v),
    do: is_binary(v) and (String.starts_with?(v, "http://") or String.starts_with?(v, "https://"))

  defp clean_models(list) when is_list(list),
    do: list |> Enum.map(&trim/1) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

  defp clean_models(_), do: []

  defp first_message([%{"message" => m} | _]), do: m
  defp first_message(_), do: nil

  defp secret(c, slot) do
    Enum.find_value(c.secrets, fn s -> if get(s, "slot") == slot, do: get(s, "value") end)
  end

  @doc "The paste checks of §3.5.9 (the words the service answers)."
  def check_paste(value) when is_binary(value) do
    v = String.trim(value)
    lines = v |> String.split(~r/\r\n|\r|\n/) |> length()

    cond do
      lines > 1 -> "paste only the key: it had #{lines} lines"
      Regex.match?(~r/\s/, v) -> "a key has no spaces inside"
      byte_size(v) < 8 -> "that is too short to be a key"
      byte_size(v) > 8_192 -> "that is too long to be a key"
      true -> nil
    end
  end

  def check_paste(_), do: "that is too short to be a key"

  defp secret_mask(nil), do: %{"set" => false, "hint" => nil}
  defp secret_mask(value), do: %{"set" => true, "hint" => hint(String.trim(value))}

  @doc "The last 4 characters of a secret of at least 12 characters, else nil (§3.2.5)."
  def hint(value) when is_binary(value) do
    if String.length(value) >= 12, do: String.slice(value, -4, 4), else: nil
  end

  def hint(%{"hint" => h}), do: h
  def hint(_), do: nil

  defp ends(%{"hint" => h}) when is_binary(h), do: " · ends #{h}"
  defp ends(_), do: ""

  defp new_id(state, prefix) do
    n = state.revision |> Integer.to_string() |> String.pad_leading(12, "0")
    prefix <> n
  end

  defp stamp(state), do: "#{state.now}##{state.revision}"

  defp bump(state), do: %{state | revision: state.revision + 1}

  defp with_provider(state, c, fun) do
    case Map.get(state.providers, get(c.target, "id") || "") do
      nil -> {{:ok, result("not_found", message: "that provider no longer exists")}, state}
      p -> fun.(p)
    end
  end

  defp with_search(state, c, fun) do
    case Map.get(state.search, get(c.target, "kind") || "") do
      nil -> {{:ok, result("not_found", message: "no such search provider")}, state}
      row -> fun.(row)
    end
  end

  defp with_mcp(state, c, fun) do
    case Map.get(state.mcp, get(c.target, "id") || "") do
      nil -> {{:ok, result("not_found", message: "that server no longer exists")}, state}
      s -> fun.(s)
    end
  end

  defp cas_fields(_current, nil), do: :ok

  defp cas_fields(current, expected) do
    fields = get(expected, "fields") || %{}

    rows =
      for {k, v} <- stringify(fields), not same?(Map.get(current, k), v) do
        %{"target" => k, "status" => "conflict", "current" => Map.get(current, k)}
      end

    if rows == [], do: :ok, else: {:conflict, rows}
  end

  defp cas_key(_current, nil), do: :ok

  defp cas_key(current, expected) do
    case get(expected, "key") do
      nil ->
        :ok

      %{"$any" => true} ->
        :ok

      key ->
        if same?(key, current),
          do: :ok,
          else: %{"target" => "api_key", "status" => "conflict", "current" => current}
    end
  end

  defp cas_value(_current, nil, _target), do: :ok
  defp cas_value(_current, %{"$any" => true}, _target), do: :ok

  defp cas_value(current, expected, target) do
    if same?(current, expected),
      do: :ok,
      else: {:conflict, %{"target" => target, "status" => "conflict", "current" => current}}
  end

  defp same?(a, b) when is_number(a) and is_number(b), do: a == b

  defp same?(a, b) when is_map(a) and is_map(b),
    do:
      stringify(a) |> Map.keys() |> Enum.sort() == stringify(b) |> Map.keys() |> Enum.sort() and
        Enum.all?(stringify(a), fn {k, v} -> same?(v, Map.get(stringify(b), k)) end)

  defp same?(a, b) when is_list(a) and is_list(b),
    do: length(a) == length(b) and Enum.all?(Enum.zip(a, b), fn {x, y} -> same?(x, y) end)

  defp same?(a, b), do: a == b

  defp field_results(attrs),
    do: for({k, v} <- attrs, do: %{"target" => k, "status" => "accepted", "value" => v})

  defp normalize_provider_attrs(attrs) do
    attrs
    |> then(
      &if Map.has_key?(&1, "base_url"),
        do: Map.update!(&1, "base_url", fn v -> normalize_url(v) end),
        else: &1
    )
    |> then(
      &if Map.has_key?(&1, "name"), do: Map.update!(&1, "name", fn v -> trim(v) end), else: &1
    )
    |> then(
      &if Map.has_key?(&1, "models"),
        do: Map.update!(&1, "models", fn v -> clean_models(v) end),
        else: &1
    )
    |> then(
      &if Map.has_key?(&1, "default_model"),
        do: Map.update!(&1, "default_model", fn v -> blank_nil(v) end),
        else: &1
    )
  end

  defp provider_errors(state, fields, own_id) do
    name = fields["name"] || ""
    base = fields["base_url"]

    taken =
      Enum.any?(
        Map.values(state.providers),
        &(&1["id"] != own_id and String.downcase(&1["name"]) == String.downcase(name))
      )

    [
      name == "" && %{"target" => "name", "message" => "can't be blank"},
      (name != "" and taken) && %{"target" => "name", "message" => "has already been taken"},
      String.length(name) > 120 &&
        %{"target" => "name", "message" => "should be at most 120 character(s)"},
      fields["kind"] not in ~w(openai_compatible anthropic) &&
        %{"target" => "kind", "message" => "is invalid"},
      base in [nil, ""] && %{"target" => "base_url", "message" => "can't be blank"},
      (base not in [nil, ""] and not url?(base)) &&
        %{"target" => "base_url", "message" => "must start with http:// or https://"},
      length(fields["models"] || []) > @max_models &&
        %{"target" => "models", "message" => "2 000 models at most"}
    ]
    |> Enum.filter(& &1)
  end

  defp provider_list(state),
    do: state.providers |> Map.values() |> Enum.sort_by(&String.downcase(&1["name"]))

  @doc "D11's usable predicate: a non-blank key, or a base URL on a private host."
  def usable?(p), do: p["api_key"]["set"] == true or private_host?(p["base_url"])

  @doc "Loopback, RFC 1918, link-local, `.local`, `.internal`, `.home.arpa` hosts."
  def private_host?(url) when is_binary(url) do
    host = URI.parse(url).host || ""

    host in ["localhost", "::1"] or String.starts_with?(host, "127.") or
      String.starts_with?(host, "10.") or
      String.starts_with?(host, "192.168.") or String.starts_with?(host, "169.254.") or
      Regex.match?(~r/^172\.(1[6-9]|2\d|3[01])\./, host) or
      Enum.any?([".local", ".internal", ".home.arpa"], &String.ends_with?(host, &1))
  end

  def private_host?(_), do: false

  defp provider_summary(state, p) do
    rec("provider", p["id"], provider_summary_fields(state, p))
  end

  defp provider_summary_fields(state, p) do
    tests = Map.get(state.provider_tests, p["id"], %{})

    p
    |> Map.take(~w(id name kind base_url api_key default_model fallbacks updated_at))
    |> Map.merge(%{
      "usable" => usable?(p),
      "models_count" => length(p["models"]),
      "last_test" => Map.get(tests, "test"),
      "last_fetch" => Map.get(tests, "fetch")
    })
  end

  defp provider_full(state, p) do
    state
    |> provider_summary_fields(p)
    |> Map.merge(%{
      "models" => p["models"],
      "effort_levels" => p["effort_levels"],
      "model_effort_levels" => p["model_effort_levels"] || %{},
      "builtin_levels" => builtin_levels(p["kind"]),
      "presets" => Enum.filter(presets(), &(p["kind"] in &1["kinds"])),
      "used_by" => used_by(state, p["id"]),
      "caps" =>
        Map.get(state.caps, p["id"], %{
          "effort_rejected" => false,
          "prefix_cache_rejected" => false,
          "fallbacks_rejected" => false
        })
    })
  end

  defp used_by(state, id) do
    conversations = %{@deepseek => 12, @anthropic => 2}

    %{
      "defaults" => serves(state, id) |> Enum.filter(&String.starts_with?(&1, "models.")),
      "research" => serves(state, id) |> Enum.filter(&String.starts_with?(&1, "research.")),
      "conversations" => Map.get(conversations, id, 0),
      "scheduled_tasks" => if(id == @deepseek, do: 2, else: 0)
    }
  end

  defp serves(state, id),
    do: for({key, {pid, _}} <- state.defaults, pid == id, do: key) |> Enum.sort()

  defp fetched_models(state, id) do
    state.fetches
    |> Map.values()
    |> Enum.filter(&(&1.provider_id == id))
    |> List.last()
    |> then(&(&1 && &1.listed))
  end

  defp listed_models(%{"id" => @deepseek}), do: ["deepseek-v4-pro", "deepseek-v4-lite"]
  defp listed_models(p), do: p["models"]

  defp used_by_model("deepseek-v4-flash"), do: 3
  defp used_by_model(_), do: 0

  defp change_order("new"), do: 0
  defp change_order("gone"), do: 1
  defp change_order(_), do: 2

  defp remember_test(state, task, status, message, extra \\ %{}) do
    case {task["action"], task["target"]} do
      {action, %{"id" => id}} when action in ~w(provider.test provider.fetch_models) ->
        slot = if action == "provider.test", do: "test", else: "fetch"

        entry =
          Map.merge(
            %{
              "state" => status,
              "at" => state.now,
              "message" => message,
              "count" => nil,
              "ms" => nil
            },
            extra
          )

        tests = Map.update(state.provider_tests, id, %{slot => entry}, &Map.put(&1, slot, entry))
        %{state | provider_tests: tests}

      {"search.test", %{"kind" => kind}} ->
        remember_search(state, kind, status, message, extra)

      _ ->
        state
    end
  end

  defp remember_search(state, kind, status, message, extra \\ %{}) do
    entry =
      Map.merge(
        %{
          "state" => status,
          "at" => state.now,
          "message" => message,
          "count" => nil,
          "ms" => nil
        },
        extra
      )

    %{state | search_tests: Map.put(state.search_tests, kind, entry)}
  end

  defp builtin_levels("anthropic") do
    for k <- ~w(low medium high xhigh max),
        do:
          level(
            k,
            %{
              "thinking" => %{"type" => "adaptive", "display" => "summarized"},
              "output_config" => %{"effort" => k}
            },
            nil,
            ~w(temperature top_p top_k)
          )
  end

  defp builtin_levels(_),
    do: for(k <- ~w(low medium high), do: level(k, %{"reasoning_effort" => k}))

  defp level(key, body, hint \\ nil, drop \\ []) do
    %{
      "key" => key,
      "label" => String.capitalize(key),
      "hint" => hint || classic_hint(key),
      "body" => body,
      "drop" => drop
    }
  end

  defp classic_hint("low"), do: "fastest"
  defp classic_hint("medium"), do: "balanced"
  defp classic_hint("high"), do: "deeper reasoning"
  defp classic_hint("xhigh"), do: "coding and agentic work"
  defp classic_hint("max"), do: "maximum thinking"
  defp classic_hint(_), do: ""

  @doc "The effort presets the fake offers (a subset of `Efforts.presets/0`, D§4d)."
  def presets do
    both = ~w(openai_compatible anthropic)
    openai = ~w(openai_compatible)

    [
      %{
        "id" => "openai",
        "name" => "OpenAI reasoning",
        "kinds" => openai,
        "levels" =>
          for(k <- ~w(minimal low medium high), do: level(k, %{"reasoning_effort" => k}))
      },
      %{
        "id" => "anthropic_adaptive",
        "name" => "Anthropic adaptive (Claude 4.6+, 5)",
        "kinds" => ~w(anthropic),
        "levels" => builtin_levels("anthropic")
      },
      %{
        "id" => "deepseek",
        "name" => "DeepSeek V4",
        "kinds" => openai,
        "levels" => [
          level("off", %{"thinking" => %{"type" => "disabled"}}, "no thinking"),
          level("high", %{"reasoning_effort" => "high"}),
          level("max", %{"reasoning_effort" => "max"})
        ]
      },
      %{
        "id" => "openrouter",
        "name" => "OpenRouter",
        "kinds" => openai,
        "levels" =>
          for(k <- ~w(low medium high), do: level(k, %{"reasoning" => %{"effort" => k}}))
      },
      %{
        "id" => "off",
        "name" => "Send nothing",
        "kinds" => both,
        "levels" => [level("medium", %{}, "no effort parameter")]
      }
    ]
  end

  defp effort_rows(rows) when is_list(rows) and length(rows) <= 32 do
    {levels, errors, _} =
      rows
      |> Enum.with_index()
      |> Enum.reduce({[], [], MapSet.new()}, fn {row, i}, {acc, errs, seen} ->
        key = trim(get(row, "key"))
        body = get(row, "body")

        err =
          cond do
            not Regex.match?(@key_format, key) ->
              "key: lowercase letters, digits, - or _ (24 max)"

            MapSet.member?(seen, key) ->
              "key: already used"

            not is_map(body) ->
              "body: must be a JSON object"

            true ->
              nil
          end

        label = blank_nil(get(row, "label")) || String.capitalize(key)

        lvl = %{
          "key" => key,
          "label" => label,
          "hint" => get(row, "hint") || "",
          "body" => body || %{},
          "drop" => get(row, "drop") || []
        }

        errs = if err, do: errs ++ [%{"target" => "rows[#{i}]", "message" => err}], else: errs
        {acc ++ [lvl], errs, MapSet.put(seen, key)}
      end)

    if errors == [], do: {:ok, levels}, else: {:error, errors}
  end

  defp effort_rows(_), do: {:error, [%{"target" => "rows", "message" => "32 levels at most"}]}

  defp price(row) do
    %{
      "input" => row["input"],
      "output" => row["output"],
      "cache_read" => row["cache_read"],
      "cache_write" => row["cache_write"]
    }
  end

  defp pricing_wire(nil), do: nil

  defp pricing_wire(row),
    do: Map.merge(%{"cache_read" => nil, "cache_write" => nil, "context_window" => nil}, row)

  defp pricing_fields(model, row) do
    input = row["input"] || 0

    factor =
      if String.starts_with?(model, ["claude-fable-5-1", "claude-mythos-5-1"]),
        do: 0.025,
        else: 0.1

    row
    |> pricing_wire()
    |> Map.merge(%{
      "model" => model,
      "derived_cache_read" => round4(input * factor),
      "derived_cache_write" => round4(input * 1.25)
    })
  end

  defp round4(n), do: Float.round(n * 1.0, 4)

  defp pricing_errors(state, model, rename_from, attrs) do
    num = fn k ->
      v = get(attrs, k)
      is_number(v) and v >= 0
    end

    opt = fn k ->
      v = get(attrs, k)
      v == nil or (is_number(v) and v >= 0)
    end

    cw = get(attrs, "context_window")

    [
      (model != rename_from and Map.has_key?(state.pricing, model)) &&
        %{"target" => "model", "message" => "duplicate model"},
      String.length(model) > 256 &&
        %{"target" => "model", "message" => "should be at most 256 character(s)"},
      not num.("input") && %{"target" => "input", "message" => "input: must be a number ≥ 0"},
      not num.("output") && %{"target" => "output", "message" => "output: must be a number ≥ 0"},
      not opt.("cache_read") &&
        %{"target" => "cache_read", "message" => "cache read: must be a number ≥ 0"},
      not opt.("cache_write") &&
        %{"target" => "cache_write", "message" => "cache write: must be a number ≥ 0"},
      (cw != nil and not (is_integer(cw) and cw >= 8_000 and cw <= 2_000_000)) &&
        %{
          "target" => "context_window",
          "message" => "context window: a whole number of tokens between 8000 and 2000000"
        }
    ]
    |> Enum.filter(& &1)
  end

  defp unpriced(state) do
    defaults = for {_key, {_pid, m}} <- state.defaults, do: m

    (Map.keys(state.unpriced_usage) ++ defaults)
    |> Enum.uniq()
    |> Enum.reject(&Map.has_key?(state.pricing, &1))
    |> Enum.sort()
    |> Enum.map(fn m ->
      rec("unpriced_model", m, %{
        "model" => m,
        "conversations_30d" => Map.get(state.unpriced_usage, m, 0),
        "in_defaults" => m in defaults
      })
    end)
  end

  # search helpers

  defp search_list(state) do
    engines =
      state.search
      |> Map.values()
      |> Enum.filter(&(&1["role"] == "engine"))
      |> Enum.sort_by(& &1["position"])

    readers = Enum.map(@readers, &state.search[&1])
    engines ++ readers
  end

  defp engine_order(state), do: for(r <- search_list(state), r["role"] == "engine", do: r["kind"])

  defp search_record(state, row) do
    fields =
      row
      |> Map.take(~w(kind role enabled api_key base_url position))
      |> Map.merge(%{
        "needs_key" => needs_key?(row["kind"]),
        "default_base_url" => @default_base_urls[row["kind"]],
        "last_test" => Map.get(state.search_tests, row["kind"])
      })

    rec("search_provider", row["kind"], fields)
  end

  @doc "The label of a search kind (I§2.3)."
  def search_label("tavily"), do: "Tavily"
  def search_label("exa"), do: "Exa"
  def search_label("brave"), do: "Brave"
  def search_label("serper"), do: "Serper"
  def search_label("jina"), do: "Jina Reader"
  def search_label("firecrawl"), do: "Firecrawl"
  def search_label(other), do: to_string(other)

  defp needs_key?(kind), do: kind not in @key_optional

  # mcp helpers

  @doc "`SecretPattern.secret_kv?/2` (§3.2.5), mirrored so the fake masks exactly as the service does."
  def secret_kv?(name, value) do
    name = to_string(name)
    value = if is_binary(value), do: value, else: ""

    Regex.match?(
      ~r/(authorization|cookie|api[-_ ]?key|apikey|token|secret|password|credential)/i,
      name
    ) or
      Regex.match?(~r/^(sk-[A-Za-z0-9_\-]{4,}|Bearer\s+\S{4,})$/i, value) or
      Regex.match?(~r/(API_?KEY|_KEY$|SECRET|TOKEN|PASSWORD|PASSWD|CREDENTIAL|_PAT$)/i, name) or
      String.starts_with?(
        value,
        ~w(sk_live_ sk_test_ rk_live_ sk-ant- sk-proj- ghp_ gho_ ghu_ ghs_ github_pat_ glpat- xoxa- xoxb- xoxp- xoxr- AKIA ASIA AIza hf_ tvly-)
      ) or
      Regex.match?(~r{://[^/@\s:]+:[^/@\s]+@}, value)
  end

  defp placeholder(value), do: %{"secret" => true, "hint" => hint(String.trim(value))}

  defp store_value(name, value) do
    if secret_kv?(name, value), do: placeholder(value), else: value
  end

  defp masked(map) do
    map
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn
      {name, %{"secret" => true, "hint" => h}} ->
        %{"name" => name, "secret" => true, "value" => nil, "hint" => h}

      {name, value} ->
        %{"name" => name, "secret" => false, "value" => value, "hint" => nil}
    end)
  end

  defp slug(name),
    do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_") |> String.trim("_")

  defp mcp_record(s, full?) do
    tools = s["tools"] || []
    enabled = Enum.count(tools, &(&1["name"] not in s["disabled_tools"]))

    base =
      s
      |> Map.take(~w(id updated_at name enabled project_id transport status status_message))
      |> Map.merge(%{
        "slug" => slug(s["name"]),
        "tools_total" => length(tools),
        "tools_enabled" => enabled
      })

    fields =
      if full? do
        Map.merge(base, %{
          "command" => s["command"],
          "args" => s["args"],
          "env" => masked(s["env"]),
          "url" => s["url"],
          "headers" => masked(s["headers"]),
          "disabled_tools" => s["disabled_tools"],
          "tools" =>
            Enum.map(tools, &Map.put(&1, "enabled", &1["name"] not in s["disabled_tools"])),
          "output" => s["output"] || []
        })
      else
        base
      end

    rec("mcp_server", s["id"], fields)
  end

  defp mcp_wire(s), do: mcp_record(s, true)["fields"]

  defp mcp_build(state, base, attrs, c, own_id) do
    server =
      base
      |> Map.merge(Map.take(attrs, ~w(name enabled transport command url)))
      |> then(
        &if Map.has_key?(attrs, "project_id"),
          do: Map.put(&1, "project_id", attrs["project_id"]),
          else: &1
      )
      |> then(
        &if is_list(attrs["args"]),
          do: Map.put(&1, "args", Enum.map(attrs["args"], fn a -> to_string(a) end)),
          else: &1
      )
      |> Map.update("name", "", &trim/1)
      |> Map.update("command", nil, &blank_nil/1)
      |> Map.update("url", nil, &blank_nil(normalize_url(&1)))

    {env, env_errors} =
      kv_merge(
        Map.get(base, "env", %{}),
        attrs["env"],
        c,
        "env",
        @env_name,
        "use a variable name: A–Z, 0–9 and _"
      )

    {headers, header_errors} =
      kv_merge(
        Map.get(base, "headers", %{}),
        attrs["headers"],
        c,
        "header",
        @header_name,
        "not a header name"
      )

    server = %{server | "env" => env, "headers" => headers}
    name = server["name"]
    others = state.mcp |> Map.values() |> Enum.reject(&(&1["id"] == own_id))
    clash = Enum.find(others, &(slug(&1["name"]) == slug(name) and &1["name"] != name))

    errors =
      [
        name == "" && %{"target" => "name", "message" => "can't be blank"},
        String.length(name) > 64 &&
          %{"target" => "name", "message" => "should be at most 64 character(s)"},
        (name != "" and Enum.any?(others, &(&1["name"] == name))) &&
          %{"target" => "name", "message" => "has already been taken"},
        clash &&
          %{
            "target" => "name",
            "message" => "shares the tool prefix mcp__#{slug(name)}__ with \"#{clash["name"]}\""
          },
        server["transport"] not in ~w(stdio http) &&
          %{"target" => "transport", "message" => "is invalid"},
        (server["transport"] == "stdio" and server["command"] == nil) &&
          %{"target" => "command", "message" => "is required for stdio servers"},
        (server["transport"] == "http" and server["url"] == nil) &&
          %{"target" => "url", "message" => "is required for http servers"},
        (server["transport"] == "http" and server["url"] != nil and not url?(server["url"])) &&
          %{"target" => "url", "message" => "must start with http:// or https://"},
        server["project_id"] not in [nil, @ailogic, @notes] &&
          %{"target" => "project_id", "message" => "no such project"}
      ]
      |> Enum.filter(& &1)

    case errors ++ env_errors ++ header_errors do
      [] -> {:ok, server}
      all -> {:error, all}
    end
  end

  # entries: nil keeps the stored map; a list is the full desired list
  defp kv_merge(stored, nil, _c, _slot, _rule, _words), do: {stored, []}

  defp kv_merge(stored, entries, c, slot, rule, words) when is_list(entries) do
    field = if slot == "env", do: "env", else: "headers"

    Enum.reduce(entries, {%{}, []}, fn entry, {acc, errs} ->
      name = trim(get(entry, "name"))
      pasted = secret(c, "#{slot}:#{name}")

      cond do
        not Regex.match?(rule, name) ->
          {acc, errs ++ [%{"target" => "#{field}.#{name}", "message" => words}]}

        Map.has_key?(acc, name) ->
          {acc, errs ++ [%{"target" => "#{field}.#{name}", "message" => "already in the list"}]}

        pasted != nil ->
          {Map.put(acc, name, placeholder(pasted)), errs}

        get(entry, "keep") == true and Map.has_key?(stored, name) ->
          {Map.put(acc, name, stored[name]), errs}

        is_binary(get(entry, "value")) ->
          {Map.put(acc, name, store_value(name, get(entry, "value"))), errs}

        true ->
          {acc, errs ++ [%{"target" => "#{field}.#{name}", "message" => "can't be blank"}]}
      end
    end)
  end

  defp kv_merge(stored, _other, _c, _slot, _rule, _words), do: {stored, []}

  defp import_drafts(state) do
    names = state.mcp |> Map.values() |> MapSet.new(& &1["name"])

    [
      %{
        name: "github",
        transport: "stdio",
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-github"],
        env: %{"GITHUB_TOKEN" => "${GITHUB_TOKEN}"},
        url: nil,
        headers: %{},
        unsupported: false
      },
      %{
        name: "docs",
        transport: "http",
        command: nil,
        args: [],
        env: %{},
        url: "https://mcp.example.test/mcp",
        headers: %{"Authorization" => "Bearer test-token-import00000000"},
        unsupported: false
      },
      %{
        name: "events",
        transport: "sse",
        command: nil,
        args: [],
        env: %{},
        url: "https://events.example.test/sse",
        headers: %{},
        unsupported: true
      }
    ]
    |> Enum.map(fn d ->
      variables =
        for {map, entries} <- [{"env", d.env}, {"headers", d.headers}],
            {name, value} <- entries,
            ref = variable_ref(value),
            ref != nil do
          %{
            "map" => map,
            "name" => name,
            "ref" => ref,
            "in_shell" => Map.has_key?(state.env, ref)
          }
        end

      Map.merge(d, %{conflict: MapSet.member?(names, d.name), variables: variables})
    end)
  end

  defp variable_ref(value) do
    case Regex.run(@variable, value) do
      [_, a] -> a
      [_, "", b] -> b
      _ -> nil
    end
  end

  defp draft_wire(d) do
    mask = fn map ->
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {name, value} ->
        if variable_ref(value) == nil and secret_kv?(name, value),
          do: %{"name" => name, "secret" => true, "value" => nil, "hint" => hint(value)},
          else: %{"name" => name, "secret" => false, "value" => value, "hint" => nil}
      end)
    end

    %{
      "name" => d.name,
      "transport" => d.transport,
      "command" => d.command,
      "args" => d.args,
      "env" => mask.(d.env),
      "url" => d.url,
      "headers" => mask.(d.headers),
      "conflict" => d.conflict,
      "unsupported" => d.unsupported,
      "variables" => d.variables
    }
  end

  defp import_one(state, draft, name, choices, project, c) do
    taken = state.mcp |> Map.values() |> Enum.any?(&(&1["name"] == name))

    resolved =
      Enum.reduce_while(
        draft.variables,
        {:ok, %{"env" => draft.env, "headers" => draft.headers}},
        fn var, {:ok, acc} ->
          key = "#{if var["map"] == "env", do: "env", else: "header"}.#{var["name"]}"
          choice = Map.get(choices, key) || if(var["in_shell"], do: "shell", else: "literal")

          slot =
            "import:#{draft.name}:#{if var["map"] == "env", do: "env", else: "header"}:#{var["name"]}"

          case choice do
            "shell" ->
              if Map.has_key?(state.env, var["ref"]),
                do:
                  {:cont,
                   {:ok, put_in(acc[var["map"]][var["name"]], "shell-value-of-" <> var["ref"])}},
                else: {:halt, {:error, "#{var["ref"]} is not set in this shell"}}

            "paste" ->
              case secret(c, slot) do
                nil -> {:halt, {:error, "paste a value for #{var["name"]}"}}
                value -> {:cont, {:ok, put_in(acc[var["map"]][var["name"]], value)}}
              end

            "literal" ->
              {:cont, {:ok, acc}}

            _ ->
              {:halt, {:error, "is invalid"}}
          end
        end
      )

    cond do
      draft.unsupported ->
        {%{
           "target" => draft.name,
           "status" => "rejected",
           "message" => "SSE servers are not supported; use the server's streamable http URL"
         }, state}

      taken ->
        {%{"target" => draft.name, "status" => "rejected", "message" => "has already been taken"},
         state}

      match?({:error, _}, resolved) ->
        {:error, message} = resolved
        {%{"target" => draft.name, "status" => "rejected", "message" => message}, state}

      true ->
        {:ok, maps} = resolved
        id = new_id(state, "3c9a0000-0000-4000-9000-")

        server = %{
          "id" => id,
          "updated_at" => stamp(state),
          "name" => name,
          "enabled" => true,
          "project_id" => project,
          "transport" => draft.transport,
          "command" => draft.command,
          "args" => draft.args,
          "env" => Map.new(maps["env"], fn {k, v} -> {k, store_value(k, v)} end),
          "url" => draft.url,
          "headers" => Map.new(maps["headers"], fn {k, v} -> {k, store_value(k, v)} end),
          "disabled_tools" => [],
          "status" => "connecting",
          "status_message" => nil,
          "tools" => [],
          "output" => []
        }

        {%{"target" => draft.name, "status" => "accepted", "value" => name},
         bump(%{state | mcp: Map.put(state.mcp, id, server)})}
    end
  end

  # storage helpers

  defp sort_sessions(sessions, "date"), do: Enum.sort_by(sessions, & &1["age_days"])
  defp sort_sessions(sessions, "title"), do: Enum.sort_by(sessions, &String.downcase(&1["title"]))
  defp sort_sessions(sessions, _bytes), do: Enum.sort_by(sessions, &(-&1["bytes"]))

  defp storage_overview(state) do
    kinds = [
      {"sessions", "Sessions", 214, 620_000_000},
      {"agent_details", "Agent details", 4_120, 910_000_000},
      {"checkpoints", "Rewind snapshots", 380, 96_000_000},
      {"journals", "Workflow journals", 12, 14_000_000},
      {"research", "Research", 9, 60_000_000},
      {"free", "Index & free space", 0, 100_000_000}
    ]

    %{
      "kinds" =>
        for(
          {kind, label, count, bytes} <- kinds,
          bytes > 0,
          do: %{"kind" => kind, "label" => label, "count" => count, "bytes" => bytes}
        ),
      "db_bytes" => 1_800_000_000,
      "wal_bytes" => 4_000_000,
      "reclaimable_bytes" => 100_000_000,
      "isolation_dirs" => 2,
      "isolation_bytes" => 30_000_000,
      "sessions" => length(state.storage.sessions),
      "measured_at" => state.now,
      "last_cleanup_at" => state.storage.last_cleanup_at,
      "presets" => storage_presets(state)
    }
  end

  defp storage_presets(state) do
    [
      {"older_30", "Delete sessions older than 30 days", "everything they hold goes with them",
       %{"older_than_days" => 30}},
      {"keep_2w", "Keep only the last 2 weeks", nil, %{"older_than_days" => 14}},
      {"prune_14", "Prune agent details older than 14 days", nil, %{"prune_days" => 14}},
      {"checkpoints_30", "Delete rewind snapshots older than 30 days", nil,
       %{"checkpoint_days" => 30}},
      {"vacuum", "Reclaim disk space (VACUUM)", "compacts the file; deletes nothing",
       %{"vacuum" => true}}
    ]
    |> Enum.map(fn {id, label, note, selection} ->
      {items, _skipped, vacuum} = plan(state, selection)

      %{
        "id" => id,
        "label" => label,
        "note" => note,
        "selection" => selection,
        "count" => Enum.sum(Enum.map(items, & &1["count"])),
        "bytes" => Enum.sum(Enum.map(items, & &1["bytes"])),
        "vacuum" => vacuum
      }
    end)
  end

  defp plan(state, selection) do
    picked = MapSet.new(get(selection, "session_ids") || [])
    include_pinned = get(selection, "include_pinned") == true
    older = get(selection, "older_than_days")

    candidates =
      Enum.filter(state.storage.sessions, fn s ->
        MapSet.member?(picked, s["id"]) or (older != nil and s["age_days"] > older)
      end)

    {go, kept} =
      Enum.split_with(candidates, fn s ->
        s["deletable"] and
          (not s["pinned"] or (include_pinned and MapSet.member?(picked, s["id"])))
      end)

    session_item =
      cond do
        go == [] ->
          []

        MapSet.size(picked) > 0 ->
          [
            %{
              "label" => "#{length(go)} picked sessions",
              "count" => length(go),
              "bytes" => Enum.sum(Enum.map(go, & &1["bytes"]))
            }
          ]

        true ->
          [
            %{
              "label" => "#{length(go)} sessions older than #{older} days",
              "count" => length(go),
              "bytes" => Enum.sum(Enum.map(go, & &1["bytes"]))
            }
          ]
      end

    extra =
      [
        {get(selection, "prune_days"),
         fn d ->
           %{
             "label" => "agent details of 230 runs older than #{d} days",
             "count" => 230,
             "bytes" => 1_100_000_000
           }
         end},
        {get(selection, "checkpoint_days"),
         fn d ->
           %{
             "label" => "rewind snapshots older than #{d} days",
             "count" => 380,
             "bytes" => 96_000_000
           }
         end},
        {get(selection, "journal_days"),
         fn d ->
           %{
             "label" => "workflow journals older than #{d} days",
             "count" => 12,
             "bytes" => 14_000_000
           }
         end},
        {get(selection, "research_days"),
         fn d ->
           %{
             "label" => "research reports older than #{d} days",
             "count" => 4,
             "bytes" => 40_000_000
           }
         end},
        {if(get(selection, "empty_sessions") == true, do: true),
         fn _ -> %{"label" => "empty sessions", "count" => 3, "bytes" => 12_000} end}
      ]
      |> Enum.flat_map(fn {v, f} -> if v, do: [f.(v)], else: [] end)

    skipped =
      kept
      |> Enum.group_by(&kept_reason/1)
      |> Enum.map(fn {reason, list} -> %{"reason" => reason, "count" => length(list)} end)
      |> Enum.sort_by(& &1["reason"])

    {session_item ++ extra, skipped, get(selection, "vacuum") == true}
  end

  defp kept_reason(%{"running" => true}), do: "still running"
  defp kept_reason(%{"open" => true}), do: "open in this terminal"
  defp kept_reason(%{"pinned" => true}), do: "pinned — pick it in Sessions to include it"
  defp kept_reason(_), do: "cannot be deleted"

  defp plan_session_ids(state, selection) do
    {_items, _skipped, _vacuum} = plan(state, selection)
    picked = MapSet.new(get(selection, "session_ids") || [])
    older = get(selection, "older_than_days")
    include_pinned = get(selection, "include_pinned") == true

    for s <- state.storage.sessions,
        MapSet.member?(picked, s["id"]) or (older != nil and s["age_days"] > older),
        s["deletable"] and
          (not s["pinned"] or (include_pinned and MapSet.member?(picked, s["id"]))),
        do: s["id"]
  end

  # files helpers

  defp valid_ref?(ref) do
    case String.split(ref, ":") do
      [kind, scope, _project, name] when name != "" ->
        kind in ~w(memory_project memory_global instructions command agent skill workflow project_config) and
          scope in ~w(project global user bundled builtin)

      _ ->
        false
    end
  end

  @doc "The fingerprint of a fake file (`{\"sha256\", \"size\"}` or `{\"missing\": true}`)."
  def fingerprint(nil), do: %{"missing" => true}

  def fingerprint(%{content: content}),
    do: %{
      "sha256" => Base.encode16(:crypto.hash(:sha256, content), case: :lower),
      "size" => byte_size(content)
    }

  defp file_meta(state, ref) do
    [kind, scope, project, name] = String.split(ref, ":")
    file = Map.get(state.files, ref)
    content = if file, do: file.content, else: ""
    bytes = byte_size(content)

    lines =
      if content == "",
        do: 0,
        else: length(String.split(String.trim_trailing(content, "\n"), "\n"))

    base = %{
      "file_kind" => kind,
      "ref" => ref,
      "path" => (file && file.path) || default_path(kind, scope, project, name),
      "bytes" => bytes,
      "lines" => lines,
      "fingerprint" => fingerprint(file),
      "editable_in_place" => bytes <= 16_384,
      "too_large" => bytes > 262_144
    }

    if kind == "instructions" do
      Map.merge(base, %{
        "winner" => (file && file.winner) || "AGENTS.md",
        "exists" => file != nil,
        "trusted" => Map.get(state.trusted, project, false)
      })
    else
      base
    end
  end

  defp root(@ailogic), do: "~/dev/ailogic"
  defp root(@notes), do: "~/dev/notes"
  defp root(_), do: "~/dev/project"

  defp default_path("memory_project", _, project, _),
    do: root(project) <> "/.swarm_code/MEMORY.md"

  defp default_path("memory_global", _, _, _), do: "~/.swarm_code/MEMORY.md"
  defp default_path("instructions", _, project, _), do: root(project) <> "/AGENTS.md"

  defp default_path("project_config", _, project, _),
    do: root(project) <> "/.swarm_code/config.json"

  defp default_path("command", "global", _, name), do: "~/.swarm_code/commands/#{name}.md"

  defp default_path("command", _, project, name),
    do: root(project) <> "/.swarm_code/commands/#{name}.md"

  defp default_path("agent", "user", _, name), do: "~/.swarm_code/agents/#{name}.md"
  defp default_path("agent", "bundled", _, name), do: "(bundled)/agents/#{name}.md"

  defp default_path("agent", _, project, name),
    do: root(project) <> "/.swarm_code/agents/#{name}.md"

  defp default_path("skill", "user", _, name), do: "~/.swarm_code/skills/#{name}/SKILL.md"

  defp default_path("skill", _, project, name),
    do: root(project) <> "/.swarm_code/skills/#{name}/SKILL.md"

  defp default_path("workflow", "user", _, name), do: "~/.swarm_code/workflows/#{name}.exs"

  defp default_path("workflow", _, project, name),
    do: root(project) <> "/.swarm_code/workflows/#{name}.exs"

  defp default_path(_, _, _, name), do: name

  defp save_file(state, ref, content) do
    file = Map.get(state.files, ref, %{content: "", path: nil, winner: nil})
    [kind, scope, project, name] = String.split(ref, ":")
    path = file.path || default_path(kind, scope, project, name)

    {ref,
     bump(%{state | files: Map.put(state.files, ref, %{file | content: content, path: path})})}
  end

  defp command_template(name),
    do:
      "---\ndescription: What /#{name} does\n---\nWrite the prompt /#{name} sends here. $ARGUMENTS is what you type after the command.\n"

  defp agent_template(name),
    do:
      "---\nname: #{name}\ndescription: What this agent is for\ntools: read_file,grep,find_files\neffort: medium\nmax_turns: 30\n---\nWrite the instructions this agent adds to its system prompt here.\n"

  defp name_rule_words("command"), do: "lowercase letters, digits, ., _ or - (64 max)"
  defp name_rule_words("agent"), do: "lowercase letters, digits, - or _ (24 max)"
  defp name_rule_words(_), do: "letters, digits, ., _ or -"

  defp library_item("command", name, scope, project, ref),
    do: %{
      "ref" => ref,
      "project_id" => if(scope == "project", do: project || @ailogic),
      "name" => name,
      "scope" => scope,
      "description" => "What /#{name} does",
      "swarm" => false,
      "mode" => nil,
      "overrides_global" => false,
      "shadowed_by_builtin" => name in ~w(settings config prefs),
      "path" => nil
    }

  defp library_item("agent", name, scope, project, ref),
    do: %{
      "ref" => ref,
      "project_id" => if(scope == "project", do: project || @ailogic),
      "name" => name,
      "tier" => scope,
      "description" => "What this agent is for",
      "tools_label" => "read_file, grep, find_files",
      "model" => nil,
      "effort" => "medium",
      "prewalk" => false,
      "max_turns" => 30,
      "shadows" => nil,
      "shadowed" => false,
      "parse_error" => nil,
      "path" => nil
    }

  defp library_item("skill", name, scope, project, ref),
    do: %{
      "ref" => ref,
      "project_id" => if(scope == "project", do: project || @ailogic),
      "name" => name,
      "scope" => scope,
      "description" => "Describe what this skill does in the first line.",
      "files" => 1,
      "bytes" => 60,
      "shadowed" => false,
      "path" => nil
    }

  # project config helpers

  @hook_events ~w(session_start pre_tool_use post_tool_use)
  @denied ~w(tavily_api_key default_chat_provider_id default_swarm_provider_id default_scheduled_provider_id default_workflow_provider_id monthly_budget_usd workflow_budget)
  @ignored_top ~w(effort swarm_effort model swarm_model)

  defp config_fingerprint(nil), do: %{"missing" => true}

  defp config_fingerprint(config),
    do: fingerprint(%{content: :erlang.term_to_binary(config) |> Base.encode64()})

  defp project_config_fields(state, project, config) do
    config = config || %{}
    exists = map_size(config) > 0 or Map.get(state.project_config, project) != nil

    %{
      "path" => root(project) <> "/.swarm_code/config.json",
      "exists" => exists,
      "parse" => if(exists, do: "ok", else: "missing"),
      "error" => nil,
      "fingerprint" => if(exists, do: config_fingerprint(config), else: %{"missing" => true}),
      "top_level" => Map.take(config, @ignored_top),
      "denied" => config |> Map.keys() |> Enum.filter(&(&1 in @denied)),
      "unknown_keys" =>
        config
        |> Map.keys()
        |> Enum.reject(&(&1 in @ignored_top or &1 in @denied or &1 in ~w(hooks profiles))),
      "ignored_entries" => ignored_entries(config),
      "hooks" => Map.new(@hook_events, &{&1, config |> Map.get("hooks", %{}) |> Map.get(&1, [])}),
      "profiles" => Map.get(config, "profiles", %{}),
      "trusted" => Map.get(state.trusted, project, false)
    }
  end

  defp ignored_entries(config) do
    hooks = Map.get(config, "hooks", %{})
    profiles = Map.get(config, "profiles", %{})

    unknown_events =
      for {event, _} <- hooks,
          event not in @hook_events,
          do: %{
            "path" => "hooks.#{event}",
            "reason" => "unknown event #{event}",
            "severity" => "error"
          }

    profile_keys =
      for {name, p} <- profiles,
          is_map(p),
          {k, _} <- p,
          k not in ~w(effort swarm_effort model swarm_model),
          do: %{
            "path" => "profiles.#{name}.#{k}",
            "reason" => "not a profile key",
            "severity" => "warning"
          }

    Enum.sort_by(unknown_events, & &1["path"]) ++ Enum.sort_by(profile_keys, & &1["path"])
  end

  defp hooks_need_confirmation?(state, ref, content, attrs) do
    [_, _, project, _] = String.split(ref, ":")

    get(attrs, "confirmed_hooks") != true and Map.get(state.trusted, project, false) and
      new_hook_commands(state, ref, content) != []
  end

  defp new_hook_commands(state, ref, content) do
    [_, _, project, _] = String.split(ref, ":")
    old = hook_commands(Map.get(state.project_config, project) || %{})

    case Jason.decode(content) do
      {:ok, %{} = json} -> json |> hook_commands() |> Enum.reject(&(&1 in old))
      _ -> []
    end
  end

  defp hook_commands(config) do
    for {event, list} <- Map.get(config, "hooks", %{}),
        event in @hook_events,
        is_list(list),
        %{"command" => cmd} <- list,
        do: "#{event}: #{cmd}"
  end

  defp project_config_op("put_hook", c, config, trusted) do
    event = get(c.target, "event")
    index = get(c.target, "index")
    attrs = c.attributes
    command = trim(get(attrs, "command"))
    matcher = blank_nil(get(attrs, "matcher"))
    timeout = get(attrs, "timeout_ms") || 10_000
    cap = get(attrs, "output_cap") || 4_096
    hooks = Map.get(config, "hooks", %{})
    list = Map.get(hooks, event, [])
    old = if is_integer(index), do: Enum.at(list, index)

    cond do
      event not in @hook_events ->
        {:error, "is invalid"}

      command == "" ->
        {:error, "can't be blank"}

      matcher != nil and match?({:error, _}, Regex.compile(matcher)) ->
        {:error, "not a valid regular expression: #{elem(Regex.compile(matcher), 1) |> elem(0)}"}

      not (is_integer(timeout) and timeout in 1..30_000) ->
        {:error, "must be between 1 and 30000"}

      not (is_integer(cap) and cap in 1..16_384) ->
        {:error, "must be between 1 and 16384"}

      trusted and get(attrs, "confirmed") != true and (old == nil or old["command"] != command) ->
        {:confirm, ["#{event}: #{command}"]}

      true ->
        hook =
          %{
            "command" => command,
            "matcher" => matcher,
            "timeout_ms" => timeout,
            "output_cap" => cap
          }
          |> Enum.reject(fn {_, v} -> v == nil end)
          |> Map.new()

        list = if old, do: List.replace_at(list, index, hook), else: list ++ [hook]
        {:ok, Map.put(config, "hooks", Map.put(hooks, event, list)), "Saved the hook"}
    end
  end

  defp project_config_op("delete_hook", c, config, _trusted) do
    event = get(c.target, "event")
    index = get(c.target, "index")
    hooks = Map.get(config, "hooks", %{})
    list = Map.get(hooks, event, [])

    if is_integer(index) and index in 0..(length(list) - 1)//1,
      do:
        {:ok, Map.put(config, "hooks", Map.put(hooks, event, List.delete_at(list, index))),
         "Deleted the hook"},
      else: {:error, "no such hook"}
  end

  defp project_config_op("move_hook", c, config, _trusted) do
    event = get(c.target, "event")
    index = get(c.target, "index")
    dir = get(c.attributes, "dir")
    hooks = Map.get(config, "hooks", %{})
    list = Map.get(hooks, event, [])
    to = if is_integer(index) and dir in [-1, 1], do: index + dir

    if to != nil and index in 0..(length(list) - 1)//1 and to in 0..(length(list) - 1)//1 do
      a = Enum.at(list, index)
      b = Enum.at(list, to)
      list = list |> List.replace_at(index, b) |> List.replace_at(to, a)
      {:ok, Map.put(config, "hooks", Map.put(hooks, event, list)), "Moved the hook"}
    else
      {:error, "it cannot move further"}
    end
  end

  defp project_config_op("put_profile", c, config, _trusted) do
    old = get(c.target, "name")
    attrs = c.attributes
    name = trim(get(attrs, "name"))
    profiles = Map.get(config, "profiles", %{})

    cond do
      not Regex.match?(~r/\A[\w-]{1,32}\z/, name) ->
        {:error, "1 to 32 letters, digits, _ or -"}

      name != old and Map.has_key?(profiles, name) ->
        {:error, "already used"}

      true ->
        profile =
          for k <- ~w(effort swarm_effort model swarm_model),
              v = get(attrs, k),
              v != nil,
              into: %{},
              do: {k, v}

        {:ok, Map.put(config, "profiles", profiles |> Map.delete(old) |> Map.put(name, profile)),
         "Saved the profile #{name}"}
    end
  end

  defp project_config_op("delete_profile", c, config, _trusted) do
    name = get(c.target, "name")
    profiles = Map.get(config, "profiles", %{})

    if Map.has_key?(profiles, name),
      do:
        {:ok, Map.put(config, "profiles", Map.delete(profiles, name)),
         "Deleted the profile #{name}"},
      else: {:error, "no such profile"}
  end

  defp project_config_op("remove_key", c, config, _trusted) do
    key = get(c.target, "key")

    if key in @ignored_top or key in @denied,
      do: {:ok, Map.delete(config, key), "Removed #{key}"},
      else: {:error, "only a key SwarmCode ignores can be removed here"}
  end

  defp project_config_op("remove_entry", c, config, _trusted) do
    path = get(c.target, "path")

    cond do
      path not in Enum.map(ignored_entries(config), & &1["path"]) ->
        {:error, "only an ignored entry can be removed here"}

      String.starts_with?(path, "hooks.") ->
        event = String.replace_prefix(path, "hooks.", "")
        {:ok, Map.update(config, "hooks", %{}, &Map.delete(&1, event)), "Removed #{path}"}

      true ->
        ["profiles", name, key] = String.split(path, ".", parts: 3)
        {:ok, update_in(config, ["profiles", name], &Map.delete(&1, key)), "Removed #{path}"}
    end
  end

  defp project_config_op(_op, _c, _config, _trusted), do: {:error, "is invalid"}

  # ------------------------------------------------------------------- seed

  defp seed_providers(now) do
    [
      {@deepseek, "DeepSeek", "openai_compatible", "https://api.deepseek.com/v1", "a1b2",
       ["deepseek-v4-pro", "deepseek-v4-flash"], "deepseek-v4-pro"},
      {@anthropic, "Anthropic", "anthropic", "https://api.anthropic.com", "c3d4",
       ["claude-sonnet-5", "claude-opus-5"], "claude-sonnet-5"},
      {@ollama, "Ollama", "openai_compatible", "http://127.0.0.1:11434/v1", nil, ["qwen3-coder"],
       "qwen3-coder"},
      {@openrouter, "OpenRouter", "openai_compatible", "https://openrouter.ai/api/v1", nil, [],
       nil}
    ]
    |> Map.new(fn {id, name, kind, url, hint, models, default} ->
      {id,
       %{
         "id" => id,
         "name" => name,
         "kind" => kind,
         "base_url" => url,
         "api_key" => %{"set" => hint != nil, "hint" => hint},
         "models" => models,
         "default_model" => default,
         "fallbacks" => kind == "anthropic",
         "effort_levels" =>
           if(id == @deepseek, do: Enum.find(presets(), &(&1["id"] == "deepseek"))["levels"]),
         "model_effort_levels" => %{},
         "updated_at" => "#{now}#0"
       }}
    end)
  end

  defp seed_search do
    rows = [
      {"tavily", "engine", true, "e5f6", 0},
      {"exa", "engine", true, "g7h8", 1},
      {"brave", "engine", false, nil, 2},
      {"serper", "engine", false, nil, 3},
      {"jina", "reader", false, nil, 4},
      {"firecrawl", "reader", false, nil, 5}
    ]

    Map.new(rows, fn {kind, role, enabled, hint, position} ->
      {kind,
       %{
         "kind" => kind,
         "role" => role,
         "enabled" => enabled,
         "api_key" => %{"set" => hint != nil, "hint" => hint},
         "base_url" => nil,
         "position" => position
       }}
    end)
  end

  defp seed_mcp(now) do
    tools = fn prefix, n ->
      for i <- 1..n do
        name = "#{prefix}_#{String.pad_leading(Integer.to_string(i), 2, "0")}"

        %{
          "name" => name,
          "published_name" => name,
          "description" => "Tool #{i} of #{prefix}",
          "read_only" => rem(i, 3) == 0
        }
      end
    end

    fs_tools = [
      %{
        "name" => "read_file",
        "published_name" => "read_file",
        "description" => "Read a file",
        "read_only" => true
      }
      | tools.("fs", 11)
    ]

    docs_tools = [
      %{
        "name" => "create_issue",
        "published_name" => "create_issue",
        "description" => "Create an issue",
        "read_only" => false
      }
      | tools.("docs", 28)
    ]

    %{
      @github => %{
        "id" => @github,
        "updated_at" => "#{now}#0",
        "name" => "github",
        "enabled" => true,
        "project_id" => nil,
        "transport" => "stdio",
        "command" => "github-mcp-server",
        "args" => ["stdio"],
        "env" => %{
          "GITHUB_PERSONAL_ACCESS_TOKEN" => %{"secret" => true, "hint" => "i9j0"},
          "GITHUB_TOOLSETS" => "repos,issues"
        },
        "url" => nil,
        "headers" => %{},
        "disabled_tools" => [],
        "status" => "error",
        "status_message" => "command not found: github-mcp-server",
        "tools" => [],
        "output" => ["sh: github-mcp-server: command not found"]
      },
      @fs => %{
        "id" => @fs,
        "updated_at" => "#{now}#0",
        "name" => "fs",
        "enabled" => true,
        "project_id" => @ailogic,
        "transport" => "stdio",
        "command" => "mcp-fs",
        "args" => ["/Users/dev/ailogic"],
        "env" => %{},
        "url" => nil,
        "headers" => %{},
        "disabled_tools" => ["fs_01", "fs_02"],
        "status" => "ready",
        "status_message" => nil,
        "tools" => fs_tools,
        "output" => ["mcp-fs ready"]
      },
      @docs => %{
        "id" => @docs,
        "updated_at" => "#{now}#0",
        "name" => "docs",
        "enabled" => true,
        "project_id" => nil,
        "transport" => "http",
        "command" => nil,
        "args" => [],
        "env" => %{},
        "url" => "https://mcp.example.test/mcp",
        "headers" => %{"Authorization" => %{"secret" => true, "hint" => "k1l2"}},
        "disabled_tools" => ["docs_01"],
        "status" => "ready",
        "status_message" => nil,
        "tools" => docs_tools,
        "output" => []
      }
    }
  end

  defp seed_sessions do
    named = [
      {"5e550000-0000-4000-8000-000000000001", "Refactor the parser (old)", "ailogic", 142,
       402_000_000, %{}},
      {"5e550000-0000-4000-8000-000000000002", "Try the new router", "notes", 98, 180_000_000,
       %{}},
      {"5e550000-0000-4000-8000-000000000003", "Refactor the parser", "ailogic", 0, 88_000_000,
       %{"open" => true, "deletable" => false, "reason" => "open in this terminal"}},
      {"5e550000-0000-4000-8000-000000000004", "Release checklist", "ailogic", 61, 30_000_000,
       %{"pinned" => true}},
      {"5e550000-0000-4000-8000-000000000005", "Nightly build", "ailogic", 1, 20_000_000,
       %{
         "running" => true,
         "deletable" => false,
         "reason" => "A run of this session is still going"
       }}
    ]

    filler =
      for i <- 6..214 do
        id = "5e550000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(i), 12, "0")

        {id, "Session #{i}", if(rem(i, 3) == 0, do: "notes", else: "ailogic"),
         rem(i * 7, 200) + 2, 100_000 + i * 1_000, %{}}
      end

    for {id, title, project, age, bytes, extra} <- named ++ filler do
      Map.merge(
        %{
          "id" => id,
          "title" => title,
          "project" => project,
          "updated_at" => "#{age} days ago",
          "age_days" => age,
          "messages" => 10,
          "runs" => 2,
          "bytes" => bytes,
          "running" => false,
          "open" => false,
          "pinned" => false,
          "deletable" => true,
          "reason" => nil
        },
        extra
      )
    end
  end

  defp seed_files do
    lines = fn n, prefix -> Enum.map_join(1..n, "", &"#{prefix} #{&1}\n") end

    %{
      "memory_project:project:#{@ailogic}:MEMORY" => %{
        content: lines.(42, "- fact"),
        path: "~/dev/ailogic/.swarm_code/MEMORY.md",
        winner: nil
      },
      "instructions:project:#{@ailogic}:AGENTS" => %{
        content: lines.(120, "rule"),
        path: "~/dev/ailogic/AGENTS.md",
        winner: "AGENTS.md"
      },
      "instructions:project:#{@notes}:AGENTS" => %{
        content: lines.(8, "note"),
        path: "~/dev/notes/CLAUDE.md",
        winner: "CLAUDE.md"
      },
      "command:global:-:review" => %{
        content: "---\ndescription: Review the staged diff\n---\nReview the staged diff.\n",
        path: "~/.swarm_code/commands/review.md",
        winner: nil
      },
      "command:project:#{@ailogic}:deploy" => %{
        content: "---\ndescription: Deploy the app to staging\nmode: build\n---\nDeploy.\n",
        path: "~/dev/ailogic/.swarm_code/commands/deploy.md",
        winner: nil
      },
      "agent:user:-:scout" => %{
        content: "---\nname: scout\nmodel: claude-opus-5\neffort: high\n---\nScout.\n",
        path: "~/.swarm_code/agents/scout.md",
        winner: nil
      },
      "agent:bundled:-:reviewer" => %{
        content: "---\nname: reviewer\n---\nReview.\n",
        path: "(bundled)/agents/reviewer.md",
        winner: nil
      },
      "agent:project:#{@ailogic}:reviewer" => %{
        content: "---\nname: reviewer\neffort: medium\n---\nReview harder.\n",
        path: "~/dev/ailogic/.swarm_code/agents/reviewer.md",
        winner: nil
      },
      "skill:project:#{@ailogic}:html-report" => %{
        content: "# html-report\n\nBuild a report page\n",
        path: "~/dev/ailogic/.swarm_code/skills/html-report/SKILL.md",
        winner: nil
      },
      "workflow:user:-:nightly" => %{
        content: "meta %{name: \"nightly\"}\n",
        path: "~/.swarm_code/workflows/nightly.exs",
        winner: nil
      },
      "workflow:project:#{@ailogic}:broken" => %{
        content: "meta %{name: \"broken\"}\nSystem.os_time()\n",
        path: "~/dev/ailogic/.swarm_code/workflows/broken.exs",
        winner: nil
      }
    }
  end

  defp seed_library do
    %{
      "commands" => [
        %{
          "ref" => "command:project:#{@ailogic}:deploy",
          "project_id" => @ailogic,
          "name" => "deploy",
          "scope" => "project",
          "description" => "Deploy the app to staging",
          "swarm" => false,
          "mode" => "build",
          "overrides_global" => false,
          "shadowed_by_builtin" => false,
          "path" => "~/dev/ailogic/.swarm_code/commands/deploy.md"
        },
        %{
          "ref" => "command:global:-:review",
          "project_id" => nil,
          "name" => "review",
          "scope" => "global",
          "description" => "Review the staged diff",
          "swarm" => false,
          "mode" => nil,
          "overrides_global" => false,
          "shadowed_by_builtin" => false,
          "path" => "~/.swarm_code/commands/review.md"
        }
      ],
      "agent_defs" => [
        %{
          "ref" => "agent:project:#{@ailogic}:reviewer",
          "project_id" => @ailogic,
          "name" => "reviewer",
          "tier" => "project",
          "description" => "Review harder",
          "tools_label" => "all tools",
          "model" => nil,
          "effort" => "medium",
          "prewalk" => false,
          "max_turns" => nil,
          "shadows" => "bundled",
          "shadowed" => false,
          "parse_error" => nil,
          "path" => "~/dev/ailogic/.swarm_code/agents/reviewer.md"
        },
        %{
          "ref" => "agent:bundled:-:reviewer",
          "project_id" => nil,
          "name" => "reviewer",
          "tier" => "bundled",
          "description" => "Review",
          "tools_label" => "all tools",
          "model" => nil,
          "effort" => nil,
          "prewalk" => false,
          "max_turns" => nil,
          "shadows" => nil,
          "shadowed" => true,
          "parse_error" => nil,
          "path" => "(bundled)/agents/reviewer.md"
        },
        %{
          "ref" => "agent:user:-:scout",
          "project_id" => nil,
          "name" => "scout",
          "tier" => "user",
          "description" => "Scout",
          "tools_label" => "all tools",
          "model" => "claude-opus-5",
          "effort" => "high",
          "prewalk" => false,
          "max_turns" => nil,
          "shadows" => nil,
          "shadowed" => false,
          "parse_error" => nil,
          "path" => "~/.swarm_code/agents/scout.md"
        }
      ],
      "skills" => [
        %{
          "ref" => "skill:project:#{@ailogic}:html-report",
          "project_id" => @ailogic,
          "name" => "html-report",
          "scope" => "project",
          "description" => "Build a report page",
          "files" => 3,
          "bytes" => 4_200,
          "shadowed" => false,
          "path" => "~/dev/ailogic/.swarm_code/skills/html-report/SKILL.md"
        }
      ],
      "workflows" => [
        %{
          "ref" => "workflow:user:-:nightly",
          "project_id" => nil,
          "name" => "nightly",
          "scope" => "user",
          "path" => "~/.swarm_code/workflows/nightly.exs"
        },
        %{
          "ref" => "workflow:project:#{@ailogic}:broken",
          "project_id" => @ailogic,
          "name" => "broken",
          "scope" => "project",
          "path" => "~/dev/ailogic/.swarm_code/workflows/broken.exs"
        }
      ]
    }
  end

  defp seed_project_config do
    %{
      "effort" => "high",
      "hooks" => %{
        "post_tool_use" => [
          %{"matcher" => "^edit_file$", "command" => "mix format", "timeout_ms" => 10_000}
        ],
        "post_edit" => [%{"matcher" => "*.ex", "command" => "mix format"}]
      },
      "profiles" => %{"fast" => %{"mode" => "auto", "effort" => "low"}},
      "x-custom" => true
    }
  end
end
