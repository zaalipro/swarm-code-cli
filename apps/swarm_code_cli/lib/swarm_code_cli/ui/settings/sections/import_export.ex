defmodule SwarmCodeCLI.UI.Settings.Sections.ImportExport do
  @moduledoc """
  pass74 U3-13 (spec §2.22, sketch §4.15): Import & export.

    * `▸ Export settings…` opens the export page: the file (default
      `~/swarmcode-settings-YYYY-MM-DD.json`), one toggle per scope (global
      values, terminal, this project, providers and search providers without
      keys, MCP servers, pricing, language servers, desktop keys), *include
      plain MCP values* (off: every MCP env/header value is written as
      `<secret: set>`; secret-shaped values always are), then `▸ Export`.
      Never secrets.
    * `▸ Import settings…` asks for a file, reads it (`import.preview`) and
      shows `key · now · after` with ticks, paged from the task's result;
      `Enter` applies the ticked rows only (scalars as one undoable batch;
      records never carry keys: paste the key after import).
    * `▸ Reset everything to defaults…` asks for the typed word `reset`.

  The pages' own state (the path, the scopes, the ticks) lives in the page's
  `sub`, so it is pure and survives a redraw.
  """

  use SwarmCodeCLI.UI.Settings.Section, id: :import_export

  alias SwarmCodeCLI.UI.Settings.{Confirm, Page, Row, Rows}

  @scopes [
    {"global", "Global values", true},
    {"terminal", "Terminal (cli.json)", true},
    {"project", "This project (approvals, always-allowed commands)", true},
    {"providers", "Providers (no keys)", true},
    {"search", "Search providers (no keys)", true},
    {"mcp", "MCP servers", true},
    {"pricing", "Pricing", true},
    {"lsp", "Language servers", true},
    {"desktop_keys", "Desktop keys", true}
  ]

  @impl true
  def loads(_ctx), do: []

  @impl true
  def rows(ctx) do
    Rows.registry(ctx, :import_export)
    |> Enum.map(fn
      %Row{key: "transfer.reset_everything"} = row ->
        %Row{row | lines: row.lines ++ [[{"asks you to type reset · not undoable", :text_faint}]]}

      row ->
        row
    end)
  end

  @impl true
  def title(%{page: %Page{sub: {:export, _}}}), do: "Import & export › Export"
  def title(%{page: %Page{sub: {:import, _}}}), do: "Import & export › Import"
  def title(_ctx), do: "Import & export"

  # --------------------------------------------------------------- export

  @doc "The export page's starting state (the date comes from `ctx.now`)."
  @spec export_state(integer()) :: map()
  def export_state(now_ms) do
    date = now_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_date() |> Date.to_iso8601()

    %{
      path: "~/swarmcode-settings-#{date}.json",
      scopes: for({id, _label, on?} <- @scopes, on?, do: id),
      plain: false,
      overwrite: false
    }
  end

  @impl true
  def sub_rows(_ctx, {:export, state}) do
    [
      %Row{
        id: "exp:path",
        kind: :setting,
        label: "File",
        value: [{state.path, :text_primary}],
        editor: {SwarmCodeCLI.UI.Settings.Editors.Text, %{value: state.path}},
        keys: [{"Enter", :enter, "change the file"}],
        target: {:export, :path}
      },
      Row.heading("what goes in · never secrets")
    ] ++
      Enum.map(@scopes, fn {id, label, _} ->
        on? = id in state.scopes

        %Row{
          id: "exp:scope:" <> id,
          kind: :setting,
          label: label,
          value: [
            {if(on?, do: "[✓]", else: "[ ]"), if(on?, do: :text_primary, else: :text_muted)}
          ],
          target: {:export, {:scope, id}},
          keys: [{"Space", :toggle, "include or leave out"}]
        }
      end) ++
      [
        %Row{
          id: "exp:plain",
          kind: :setting,
          label: "Include plain MCP values",
          value: [{if(state.plain, do: "[✓] on", else: "[ ] off"), :text_muted}],
          lines: [
            [
              {"off: every MCP env and header value is written as <secret: set>; values shaped like secrets always are",
               :text_faint}
            ]
          ],
          target: {:export, :plain},
          keys: [{"Space", :toggle, "switch"}]
        },
        %Row{
          id: "exp:overwrite",
          kind: :setting,
          label: "Replace the file if it exists",
          value: [{if(state.overwrite, do: "[✓] yes", else: "[ ] no"), :text_muted}],
          target: {:export, :overwrite},
          keys: [{"Space", :toggle, "switch"}]
        },
        %Row{
          id: "exp:go",
          kind: :action,
          label: "Export",
          value: [{"#{length(state.scopes)} parts to #{state.path}", :text_muted}],
          target: {:export, :go},
          keys: [{"Enter", :enter, "export now"}]
        }
      ]
  end

  def sub_rows(ctx, {:import, state}), do: import_rows(ctx, state)
  def sub_rows(_ctx, _sub), do: []

  @impl true
  def act(ctx, %Row{key: "transfer.export"}, verb) when verb in [:open, :enter, :open_row],
    do: [{:open, %Page{section: :import_export, sub: {:export, export_state(ctx.now)}}}]

  def act(_ctx, %Row{key: "transfer.import"}, verb) when verb in [:open, :enter, :open_row],
    do: [
      {:open,
       %Page{
         section: :import_export,
         sub: {:import, %{path: "", task_id: nil, ticks: nil, cursor: nil}}
       }}
    ]

  def act(ctx, %Row{key: "transfer.reset_everything"}, verb)
      when verb in [:open, :enter, :open_row] do
    cli_keys = Map.keys(ctx.prefs || %{}) -- ["x-unknown"]

    [
      {:confirm,
       %Confirm{
         id: "reset-everything",
         title: "Reset everything to defaults?",
         lines: [
           "Every global value and every terminal preference goes back to its default.",
           "Secrets, providers, MCP servers, sessions and projects are not touched.",
           "#{length(cli_keys)} terminal preferences in cli.json · keys this CLI does not know are kept."
         ],
         safe: "Cancel",
         danger: "R  Reset everything",
         letter: "R",
         undoable?: false,
         typed: "reset",
         opener: "key:transfer.reset_everything"
       }, then: reset_everything_ops(ctx)}
    ]
  end

  def act(ctx, %Row{target: {:export, part}} = row, verb) do
    state = sub_state(ctx, :export)

    case {part, verb} do
      {{:scope, id}, v} when v in [:toggle, :open, :enter, :open_row] ->
        scopes =
          if id in state.scopes, do: List.delete(state.scopes, id), else: state.scopes ++ [id]

        reopen(:export, %{state | scopes: order(scopes)}, row.id)

      {:plain, v} when v in [:toggle, :open, :enter, :open_row] ->
        reopen(:export, %{state | plain: not state.plain}, row.id)

      {:overwrite, v} when v in [:toggle, :open, :enter, :open_row] ->
        reopen(:export, %{state | overwrite: not state.overwrite}, row.id)

      {:go, v} when v in [:open, :enter, :open_row] ->
        if state.scopes == [] do
          [{:toast, "Pick at least one part to export", :warning}]
        else
          [
            {:task, "export", %{"path" => state.path},
             %{
               "scopes" => state.scopes,
               "terminal" => if("terminal" in state.scopes, do: ctx.prefs || %{}, else: %{}),
               "mcp_plain_values" => state.plain,
               "overwrite" => state.overwrite
             }}
          ]
        end

      _ ->
        :default
    end
  end

  def act(ctx, %Row{target: {:import, part}} = row, verb), do: import_act(ctx, row, part, verb)

  def act(_ctx, _row, _verb), do: :default

  @impl true
  def commit(ctx, %Row{target: {:export, :path}} = row, value) when is_binary(value) do
    state = sub_state(ctx, :export)
    reopen(:export, %{state | path: String.trim(value)}, row.id)
  end

  def commit(ctx, %Row{target: {:import, :path}}, value) when is_binary(value) do
    path = String.trim(value)

    if path == "" do
      [{:toast, "Type the file to import", :warning}]
    else
      state = sub_state(ctx, :import)

      [{:task, "import.preview", %{"path" => path}, %{}}] ++
        reopen(:import, %{state | path: path}, "imp:path")
    end
  end

  def commit(_ctx, _row, _value), do: :default

  # --------------------------------------------------------------- import

  defp import_rows(ctx, state) do
    path_row = %Row{
      id: "imp:path",
      kind: :setting,
      label: "File",
      value: [
        {if(state.path == "", do: "type the file to read", else: state.path),
         if(state.path == "", do: :text_ghost, else: :text_primary)}
      ],
      editor: {SwarmCodeCLI.UI.Settings.Editors.Text, %{value: state.path}},
      target: {:import, :path},
      keys: [{"Enter", :enter, "choose the file"}]
    }

    case preview(ctx, state) do
      nil ->
        [path_row | task_line(ctx, state)]

      {task_id, rows, summary} ->
        ticks = ticks(state, rows)
        count = Enum.count(rows, &(&1.status == "change" and MapSet.member?(ticks, &1.id)))

        head = %Row{
          id: "imp-head",
          kind: :heading,
          label: "",
          columns: [
            {"✓", :text_faint, 1},
            {"key or record", :text_faint, 1},
            {"now", :text_faint, 2},
            {"after", :text_faint, 2}
          ]
        }

        body = Enum.map(rows, &preview_row(&1, ticks))

        apply_row = %Row{
          id: "imp:apply",
          kind: :action,
          label: "Apply #{count} #{if count == 1, do: "change", else: "changes"}",
          value: [{"scalars are one undo step · records never carry keys", :text_muted}],
          target: {:import, {:apply, task_id}},
          keys: [{"Enter", :enter, "apply the ticked rows"}]
        }

        [Row.info("imp-summary", summary_words(summary, state.path)), path_row, head] ++
          body ++ [apply_row]
    end
  end

  defp task_line(ctx, state) do
    case state.task_id && task(ctx, state.task_id) do
      %{state: "failed", message: message} ->
        [Row.info("imp-failed", "✗ " <> (message || "Couldn't read that file"), role: :error)]

      %{state: s} when s in ["running", :running] ->
        [Row.info("imp-running", "◷ reading #{state.path}", role: :info)]

      _ ->
        []
    end
  end

  defp preview_row(row, ticks) do
    tickable? = row.status == "change"
    on? = tickable? and MapSet.member?(ticks, row.id)

    {mark, after_text, after_role} =
      case row.status do
        "change" -> {if(on?, do: "[✓]", else: "[ ]"), row.after, :text_primary}
        "same" -> {"   ", "#{row.after}   same", :text_faint}
        "invalid" -> {"  ✗", "#{row.after}   #{row.message || "not applied"}", :error}
        "secret_skipped" -> {"   ", "paste the key after import", :text_faint}
        _ -> {"   ", row.after, :text_muted}
      end

    %Row{
      id: "imp:" <> row.id,
      kind: :record,
      label: row.key,
      columns: [
        {mark, if(on?, do: :text_primary, else: :text_muted), 1},
        {row.key, :text_primary, 1},
        {row.now, :text_muted, 2},
        {after_text, after_role, 2}
      ],
      state: if(tickable?, do: :normal, else: :readonly),
      target: {:import, {:tick, row.id}},
      keys: if(tickable?, do: [{"Space", :toggle, "tick"}, {"A", :all_on, "tick all"}], else: [])
    }
  end

  defp import_act(ctx, row, part, verb) do
    state = sub_state(ctx, :import)

    case {part, verb} do
      {{:tick, id}, v} when v in [:toggle, :open, :enter, :open_row] ->
        {_task, rows, _} = preview(ctx, state) || {nil, [], nil}
        ticks = ticks(state, rows)

        ticks =
          if MapSet.member?(ticks, id), do: MapSet.delete(ticks, id), else: MapSet.put(ticks, id)

        reopen(:import, %{state | ticks: ticks}, row.id)

      {_, :all_on} ->
        {_task, rows, _} = preview(ctx, state) || {nil, [], nil}
        ids = for r <- rows, r.status == "change", into: MapSet.new(), do: r.id
        reopen(:import, %{state | ticks: ids}, row.id)

      {{:apply, task_id}, v} when v in [:open, :enter, :open_row] ->
        {_task, rows, _} = preview(ctx, state) || {nil, [], nil}

        ids =
          for r <- rows, r.status == "change", MapSet.member?(ticks(state, rows), r.id), do: r.id

        cond do
          ids == [] ->
            [{:toast, "Nothing is ticked", :info}]

          length(ids) > 20 and state.cursor != :confirmed ->
            [
              {:confirm,
               %Confirm{
                 id: "import-apply",
                 title: "Apply #{length(ids)} changes?",
                 lines: [
                   "The table above is what changes. Scalars are one undo step; records are not undoable."
                 ],
                 safe: "Cancel",
                 danger: "A  Apply #{length(ids)} changes",
                 letter: "A",
                 opener: row.id
               }, then: apply_ops(task_id, ids, rows)}
            ]

          true ->
            apply_ops(task_id, ids, rows)
        end

      _ ->
        :default
    end
  end

  defp apply_ops(task_id, ids, rows) do
    task = {:task, "import.apply", nil, %{"preview_id" => task_id, "rows" => ids}}

    # the terminal's rows are this client's cli.json (§2.22: client-side apply)
    cli =
      for row <- rows,
          row.id in ids,
          row.scope == "terminal",
          name = cli_name(row.key),
          name != nil,
          into: %{},
          do: {name, row.raw_after}

    if cli == %{}, do: [task], else: [task, {:cli_write, cli}]
  end

  defp cli_name(key) do
    case SwarmCode.Settings.Registry.fetch(key) do
      {:ok, %{storage: {:cli, name}}} -> name
      _ -> nil
    end
  end

  @doc false
  def preview(ctx, state) do
    task_id = state.task_id || latest_preview(ctx, state.path)

    with id when is_binary(id) <- task_id,
         %{} = view <- ctx.data |> Map.get(:task_views, %{}) |> Map.get(id) do
      rows =
        view
        |> Map.get(:pages, %{})
        |> Enum.sort_by(fn {cursor, _} -> to_string(cursor) end)
        |> Enum.flat_map(fn {_cursor, rows} -> rows end)
        |> Enum.map(&preview_item/1)

      {id, rows, Map.get(view, :summary)}
    else
      _ -> nil
    end
  end

  defp latest_preview(ctx, path) do
    tasks = ctx.layer && Map.get(ctx.layer, :tasks, %{})

    (tasks || %{})
    |> Enum.filter(fn {_id, t} ->
      Map.get(t, :action) == "import.preview" and
        (path == "" or get(Map.get(t, :target), :path) == path)
    end)
    |> Enum.max_by(fn {_id, t} -> Map.get(t, :received_at_ms, 0) end, fn -> nil end)
    |> case do
      nil -> nil
      {id, _} -> id
    end
  end

  defp preview_item(row) do
    %{
      id: to_string(get(row, :id)),
      key: to_string(get(row, :key_or_record) || get(row, :key) || "?"),
      now: words(get(row, :now)),
      after: words(get(row, :after)),
      status: to_string(get(row, :status) || "change"),
      message: get(row, :message),
      scope: to_string(get(row, :scope) || ""),
      raw_after: get(row, :after)
    }
  end

  defp ticks(%{ticks: %MapSet{} = ticks}, _rows), do: ticks

  defp ticks(_state, rows),
    do: for(r <- rows, r.status == "change", into: MapSet.new(), do: r.id)

  @count_words [
    {:values, "value", "values"},
    {:providers, "provider", "providers"},
    {:search_providers, "search provider", "search providers"},
    {:mcp_servers, "MCP server", "MCP servers"},
    {:pricing, "price", "prices"},
    {:lsp_servers, "language server", "language servers"},
    {:desktop_keys, "desktop key", "desktop keys"}
  ]

  @doc "The preview's header words: `Import · <path> · 71 values, 3 providers, 1 MCP server`."
  @spec summary_words(map() | nil, String.t()) :: String.t()
  def summary_words(summary, path) do
    counts =
      for {key, one, many} <- @count_words,
          n = get(summary || %{}, key),
          is_integer(n) and n > 0,
          do: "#{n} #{if n == 1, do: one, else: many}"

    Enum.join(
      ["Import", path] ++ if(counts == [], do: [], else: [Enum.join(counts, ", ")]),
      " · "
    )
  end

  defp words(nil), do: "—"
  defp words(value) when is_binary(value), do: value
  defp words(value) when is_boolean(value), do: if(value, do: "on", else: "off")
  defp words(value) when is_number(value), do: to_string(value)
  defp words(value) when is_list(value), do: Enum.map_join(value, ", ", &words/1)
  defp words(value), do: value |> inspect() |> String.slice(0, 60)

  # ---------------------------------------------------------------- helpers

  @reset_words "Every value is back to its default · no undo"

  # §3.3.4: the reset names every changed global value with its snapshot base
  # (a value changed since conflicts and nothing is written); the cli.json half
  # says nothing when the database half speaks, so the last word is the reset's.
  defp reset_everything_ops(ctx) do
    keys = changed_global_keys(ctx)
    cli = reset_cli(ctx)

    values =
      if keys == [],
        do: [],
        else: [
          {:command, "values.reset", nil, %{"keys" => keys},
           %{expected: Map.new(keys, &{&1, base(ctx, &1)}), toast: @reset_words, undo: false}}
        ]

    cli =
      case cli do
        [] ->
          []

        [{:cli_write, changes}] ->
          [{:cli_write, changes, %{toast: if(values == [], do: @reset_words)}}]
      end

    case values ++ cli do
      [] -> [{:toast, "Nothing to reset: every value is its default", :text_muted}]
      ops -> ops
    end
  end

  defp changed_global_keys(ctx) do
    values = (ctx.data && ctx.data.values) || %{}

    for entry <- SwarmCode.Settings.Registry.all(),
        entry.home == :global and entry.resettable and
          SwarmCode.Settings.Entry.writable?(entry) and not match?({:cli, _}, entry.storage),
        %{winner: winner} <- [Map.get(values, entry.key)],
        winner not in [:default, nil],
        do: entry.key
  end

  defp base(ctx, key) do
    case Map.get(ctx.data.values, key) do
      %{base: base} when base not in [nil, :absent] -> base
      _ -> %{"$any" => true}
    end
  end

  defp reset_cli(ctx) do
    known = known_cli_names()

    changes =
      for {name, _} <- ctx.prefs || %{}, name in known, into: %{}, do: {name, :remove}

    if changes == %{}, do: [], else: [{:cli_write, changes}]
  end

  defp known_cli_names,
    do: for(%{storage: {:cli, name}} <- SwarmCode.Settings.Registry.cli_entries(), do: name)

  defp reopen(kind, state, cursor),
    do: [:back, {:open, %Page{section: :import_export, sub: {kind, state}, cursor: cursor}}]

  defp sub_state(%{page: %Page{sub: {kind, state}}}, kind), do: state

  defp sub_state(ctx, :export), do: export_state(ctx.now)
  defp sub_state(_ctx, :import), do: %{path: "", task_id: nil, ticks: nil, cursor: nil}

  defp order(scopes), do: for({id, _, _} <- @scopes, id in scopes, do: id)

  defp task(ctx, id) do
    case ctx.layer && Map.get(ctx.layer, :tasks, %{}) |> Map.get(id) do
      nil -> nil
      t -> %{state: to_string(Map.get(t, :state)), message: Map.get(t, :message)}
    end
  end

  defp get(nil, _key), do: nil
  defp get(map, key) when is_map(map), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp get(_other, _key), do: nil
end
