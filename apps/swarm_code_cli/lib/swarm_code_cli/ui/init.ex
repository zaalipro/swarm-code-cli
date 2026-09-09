defmodule SwarmCodeCLI.UI.Init do
  @moduledoc "All external values needed by the pure reducer, supplied by its owner."
  @enforce_keys [:size, :capabilities, :source_epoch]
  defstruct [
    :size,
    :capabilities,
    :source_epoch,
    destination: :activity,
    focus: "main",
    now: 0,
    deadline_ms: 30_000,
    id_prefix: "ui",
    id_sequence: 0,
    terminal_generation: 0,
    banner: nil
  ]

  @type t :: %__MODULE__{}
  def new(options), do: struct!(__MODULE__, options)
end
