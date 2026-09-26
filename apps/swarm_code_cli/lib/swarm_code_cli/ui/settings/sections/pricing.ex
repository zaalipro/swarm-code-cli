defmodule SwarmCodeCLI.UI.Settings.Sections.Pricing do
  @moduledoc """
  The Pricing section (spec §2.4, §2.23 *pricing_row*, the §4.15 sketch): a first group
  *used but unpriced* (models in defaults or recent conversations without a row; Enter adds
  a row for one), then the rows sorted by model in the fixed column order `model · in $/M ·
  out $/M · cache read · cache write · context`, derived cache prices shown faint with `·`.

  Enter opens a row's page, where each cell commits on its own (`pricing.put_row` with the
  whole row and CAS on the row read); `a` adds a draft row that stays a draft until the
  model and both prices are valid; `x` removes a row (undoable). Pure.
  """

  alias SwarmCodeCLI.UI.Settings.IntegrationRows, as: R

  @kind "pricing_row"
  @draft "draft"

  @fields [
    {"model", "Model", :text},
    {"input", "Input · $ per M tokens", :money},
    {"output", "Output · $ per M tokens", :money},
    {"cache_read", "Cache read · $ per M tokens", :money_null},
    {"cache_write", "Cache write · $ per M tokens", :money_null},
    {"context_window", "Context window · tokens", :context}
  ]

  def id, do: :pricing

  def loads(_ctx), do: [{:records, "pricing_rows", %{}}, {:records, "unpriced_models", %{}}]

  def title(ctx) do
    case R.page_record(ctx) do
      {@kind, @draft} ->
        "New price · unsaved · it saves once the model and both prices are set · Esc discards"

      {@kind, model} ->
        "Pricing › #{model}"

      _ ->
        "Pricing"
    end
  end

  def counts(ctx),
    do: %{records: if(R.loaded?(ctx, "pricing_rows"), do: length(R.items(ctx, "pricing_rows")))}

  def attention(_ctx), do: []

  # -------------------------------------------------------------- the page

  def rows(ctx) do
    unpriced = R.items(ctx, "unpriced_models")
    priced = R.items(ctx, "pricing_rows")

    head = [
      R.row(
        id: "info:pricing:head",
        kind: :info,
        label: "Pricing · $ per million tokens",
        tag: [{"/", :key}, {" filter · ", :text_faint}, {"a", :key}, {" add", :text_faint}],
        state: :readonly
      )
    ]

    unpriced_rows =
      if unpriced == [] do
        []
      else
        [
          R.heading("used but unpriced", "used but unpriced", [
            {R.count(length(unpriced), "model"), :text_faint}
          ])
        ] ++
          Enum.map(unpriced, &unpriced_row(ctx, &1))
      end

    draft_rows =
      case R.draft(ctx, @kind) do
        nil ->
          []

        d ->
          f = R.draft_fields(d)

          [
            R.row(
              id: "link:pricing:draft",
              kind: :link,
              label: blank(R.field(f, "model"), "new row"),
              value: [{"unsaved · needs the model and both prices", :warning}],
              keys: [{"Enter", :open_row, "open the draft"}],
              target: {:draft}
            )
          ]
      end

    table =
      cond do
        not R.loaded?(ctx, "pricing_rows") ->
          [R.info("loading", "…", :text_faint)]

        priced == [] ->
          [
            R.info(
              "empty",
              "No price yet. Every model counts as $0.00 in every cost until it has one · a adds a row"
            )
          ]

        true ->
          [columns_row()] ++
            Enum.map(priced, &price_row(ctx, &1)) ++
            [
              R.info(
                "derived",
                "· = derived from the input price (read × 0.1, write × 1.25)",
                :text_faint
              )
            ]
      end

    head ++
      unpriced_rows ++
      draft_rows ++
      table ++
      [
        R.row(
          id: "act:pricing.add",
          kind: :action,
          label: "▸ Add a price",
          keys: [{"Enter", :open_row, "add"}, {"a", :add, "add"}],
          target: {:add, nil}
        )
      ]
  end

  defp unpriced_row(_ctx, rec) do
    f = R.fields(rec)
    model = R.field(f, "model")
    convs = R.field(f, "conversations_30d") || 0

    reason =
      "used by #{R.count(convs, "conversation")}" <>
        if(R.field(f, "in_defaults") == true, do: " · a default", else: "")

    R.row(
      id: "rec:unpriced_model:#{model}",
      kind: :record,
      label: model,
      value: [{reason, :text_muted}],
      tag: [{"Enter", :key}, {" adds a row", :text_faint}],
      marks: [:attention],
      keys: [{"Enter", :open_row, "add a row"}],
      target: {:add, model}
    )
  end

  defp columns_row do
    R.row(
      id: "info:pricing:columns",
      kind: :info,
      label: "",
      state: :readonly,
      columns: [
        {"model", :text_faint, 1},
        {"in $/M", :text_faint, 2},
        {"out $/M", :text_faint, 3},
        {"cache read", :text_faint, 5},
        {"cache write", :text_faint, 6},
        {"context", :text_faint, 4}
      ]
    )
  end

  defp price_row(ctx, rec) do
    f = R.fields(rec)
    model = R.field(f, "model") || R.record_id(rec)
    row_id = "rec:pricing_row:#{model}"

    R.row(
      id: row_id,
      kind: :record,
      label: model,
      columns: [
        {model, :text_primary, 1},
        {R.money(R.field(f, "input")), :text_primary, 2},
        {R.money(R.field(f, "output")), :text_primary, 3},
        cache_cell(ctx, R.field(f, "cache_read"), R.field(f, "derived_cache_read"), 5),
        cache_cell(ctx, R.field(f, "cache_write"), R.field(f, "derived_cache_write"), 6),
        context_cell(ctx, R.field(f, "context_window"), 4)
      ],
      lines: error_lines(ctx, row_id),
      keys: [{"Enter", :open_row, "edit the row"}, {"x", :delete, "delete"}, {"u", :undo, "undo"}],
      target: {:row, model},
      detail:
        R.detail(
          title: model,
          scope: "global · shared with the desktop app",
          key_line: "pricing · settings.pricing[\"#{model}\"]",
          description:
            "What a million tokens of #{model} cost, in dollars. Every cost SwarmCode shows (runs, the budget, usage) multiplies tokens by these prices; a cache read or write without its own price is derived from the input price.",
          facts: [{"applies", "the next cost computed"}]
        )
    )
  end

  defp cache_cell(_ctx, nil, derived, priority),
    do: {"#{R.money(derived)} ·", :text_faint, priority}

  defp cache_cell(_ctx, value, _derived, priority), do: {R.money(value), :text_primary, priority}

  defp context_cell(ctx, nil, priority),
    do: {"family default", :text_faint, priority} |> keep(ctx)

  defp context_cell(_ctx, n, priority), do: {group_digits(n), :text_primary, priority}

  defp keep(cell, _ctx), do: cell

  @doc "A whole number with thin groups: `200 000`."
  def group_digits(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.to_charlist()
    |> Enum.chunk_every(3)
    |> Enum.join(" ")
    |> String.reverse()
  end

  def group_digits(n), do: to_string(n)

  defp error_lines(ctx, row_id) do
    case R.row_error(ctx, row_id) do
      nil -> []
      m -> [[{R.glyph(ctx, :error) <> " " <> m, :error}]]
    end
  end

  # ------------------------------------------------------------ row pages

  def record_rows(ctx, @kind, @draft) do
    d = R.draft(ctx, @kind)
    f = R.draft_fields(d)
    errors = R.draft_errors(d)

    [
      R.row(
        id: "info:pricing:draft",
        kind: :info,
        label: "New price",
        value: [{"unsaved · it saves once the model and both prices are set", :warning}],
        state: :readonly
      )
    ] ++
      Enum.map(@fields, fn {field, label, type} ->
        cell_row(
          ctx,
          "fld:pricing_row:draft:#{field}",
          field,
          label,
          type,
          R.field(f, field),
          nil,
          Map.get(errors, field),
          {:draft_cell, field}
        )
      end)
  end

  def record_rows(ctx, @kind, model) do
    case Enum.find(
           R.items(ctx, "pricing_rows"),
           &(R.record_id(&1) == model or R.field(R.fields(&1), "model") == model)
         ) do
      nil ->
        [
          R.info(
            "gone",
            "#{model} has no price any more (changed elsewhere in this session). Esc goes back."
          )
        ]

      rec ->
        f = R.fields(rec)

        Enum.map(@fields, fn {field, label, type} ->
          row_id = "fld:pricing_row:#{model}:#{field}"
          derived = if field in ~w(cache_read cache_write), do: R.field(f, "derived_" <> field)

          cell_row(
            ctx,
            row_id,
            field,
            label,
            type,
            R.field(f, field),
            derived,
            R.row_error(ctx, row_id),
            {:cell, model, field, row_wire(f)}
          )
        end) ++
          [
            R.heading("danger", "danger"),
            R.row(
              id: "act:pricing.delete",
              kind: :action,
              label: "▸ Delete this price",
              value: [{"undoable", :text_faint}],
              keys: [{"x", :delete, "delete"}, {"Enter", :open_row, "delete"}],
              target: {:row, model}
            )
          ]
    end
  end

  def record_rows(_ctx, _kind, _id), do: []

  def sub_rows(_ctx, _sub), do: []

  defp cell_row(ctx, row_id, field, label, type, value, derived, error, target) do
    shown =
      case {type, value} do
        {:text, v} ->
          [{blank(v, "—"), :text_primary}]

        {:money, nil} ->
          [{"not set", :text_ghost}]

        {:money, v} ->
          [{"$" <> R.money(v), :text_primary}]

        {:money_null, nil} ->
          [{"$" <> R.money(derived) <> " · derived from the input price", :text_faint}]

        {:money_null, v} ->
          [{"$" <> R.money(v), :text_primary}]

        {:context, nil} ->
          [{"family default", :text_faint}]

        {:context, v} ->
          [{group_digits(v), :text_primary}]
      end

    editor =
      case type do
        :text ->
          {SwarmCodeCLI.UI.Settings.Editors.Text, %{value: value || "", max: 256}}

        :money ->
          {SwarmCodeCLI.UI.Settings.Editors.Number,
           %{value: value, min: 0, decimals: 4, nullable: false, unit: :usd_per_m}}

        :money_null ->
          {SwarmCodeCLI.UI.Settings.Editors.Number,
           %{
             value: value,
             min: 0,
             decimals: 4,
             nullable: true,
             null_label: "derived from the input price",
             unit: :usd_per_m
           }}

        :context ->
          {SwarmCodeCLI.UI.Settings.Editors.Number,
           %{
             value: value,
             min: 8_000,
             max: 2_000_000,
             step: 1_000,
             big_step: 100_000,
             nullable: true,
             null_label: "family default"
           }}
      end

    R.row(
      id: row_id,
      kind: :field,
      key: "pricing.#{field}",
      label: label,
      value: shown,
      tag: [{"global", :text_muted}],
      lines: if(error, do: [[{R.glyph(ctx, :error) <> " " <> error, :error}]], else: []),
      marks: if(error, do: [:invalid], else: []),
      editor: editor,
      keys:
        [{"Enter", :open_row, "edit"}] ++
          if(type in [:money_null, :context],
            do: [{"r", :reset, "back to the default"}],
            else: []
          ),
      target: target
    )
  end

  # QA #2: a row as the service stores it, for a CAS `expected`: its set
  # fields only (the stored map never holds a blank one). With the blanks
  # every price edit of a row without cache rates read as a conflict.
  defp stored_row(nil), do: nil
  defp stored_row(row), do: for({k, v} <- row, v != nil, into: %{}, do: {k, v})

  defp row_wire(f) do
    %{
      "input" => R.field(f, "input"),
      "output" => R.field(f, "output"),
      "cache_read" => R.field(f, "cache_read"),
      "cache_write" => R.field(f, "cache_write"),
      "context_window" => R.field(f, "context_window")
    }
  end

  # ------------------------------------------------------------------ act

  def act(ctx, row, verb) do
    case {Map.get(row, :target), verb} do
      {{:add, model}, v} when v in [:open_row, :add] ->
        add_ops(model)

      {_, :add} ->
        add_ops(nil)

      {{:draft}, :open_row} ->
        [{:open, R.new_page(:pricing, {@kind, @draft})}]

      {{:row, model}, :open_row} ->
        open_or_delete(ctx, row, model)

      {{:row, model}, :delete} ->
        delete_ops(ctx, model)

      {{:cell, model, field, old}, :reset}
      when field in ~w(cache_read cache_write context_window) ->
        put_ops(ctx, model, old, %{field => nil})

      _ ->
        :default
    end
  end

  defp open_or_delete(ctx, %{id: "act:pricing.delete"}, model), do: delete_ops(ctx, model)
  defp open_or_delete(_ctx, _row, model), do: [{:open, R.new_page(:pricing, {@kind, model})}]

  defp add_ops(model) do
    [
      {:draft_discard, @kind},
      {:draft_put, @kind,
       %{
         "model" => model || "",
         "input" => nil,
         "output" => nil,
         "cache_read" => nil,
         "cache_write" => nil,
         "context_window" => nil
       }},
      {:open, R.new_page(:pricing, {@kind, @draft})}
    ]
  end

  defp delete_ops(ctx, model) do
    case Enum.find(R.items(ctx, "pricing_rows"), &(R.record_id(&1) == model)) do
      nil ->
        []

      rec ->
        old = row_wire(R.fields(rec))

        [
          {:command, "pricing.delete_row", %{"model" => model}, %{},
           %{
             expected: %{"row" => stored_row(old)},
             write_key: {:record, @kind, model, :delete},
             undo:
               {:command, "pricing.put_row", nil, Map.put(old, "model", model),
                %{expected: %{"row" => nil}}},
             toast: "Removed the price of #{model}"
           }}
        ] ++ if(R.page_record(ctx) == {@kind, model}, do: [:back], else: [])
    end
  end

  defp put_ops(_ctx, model, old, changes) do
    new = Map.merge(old, changes)

    if new == old do
      []
    else
      [
        {:command, "pricing.put_row", nil, Map.put(new, "model", model),
         %{
           expected: %{"row" => stored_row(old)},
           write_key: {:record, @kind, model, changes |> Map.keys() |> hd()},
           undo:
             {:command, "pricing.put_row", nil, Map.put(old, "model", model),
              %{expected: %{"row" => stored_row(new)}}},
           toast: "#{model} · #{describe(changes)}"
         }}
      ]
    end
  end

  defp describe(changes) do
    changes
    |> Enum.map(fn
      {"model", v} -> "renamed to #{v}"
      {k, nil} -> "#{words(k)} back to the default"
      {k, v} when k == "context_window" -> "#{words(k)} → #{group_digits(v)}"
      {k, v} -> "#{words(k)} → $#{R.money(v)}"
    end)
    |> Enum.join(" · ")
  end

  defp words("input"), do: "input"
  defp words("output"), do: "output"
  defp words("cache_read"), do: "cache read"
  defp words("cache_write"), do: "cache write"
  defp words("context_window"), do: "context window"
  defp words(k), do: k

  # --------------------------------------------------------------- commit

  @doc """
  A committed cell. On a saved row it writes the whole row with CAS (a model rename sends
  `rename_from`). On the draft it keeps the value in the draft until the model and both
  prices are valid, then creates the row and drops the draft.
  """
  def commit(ctx, row, value) do
    case Map.get(row, :target) do
      {:cell, model, "model", old} ->
        name = String.trim(to_string(value || ""))

        cond do
          name == "" -> [{:row_error, row.id, "can't be blank"}]
          name == model -> []
          true -> rename_ops(model, name, old)
        end

      {:cell, model, field, old} ->
        case check(field, value) do
          :ok -> put_ops(ctx, model, old, %{field => value})
          {:error, message} -> [{:row_error, row.id, message}]
        end

      {:draft_cell, field} ->
        draft_commit(ctx, field, value)

      _ ->
        :default
    end
  end

  defp rename_ops(model, name, old) do
    [
      {
        :command,
        "pricing.put_row",
        nil,
        old |> Map.put("model", name) |> Map.put("rename_from", model),
        # QA #2: `row` is the row at the new name (none yet), `rename_row` the
        # renamed one; they were swapped, and the undo had neither.
        %{
          expected: %{"row" => nil, "rename_row" => stored_row(old)},
          write_key: {:record, @kind, model, "model"},
          undo:
            {:command, "pricing.put_row", nil,
             old |> Map.put("model", model) |> Map.put("rename_from", name),
             %{expected: %{"row" => nil, "rename_row" => stored_row(old)}}},
          toast: "#{model} renamed to #{name}",
          after: {:open_record, :pricing, @kind, name}
        }
      }
    ]
  end

  defp draft_commit(ctx, field, value) do
    value = if field == "model", do: String.trim(to_string(value || "")), else: value

    case check(field, value) do
      {:error, message} ->
        [{:row_error, "fld:pricing_row:draft:#{field}", message}]

      :ok ->
        fields = Map.put(R.draft_fields(R.draft(ctx, @kind)), field, value)

        if complete?(fields) do
          model = R.field(fields, "model")

          row =
            Map.merge(
              %{"cache_read" => nil, "cache_write" => nil, "context_window" => nil},
              Map.take(fields, ~w(model input output cache_read cache_write context_window))
            )

          [
            {:command, "pricing.put_row", nil, row,
             %{
               expected: %{"row" => nil},
               write_key: {:record, @kind, model, :create},
               undo:
                 {:command, "pricing.delete_row", %{"model" => model}, %{},
                  %{expected: %{"row" => stored_row(Map.delete(row, "model"))}}},
               toast: "Priced #{model}",
               errors_to: {:draft, @kind},
               after: {:discard_draft, @kind, then: :back}
             }}
          ]
        else
          [{:draft_put, @kind, %{field => value}}]
        end
    end
  end

  defp complete?(f) do
    blank(R.field(f, "model"), nil) != nil and number?(R.field(f, "input")) and
      number?(R.field(f, "output"))
  end

  defp number?(v), do: is_number(v) and v >= 0

  @doc "The desktop's row validation of one cell (exact words, D§5)."
  def check("model", v) when is_binary(v),
    do: if(String.length(v) > 256, do: {:error, "should be at most 256 character(s)"}, else: :ok)

  def check("input", v),
    do: if(number?(v), do: :ok, else: {:error, "input: must be a number ≥ 0"})

  def check("output", v),
    do: if(number?(v), do: :ok, else: {:error, "output: must be a number ≥ 0"})

  def check("cache_read", v),
    do: if(v == nil or number?(v), do: :ok, else: {:error, "cache read: must be a number ≥ 0"})

  def check("cache_write", v),
    do: if(v == nil or number?(v), do: :ok, else: {:error, "cache write: must be a number ≥ 0"})

  def check("context_window", v) do
    if v == nil or (is_integer(v) and v >= 8_000 and v <= 2_000_000),
      do: :ok,
      else: {:error, "context window: a whole number of tokens between 8000 and 2000000"}
  end

  def check(_field, _v), do: :ok

  defp blank(nil, word), do: word
  defp blank("", word), do: word
  defp blank(v, _word), do: v
end
