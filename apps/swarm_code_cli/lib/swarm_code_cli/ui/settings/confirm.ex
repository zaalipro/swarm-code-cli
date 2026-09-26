defmodule SwarmCodeCLI.UI.Settings.Confirm do
  @moduledoc """
  A confirmation popover (T§12 as amended by spec §4.8): a question titled
  with the object's name, `not undoable` on the border when true, the
  consequences as lines, then the safe button first and focused and the
  destructive one (`chip_err`) with its letter. `typed` asks for a word
  (`delete 14`, `reset`) before the destructive button can be pressed;
  `counting?` keeps it disabled until the counts arrive.
  """

  defstruct id: nil,
            title: "",
            lines: [],
            safe: "Cancel",
            danger: "",
            letter: nil,
            undoable?: true,
            typed: nil,
            counting?: false,
            focus: :safe,
            input: "",
            tabbed?: false,
            opener: nil

  @type t :: %__MODULE__{
          id: String.t() | nil,
          title: String.t(),
          lines: [String.t() | [{String.t(), atom()}]],
          safe: String.t(),
          danger: String.t(),
          letter: String.t() | nil,
          undoable?: boolean(),
          typed: nil | String.t(),
          counting?: boolean(),
          focus: :safe | :danger,
          input: String.t(),
          tabbed?: boolean(),
          opener: String.t() | nil
        }
end
