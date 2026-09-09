defmodule SwarmCode.Domain.LLM.Result do
  @moduledoc "Provider-neutral result of a completed LLM call."

  @typedoc """
  A tool call. `args_error`/`args_raw` are present only when the provider's
  `arguments` JSON could not be decoded (`SwarmCode.Domain.LLM.ToolArgs`): `args` is
  then `%{}` and the agent reports the reason to the model instead of running
  the tool with nothing.
  """
  @type tool_call :: %{
          :id => String.t(),
          :name => String.t(),
          :args => map(),
          optional(:args_error) => String.t(),
          optional(:args_raw) => String.t()
        }

  @typedoc """
  Provider continuation state: the assistant turn exactly as the provider sent
  it, in wire order (spec 30 §1).

  Anthropic's extended thinking is not decoration — a `thinking` block carries a
  signature, and the Messages API requires the whole block back, unaltered,
  on the request that answers a `tool_use` with `tool_result`. The text we show
  the user cannot reconstruct it, so the blocks travel beside it.

  Empty for every ordinary turn and every other provider, and never persisted:
  it lives only in an `AgentServer`'s in-memory history.
  """
  @type provider_block :: %{String.t() => term()}

  @typedoc """
  Token usage. `input` is the size of the prompt whatever it was billed as:
  spec 51 §6.4 sums Anthropic's `input_tokens`, `cache_creation_input_tokens`
  and `cache_read_input_tokens` into it, and carries the two cache counters
  beside it, so `tokens_in` keeps meaning "prompt size". Present only on a
  provider that does prompt caching.
  """
  @type usage :: %{
          :input => non_neg_integer(),
          :output => non_neg_integer(),
          optional(:cache_read) => non_neg_integer(),
          optional(:cache_write) => non_neg_integer()
        }

  @typedoc """
  The policy category of a `stop_reason: "refusal"` (spec 53b §3):
  `%{"category" => "cyber" | "bio" | "reasoning_extraction" | …}`, with an
  optional `"explanation"`. It is informational and can be `nil` on a real
  refusal, so code branches on `stop_reason` and only reads this for the
  message it shows.
  """
  @type stop_details :: map() | nil

  @type t :: %__MODULE__{
          text: String.t(),
          reasoning: String.t(),
          tool_calls: [tool_call()],
          provider_blocks: [provider_block()],
          usage: usage(),
          stop_reason: String.t(),
          stop_details: stop_details(),
          model: String.t() | nil
        }

  defstruct text: "",
            reasoning: "",
            tool_calls: [],
            provider_blocks: [],
            usage: %{input: 0, output: 0},
            stop_reason: "other",
            stop_details: nil,
            model: nil
end
