defmodule SwarmCode.Daemon.Service.Settings.C74ValuesTest do
  @moduledoc """
  pass74 S1-7: the values view and `values.patch`/`values.reset`/`profile.apply`
  against a fixture database (pool 3): layers, winner, base, invalid stored
  values, ignored layers, the `--model` flag, compare-and-set per scope, all or
  nothing, no insert on a read, the mode columns and the post-commit cache
  invalidation (M2).
  """
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias SwarmCode.Daemon.Service.Settings
  alias SwarmCode.Daemon.Service.Settings.{Result, Values}
  alias SwarmCode.Domain.{Conversations, Projects, Repo}
  alias SwarmCode.Domain.Settings.Setting
  alias SwarmCode.Settings.Registry
  alias SwarmCode.Test.C74S1

  setup do
    %{dir: dir} = C74S1.repo!()
    fixture = C74S1.appendix_a!(dir)

    on_exit(fn ->
      Application.delete_env(:swarm_code_daemon, :settings_values_seam)
      Application.delete_env(:swarm_code_daemon, :session_model_override)
    end)

    Map.put(fixture, :dir, dir)
  end

  defp values(ctx, params \\ %{}) do
    {:ok, %{"values" => values}} = Settings.query("values", params, ctx)
    Map.new(values, &{&1["key"], &1})
  end

  defp patch(ctx, changes, expected, opts \\ []) do
    changes = for {key, value} <- changes, do: %{"key" => key, "value" => value, "target" => nil}

    Settings.command(
      C74S1.command("values.patch",
        attributes: %{"changes" => changes},
        expected: expected,
        dry_run: Keyword.get(opts, :dry_run, false)
      ),
      ctx
    )
  end

  defp row, do: Repo.one(from(s in Setting, limit: 1))

  test "a snapshot on a database without a settings row inserts nothing (D24)", fixture do
    Repo.delete_all(Setting)
    assert C74S1.settings_rows() == 0

    by_key = values(C74S1.context(fixture))
    assert C74S1.settings_rows() == 0
    assert by_key["limits.max_concurrent_agents"]["value"] == 4
    assert by_key["limits.max_concurrent_agents"]["winner"] == "default"
    assert Enum.all?(by_key, fn {_, v} -> v["state"] in ["ok", "attention"] end)
  end

  test "layers, winner, base and writable of global, session and project values", fixture do
    by_key = values(C74S1.context(fixture))

    agents = by_key["limits.max_concurrent_agents"]
    assert agents["value"] == 6 and agents["winner"] == "global" and agents["base"] == 6
    assert agents["writable"] == ["global"]

    assert %{"layer" => "default", "value" => 4, "set" => true} =
             Enum.find(agents["layers"], &(&1["layer"] == "default"))

    effort = by_key["session.effort"]
    assert effort["value"] == "high" and effort["winner"] == "session"
    assert Enum.map(effort["choices"], & &1["value"]) |> Enum.member?("high")

    approval = by_key["project.approval_mode"]
    assert approval["value"] == "auto" and approval["winner"] == "project"
    assert by_key["project.trusted"]["value"] == true

    # 50.0 in the column reads 50.
    assert by_key["budget.monthly_usd"]["value"] == 50
    assert Map.keys(by_key) |> Enum.all?(&(Registry.fetch!(&1).scope != :cli))
  end

  test "patch per scope: accepted, unchanged, conflict, rejected; a write touches only its column",
       fixture do
    ctx = C74S1.context(fixture)
    before = row()

    assert {:ok, %Result{status: :accepted, results: [%{status: :accepted}]}} =
             patch(ctx, [{"limits.max_concurrent_agents", 8}], %{
               "limits.max_concurrent_agents" => 6
             })

    after_row = row()
    assert after_row.max_concurrent_agents == 8

    for field <- Setting.__schema__(:fields) -- [:max_concurrent_agents, :updated_at] do
      assert Map.get(after_row, field) == Map.get(before, field), "#{field} changed"
    end

    assert {:ok, %Result{status: :conflict, results: [%{status: :conflict, current: 8}]}} =
             patch(ctx, [{"limits.max_concurrent_agents", 9}], %{
               "limits.max_concurrent_agents" => 6
             })

    assert {:ok, %Result{status: :unchanged}} =
             patch(ctx, [{"limits.max_concurrent_agents", 8}], %{
               "limits.max_concurrent_agents" => 8
             })

    # A retry of an applied write: its expected value is stale, the value is current.
    assert {:ok, %Result{status: :unchanged}} =
             patch(ctx, [{"limits.max_concurrent_agents", 8}], %{
               "limits.max_concurrent_agents" => 6
             })

    assert {:ok, %Result{status: :rejected, results: [%{message: message}]}} =
             patch(ctx, [{"limits.max_concurrent_agents", 0}], %{
               "limits.max_concurrent_agents" => 8
             })

    assert message =~ "must be"

    # Session and project homes.
    assert {:ok, %Result{status: :accepted}} =
             patch(ctx, [{"session.effort", "low"}], %{"session.effort" => "high"})

    assert Conversations.get(fixture.conversation.id).effort == "low"

    assert {:ok, %Result{status: :accepted}} =
             patch(ctx, [{"project.approval_mode", "full_access"}], %{
               "project.approval_mode" => "auto"
             })

    assert Projects.get(fixture.ailogic.id).approval_mode == "full_access"

    # All or nothing: one conflict writes nothing.
    assert {:ok, %Result{status: :conflict, results: rows}} =
             patch(ctx, [{"limits.max_agent_turns", 90}, {"session.effort", "medium"}], %{
               "limits.max_agent_turns" => 60,
               "session.effort" => "high"
             })

    assert [%{status: :skipped}, %{status: :conflict}] = rows
    assert row().max_agent_turns == 60
  end

  test "the words of refused changes", fixture do
    ctx = C74S1.context(fixture)

    assert {:ok, %Result{results: [%{message: "not a setting: nope"}]}} =
             patch(ctx, [{"nope", 1}], %{"nope" => 1})

    assert {:ok,
            %Result{
              results: [
                %{message: "this setting lives in cli.json and is written by the terminal"}
              ]
            }} = patch(ctx, [{"terminal.panel", "hidden"}], %{"terminal.panel" => "compact"})

    assert {:error, %{message: "expected is missing for limits.max_agent_turns"}} =
             patch(ctx, [{"limits.max_agent_turns", 90}], %{})

    missing = %{"provider_id" => "99999999-9999-4999-8999-999999999999", "model" => "x"}

    assert {:ok, %Result{results: [%{message: "that provider no longer exists"}]}} =
             patch(ctx, [{"models.chat", missing}], %{"models.chat" => %{"$any" => true}})

    assert {:ok, %Result{results: [%{message: effort}]}} =
             patch(ctx, [{"session.effort", "turbo"}], %{"session.effort" => "high"})

    assert effort =~ "is not a level of deepseek-v4-pro"

    other = %{"conversation_id" => "33333333-3333-4333-8333-333333333333"}

    assert {:ok,
            %Result{results: [%{message: "only this session's conversation can be changed here"}]}} =
             Settings.command(
               C74S1.command("values.patch",
                 attributes: %{
                   "changes" => [
                     %{"key" => "session.effort", "value" => "low", "target" => other}
                   ]
                 },
                 expected: %{"session.effort" => "high"}
               ),
               ctx
             )
  end

  test "a nullable value clears to null (D16); dry_run writes nothing", fixture do
    ctx = C74S1.context(fixture)

    assert {:ok, %Result{status: :accepted}} =
             patch(ctx, [{"budget.monthly_usd", 75}], %{"budget.monthly_usd" => 50},
               dry_run: true
             )

    assert row().monthly_budget_usd == 50.0

    assert {:ok, %Result{status: :accepted}} =
             patch(ctx, [{"budget.monthly_usd", nil}], %{"budget.monthly_usd" => 50})

    assert row().monthly_budget_usd == nil
    assert values(ctx)["budget.monthly_usd"]["value"] == nil
  end

  test "session.mode writes the four columns as mode_fields/1 does, for all five modes",
       fixture do
    ctx = C74S1.context(fixture)

    expected = %{
      "build" => %{mode: "build", ultra: false, consensus: false, authoring_workflow: false},
      "plan" => %{mode: "plan", ultra: false, consensus: false, authoring_workflow: false},
      "consensus" => %{mode: "build", ultra: false, consensus: true, authoring_workflow: false},
      "ultra" => %{mode: "build", ultra: true, consensus: false, authoring_workflow: false},
      "workflow" => %{mode: "build", ultra: false, consensus: false, authoring_workflow: true}
    }

    for mode <- ["plan", "consensus", "ultra", "workflow", "build"] do
      assert Values.mode_fields(mode) == expected[mode]

      assert {:ok, %Result{status: status}} =
               patch(ctx, [{"session.mode", mode}], %{"session.mode" => %{"$any" => true}})

      assert status in [:accepted, :unchanged]
      conversation = Conversations.get(fixture.conversation.id)
      assert Map.take(conversation, Map.keys(expected[mode])) == expected[mode]
      assert values(ctx)["session.mode"]["value"] == mode
    end
  end

  test "reset of every scalar key in one request, then a 70-change batch back", fixture do
    ctx = C74S1.context(fixture)
    by_key = values(ctx)

    expected =
      for {key, value} <- by_key,
          entry = Registry.fetch!(key),
          SwarmCode.Settings.Entry.writable?(entry) and entry.resettable,
          into: %{},
          do: {key, value["base"]}

    assert map_size(expected) <= 256

    assert {:ok, %Result{status: :accepted, results: rows}} =
             Settings.command(
               C74S1.command("values.reset", attributes: %{"scope" => "all"}, expected: expected),
               ctx
             )

    assert length(rows) == map_size(expected)
    assert row().max_concurrent_agents == 4
    assert Conversations.get(fixture.conversation.id).effort == nil

    # Undo: the old bases back, 70 keys at once.
    after_reset = values(ctx)

    # The keys the reset changed first, then unchanged ones up to 70.
    batch =
      expected
      |> Enum.filter(fn {key, _} -> Registry.fetch!(key).home == :global end)
      |> Enum.sort_by(fn {key, old} -> {old == after_reset[key]["base"], key} end)
      |> Enum.take(70)

    assert length(batch) == 70

    assert {:ok, %Result{status: status, results: rows}} =
             patch(
               ctx,
               batch,
               Map.new(batch, fn {key, _} -> {key, after_reset[key]["base"]} end)
             )

    assert status in [:accepted, :unchanged] and length(rows) == 70
    assert row().max_concurrent_agents == 6
  end

  test "stored values this CLI does not understand are invalid rows; a reset uses the raw base",
       fixture do
    Repo.query!(
      "UPDATE settings SET theme = 'nord', research_max_live = 40, monthly_budget_usd = 12.5"
    )

    ctx = C74S1.context(fixture)
    by_key = values(ctx)

    for key <- ["desktop.theme", "research.max_live", "budget.monthly_usd"] do
      assert %{"state" => "invalid", "value" => nil} = by_key[key], key
    end

    assert by_key["desktop.theme"]["base"] == "nord"
    assert by_key["desktop.theme"]["note"] =~ "the stored value \"nord\" is not valid here"
    assert by_key["limits.max_concurrent_agents"]["state"] == "ok"

    assert {:ok, %Result{status: :accepted}} =
             Settings.command(
               C74S1.command("values.reset",
                 attributes: %{"keys" => ["desktop.theme"]},
                 expected: %{"desktop.theme" => "nord"}
               ),
               ctx
             )

    assert row().theme == "carbon"
  end

  test "the environment never wins where the runtime ignores it; the project file effort is shown ignored",
       fixture do
    File.mkdir_p!(Path.join(fixture.ailogic.root_path, ".swarm_code"))

    File.write!(
      Path.join(fixture.ailogic.root_path, ".swarm_code/config.json"),
      ~s({"effort": "high", "profiles": {"fast": {"effort": "low"}}})
    )

    ctx =
      C74S1.context(fixture,
        env: %{
          "SWARM_APPROVAL" => "ask",
          "SWARM_CONVERSATION" => "44444444-4444-4444-8444-444444444444"
        }
      )

    by_key = values(ctx)
    refute Enum.any?(by_key, fn {_, v} -> v["winner"] == "env" end)
    assert by_key["project.approval_mode"]["winner"] == "project"

    default_effort = by_key["efforts.default"]
    ignored = Enum.find(default_effort["layers"], &(&1["layer"] == "project_file"))
    assert %{"set" => true, "ignored" => true, "note" => "SwarmCode ignores this key"} = ignored
    assert default_effort["winner"] in ["global", "default"]
    assert by_key["project_file.effort"]["value"] == "high"

    assert {:ok, %Result{status: :accepted}} =
             Settings.command(
               C74S1.command("profile.apply", attributes: %{"name" => "fast"}),
               ctx
             )

    assert Conversations.get(fixture.conversation.id).effort == "low"

    assert {:error, %{message: ~s(Unknown profile "slow" — available: fast)}} =
             Settings.command(
               C74S1.command("profile.apply", attributes: %{"name" => "slow"}),
               ctx
             )
  end

  test "--model is the flag layer of both session model rows; a write clears it", fixture do
    override = %{provider_id: fixture.deepseek.id, model: "deepseek-v4-flash"}
    Application.put_env(:swarm_code_daemon, :session_model_override, override)
    ctx = C74S1.context(fixture, override: override)
    by_key = values(ctx)

    for key <- ["session.model", "session.sub_agent_model"] do
      assert %{"winner" => "flag", "value" => %{"model" => "deepseek-v4-flash"}} = by_key[key]
      flag = Enum.find(by_key[key]["layers"], &(&1["layer"] == "flag"))
      assert flag["source"] == "--model" and flag["note"] == "for this launch only"
    end

    pro = %{"provider_id" => fixture.deepseek.id, "model" => "deepseek-v4-pro"}

    assert {:ok, %Result{status: status}} =
             patch(ctx, [{"session.model", pro}], %{"session.model" => %{"$any" => true}})

    assert status in [:accepted, :unchanged]
    assert SwarmCode.Daemon.Service.SessionConfiguration.override() == nil
  end

  test "a reader caching between the domain write and the commit sees the new approval mode (M2)",
       fixture do
    id = fixture.ailogic.id
    assert Projects.get_cached(id).approval_mode == "auto"

    Application.put_env(:swarm_code_daemon, :settings_values_seam, fn ->
      # Another connection reads the committed (old) row and caches it.
      task = Task.async(fn -> Projects.get_cached(id).approval_mode end)
      assert Task.await(task) == "auto"
    end)

    assert {:ok, %Result{status: :accepted}} =
             patch(C74S1.context(fixture), [{"project.approval_mode", "full_access"}], %{
               "project.approval_mode" => "auto"
             })

    Application.delete_env(:swarm_code_daemon, :settings_values_seam)
    assert Projects.get_cached(id).approval_mode == "full_access"
  end
end
