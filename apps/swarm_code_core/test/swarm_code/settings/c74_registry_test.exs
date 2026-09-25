defmodule SwarmCode.Settings.C74RegistryTest do
  use ExUnit.Case, async: true

  alias SwarmCode.Settings.{Entry, Registry, Sections, Validate, WireValue}

  @part1 %{
    models_effort:
      ~w(models.chat models.sub_agent models.scheduled models.workflow models.implementer models.fetch_all efforts.default efforts.sub_agent efforts.scheduled efforts.workflow efforts.implementer session.model session.effort session.sub_agent_model session.sub_agent_effort session.mode session.title session.pinned session.consensus_checks session.consensus_rounds session.judge_model session.judge_effort session.implementer_model session.implementer_effort session.profile),
    search_web: ~w(web.reader web.fetch_facts),
    deep_research:
      ~w(research.level research.max_live research.max_sources research.recency_days research.agent_timeout research.max_retries research.retry_timeouts research.headlines research.auto_design research.include_domains research.exclude_domains research.lead_model research.lead_effort research.worker_model research.worker_effort research.reporter_model research.reporter_effort research.root),
    agents_limits:
      ~w(limits.max_concurrent_agents limits.max_agent_depth limits.max_agent_turns limits.sub_agent_timeout limits.workflow_budget limits.workflow_max_live limits.command_timeout limits.tool_timeout isolation.worktrees isolation.backend shell.env_scrub shell.env_keep shell.path shell.login),
    approvals:
      ~w(project.approval_mode project.trusted project.allow project.name project.root project.last_opened project.approval_env)
  }

  test "part 1 sections hold exactly the keys of §2.2, §2.5, §2.6, §2.9, §2.10, in page order" do
    for {section, keys} <- @part1 do
      assert Enum.map(Registry.for_section(section), & &1.key) == keys, "#{section}"
    end
  end

  test "entries come in rail order" do
    order = Sections.ids() |> Enum.with_index() |> Map.new()
    indexes = Enum.map(Registry.all(), &Map.fetch!(order, &1.section))
    assert indexes == Enum.sort(indexes)
  end

  test "writable entries: defaults and examples pass their validators; examples differ" do
    for entry <- Registry.all(), Entry.writable?(entry), entry.resettable do
      unless entry.default == nil and not entry.nullable do
        assert Validate.check(entry, entry.default) == :ok, entry.key
        assert WireValue.type_ok?(entry, entry.default), entry.key
      end

      case entry.example do
        {:model, "DeepSeek", _model} ->
          :ok

        example ->
          assert example != entry.default and Validate.check(entry, example) == :ok, entry.key
      end
    end
  end

  test "every entry's home layer is one of its layers; facts and actions have none" do
    for entry <- Registry.all() do
      if Entry.writable?(entry), do: assert(entry.home in entry.layers, entry.key)
      if entry.scope in [:fact, :action, :link], do: assert(entry.home == nil, entry.key)
    end
  end

  test "session.mode is one enum of the five modes" do
    mode = Registry.fetch!("session.mode")
    assert Entry.choice_values(mode) == ~w(build plan consensus ultra workflow)
    assert mode.storage == {:conversation_mode}
  end
end
