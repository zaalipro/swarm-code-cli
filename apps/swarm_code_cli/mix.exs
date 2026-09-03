defmodule SwarmCodeCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :swarm_code_cli,
      version: "0.1.0-dev",
      elixir: "~> 1.18.4",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:swarm_code_core, in_umbrella: true},
      {:stream_data, "== 1.4.0", only: :test, runtime: false}
    ]
  end
end
