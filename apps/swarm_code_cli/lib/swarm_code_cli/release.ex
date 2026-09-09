defmodule SwarmCodeCLI.Release do
  @moduledoc "Entry point for the packaged SwarmCode terminal client."

  @doc "Run the packaged client command."
  def main(["tui"]), do: SwarmCodeCLI.Release.PersistedSession.run()

  def main(["--help"]) do
    IO.puts("Usage: swarm-code tui")
    IO.puts("Environment: SWARM_PROJECT_ROOT, SWARM_MODEL, SWARM_BASE_URL, SWARM_API_KEY")
  end

  def main([]), do: main(["--help"])

  def main(_args) do
    IO.puts(:stderr, "Unknown command. Run 'swarm-code --help'.")
    System.halt(2)
  end
end
