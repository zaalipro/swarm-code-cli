defmodule SwarmCodeCLI.Demo.Home do
  @moduledoc """
  orbit U12: gallery scenes for Home (the startup dashboard), from the designer's
  mock (`Fixtures.home_state/3`). Synthetic data only.

    * `:main` — a busy project: four orbits, three live runs, one approval waits.
    * `:first_run` — a project with nothing in it yet, untrusted and read-only.
    * `:interact` — the project map focused on another project's newest bead.
    * `:compact` — the small class (line orbits); `:wide` — the large one (bead
      titles, the provider windows). Both draw the `:main` data; their size makes
      the class, so the gallery pairs them with 80 x 24 and 160 x 44.
  """
  alias SwarmCodeCLI.UI.{Capabilities, Fixtures, Size, State}

  @scenes [:main, :first_run, :interact, :compact, :wide]

  # The size each scene is shown at in the gallery.
  @sizes %{
    main: {120, 36},
    first_run: {120, 36},
    interact: {120, 36},
    compact: {80, 24},
    wide: {160, 44}
  }

  @doc "Every scene, in gallery order."
  def scenes, do: @scenes

  @doc "The `{scene, {columns, rows}}` pairs of the gallery."
  def examples, do: Enum.map(@scenes, &{&1, Map.fetch!(@sizes, &1)})

  @spec state(atom(), Size.t(), Capabilities.t()) :: State.t()
  def state(scene, %Size{} = size, %Capabilities{} = capabilities) when scene in @scenes do
    Fixtures.home_state(size, capabilities, scene: data(scene))
  end

  defp data(scene) when scene in [:first_run, :interact], do: scene
  defp data(_scene), do: :main
end
