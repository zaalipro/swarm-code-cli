defmodule SwarmCodeCLI.UI.Settings.Sections.MCP do
  @moduledoc """
  The MCP servers section (spec §2.7, §2.23 *mcp_server*/*mcp_tool*, F8, the import sketch).

  * The list: a project picker (D12), servers grouped `every project` / `<project> only`,
    each `name · transport · state · tools on/total` (`Space` on/off at once, `R` restart,
    `t` test), a draft link, `▸ Add an MCP server`, `▸ Import from .mcp.json` (and from a
    path you type) → the import preview (`Settings.McpImport`).
  * A server's page (F8): connection fields are **staged** (D8) — name, scope, transport,
    command, arguments, environment, URL, headers — and applied once in one `mcp.update`
    on leaving the page or with `R restart now`; `r` reverts a staged field (on the head row:
    every staged field). Enabled switches at once. The tools checklist (`Space` one, `A` all
    on, `N` all off, `/` filter), `t` test, `o` the server's output, the scope row as the only
    way to change scope (R7), `D` delete (asks).
  * Sub-pages `:env`, `:headers` (`Settings.KeyValueSecrets`), `:output`, `:import`.

  Pure.
  """

  alias SwarmCodeCLI.UI.Settings.{KeyValueSecrets, McpImport}
  alias SwarmCodeCLI.UI.Settings.IntegrationRows, as: R

  @kind "mcp_server"
  @draft "draft"
  @staged_fields ~w(name project_id transport command args env url headers)

  def id, do: :mcp

  def loads(ctx) do
    project = R.project_id(ctx)
    list = {:records, "mcp_servers", %{"project_id" => project}}

    case R.page_record(ctx) do
      {@kind, @draft} -> [list]
      {@kind, id} -> [{:record, @kind, id}, list]
      _ -> [list]
    end
  end

  def title(ctx) do
    case {R.page_record(ctx), R.page_sub(ctx)} do
      {_, :import} -> "MCP servers › Import"
      {{@kind, @draft}, _} -> "New MCP server · unsaved · Ctrl-S creates it · Esc discards"
      {{@kind, id}, _} -> server_name(ctx, id) || "MCP servers"
      _ -> "MCP servers"
    end
  end

  def counts(ctx),
    do: %{records: if(R.loaded?(ctx, "mcp_servers"), do: length(R.items(ctx, "mcp_servers")))}

  def attention(_ctx), do: []

  defp server(ctx, id) do
    case R.record(ctx, @kind, id) do
      nil -> nil
      rec -> R.fields(rec)
    end
  end

  defp server_name(ctx, id) do
    case server(ctx, id) do
      nil -> nil
      f -> R.field(f, "name")
    end
  end

  # ---------------------------------------------------------------- the list

  def rows(ctx) do
    if R.page_sub(ctx) == :import do
      McpImport.rows(ctx)
    else
      list_rows(ctx)
    end
  end

  defp list_rows(ctx) do
    servers = Enum.map(R.items(ctx, "mcp_servers"), &R.fields/1)
    project = R.project_id(ctx)
    {global, local} = Enum.split_with(servers, &(R.field(&1, "project_id") == nil))
    pname = R.project_name(ctx)

    picker =
      R.row(
        id: "fld:mcp:project",
        kind: :field,
        label: "Project",
        value: [{pname, :text_primary}, {" ▾", :text_faint}],
        tag: [{"the servers of every project and of this one", :text_faint}],
        keys: [{"Enter", :open_row, "pick a project"}],
        target: {:project_picker}
      )

    body =
      cond do
        not R.loaded?(ctx, "mcp_servers") ->
          [R.info("loading", "…", :text_faint)]

        servers == [] ->
          [
            R.info(
              "empty",
              "No MCP server yet · a adds one · ▸ Import from .mcp.json reads the ones a project lists"
            )
          ]

        true ->
          [R.heading("every project", "every project")] ++
            if(global == [],
              do: [R.info("global:none", "none", :text_ghost)],
              else: Enum.map(global, &server_row(ctx, &1))
            ) ++
            [R.heading("project only", "#{pname} only")] ++
            if(local == [],
              do: [R.info("local:none", "none", :text_ghost)],
              else: Enum.map(local, &server_row(ctx, &1))
            )
      end

    draft =
      case R.draft(ctx, @kind) do
        nil ->
          []

        d ->
          [
            R.row(
              id: "link:mcp:draft",
              kind: :link,
              label: blank(R.field(R.draft_fields(d), "name"), "New server"),
              value: [{"unsaved", :warning}],
              keys: [{"Enter", :open_row, "open the draft"}],
              target: {:draft}
            )
          ]
      end

    import_task = R.task(ctx, "mcp.import.read")

    import_value =
      case import_task do
        nil ->
          [
            {"reads #{if project, do: "the project's", else: "a"} .mcp.json; nothing is saved until you import",
             :text_faint}
          ]

        task ->
          elem(
            R.task_words(ctx, task, "reading .mcp.json", fn s ->
              "#{R.count(R.field(s, "count") || 0, "server")} found · Enter shows them"
            end),
            0
          )
      end

    [picker] ++
      body ++
      draft ++
      [
        R.heading("actions", "actions"),
        R.row(
          id: "act:mcp.add",
          kind: :action,
          label: "▸ Add an MCP server",
          value: [{"stdio, on · Ctrl-S creates it", :text_faint}],
          keys: [{"Enter", :open_row, "add"}, {"a", :add, "add"}],
          target: {:add}
        ),
        R.row(
          id: "act:mcp.import",
          kind: :action,
          label: "▸ Import from .mcp.json",
          value: import_value,
          state: if(R.running?(import_task), do: :running, else: :normal),
          keys: [{"Enter", :open_row, "read it"}],
          target: {:import, nil}
        ),
        R.row(
          id: "act:mcp.import_path",
          kind: :action,
          label: "▸ Import from a file…",
          value: [{"a path in your home folder", :text_faint}],
          editor: {SwarmCodeCLI.UI.Settings.Editors.Text, %{value: "~/", max: 1_024}},
          keys: [{"Enter", :open_row, "type the path"}],
          target: {:import_path}
        )
      ]
  end

  defp server_row(ctx, f) do
    id = R.field(f, "id")
    on = R.field(f, "enabled") == true

    R.row(
      id: "rec:mcp_server:#{id}",
      kind: :record,
      label: R.field(f, "name"),
      value: status_segments(ctx, f),
      marks: if(on and R.field(f, "status") == "error", do: [:attention], else: []),
      columns: [
        {R.field(f, "name"), :text_primary, 1},
        {R.field(f, "transport"), :text_muted, 3},
        {status_segments(ctx, f) |> Enum.map_join("", &elem(&1, 0)), :text_muted, 2},
        {tools_words(f), :text_faint, 4}
      ],
      keys: [
        {"Enter", :open_row, "open"},
        {"Space", :toggle, if(on, do: "turn off", else: "turn on")},
        {"R", :restart, "restart now"},
        {"t", :test, "test"}
      ],
      target: {:server, id}
    )
  end

  @doc "The state of a server in words: `✓ connected`, `◷ connecting`, `✗ failed: …`, `off`."
  def status_segments(ctx, f) do
    cond do
      R.field(f, "enabled") != true ->
        [{"off", :text_faint}]

      R.field(f, "status") == "ready" ->
        [{R.glyph(ctx, :ok) <> " ", :success}, {"connected", :text_muted}]

      R.field(f, "status") == "connecting" ->
        [{R.glyph(ctx, :running) <> " ", :info}, {"connecting", :text_muted}]

      R.field(f, "status") == "error" ->
        [
          {R.glyph(ctx, :error) <> " ", :error},
          {"failed: #{R.field(f, "status_message")}", :text_muted}
        ]

      true ->
        [{"stopped", :text_faint}]
    end
  end

  defp tools_words(f) do
    total = R.field(f, "tools_total") || 0
    on = R.field(f, "tools_enabled") || total
    if total == 0, do: "no tools yet", else: "#{on}/#{total} tools"
  end

  # --------------------------------------------------------- a server's page

  def record_rows(ctx, @kind, @draft), do: draft_rows(ctx)

  def record_rows(ctx, @kind, id) do
    case {server(ctx, id), R.page_sub(ctx)} do
      {nil, _} ->
        if R.loaded?(ctx, "mcp_servers"),
          do: [
            R.info("gone", "This server was deleted (elsewhere in this session). Esc goes back.")
          ],
          else: [R.info("loading", "…", :text_faint)]

      {f, :env} ->
        KeyValueSecrets.rows(ctx, id, :env, f)

      {f, :headers} ->
        KeyValueSecrets.rows(ctx, id, :headers, f)

      {f, :output} ->
        output_rows(f)

      {f, _} ->
        server_rows(ctx, id, f)
    end
  end

  def record_rows(_ctx, _kind, _id), do: []

  def sub_rows(ctx, :import), do: McpImport.rows(ctx)

  def sub_rows(ctx, sub) do
    case R.page_record(ctx) do
      {@kind, id} ->
        record_rows(Map.put(ctx, :page, Map.put(R.current_page(ctx), :sub, sub)), @kind, id)

      _ ->
        []
    end
  end

  @doc "The staged connection fields of a server (D8)."
  def staged(ctx, id), do: ctx |> R.staged(@kind, id) |> Map.take(@staged_fields)

  defp effective(ctx, id, f, field) do
    case Map.fetch(staged(ctx, id), field) do
      {:ok, v} -> v
      :error -> R.field(f, field)
    end
  end

  defp server_rows(ctx, id, f) do
    staged = staged(ctx, id)
    transport = effective(ctx, id, f, "transport")
    task = R.task(ctx, "mcp.reconnect", %{"id" => id}) || R.task(ctx, "mcp.test", %{"id" => id})
    scope_id = effective(ctx, id, f, "project_id")

    head =
      R.row(
        id: "info:mcp:head:#{id}",
        kind: :info,
        label: R.field(f, "name"),
        value: [
          {"MCP server · #{R.field(f, "transport")} · #{scope_words(ctx, R.field(f, "project_id"))}",
           :text_faint}
        ],
        tag: status_segments(ctx, f),
        lines:
          if(staged != %{},
            do: [
              [
                {"! #{R.count(map_size(staged), "change")} not applied · restarts when you leave this page · ",
                 :warning},
                {"R", :key},
                {" now · ", :text_faint},
                {"r", :key},
                {" discards them", :text_faint}
              ]
            ],
            else: []
          ) ++ running_line(ctx, task),
        keys:
          if(staged != %{},
            do: [{"R", :restart, "restart now"}, {"r", :reset, "discard the changes"}],
            else: [{"R", :restart, "restart now"}]
          ),
        target: {:head, id}
      )

    connection =
      [
        head,
        R.heading("server", "server"),
        staged_row(ctx, id, f, "name", "Name", {:text, 64}),
        R.row(
          id: "fld:mcp_server:#{id}:enabled",
          kind: :field,
          key: "mcp_server.enabled",
          label: "Enabled",
          value: [{if(R.field(f, "enabled") == true, do: "on", else: "off"), :text_primary}],
          lines: [[{"off stops it at once", :text_faint}]],
          tag: [{"global", :text_muted}],
          keys: [{"Space", :toggle, "switch"}],
          target: {:enabled, id}
        ),
        R.row(
          id: "fld:mcp_server:#{id}:project_id",
          kind: :field,
          key: "mcp_server.project_id",
          label: "Scope",
          value: [{scope_words(ctx, scope_id), :text_primary}, {" ▾", :text_faint}],
          marks: if(Map.has_key?(staged, "project_id"), do: [:pending], else: []),
          lines:
            if(Map.has_key?(staged, "project_id"),
              do: [
                [{"not applied · was #{scope_words(ctx, R.field(f, "project_id"))}", :warning}]
              ],
              else: []
            ),
          keys: [{"Enter", :open_row, "choose"}, {"r", :reset, "revert"}],
          target: {:scope, id}
        ),
        staged_row(ctx, id, f, "transport", "Transport", {:enum, ~w(stdio http)})
      ] ++
        if(transport == "http",
          do: [
            staged_row(ctx, id, f, "url", "URL", {:text, 2_048}),
            map_row(ctx, id, f, :headers)
          ],
          else: [
            staged_row(ctx, id, f, "command", "Command", {:text, 1_024}),
            args_row(ctx, id, f),
            map_row(ctx, id, f, :env)
          ]
        )

    connection ++
      tools_rows(ctx, id, f) ++
      output_summary(f) ++
      [
        R.heading("actions", "actions"),
        test_row(ctx, id),
        R.heading("danger", "danger"),
        R.row(
          id: "act:mcp.delete",
          kind: :action,
          label: "▸ Delete this server…",
          value: [{"asks first", :text_faint}],
          tag: [{"D", :key}],
          keys: [{"D", :delete_record, "delete"}, {"Enter", :open_row, "delete…"}],
          target: {:delete, id}
        )
      ]
  end

  defp running_line(ctx, {_tid, t} = task) do
    if R.running?(task) do
      words =
        if R.field(t, "action") == "mcp.reconnect",
          do: "restarting with the new settings",
          else: "starting it to list its tools"

      [[{R.glyph(ctx, :running) <> " #{words} · #{R.elapsed_s(ctx, t)} s", :info}]]
    else
      []
    end
  end

  defp running_line(_ctx, _), do: []

  defp scope_words(_ctx, nil), do: "every project"

  defp scope_words(ctx, pid) do
    case R.project(ctx, pid) do
      nil -> "one project only"
      p -> "#{R.field(p, "name")} only"
    end
  end

  defp staged_row(ctx, id, f, field, label, type) do
    staged = staged(ctx, id)
    changed = Map.has_key?(staged, field)
    value = effective(ctx, id, f, field)
    row_id = "fld:mcp_server:#{id}:#{field}"

    editor =
      case type do
        {:text, max} ->
          {SwarmCodeCLI.UI.Settings.Editors.Text, %{value: to_string(value || ""), max: max}}

        {:enum, choices} ->
          {SwarmCodeCLI.UI.Settings.Editors.Enum,
           %{value: value, choices: Enum.map(choices, &%{value: &1, label: &1, hint: nil})}}
      end

    R.row(
      id: row_id,
      kind: :field,
      key: "mcp_server.#{field}",
      label: label,
      value: [{to_string(value || ""), :text_primary}],
      tag: [
        {if(changed, do: "not applied", else: "global"),
         if(changed, do: :warning, else: :text_muted)}
      ],
      marks: if(changed, do: [:pending], else: []),
      lines:
        error_lines(ctx, row_id) ++
          if(changed,
            do: [[{"restarts when you leave this page · R now · r reverts", :text_faint}]],
            else: []
          ),
      editor: editor,
      keys: [
        {"Enter", :open_row, "edit"},
        {"r", :reset, "revert"},
        {"R", :restart, "restart now"}
      ],
      target: {:staged, id, field}
    )
  end

  defp args_row(ctx, id, f) do
    args = effective(ctx, id, f, "args") || []
    changed = Map.has_key?(staged(ctx, id), "args")

    R.row(
      id: "fld:mcp_server:#{id}:args",
      kind: :field,
      key: "mcp_server.args",
      label: "Arguments",
      value: [{Enum.map_join(args, " ", &quote_arg/1), :text_primary}],
      tag: [
        {if(changed, do: "not applied", else: "one line, shell-quoted"),
         if(changed, do: :warning, else: :text_faint)}
      ],
      marks: if(changed, do: [:pending], else: []),
      lines: error_lines(ctx, "fld:mcp_server:#{id}:args"),
      editor:
        {SwarmCodeCLI.UI.Settings.Editors.Text,
         %{value: Enum.map_join(args, " ", &quote_arg/1), max: 16_384}},
      keys: [{"Enter", :open_row, "edit"}, {"r", :reset, "revert"}],
      target: {:staged, id, "args"}
    )
  end

  @doc "One argument quoted for a shell line (single quotes when needed)."
  def quote_arg(arg) do
    arg = to_string(arg)

    if arg != "" and Regex.match?(~r/^[A-Za-z0-9_@%+=:,.\/-]+$/, arg),
      do: arg,
      else: "'" <> String.replace(arg, "'", "'\\''") <> "'"
  end

  @doc "Splits a shell-quoted line into argv (single and double quotes, backslash escapes)."
  def split_args(line) do
    line
    |> String.trim()
    |> String.to_charlist()
    |> do_split([], [], nil, false)
  end

  defp do_split([], [], acc, nil, false), do: {:ok, Enum.reverse(acc)}

  defp do_split([], cur, acc, nil, true),
    do: {:ok, Enum.reverse([List.to_string(Enum.reverse(cur)) | acc])}

  defp do_split([], _cur, _acc, _q, _started), do: {:error, "a quote is not closed"}

  defp do_split([?\\, c | rest], cur, acc, q, _s) when q != ?',
    do: do_split(rest, [c | cur], acc, q, true)

  defp do_split([c | rest], cur, acc, nil, _s) when c in [?', ?"],
    do: do_split(rest, cur, acc, c, true)

  defp do_split([q | rest], cur, acc, q, _s) when q in [?', ?"],
    do: do_split(rest, cur, acc, nil, true)

  defp do_split([c | rest], [], acc, nil, false) when c in [?\s, ?\t],
    do: do_split(rest, [], acc, nil, false)

  defp do_split([c | rest], cur, acc, nil, true) when c in [?\s, ?\t],
    do: do_split(rest, [], [List.to_string(Enum.reverse(cur)) | acc], nil, false)

  defp do_split([c | rest], cur, acc, q, _s), do: do_split(rest, [c | cur], acc, q, true)

  defp map_row(ctx, id, f, map) do
    entries = KeyValueSecrets.entries(ctx, id, map, f)
    changed = Map.has_key?(staged(ctx, id), KeyValueSecrets.field(map))

    R.row(
      id: "fld:mcp_server:#{id}:#{KeyValueSecrets.field(map)}",
      kind: :field,
      key: "mcp_server.#{KeyValueSecrets.field(map)}",
      label: if(map == :env, do: "Environment", else: "Headers"),
      value: [{KeyValueSecrets.summary(entries, map), :text_primary}],
      tag: [
        {if(changed, do: "not applied", else: "Enter edit"),
         if(changed, do: :warning, else: :text_faint)}
      ],
      marks: if(changed, do: [:pending], else: []),
      lines: KeyValueSecrets.lines(ctx, entries),
      keys: [{"Enter", :open_row, "edit"}, {"r", :reset, "revert"}],
      target: {:open_sub, id, map}
    )
  end

  defp tools_rows(ctx, id, f) do
    tools = R.field(f, "tools") || []
    total = length(tools)
    off = Enum.count(tools, &(R.field(&1, "enabled") != true))

    head =
      R.heading("tools", "tools", [
        {"#{total} · #{off} off · Space one · A all on · N all off · / filter", :text_faint}
      ])

    if tools == [] do
      [
        head,
        R.info(
          "tools:none",
          "No tools yet · they are listed after the server connects",
          :text_faint
        )
      ]
    else
      rows =
        for t <- tools do
          name = R.field(t, "name")
          on = R.field(t, "enabled") == true

          R.row(
            id: "item:tools:#{name}",
            kind: :list_item,
            label: name,
            value: [
              {"#{if on, do: R.glyph(ctx, :ticked), else: R.glyph(ctx, :unticked)} ",
               :text_primary},
              {to_string(R.field(t, "description") || ""), :text_faint}
            ],
            tag: if(R.field(t, "read_only") == true, do: [{"read-only", :text_faint}], else: []),
            keys: [
              {"Space", :toggle, if(on, do: "turn off", else: "turn on")},
              {"A", :all_on, "all on"},
              {"N", :all_off, "all off"}
            ],
            target: {:tool, id, name, on}
          )
        end

      [head | rows]
    end
  end

  defp output_summary(f) do
    output = R.field(f, "output") || []

    if output == [] do
      []
    else
      last = Enum.take(output, -2)

      [
        R.heading("server output", "server output", [
          {"last #{R.count(length(last), "line")} · ", :text_faint},
          {"o", :key},
          {" all of it", :text_faint}
        ])
      ] ++
        Enum.with_index(last, fn line, i ->
          R.row(
            id: "info:output:#{i}",
            kind: :info,
            label: "",
            value: [{to_string(line), :text_muted}],
            keys: [{"o", :open_related, "all of it"}],
            target: {:output}
          )
        end)
    end
  end

  defp output_rows(f) do
    output = R.field(f, "output") || []

    [
      R.row(
        id: "info:output:head",
        kind: :info,
        label: "#{R.field(f, "name")} › output",
        value: [{"the last #{R.count(length(output), "line")} · redacted", :text_faint}],
        state: :readonly
      )
    ] ++
      if(output == [],
        do: [R.info("output:none", "It has said nothing yet.", :text_faint)],
        else:
          Enum.with_index(output, fn line, i ->
            R.row(
              id: "info:output:line:#{i}",
              kind: :info,
              label: "",
              value: [{to_string(line), :text_muted}],
              state: :readonly
            )
          end)
      )
  end

  defp test_row(ctx, id) do
    task = R.task(ctx, "mcp.test", %{"id" => id})

    {value, tag} =
      if task do
        R.task_words(ctx, task, "starting #{server_name(ctx, id)} to list its tools", fn s ->
          "connected · #{R.count(R.field(s, "count") || 0, "tool")}"
        end)
      else
        {[{"starts it with the saved settings, lists its tools, saves nothing", :text_faint}],
         [{"t", :key}]}
      end

    R.row(
      id: "act:mcp.test",
      kind: :action,
      label: "▸ Test",
      value: value,
      tag: tag,
      state: if(R.running?(task), do: :running, else: :normal),
      keys:
        [{"Enter", :open_row, "test"}, {"t", :test, "test"}] ++
          if(R.running?(task), do: [{"c", :cancel_task, "stop"}], else: []),
      target: {:test, id}
    )
  end

  defp error_lines(ctx, row_id) do
    case R.row_error(ctx, row_id) do
      nil -> []
      m -> [[{R.glyph(ctx, :error) <> " " <> m, :error}]]
    end
  end

  # ----------------------------------------------------------------- draft

  defp draft_rows(ctx) do
    d = R.draft(ctx, @kind)
    f = R.draft_fields(d)
    errors = R.draft_errors(d)
    transport = R.field(f, "transport") || "stdio"

    text_row = fn field, label ->
      R.row(
        id: "fld:mcp_server:draft:#{field}",
        kind: :field,
        key: "mcp_server.#{field}",
        label: label,
        value: [{to_string(R.field(f, field) || ""), :text_primary}],
        lines:
          if(m = Map.get(errors, field),
            do: [[{R.glyph(ctx, :error) <> " " <> m, :error}]],
            else: []
          ),
        editor:
          {SwarmCodeCLI.UI.Settings.Editors.Text,
           %{value: to_string(R.field(f, field) || ""), max: 2_048}},
        keys: [{"Enter", :open_row, "edit"}],
        target: {:draft_field, field}
      )
    end

    [
      R.row(
        id: "info:mcp:draft",
        kind: :info,
        label: "New MCP server",
        value: [{"unsaved · Ctrl-S creates it · Esc discards", :warning}],
        state: :readonly
      ),
      text_row.("name", "Name"),
      R.row(
        id: "fld:mcp_server:draft:transport",
        kind: :field,
        key: "mcp_server.transport",
        label: "Transport",
        value: [{transport, :text_primary}],
        editor:
          {SwarmCodeCLI.UI.Settings.Editors.Enum,
           %{
             value: transport,
             choices: [
               %{value: "stdio", label: "stdio", hint: nil},
               %{value: "http", label: "http", hint: nil}
             ]
           }},
        target: {:draft_field, "transport"}
      )
    ] ++
      if(transport == "http",
        do: [text_row.("url", "URL")],
        else: [text_row.("command", "Command"), text_row.("args", "Arguments")]
      ) ++
      [
        R.row(
          id: "info:mcp:draft:env",
          kind: :info,
          label: "",
          value: [
            {"environment and headers are added on the server's page after it is created",
             :text_faint}
          ],
          state: :readonly
        ),
        R.row(
          id: "act:mcp.create",
          kind: :action,
          label: "▸ Create it",
          value: [{"Ctrl-S · it starts at once", :text_faint}],
          keys: [{"Enter", :open_row, "create"}, {"Ctrl-S", :save, "create"}],
          target: {:create}
        ),
        draft_test_row(ctx)
      ]
  end

  # QA #2 P1-6: the row shows its test as the saved server's Test row does
  # (it kept its static words, so `t` and Enter looked like nothing), with the
  # tools it listed, and Enter tests too.
  defp draft_test_row(ctx) do
    task = R.task(ctx, "mcp.test", %{"draft" => true})

    {value, tag} =
      if task do
        R.task_words(ctx, task, "starting it to list its tools", &draft_tools_words/1)
      else
        {[{"starts it once, lists its tools, saves nothing", :text_faint}], [{"t", :key}]}
      end

    R.row(
      id: "act:mcp.test_draft",
      kind: :action,
      label: "▸ Test it first",
      value: value,
      tag: tag,
      state: if(R.running?(task), do: :running, else: :normal),
      keys:
        [{"Enter", :open_row, "test"}, {"t", :test, "test"}] ++
          if(R.running?(task), do: [{"c", :cancel_task, "stop"}], else: []),
      target: {:test_draft}
    )
  end

  defp draft_tools_words(summary) do
    count = R.field(summary, "count") || 0
    names = R.field(summary, "tools") || []
    shown = names |> Enum.take(5) |> Enum.join(", ")
    more = if count > 5, do: " +#{count - 5}", else: ""

    "connected · #{R.count(count, "tool")}" <> if(names == [], do: "", else: ": #{shown}#{more}")
  end

  defp draft_attrs(ctx) do
    f = R.draft_fields(R.draft(ctx, @kind))
    transport = R.field(f, "transport") || "stdio"

    args =
      case split_args(to_string(R.field(f, "args") || "")) do
        {:ok, list} -> list
        _ -> []
      end

    %{
      "name" => String.trim(to_string(R.field(f, "name") || "")),
      "transport" => transport,
      "command" => if(transport == "stdio", do: blank(R.field(f, "command"), nil)),
      "args" => if(transport == "stdio", do: args, else: []),
      "url" => if(transport == "http", do: blank(R.field(f, "url"), nil)),
      "env" => [],
      "headers" => [],
      "enabled" => true,
      "project_id" => R.field(f, "project_id")
    }
  end

  # ------------------------------------------------------------------ act

  def act(ctx, row, verb) do
    case {R.page_record(ctx), R.page_sub(ctx)} do
      {_, :import} ->
        McpImport.act(ctx, row, verb)

      {{@kind, id}, sub} when sub in [:env, :headers] and id != @draft ->
        case KeyValueSecrets.act(ctx, row, verb, server(ctx, id) || %{}) do
          :default -> server_act(ctx, id, row, verb)
          ops -> ops
        end

      {{@kind, @draft}, _} ->
        draft_act(ctx, Map.get(row, :target), verb)

      {{@kind, id}, _} ->
        server_act(ctx, id, row, verb)

      _ ->
        list_act(ctx, Map.get(row, :target), verb)
    end
  end

  defp list_act(ctx, target, verb) do
    case {target, verb} do
      {{:server, id}, :open_row} -> [{:open, R.new_page(:mcp, {@kind, id})}]
      {{:server, id}, :toggle} -> toggle_ops(ctx, id, list_fields(ctx, id))
      {{:server, id}, :restart} -> [{:task, "mcp.reconnect", %{"id" => id}, %{}}]
      {{:server, id}, :test} -> [{:task, "mcp.test", %{"id" => id}, %{}}]
      {{:project_picker}, :open_row} -> [project_picker(ctx)]
      {{:draft}, :open_row} -> [{:open, R.new_page(:mcp, {@kind, @draft})}]
      {{:add}, v} when v in [:open_row, :add] -> add_ops(ctx)
      {_, :add} -> add_ops(ctx)
      {{:import, path}, :open_row} -> import_ops(ctx, path)
      _ -> :default
    end
  end

  defp list_fields(ctx, id) do
    case Enum.find(R.items(ctx, "mcp_servers"), &(R.record_id(&1) == id)) do
      nil -> server(ctx, id) || %{}
      rec -> R.fields(rec)
    end
  end

  defp project_picker(ctx) do
    options =
      for p <- R.projects(ctx), R.field(p, "scratch") != true do
        %{
          value: R.record_id(p) || R.field(p, "id"),
          label: R.field(p, "name"),
          hint: R.field(p, "root")
        }
      end

    {:picker,
     R.picker(
       id: "mcp.project",
       title: "Servers of",
       options: options,
       current: R.project_id(ctx),
       on_pick: {:project, :page}
     )}
  end

  defp add_ops(ctx) do
    case R.draft(ctx, @kind) do
      nil ->
        [
          {:draft_put, @kind,
           %{
             "name" => "",
             "transport" => "stdio",
             "command" => "",
             "args" => "",
             "url" => "",
             "project_id" => nil
           }},
          {:open, R.new_page(:mcp, {@kind, @draft})}
        ]

      _ ->
        [{:open, R.new_page(:mcp, {@kind, @draft})}]
    end
  end

  defp import_ops(ctx, path) do
    attrs = %{"path" => path, "project_id" => R.project_id(ctx)}
    [{:task, "mcp.import.read", nil, attrs}, {:open, R.new_page(:mcp, nil, :import)}]
  end

  defp server_act(ctx, id, row, verb) do
    f = server(ctx, id) || %{}

    case {Map.get(row, :target), verb} do
      {{:enabled, _}, v} when v in [:toggle, :open_row] ->
        toggle_ops(ctx, id, f)

      {{:staged, _, field}, :reset} ->
        revert_ops(ctx, id, [field])

      {{:open_sub, _, map}, :reset} ->
        revert_ops(ctx, id, [KeyValueSecrets.field(map)])

      {{:scope, _}, :reset} ->
        revert_ops(ctx, id, ["project_id"])

      {{:head, _}, :reset} ->
        revert_ops(ctx, id, :all)

      {_, :restart} ->
        restart_ops(ctx, id, f)

      {_, :leave} ->
        leave_ops(ctx, id)

      {{:scope, _}, :open_row} ->
        [scope_picker(ctx, id, f)]

      {{:open_sub, _, map}, :open_row} ->
        [{:open, R.new_page(:mcp, {@kind, id}, map)}]

      {{:tool, _, name, on}, :toggle} ->
        tools_ops(f, id, %{name => not on})

      {_, :all_on} ->
        tools_ops(f, id, Map.new(R.field(f, "tools") || [], &{R.field(&1, "name"), true}))

      {_, :all_off} ->
        tools_ops(f, id, Map.new(R.field(f, "tools") || [], &{R.field(&1, "name"), false}))

      {_, :test} ->
        [{:task, "mcp.test", %{"id" => id}, %{}}]

      {{:test, _}, :open_row} ->
        [{:task, "mcp.test", %{"id" => id}, %{}}]

      {_, :open_related} ->
        [{:open, R.new_page(:mcp, {@kind, id}, :output)}]

      {{:output}, :open_row} ->
        [{:open, R.new_page(:mcp, {@kind, id}, :output)}]

      {{:delete, _}, v} when v in [:delete, :delete_record, :open_row] ->
        delete_ops(ctx, id, f)

      # QA F-7: `D` (delete the record this page shows) sends :delete_record.
      {_, v} when v in [:delete, :delete_record] ->
        if(R.page_sub(ctx) == nil, do: delete_ops(ctx, id, f), else: :default)

      _ ->
        :default
    end
  end

  defp toggle_ops(_ctx, id, f) do
    on = R.field(f, "enabled") == true

    [
      {:command, "mcp.toggle", %{"id" => id}, %{"enabled" => not on},
       %{
         expected: %{"fields" => %{"enabled" => on}},
         write_key: {:record, @kind, id, "enabled"},
         undo:
           {:command, "mcp.toggle", %{"id" => id}, %{"enabled" => on},
            %{expected: %{"fields" => %{"enabled" => not on}}}},
         toast:
           if(on, do: "#{R.field(f, "name")} off · stopped", else: "#{R.field(f, "name")} on")
       }}
    ]
  end

  defp revert_ops(ctx, id, fields) do
    staged = staged(ctx, id)

    cond do
      staged == %{} ->
        [{:toast, "Nothing waits to be applied here", :info}]

      fields == :all ->
        [
          {:unstage, {@kind, id}, :all},
          {:toast, "Discarded #{R.count(map_size(staged), "change")}", :info}
        ]

      Enum.any?(fields, &Map.has_key?(staged, &1)) ->
        [{:unstage, {@kind, id}, fields}]

      true ->
        [{:toast, "That field has no change to revert", :info}]
    end
  end

  @doc "`R restart now`: the staged fields in one `mcp.update`, else a reconnect."
  def restart_ops(ctx, id, f) do
    case update_ops(ctx, id, f) do
      [] ->
        if R.field(f, "enabled") == true,
          do: [{:task, "mcp.reconnect", %{"id" => id}, %{}}],
          else: [{:toast, "turn it on first", :warning}]

      ops ->
        ops
    end
  end

  @doc """
  Leaving the server's page (D8): valid staged fields are applied in one `mcp.update`
  without asking; invalid ones are left for the pending-on-leave question.
  """
  def leave_ops(ctx, id) do
    case server(ctx, id) do
      nil -> []
      f -> if invalid_staged(ctx, id) == [], do: update_ops(ctx, id, f), else: []
    end
  end

  @doc "What is not saved on a server's page, for the pending-on-leave question (§3.7.10)."
  def pending(ctx, id) do
    case invalid_staged(ctx, id) do
      [] -> []
      fields -> ["#{Enum.join(fields, ", ")} of #{server_name(ctx, id)} (not valid)"]
    end
  end

  defp invalid_staged(ctx, id) do
    staged = staged(ctx, id)
    transport = Map.get(staged, "transport") || R.field(server(ctx, id) || %{}, "transport")

    [
      (Map.has_key?(staged, "name") and String.trim(to_string(staged["name"])) == "") && "name",
      (transport == "stdio" and Map.has_key?(staged, "command") and
         blank(staged["command"], nil) == nil) && "command",
      (transport == "http" and Map.has_key?(staged, "url") and not url?(staged["url"])) && "url"
    ]
    |> Enum.filter(& &1)
  end

  defp url?(v),
    do: is_binary(v) and (String.starts_with?(v, "http://") or String.starts_with?(v, "https://"))

  defp update_ops(ctx, id, f) do
    staged = staged(ctx, id)

    if staged == %{} do
      []
    else
      expected = Map.new(Map.keys(staged), fn k -> {k, R.field(f, k)} end)
      old = Map.new(Map.keys(staged), fn k -> {k, old_attr(f, k)} end)

      [
        {:command, "mcp.update", %{"id" => id}, staged,
         %{
           expected: %{"fields" => expected},
           write_key: {:record, @kind, id, :connection},
           # QA #2: the undo expects the fields this update leaves, read from
           # the answer's record (the env is masked there).
           undo:
             {:command, "mcp.update", %{"id" => id}, old,
              %{expected_from: {:fields, Map.keys(staged)}}},
           toast:
             "Applied #{R.count(map_size(staged), "change")} · restarts #{R.field(f, "name")}",
           after: {:unstage, {@kind, id}, :all}
         }}
      ]
    end
  end

  defp old_attr(f, k) when k in ["env", "headers"] do
    for e <- R.field(f, k) || [] do
      if R.field(e, "secret") == true,
        do: %{"name" => R.field(e, "name"), "keep" => true},
        else: %{"name" => R.field(e, "name"), "value" => R.field(e, "value")}
    end
  end

  defp old_attr(f, k), do: R.field(f, k)

  defp scope_picker(ctx, id, f) do
    options =
      [%{value: nil, label: "every project", hint: "every project's agents get its tools"}] ++
        for p <- R.projects(ctx), R.field(p, "scratch") != true do
          %{
            value: R.record_id(p) || R.field(p, "id"),
            label: "#{R.field(p, "name")} only",
            hint: R.field(p, "root")
          }
        end

    {:picker,
     R.picker(
       id: "mcp.scope",
       title: "Scope of #{R.field(f, "name")}",
       options: options,
       current: effective(ctx, id, f, "project_id"),
       on_pick: {:section, :mcp, {:scope, id}}
     )}
  end

  defp tools_ops(f, id, changes) do
    tools = R.field(f, "tools") || []
    current = Map.new(tools, &{R.field(&1, "name"), R.field(&1, "enabled") == true})
    changes = Map.reject(changes, fn {name, on} -> Map.get(current, name) == on end)

    if changes == %{} do
      []
    else
      disabled = R.field(f, "disabled_tools") || for({n, false} <- current, do: n)
      inverse = Map.new(changes, fn {n, on} -> {n, not on} end)
      on_after = Enum.count(Map.merge(current, changes), &elem(&1, 1))
      # QA #2 P1-5: the undo expects the list this write leaves (the service
      # compares it as a set and refused an undo without it).
      after_ = disabled_after(disabled, changes)

      [
        {:command, "mcp.set_tools", %{"id" => id}, %{"tools" => changes},
         %{
           expected: %{"disabled_tools" => disabled},
           write_key: {:record, @kind, id, "disabled_tools"},
           undo:
             {:command, "mcp.set_tools", %{"id" => id}, %{"tools" => inverse},
              %{expected: %{"disabled_tools" => after_}}},
           toast: "#{R.field(f, "name")}: #{on_after} of #{length(tools)} tools on"
         }}
      ]
    end
  end

  defp disabled_after(disabled, changes) do
    off = for {name, false} <- changes, do: name
    on = for {name, true} <- changes, do: name
    Enum.uniq((disabled -- on) ++ off)
  end

  defp delete_ops(_ctx, id, f) do
    tools = R.field(f, "tools_total") || length(R.field(f, "tools") || [])
    name = R.field(f, "name")

    [
      {:confirm,
       R.confirm(
         id: "mcp.delete",
         title: "Delete #{name}?",
         lines: [
           "Agents lose its #{R.count(tools, "tool")}; conversations that used them keep their history"
         ],
         safe: "Keep #{name}",
         danger: "Delete #{name}",
         letter: "D",
         undoable?: false,
         opener: "act:mcp.delete"
       ),
       then: [
         {:command, "mcp.delete", %{"id" => id}, %{},
          %{
            expected: %{"updated_at" => R.field(f, "updated_at")},
            write_key: {:record, @kind, id, :delete},
            undo: false,
            toast: "Deleted #{name}",
            after: [{:unstage, {@kind, id}, :all}, :back]
          }}
       ]}
    ]
  end

  defp draft_act(ctx, target, verb) do
    case {target, verb} do
      {_, :save} -> create_ops(ctx)
      {{:create}, :open_row} -> create_ops(ctx)
      {_, :test} -> [{:task, "mcp.test", %{"draft" => true}, draft_attrs(ctx)}]
      {{:test_draft}, :open_row} -> [{:task, "mcp.test", %{"draft" => true}, draft_attrs(ctx)}]
      _ -> :default
    end
  end

  defp create_ops(ctx) do
    attrs = draft_attrs(ctx)

    [
      {:command, "mcp.create", nil, attrs,
       %{
         write_key: {:record, @kind, @draft, :create},
         undo: false,
         toast: "Added #{attrs["name"]}",
         errors_to: {:draft, @kind},
         # QA F-1: the created server's page replaces the draft's, and the draft goes.
         after: {:discard_draft, @kind, then: [:back, {:open_record, :mcp, @kind, then: []}]}
       }}
    ]
  end

  # --------------------------------------------------------------- commit

  def commit(ctx, row, value) do
    case {R.page_record(ctx), R.page_sub(ctx), Map.get(row, :target)} do
      {_, :import, _} ->
        :default

      {{@kind, id}, sub, _} when sub in [:env, :headers] and id != @draft ->
        KeyValueSecrets.commit(ctx, row, value, server(ctx, id) || %{})

      {_, _, {:draft_field, field}} ->
        [{:draft_put, @kind, %{field => value}}]

      {_, _, {:staged, id, field}} ->
        stage_ops(ctx, id, row, field, value)

      _ ->
        :default
    end
  end

  @doc "A picked value from the section's pickers (scope, import variable, import scope)."
  def picked(ctx, {:scope, id}, value), do: stage_value(ctx, id, "project_id", value)
  def picked(ctx, what, value), do: McpImport.picked(ctx, what, value)

  defp stage_ops(ctx, id, row, "args", value) do
    case split_args(to_string(value || "")) do
      {:ok, argv} -> stage_value(ctx, id, "args", argv)
      {:error, message} -> [{:row_error, row.id, message}]
    end
  end

  defp stage_ops(ctx, id, row, field, value) do
    value = if is_binary(value), do: String.trim(value), else: value

    cond do
      field == "name" and value == "" ->
        [{:row_error, row.id, "can't be blank"}]

      field == "name" and String.length(value) > 64 ->
        [{:row_error, row.id, "should be at most 64 character(s)"}]

      field == "command" and value == "" ->
        [{:row_error, row.id, "is required for stdio servers"}]

      field == "url" and value == "" ->
        [{:row_error, row.id, "is required for http servers"}]

      field == "url" and not url?(value) ->
        [{:row_error, row.id, "must start with http:// or https://"}]

      true ->
        stage_value(ctx, id, field, value)
    end
  end

  defp stage_value(ctx, id, field, value) do
    f = server(ctx, id) || %{}

    if value == R.field(f, field),
      do: [{:unstage, {@kind, id}, [field]}],
      else: [{:stage, {@kind, id}, %{field => value}}]
  end

  defp blank(nil, word), do: word
  defp blank(v, word), do: if(String.trim(to_string(v)) == "", do: word, else: v)
end
