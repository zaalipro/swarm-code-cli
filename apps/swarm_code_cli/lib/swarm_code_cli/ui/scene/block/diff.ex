defmodule SwarmCodeCLI.UI.Scene.Block.Diff do
  @moduledoc """
  A parsed unified diff for one file: its path, the added/removed counts and
  the retained hunks. Parsing belongs to the projector, so the Scene carries
  only already-bounded SafeText the paint layer can present directly.

  A hunk is `{header, lines}` and a line is `{kind, text}`; both are tuples
  rather than maps because Paint.Budget walks tuples, lists and SafeText but
  rejects bare maps. `truncated?` records that the projector dropped lines to
  stay inside its budget; paint shows the elision marker only when it is set.
  """
  alias SwarmCodeCLI.UI.SafeText

  @enforce_keys [:path]
  defstruct [:path, added: 0, removed: 0, hunks: [], truncated?: false]

  @type kind :: :add | :del | :ctx | :meta
  @type line :: {kind(), SafeText.t()}
  @type hunk :: {SafeText.t(), [line()]}
  @type t :: %__MODULE__{
          path: SafeText.t(),
          added: non_neg_integer(),
          removed: non_neg_integer(),
          hunks: [hunk()],
          truncated?: boolean()
        }
end
