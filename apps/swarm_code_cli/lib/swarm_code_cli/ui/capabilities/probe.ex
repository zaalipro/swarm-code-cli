defmodule SwarmCodeCLI.UI.Capabilities.Probe do
  @moduledoc """
  Inert observations consumed by later pure capability-selection policy.

  This module intentionally performs no operating-system, environment, or
  terminal probing.
  """

  alias SwarmCodeCLI.UI.Size

  defstruct size: nil,
            stdin_tty?: false,
            stdout_tty?: false,
            controlling_tty?: false,
            term: nil,
            colorterm: nil,
            no_color?: false,
            plain?: false,
            ascii?: false,
            reduced_motion?: false,
            ambiguous_width: nil,
            enhanced_keys: :unavailable,
            focus: :unavailable,
            paste: :unavailable,
            alternate_screen: :unavailable,
            paste_preallocation_bound?: false

  @type t :: %__MODULE__{
          size: Size.t() | nil,
          stdin_tty?: boolean(),
          stdout_tty?: boolean(),
          controlling_tty?: boolean(),
          term: binary() | nil,
          colorterm: binary() | nil,
          no_color?: boolean(),
          plain?: boolean(),
          ascii?: boolean(),
          reduced_motion?: boolean(),
          ambiguous_width: :narrow | :wide | nil,
          enhanced_keys: SwarmCodeCLI.UI.Capabilities.feature_state(),
          focus: SwarmCodeCLI.UI.Capabilities.feature_state(),
          paste: SwarmCodeCLI.UI.Capabilities.feature_state(),
          alternate_screen: SwarmCodeCLI.UI.Capabilities.feature_state(),
          paste_preallocation_bound?: boolean()
        }
end
