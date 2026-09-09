defmodule SwarmCode.Domain.Skills.Skill do
  @moduledoc "A folder of instructions an agent can be given (spec 25 §1.1)."

  @type asset :: %{name: String.t(), body: String.t()}

  @type t :: %__MODULE__{
          name: String.t(),
          scope: String.t(),
          path: String.t(),
          description: String.t(),
          body: String.t(),
          assets: [asset()]
        }

  defstruct name: "",
            scope: "builtin",
            path: "",
            description: "",
            body: "",
            assets: []
end
