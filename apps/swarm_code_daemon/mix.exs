defmodule SwarmCodeDaemon.MixProject do
  use Mix.Project

  def project do
    [
      app: :swarm_code_daemon,
      version: "0.1.0-dev",
      elixir: "~> 1.18.4",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp deps do
    [
      {:swarm_code_core, in_umbrella: true},
      {:ecto_sql, "== 3.14.0"},
      {:ecto_sqlite3, "== 0.24.1"},
      {:exqlite, "== 0.39.0"},
      {:jason, "== 1.4.5"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]
end
