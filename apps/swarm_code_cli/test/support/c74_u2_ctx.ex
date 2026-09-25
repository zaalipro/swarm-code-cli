defmodule SwarmCodeCLI.Test.C74U2Ctx do
  @moduledoc """
  Section contexts built from `Fake.SettingsIntegrations` (U2 tests): the records a page
  loads, as the layer holds them after their queries answered (§3.7.4), plus the layer
  fields a section reads (tasks, drafts, staged, filter).
  """

  alias SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations, as: I

  @kinds ~w(providers model_options pricing_rows unpriced_models search_providers mcp_servers
            memory_files commands agent_defs skills workflows)

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
        {{kind, id}, rec}
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
        values: Keyword.get(opts, :values, %{}),
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
      overrides: nil
    }
  end

  def put_task(ctx, id, task),
    do: put_in(ctx.layer.tasks[id], Map.merge(%{received_at_ms: ctx.now, elapsed_ms: 0}, task))

  def put_layer(ctx, key, value), do: put_in(ctx, [:layer, key], value)

  def text(segments), do: Enum.map_join(segments, "", fn {t, _} -> t end)
end
