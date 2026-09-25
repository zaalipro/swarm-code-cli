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
          | {:settings_cli_read, non_neg_integer()}
          | {:settings_cli_write, non_neg_integer(), pos_integer(), map(), map()}
          | {:settings_cli_write_text, non_neg_integer(), pos_integer(), binary(), binary() | nil}
          | {:settings_external_edit, non_neg_integer(), pos_integer(), map()}
          | {:settings_open_folder, non_neg_integer(), binary()}

  # What select mode's `y` may put on the clipboard in one OSC 52 write.
  @max_copy_bytes 262_144

  # cli.json's own bound (`SwarmCode.Settings.CliFile.max_bytes/0`).
  @max_cli_bytes 65_536

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

  # cli74 (§3.8.2): cli.json reads and writes run in the session runtime's
  # preference queue, one at a time; answered as `{:settings, …}` actions.
  def validate({:settings_cli_read, generation} = effect),
    do: valid_effect(effect, generation?(generation))

  def validate({:settings_cli_write, generation, ref, changes, expected} = effect),
    do:
      valid_effect(
        effect,
        generation?(generation) and ref?(ref) and cli_map?(changes) and cli_map?(expected)
      )

  def validate({:settings_cli_write_text, generation, ref, text, fingerprint} = effect),
    do:
      valid_effect(
        effect,
        generation?(generation) and ref?(ref) and is_binary(text) and
          byte_size(text) <= @max_cli_bytes and String.valid?(text) and
          (is_nil(fingerprint) or (is_binary(fingerprint) and byte_size(fingerprint) <= 128))
      )

  # The external editor on a settings text or file (a private copy, 0600).
  def validate(
        {:settings_external_edit, generation, ref, %{content: content, suffix: suffix}} = effect
      ),
      do:
        valid_effect(
          effect,
          generation?(generation) and ref?(ref) and is_binary(content) and
            byte_size(content) <= @max_copy_bytes and String.valid?(content) and is_binary(suffix) and
            suffix =~ ~r/\A\.[a-z0-9]{1,8}\z/
        )

  # `o` on a file or path row: the desktop opens the folder.
  def validate({:settings_open_folder, generation, path} = effect),
    do:
      valid_effect(
        effect,
        generation?(generation) and is_binary(path) and byte_size(path) <= 4_096 and
          String.valid?(path) and String.starts_with?(path, "/") and
          not String.contains?(path, <<0>>)
      )

  def validate(_effect), do: {:error, :invalid_effect}

  defp generation?(generation), do: is_integer(generation) and generation >= 0
  defp ref?(ref), do: is_integer(ref) and ref > 0

  defp cli_map?(map),
    do: is_map(map) and map_size(map) <= 64 and Enum.all?(Map.keys(map), &is_binary/1)

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
