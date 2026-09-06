defmodule Exqlite.MixProject do
  use Mix.Project

  @version "0.39.0-swarm.1"

  def project do
    [
      app: :exqlite,
      version: @version,
      elixir: "~> 1.16",
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      make_force_build: Application.get_env(:exqlite, :force_build, false),
      make_precompiler: nil,
      make_env: make_env(),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      description: description(),
      test_paths: test_paths(System.get_env("EXQLITE_INTEGRATION")),
      elixirc_paths: elixirc_paths(Mix.env()),
      dialyzer: dialyzer(),

      # Docs
      name: "Exqlite",
      source_url: "https://github.com/elixir-sqlite/exqlite",
      homepage_url: "https://github.com/elixir-sqlite/exqlite",
      docs: docs()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:db_connection, "~> 2.1"},
      {:elixir_make, "~> 0.8", runtime: false},
      {:table, "~> 0.1.0", optional: true}
    ]
  end

  defp description do
    "An Elixir SQLite3 library"
  end

  defp make_env do
    if System.get_env("EXQLITE_USE_SYSTEM") not in [nil, ""] do
      raise "EXQLITE_USE_SYSTEM is forbidden in the Swarm Exqlite fork"
    end

    if Mix.env() == :prod and System.get_env("SWARM_GUARD_TEST") not in [nil, ""] do
      raise "SWARM_GUARD_TEST must be absent from production builds"
    end

    Application.get_env(:exqlite, :make_env, %{})
    |> Map.put("MIX_ENV", Atom.to_string(Mix.env()))
    |> Map.put("SWARM_GUARD_TEST", if(Mix.env() in [:dev, :test], do: "1", else: ""))
  end

  defp package do
    [
      files: ~w(
        lib
        .formatter.exs
        mix.exs
        README.md
        LICENSE
        .clang-format
        c_src
        Makefile*
        checksum.exs
        UPSTREAM.json
        SWARM_PATCHES.md
        scripts
        test/swarm_guard
      ),
      name: "exqlite",
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/elixir-sqlite/exqlite",
        "Changelog" => "https://github.com/elixir-sqlite/exqlite/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: docs_extras(),
      source_ref: "v#{@version}",
      source_url: "https://github.com/elixir-sqlite/exqlite"
    ]
  end

  defp docs_extras do
    [
      "README.md": [title: "Readme"],
      "guides/windows.md": [],
      "CHANGELOG.md": []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp test_paths(nil), do: ["test"]
  defp test_paths(_any), do: ["integration_test/exqlite"]

  defp dialyzer do
    [
      plt_add_deps: :apps_direct,
      plt_add_apps: ~w(table)a
    ]
  end

end
