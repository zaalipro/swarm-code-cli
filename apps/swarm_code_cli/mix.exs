defmodule SwarmCodeCli.MixProject do
  use Mix.Project

  def project do
    [
      app: :swarm_code_cli,
      version: "0.2.2",
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
    [
      mod: {SwarmCodeCLI.Application, []},
      extra_applications: [:logger, :crypto, :inets]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]

  # C-ARCH-13: the release carries no test double or demo scene. The Fake data
  # source, the demo scenes, the UI fixtures and the `swarm_code.demo.*` Mix
  # tasks are compiled for :dev and :test only (nothing else in lib refers to
  # them; the prod compile proves it).
  defp elixirc_paths(:prod) do
    "lib/**/*.ex"
    |> Path.wildcard()
    |> Enum.reject(&dev_only?/1)
  end

  defp elixirc_paths(_env), do: ["lib"]

  defp dev_only?(path) do
    path in ["lib/swarm_code_cli/ui/data_source/fake.ex", "lib/swarm_code_cli/ui/fixtures.ex"] or
      String.starts_with?(path, [
        "lib/swarm_code_cli/ui/data_source/fake/",
        "lib/swarm_code_cli/demo/",
        "lib/mix/tasks/swarm_code.demo."
      ])
  end

  defp deps do
    [
      {:swarm_code_core, in_umbrella: true},
      {:stream_data, "== 1.4.0", only: :test, runtime: false}
    ]
  end
end
