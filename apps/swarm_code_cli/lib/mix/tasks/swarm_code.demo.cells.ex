defmodule Mix.Tasks.SwarmCode.Demo.Cells do
  use Mix.Task
  @shortdoc "Exports fixed synthetic cell previews without starting applications"
  @requirements ["compile"]

  @impl Mix.Task
  def run([]) do
    unless Mix.Project.config()[:app] == :swarm_code_cli and not Mix.Project.umbrella?(),
      do: Mix.raise("Run this task from apps/swarm_code_cli")

    case SwarmCodeCLI.Demo.Cells.run() do
      {:ok, %{directory: directory, files: files}} ->
        Mix.shell().info("Cell previews: #{directory} (#{length(files)} files)")

      {:error, reason} ->
        Mix.raise("Cell preview export failed: #{reason}")
    end
  end

  def run(_), do: Mix.raise("Cell preview task does not accept arguments")
end
