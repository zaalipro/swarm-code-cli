defmodule SwarmCodeCLI.UI.SafeText.Limits do
  @moduledoc "Per-field byte limits; tab stops use eight terminal cells by default."
  @enforce_keys [:input_bytes, :escaped_bytes]
  defstruct [:input_bytes, :escaped_bytes, tab_width: 8, ambiguous_width: :narrow]

  @type t :: %__MODULE__{
          input_bytes: non_neg_integer(),
          escaped_bytes: non_neg_integer(),
          tab_width: pos_integer(),
          ambiguous_width: :narrow | :wide
        }
  def content, do: %__MODULE__{input_bytes: 65_536, escaped_bytes: 262_144}
  def composer_viewport, do: %__MODULE__{input_bytes: 8_192, escaped_bytes: 65_536}

  @doc false
  def valid?(
        %__MODULE__{
          input_bytes: input,
          escaped_bytes: output,
          tab_width: tab,
          ambiguous_width: width
        } = limits
      ),
      do:
        map_size(limits) == 5 and is_integer(input) and input >= 0 and input <= 65_536 and
          is_integer(output) and output >= 0 and output <= 262_144 and is_integer(tab) and tab > 0 and
          tab <= 8 and width in [:narrow, :wide]

  def valid?(_), do: false
end
