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
    keymap: :default,
    # pass72-O: the side panel's mode as the preferences file had it.
    panel_mode: :full,
    # pass73-K: the rest of cli.json (T1, T2, T9) as the launcher resolved it.
    show_diffs: true,
    theme_mode: :dark,
    theme_env: nil,
    mouse?: true,
    # cli74 (§3.8.4): every cli.json value by json name, the launch's env and
    # flag overrides, and `swarmcode settings [QUERY]`'s query (nil = none;
    # "" opens the Overview).
    prefs: %{},
    launch_facts: %{},
    settings_open: nil,
    # cli74 (§2.17, A10): cli.json's `startup_conversation: ask` — the resume
    # picker opens once the shell is ready, as /resume opens it.
    resume_picker?: false
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
