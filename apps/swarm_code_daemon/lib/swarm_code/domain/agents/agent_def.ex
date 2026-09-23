defmodule SwarmCode.Domain.Agents.AgentDef do
  @moduledoc """
  A declarative agent definition parsed from a markdown file with frontmatter.

  # spec 72 A1
  """

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          tools: [String.t()] | nil,
          model: String.t() | nil,
          effort: String.t() | nil,
          prewalk: boolean(),
          max_turns: pos_integer() | nil,
          system_prompt_addition: String.t() | nil,
          source: :bundled | :user | :project
        }

  defstruct [
    :name,
    :description,
    :tools,
    :model,
    :effort,
    :max_turns,
    :system_prompt_addition,
    prewalk: false,
    source: :bundled
  ]
end
