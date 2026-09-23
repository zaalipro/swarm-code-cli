defmodule SwarmCode.Development.PersistedSession do
  @moduledoc false
  # The development launcher runs exactly the release session
  # (`SwarmCodeCLI.Release.PersistedSession`, pass70 B3): same failures, exit
  # statuses, private log and exit summary. It only adds a first stderr line
  # naming the conversation, which the saved-session PTY suite reads.

  def run, do: finish(SwarmCodeCLI.Release.PersistedSession.run_dev())

  # A trusted test runner passes this directly. No environment variable or
  # production command-line option can select an alternate database path.
  def run_for_test(boot_config),
    do: finish(SwarmCodeCLI.Release.PersistedSession.run_for_test(boot_config))

  defp finish(0), do: :ok

  defp finish(status) do
    _ = :logger_std_h.filesync(:default)
    System.halt(status)
  end
end
