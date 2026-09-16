defmodule SwarmCodeCLI.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0-dev",
      elixir: "~> 1.18.4",
      start_permanent: Mix.env() == :prod,
      deps: [],
      releases: [
        swarm_code_cli: [
          applications: [
            inets: :permanent,
            swarm_code_core: :permanent,
            swarm_code_daemon: :permanent,
            swarm_code_cli: :permanent
          ],
          overlays: ["rel/overlays"],
          steps: [:assemble]
        ]
      ],
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
        "swarm_code.provenance.verify",
        &verify_schema_snapshot/1,
        &verify_unicode/1
      ]
    ]
  end

  defp verify_schema_snapshot(_args) do
    {output, status} =
      System.cmd("sh", ["scripts/dev/check_schema_snapshot.sh"],
        cd: __DIR__,
        stderr_to_stdout: true
      )

    Mix.shell().info(output)
    if status != 0, do: Mix.raise("Native schema snapshot verification failed")
  end

  defp verify_unicode(_args) do
    for {executable, script} <- [
          {"elixir", "scripts/dev/sync_unicode_width.exs"},
          {"python3", "scripts/dev/sync_unicode_variants.py"}
        ] do
      {output, status} =
        System.cmd(executable, [script, "--check"], cd: __DIR__, stderr_to_stdout: true)

      Mix.shell().info(output)
      if status != 0, do: Mix.raise("Unicode source verification failed: #{script}")
    end
  end
end
