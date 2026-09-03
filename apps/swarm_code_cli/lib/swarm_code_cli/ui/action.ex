defmodule SwarmCodeCLI.UI.Action do
  @moduledoc "The exhaustive renderer-neutral semantic action vocabulary."

  alias SwarmCodeCLI.UI.DataSource.Delivery
  alias SwarmCodeCLI.UI.Editor.Operation

  alias SwarmCodeCLI.UI.{
    Capabilities,
    Destination,
    DraftKey,
    FieldKey,
    Intent,
    LayerSpec,
    ScrollOperation,
    Size
  }

  @terminal_error_codes [
    :terminal_unavailable,
    :initialization_failed,
    :input_failed,
    :draw_failed,
    :shutdown_failed,
    :invalid_scene,
    :ambiguous_width_unsupported,
    :unsupported_public_no_alt,
    :session_failed
  ]

  @capability_keys [
    :__struct__,
    :size,
    :color_mode,
    :ambiguous_width,
    :ascii?,
    :reduced_motion?,
    :tty?,
    :controlling_tty?,
    :stdin_tty?,
    :stdout_tty?,
    :full_screen?,
    :enhanced_keys,
    :focus,
    :paste,
    :mouse,
    :alternate_screen,
    :paste_preallocation_bound?
  ]

  @type terminal_error_code ::
          :terminal_unavailable
          | :initialization_failed
          | :input_failed
          | :draw_failed
          | :shutdown_failed
          | :invalid_scene
          | :ambiguous_width_unsupported
          | :unsupported_public_no_alt
          | :session_failed

  @type t ::
          :boot
          | {:resize, Size.t()}
          | {:terminal_capabilities, non_neg_integer(), Capabilities.t()}
          | {:terminal_lifecycle, :suspend_requested | :suspended | :resumed | :closing,
             non_neg_integer(), :keyboard | :launcher | :runtime}
          | {:terminal_failed, non_neg_integer(), terminal_error_code()}
          | {:draw_result, binary(), non_neg_integer(), :ok | {:error, terminal_error_code()}}
          | {:terminal_focus, :gained | :lost, non_neg_integer()}
          | {:input_rejected, :invalid_utf8 | :text_fragment_too_large | :paste_too_large}
          | :back
          | {:focus_cycle, :next | :previous}
          | {:focus_region, binary()}
          | {:move, :next | :previous | :first | :last}
          | {:expand, binary(), boolean()}
          | {:invoke, Intent.t(), binary()}
          | {:scroll, binary(), ScrollOperation.t()}
          | {:editor, DraftKey.t(), Operation.t()}
          | {:field_editor, FieldKey.t(), Operation.t()}
          | {:layout_adjust, :navigator | :inspector,
             :reset
             | {:preset, :compact | :balanced | :wide}
             | {:nudge, -8 | -2 | 2 | 8}}
          | {:composer_height, :reset | {:nudge, -1 | 1}}
          | {:presenter_handoff_requested, :plain}
          | {:presenter_handoff_confirmed, :plain}
          | {:navigate, Destination.t()}
          | {:open_layer, LayerSpec.t()}
          | :close_top_layer
          | {:data, Delivery.t()}
          | {:timer_fired, binary()}
          | {:quit_requested, :detach | :daemon_shutdown}
          | {:quit_confirmed, :detach}

  @spec terminal_error_codes() :: [terminal_error_code()]
  def terminal_error_codes, do: @terminal_error_codes

  @spec terminal_error_code?(term()) :: boolean()
  def terminal_error_code?(code), do: code in @terminal_error_codes

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_action}
  def validate(action) when action in [:boot, :back, :close_top_layer], do: {:ok, action}
  def validate({:resize, size} = action), do: valid_action(action, Size.valid?(size))

  def validate({:terminal_capabilities, generation, capabilities} = action),
    do:
      valid_action(
        action,
        non_negative_integer?(generation) and valid_capabilities?(capabilities)
      )

  def validate({:terminal_lifecycle, state, generation, source} = action),
    do:
      valid_action(
        action,
        state in [:suspend_requested, :suspended, :resumed, :closing] and
          non_negative_integer?(generation) and source in [:keyboard, :launcher, :runtime]
      )

  def validate({:terminal_failed, generation, code} = action),
    do: valid_action(action, non_negative_integer?(generation) and terminal_error_code?(code))

  def validate({:draw_result, draw_token, revision, result} = action),
    do:
      valid_action(
        action,
        Intent.valid_id?(draw_token) and non_negative_integer?(revision) and
          valid_draw_result?(result)
      )

  def validate({:terminal_focus, focus, generation} = action),
    do: valid_action(action, focus in [:gained, :lost] and non_negative_integer?(generation))

  def validate({:input_rejected, reason} = action),
    do:
      valid_action(action, reason in [:invalid_utf8, :text_fragment_too_large, :paste_too_large])

  def validate({:focus_cycle, direction} = action),
    do: valid_action(action, direction in [:next, :previous])

  def validate({:focus_region, region_id} = action),
    do: valid_action(action, Intent.valid_id?(region_id))

  def validate({:move, direction} = action),
    do: valid_action(action, direction in [:next, :previous, :first, :last])

  def validate({:expand, item_id, expanded?} = action),
    do: valid_action(action, Intent.valid_id?(item_id) and is_boolean(expanded?))

  def validate({:invoke, intent, request_id} = action),
    do: valid_action(action, Intent.valid?(intent) and Intent.valid_id?(request_id))

  def validate({:scroll, region_id, operation} = action),
    do:
      valid_action(
        action,
        Intent.valid_id?(region_id) and
          match?({:ok, _operation}, ScrollOperation.validate(operation))
      )

  def validate({:editor, draft_key, operation} = action),
    do:
      valid_action(
        action,
        match?({:ok, _key}, DraftKey.validate(draft_key)) and
          match?({:ok, _operation}, Operation.validate(operation))
      )

  def validate({:field_editor, field_key, operation} = action),
    do:
      valid_action(
        action,
        match?({:ok, _key}, FieldKey.validate(field_key)) and
          match?({:ok, _operation}, Operation.validate(operation))
      )

  def validate({:layout_adjust, dock, adjustment} = action),
    do:
      valid_action(
        action,
        dock in [:navigator, :inspector] and valid_layout_adjustment?(adjustment)
      )

  def validate({:composer_height, adjustment} = action),
    do: valid_action(action, adjustment == :reset or adjustment in [{:nudge, -1}, {:nudge, 1}])

  def validate({:presenter_handoff_requested, :plain} = action), do: {:ok, action}
  def validate({:presenter_handoff_confirmed, :plain} = action), do: {:ok, action}

  def validate({:navigate, destination} = action),
    do: valid_action(action, match?({:ok, _destination}, Destination.validate(destination)))

  def validate({:open_layer, layer} = action),
    do: valid_action(action, match?({:ok, _layer}, LayerSpec.validate(layer)))

  def validate({:data, delivery} = action),
    do: valid_action(action, match?({:ok, _delivery}, Delivery.validate(delivery)))

  def validate({:timer_fired, timer_id} = action),
    do: valid_action(action, Intent.valid_id?(timer_id))

  def validate({:quit_requested, kind} = action),
    do: valid_action(action, kind in [:detach, :daemon_shutdown])

  def validate({:quit_confirmed, :detach} = action), do: {:ok, action}
  def validate(_action), do: {:error, :invalid_action}

  @spec validate!(term()) :: t()
  def validate!(action) do
    case validate(action) do
      {:ok, valid} -> valid
      {:error, :invalid_action} -> raise ArgumentError, "invalid action"
    end
  end

  defp valid_draw_result?(:ok), do: true
  defp valid_draw_result?({:error, code}), do: terminal_error_code?(code)
  defp valid_draw_result?(_result), do: false

  defp valid_layout_adjustment?(:reset), do: true
  defp valid_layout_adjustment?({:preset, preset}), do: preset in [:compact, :balanced, :wide]
  defp valid_layout_adjustment?({:nudge, amount}), do: amount in [-8, -2, 2, 8]
  defp valid_layout_adjustment?(_adjustment), do: false

  defp valid_capabilities?(%Capabilities{} = capabilities) do
    Enum.sort(Map.keys(capabilities)) == Enum.sort(@capability_keys) and
      Size.valid?(capabilities.size) and
      capabilities.color_mode in [:truecolor, :ansi256, :ansi16, :monochrome] and
      capabilities.ambiguous_width in [:narrow, :wide] and
      boolean?(capabilities.ascii?) and boolean?(capabilities.reduced_motion?) and
      boolean?(capabilities.tty?) and boolean?(capabilities.controlling_tty?) and
      boolean?(capabilities.stdin_tty?) and boolean?(capabilities.stdout_tty?) and
      boolean?(capabilities.full_screen?) and feature?(capabilities.enhanced_keys) and
      feature?(capabilities.focus) and feature?(capabilities.paste) and
      capabilities.mouse == :unavailable and feature?(capabilities.alternate_screen) and
      boolean?(capabilities.paste_preallocation_bound?)
  end

  defp valid_capabilities?(_capabilities), do: false
  defp feature?(value), do: value in [:supported, :best_effort, :unavailable]
  defp boolean?(value), do: is_boolean(value)
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp valid_action(action, true), do: {:ok, action}
  defp valid_action(_action, false), do: {:error, :invalid_action}
end
