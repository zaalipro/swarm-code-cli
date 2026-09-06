defmodule Mix.Tasks.SwarmCode.Demo.Plain do
  use Mix.Task
  @shortdoc "Runs the finite renderer-free fake demo"
  @requirements ["compile"]

  @impl Mix.Task
  def run(["--script", "complete"]) do
    unless Mix.Project.config()[:app] == :swarm_code_cli and not Mix.Project.umbrella?(),
      do: Mix.raise("Run this task from apps/swarm_code_cli")

    {result, audit} =
      SwarmCodeCLI.Demo.ApplicationFence.run(fn ->
        SwarmCodeCLI.Demo.Plain.run(:complete, output: :stdio, error: :stderr, timeout: 5000)
      end)

    SwarmCodeCLI.Demo.ApplicationFence.maybe_write_fd3(audit)
    if result != :ok, do: Mix.raise("Finite plain demo failed")
    :ok
  end

  def run(_), do: Mix.raise("Expected --script complete")
end
