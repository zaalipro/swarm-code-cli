defmodule SwarmCodeCLI.UI.Scene.Color do
  @roles [
    :default,
    :muted,
    :accent,
    :success,
    :warning,
    :danger,
    :info,
    :focus,
    :border,
    :background
  ]
  @enforce_keys [:role]
  defstruct [:role]

  @type role ::
          :default
          | :muted
          | :accent
          | :success
          | :warning
          | :danger
          | :info
          | :focus
          | :border
          | :background
  @type t :: %__MODULE__{role: role()}
  def roles, do: @roles
end
