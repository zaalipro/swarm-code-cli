defmodule SwarmCode.Domain.LLM.Request do
  @moduledoc "Provider-neutral streaming request."

  @type message ::
          %{role: String.t(), content: String.t()}
          | %{role: String.t(), content: String.t(), tool_calls: [map()]}
          | %{
              role: String.t(),
              content: String.t(),
              tool_calls: [map()],
              provider_blocks: [map()]
            }
          | %{
              role: String.t(),
              tool_call_id: String.t(),
              name: String.t(),
              content: String.t(),
              is_error: boolean()
            }

  @type tool_spec :: %{name: String.t(), description: String.t(), parameters: map()}

  @type t :: %__MODULE__{
          provider: SwarmCode.Domain.Providers.Provider.t() | nil,
          model: String.t() | nil,
          system: String.t(),
          messages: [message()],
          tools: [tool_spec()],
          max_tokens: pos_integer(),
          temperature: float(),
          effort: effort(),
          deadline_ms: pos_integer() | nil,
          cache_key: String.t() | nil
        }

  @typedoc """
  Reasoning effort. Maps to `reasoning_effort` on OpenAI-compatible servers and
  to a `thinking` budget on Anthropic; `nil` means "leave it to the provider".
  """
  @type effort :: nil | String.t()

  defstruct provider: nil,
            model: nil,
            system: "",
            messages: [],
            tools: [],
            max_tokens: 8192,
            temperature: 0.2,
            effort: "medium",
            # Spec 51 §6.2 (c): the wall clock of one LLM call. Every retry is
            # refused past it and the per-chunk `receive_timeout` never outlives
            # it, so an op cannot sit on a dead socket for ever. App env only —
            # there is no Settings field (spec 51 §10 "Later"). spec 67 G46: nil
            # here, resolved by `HTTP.stream_post/9` when the call is made from
            # `HTTP.default_deadline_ms/0`, so `:llm_deadline_ms` is read at
            # request time rather than baked in at compile time.
            deadline_ms: nil,
            # spec 66 T18: the prefix-cache affinity key OpenAI-compatible
            # servers route on (`prompt_cache_key`). One per agent: the run id
            # for the root agent, `run_id:node_id` for a sub-agent, so siblings
            # with different prefixes do not evict each other. Anthropic does
            # not use it — it has explicit `cache_control` markers.
            cache_key: nil

  # spec 68 T14: efforts/0 removed — dead code superseded by Efforts.keys/2.

  @doc """
  Any well-formed level key stays (spec 45 §3.3 — the provider's list decides
  what it means, `SwarmCode.Domain.LLM.Efforts.normalise_key/3` checks it against
  that list); anything else, nil included, is `"medium"`.
  """
  def effort(value) when is_binary(value) do
    if Regex.match?(SwarmCode.Domain.LLM.Efforts.key_format(), value), do: value, else: "medium"
  end

  def effort(_value), do: "medium"
end
