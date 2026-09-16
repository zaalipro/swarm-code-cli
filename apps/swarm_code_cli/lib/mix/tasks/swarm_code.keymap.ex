defmodule Mix.Tasks.SwarmCode.Keymap do
  use Mix.Task
  @shortdoc "Prints or checks docs/keybindings.md, generated from the binding table"
  @requirements ["compile"]

  @moduledoc """
  The keyboard reference is generated, never hand-written.

      mix swarm_code.keymap            # print the Markdown
      mix swarm_code.keymap --write    # write docs/keybindings.md
      mix swarm_code.keymap --check    # exit 1 if the file and the table disagree

  Run from `apps/swarm_code_cli`; the docs directory is the umbrella's.
  """

  @impl Mix.Task
  def run(args) do
    unless Mix.Project.config()[:app] == :swarm_code_cli and not Mix.Project.umbrella?(),
      do: Mix.raise("Run this task from apps/swarm_code_cli")

    rendered = SwarmCodeCLI.UI.Keymap.Docs.render()

    case args do
      [] ->
        IO.write(rendered)

      ["--write"] ->
        File.write!(path(), rendered)
        Mix.shell().info("wrote #{path()}")

      ["--check"] ->
        if File.exists?(path()) and File.read!(path()) == rendered do
          Mix.shell().info("#{path()} matches the binding table")
        else
          Mix.raise("#{path()} is stale; run `mix swarm_code.keymap --write`")
        end

      _ ->
        Mix.raise("Expected no arguments, --write or --check")
    end
  end

  @doc false
  def path, do: Path.expand("../../docs/keybindings.md", File.cwd!())
end
