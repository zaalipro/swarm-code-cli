defmodule SwarmCode.Daemon.Service.Settings.C74StorageTest do
  @moduledoc "pass 74 S2-9: storage in settings (§3.5.5)."
  use ExUnit.Case, async: false

  @moduletag :capture_log

  import Ecto.Query

  alias SwarmCode.Daemon.Service.Settings.Storage
  alias SwarmCode.Domain.{Conversations, Repo, Settings, UIState}
  alias SwarmCode.Domain.Conversations.Conversation
  alias SwarmCode.Test.C74S2

  setup do
    fx = C74S2.repo!("c74-storage")
    data = C74S2.appendix_a!(fx)
    old = DateTime.add(DateTime.utc_now(), -40 * 86_400, :second)

    olds =
      for title <- ["Old spike", "Old notes", "Old but open"] do
        {:ok, conv} = Conversations.create(data.ailogic.id)
        {:ok, conv} = Conversations.update(conv, %{title: title})

        from(c in Conversation, where: c.id == ^conv.id)
        |> Repo.update_all(set: [updated_at: old])

        conv
      end

    # the TUI's own conversation is open (§3.3.10: UIState.opened/1)
    open = List.last(olds)
    UIState.opened(open.id)
    :sys.get_state(UIState)

    Map.merge(data, %{
      olds: olds,
      open: open,
      ctx: C74S2.context(data.ailogic, data.conversation)
    })
  end

  defp task(action, c, opts \\ []), do: Storage.command(C74S2.command(action, opts), c.ctx)

  defp measure!(c) do
    {:task, spec, _} = task("storage.measure", c)
    assert spec.timeout_ms == 120_000 and spec.cancellable?
    {:ok, result} = C74S2.run_task(spec)
    result
  end

  defp exists?(conv), do: Repo.get(Conversation, conv.id) != nil

  defp planned(c, selection, store \\ nil) do
    {:task, spec, _} =
      Storage.command(
        C74S2.command("storage.plan", attributes: %{"selection" => selection}),
        %{c.ctx | sessions_store: store}
      )

    assert spec.key == :wizard
    {:ok, result} = C74S2.run_task(spec)
    result
  end

  defp run_ctx(c, plan_result) do
    %{
      c.ctx
      | task_results: %{
          {"storage.plan", :wizard} => C74S2.task_entry("plan-1", "done", plan_result)
        }
    }
  end

  describe "measure and the sessions page" do
    test "the measure has the overview, previews and the sessions store rows", c do
      result = measure!(c)
      assert result["overview"]["sessions"] == 6

      assert Enum.map(result["presets"], & &1["key"]) ==
               ~w(older_30 keep_14 prune_14 checkpoints_30 vacuum)

      older_30 = hd(result["presets"])
      assert [%{"label" => "Sessions", "count" => 2}] = older_30["preview"]["items"]
      assert [%{"reason" => "open", "count" => 1}] = older_30["preview"]["skipped"]
      assert length(result["sessions"]) == 6

      for row <- result["sessions"],
          do: C74S2.declared!(%{"kind" => "storage_session", "fields" => row})

      open = Enum.find(result["sessions"], &(&1["id"] == c.open.id))
      assert open["open"] and open["reason"] == "open" and not open["deletable"]

      {:task, spec, _} = task("storage.measure", c)
      summary = spec.summary.(result)
      # the sessions stay in the backend's store; the page reads the numbers
      # at the top and each preset's totals (cli74 F)
      refute is_list(summary["sessions"])
      assert summary["db_bytes"] == result["overview"]["db_bytes"]
      assert length(summary["kinds"]) == length(result["overview"]["kinds"])
      assert Enum.all?(summary["kinds"], &(&1["kind"] == &1["key"]))

      assert %{"id" => "older_30", "label" => _, "count" => 2, "vacuum" => false} =
               hd(summary["presets"])
    end

    test "records page the store: no store → measure first; sort, filter, pages", c do
      assert {:error, %{code: :not_found, message: "measure first"}} =
               Storage.query("records", "storage_sessions", %{}, c.ctx)

      store = measure!(c)["sessions"]
      ctx = %{c.ctx | sessions_store: store}

      {:ok, page} =
        Storage.query(
          "records",
          "storage_sessions",
          %{"options" => %{"filter" => "OLD", "sort" => "title"}},
          ctx
        )

      C74S2.declared!(page)

      assert Enum.map(page["items"], & &1["fields"]["title"]) == [
               "Old but open",
               "Old notes",
               "Old spike"
             ]

      {:ok, by_project} =
        Storage.query("records", "storage_sessions", %{"options" => %{"filter" => "notes"}}, ctx)

      assert Enum.map(by_project["items"], & &1["fields"]["title"]) |> Enum.sort() ==
               ["Old notes", "Sketch the release notes"]

      {:ok, first} = Storage.query("records", "storage_sessions", %{"page_size" => 4}, ctx)
      assert length(first["items"]) == 4 and first["next_cursor"] == "4" and first["total"] == 6
    end
  end

  describe "plan and run" do
    test "a plan over the measured sessions keeps the open one back", c do
      store = measure!(c)["sessions"]
      result = planned(c, %{"older_than_days" => 30}, store)

      assert result["rows"] == [
               %{"label" => "Sessions", "count" => 2, "bytes" => result["total_bytes"]}
             ]

      assert result["skipped"] == [%{"reason" => "open", "count" => 1}]

      assert result["plan"]["session_ids"] |> Enum.sort() ==
               c.olds |> Enum.take(2) |> Enum.map(& &1.id) |> Enum.sort()

      assert {:error, %{message: "flavour is not a cleanup choice"}} =
               task("storage.plan", c, attributes: %{"selection" => %{"flavour" => 1}})
    end

    test "run: subscribed first, progress reported, the sessions deleted", c do
      plan = planned(c, %{"older_than_days" => 30})

      {:task, spec, _} =
        Storage.command(
          C74S2.command("storage.run", attributes: %{"plan_id" => "plan-1"}),
          run_ctx(c, plan)
        )

      refute spec.cancellable?
      assert spec.timeout_ms == 1_800_000

      assert {:ok, %{"items" => 2, "freed_bytes" => freed, "vacuum" => nil}} =
               C74S2.run_task(spec)

      assert is_integer(freed)
      assert_received {:progress, %{"step" => "Sessions", "total" => 2}}

      refute exists?(Enum.at(c.olds, 0)) or exists?(Enum.at(c.olds, 1))
      assert exists?(c.open) and exists?(c.conversation)

      assert {:error, %{code: :not_found}} =
               Storage.command(
                 C74S2.command("storage.run", attributes: %{"plan_id" => "gone"}),
                 c.ctx
               )
    end
  end

  describe "retention and vacuum" do
    test "no policy is rejected; a policy deletes old sessions and stamps the sweep", c do
      {:ok, rejected} = task("storage.apply_retention", c)
      assert rejected.status == :rejected and rejected.message == "set a retention first"

      {:ok, _} = Settings.update(%{storage_retention_days: 30})
      {:task, spec, _} = task("storage.apply_retention", c)
      refute spec.cancellable?
      assert {:ok, %{"items" => 2}} = C74S2.run_task(spec)

      refute exists?(Enum.at(c.olds, 0))
      assert exists?(c.open)
      assert Settings.get().storage_last_cleanup_at
    end

    test "while a cleanup runs: busy before the task, and inside it", c do
      {:ok, _} = Settings.update(%{storage_retention_days: 30})
      me = self()

      holder =
        spawn_link(fn ->
          {:ok, _} = Registry.register(SwarmCode.Domain.Registry, :storage_cleanup, nil)
          send(me, :holding)

          receive do
            :release ->
              Registry.unregister(SwarmCode.Domain.Registry, :storage_cleanup)
              send(me, :released)
          end
        end)

      assert_receive :holding

      assert {:error, %{code: :busy, message: "A cleanup is already running."}} =
               task("storage.apply_retention", c)

      assert {:error, %{code: :busy}} = task("storage.vacuum", c)
      assert Storage.vacuum() == {:error, "A cleanup is already running."}

      assert Storage.retention(%{older_than_days: 30}, fn _ -> :ok end) ==
               {:error, "A cleanup is already running."}

      assert exists?(Enum.at(c.olds, 0))

      send(holder, :release)
      assert_receive :released
    end

    test "vacuum reports before and after", c do
      {:task, spec, _} = task("storage.vacuum", c)
      refute spec.cancellable?
      assert {:ok, %{"before" => before, "after" => after_bytes}} = C74S2.run_task(spec)
      assert is_integer(before) and is_integer(after_bytes)
      refute SwarmCode.Domain.Storage.running?()
    end
  end

  test "glance", c do
    assert %{"storage" => %{"cleanup" => "idle"} = glance} = Storage.glance(c.ctx)
    refute Map.has_key?(glance, "retention_days")
  end
end
