defmodule SwarmCodeCLI.Test.C74U2Ctx do
  @moduledoc """
  Section contexts built from `Fake.SettingsIntegrations` (U2 tests): the records a page
  loads, as the layer holds them after their queries answered (§3.7.4), plus the layer
  fields a section reads (tasks, drafts, staged, filter).
  """

  alias SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations, as: I

  @kinds ~w(providers model_options effort_presets pricing_rows unpriced_models search_providers
            mcp_servers memory_files commands agent_defs skills workflows)

  def ctx(state \\ I.seed(), opts \\ []) do
    records =
      for kind <- Keyword.get(opts, :kinds, @kinds), into: %{} do
        {:ok, page} = I.query(state, %{"view" => "records", "kind" => kind, "page_size" => 200})

        {{kind, %{}},
         %{
           items: page["items"],
           next_cursor: page["next_cursor"],
           total: page["total"],
           loaded_at: 0
         }}
      end

    singles =
      for {kind, id} <- Keyword.get(opts, :records, []), into: %{} do
        {:ok, rec} = I.query(state, %{"view" => "record", "kind" => kind, "id" => id})
        {{kind, id}, %{fields: rec["fields"], loaded_at: 0}}
      end

    layer =
      Map.merge(
        %{
          tasks: %{},
          drafts: %{},
          staged: %{},
          row_errors: %{},
          filter: nil,
          page_project_id: nil
        },
        Map.new(Keyword.get(opts, :layer, []))
      )

    %{
      data: %{
        records: records,
        record: singles,
        files: Keyword.get(opts, :files, %{}),
        values: Keyword.get(opts, :values, default_values()),
        task_views: Keyword.get(opts, :task_views, %{})
      },
      layer: layer,
      caps: %{glyph_tier: Keyword.get(opts, :tier, :rich), paste: :bracketed},
      size: {160, 45},
      now: Keyword.get(opts, :now, 1_000_000),
      project: %{"id" => I.ids().ailogic, "name" => "ailogic"},
      conversation: %{"id" => I.ids().conversation},
      prefs: %{},
      launch_facts: %{env: %{"VISUAL" => "hx"}},
      overrides: nil,
      page:
        Keyword.get(opts, :page, %{section: nil, record: nil, sub: nil, cursor: nil, scroll: 0})
    }
  end

  @doc "Appendix A values the integration pages read."
  def default_values do
    ids = I.ids()

    %{
      "models.chat" => %{
        key: "models.chat",
        value: %{"provider_id" => ids.deepseek, "model" => "deepseek-v4-pro"},
        state: "ok"
      },
      "models.sub_agent" => %{
        key: "models.sub_agent",
        value: %{"provider_id" => ids.deepseek, "model" => "deepseek-v4-flash"},
        state: "ok"
      },
      "web.reader" => %{key: "web.reader", value: "web_fetch", state: "ok"},
      "storage.retention_days" => %{key: "storage.retention_days", value: nil, state: "ok"},
      "storage.prune_days" => %{key: "storage.prune_days", value: nil, state: "ok"}
    }
  end

  def put_task(ctx, id, task),
    do: put_in(ctx.layer.tasks[id], Map.merge(%{received_at_ms: ctx.now, elapsed_ms: 0}, task))

  def put_layer(ctx, key, value), do: put_in(ctx, [:layer, key], value)

  def text(segments), do: Enum.map_join(segments, "", fn {t, _} -> t end)
end

defmodule SwarmCodeCLI.Test.C74U2Ctx.Page do
  @moduledoc false
  def at(section, record \\ nil, sub \\ nil),
    do: %{section: section, record: record, sub: sub, cursor: nil, scroll: 0}
end

defmodule SwarmCodeCLI.Test.C74U2Tasks do
  @moduledoc false
  alias SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations, as: I

  @doc "Runs `action` through the fake: `{state, task_map_for_the_layer, rows}`."
  def run(
        state,
        action,
        target,
        attributes \\ %{},
        outcome \\ :run,
        task_id \\ nil,
        secrets \\ []
      ) do
    {{:task, task, _}, state} =
      I.command(state, %{
        "action" => action,
        "target" => target,
        "attributes" => attributes,
        "secrets" => secrets
      })

    id = task_id || "task-" <> action
    task = Map.put(task, "task_id", id)

    case I.run_task(state, task, outcome) do
      {{:done, summary, rows}, state} ->
        {state, id,
         %{
           action: action,
           target: target,
           state: "done",
           summary: summary,
           at: "2026-09-25T18:42:00Z",
           cancellable: task["cancellable"]
         }, rows}

      {{:failed, message}, state} ->
        {state, id,
         %{
           action: action,
           target: target,
           state: "failed",
           message: message,
           at: "2026-09-25T18:42:00Z",
           cancellable: task["cancellable"]
         }, []}
    end
  end

  @doc "Puts a finished task and its rows into a section context."
  def put(ctx, id, task, rows) do
    ctx
    |> put_in([:layer, :tasks, id], Map.merge(%{received_at_ms: ctx.now, elapsed_ms: 400}, task))
    |> put_in([:data, :task_views, id], %{summary: task[:summary], pages: %{nil => rows}})
  end
end
