defmodule SwarmCodeCLI.Plain.Environment do
  @moduledoc "Inert terminal capabilities supplied by the composition root; never probes the OS."
  defstruct stdin_tty?: false,
            stdout_tty?: false,
            controlling_tty?: false,
            term: "dumb",
            color?: true,
            no_color?: false

  @type t :: %__MODULE__{
          stdin_tty?: boolean(),
          stdout_tty?: boolean(),
          controlling_tty?: boolean(),
          term: binary(),
          color?: boolean(),
          no_color?: boolean()
        }
end
