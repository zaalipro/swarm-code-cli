defmodule SwarmCodeCLI.UI.Projector.Home do
  @moduledoc """
  orbit: Home on screen. It covers the whole screen the way Settings does and is
  projected before the agent overlay and the shell (D7: too_small, Settings,
  Home, Overlay, Shell). This is the skeleton U2 needs (the region exists and
  Esc can be tested); U5 draws the screen.
  """

  alias SwarmCodeCLI.UI.Home
  alias SwarmCodeCLI.UI.Scene.{Rect, Region}
  alias SwarmCodeCLI.UI.SafeText

  @doc "Home's regions and cursor, or nil while it is closed."
  @spec project(map(), term()) :: nil | {[Region.t()], term()}
  def project(%{home: %Home{}} = state, layout) do
    %{columns: width, rows: height} = state.size

    if layout.class == :too_small do
      nil
    else
      region = %Region{
        id: "home",
        role: :main,
        rect: %Rect{x: 0, y: 0, width: width, height: height},
        label: SafeText.chrome(:empty),
        blocks: [],
        focus: :active
      }

      {[region], nil}
    end
  end

  def project(_state, _layout), do: nil
end
