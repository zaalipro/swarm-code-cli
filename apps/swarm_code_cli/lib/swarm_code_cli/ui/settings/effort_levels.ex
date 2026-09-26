defmodule SwarmCodeCLI.UI.Settings.EffortLevels do
  @moduledoc """
  The effort levels sub-page of a provider (spec §2.23 *effort_level*, T§5.3, the T§24
  sketch): the one drafted table. A scope row (`this provider` or one model's override), a
  preset picker, the levels `key · label · hint · adds to the request · drops`, a preview
  of what the focused level adds, `a` add, `x` remove, `J K` move, Enter edits a level as
  JSON (the body validated as an object, parse errors with line and column), `r` resets to
  the built-in levels, `Ctrl-S` saves with `efforts.save` (row errors land under their
  row), and a model scope with an override offers `▸ Remove this model's override`.

  Every edit rewrites the draft (`{:draft_put, "effort_levels", %{"provider_id", "model",
  "rows"}}`); nothing is saved until `Ctrl-S`. Pure.
  """

  alias SwarmCodeCLI.UI.Settings.IntegrationRows, as: R

  @draft "effort_levels"
  @key_format ~r/^[a-z0-9][a-z0-9_-]{0,23}$/

  # ------------------------------------------------------------- sources

  @doc "Where a provider's levels come from, in words (`DeepSeek V4 · 3 levels`)."
  def source_words(f) do
    levels = R.field(f, "effort_levels")
    overrides = map_size(R.field(f, "model_effort_levels") || %{})
    presets = R.field(f, "presets") || []

    base =
      cond do
        levels in [nil, []] ->
          "built-in levels"

        preset = Enum.find(presets, &(R.field(&1, "levels") == levels)) ->
          "#{R.field(preset, "name")} · #{R.count(length(levels), "level")}"

        true ->
          "custom · #{R.count(length(levels), "level")}"
      end

    if overrides > 0, do: base <> " + #{R.count(overrides, "model override")}", else: base
  end

  @doc "The draft of this page when it belongs to provider `id`, else nil."
  def draft(ctx, id) do
    case R.draft(ctx, @draft) do
      nil ->
        nil

      d ->
        f = R.draft_fields(d)
        if R.field(f, "provider_id") == id, do: d, else: nil
    end
  end

  @doc "The scope on screen: nil (the provider) or a model id."
  def scope(ctx, id) do
    case draft(ctx, id) do
      nil -> ctx |> R.staged("provider", id) |> Map.get("effort_scope")
      d -> R.field(R.draft_fields(d), "model")
    end
  end

  @doc "The stored levels of a scope (nil when the scope has none of its own)."
  def stored(f, nil), do: R.field(f, "effort_levels")
  def stored(f, model), do: Map.get(R.field(f, "model_effort_levels") || %{}, model)

  @doc "The levels shown: the draft's, else the stored ones of the scope, else what is in force."
  def levels(ctx, id, f) do
    model = scope(ctx, id)

    case draft(ctx, id) do
      nil -> stored(f, model) || stored(f, nil) || R.field(f, "builtin_levels") || []
      d -> R.field(R.draft_fields(d), "rows") || []
    end
  end

  # ----------------------------------------------------------------- rows

  @doc "The sub-page rows for provider `id`."
  def rows(ctx, id) do
    case R.record(ctx, "provider", id) do
      nil -> [R.info("loading", "…", :text_faint)]
      rec -> page_rows(ctx, id, R.fields(rec))
    end
  end

  defp page_rows(ctx, id, f) do
    model = scope(ctx, id)
    d = draft(ctx, id)
    levels = levels(ctx, id, f)
    errors = if d, do: R.draft_errors(d), else: %{}
    overrides = R.field(f, "model_effort_levels") || %{}
    focused = Map.get(R.current_page(ctx), :cursor)

    head =
      R.row(
        id: "info:levels:head",
        kind: :info,
        label: "#{R.field(f, "name")} › Effort levels",
        value:
          if(d,
            do: [{"unsaved · Ctrl-S saves · Esc asks", :warning}],
            else: [{source_words(f), :text_faint}]
          ),
        state: :readonly
      )

    scope_row =
      R.row(
        id: "fld:levels:scope",
        kind: :field,
        label: "scope",
        value: scope_segments(f, model, overrides),
        editor:
          {SwarmCodeCLI.UI.Settings.Editors.Enum,
           %{
             value: model,
             choices:
               [%{value: nil, label: "this provider", hint: nil}] ++
                 for(
                   m <- R.field(f, "models") || [],
                   do: %{
                     value: m,
                     label: "#{m} override",
                     hint: if(Map.has_key?(overrides, m), do: "has an override")
                   }
                 )
           }},
        keys: [{"Enter", :open_row, "change the scope"}],
        target: {:levels_scope, id}
      )

    preset_row =
      R.row(
        id: "fld:levels:preset",
        kind: :field,
        label: "preset",
        value: [{preset_name(f, levels) || "none", :text_primary}, {" ▾", :text_faint}],
        tag: [{"r", :key}, {" reset to built-in", :text_faint}],
        keys: [{"Enter", :open_row, "pick a preset"}, {"r", :reset, "reset to built-in"}],
        target: {:levels_preset, id}
      )

    header =
      R.row(
        id: "info:levels:columns",
        kind: :info,
        label: "",
        state: :readonly,
        columns: [
          {"key", :text_faint, 1},
          {"label", :text_faint, 3},
          {"hint", :text_faint, 4},
          {"adds to the request", :text_faint, 2},
          {"drops", :text_faint, 5}
        ]
      )

    level_rows =
      levels
      |> Enum.with_index()
      |> Enum.flat_map(fn {level, i} ->
        row_id = "item:levels:#{i}"
        message = Map.get(errors, "rows[#{i}]") || R.row_error(ctx, row_id)

        row =
          R.row(
            id: row_id,
            kind: :list_item,
            label: to_string(R.field(level, "key")),
            columns: [
              {to_string(R.field(level, "key")), :text_primary, 1},
              {to_string(R.field(level, "label") || ""), :text_primary, 3},
              {to_string(R.field(level, "hint") || ""), :text_muted, 4},
              {adds(R.field(level, "body")), :text_muted, 2},
              {Enum.join(R.field(level, "drop") || [], " "), :text_faint, 5}
            ],
            lines:
              if(message, do: [[{R.glyph(ctx, :error) <> " " <> message, :error}]], else: []),
            marks: if(message, do: [:invalid], else: []),
            editor:
              {SwarmCodeCLI.UI.Settings.Editors.Multiline,
               %{value: level_json(level), max: 16_384, syntax: :json}},
            keys: [
              {"Enter", :open_row, "edit the level"},
              {"a", :add, "add"},
              {"x", :delete, "remove"},
              {"J", :move_down, "down"},
              {"K", :move_up, "up"}
            ],
            target: {:level, id, i}
          )

        if focused == row_id, do: [row, preview_row(level)], else: [row]
      end)

    actions =
      [
        R.row(
          id: "act:levels.add",
          kind: :action,
          label: "▸ Add a level",
          keys: [{"Enter", :open_row, "add"}, {"a", :add, "add"}],
          target: {:level_add, id}
        ),
        R.row(
          id: "act:levels.save",
          kind: :action,
          label: "▸ Save",
          value:
            if(d,
              do: [
                {"Ctrl-S", :key},
                {" · writes these levels to #{scope_words(model)}", :text_faint}
              ],
              else: [{"nothing to save", :text_faint}]
            ),
          state: if(d, do: :normal, else: :disabled),
          keys: [{"Ctrl-S", :save, "save"}],
          target: {:levels_save, id}
        ),
        R.row(
          id: "act:levels.reset",
          kind: :action,
          label: "▸ Reset to built-in levels",
          value: [{"the levels of #{kind_words(R.field(f, "kind"))} providers", :text_faint}],
          keys: [{"Enter", :open_row, "reset"}, {"r", :reset, "reset"}],
          target: {:levels_reset, id}
        )
      ] ++
        if(model && Map.has_key?(overrides, model),
          do: [
            R.row(
              id: "act:levels.remove_override",
              kind: :action,
              label: "▸ Remove this model's override",
              value: [{"#{model} uses the provider's levels again", :text_faint}],
              keys: [{"Enter", :open_row, "remove"}],
              target: {:remove_override, id, model}
            )
          ],
          else: []
        )

    [head, scope_row, preset_row, header] ++ level_rows ++ actions
  end

  defp scope_segments(_f, nil, overrides) do
    [{"[this provider]", :text_primary}] ++
      for({m, _} <- overrides, do: {"  #{m} •override", :text_muted})
  end

  defp scope_segments(_f, model, overrides) do
    [{"this provider  ", :text_muted}, {"[#{model} override]", :text_primary}] ++
      for({m, _} <- overrides, m != model, do: {"  #{m} •override", :text_muted})
  end

  defp scope_words(nil), do: "this provider"
  defp scope_words(model), do: "#{model}'s override"

  defp kind_words("anthropic"), do: "Anthropic"
  defp kind_words(_), do: "OpenAI-compatible"

  defp preset_name(f, levels) do
    Enum.find_value(R.field(f, "presets") || [], fn p ->
      if R.field(p, "levels") == levels, do: R.field(p, "name")
    end) ||
      if(levels == R.field(f, "builtin_levels"), do: "built-in", else: nil)
  end

  defp preview_row(level) do
    body = R.field(level, "body") || %{}
    drops = R.field(level, "drop") || []
    json = Jason.encode!(body)
    tail = if drops == [], do: "", else: " · drops #{Enum.join(drops, ", ")}"

    R.row(
      id: "info:levels:preview",
      kind: :info,
      label: "",
      indent: 2,
      value: [{"the request gains #{json}#{tail}", :text_faint}],
      state: :readonly
    )
  end

  @doc "What a level's body adds, in words (`thinking adaptive · effort high · 32k tokens`)."
  def adds(body) when is_map(body) and map_size(body) == 0, do: "nothing"

  def adds(body) when is_map(body) do
    body
    |> Enum.sort_by(fn {k, _} -> k end)
    |> Enum.map(fn
      {"max_tokens", n} when is_integer(n) and n >= 1_000 ->
        "#{div(n, 1_000)}k tokens"

      {k, %{"type" => type}} ->
        "#{k} #{type}"

      {_k, %{} = m} when map_size(m) == 1 ->
        m |> Enum.map(fn {ik, iv} -> "#{ik} #{scalar(iv)}" end) |> hd()

      {k, v} ->
        "#{k} #{scalar(v)}"
    end)
    |> Enum.join(" · ")
  end

  def adds(_), do: "nothing"

  defp scalar(v) when is_binary(v), do: v
  defp scalar(v) when is_number(v) or is_boolean(v), do: to_string(v)
  defp scalar(v), do: Jason.encode!(v)

  defp level_json(level) do
    %{
      "key" => R.field(level, "key"),
      "label" => R.field(level, "label"),
      "hint" => R.field(level, "hint"),
      "body" => R.field(level, "body") || %{},
      "drop" => R.field(level, "drop") || []
    }
    |> Jason.encode!(pretty: true)
  end

  # ------------------------------------------------------------------ act

  @doc "Row letters and Enter on the sub-page."
  def act(ctx, row, verb) do
    id = page_provider(ctx)
    f = provider_fields(ctx, id)

    case {Map.get(row, :target), verb} do
      {{:level_add, _}, v} when v in [:open_row, :add] -> add_ops(ctx, id, f)
      {{:level, _, _}, :add} -> add_ops(ctx, id, f)
      {{:level, _, i}, :delete} -> put_rows(ctx, id, f, &List.delete_at(&1, i))
      {{:level, _, i}, :move_down} -> put_rows(ctx, id, f, &swap(&1, i, i + 1))
      {{:level, _, i}, :move_up} -> put_rows(ctx, id, f, &swap(&1, i, i - 1))
      {{:levels_preset, _}, :open_row} -> [preset_picker(f)]
      {_, :reset} -> reset_ops(ctx, id, f)
      {{:levels_reset, _}, :open_row} -> reset_ops(ctx, id, f)
      {_, :save} -> save_ops(ctx, id, f)
      {{:levels_save, _}, :open_row} -> save_ops(ctx, id, f)
      {{:remove_override, _, model}, :open_row} -> remove_override_ops(f, id, model)
      _ -> :default
    end
  end

  defp page_provider(ctx) do
    case R.page_record(ctx) do
      {"provider", id} -> id
      _ -> nil
    end
  end

  defp provider_fields(ctx, id) do
    case R.record(ctx, "provider", id) do
      nil -> %{}
      rec -> R.fields(rec)
    end
  end

  defp put_rows(ctx, id, f, fun) do
    old = levels(ctx, id, f)
    new = fun.(old)

    if new == old,
      do: [],
      else: [
        {:draft_put, @draft, %{"provider_id" => id, "model" => scope(ctx, id), "rows" => new}}
      ]
  end

  defp add_ops(ctx, id, f) do
    rows = levels(ctx, id, f)
    taken = MapSet.new(rows, &R.field(&1, "key"))
    key = Enum.find(Stream.map(1..99, &"level#{&1}"), &(not MapSet.member?(taken, &1)))

    new = %{
      "key" => key,
      "label" => String.capitalize(key),
      "hint" => "",
      "body" => %{},
      "drop" => []
    }

    put_rows(ctx, id, f, &(&1 ++ [new])) ++ [{:edit, "item:levels:#{length(rows)}"}]
  end

  defp swap(list, i, j) when i >= 0 and j >= 0 and i < length(list) and j < length(list) do
    a = Enum.at(list, i)
    list |> List.replace_at(i, Enum.at(list, j)) |> List.replace_at(j, a)
  end

  defp swap(list, _, _), do: list

  defp preset_picker(f) do
    {:picker,
     R.picker(
       id: "effort_levels.preset",
       title: "Effort preset",
       options:
         for p <- R.field(f, "presets") || [] do
           levels = R.field(p, "levels") || []

           %{
             value: R.field(p, "id"),
             label: R.field(p, "name"),
             hint: Enum.map_join(levels, " ", &R.field(&1, "key"))
           }
         end,
       on_pick: {:section, :providers, :effort_preset}
     )}
  end

  defp reset_ops(ctx, id, f) do
    model = scope(ctx, id)
    stored = stored(f, model)
    custom = stored not in [nil, []]

    ops =
      if model,
        do: remove_override_ops(f, id, model),
        else: [{:draft_discard, @draft}, command(id, nil, [], f)]

    cond do
      not custom ->
        [{:draft_discard, @draft}]

      true ->
        [
          {:confirm,
           R.confirm(
             id: "effort_levels.reset",
             title: "Reset to the built-in levels?",
             lines: [
               "#{R.count(length(stored), "custom level")} of #{scope_words(model)} will be lost."
             ],
             safe: "Keep them",
             danger: "Reset",
             letter: "R"
           ), then: ops}
        ]
    end
  end

  defp remove_override_ops(f, id, model) do
    [
      {:command, "efforts.remove_override", %{"id" => id, "model" => model}, %{},
       %{
         expected: %{"levels" => stored(f, model)},
         write_key: {:record, "provider", id, "model_effort_levels"},
         toast: "#{model} uses the provider's levels again"
       }}
    ]
  end

  defp save_ops(ctx, id, f) do
    case draft(ctx, id) do
      nil ->
        []

      d ->
        [
          command(
            id,
            R.field(R.draft_fields(d), "model"),
            R.field(R.draft_fields(d), "rows") || [],
            f
          )
        ]
    end
  end

  defp command(id, model, rows, f) do
    wire = Enum.map(rows, &Map.take(stringify(&1), ~w(key label hint body drop)))

    {:command, "efforts.save", %{"id" => id, "model" => model}, %{"rows" => wire},
     %{
       expected: %{"levels" => stored(f, model)},
       write_key:
         {:record, "provider", id, if(model, do: "model_effort_levels", else: "effort_levels")},
       undo:
         {:command, "efforts.save", %{"id" => id, "model" => model},
          %{"rows" => stored(f, model) || []}, %{}},
       toast: "Saved #{R.count(length(rows), "effort level")}",
       after: {:discard_draft, @draft},
       errors_to: {:draft, @draft}
     }}
  end

  defp stringify(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), v} end)

  # --------------------------------------------------------------- commit

  @doc """
  A committed edit: the scope row switches the scope (the draft follows it), a preset id
  replaces the rows, a level's JSON replaces that level after it validates (errors with
  the exact words: `body: must be a JSON object`, the parse error with line and column).
  """
  def commit(ctx, row, value) do
    id = page_provider(ctx)
    f = provider_fields(ctx, id)

    case Map.get(row, :target) do
      {:levels_scope, _} ->
        rows = stored(f, value) || stored(f, nil) || R.field(f, "builtin_levels") || []

        [{:stage, {"provider", id}, %{"effort_scope" => value}}] ++
          if(draft(ctx, id),
            do: [{:draft_put, @draft, %{"provider_id" => id, "model" => value, "rows" => rows}}],
            else: []
          )

      {:level, _, i} ->
        case parse_level(value) do
          {:ok, level} -> put_rows(ctx, id, f, &List.replace_at(&1, i, level))
          {:error, message} -> [{:row_error, "item:levels:#{i}", message}]
        end

      _ ->
        if Map.get(row, :id) == "picker:effort_levels.preset",
          do: preset_ops(ctx, id, f, value),
          else: :default
    end
  end

  @doc "The preset picker's choice on the page's provider (`on_pick: {:section, :providers, :effort_preset}`)."
  def picked(ctx, preset_id) do
    id = page_provider(ctx)
    preset_ops(ctx, id, provider_fields(ctx, id), preset_id)
  end

  @doc "Ops that put a preset's levels into the draft (the preset picker's `on_pick`)."
  def preset_ops(ctx, id, f, preset_id) do
    case Enum.find(R.field(f, "presets") || [], &(R.field(&1, "id") == preset_id)) do
      nil ->
        []

      p ->
        [
          {:draft_put, @draft,
           %{"provider_id" => id, "model" => scope(ctx, id), "rows" => R.field(p, "levels") || []}}
        ]
    end
  end

  @doc "Parses one level edited as JSON: `{:ok, level}` or `{:error, words}`."
  def parse_level(text) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, %{} = map} ->
        key = to_string(Map.get(map, "key") || "")
        body = Map.get(map, "body", %{})
        drop = Map.get(map, "drop", [])

        cond do
          not Regex.match?(@key_format, key) ->
            {:error, "key: lowercase letters, digits, - or _ (24 max)"}

          not is_map(body) ->
            {:error, "body: must be a JSON object"}

          not (is_list(drop) and Enum.all?(drop, &is_binary/1)) ->
            {:error, "drop: a list of top-level keys"}

          true ->
            {:ok,
             %{
               "key" => key,
               "label" => blank(Map.get(map, "label"), String.capitalize(key)),
               "hint" => Map.get(map, "hint") || "",
               "body" => body,
               "drop" => drop
             }}
        end

      {:ok, _other} ->
        {:error, "a level is a JSON object"}

      {:error, %Jason.DecodeError{position: pos, data: data}} ->
        {line, column} = line_column(data, pos)
        {:error, "body: line #{line}, column #{column}: not valid JSON"}
    end
  end

  def parse_level(_), do: {:error, "a level is a JSON object"}

  defp blank(nil, word), do: word
  defp blank("", word), do: word
  defp blank(v, _word), do: v

  defp line_column(data, pos) do
    before = binary_part(data, 0, min(pos, byte_size(data)))
    lines = String.split(before, "\n")
    {length(lines), String.length(List.last(lines)) + 1}
  end

  @doc "The page title."
  def title(ctx, id) do
    name = ctx |> provider_fields(id) |> R.field("name")
    base = "#{name} › Effort levels"
    if draft(ctx, id), do: base <> " · unsaved · Ctrl-S saves · Esc asks", else: base
  end
end
