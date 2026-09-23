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
    Keymap,
    LayerSpec,
    ScrollOperation,
    Size,
    Vim
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

  # One keystroke at a time reaches the runs dashboard filter, so a fragment is
  # bounded far below the editor's 4 KiB: a paste never routes here.
  @max_filter_fragment_bytes 64

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
    :paste_preallocation_bound?,
    :glyph_tier
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
          | :editor_detach_notice
          | :open_companion
          | :nothing_waiting
          | {:open_interaction, binary()}
          | {:interrupt, :escape | :ctrl_c}
          | :select_mode
          | :defer_send
          | {:compose, binary()}
          | {:history, :previous | :next}
          | :copy_selection
          | {:slash_local,
             :help | :quit | :new | :resume | :conversations | :queue | :approval | :trust}
          | {:open_conversation, binary()}
          | :new_conversation
          | {:complete_path, binary()}
          | :dismiss_completion
          | {:external_editor, DraftKey.t()}
          | {:external_edit_done, DraftKey.t(), {:ok, binary()} | {:error, external_edit_error()}}
          | {:toggle_dock, :inspector}
          | {:set_tab, :agents | :timeline | :changes}
          | {:select_agent, binary()}
          | {:set_keymap, :default | :vim}
          | {:vim,
             {:mode, Vim.mode()}
             | {:pending, nil | binary()}
             | {:count, nil | pos_integer()}
             | {:edit_then, [Operation.t(), ...], Vim.mode()}}
          | {:run_tab, :next | :previous | 1 | 2 | 3 | 4}
          | {:inspector_tab, :next | :previous}
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
          | {:draft_target, DraftKey.t(), :none | Intent.dispatch_target()}
          | {:select_option, binary(), binary()}
          | {:open_detail, binary(), binary()}
          | {:detail_page, :next | :previous}
          | {:retry_page, :shell | :workspace | :activity | :inspector, :before | :after}
          | {:field_editor, FieldKey.t(), Operation.t()}
          | {:layout_adjust, :navigator | :inspector,
             :reset
             | {:preset, :compact | :balanced | :wide}
             | {:nudge, -8 | -2 | 2 | 8}}
          | {:composer_height, :reset | {:nudge, -1 | 1}}
          | {:complete_command, binary()}
          | {:library_page, :next | :previous | :refresh}
          | {:library_command, atom(), binary(), atom()}
          | {:library_select, binary()}
          | {:research_depth, :low | :medium | :high | :ultra}
          | :research_start
          | :feature_submit
          | {:feature_cycle, binary(), -1 | 1}
          | {:library_confirm, boolean()}
          | {:presenter_handoff_requested, :plain}
          | {:presenter_handoff_confirmed, :plain}
          | {:navigate, Destination.t()}
          | {:open_layer, LayerSpec.t()}
          | {:dashboard_filter, {:append, binary()} | :backspace | :clear}
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
  def validate(action)
      when action in [
             :boot,
             :back,
             :close_top_layer,
             :editor_detach_notice,
             :open_companion,
             :nothing_waiting
           ],
      do: {:ok, action}

  def validate({:open_interaction, id} = action),
    do: valid_action(action, SwarmCodeCLI.UI.Intent.valid_id?(id))

  # Esc and Ctrl-C both stop the turn in view; which key asked decides what
  # else happens (Ctrl-C clears a draft first and arms the second-press quit).
  def validate({:interrupt, source} = action),
    do: valid_action(action, source in [:escape, :ctrl_c])

  def validate(:select_mode), do: {:ok, :select_mode}

  # Enter in the composer before the workspace is ready: the reducer keeps
  # the draft as one deferred send and replays it once the watch is (R2).
  def validate(:defer_send), do: {:ok, :defer_send}
  def validate(:copy_selection), do: {:ok, :copy_selection}

  # A printable key pressed in select mode leaves it and types: one fragment,
  # bounded like any editor insert.
  def validate({:compose, text} = action),
    do: valid_action(action, match?({:ok, _}, Operation.validate({:insert, text})))

  def validate({:history, direction} = action),
    do: valid_action(action, direction in [:previous, :next])

  def validate({:slash_local, command} = action),
    do:
      valid_action(
        action,
        command in [:help, :quit, :new, :resume, :conversations, :queue, :approval, :trust]
      )

  def validate({:open_conversation, id} = action), do: valid_action(action, Intent.valid_id?(id))
  def validate(:new_conversation), do: {:ok, :new_conversation}

  # `@path` completion: a path is one of the rows the service sent, bounded
  # like any id; the reducer checks it is one of them.
  def validate({:complete_path, path} = action), do: valid_action(action, Intent.valid_id?(path))
  def validate(:dismiss_completion), do: {:ok, :dismiss_completion}

  # Ctrl-X: the draft goes to $VISUAL/$EDITOR. The session runtime answers
  # with the edited text (bounded like a paste) or one of a closed set of
  # reasons; only the runtime itself sends the answer.
  def validate({:external_editor, key} = action),
    do: valid_action(action, match?({:ok, _}, DraftKey.validate(key)))

  def validate({:external_edit_done, key, {:ok, text}} = action),
    do:
      valid_action(
        action,
        match?({:ok, _}, DraftKey.validate(key)) and
          (text == "" or match?({:ok, _}, Operation.validate({:paste, text})))
      )

  def validate({:external_edit_done, key, {:error, reason}} = action),
    do:
      valid_action(
        action,
        match?({:ok, _}, DraftKey.validate(key)) and external_edit_error?(reason)
      )

  def validate({:toggle_dock, dock} = action),
    do: valid_action(action, dock == :inspector)

  def validate({:library_page, direction} = action),
    do: valid_action(action, direction in [:next, :previous, :refresh])

  def validate({:library_command, feature, id, action} = value),
    do:
      valid_action(
        value,
        feature in SwarmCodeCLI.UI.Library.features() and Intent.valid_id?(id) and
          action in [
            :start,
            :pause,
            :resume,
            :stop,
            :delete,
            :restore,
            :retry,
            :report,
            :toggle,
            :run_now,
            :update,
            :clear,
            :diff
          ]
      )

  def validate({:library_select, id} = action), do: valid_action(action, Intent.valid_id?(id))

  def validate({:research_depth, depth} = action),
    do: valid_action(action, depth in [:low, :medium, :high, :ultra])

  def validate(:research_start), do: {:ok, :research_start}
  def validate(:feature_submit), do: {:ok, :feature_submit}

  def validate({:feature_cycle, field, direction} = action),
    do: valid_action(action, SwarmCodeCLI.UI.Intent.valid_id?(field) and direction in [-1, 1])

  def validate({:library_confirm, value} = action), do: valid_action(action, is_boolean(value))

  def validate({:select_agent, id} = action),
    do: valid_action(action, is_binary(id) and id != "")

  def validate({:set_tab, tab} = action),
    do: valid_action(action, tab in [:agents, :timeline, :changes])

  def validate({:set_keymap, keymap} = action),
    do: valid_action(action, keymap in [:default, :vim])

  # `:next`/`:previous` cycle the stable run order; 1..4 pick the tab drawn at
  # that position, which is the only thing an Alt-digit accelerator can mean.
  def validate({:run_tab, target} = action),
    do: valid_action(action, target in [:next, :previous] or target in 1..4)

  def validate({:inspector_tab, direction} = action),
    do: valid_action(action, direction in [:next, :previous])

  # The composer's vim state moves through actions so that one keystroke is
  # still one action: a mode, a pending operator (nil cancels the count too), a
  # count, or an edit followed by a mode for the keys that do both (`cw`, `o`).
  def validate({:vim, {:mode, mode}} = action), do: valid_action(action, mode in Vim.modes())

  def validate({:vim, {:pending, pending}} = action),
    do:
      valid_action(action, is_nil(pending) or pending in Keymap.Vim.operators() or pending == "g")

  def validate({:vim, {:count, count}} = action),
    do:
      valid_action(
        action,
        is_nil(count) or (is_integer(count) and count >= 1 and count <= Vim.max_count())
      )

  def validate({:vim, {:edit_then, operations, mode}} = action),
    do:
      valid_action(
        action,
        is_list(operations) and operations != [] and mode in Vim.modes() and
          Enum.all?(operations, &match?({:ok, _}, Operation.validate(&1)))
      )

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

  def validate({:open_detail, run_id, ref_id} = action),
    do: valid_action(action, Intent.valid_id?(run_id) and Intent.valid_id?(ref_id))

  def validate({:detail_page, direction} = action),
    do: valid_action(action, direction in [:next, :previous])

  def validate({:select_option, interaction_id, option_id} = action),
    do: valid_action(action, Intent.valid_id?(interaction_id) and Intent.valid_id?(option_id))

  def validate({:draft_target, key, target} = action),
    do:
      valid_action(
        action,
        match?({:ok, _}, DraftKey.validate(key)) and
          (target == :none or Intent.valid_dispatch_target?(target))
      )

  def validate({:retry_page, slot, direction} = action),
    do:
      valid_action(
        action,
        slot in [:shell, :workspace, :activity, :inspector] and direction in [:before, :after]
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

  def validate({:complete_command, name} = action),
    do: valid_action(action, SwarmCodeCLI.UI.SlashPalette.valid_name?(name))

  def validate({:presenter_handoff_requested, :plain} = action), do: {:ok, action}
  def validate({:presenter_handoff_confirmed, :plain} = action), do: {:ok, action}

  def validate({:navigate, destination} = action),
    do: valid_action(action, match?({:ok, _destination}, Destination.validate(destination)))

  def validate({:open_layer, layer} = action),
    do: valid_action(action, match?({:ok, _layer}, LayerSpec.validate(layer)))

  def validate({:dashboard_filter, operation} = action),
    do: valid_action(action, valid_filter_operation?(operation))

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

  defp valid_filter_operation?(operation) when operation in [:backspace, :clear], do: true

  defp valid_filter_operation?({:append, fragment}) when is_binary(fragment),
    do:
      fragment != "" and byte_size(fragment) <= @max_filter_fragment_bytes and
        String.valid?(fragment) and printable_fragment?(fragment)

  defp valid_filter_operation?(_operation), do: false

  # A filter query is drawn inline in the dashboard header, so only printable
  # graphemes may enter it: control codes, tabs and newlines are not typing.
  defp printable_fragment?(fragment) do
    fragment
    |> String.to_charlist()
    |> Enum.all?(&(&1 >= 0x20 and &1 != 0x7F and not (&1 >= 0x80 and &1 <= 0x9F)))
  end

  defp valid_layout_adjustment?(:reset), do: true
  defp valid_layout_adjustment?({:preset, preset}), do: preset in [:compact, :balanced, :wide]
  defp valid_layout_adjustment?({:nudge, amount}), do: amount in [-8, -2, 2, 8]
  defp valid_layout_adjustment?(_adjustment), do: false

  defp valid_capabilities?(%Capabilities{} = capabilities) do
    map_size(capabilities) == 18 and
      Enum.sort(Map.keys(capabilities)) == Enum.sort(@capability_keys) and
      Size.valid?(capabilities.size) and
      capabilities.color_mode in [:truecolor, :ansi256, :ansi16, :monochrome] and
      capabilities.ambiguous_width in [:narrow, :wide] and
      boolean?(capabilities.ascii?) and boolean?(capabilities.reduced_motion?) and
      boolean?(capabilities.tty?) and boolean?(capabilities.controlling_tty?) and
      boolean?(capabilities.stdin_tty?) and boolean?(capabilities.stdout_tty?) and
      boolean?(capabilities.full_screen?) and feature?(capabilities.enhanced_keys) and
      feature?(capabilities.focus) and feature?(capabilities.paste) and
      capabilities.mouse in [:unavailable, :best_effort] and
      feature?(capabilities.alternate_screen) and
      boolean?(capabilities.paste_preallocation_bound?) and
      capabilities.glyph_tier in [:measured, :rich]
  end

  defp valid_capabilities?(_capabilities), do: false
  defp feature?(value), do: value in [:supported, :best_effort, :unavailable]
  defp boolean?(value), do: is_boolean(value)
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp valid_action(action, true), do: {:ok, action}
  defp valid_action(_action, false), do: {:error, :invalid_action}

  @external_edit_errors [:unavailable, :too_large, :not_utf8, :terminal, :busy]

  @typedoc "Why an external edit left the draft as it was."
  @type external_edit_error ::
          :unavailable | :too_large | :not_utf8 | :terminal | :busy | {:exit, 1..255}

  @doc "True for a reason the runtime may report for an external edit."
  def external_edit_error?({:exit, status}), do: is_integer(status) and status in 1..255
  def external_edit_error?(reason), do: reason in @external_edit_errors
end
