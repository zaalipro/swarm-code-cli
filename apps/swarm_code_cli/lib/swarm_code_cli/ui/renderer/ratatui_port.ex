defmodule SwarmCodeCLI.UI.Renderer.RatatuiPort do
  @moduledoc """
  The terminal port's public operations beyond drawing (pass70 B10).

  `copy/2` puts text on the system clipboard through OSC 52; the owner is the
  pid the runtime received from `SessionRuntime.register_terminal/4`. Mouse
  wheel reports are opt-in through the owner's `flags: %{mouse?: true}` and
  arrive as `{:mouse, :wheel_up | :wheel_down, nil, column, row, modifiers}`.
  """
  alias SwarmCodeCLI.UI.Renderer.RatatuiPort.Owner

  @doc "Copies `text` (1..65,536 bytes of UTF-8, LF and TAB the only controls)."
  @spec copy(pid(), binary()) :: :ok | {:error, :invalid_text}
  defdelegate copy(owner, text), to: Owner
end
