defmodule SwarmCodeCLI.UI.Settings.Sections.Library do
  @moduledoc """
  The Library section (spec §2.13, the §4.15 sketch): four groups of files for the page
  project — commands (`/name · scope · mode · description`; a name the built-in /settings
  takes says so), agent definitions (three tiers, `shadows the bundled one` / `shadowed`,
  parse errors as `✗`), skills (`name · scope · description · N files`), workflows
  (`name · scope · smoke`). Keys: Enter opens the file in the editor (external edit round
  trip), `n` new from a template (a scope picker, then the name), `x` delete (asks; bundled
  and built-in files say why not), `o` the folder, `y` copy the path, `t` the workflow smoke
  check (one workflow, or every one from the group heading). Pure.
  """

  alias SwarmCodeCLI.UI.Settings.IntegrationRows, as: R

  @groups [
    {"commands", "commands", "command"},
    {"agent_defs", "agent definitions", "agent"},
    {"skills", "skills", "skill"},
    {"workflows", "workflows", "workflow"}
  ]

  @scopes %{
    "command" => [{"project", "this project"}, {"global", "every project"}],
    "agent" => [{"project", "this project"}, {"user", "you, in every project"}],
    "skill" => [{"project", "this project"}, {"user", "you, in every project"}]
  }

  @read_only ~w(bundled builtin)
  @new "library_new"

  def id, do: :library

  def loads(ctx) do
    pid = R.project_id(ctx)
    for {kind, _, _} <- @groups, do: {:records, kind, %{"project_id" => pid}}
  end

  def title(ctx), do: "Library · #{R.project_name(ctx)}"
  def counts(_ctx), do: %{records: nil}
  def attention(_ctx), do: []
  def record_rows(_ctx, _kind, _id), do: []
  def sub_rows(_ctx, _sub), do: []

  # ------------------------------------------------------------------ rows

  def rows(ctx) do
    filter = R.filter(ctx, {:library, nil})

    Enum.flat_map(@groups, fn {kind, heading, file_kind} ->
      items = ctx |> R.items(kind) |> Enum.map(&with_ref/1)
      shown = if filter, do: Enum.filter(items, &matches?(&1, filter)), else: items
      smoke = if kind == "workflows", do: smoke_results(ctx), else: %{}

      head =
        R.row(
          id: "head:#{heading}",
          kind: :heading,
          label: heading,
          value: [{"#{length(items)}", :text_faint}],
          keys:
            [{"n", :new, "new"}] ++
              if(kind == "workflows", do: [{"t", :test, "smoke every workflow"}], else: []),
          target: {:group, file_kind}
        )

      body =
        cond do
          not R.loaded?(ctx, kind) -> [R.info("#{kind}:loading", "…", :text_faint)]
          shown == [] and filter -> [R.info("#{kind}:none", "none match", :text_ghost)]
          shown == [] -> [R.info("#{kind}:none", empty_words(file_kind), :text_ghost)]
          true -> Enum.map(shown, &item_row(ctx, file_kind, &1, smoke))
        end

      [head] ++ new_row(ctx, file_kind) ++ body ++ extra(kind)
    end)
  end

  defp with_ref(rec), do: Map.put(R.fields(rec), "ref", R.record_id(rec) || R.field(rec, "ref"))

  defp matches?(item, filter) do
    q = String.downcase(filter)

    String.contains?(
      String.downcase("#{R.field(item, "name")} #{R.field(item, "description")}"),
      q
    )
  end

  defp empty_words("workflow"), do: "none yet · /create-workflow in a conversation writes one"
  defp empty_words(_), do: "none yet · n creates one from a template"

  defp extra("workflows") do
    [
      R.info(
        "workflows:create",
        "New workflows are written by /create-workflow in a conversation",
        :text_faint
      )
    ]
  end

  defp extra(_), do: []

  defp scope_of(item), do: R.field(item, "scope") || R.field(item, "tier")

  defp item_row(ctx, "command", c, _smoke) do
    shadowed = R.field(c, "shadowed_by_builtin") == true
    name = "/#{R.field(c, "name")}"
    mode = R.field(c, "mode")

    base(ctx, "command", c,
      label: name,
      value:
        [
          {String.pad_trailing(to_string(R.field(c, "scope")), 9), :text_muted},
          {String.pad_trailing(to_string(mode || ""), 6), :text_muted}
        ] ++
          if(R.field(c, "swarm") == true, do: [{"swarm ", :text_muted}], else: []) ++
          [{to_string(R.field(c, "description") || ""), :text_primary}],
      lines:
        if(shadowed,
          do: [[{"! shadowed by the built-in /settings · rename the file to use it", :warning}]],
          else: []
        ) ++
          if(R.field(c, "overrides_global") == true,
            do: [[{"overrides the global /#{R.field(c, "name")}", :text_faint}]],
            else: []
          ),
      marks: if(shadowed, do: [:attention], else: [])
    )
  end

  defp item_row(ctx, "agent", a, _smoke) do
    model = R.field(a, "model") || "the sub-agent model"
    effort = R.field(a, "effort")
    who = if effort, do: "#{model} · #{effort}", else: model

    tag =
      cond do
        R.field(a, "shadowed") == true ->
          [{"shadowed", :text_faint}]

        is_binary(R.field(a, "shadows")) ->
          [{"shadows the #{R.field(a, "shadows")} one", :text_muted}]

        true ->
          []
      end

    case R.field(a, "parse_error") do
      nil ->
        base(ctx, "agent", a,
          label: R.field(a, "name"),
          value: [
            {String.pad_trailing(to_string(R.field(a, "tier")), 9), :text_muted},
            {who, :text_primary}
          ],
          tag: tag
        )

      error ->
        base(ctx, "agent", a,
          label: R.field(a, "name"),
          value: [
            {String.pad_trailing(to_string(R.field(a, "tier")), 9), :text_muted},
            {R.glyph(ctx, :error) <> " " <> error, :error}
          ],
          tag: tag,
          marks: [:attention]
        )
    end
  end

  defp item_row(ctx, "skill", s, _smoke) do
    base(ctx, "skill", s,
      label: R.field(s, "name"),
      value: [
        {String.pad_trailing(to_string(R.field(s, "scope")), 9), :text_muted},
        {to_string(R.field(s, "description") || ""), :text_primary},
        {" · #{R.count(R.field(s, "files") || 1, "file")}", :text_faint}
      ],
      tag: if(R.field(s, "shadowed") == true, do: [{"shadowed", :text_faint}], else: [])
    )
  end

  defp item_row(ctx, "workflow", w, smoke) do
    ref = R.field(w, "ref")
    result = Map.get(smoke, ref, R.field(w, "smoke"))

    {words, role, tag} =
      cond do
        R.running?(smoke_task(ctx, ref)) ->
          {R.glyph(ctx, :running) <> " checking", :info, []}

        result == "ok" ->
          {R.glyph(ctx, :ok) <> " smoke ok", :success, []}

        is_binary(result) ->
          {R.glyph(ctx, :error) <> " " <> result, :error,
           [{"t", :key}, {" check again", :text_faint}]}

        true ->
          {"not checked · t checks it", :text_faint, []}
      end

    base(ctx, "workflow", w,
      label: R.field(w, "name"),
      value: [
        {String.pad_trailing(to_string(R.field(w, "scope")), 9), :text_muted},
        {words, role}
      ],
      tag: tag,
      marks: if(role == :error, do: [:attention], else: [])
    )
  end

  defp base(ctx, file_kind, item, attrs) do
    ref = R.field(item, "ref")
    read_only = scope_of(item) in @read_only

    keys =
      [{"Enter", :open_row, "open in #{R.editor_name(ctx)}"}, {"n", :new, "new"}] ++
        if(read_only, do: [], else: [{"x", :delete, "delete"}]) ++
        [{"o", :open_related, "folder"}, {"y", :copy, "copy path"}] ++
        if(file_kind == "workflow", do: [{"t", :test, "smoke"}], else: [])

    R.row(
      Keyword.merge(
        [
          id: "file:#{ref}",
          kind: :record,
          keys: keys,
          state: if(read_only, do: :readonly, else: :normal),
          target: {:item, file_kind, ref, R.field(item, "path"), read_only, R.field(item, "name")}
        ],
        attrs
      )
    )
  end

  defp smoke_task(ctx, ref) do
    R.task(ctx, "workflow.smoke", %{"ref" => ref}) ||
      R.task(ctx, "workflow.smoke", %{"all" => true})
  end

  defp smoke_results(ctx) do
    ctx
    |> R.tasks()
    |> Enum.filter(fn {_id, t} ->
      R.field(t, "action") == "workflow.smoke" and R.field(t, "state") == "done"
    end)
    |> Enum.sort_by(fn {_id, t} -> R.field(t, "received_at_ms") || 0 end)
    |> Enum.reduce(%{}, fn {id, _t}, acc ->
      Enum.reduce(
        R.task_rows(ctx, id),
        acc,
        &Map.put(&2, R.field(&1, "ref"), R.field(&1, "smoke"))
      )
    end)
  end

  defp new_row(ctx, file_kind) do
    case R.draft(ctx, @new) do
      nil ->
        []

      d ->
        f = R.draft_fields(d)

        if R.field(f, "kind") == file_kind do
          errors = R.draft_errors(d)

          [
            R.row(
              id: "new:library",
              kind: :field,
              label: "New #{file_kind} · #{R.field(f, "scope")}",
              value: [
                {"type its name · Enter creates it from the template · Esc discards", :text_faint}
              ],
              lines:
                if(m = Map.get(errors, "name"),
                  do: [[{R.glyph(ctx, :error) <> " " <> m, :error}]],
                  else: []
                ),
              editor: {SwarmCodeCLI.UI.Settings.Editors.Text, %{value: "", max: 64}},
              keys: [{"Enter", :open_row, "name it"}],
              target: {:new_name, file_kind, R.field(f, "scope")}
            )
          ]
        else
          []
        end
    end
  end

  # ------------------------------------------------------------------- act

  def act(ctx, row, verb) do
    case {Map.get(row, :target), verb} do
      {{:group, "workflow"}, :new} ->
        [{:toast, "New workflows are written by /create-workflow in a conversation", :info}]

      {{:group, kind}, :new} ->
        [scope_picker(kind)]

      {{:group, "workflow"}, :test} ->
        [{:task, "workflow.smoke", nil, %{}}]

      {{:item, "workflow", _, _, _, _}, :new} ->
        [{:toast, "New workflows are written by /create-workflow in a conversation", :info}]

      {{:item, kind, _, _, _, _}, :new} ->
        [scope_picker(kind)]

      {{:item, _, ref, _, _, _}, :open_row} ->
        open(ctx, ref)

      {{:item, _, _, _, true, _}, :delete} ->
        [{:toast, "a built-in file cannot be deleted; make a user copy to override it", :info}]

      {{:item, kind, ref, _, false, name}, :delete} ->
        delete_ops(ctx, kind, ref, name)

      {{:item, _, _, path, _, _}, :open_related} ->
        [{:open_folder, Path.dirname(path)}]

      {{:item, _, _, path, _, _}, :copy} ->
        [{:copy, path}, {:toast, "Copied #{path}", :info}]

      {{:item, "workflow", ref, _, _, _}, :test} ->
        [{:task, "workflow.smoke", %{"ref" => ref}, %{"ref" => ref}}]

      {{:new_name, _, _}, :escape} ->
        [{:draft_discard, @new}]

      {{:new_name, _, _}, :open_row} ->
        [{:edit, "new:library"}]

      _ ->
        :default
    end
  end

  defp scope_picker(kind) do
    options = for {value, hint} <- @scopes[kind], do: %{value: value, label: value, hint: hint}

    {:picker,
     R.picker(
       id: "library.new_scope",
       title: "New #{kind} for",
       options: options,
       on_pick: {:section, :library, {:new, kind}}
     )}
  end

  @doc "The scope picked for a new file: a name row follows."
  def picked(_ctx, {:new, kind}, scope) do
    [{:draft_put, @new, %{"kind" => kind, "scope" => scope}}, {:edit, "new:library"}]
  end

  def picked(_ctx, _what, _value), do: []

  defp open(ctx, ref) do
    case R.file(ctx, ref) do
      nil ->
        [{:load, {:file, ref}}, {:toast, "Reading the file · press Enter again", :info}]

      file ->
        read_only = String.contains?(ref, ":bundled:") or String.contains?(ref, ":builtin:")

        [
          {:external_edit,
           %{
             ref: ref,
             content: R.field(file, "content"),
             fingerprint: R.field(file, "fingerprint"),
             suffix: Path.extname(R.field(file, "path") || ".md"),
             read_only: read_only
           }}
        ]
    end
  end

  defp delete_ops(ctx, kind, ref, name) do
    expected =
      case R.file(ctx, ref) do
        nil -> %{}
        file -> %{"fingerprint" => R.field(file, "fingerprint")}
      end

    [
      {:confirm,
       R.confirm(
         id: "library.delete",
         title: "Delete #{kind} #{name}?",
         lines: ["The file goes from disk; this cannot be undone."],
         safe: "Keep it",
         danger: "Delete #{name}",
         letter: "x",
         undoable?: false,
         opener: "file:#{ref}"
       ),
       then: [
         {:command, "file.delete", %{"ref" => ref}, %{},
          %{expected: expected, write_key: {:file, ref}, undo: false, toast: "Deleted #{name}"}}
       ]}
    ]
  end

  # ---------------------------------------------------------------- commit

  defp name_rule("command"),
    do: {~r/^[a-z0-9._-]{1,64}$/, "lowercase letters, digits, ., _ or - (64 max)"}

  defp name_rule("agent"),
    do: {~r/^[a-z0-9_-]{1,24}$/, "lowercase letters, digits, _ or - (24 max)"}

  defp name_rule("skill"), do: {~r/^[A-Za-z0-9._-]+$/, "letters, digits, ., _ or -"}

  def commit(ctx, row, value) do
    case Map.get(row, :target) do
      {:new_name, kind, scope} ->
        name = String.trim(to_string(value || ""))
        {rule, words} = name_rule(kind)

        if Regex.match?(rule, name) do
          target = %{"kind" => kind, "scope" => scope, "name" => name}

          target =
            if scope == "project",
              do: Map.put(target, "project_id", R.project_id(ctx)),
              else: target

          [
            {:command, "file.create", target, %{},
             %{
               write_key: {:file_create, kind, name},
               undo: false,
               toast: "Created #{name}",
               errors_to: {:draft, @new},
               after: {:discard_draft, @new}
             }}
          ]
        else
          [{:row_error, row.id, words}]
        end

      _ ->
        :default
    end
  end
end
