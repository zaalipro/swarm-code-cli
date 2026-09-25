defmodule SwarmCodeCLI.UI.Settings.Sections.C74StorageTest do
  use ExUnit.Case, async: true

  alias SwarmCodeCLI.UI.DataSource.Fake.SettingsIntegrations, as: I
  alias SwarmCodeCLI.UI.Settings.CleanupWizard, as: W
  alias SwarmCodeCLI.UI.Settings.Sections.Storage
  alias SwarmCodeCLI.Test.C74U2Tasks, as: T
  import SwarmCodeCLI.Test.C74U2Ctx
  alias SwarmCodeCLI.Test.C74U2Ctx.Page

  defp row(rows, id),
    do:
      Enum.find(rows, &(&1.id == id)) ||
        flunk("no row #{id}: #{inspect(Enum.map(rows, & &1.id))}")

  defp measured(opts \\ []) do
    {state, id, task, rows} = T.run(I.seed(), "storage.measure", nil, %{}, :run, "m-1")

    ctx(state,
      kinds: ["storage_sessions"],
      page: Keyword.get(opts, :page, Page.at(:storage)),
      layer: Keyword.get(opts, :layer, [])
    )
    |> T.put(id, task, rows)
    |> Map.put(:state, state)
  end

  defp wizard(fields, extra_layer \\ []) do
    c =
      measured(
        page: Page.at(:storage, nil, :cleanup),
        layer:
          [drafts: %{"storage_cleanup" => %{fields: Map.merge(W.fresh(), fields)}}] ++ extra_layer
      )

    c
  end

  # applies the draft ops of a result to the context, as the reducer would
  defp apply_ops(c, ops) do
    Enum.reduce(ops, c, fn
      {:draft_put, kind, fields}, acc ->
        update_in(acc, [:layer, :drafts], &Map.put(&1, kind, %{fields: fields}))

      _, acc ->
        acc
    end)
  end

  defp plan(c, selection, task_id) do
    {state, id, task, rows} =
      T.run(
        c.state,
        "storage.plan",
        %{"slot" => "wizard"},
        %{"selection" => selection},
        :run,
        task_id
      )

    task = Map.put(task, :attributes, %{"selection" => selection})
    c |> T.put(id, task, rows) |> Map.put(:state, state)
  end

  test "the page measures on open once, then shows the overview and the actions" do
    assert {:auto_task, "storage.measure", nil} in Storage.loads(ctx())
    c = measured()
    refute {:auto_task, "storage.measure", nil} in Storage.loads(c)
    rows = Storage.rows(c)

    assert text(row(rows, "info:storage:intro").value) =~ "Nothing here touches your projects."

    assert text(row(rows, "info:storage:line").value) ==
             "1.8 GB on disk · 4 MB write-ahead log · at least 100 MB reclaimable · 2 isolation directories (30 MB) · 214 sessions"

    assert text(row(rows, "info:storage:kind:agent_details").value) == "4120 · 910 MB"
    # cli74 F19: the stored UTC stamp in this machine's local time.
    local =
      {{2026, 9, 13}, {9, 0, 0}}
      |> :calendar.universal_time_to_local_time()
      |> NaiveDateTime.from_erl!()
      |> Calendar.strftime("%d %b %Y %H:%M")

    assert text(row(rows, "fact:storage.last_sweep").value) == local
    assert row(rows, "act:storage.apply_retention").state == :disabled
    assert text(row(rows, "act:storage.apply_retention").value) == "set a retention first"
    assert row(rows, "act:storage.measure").label == "▸ Re-measure"
  end

  test "retention rows: quick picks step, typed days validate, r turns off" do
    c = measured()
    r = row(Storage.rows(c), "key:storage.retention_days")
    assert text(r.tag) == "quick: Off · 30 · 60 · 90 · 180"
    assert [{:patch, "storage.retention_days", 30}] = Storage.act(c, r, :step)
    assert [{:patch, "storage.retention_days", 45}] = Storage.commit(c, r, "45")
    assert [{:row_error, _, "must be between 7 and 3650"}] = Storage.commit(c, r, "3")
    assert [] = Storage.commit(c, r, "off")

    c =
      put_in(c, [:data, :values, "storage.prune_days"], %{
        key: "storage.prune_days",
        value: 90,
        state: "ok"
      })

    p = row(Storage.rows(c), "key:storage.prune_days")
    assert [{:patch, "storage.prune_days", nil}] = Storage.act(c, p, :step)
    assert [{:patch, "storage.prune_days", nil}] = Storage.act(c, p, :reset)
    assert row(Storage.rows(c), "act:storage.apply_retention").state == :normal
  end

  test "the choose sketch: tabs, filter hint, sort, picks with locked and pinned rows" do
    ids = ["5e550000-0000-4000-8000-000000000001", "5e550000-0000-4000-8000-000000000004"]
    c = wizard(%{"tab" => "sessions", "picks" => ids, "include_pinned" => true})
    rows = W.rows(c)

    assert text(row(rows, "info:cleanup:tabs").value) =~ "[ Quick ]  [ Sessions ]  [ Advanced ]"

    assert text(row(rows, "info:cleanup:sessions").value) ==
             "/ Filter by title or project…   sort: size ▾   2 picked · 432 MB"

    assert text(row(rows, "item:session:#{hd(ids)}").value) == "[✓] Refactor the parser (old)"

    open = row(rows, "item:session:5e550000-0000-4000-8000-000000000003")
    assert text(open.tag) == "locked · open in this terminal"
    assert [{:toast, "locked · open in this terminal", :info}] = W.act(c, open, :toggle)

    pinned = row(rows, "item:session:5e550000-0000-4000-8000-000000000004")
    assert pinned.label == "pinned: Release checklist"
    assert text(pinned.tag) == "pinned — picked by you"

    [{:draft_put, _, f}, {:load, {:records, "storage_sessions", %{"sort" => "date"}}}] =
      W.act(c, pinned, :alt)

    assert f["sort"] == "date"

    [{:draft_put, _, f}] =
      W.act(c, row(rows, "item:session:5e550000-0000-4000-8000-000000000002"), :toggle)

    assert length(f["picks"]) == 3

    [{:draft_put, _, f}] = W.act(c, pinned, :all_on)
    refute "5e550000-0000-4000-8000-000000000003" in f["picks"]
    refute "5e550000-0000-4000-8000-000000000005" in f["picks"]

    [{:draft_put, _, f}, {:task, "storage.plan", %{"slot" => "wizard"}, %{"selection" => sel}}] =
      W.act(c, row(rows, "act:cleanup.review_sessions"), :open_row)

    assert f["step"] == "review"
    assert sel == %{"session_ids" => ids, "include_pinned" => true}
  end

  test "Tab cycles the tabs; a Quick preset goes straight to review" do
    c = wizard(%{})
    rows = W.rows(c)
    [{:draft_put, _, f}] = W.act(c, hd(rows), :next_tab)
    assert f["tab"] == "sessions"
    [{:draft_put, _, f}] = W.act(c, hd(rows), :prev_tab)
    assert f["tab"] == "advanced"

    older = row(rows, "act:cleanup.preset:older_30")
    assert text(older.lines |> hd()) == "everything they hold goes with them"

    [{:draft_put, _, f}, {:task, "storage.plan", _, %{"selection" => %{"older_than_days" => 30}}}] =
      W.act(c, older, :open_row)

    assert f["step"] == "review"
  end

  test "each Advanced change re-plans; a stale plan is dropped" do
    c = wizard(%{"tab" => "advanced"})
    rows = W.rows(c)

    [{:draft_put, _, f}, {:task, "storage.plan", _, %{"selection" => %{"checkpoint_days" => 14}}}] =
      W.act(c, row(rows, "fld:cleanup:checkpoint_days"), :step)

    [{:draft_put, _, f2}, {:task, "storage.plan", _, %{"selection" => sel2}}] =
      W.commit(
        apply_ops(c, [{:draft_put, "storage_cleanup", f}]),
        row(rows, "fld:cleanup:journal_days"),
        30
      )

    assert sel2 == %{"checkpoint_days" => 14, "journal_days" => 30}

    c =
      apply_ops(c, [
        {:draft_put, "storage_cleanup",
         Map.put(f2, "step", "review") |> Map.put("selection", sel2)}
      ])

    stale = plan(c, %{"checkpoint_days" => 14}, "p-1")
    assert W.plan(stale, sel2) == :none
    assert text(row(W.rows(stale), "info:cleanup:planning").value) =~ "planning"

    fresh = plan(c, sel2, "p-2")
    assert {:ready, "p-2", _} = W.plan(fresh, sel2)
    assert row(W.rows(fresh), "act:cleanup.confirm").label == "type delete 392 and Enter"
  end

  test "review needs the typed delete N; Esc goes back; running ignores Esc; done nudges VACUUM" do
    sel = %{"older_than_days" => 30}
    c = wizard(%{"step" => "review", "selection" => sel}) |> plan(sel, "p-1")
    rows = W.rows(c)
    confirm = row(rows, "act:cleanup.confirm")
    assert confirm.label =~ ~r/^type delete \d+ and Enter$/
    n = confirm.label |> String.split() |> Enum.at(2)
    assert Enum.any?(rows, &(text(&1.value) =~ "This cannot be undone."))

    assert Enum.any?(
             rows,
             &(text(&1.value) =~
                 "kept back · 1 session · pinned — pick it in Sessions to include it")
           )

    assert [{:edit, "act:cleanup.confirm"}] = W.act(c, confirm, :open_row)
    assert [{:row_error, _, _}] = W.commit(c, confirm, "delete")

    [{:draft_put, _, f}, {:task, "storage.run", nil, %{"plan_id" => "p-1"}}] =
      W.commit(c, confirm, "delete #{n}")

    assert f["step"] == "running"
    [{:draft_put, _, back}] = W.act(c, confirm, :escape)
    assert back["step"] == "choose"

    running =
      apply_ops(c, [{:draft_put, "storage_cleanup", f}])
      |> put_task("r-1", %{
        action: "storage.run",
        target: nil,
        state: "running",
        cancellable: false,
        progress: %{
          "done" => 2,
          "total" => 5,
          "freed_bytes" => 402_000_000,
          "step" => "deleting sessions"
        }
      })

    [r] = W.rows(running)
    assert text(r.value) == "◷ deleting 2 of 5 · 402 MB freed · deleting sessions"
    assert text(r.tag) == "can't be stopped"
    assert [] = W.act(running, r, :escape)

    {state, id, task, trows} =
      T.run(c.state, "storage.run", nil, %{"plan_id" => "p-1"}, :run, "r-1")

    done =
      apply_ops(c, [{:draft_put, "storage_cleanup", f}])
      |> T.put(id, task, trows)
      |> Map.put(:state, state)

    rows = W.rows(done)
    assert text(row(rows, "info:cleanup:done").value) =~ ~r/^Freed .+ from \d+ items\.$/
    assert text(row(rows, "info:cleanup:nudge").value) =~ "SQLite keeps deleted space for reuse"

    assert [{:task, "storage.vacuum", nil, %{}}] =
             W.act(done, row(rows, "act:storage.vacuum"), :open_row)

    assert [{:draft_discard, "storage_cleanup"}, :back, {:task, "storage.measure", nil, %{}}] =
             W.act(done, hd(rows), :escape)
  end

  test "a vacuum-only plan needs Enter only; an empty plan says so" do
    sel = %{"vacuum" => true}
    c = wizard(%{"step" => "review", "selection" => sel}) |> plan(sel, "p-v")
    rows = W.rows(c)
    assert text(row(rows, "info:cleanup:vacuum_only").value) =~ "Nothing is deleted."

    assert [{:draft_put, _, _}, {:task, "storage.run", nil, %{"plan_id" => "p-v"}}] =
             W.act(c, row(rows, "act:cleanup.run"), :open_row)

    sel = %{"session_ids" => ["5e550000-0000-4000-8000-000000000003"]}
    c = wizard(%{"step" => "review", "selection" => sel}) |> plan(sel, "p-e")
    assert Enum.any?(W.rows(c), &(&1.id == "info:cleanup:empty"))
  end
end
