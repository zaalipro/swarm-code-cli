defmodule SwarmCodeCLI.UI.Settings.Sections.Memory do
  @moduledoc """
  The Memory & instructions section (spec §2.12, D36): a project picker, then three file
  rows — this project's memory, global memory, and the project instructions file (the
  winning `AGENTS.md` / `SWARMCODE.md` / `CLAUDE.md`, or `AGENTS.md · no file yet · Enter
  creates it`). A file of ≤ 16 384 bytes edits in place (Multiline, `Ctrl-S` saves) and
  every file opens in the external editor (`e`); a save carries the fingerprint as read
  (`file.save`, CAS). A file conflict (the layer's `file_conflicts`, §3.7.9) shows `The file
  changed while you edited. s save yours over it · e edit again · Esc keep the file's
  version`. `C` clears a memory (asks, names the line count), `o` opens the folder. In an
  untrusted project the instructions row warns and links to Approvals & trust. Pure.
  """

  alias SwarmCodeCLI.UI.Settings.IntegrationRows, as: R

  @in_place 16_384

  @memory_detail "Facts the agents saved with the remember tool. They are added to every system prompt (project memory even in untrusted projects)."

  @agents_template "# AGENTS.md\n\nInstructions for the agents working in this project: how to build, test and style changes.\n"

  def id, do: :memory

  def loads(ctx), do: [{:records, "memory_files", %{"project_id" => R.project_id(ctx)}}]

  def title(_ctx), do: "Memory & instructions"
  def counts(_ctx), do: %{records: nil}
  def attention(_ctx), do: []
  def record_rows(_ctx, _kind, _id), do: []
  def sub_rows(_ctx, _sub), do: []

  defp files(ctx), do: Enum.map(R.items(ctx, "memory_files"), &R.fields/1)

  defp by_kind(ctx, kind), do: Enum.find(files(ctx), &(R.field(&1, "file_kind") == kind))

  # ------------------------------------------------------------------ rows

  def rows(ctx) do
    picker =
      R.row(
        id: "fld:memory:project",
        kind: :field,
        label: "Project",
        value: [{R.project_name(ctx), :text_primary}, {" ▾", :text_faint}],
        keys: [{"Enter", :open_row, "pick a project"}],
        target: {:project_picker}
      )

    body =
      if R.loaded?(ctx, "memory_files") do
        [R.heading("memory", "memory")] ++
          file_rows(ctx, by_kind(ctx, "memory_project"), "This project's memory") ++
          file_rows(ctx, by_kind(ctx, "memory_global"), "Global memory") ++
          [
            R.info("memory:detail", @memory_detail, :text_faint),
            R.heading("instructions", "instructions")
          ] ++
          instructions_rows(ctx, by_kind(ctx, "instructions"))
      else
        [R.info("memory:loading", "…", :text_faint)]
      end

    [picker | body]
  end

  defp file_rows(_ctx, nil, _label), do: []

  defp file_rows(ctx, f, label) do
    ref = R.field(f, "ref")
    lines = R.field(f, "lines") || 0
    in_place = in_place?(f)

    value =
      if lines == 0,
        do: [{"empty", :text_faint}],
        else: [{"#{R.count(lines, "line")} · #{R.bytes(R.field(f, "bytes"))}", :text_primary}]

    [
      R.row(
        id: "file:#{ref}",
        kind: :record,
        label: label,
        value: value,
        tag: [{R.field(f, "path"), :text_faint}],
        lines: size_lines(ctx, f) ++ conflict_lines(ctx, ref),
        editor: editor(ctx, f),
        keys:
          [
            {"Enter", :open_row, if(in_place, do: "edit", else: "open in #{R.editor_name(ctx)}")},
            {"e", :alt, "edit in #{R.editor_name(ctx)}"}
          ] ++
            if(lines > 0, do: [{"C", :delete, "clear"}], else: []) ++
            [{"o", :open_related, "folder"}],
        target: {:file, ref, R.field(f, "file_kind")}
      )
    ]
  end

  defp in_place?(f),
    do: R.field(f, "editable_in_place") != false and (R.field(f, "bytes") || 0) <= @in_place

  defp size_lines(ctx, f) do
    cond do
      R.field(f, "too_large") == true ->
        [[{"too large to open here · e opens it in #{R.editor_name(ctx)}", :text_faint}]]

      not in_place?(f) ->
        [[{"over 16 KB · e opens it in #{R.editor_name(ctx)}", :text_faint}]]

      true ->
        []
    end
  end

  defp editor(ctx, f) do
    if in_place?(f) do
      content =
        case R.file(ctx, R.field(f, "ref")) do
          nil -> nil
          file -> R.field(file, "content")
        end

      {SwarmCodeCLI.UI.Settings.Editors.Multiline,
       %{value: content, max: @in_place, loading: content == nil}}
    end
  end

  defp conflict(ctx, ref) do
    case Map.get(R.layer(ctx), :file_conflicts) do
      %{} = conflicts -> Map.get(conflicts, ref)
      _ -> nil
    end
  end

  defp conflict_lines(ctx, ref) do
    if conflict(ctx, ref),
      do: [
        [
          {"! The file changed while you edited. ", :warning},
          {"s", :key},
          {" save yours over it · ", :text_faint},
          {"e", :key},
          {" edit again · ", :text_faint},
          {"Esc", :key},
          {" keep the file's version", :text_faint}
        ]
      ],
      else: []
  end

  defp instructions_rows(_ctx, nil), do: []

  defp instructions_rows(ctx, f) do
    ref = R.field(f, "ref")
    exists = R.field(f, "exists") != false
    winner = R.field(f, "winner") || "AGENTS.md"
    project = R.project_name(ctx)
    trusted = R.field(f, "trusted") != false

    facts = [
      {"loaded at run start from the root and 3 levels below (AGENTS.override.md first in each folder) · 12 files · 32 000 characters",
       :text_faint}
    ]

    warning = if trusted, do: [], else: [[{"! not read until you trust #{project}", :warning}]]

    row =
      if exists do
        R.row(
          id: "file:#{ref}",
          kind: :record,
          label: winner,
          value: [
            {"#{R.count(R.field(f, "lines") || 0, "line")} · #{R.bytes(R.field(f, "bytes"))}",
             :text_primary}
          ],
          tag: [{R.field(f, "path"), :text_faint}],
          marks: if(trusted, do: [], else: [:attention]),
          lines: [facts] ++ warning ++ size_lines(ctx, f) ++ conflict_lines(ctx, ref),
          editor: editor(ctx, f),
          keys: [
            {"Enter", :open_row,
             if(in_place?(f), do: "edit", else: "open in #{R.editor_name(ctx)}")},
            {"e", :alt, "edit in #{R.editor_name(ctx)}"},
            {"o", :open_related, "folder"}
          ],
          target: {:file, ref, "instructions"}
        )
      else
        R.row(
          id: "file:#{ref}",
          kind: :record,
          label: "AGENTS.md",
          value: [{"no file yet · ", :text_faint}, {"Enter", :key}, {" creates it", :text_faint}],
          tag: [{R.field(f, "path"), :text_faint}],
          marks: if(trusted, do: [], else: [:attention]),
          lines: [facts] ++ warning,
          keys: [{"Enter", :open_row, "create AGENTS.md"}],
          target: {:create_instructions, ref}
        )
      end

    trust =
      if trusted,
        do: [],
        else: [
          R.row(
            id: "link:approvals.trusted",
            kind: :link,
            label: "Approvals & trust › Trusted",
            value: [{"trust #{project} so its instructions are read", :text_faint}],
            keys: [{"Enter", :open_row, "open"}],
            target: {:link, :approvals}
          )
        ]

    [row | trust]
  end

  # ------------------------------------------------------------------- act

  def act(ctx, row, verb) do
    case {Map.get(row, :target), verb} do
      {{:project_picker}, :open_row} ->
        [project_picker(ctx)]

      {{:link, section}, :open_row} ->
        [{:section, section}]

      {{:create_instructions, ref}, :open_row} ->
        [
          {:command, "file.save", %{"ref" => ref}, %{"content" => @agents_template},
           %{
             expected: %{"fingerprint" => %{"missing" => true}},
             write_key: {:file, ref},
             undo: false,
             toast: "Created AGENTS.md"
           }}
        ]

      {{:file, ref, _kind}, :save} ->
        if conflict(ctx, ref), do: save_over(ctx, ref), else: :default

      {{:file, ref, _kind}, :alt} ->
        if conflict(ctx, ref), do: save_over(ctx, ref), else: external(ctx, ref)

      {{:file, ref, _kind}, :external} ->
        external(ctx, ref)

      {{:file, ref, _kind}, :escape} ->
        if conflict(ctx, ref),
          do: [{:conflict_discard, {:file, ref}}, {:load, {:file, ref}}],
          else: :default

      {{:file, ref, _kind}, :open_row} ->
        open(ctx, row, ref)

      {{:file, ref, kind}, :delete} when kind in ["memory_project", "memory_global"] ->
        clear_ops(ctx, ref, kind)

      {{:file, _ref, "instructions"}, :delete} ->
        [{:toast, "An instructions file is not cleared here; edit it instead", :info}]

      {{:file, ref, _kind}, :open_related} ->
        case meta(ctx, ref) do
          nil -> :default
          f -> [{:open_folder, Path.dirname(R.field(f, "path"))}]
        end

      _ ->
        :default
    end
  end

  defp meta(ctx, ref), do: Enum.find(files(ctx), &(R.field(&1, "ref") == ref))

  defp content(ctx, ref) do
    case R.file(ctx, ref) do
      nil -> nil
      file -> R.field(file, "content")
    end
  end

  defp fingerprint(ctx, ref) do
    case R.file(ctx, ref) do
      nil -> ctx |> meta(ref) |> R.field("fingerprint")
      file -> R.field(file, "fingerprint") || ctx |> meta(ref) |> R.field("fingerprint")
    end
  end

  defp open(ctx, row, ref) do
    f = meta(ctx, ref)

    cond do
      f == nil -> []
      not in_place?(f) -> external(ctx, ref)
      content(ctx, ref) == nil -> [{:load, {:file, ref}}, {:edit, row.id}]
      true -> [{:edit, row.id}]
    end
  end

  defp external(ctx, ref) do
    mine = conflict(ctx, ref) && R.field(conflict(ctx, ref), "mine")

    case mine || content(ctx, ref) do
      nil ->
        [{:load, {:file, ref}}, {:toast, "Reading the file · press e again", :info}]

      text ->
        [
          {:external_edit,
           %{ref: ref, content: text, fingerprint: fingerprint(ctx, ref), suffix: ".md"}}
        ]
    end
  end

  defp save_over(ctx, ref) do
    c = conflict(ctx, ref)
    mine = R.field(c, "mine")
    fresh = R.field(c, "fingerprint") || fingerprint(ctx, ref)

    [
      {:command, "file.save", %{"ref" => ref}, %{"content" => mine},
       %{
         expected: %{"fingerprint" => fresh},
         write_key: {:file, ref},
         undo: false,
         toast: "Saved yours over it"
       }}
    ]
  end

  defp clear_ops(ctx, ref, kind) do
    f = meta(ctx, ref)
    lines = R.field(f, "lines") || 0
    what = if kind == "memory_project", do: "this project's memory", else: "global memory"

    if lines == 0 do
      [{:toast, "It is already empty", :info}]
    else
      [
        {:confirm,
         R.confirm(
           id: "memory.clear",
           title: "Clear #{what}?",
           lines: [
             "All #{R.count(lines, "line")} go; the agents forget what they saved with the remember tool."
           ],
           safe: "Keep it",
           danger: "Clear #{R.count(lines, "line")}",
           letter: "C",
           undoable?: false,
           opener: "file:#{ref}"
         ),
         then: [
           {:command, "file.clear", %{"ref" => ref}, %{},
            %{
              expected: %{"fingerprint" => R.field(f, "fingerprint")},
              write_key: {:file, ref},
              undo: false,
              toast: "Cleared #{what}"
            }}
         ]}
      ]
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
       id: "memory.project",
       title: "Memory of",
       options: options,
       current: R.project_id(ctx),
       on_pick: {:project, :page}
     )}
  end

  # ---------------------------------------------------------------- commit

  @doc "The Multiline result: save with the fingerprint as read."
  def commit(ctx, row, value) do
    case Map.get(row, :target) do
      {:file, ref, _kind} ->
        text = to_string(value || "")

        cond do
          text == content(ctx, ref) ->
            []

          byte_size(text) > @in_place ->
            [{:row_error, row.id, "over 16 KB · e opens it in #{R.editor_name(ctx)}"}]

          true ->
            f = meta(ctx, ref)
            name = f && Path.basename(R.field(f, "path"))

            [
              {:command, "file.save", %{"ref" => ref}, %{"content" => text},
               %{
                 expected: %{"fingerprint" => fingerprint(ctx, ref)},
                 write_key: {:file, ref},
                 undo: false,
                 toast: "Saved #{name}"
               }}
            ]
        end

      _ ->
        :default
    end
  end
end
