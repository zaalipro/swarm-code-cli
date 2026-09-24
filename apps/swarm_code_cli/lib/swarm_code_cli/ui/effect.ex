defmodule SwarmCodeCLI.UI.Effect do
  @moduledoc "The exhaustive declarative reducer effect vocabulary."

  alias SwarmCodeCLI.UI.DataSource.{Request, Watch}
  alias SwarmCodeCLI.UI.{Action, DraftKey, Intent, SafeText}

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
          | {:companion, :open}
          | {:copy, binary()}
          | {:edit_externally, DraftKey.t(), binary()}
          | {:detach, non_neg_integer()}
          | {:save_preferences, map()}
          | {:terminal_preferences,
             %{optional(:theme) => :dark | :light, optional(:mouse?) => boolean()}}

  # What select mode's `y` may put on the clipboard in one OSC 52 write.
  @max_copy_bytes 262_144

  @doc "The largest text a copy effect carries."
  @spec max_copy_bytes() :: pos_integer()
  def max_copy_bytes, do: @max_copy_bytes

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
  def validate({:companion, :open} = effect), do: {:ok, effect}

  def validate({:copy, text} = effect),
    do:
      valid_effect(
        effect,
        is_binary(text) and text != "" and byte_size(text) <= @max_copy_bytes and
          String.valid?(text)
      )

  # Ctrl-X: the session runtime suspends the terminal, runs $VISUAL/$EDITOR
  # on a private copy of the draft and answers `{:external_edit_done, …}`.
  def validate({:edit_externally, key, text} = effect),
    do:
      valid_effect(
        effect,
        match?({:ok, _}, DraftKey.validate(key)) and is_binary(text) and
          byte_size(text) <= @max_copy_bytes and String.valid?(text)
      )

  def validate({:detach, exit_status} = effect),
    do: valid_effect(effect, is_integer(exit_status) and exit_status >= 0)

  # pass72-O: the session writes the CLI preferences file (the side panel's
  # mode) in work it owns; the reducer only says what changed. pass73-K: any
  # subset of the file's preferences (`Init.Preferences.valid?/1`).
  def validate({:save_preferences, preferences} = effect),
    do: valid_effect(effect, SwarmCodeCLI.UI.Init.Preferences.valid?(preferences))

  # pass73-K (T2, T9): the terminal's owner repaints in the other theme, or
  # turns wheel reports on or off, without a restart.
  def validate({:terminal_preferences, preferences} = effect) when is_map(preferences),
    do:
      valid_effect(
        effect,
        map_size(preferences) > 0 and
          Enum.all?(preferences, fn
            {:theme, mode} -> mode in [:dark, :light]
            {:mouse?, on?} -> is_boolean(on?)
            _ -> false
          end)
      )

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
    _error in [FunctionClauseError, ArgumentError] -> false
  end

  defp valid_effect(effect, true), do: {:ok, effect}
  defp valid_effect(_effect, false), do: {:error, :invalid_effect}
end
