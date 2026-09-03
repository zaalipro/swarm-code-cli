defmodule SwarmCodeCLI.UI.Scene.Style do
  alias SwarmCodeCLI.UI.Scene.Color

  @roles [
    :plain,
    :title,
    :heading,
    :body,
    :label,
    :value,
    :code,
    :link,
    :key,
    :status,
    :selected,
    :disabled,
    :emphasis
  ]
  @modifiers [:bold, :dim, :italic, :underlined, :reversed]
  defstruct role: :plain, foreground: nil, background: nil, modifiers: []

  @type t :: %__MODULE__{
          role: atom(),
          foreground: Color.t() | nil,
          background: Color.t() | nil,
          modifiers: [atom()]
        }
  def roles, do: @roles
  def modifiers, do: @modifiers
end
