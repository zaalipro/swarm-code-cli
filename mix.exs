defmodule SwarmCodeCLI.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0-dev",
      elixir: "~> 1.18.4",
      start_permanent: Mix.env() == :prod,
      deps: [],
      aliases: aliases()
    ]
  end

  def cli do
    [preferred_envs: [precommit: :test]]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "deps.unlock --check-unused",
        "test",
        "swarm_code.provenance.verify"
      ]
    ]
  end
end
