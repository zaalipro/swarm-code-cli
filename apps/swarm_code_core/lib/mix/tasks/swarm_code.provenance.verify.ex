defmodule Mix.Tasks.SwarmCode.Provenance.Verify do
  @moduledoc false
  use Mix.Task

  alias SwarmCode.Governance.Provenance

  @shortdoc "Verifies source authorization and extracted-file provenance"

  @impl Mix.Task
  def run(_args) do
    case Provenance.verify(File.cwd!()) do
      :ok -> Mix.shell().info("provenance verified")
      {:error, errors} -> Mix.raise(Enum.join(errors, "\n"))
    end
  end
end
