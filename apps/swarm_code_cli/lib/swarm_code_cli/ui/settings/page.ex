defmodule SwarmCodeCLI.UI.Settings.Page do
  @moduledoc """
  One level of the settings layer's page stack (spec §3.7.1): a section page,
  a record page (`record: {kind, id}`) or a sub-page (`sub`), with the row the
  cursor is on and the scroll offset of the page column. The head of the
  layer's stack is the page on screen; Esc pops one and restores the parent's
  cursor and scroll.
  """

  defstruct section: :overview, record: nil, sub: nil, cursor: nil, scroll: 0

  @type t :: %__MODULE__{
          section: atom(),
          record: nil | {String.t(), String.t()},
          sub: nil | term(),
          cursor: nil | String.t(),
          scroll: non_neg_integer()
        }

  @doc "A section's own page."
  @spec section(atom()) :: t()
  def section(id) when is_atom(id), do: %__MODULE__{section: id}

  @doc "The level of a page: `:section`, `:record` or `:sub`."
  @spec level(t()) :: :section | :record | :sub
  def level(%__MODULE__{sub: sub}) when not is_nil(sub), do: :sub
  def level(%__MODULE__{record: record}) when not is_nil(record), do: :record
  def level(%__MODULE__{}), do: :section

  @doc "A reference that names this page for stale-response checks and filters."
  @spec ref(t()) :: {atom(), term(), term()}
  def ref(%__MODULE__{section: section, record: record, sub: sub}), do: {section, record, sub}
end
