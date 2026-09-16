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
    banner: nil,
    keymap: :default
  ]

  @type t :: %__MODULE__{}
  def new(options), do: struct!(__MODULE__, options)

  @doc """
  The keymap the environment asks for.

  Nothing in the CLI persists preferences to disk, so `SWARM_KEYMAP=vim` in
  the shell that launches it is how vim mode survives a restart. Any other
  value, or none, is the default keymap.
  """
  @spec keymap_from_env(binary() | nil) :: :default | :vim
  def keymap_from_env(value \\ System.get_env("SWARM_KEYMAP")) do
    if is_binary(value) and String.downcase(String.trim(value)) == "vim",
      do: :vim,
      else: :default
  end
end
