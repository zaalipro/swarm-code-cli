defmodule SwarmCodeCLI.UI.Settings.Normalize do
  @moduledoc """
  Sections from other owners build rows, pages, details, confirmations and
  pickers as plain maps with the structs' field names (U2's
  `IntegrationRows`). The layer turns them into the structs here, once, at
  the edge (`Nav.rows/1`, `Ops.run/2`); unknown keys are dropped, missing
  ones take the struct defaults.
  """

  alias SwarmCodeCLI.UI.Settings.{Confirm, Detail, Page, Picker, Row}

  @doc "A row as `%Row{}` (its detail as `%Detail{}`)."
  @spec row(Row.t() | map()) :: Row.t()
  def row(%Row{detail: detail} = row) when is_map(detail) and not is_struct(detail),
    do: %{row | detail: detail(detail)}

  def row(%Row{} = row), do: row
  def row(%{} = map), do: row(struct(Row, map))

  @doc "Rows as `%Row{}`s (anything that is not a map is dropped)."
  @spec rows(list()) :: [Row.t()]
  def rows(rows) when is_list(rows), do: for(row <- rows, is_map(row), do: row(row))
  def rows(_rows), do: []

  @doc "A detail as `%Detail{}`."
  def detail(%Detail{} = detail), do: detail
  def detail(%{} = map), do: struct(Detail, map)
  def detail(other), do: other

  @doc "A page as `%Page{}`."
  def page(%Page{} = page), do: page
  def page(%{} = map), do: struct(Page, map)

  @doc "A confirmation as `%Confirm{}`."
  def confirm(%Confirm{} = confirm), do: confirm
  def confirm(%{} = map), do: struct(Confirm, map)

  @doc "A picker as `%Picker{}`, each option with `value`, `label` and `hint`."
  def picker(%Picker{} = picker), do: %{picker | options: Enum.map(picker.options, &option/1)}
  def picker(%{} = map), do: picker(struct(Picker, map))

  defp option(%{} = option) do
    value = Map.get(option, :value, Map.get(option, "value"))
    label = Map.get(option, :label) || Map.get(option, "label") || words(value)
    %{value: value, label: label, hint: Map.get(option, :hint) || Map.get(option, "hint")}
  end

  defp option(value), do: %{value: value, label: words(value), hint: nil}

  defp words(value) when is_binary(value), do: value
  defp words(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp words(_value), do: ""

  @doc "An op with its nested page, confirmation, picker and ops normalised."
  @spec op(term()) :: term()
  def op({:open, %{} = page}), do: {:open, page(page)}
  def op({:picker, %{} = picker}), do: {:picker, picker(picker)}

  def op({:confirm, %{} = confirm, then: ops}) when is_list(ops),
    do: {:confirm, confirm(confirm), then: Enum.map(ops, &op/1)}

  def op({:confirm, %{} = confirm, [then: ops]}), do: op({:confirm, confirm, then: ops})
  def op({:leave, ops}) when is_list(ops), do: {:leave, Enum.map(ops, &op/1)}
  def op(op), do: op
end
