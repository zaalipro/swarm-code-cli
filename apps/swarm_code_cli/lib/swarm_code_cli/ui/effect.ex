defmodule SwarmCodeCLI.UI.Effect do
  @moduledoc "The exhaustive declarative reducer effect vocabulary."

  alias SwarmCodeCLI.UI.DataSource.{Request, Watch}
  alias SwarmCodeCLI.UI.{Action, Intent, SafeText}

  @type t ::
          {:watch, Watch.t()}
          | {:unwatch, binary()}
          | {:query, Request.t()}
          | {:command, Request.t()}
          | {:cancel_request, binary()}
          | {:start_timer, binary(), non_neg_integer(), Action.t()}
          | {:cancel_timer, binary()}
          | {:terminal_control, :suspend | :resume | :shutdown}
          | {:announce, SafeText.t()}
          | {:bell, :needs_you}
          | {:presenter_handoff, :plain}
          | {:detach, non_neg_integer()}

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_effect}
  def validate({:watch, watch} = effect),
    do: valid_effect(effect, match?({:ok, _watch}, Watch.validate(watch)))

  def validate({:unwatch, watch_ref} = effect),
    do: valid_effect(effect, Intent.valid_id?(watch_ref))

  def validate({:query, %Request{expected_response: expected_response} = request} = effect),
    do:
      valid_effect(
        effect,
        expected_response != :outcome and match?({:ok, _request}, Request.validate(request))
      )

  def validate({:command, %Request{expected_response: :outcome} = request} = effect),
    do: valid_effect(effect, match?({:ok, _request}, Request.validate(request)))

  def validate({:cancel_request, request_id} = effect),
    do: valid_effect(effect, Intent.valid_id?(request_id))

  def validate({:start_timer, timer_id, milliseconds, action} = effect),
    do:
      valid_effect(
        effect,
        Intent.valid_id?(timer_id) and is_integer(milliseconds) and milliseconds >= 0 and
          match?({:ok, _action}, Action.validate(action))
      )

  def validate({:cancel_timer, timer_id} = effect),
    do: valid_effect(effect, Intent.valid_id?(timer_id))

  def validate({:terminal_control, operation} = effect),
    do: valid_effect(effect, operation in [:suspend, :resume, :shutdown])

  def validate({:announce, safe_text} = effect),
    do: valid_effect(effect, valid_safe_text?(safe_text))

  def validate({:bell, :needs_you} = effect), do: {:ok, effect}
  def validate({:presenter_handoff, :plain} = effect), do: {:ok, effect}

  def validate({:detach, exit_status} = effect),
    do: valid_effect(effect, is_integer(exit_status) and exit_status >= 0)

  def validate(_effect), do: {:error, :invalid_effect}

  @spec validate!(term()) :: t()
  def validate!(effect) do
    case validate(effect) do
      {:ok, valid} -> valid
      {:error, :invalid_effect} -> raise ArgumentError, "invalid effect"
    end
  end

  defp valid_safe_text?(safe_text) do
    _value = SafeText.value(safe_text)
    true
  rescue
    FunctionClauseError -> false
  end

  defp valid_effect(effect, true), do: {:ok, effect}
  defp valid_effect(_effect, false), do: {:error, :invalid_effect}
end
