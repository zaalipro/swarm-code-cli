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

  @part2 %{
    providers: ~w(providers.add providers.fetch_all),
    mcp: ~w(mcp.add mcp.import),
    language_servers:
      ~w(lsp.elixir lsp.erlang lsp.typescript lsp.javascript lsp.python lsp.rust lsp.go lsp.c lsp.cpp lsp.ruby lsp.java lsp.swift lsp.zig lsp.check lsp.stop),
    project_file:
      ~w(project_file.effort project_file.swarm_effort project_file.model project_file.swarm_model project_file.denied project_file.edit),
    appearance:
      ~w(terminal.theme terminal.colors terminal.glyphs terminal.ambiguous_width terminal.reduced_motion terminal.accent terminal.desktop_theme_link),
    layout:
      ~w(terminal.panel terminal.composer_rows terminal.inspector_width terminal.show_diffs terminal.notice_seconds terminal.diff_lines),
    keys:
      ~w(terminal.keymap terminal.mouse terminal.wheel_lines terminal.editor terminal.hint_letters terminal.keys terminal.terminal_facts),
    startup:
      ~w(terminal.startup_conversation terminal.companion terminal.project_root terminal.launch_flags),
    storage:
      ~w(storage.retention_days storage.prune_days storage.last_sweep storage.measure storage.cleanup storage.vacuum storage.apply_retention),
    budget: ~w(budget.monthly_usd budget.month budget.by_model),
    desktop:
      ~w(desktop.theme desktop.mode desktop.reduce_motion desktop.bench_layout desktop.consensus_layout desktop.focus_on_finish desktop.show_global_tasks desktop.show_reasoning desktop.keys.file_finder desktop.keys.new desktop.keys.nudge_left desktop.keys.nudge_right desktop.keys.quit desktop.keys.search desktop.keys.settings desktop.keys.side desktop.keys.sidebar desktop.sidebar_collapsed desktop.sidebar_width desktop.sidebar_sections desktop.sidebar_scroll desktop.pane_view desktop.agents_view desktop.agents_density desktop.side_w_2col desktop.side_w_3col desktop.pane_w desktop.composer_h desktop.side_composer_h desktop.prompt_size),
    files_env:
      ~w(files.cli_json files.database files.config_dir files.log files.project_dir files.research files.user_agents env.variables launch.summary terminal.this_terminal files.versions files.doctor),
    import_export: ~w(transfer.export transfer.import transfer.reset_everything)
  }

  test "part 1 sections hold exactly the keys of §2.2, §2.5, §2.6, §2.9, §2.10, in page order" do
    for {section, keys} <- @part1 do
      assert Enum.map(Registry.for_section(section), & &1.key) == keys, "#{section}"
    end
  end

  test "part 2 sections hold exactly the keys of §2.3, §2.7, §2.8, §2.11, §2.14–§2.22" do
    for {section, keys} <- @part2 do
      assert Enum.map(Registry.for_section(section), & &1.key) == keys, "#{section}"
    end
  end

  test "the registry holds #{length(Registry.all())} entries (170: 168 table rows + lsp.check, lsp.stop)" do
    assert length(Registry.all()) == 170
    all = Map.merge(@part1, @part2) |> Map.values() |> List.flatten()
    assert Enum.sort(all) == Enum.sort(Enum.map(Registry.all(), & &1.key))
  end

  test "entries come in rail order" do
    order = Sections.ids() |> Enum.with_index() |> Map.new()
    indexes = Enum.map(Registry.all(), &Map.fetch!(order, &1.section))
    assert indexes == Enum.sort(indexes)
  end

  test "scalar keys fit in one values.patch; cli entries are the 20 terminal keys" do
    assert length(Registry.scalar_keys()) <= Registry.max_patch()
    assert length(Registry.scalar_keys()) == 130
    assert length(Registry.cli_entries()) == 20

    for entry <- Registry.cli_entries() do
      assert {:cli, name} = entry.storage
      assert {:ok, ^entry} = Registry.cli_entry(name)
    end

    assert {:ok, %Entry{key: "terminal.panel"}} = Registry.cli_entry("panel")
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

  test "numeric entries of more than 50 steps have a big step" do
    for entry <- Registry.all(), entry.type in [:integer, :duration, :money] do
      if is_nil(entry.max) or (entry.max - entry.min) / entry.step > 50,
        do: assert(is_integer(entry.big_step), entry.key)
    end

    assert Registry.fetch!("limits.command_timeout").big_step == 60_000
    assert Registry.fetch!("terminal.diff_lines").big_step == 10
  end

  test "every entry's home layer is one of its layers; facts and actions have none" do
    for entry <- Registry.all() do
      if Entry.writable?(entry), do: assert(entry.home in entry.layers, entry.key)
      if entry.scope in [:fact, :action, :link], do: assert(entry.home == nil, entry.key)
    end
  end

  test "synonyms resolve to keys, sections and records" do
    assert Registry.resolve("theme") == {:key, "terminal.theme"}
    assert Registry.resolve("dark mode") == {:key, "terminal.theme"}
    assert Registry.resolve("vim") == {:key, "terminal.keymap"}
    assert Registry.resolve("editor") == {:key, "terminal.editor"}
    assert Registry.resolve("model") == {:key, "models.chat"}
    assert Registry.resolve("effort") == {:key, "efforts.default"}
    assert Registry.resolve("budget") == {:key, "budget.monthly_usd"}
    assert Registry.resolve("retention") == {:key, "storage.retention_days"}
    assert Registry.resolve("lsp") == {:section, :language_servers}
    assert Registry.resolve("consensus") == {:key, "session.mode"}
    assert Registry.resolve("AGENTS.md") == {:record, "file", "instructions"}
    assert Registry.resolve("Tavily") == {:record, "search_provider", "tavily"}
    assert Registry.resolve("mcp") == {:section, :mcp}
    assert Registry.resolve("keybindings") == {:key, "terminal.keys"}
    assert Registry.resolve("max_concurrent_agents") == {:key, "limits.max_concurrent_agents"}
    assert Registry.resolve("limits.tool_timeout") == {:key, "limits.tool_timeout"}
    assert Registry.resolve("nonsense words") == :error

    for {_word, target} <- Registry.synonyms() do
      case target do
        {:key, key} -> assert {:ok, _} = Registry.fetch(key)
        {:section, section} -> assert Sections.valid?(section)
        {:record, _kind, _id} -> :ok
      end
    end
  end

  test "sections: 22, fetch by id, title and synonym; theme is not a section" do
    assert length(Sections.all()) == 22
    assert Sections.fetch("MCP") == {:ok, :mcp}
    assert Sections.fetch("search & web") == {:ok, :search_web}
    assert Sections.fetch("keybindings") == {:ok, :keys}
    assert Sections.fetch("memory-and-instructions") == :error
    assert Sections.fetch("Memory & instructions") == {:ok, :memory}
    assert Sections.fetch("theme") == :error
  end

  test "session.mode is one enum of the five modes" do
    mode = Registry.fetch!("session.mode")
    assert Entry.choice_values(mode) == ~w(build plan consensus ultra workflow)
    assert mode.storage == {:conversation_mode}
  end
end
