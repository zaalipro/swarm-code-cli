defmodule SwarmCodeCLI.UI.Settings.McpImport do
  @moduledoc """
  The MCP import preview (spec §2.7, §3.5.4, the §4.15 sketch): the servers a `.mcp.json`
  lists, one row each (`name · transport · command or url · N env · N headers`), ticked
  unless the name exists (`n` imports it under a new name, `x` skips it), SSE entries
  unticked for good, masked secrets, and one row per `${NAME}` variable with its choice:
  take it from this shell now (only when it is set there), paste a value (a paste target
  whose bytes go only into the apply command's `secrets`), or keep it literally. A scope
  row picks `every project` or the page project; Enter on `▸ Import N servers` sends
  `mcp.import.apply` with the ticked names, renames, choices and the pasted values.

  The choices live in the `mcp_import` draft (`fields`: `import_id`, `ticks`, `rename`,
  `choices`, `project_id`; `secrets`: the pasted values by slot). Pure.
  """

  alias SwarmCodeCLI.UI.Settings.IntegrationRows, as: R

  @draft "mcp_import"

  @doc "The last finished `mcp.import.read`: `{task_id, summary, drafts}` or nil."
  def read(ctx) do
    case R.task(ctx, "mcp.import.read") do
      {task_id, task} ->
        if R.field(task, "state") == "done",
          do:
            {task_id, R.task_summary(ctx, task_id) || R.field(task, "summary") || %{},
             R.task_rows(ctx, task_id)},
          else: nil

      nil ->
        nil
    end
  end

  @doc "The draft of this import (nil until the preview is touched)."
  def draft(ctx, import_id) do
    case R.draft(ctx, @draft) do
      nil -> nil
      d -> if R.field(R.draft_fields(d), "import_id") == import_id, do: d, else: nil
    end
  end

  defp state(ctx, import_id, drafts) do
    f = R.draft_fields(draft(ctx, import_id))

    %{
      ticks: R.field(f, "ticks") || Map.new(drafts, &{R.field(&1, "name"), default_tick(&1)}),
      rename: R.field(f, "rename") || %{},
      choices: R.field(f, "choices") || %{},
      project_id: R.field(f, "project_id")
    }
  end

  defp default_tick(d), do: R.field(d, "unsupported") != true and R.field(d, "conflict") != true

  @doc "The effective choice of a variable: the draft's, else shell when set there, else literal."
  def choice(st, draft, var) do
    key = var_key(var)

    Map.get(Map.get(st.choices, R.field(draft, "name"), %{}), key) ||
      if(R.field(var, "in_shell") == true, do: "shell", else: "literal")
  end

  defp var_key(var),
    do: "#{if R.field(var, "map") == "env", do: "env", else: "header"}.#{R.field(var, "name")}"

  # ----------------------------------------------------------------- rows

  @doc "The preview's rows."
  def rows(ctx) do
    task = R.task(ctx, "mcp.import.read")

    case {task, read(ctx)} do
      {nil, _} ->
        [R.info("import:none", "Nothing read yet · Enter on ▸ Import from .mcp.json reads it")]

      {{_id, t}, nil} ->
        {value, tag} =
          R.task_words(ctx, {nil, t}, "reading .mcp.json", fn s ->
            "#{R.count(R.field(s, "count") || 0, "server")} found"
          end)

        [
          R.row(
            id: "info:import:reading",
            kind: :info,
            label: "Import MCP servers",
            value: value,
            tag: tag,
            state: :readonly
          )
        ]

      {_, {import_id, summary, drafts}} ->
        preview_rows(ctx, import_id, summary, drafts)
    end
  end

  defp preview_rows(ctx, import_id, summary, drafts) do
    st = state(ctx, import_id, drafts)

    ticked =
      Enum.count(
        drafts,
        &(Map.get(st.ticks, R.field(&1, "name")) == true and R.field(&1, "unsupported") != true)
      )

    path = R.field(summary, "path") || ".mcp.json"

    head =
      R.row(
        id: "info:import:head",
        kind: :info,
        label: "Import MCP servers",
        value: [{"#{path} · #{R.count(length(drafts), "server")}", :text_faint}],
        tag: [{"Esc", :key}, {" back", :text_faint}],
        state: :readonly
      )

    server_rows = Enum.flat_map(drafts, &draft_rows(ctx, import_id, st, &1))

    scope_name =
      if st.project_id, do: "#{project_name(ctx, st.project_id)} only", else: "every project"

    [
      head
      | server_rows ++
          [
            R.row(
              id: "fld:import:scope",
              kind: :field,
              label: "Scope",
              value: [{scope_name, :text_primary}, {" ▾", :text_faint}],
              keys: [{"Enter", :open_row, "choose"}],
              target: {:import_scope, import_id}
            ),
            R.row(
              id: "act:import.apply",
              kind: :action,
              label: "▸ Import #{R.count(ticked, "server")}",
              value: [{"pasted values travel once, with this command", :text_faint}],
              state: if(ticked > 0, do: :normal, else: :disabled),
              keys: [{"Enter", :open_row, "import #{R.count(ticked, "server")}"}],
              target: {:import_apply, import_id}
            )
          ]
    ]
  end

  defp project_name(ctx, id) do
    case R.project(ctx, id) do
      nil -> "this project"
      p -> R.field(p, "name") || "this project"
    end
  end

  defp draft_rows(ctx, import_id, st, d) do
    name = R.field(d, "name")
    unsupported = R.field(d, "unsupported") == true
    ticked = Map.get(st.ticks, name) == true and not unsupported
    tick = if ticked, do: R.glyph(ctx, :ticked), else: R.glyph(ctx, :unticked)
    rename = Map.get(st.rename, name)
    env = R.field(d, "env") || []
    headers = R.field(d, "headers") || []

    where =
      R.field(d, "command") && Enum.join([R.field(d, "command") | R.field(d, "args") || []], " ")

    where = where || R.field(d, "url") || ""

    counts =
      [
        env != [] && R.count(length(env), "env") |> String.replace("envs", "env"),
        headers != [] &&
          R.count(length(headers), "header") <>
            if(Enum.any?(headers, &(R.field(&1, "secret") == true)), do: " · masked", else: "")
      ]
      |> Enum.filter(& &1)
      |> Enum.join(" · ")

    lines =
      cond do
        unsupported ->
          [[{"SSE servers are not supported; use the server's streamable http URL", :warning}]]

        R.field(d, "conflict") == true and rename == nil ->
          [
            [
              {"a server named #{name} exists · ", :warning},
              {"n", :key},
              {" import as #{name}-2 · ", :text_faint},
              {"x", :key},
              {" skip", :text_faint}
            ]
          ]

        rename != nil ->
          [[{"imported as #{rename}", :text_faint}]]

        true ->
          []
      end

    server =
      R.row(
        id: "item:import:#{name}",
        kind: :list_item,
        label: name,
        value:
          [
            {"#{tick} ", :text_primary},
            {String.pad_trailing(to_string(R.field(d, "transport")), 8), :text_muted},
            {where, :text_primary}
          ] ++ if(counts != "", do: [{"   " <> counts, :text_faint}], else: []),
        lines: lines,
        state: if(unsupported, do: :disabled, else: :normal),
        keys:
          [{"Space", :toggle, "tick"}] ++
            if(R.field(d, "conflict") == true,
              do: [{"n", :new, "import as #{name}-2"}, {"x", :delete, "skip"}],
              else: []
            ),
        target: {:import_server, import_id, name}
      )

    masked =
      for e <- env ++ headers, R.field(e, "secret") == true do
        R.row(
          id: "info:import:#{name}:#{R.field(e, "name")}",
          kind: :info,
          label: "",
          indent: 4,
          value: [
            {"#{R.field(e, "name")} = ", :text_muted},
            {if(R.tier(ctx) == :ascii, do: "********", else: "●●●●●●●●"), :text_muted},
            {" · kept as the file has it", :text_faint}
          ],
          state: :readonly
        )
      end

    vars =
      for var <- R.field(d, "variables") || [] do
        choice = choice(st, d, var)
        ref = R.field(var, "ref")
        in_shell = R.field(var, "in_shell") == true
        pasted = R.draft_secret?(draft(ctx, import_id), slot(name, var))

        R.row(
          id: "item:importvar:#{name}:#{var_key(var)}",
          kind: :list_item,
          label: "",
          indent: 4,
          value: [
            {"#{R.field(var, "name")} = ${#{ref}}", :text_primary},
            {" · SwarmCode does not expand variables", :text_faint}
          ],
          lines: [choice_line(choice, in_shell, pasted)],
          keys: [{"Enter", :open_row, "choose"}],
          target: {:import_var, import_id, name, var}
        )
      end

    [server] ++ masked ++ vars
  end

  defp choice_line(choice, in_shell, pasted) do
    mark = fn c, text ->
      {if(c == choice, do: "[#{text}]", else: " #{text} "),
       if(c == choice, do: :text_primary, else: :text_faint)}
    end

    [
      mark.(
        "shell",
        "v take it from this shell now (#{if in_shell, do: "set", else: "not set"})"
      ),
      {"  ", :text_faint},
      mark.("paste", "p paste a value" <> if(pasted, do: " · pasted", else: "")),
      {"  ", :text_faint},
      mark.("literal", "k keep it literally")
    ]
  end

  @doc "The paste slot of a variable (`import:<server>:env:<NAME>`)."
  def slot(server, var),
    do:
      "import:#{server}:#{if R.field(var, "map") == "env", do: "env", else: "header"}:#{R.field(var, "name")}"

  # ------------------------------------------------------------------ act

  @doc "The keys of the preview."
  def act(ctx, row, verb) do
    case read(ctx) do
      nil -> :default
      {import_id, _summary, drafts} -> act(ctx, import_id, drafts, Map.get(row, :target), verb)
    end
  end

  defp act(ctx, import_id, drafts, {:import_server, _, name}, :toggle) do
    d = Enum.find(drafts, &(R.field(&1, "name") == name))

    if R.field(d, "unsupported") == true do
      [{:toast, "SSE servers are not supported; use the server's streamable http URL", :warning}]
    else
      st = state(ctx, import_id, drafts)
      put(import_id, st, %{ticks: Map.put(st.ticks, name, Map.get(st.ticks, name) != true)})
    end
  end

  defp act(ctx, import_id, drafts, {:import_server, _, name}, :new) do
    st = state(ctx, import_id, drafts)

    put(import_id, st, %{
      rename: Map.put(st.rename, name, "#{name}-2"),
      ticks: Map.put(st.ticks, name, true)
    })
  end

  defp act(ctx, import_id, drafts, {:import_server, _, name}, :delete) do
    st = state(ctx, import_id, drafts)

    put(import_id, st, %{
      rename: Map.delete(st.rename, name),
      ticks: Map.put(st.ticks, name, false)
    })
  end

  defp act(ctx, import_id, drafts, {:import_var, _, server, var}, verb)
       when verb in [:var_shell, :var_paste, :var_literal] do
    choose(
      ctx,
      import_id,
      drafts,
      server,
      var,
      %{var_shell: "shell", var_paste: "paste", var_literal: "literal"}[verb]
    )
  end

  defp act(_ctx, _import_id, _drafts, {:import_var, _, server, var}, :open_row) do
    [
      {:picker,
       R.picker(
         id: "mcp_import.variable",
         title: "#{R.field(var, "name")} of #{server}",
         options: [
           %{
             value: "shell",
             label: "take it from this shell now",
             hint:
               if(R.field(var, "in_shell") == true,
                 do: "#{R.field(var, "ref")} is set",
                 else: "#{R.field(var, "ref")} is not set here"
               )
           },
           %{value: "paste", label: "paste a value", hint: "held until the import, never shown"},
           %{
             value: "literal",
             label: "keep it literally",
             hint: "the server gets ${#{R.field(var, "ref")}} as text"
           }
         ],
         on_pick: {:section, :mcp, {:import_var, server, var_key(var)}}
       )}
    ]
  end

  defp act(ctx, _import_id, _drafts, {:import_scope, _}, :open_row) do
    options =
      [%{value: nil, label: "every project", hint: nil}] ++
        for p <- R.projects(ctx), R.field(p, "scratch") != true do
          %{
            value: R.record_id(p) || R.field(p, "id"),
            label: "#{R.field(p, "name")} only",
            hint: R.field(p, "root")
          }
        end

    [
      {:picker,
       R.picker(
         id: "mcp_import.scope",
         title: "Import into",
         options: options,
         on_pick: {:section, :mcp, :import_scope}
       )}
    ]
  end

  defp act(ctx, import_id, drafts, {:import_apply, _}, :open_row),
    do: apply_ops(ctx, import_id, drafts)

  defp act(_ctx, _import_id, _drafts, _target, _verb), do: :default

  @doc "A choice for one variable (`shell` needs the variable set in this shell)."
  def choose(ctx, import_id, drafts, server, var, choice) do
    st = state(ctx, import_id, drafts)
    key = var_key(var)

    cond do
      choice == "shell" and R.field(var, "in_shell") != true ->
        [{:toast, "#{R.field(var, "ref")} is not set in this shell", :warning}]

      choice == "paste" ->
        put(import_id, st, %{
          choices: Map.update(st.choices, server, %{key => "paste"}, &Map.put(&1, key, "paste"))
        }) ++
          [
            {:paste,
             %{
               row_id: "item:importvar:#{server}:#{key}",
               action: nil,
               draft: @draft,
               target: nil,
               attributes: %{},
               slot: slot(server, var),
               label: "#{R.field(var, "name")} of #{server}",
               set?: false,
               kind: "mcp_server"
             }}
          ]

      true ->
        put(import_id, st, %{
          choices: Map.update(st.choices, server, %{key => choice}, &Map.put(&1, key, choice))
        })
    end
  end

  @doc "A picked value (the variable and scope pickers)."
  def picked(ctx, {:import_var, server, key}, value) do
    case read(ctx) do
      nil ->
        []

      {import_id, _s, drafts} ->
        d = Enum.find(drafts, &(R.field(&1, "name") == server))
        var = Enum.find(R.field(d, "variables") || [], &(var_key(&1) == key))
        if var, do: choose(ctx, import_id, drafts, server, var, value), else: []
    end
  end

  def picked(ctx, :import_scope, value) do
    case read(ctx) do
      nil ->
        []

      {import_id, _s, drafts} ->
        put(import_id, state(ctx, import_id, drafts), %{project_id: value})
    end
  end

  def picked(_ctx, _what, _value), do: []

  defp put(import_id, st, changes) do
    st = Map.merge(st, changes)

    [
      {:draft_put, @draft,
       %{
         "import_id" => import_id,
         "ticks" => st.ticks,
         "rename" => st.rename,
         "choices" => st.choices,
         "project_id" => st.project_id
       }}
    ]
  end

  @doc "The apply command: ticked names, renames, per-value choices, pasted values from the draft."
  def apply_ops(ctx, import_id, drafts) do
    st = state(ctx, import_id, drafts)

    names =
      for d <- drafts,
          Map.get(st.ticks, R.field(d, "name")) == true,
          R.field(d, "unsupported") != true,
          do: R.field(d, "name")

    missing =
      for name <- names,
          d = Enum.find(drafts, &(R.field(&1, "name") == name)),
          var <- R.field(d, "variables") || [],
          choice(st, d, var) == "paste",
          not R.draft_secret?(draft(ctx, import_id), slot(name, var)),
          do: "#{R.field(var, "name")} of #{name}"

    values =
      for name <- names,
          d = Enum.find(drafts, &(R.field(&1, "name") == name)),
          (R.field(d, "variables") || []) != [],
          into: %{} do
        {name, Map.new(R.field(d, "variables"), &{var_key(&1), choice(st, d, &1)})}
      end

    cond do
      names == [] ->
        [{:toast, "Nothing is ticked", :info}]

      missing != [] ->
        [
          {:toast, "Paste a value for #{Enum.join(missing, ", ")} first, or choose another way",
           :warning}
        ]

      true ->
        [
          {:command, "mcp.import.apply", nil,
           %{
             "import_id" => import_id,
             "names" => names,
             "project_id" => st.project_id,
             "rename" => Map.take(st.rename, names),
             "values" => values
           },
           %{
             secrets_from: {:draft, @draft},
             undo: false,
             toast: "Imported #{R.count(length(names), "server")}",
             after: {:discard_draft, @draft, then: :back}
           }}
        ]
    end
  end
end
