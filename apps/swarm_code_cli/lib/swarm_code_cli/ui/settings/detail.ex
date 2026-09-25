defmodule SwarmCodeCLI.UI.Settings.Detail do
  @moduledoc """
  What the detail pane (≥ 160 columns) or the drawer (narrower) says about the
  focused row, in the order of T§6.5: the title and its scope, the key line
  (`limits.command_timeout · command_timeout_ms`), the description, the facts,
  where the value comes from (strongest first, the winner marked), checks,
  recent results and the row's actions.

  Every text is plain words; the projector styles them. `layers` entries are
  `%{layer, value, note, winner?, set?, ignored?}`.
  """

  defstruct title: "",
            scope: nil,
            key_line: nil,
            description: "",
            facts: [],
            layers: [],
            checks: [],
            results: [],
            actions: [],
            notes: []

  @type t :: %__MODULE__{
          title: String.t(),
          scope: String.t() | nil,
          key_line: String.t() | nil,
          description: String.t(),
          facts: [{String.t(), String.t()}],
          layers: [map()],
          checks: [{:ok | :fail | :running, String.t()}],
          results: [String.t()],
          actions: [{String.t(), String.t()}],
          notes: [{String.t(), atom()}]
        }
end
