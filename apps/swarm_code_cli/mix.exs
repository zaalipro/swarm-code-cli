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
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp deps, do: [{:swarm_code_core, in_umbrella: true}]
end
