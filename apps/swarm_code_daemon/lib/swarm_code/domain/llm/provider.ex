defmodule SwarmCode.Domain.LLM.Provider do
  @moduledoc "Behaviour every LLM client implements."

  alias SwarmCode.Domain.LLM.{Request, Result}

  # spec 36 §A10: everything a stream can hand its `on_event` callback. The
  # deltas come from the provider modules themselves; the three retry events are
  # synthesised by `SwarmCode.Domain.LLM.on_retry/1` around them, so a caller
  # (`Engine.Operation`) sees them on exactly the same channel. Spec 51 §6.3:
  # usage is not an event — it is read from `Result.usage` when the op is done.
  @type event ::
          {:text_delta, String.t()}
          | {:reasoning_delta, String.t()}
          | {:text_reset}
          | {:reasoning_reset}
          | {:retry, pos_integer(), pos_integer(), String.t()}

  # spec 55 T13 (55a A-P5): `{:ok, result}` only after the provider's terminal event
  # (message_stop / finish_reason / [DONE]); a 200 whose body merely ends is retried
  # in-band and then an error.
  @callback stream(Request.t(), on_event :: (event() -> any())) ::
              {:ok, Result.t()} | {:error, String.t()}

  @callback list_models(SwarmCode.Domain.Providers.Provider.t()) ::
              {:ok, [String.t()]} | {:error, String.t()}
end
