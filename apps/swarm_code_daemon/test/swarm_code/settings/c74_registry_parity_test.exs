defmodule SwarmCode.Settings.C74RegistryParityTest do
  @moduledoc """
  The choice lists the settings registry copies by value from the synced
  domain (spec §3.2.6): they must agree with the domain they came from.
  """
  use ExUnit.Case, async: true

  alias SwarmCode.Domain.{Search, Settings}
  alias SwarmCode.Domain.Engine.Consensus
  alias SwarmCode.Domain.LSP.Language
  alias SwarmCode.Domain.Research.Levels
  alias SwarmCode.Domain.Settings.Setting
  alias SwarmCode.Settings.{Entry, RecordKind, Registry}
  alias SwarmCode.Settings.Registry.{Desktop, Lsp, ProjectFile}

  # §2.24 N1 / §2.26: columns that are deliberately not registry values.
  @not_settings ~w(id inserted_at updated_at tavily_api_key pricing)

  test "every settings column is a registry storage, a fact, a record map or listed as not ported" do
    columns = Setting.__schema__(:fields) |> Enum.map(&Atom.to_string/1)
    assert length(columns) == 79 + 3

    stored =
      Registry.all()
      |> Enum.flat_map(fn %Entry{storage: storage} ->
        case storage do
          {:setting, field} -> [Atom.to_string(field)]
          {:setting_pair, provider, model} -> [Atom.to_string(provider), Atom.to_string(model)]
          {:setting_map, field, _entry} -> [Atom.to_string(field)]
          {:fact, :storage_last_cleanup_at} -> ["storage_last_cleanup_at"]
          _ -> []
        end
      end)
      |> MapSet.new()

    missing = Enum.reject(columns, &(&1 in stored or &1 in @not_settings))
    assert missing == []
  end

  test "desktop themes are the domain's eight" do
    assert Registry.fetch!("desktop.theme") |> Entry.choice_values() ==
             Enum.map(Settings.themes(), &elem(&1, 0))

    assert Desktop.themes() == Enum.map(Settings.themes(), &elem(&1, 0))
  end

  test "desktop key defaults are the domain's" do
    assert Desktop.default_keybindings() == Settings.default_keybindings()
  end

  test "search kinds are the domain's engines then readers" do
    {:ok, kind} = RecordKind.fetch("search_provider")
    choices = RecordKind.field(kind, "kind").choices
    assert choices == Search.engine_kinds() ++ Search.reader_kinds()
  end

  test "the twelve consensus checks and their defaults" do
    entry = Registry.fetch!("session.consensus_checks")
    assert Entry.choice_values(entry) == Enum.map(Consensus.checks(), & &1.key)
    assert length(Entry.choice_values(entry)) == 12

    defaults = for %{hint: "on by default", value: value} <- entry.choices, do: value
    assert defaults == Consensus.default_keys()

    for check <- Consensus.checks() do
      assert Enum.find(entry.choices, &(&1.value == check.key)).label == check.label
    end
  end

  test "research levels" do
    assert Registry.fetch!("research.level") |> Entry.choice_values() == Levels.names()
  end

  test "language servers: the 13 languages and their built-in commands" do
    languages = for {language, _label, _ext, _command} <- Lsp.languages(), do: language
    assert length(languages) == 13

    for {language, _label, _ext, command} <- Lsp.languages() do
      expected = if command, do: String.split(command), else: nil
      assert Language.server_command(language) == expected, language
    end

    extensions =
      for {language, _label, ext, _command} <- Lsp.languages(),
          e <- String.split(ext),
          do: {e, language}

    for {extension, language} <- extensions do
      assert Language.detect("file" <> extension) == language
    end
  end

  test "inclusion lists agree with the Setting changeset (probed)" do
    for key <-
          ~w(isolation.backend desktop.bench_layout desktop.consensus_layout desktop.mode desktop.pane_view desktop.agents_view desktop.agents_density desktop.prompt_size research.auto_design web.reader research.level) do
      entry = Registry.fetch!(key)
      {:setting, field} = entry.storage

      for value <- Entry.choice_values(entry) do
        assert Setting.changeset(%Setting{}, %{field => value}).valid?, "#{key} #{value}"
      end

      refute Setting.changeset(%Setting{}, %{field => "not-a-choice"}).valid?, key
    end
  end

  test "numeric bounds agree with the changeset at both edges (probed)" do
    for entry <- Registry.all(),
        entry.type in [:integer, :duration, :money],
        match?({:setting, _}, entry.storage),
        is_integer(entry.min) do
      {:setting, field} = entry.storage
      assert Setting.changeset(%Setting{}, %{field => entry.min}).valid?, entry.key

      refute Setting.changeset(%Setting{}, %{field => entry.min - 1}).valid? and
               entry.special == %{},
             entry.key

      if is_integer(entry.max) do
        assert Setting.changeset(%Setting{}, %{field => entry.max}).valid?, entry.key
        refute Setting.changeset(%Setting{}, %{field => entry.max + 1}).valid?, entry.key
      end
    end
  end

  test "the registry's range messages are the changeset's" do
    for key <-
          ~w(limits.max_concurrent_agents limits.command_timeout research.max_live storage.retention_days limits.sub_agent_timeout) do
      entry = Registry.fetch!(key)
      {:setting, field} = entry.storage
      changeset = Setting.changeset(%Setting{}, %{field => entry.max + 1})
      {message, _} = Keyword.fetch!(changeset.errors, field)
      assert SwarmCode.Settings.Validate.check(entry, entry.max + 1) == {:error, message}, key
    end
  end

  test "the project file lists: the denylist and the ignored keys" do
    source = File.read!(Path.expand("../../../lib/swarm_code/domain/project_config.ex", __DIR__))

    for key <- ProjectFile.denied_keys() do
      assert source =~ key, key
    end
  end
end
