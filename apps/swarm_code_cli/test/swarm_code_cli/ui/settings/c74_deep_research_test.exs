defmodule SwarmCodeCLI.UI.Settings.C74DeepResearchTest do
  @moduledoc "cli74 U3-5: the Deep research page (§2.6, F7 second page)."
  use ExUnit.Case, async: true

  import SwarmCodeCLI.UI.C74U3Helpers

  alias SwarmCodeCLI.UI.DataSource.Fake.Settings, as: FakeSettings
  alias SwarmCodeCLI.UI.Settings.{Nav, Sections}
  alias SwarmCodeCLI.UI.Settings.Sections.DeepResearch

  defp line_words(row), do: Enum.map_join(row.lines, " / ", &words/1)

  test "every §2.6 row, the tiers with the sub-agent model as their null label" do
    {state, _fake} = opened(:deep_research)
    ids = Enum.map(rows(state), & &1.id)

    for key <- ~w(research.level research.max_live research.max_sources research.recency_days
                  research.agent_timeout research.max_retries research.retry_timeouts
                  research.headlines research.auto_design research.include_domains
                  research.exclude_domains research.lead_model research.lead_effort
                  research.worker_model research.worker_effort research.reporter_model
                  research.reporter_effort research.root) do
      assert ("key:" <> key) in ids, key
    end

    for tier <- ~w(lead worker reporter) do
      row = key_row(state, "research.#{tier}_model")
      assert words(row.value) == "the sub-agent model"
      assert line_words(row) =~ "runs per research: "
    end
  end

  test "the level's hint is this machine's median, or not measured yet" do
    {state, _fake} = opened(:deep_research)
    assert line_words(key_row(state, "research.level")) =~ "median 4 min on this machine"

    {:ok, fake, _} = FakeSettings.control(FakeSettings.seed(), :put, ["research.level", "low"])
    {state, _fake} = opened(:deep_research, fake: fake)
    assert line_words(key_row(state, "research.level")) =~ "not measured yet"
  end

  test "tier runs follow the desktop's tier_runs/2" do
    assert DeepResearch.tier_runs("lead", "medium", true, "deep") == 4
    assert DeepResearch.tier_runs("lead", "medium", false, "deep") == 2
    assert DeepResearch.tier_runs("lead", "low", true, "deep") == 1
    assert DeepResearch.tier_runs("worker", "ultra", true, "deep") == 40
    assert DeepResearch.tier_runs("worker", "high", true, "deep") == 12
    assert DeepResearch.tier_runs("reporter", "medium", true, "deep") == 2
    assert DeepResearch.tier_runs("reporter", "low", true, "deep") == 1
    assert DeepResearch.tier_runs("reporter", "low", true, "all") == 2
    assert DeepResearch.tier_runs("reporter", "ultra", true, "never") == 1
  end

  test "median words" do
    assert DeepResearch.median_words(nil) == "not measured yet"
    assert DeepResearch.median_words(45_000) == "median 45 s on this machine"
    assert DeepResearch.median_words(240_000) == "median 4 min on this machine"
    assert DeepResearch.median_words(7_200_000) == "median 2.0 h on this machine"
  end

  test "the research folder: o opens it, y copies the path" do
    {state, _fake} = opened(:deep_research)
    ctx = Nav.ctx(state)
    row = key_row(state, "research.root")
    path = words(row.value)
    assert path =~ "research"
    assert [{:open_folder, ^path}] = Sections.act(:deep_research, ctx, row, :open_related)
    assert [{:copy, ^path} | _] = Sections.act(:deep_research, ctx, row, :copy)
  end
end
