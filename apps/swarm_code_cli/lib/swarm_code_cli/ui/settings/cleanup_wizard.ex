defmodule SwarmCodeCLI.UI.Settings.CleanupWizard do
  @moduledoc """
  Storage › Clean up (spec §2.18, the §4.15 *choose* sketch): steps `choose → review →
  running → done`. *Choose* has three tabs cycled with Tab/Shift-Tab (`:next_tab` /
  `:prev_tab`): **Quick** (the five measured presets; Enter goes straight to review),
  **Sessions** (the measured table: Space picks, `A` picks every deletable shown row, `s`
  cycles the sort, `/` filters; locked rows say why; a pinned row can be picked and then
  carries `include_pinned`), **Advanced** (the desktop's options; every change re-plans).
  *Review* shows the newest `storage.plan` only when it answers the draft's selection (a
  stale plan is dropped) and asks for the typed `delete N`; a vacuum-only plan needs Enter.
  *Running* reads the `storage.run` task (Esc is ignored); *done* says what came back and
  nudges VACUUM after a delete.

  The wizard's state is the `storage_cleanup` draft: `step`, `tab`, `picks`,
  `include_pinned`, `sort`, `advanced`, `selection`. Pure.
  """

  alias SwarmCodeCLI.UI.Settings.IntegrationRows, as: R

  @draft "storage_cleanup"
  @tabs ~w(quick sessions advanced)
  @sorts ~w(bytes date title)
  @sort_words %{"bytes" => "size", "date" => "date", "title" => "title"}

  @advanced [
    {"checkpoint_days", "Rewind snapshots older than", [nil, 14, 30, 90],
     "the file contents saved before an agent overwrote them"},
    {"journal_days", "Workflow journals of finished runs older than", [nil, 30, 90],
     "a finished run can no longer be replayed or resumed without them"},
    {"prune_days", "Agent details older than", [nil, 14, 30, 90],
     "keeps every transcript, token and cost — only tool output and prompts go"},
    {"research_days", "Research reports and their folders older than", [nil, 30, 90],
     "removes the row and ~/.swarmcode/research/<id>"}
  ]

  @toggles [
    {"empty_sessions", "Empty sessions", "no messages and no runs"},
    {"vacuum", "Reclaim disk space afterwards (VACUUM)", nil}
  ]

  @doc "The draft kind of the wizard."
  def draft_kind, do: @draft

  @doc "The fresh wizard state."
  def fresh do
    %{
      "step" => "choose",
      "tab" => "quick",
      "picks" => [],
      "include_pinned" => false,
      "sort" => "bytes",
      "advanced" => %{},
      "selection" => nil
    }
  end

  @doc "Opening the wizard: a fresh draft (unless one is mid-way) and the sub-page."
  def open_ops(ctx) do
    keep? = state(ctx)["step"] in ~w(choose review running) and R.draft(ctx, @draft) != nil
    put = if keep?, do: [], else: [{:draft_put, @draft, fresh()}]
    put ++ [{:open, R.new_page(:storage, nil, :cleanup)}]
  end

  @doc "The wizard state (the draft's fields over the fresh defaults)."
  def state(ctx), do: Map.merge(fresh(), R.draft_fields(R.draft(ctx, @draft)))

  @doc "What the wizard loads: the sessions table in the chosen sort."
  def loads(ctx), do: [{:records, "storage_sessions", %{"sort" => state(ctx)["sort"]}}]

  @doc "The step in effect: `running`/`done` follow the `storage.run` task."
  def step(ctx) do
    st = state(ctx)

    case {st["step"], R.task(ctx, "storage.run")} do
      {s, {_id, t}} when s in ~w(running done) ->
        if R.field(t, "state") == "running", do: "running", else: "done"

      {s, nil} when s in ~w(running done) ->
        "choose"

      {s, _} ->
        s
    end
  end

  def title(ctx) do
    case step(ctx) do
      "choose" -> "Storage › Clean up"
      "review" -> "Storage › Clean up · review"
      "running" -> "Storage › Clean up · running"
      "done" -> "Storage › Clean up · done"
    end
  end

  # ------------------------------------------------------------------ rows

  def rows(ctx) do
    case step(ctx) do
      "choose" -> choose_rows(ctx)
      "review" -> review_rows(ctx)
      "running" -> running_rows(ctx)
      "done" -> done_rows(ctx)
    end
  end

  defp tabs_row(ctx) do
    tab = state(ctx)["tab"]

    segs =
      [{"quick", "Quick"}, {"sessions", "Sessions"}, {"advanced", "Advanced"}]
      |> Enum.flat_map(fn {id, label} ->
        [
          {"[ #{label} ]", if(id == tab, do: :text_primary, else: :text_faint)},
          {"  ", :text_faint}
        ]
      end)

    R.row(
      id: "info:cleanup:tabs",
      kind: :info,
      label: "Storage › Clean up",
      value: segs,
      tag: [{"Tab", :key}, {" next tab · ", :text_faint}, {"Esc", :key}, {" back", :text_faint}],
      state: :readonly
    )
  end

  defp choose_rows(ctx) do
    st = state(ctx)

    body =
      case st["tab"] do
        "sessions" -> session_rows(ctx, st)
        "advanced" -> advanced_rows(ctx, st)
        _ -> quick_rows(ctx)
      end

    [tabs_row(ctx) | body]
  end

  defp measure(ctx) do
    case R.task(ctx, "storage.measure") do
      {id, t} ->
        if R.field(t, "state") == "done", do: R.task_summary(ctx, id) || R.field(t, "summary")

      nil ->
        nil
    end
  end

  defp quick_rows(ctx) do
    case measure(ctx) do
      nil ->
        [
          R.info(
            "cleanup:measuring",
            "◷ measuring · the presets show what they would remove when it answers",
            :text_faint
          )
        ]

      m ->
        for p <- R.field(m, "presets") || [] do
          count = R.field(p, "count") || 0
          vacuum = R.field(p, "vacuum") == true
          empty = count == 0 and not vacuum

          preview =
            cond do
              vacuum -> "at least #{R.bytes(R.field(m, "reclaimable_bytes"))} would come back"
              empty -> "nothing to remove"
              true -> "#{R.count(count, "item")} · #{R.bytes(R.field(p, "bytes"))}"
            end

          R.row(
            id: "act:cleanup.preset:#{R.field(p, "id")}",
            kind: :action,
            label: "▸ " <> R.field(p, "label"),
            value: [{preview, if(empty, do: :text_faint, else: :text_primary)}],
            lines: if(n = R.field(p, "note"), do: [[{n, :text_faint}]], else: []),
            state: if(empty, do: :disabled, else: :normal),
            keys: [{"Enter", :open_row, "review"}],
            target: {:preset, R.field(p, "selection") || %{}, empty}
          )
        end
    end
  end

  defp session_rows(ctx, st) do
    items = R.items(ctx, "storage_sessions")
    picks = MapSet.new(st["picks"])

    picked_bytes =
      items
      |> Enum.filter(&MapSet.member?(picks, R.record_id(&1)))
      |> Enum.map(&(R.field(&1, "bytes") || 0))
      |> Enum.sum()

    total = R.total(ctx, "storage_sessions") || length(items)
    filter = R.filter(ctx, {:storage, :cleanup})

    head =
      R.row(
        id: "info:cleanup:sessions",
        kind: :info,
        label: "",
        value: [
          {if(filter, do: "/ #{filter}", else: "/ Filter by title or project…"),
           if(filter, do: :text_primary, else: :text_faint)},
          {"   sort: #{@sort_words[st["sort"]]} ▾   ", :text_muted},
          {"#{MapSet.size(picks)} picked · #{R.bytes(picked_bytes)}", :text_primary}
        ],
        state: :readonly
      )

    columns =
      R.row(
        id: "info:cleanup:columns",
        kind: :info,
        label: "",
        columns: [
          {"title", :text_faint, 1},
          {"project", :text_faint, 3},
          {"updated", :text_faint, 4},
          {"size", :text_faint, 2}
        ],
        value: [],
        state: :readonly
      )

    shown = if filter, do: Enum.filter(items, &matches?(&1, filter)), else: items

    rows =
      cond do
        not R.loaded?(ctx, "storage_sessions") ->
          [R.info("cleanup:sessions:loading", "◷ measuring", :text_faint)]

        shown == [] ->
          [R.info("cleanup:sessions:none", "No session matches", :text_faint)]

        true ->
          Enum.map(shown, &session_row(ctx, &1, picks))
      end

    more =
      if total > length(items),
        do: [R.info("cleanup:more", "… #{total - length(items)} more · PgDn", :text_faint)],
        else: []

    review =
      R.row(
        id: "act:cleanup.review_sessions",
        kind: :action,
        label: "▸ Review #{R.count(MapSet.size(picks), "session")}",
        value: [{"Space pick · A pick all shown · s sort · / filter", :text_faint}],
        state: if(MapSet.size(picks) > 0, do: :normal, else: :disabled),
        keys: [{"Enter", :open_row, "review"}],
        target: {:review, :sessions}
      )

    [head, columns] ++ rows ++ more ++ [review]
  end

  defp matches?(s, filter) do
    q = String.downcase(filter)
    String.contains?(String.downcase("#{R.field(s, "title")} #{R.field(s, "project")}"), q)
  end

  defp session_row(ctx, s, picks) do
    id = R.record_id(s) || R.field(s, "id")
    picked = MapSet.member?(picks, id)
    locked = R.field(s, "deletable") != true
    pinned = R.field(s, "pinned") == true
    tick = if picked, do: R.glyph(ctx, :ticked), else: R.glyph(ctx, :unticked)
    title = if pinned, do: "pinned: #{R.field(s, "title")}", else: R.field(s, "title")

    tag =
      cond do
        locked -> [{"locked · #{reason(s)}", :text_muted}]
        pinned and picked -> [{"pinned — picked by you", :text_muted}]
        pinned -> [{"pinned — Space picks it anyway", :text_faint}]
        true -> []
      end

    R.row(
      id: "item:session:#{id}",
      kind: :list_item,
      label: title,
      value: [{"#{tick} #{title}", if(locked, do: :text_muted, else: :text_primary)}],
      columns: [
        {"#{tick} #{title}", :text_primary, 1},
        {R.field(s, "project") || "", :text_muted, 3},
        {R.field(s, "updated_at") || "", :text_muted, 4},
        {R.bytes(R.field(s, "bytes")), :text_primary, 2}
      ],
      tag: tag,
      state: if(locked, do: :disabled, else: :normal),
      keys: [
        {"Space", :toggle, "pick"},
        {"A", :all_on, "pick all shown"},
        {"s", :alt, "sort"},
        {"Enter", :open_row, "review"}
      ],
      target: {:session, id, pinned, locked}
    )
  end

  defp reason(s) do
    cond do
      R.field(s, "running") == true -> "A run of this session is still going"
      R.field(s, "open") == true -> "open in this terminal"
      is_binary(R.field(s, "reason")) -> R.field(s, "reason")
      true -> "Cannot be deleted"
    end
  end

  defp advanced_rows(ctx, st) do
    adv = st["advanced"]
    reclaimable = measure(ctx) && R.field(measure(ctx), "reclaimable_bytes")

    enums =
      for {field, label, choices, hint} <- @advanced do
        value = Map.get(adv, field)

        R.row(
          id: "fld:cleanup:#{field}",
          kind: :field,
          label: label,
          value: [{days_words(value), if(value, do: :text_primary, else: :text_faint)}],
          lines: [[{hint, :text_faint}]],
          editor:
            {SwarmCodeCLI.UI.Settings.Editors.Enum,
             %{
               value: value,
               choices: Enum.map(choices, &%{value: &1, label: days_words(&1), hint: nil})
             }},
          keys: [{"←→", :step, "change"}, {"Enter", :open_row, "choose"}],
          target: {:advanced, field, choices}
        )
      end

    toggles =
      for {field, label, hint} <- @toggles do
        on = Map.get(adv, field) == true
        hint = hint || "at least #{R.bytes(reclaimable)} would come back; deletes nothing"

        R.row(
          id: "fld:cleanup:#{field}",
          kind: :field,
          label: label,
          value: [
            {"#{if on, do: R.glyph(ctx, :ticked), else: R.glyph(ctx, :unticked)} #{if on, do: "on", else: "off"}",
             :text_primary}
          ],
          lines: [[{hint, :text_faint}]],
          keys: [{"Space", :toggle, "switch"}],
          target: {:advanced_toggle, field}
        )
      end

    plan = plan_words(ctx, advanced_selection(adv))

    enums ++
      toggles ++
      [
        R.row(
          id: "act:cleanup.review_advanced",
          kind: :action,
          label: "▸ Review",
          value: plan,
          state: if(advanced_selection(adv) == %{}, do: :disabled, else: :normal),
          keys: [{"Enter", :open_row, "review"}],
          target: {:review, :advanced}
        )
      ]
  end

  defp days_words(nil), do: "off"
  defp days_words(n), do: "#{n} days"

  defp advanced_selection(adv) do
    adv
    |> Enum.reject(fn {_k, v} -> v in [nil, false] end)
    |> Map.new()
  end

  defp plan_words(ctx, selection) do
    cond do
      selection == %{} ->
        [{"choose at least one option", :text_faint}]

      true ->
        case plan(ctx, selection) do
          {:ready, _id, s} ->
            [
              {"#{R.count(R.field(s, "total_count") || 0, "item")} · #{R.bytes(R.field(s, "total_bytes"))}",
               :text_primary}
            ]

          {:running, _} ->
            [{R.glyph(ctx, :running) <> " planning", :info}]

          _ ->
            [{"not planned yet", :text_faint}]
        end
    end
  end

  @doc """
  The plan for `selection`: `{:ready, plan_id, summary}` when the newest `storage.plan`
  answered this selection, `{:running, task_id}` while it plans, `{:failed, message}`, or
  `:none` (no plan, or only a stale one — dropped).
  """
  def plan(ctx, selection) do
    case R.task(ctx, "storage.plan") do
      nil ->
        :none

      {id, t} ->
        attrs = R.field(t, "attributes")
        asked = attrs && R.field(attrs, "selection")

        cond do
          asked != nil and asked != selection -> :none
          R.field(t, "state") == "running" -> {:running, id}
          R.field(t, "state") == "done" -> ready(ctx, id, t)
          true -> {:failed, R.field(t, "message") || "planning failed"}
        end
    end
  end

  defp ready(ctx, id, t) do
    s = R.task_summary(ctx, id) || R.field(t, "summary") || %{}
    if R.field(s, "plan_id") in [nil, id], do: {:ready, id, s}, else: :none
  end

  defp review_rows(ctx) do
    st = state(ctx)
    selection = st["selection"] || %{}

    head =
      R.row(
        id: "info:cleanup:review",
        kind: :info,
        label: "Storage › Clean up · review",
        value: [{"Esc", :key}, {" back to choose", :text_faint}],
        state: :readonly
      )

    body =
      case plan(ctx, selection) do
        {:running, _} ->
          [
            R.info(
              "cleanup:planning",
              R.glyph(ctx, :running) <> " planning what this would remove",
              :info
            )
          ]

        {:failed, m} ->
          [R.info("cleanup:plan_failed", R.glyph(ctx, :error) <> " " <> m, :error)]

        :none ->
          [
            R.info(
              "cleanup:planning",
              R.glyph(ctx, :running) <> " planning what this would remove",
              :info
            )
          ]

        {:ready, id, s} ->
          plan_rows(ctx, id, s, selection)
      end

    [head | body]
  end

  defp plan_rows(ctx, plan_id, s, selection) do
    items = R.field(s, "items") || []
    count = R.field(s, "total_count") || Enum.sum(Enum.map(items, &(R.field(&1, "count") || 0)))
    vacuum = R.field(s, "vacuum") == true

    item_rows =
      Enum.with_index(items, fn i, n ->
        R.row(
          id: "info:plan:#{n}",
          kind: :info,
          label: "",
          value: [
            {"#{R.field(i, "count")}", :text_primary},
            {" · #{R.field(i, "label")} · ", :text_muted},
            {R.bytes(R.field(i, "bytes")), :text_primary}
          ],
          state: :readonly
        )
      end)

    kept =
      for k <- R.field(s, "skipped") || [] do
        R.row(
          id: "info:kept:#{R.field(k, "reason")}",
          kind: :info,
          label: "",
          value: [
            {"kept back · #{R.count(R.field(k, "count") || 0, "session")} · #{R.field(k, "reason")}",
             :text_muted}
          ],
          state: :readonly
        )
      end

    prune_note =
      if Map.has_key?(selection, "prune_days"),
        do: [
          R.info(
            "cleanup:prune_note",
            "Pruning keeps every transcript: a run keeps its tokens, cost and timings, and only the tool output and prompts are dropped.",
            :text_faint
          )
        ],
        else: []

    cond do
      items == [] and not vacuum ->
        [R.info("cleanup:empty", "There is nothing to remove.")] ++ kept

      items == [] and vacuum ->
        [
          R.info(
            "cleanup:vacuum_only",
            "Nothing is deleted. SQLite rewrites the database file so the space deleted rows left behind comes back to the disk. It can take a minute on a large file."
          ),
          R.row(
            id: "act:cleanup.run",
            kind: :action,
            label: "▸ Reclaim disk space (VACUUM)",
            value: [{"Enter", :key}, {" starts it", :text_faint}],
            keys: [{"Enter", :open_row, "start"}],
            target: {:run, plan_id, nil}
          )
        ] ++ kept

      true ->
        item_rows ++
          kept ++
          [
            R.row(
              id: "info:cleanup:warning",
              kind: :info,
              label: "",
              value: [
                {"! This cannot be undone. Deleted sessions, snapshots and reports are gone for good.",
                 :warning}
              ],
              state: :readonly
            )
          ] ++
          prune_note ++
          [
            R.row(
              id: "act:cleanup.confirm",
              kind: :action,
              label: "type delete #{count} and Enter",
              value:
                [
                  {"#{R.count(count, "item")} · #{R.bytes(R.field(s, "total_bytes"))}",
                   :text_primary}
                ] ++ if(vacuum, do: [{" · then VACUUM", :text_faint}], else: []),
              lines: error_lines(ctx, "act:cleanup.confirm"),
              editor:
                {SwarmCodeCLI.UI.Settings.Editors.Text,
                 %{value: "", max: 32, placeholder: "delete #{count}"}},
              keys: [{"Enter", :open_row, "type"}],
              target: {:run, plan_id, count}
            )
          ]
    end
  end

  defp running_rows(ctx) do
    {_id, t} = R.task(ctx, "storage.run")
    p = R.field(t, "progress") || %{}
    done = R.field(p, "done") || 0
    total = R.field(p, "total") || 0
    freed = R.field(p, "freed_bytes") || 0
    step = R.field(p, "step")

    words =
      "#{R.glyph(ctx, :running)} deleting #{done} of #{total} · #{R.bytes(freed)} freed" <>
        if(step, do: " · #{step}", else: "")

    [
      R.row(
        id: "info:cleanup:running",
        kind: :info,
        label: "Storage › Clean up",
        value: [{words, :info}],
        tag: [{"can't be stopped", :text_faint}],
        state: :running
      )
    ]
  end

  defp done_rows(ctx) do
    {id, t} = R.task(ctx, "storage.run")
    s = R.task_summary(ctx, id) || R.field(t, "summary") || %{}
    freed = R.field(s, "freed_bytes") || 0
    items = R.field(s, "items") || 0
    vacuum = R.field(s, "vacuum")

    headline =
      cond do
        R.field(t, "state") != "done" ->
          R.glyph(ctx, :error) <> " " <> to_string(R.field(t, "message") || "the cleanup failed")

        items > 0 ->
          "Freed #{R.bytes(freed)} from #{R.count(items, "item")}."

        is_map(vacuum) ->
          "Reclaimed #{R.bytes(R.field(vacuum, "before") - R.field(vacuum, "after"))} of disk space."

        true ->
          "Nothing was removed."
      end

    vacuum_line =
      if is_map(vacuum),
        do: [
          R.info(
            "cleanup:vacuum",
            "The database file went from #{R.bytes(R.field(vacuum, "before"))} to #{R.bytes(R.field(vacuum, "after"))}."
          )
        ],
        else: []

    nudge =
      if items > 0 and vacuum == nil do
        [
          R.info(
            "cleanup:nudge",
            "The database file is still #{R.bytes(R.field(s, "db_bytes_after"))} — SQLite keeps deleted space for reuse until the file is compacted. At least #{R.bytes(R.field(s, "reclaimable_after"))} would come back."
          ),
          R.row(
            id: "act:storage.vacuum",
            kind: :action,
            label: "▸ Reclaim disk space (VACUUM)",
            value: [{"compacts the file; deletes nothing", :text_faint}],
            keys: [{"Enter", :open_row, "start"}],
            target: {:vacuum}
          )
        ]
      else
        []
      end

    [
      R.row(
        id: "info:cleanup:done",
        kind: :info,
        label: "Storage › Clean up",
        value: [{headline, :text_primary}],
        state: :readonly
      )
    ] ++
      vacuum_line ++
      nudge ++
      [
        R.row(
          id: "act:cleanup.finish",
          kind: :action,
          label: "▸ Back to Storage",
          value: [{"the overview measures again", :text_faint}],
          keys: [{"Enter", :open_row, "back"}],
          target: {:finish}
        )
      ]
  end

  defp error_lines(ctx, row_id) do
    case R.row_error(ctx, row_id) do
      nil -> []
      m -> [[{R.glyph(ctx, :error) <> " " <> m, :error}]]
    end
  end

  # ------------------------------------------------------------------- act

  def act(ctx, row, verb) do
    st = state(ctx)
    target = Map.get(row, :target)

    case {step(ctx), target, verb} do
      {"running", _, v} when v in [:escape, :leave] ->
        []

      {"running", _, _} ->
        [{:toast, "A cleanup can't be stopped", :info}]

      {"done", _, :escape} ->
        finish_ops()

      {"done", {:finish}, :open_row} ->
        finish_ops()

      {"done", {:vacuum}, :open_row} ->
        [{:task, "storage.vacuum", nil, %{}}]

      {"review", _, :escape} ->
        put(st, %{"step" => "choose"})

      {"review", {:run, plan_id, nil}, :open_row} ->
        run_ops(st, plan_id)

      {"review", {:run, _plan_id, _n}, :open_row} ->
        [{:edit, "act:cleanup.confirm"}]

      {"choose", _, :next_tab} ->
        put(st, %{"tab" => cycle(@tabs, st["tab"], 1)})

      {"choose", _, :prev_tab} ->
        put(st, %{"tab" => cycle(@tabs, st["tab"], -1)})

      {"choose", _, :escape} ->
        :default

      {"choose", {:preset, _sel, true}, :open_row} ->
        [{:toast, "nothing to remove", :info}]

      {"choose", {:preset, sel, false}, :open_row} ->
        review_ops(st, sel)

      {"choose", {:session, _id, _p, true}, :toggle} ->
        [{:toast, "locked · #{locked_reason(ctx, target)}", :info}]

      {"choose", {:session, id, pinned, false}, :toggle} ->
        toggle_pick(st, id, pinned)

      {"choose", {:session, _, _, _}, :all_on} ->
        pick_all(ctx, st)

      {"choose", {:session, _, _, _}, :alt} ->
        sort_ops(st)

      {"choose", {:session, _, _, _}, :open_row} ->
        sessions_review(st)

      {"choose", {:review, :sessions}, :open_row} ->
        sessions_review(st)

      {"choose", {:advanced_toggle, field}, v} when v in [:toggle, :open_row] ->
        advanced_ops(st, field, Map.get(st["advanced"], field) != true)

      {"choose", {:advanced, field, choices}, :step} ->
        advanced_ops(st, field, cycle(choices, Map.get(st["advanced"], field), 1))

      {"choose", {:review, :advanced}, :open_row} ->
        advanced_review(ctx, st)

      _ ->
        :default
    end
  end

  defp locked_reason(ctx, {:session, id, _, _}) do
    case Enum.find(R.items(ctx, "storage_sessions"), &(R.record_id(&1) == id)) do
      nil -> "Cannot be deleted"
      s -> reason(s)
    end
  end

  defp cycle(list, current, dir) do
    i = Enum.find_index(list, &(&1 == current)) || 0
    Enum.at(list, rem(i + dir + length(list), length(list)))
  end

  defp put(st, changes), do: [{:draft_put, @draft, Map.merge(st, changes)}]

  defp plan_op(selection),
    do: {:task, "storage.plan", %{"slot" => "wizard"}, %{"selection" => selection}}

  defp review_ops(st, selection),
    do: put(st, %{"step" => "review", "selection" => selection}) ++ [plan_op(selection)]

  defp toggle_pick(st, id, pinned) do
    picks = st["picks"]

    picks = if id in picks, do: List.delete(picks, id), else: picks ++ [id]
    include = st["include_pinned"] or (pinned and id in picks)
    put(st, %{"picks" => picks, "include_pinned" => include})
  end

  defp pick_all(ctx, st) do
    filter = R.filter(ctx, {:storage, :cleanup})

    shown =
      for s <- R.items(ctx, "storage_sessions"),
          filter == nil or matches?(s, filter),
          R.field(s, "deletable") == true,
          R.field(s, "pinned") != true,
          do: R.record_id(s)

    picks =
      if shown != [] and Enum.all?(shown, &(&1 in st["picks"])),
        do: st["picks"] -- shown,
        else: Enum.uniq(st["picks"] ++ shown)

    put(st, %{"picks" => picks})
  end

  defp sort_ops(st) do
    sort = cycle(@sorts, st["sort"], 1)
    put(st, %{"sort" => sort}) ++ [{:load, {:records, "storage_sessions", %{"sort" => sort}}}]
  end

  defp sessions_review(%{"picks" => []}),
    do: [{:toast, "Pick at least one session (Space)", :info}]

  defp sessions_review(st) do
    selection = %{"session_ids" => st["picks"]}

    selection =
      if st["include_pinned"], do: Map.put(selection, "include_pinned", true), else: selection

    review_ops(st, selection)
  end

  defp advanced_ops(st, field, value) do
    adv = Map.put(st["advanced"], field, value)
    selection = advanced_selection(adv)
    ops = put(st, %{"advanced" => adv})
    if selection == %{}, do: ops, else: ops ++ [plan_op(selection)]
  end

  defp advanced_review(ctx, st) do
    case advanced_selection(st["advanced"]) do
      sel when sel == %{} ->
        [{:toast, "Choose at least one option", :info}]

      sel ->
        replan = if plan(ctx, sel) == :none, do: [plan_op(sel)], else: []
        put(st, %{"step" => "review", "selection" => sel}) ++ replan
    end
  end

  defp run_ops(st, plan_id),
    do: put(st, %{"step" => "running"}) ++ [{:task, "storage.run", nil, %{"plan_id" => plan_id}}]

  defp finish_ops, do: [{:draft_discard, @draft}, :back, {:task, "storage.measure", nil, %{}}]

  @doc "The typed confirmation and the Advanced enums."
  def commit(ctx, row, value) do
    st = state(ctx)

    case Map.get(row, :target) do
      {:run, plan_id, n} when is_integer(n) ->
        if String.trim(to_string(value)) == "delete #{n}",
          do: run_ops(st, plan_id),
          else: [{:row_error, row.id, "type delete #{n} to go on; Esc keeps everything"}]

      {:advanced, field, choices} ->
        if value in choices,
          do: advanced_ops(st, field, value),
          else: [{:row_error, row.id, "is invalid"}]

      _ ->
        :default
    end
  end
end
