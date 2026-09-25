defmodule SwarmCodeCLI.UI.Settings.Picker do
  @moduledoc """
  A picker popover in the `/approval` picker's style (spec §3.7.8): a title
  in the top border (the filter joins it while typing), one row per option
  with its meaning beside it, a `1 of N · Enter chooses · Esc closes` row.
  `options` are `%{value, label, hint}`; `on_pick` is what the layer does
  with the chosen value (`{:patch, key}`, `{:project, :page}`, `{:op, fun_id}`
  resolved by the opener).
  """

  defstruct id: nil,
            title: "",
            options: [],
            cursor: 0,
            query: "",
            current: nil,
            on_pick: nil,
            opener: nil,
            filter?: true

  @type option :: %{value: term(), label: String.t(), hint: String.t() | nil}
  @type t :: %__MODULE__{
          id: String.t() | nil,
          title: String.t(),
          options: [option()],
          cursor: non_neg_integer(),
          query: String.t(),
          current: term(),
          on_pick: term(),
          opener: String.t() | nil,
          filter?: boolean()
        }

  @doc "The options the query leaves, case-insensitive, words AND, each a prefix of a word."
  @spec visible(t()) :: [option()]
  def visible(%__MODULE__{query: ""} = picker), do: picker.options

  def visible(%__MODULE__{} = picker) do
    words = picker.query |> String.downcase() |> String.split(~r/\s+/u, trim: true)

    Enum.filter(picker.options, fn option ->
      haystack =
        [option.label, Map.get(option, :hint) || "", to_string_value(option.value)]
        |> Enum.join(" ")
        |> String.downcase()
        |> String.split(~r/[^\p{L}\p{N}._\/-]+/u, trim: true)

      Enum.all?(words, fn word -> Enum.any?(haystack, &String.starts_with?(&1, word)) end)
    end)
  end

  defp to_string_value(value) when is_binary(value), do: value
  defp to_string_value(value) when is_atom(value) or is_number(value), do: to_string(value)
  defp to_string_value(_value), do: ""
end
