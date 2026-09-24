defmodule SwarmCodeCLI.UI.Keymap do
  @moduledoc """
  Single-action input resolution, driven by one table.

  `UI.Keymap.Bindings` is the grammar; this module is only the machine that
  runs it:

    1. lifecycle inputs (focus, resize, paste, rejections) answer first,
    2. `UI.Keymap.Context.of/1` names the one context this keystroke is read
       against,
    3. the table is looked up for `{context, {code, mods}}`; a literal action is
       validated and returned, `{:editor_op, op}` is aimed at whichever editor
       the context owns, and `{:special, name}` goes to `UI.Keymap.Special`,
    4. anything unbound — or a binding that declined, or an auto-repeat of a
       binding that does not repeat — falls through to typing: the composer, a
       field editor, or a picker's filter,
    5. `:ignore`.

  A text fragment carries its shift in the character itself, so a lone `:shift`
  is dropped before lookup (`"G"` is a code, not `"g"` plus a modifier). A
  `:shift` alongside a command modifier is kept: `Ctrl-Shift-Z` is not
  `Ctrl-Z`.
  """

  alias SwarmCodeCLI.UI.{
    Action,
    Drafts,
    Editor,
    Input,
    Layout,
    ModelPicker,
    Question,
    State,
    Switcher,
    WorkflowKeyword
  }

  alias SwarmCodeCLI.UI.Keymap.{Bindings, Context, Special}

  @spec resolve(term(), map(), map()) :: {:ok, Action.t()} | :ignore
  def resolve(input, state, table) when is_map(table) do
    case Input.validate(input) do
      {:ok, input} -> route(input, state, table)
      _ -> :ignore
    end
  end

  def resolve(_, _, _), do: :ignore

  @doc """
  Whether `input` is plain typing into the composer: a printable fragment or a
  Backspace that no binding of the composer claims, outside the grace and
  confirmation paths. Such a key resolves to an edit of the draft without
  looking at the action table, so the session may apply it before the table
  of the previous keystroke has been projected (pass70 Q4).
  """
  @spec typing?(term(), map()) :: boolean()
  def typing?({:text_fragment, phase, text, mods}, state)
      when phase in [:press, :repeat] and is_binary(text),
      do: plain_typing?(text, fragment_mods(mods), phase, state)

  def typing?({:key, phase, :backspace, []}, state) when phase in [:press, :repeat],
    do: plain_typing?(:backspace, [], phase, state)

  def typing?(_input, _state), do: false

  # The agent overlay's composer types the same way (pass72): its own
  # letters (`o [ ] y a …`) are bindings and take the full path.
  defp plain_typing?(code, mods, phase, state) do
    context = Context.of(state)

    mods == [] and context in [:composer, :overlay] and not tiny_unsent?(state) and
      not confirm_exit?(code, mods, phase, state) and not grace?(state) and
      Bindings.lookup(context, code, mods) == nil and
      match?({:ok, _}, Input.validate(input_of(code, phase)))
  end

  defp input_of(:backspace, phase), do: {:key, phase, :backspace, []}
  defp input_of(text, phase), do: {:text_fragment, phase, text, []}

  def activate(target, state, table) do
    if Enum.any?(table, fn {_, current} -> current == target end) do
      case target do
        {:intent, {:dispatch, :send, _, _, _}} -> send_target(target, state)
        {:local, action} -> result(action)
        {:intent, _intent} -> invoke(target, state)
        _ -> :ignore
      end
    else
      :ignore
    end
  end

  @doc """
  What Send does with the current draft, as if its drawn Send target had been
  activated: the action a deferred Enter replays once the workspace is ready
  (pass71 R2). `:ignore` when there is no draft or it is blank.
  """
  @spec draft_send(map()) :: {:ok, Action.t()} | :ignore
  def draft_send(state) do
    case draft_dispatch(state, :send) do
      {:ok, {:invoke, intent, _id}} -> send_target({:intent, intent}, state)
      :ignore -> :ignore
    end
  end

  defp send_target({:intent, {:dispatch, :send, "/workflows", :main, []}}, state)
       when state.banner == :live_banner,
       do: result({:open_layer, {:library, :workflows}})

  defp send_target({:intent, {:dispatch, :send, text, :main, []}}, state)
       when state.banner == :live_banner and text in ["/deep_research", "/deep_research "],
       do: result({:open_layer, {:library, :research}})

  # A bare `/model` or `/swarm_model` has nothing to send yet: it opens the
  # picker, whichever surface pressed Send. The reducer clears the draft as
  # the layer opens. The session's own commands (/help, /quit, /new, /resume,
  # /queue …) never reach the daemon either.
  defp send_target({:intent, {:dispatch, :send, text, :main, []}} = target, state)
       when is_binary(text) do
    case {local_command(text), ModelPicker.opener(text)} do
      {command, _} when not is_nil(command) -> result({:slash_local, command})
      {nil, nil} -> invoke(workflow_route(target), state)
      {nil, picker} -> result({:open_layer, ModelPicker.open(state, picker)})
    end
  end

  defp send_target(target, state), do: invoke(target, state)

  # pass73 T5: a message that names a workflow (`WorkflowKeyword`) goes as
  # `/create-workflow <text>`; the opt-out key (`:send_plain`) skips this.
  defp workflow_route({:intent, {:dispatch, :send, text, :main, []}} = target) do
    routed = {:dispatch, :send, WorkflowKeyword.command(text), :main, []}

    if WorkflowKeyword.routes?(text) and
         match?({:ok, _}, SwarmCodeCLI.UI.Intent.validate(routed)),
       do: {:intent, routed},
       else: target
  end

  @doc """
  Whether an Enter that found no Send target should wait for the workspace:
  a conversation is in view, its watch is still loading, and the draft holds
  text that is not already on its way.
  """
  @spec deferrable_send?(map()) :: boolean()
  def deferrable_send?(state) do
    with {:conversation, _} <- state.destination,
         %{status: status} when status in [:frozen, :resyncing] <-
           Map.get(state.watches, :workspace),
         key when not is_nil(key) <- State.current_draft_key(state),
         false <- Map.has_key?(state.drafts.pending, key) do
      String.trim(draft_text(state)) != ""
    else
      _ -> false
    end
  end

  @local_commands %{
    "/help" => :help,
    "/quit" => :quit,
    "/exit" => :quit,
    "/new" => :new,
    "/clear" => :new,
    "/resume" => :resume,
    "/conversations" => :conversations
  }

  @doc """
  The slash commands the client answers itself, from the draft's text: a bare
  `/help`, `/quit` (`/exit`), `/new` (`/clear`), `/resume`, `/conversations`,
  `/trust`, and `/queue`, `/approval`, `/panel`, `/diff`, `/theme` and
  `/mouse` with or without their argument.
  """
  @spec local_command(binary()) :: atom() | nil
  def local_command(text) when is_binary(text) do
    trimmed = String.trim(text)

    cond do
      Map.has_key?(@local_commands, trimmed) -> Map.fetch!(@local_commands, trimmed)
      command?(trimmed, "/queue") -> :queue
      command?(trimmed, "/approval") -> :approval
      command?(trimmed, "/panel") -> :panel
      command?(trimmed, "/diff") -> :diff
      command?(trimmed, "/theme") -> :theme
      command?(trimmed, "/mouse") -> :mouse
      trimmed == "/trust" -> :trust
      true -> nil
    end
  end

  def local_command(_text), do: nil

  defp command?(text, name), do: text == name or String.starts_with?(text, name <> " ")

  defp invoke({:intent, intent}, state) do
    if destructive?(intent) and not match?([{:confirm_intent, ^intent} | _], state.layers),
      do: result({:open_layer, {:confirm_intent, intent}}),
      else: result({:invoke, intent, elem(State.next_id(state, :request), 0)})
  end

  # ---------------------------------------------------------------- routing

  defp route({:key, :release, _, _}, _, _), do: :ignore
  defp route({:text_fragment, :release, _, _}, _, _), do: :ignore

  defp route({:mouse, kind, _, column, row, _}, state, _) when kind in [:wheel_up, :wheel_down],
    do: wheel(kind, column, row, state)

  defp route({:mouse, _, _, _, _, _}, _, _), do: :ignore

  defp route(:focus_gained, state, _),
    do: result({:terminal_focus, :gained, state.terminal_generation})

  defp route(:focus_lost, state, _),
    do: result({:terminal_focus, :lost, state.terminal_generation})

  defp route({:resize, size}, _, _), do: result({:resize, size})
  defp route({:rejected, reason}, _, _), do: result({:input_rejected, reason})

  defp route({:paste, text}, state, _) do
    if grace?(state), do: draft_edit(state, {:paste, text}), else: edit(state, {:paste, text})
  end

  # Ctrl-Space reaches the port as NUL (pass72, K1): it is the chord the
  # table names Ctrl-Space.
  defp route({:key, phase, :null, mods}, state, table),
    do: dispatch(" ", Enum.sort([:control | mods -- [:control]]), phase, state, table)

  defp route({:key, phase, code, mods}, state, table),
    do: dispatch(code, Enum.sort(mods), phase, state, table)

  defp route({:text_fragment, phase, text, mods}, state, table),
    do: dispatch(text, fragment_mods(mods), phase, state, table)

  # Shift is already spelled in the character. It only survives when another
  # modifier is present, where it really is a distinct chord.
  defp fragment_mods([:shift]), do: []
  defp fragment_mods(mods), do: Enum.sort(mods)

  defp dispatch(code, mods, phase, state, table) do
    cond do
      phase not in [:press, :repeat] ->
        :ignore

      tiny_unsent?(state) ->
        tiny_exit(code, mods, phase, state)

      # The quit confirmation says "X CONFIRM EXIT" at every size, so X
      # confirms it at every size (pass70 F), not only at :too_small.
      confirm_exit?(code, mods, phase, state) ->
        tiny_exit(code, mods, phase, state)

      grace?(state) ->
        grace(code, mods, state)

      typing_over_card?(code, mods, state) ->
        draft_edit(state, if(code == :backspace, do: :delete_backward, else: {:insert, code}))

      true ->
        context = Context.of(state)

        case Bindings.lookup(context, code, mods) do
          nil ->
            fallthrough(context, code, mods, state)

          binding ->
            case bind(binding, {code, mods}, phase, state, table) do
              # A key select mode uses but that declined here (a held "x", "]"
              # with no inspector) is not typing either.
              :ignore when context in [:main, :inspector] -> :ignore
              :ignore -> fallthrough(context, code, mods, state)
              resolved -> resolved
            end
        end
    end
  end

  # An auto-repeat of a binding that does not repeat is not the binding: a held
  # "q" types into a picker filter rather than closing the layer once per frame.
  defp bind(%{repeat: false}, _key, :repeat, _state, _table), do: :ignore

  defp bind(binding, key, _phase, state, table) do
    case binding.action do
      {:special, name} -> Special.run(name, key, state, table)
      {:editor_op, operation} -> edit(state, operation)
      action -> result(action)
    end
  end

  defp fallthrough(context, code, mods, state) when context in [:composer, :field, :overlay],
    do: editor_fallthrough(code, mods, state)

  # Hint mode takes every key: a printable one that is no badge ends it (the
  # reducer says nothing matched), anything else simply ends it. A hint key
  # never reaches the composer or an approval.
  defp fallthrough(:hint, code, [], _state) when is_binary(code),
    do: result({:hint, {:key, code}})

  defp fallthrough(:hint, _code, _mods, _state), do: result({:hint, :cancel})

  defp fallthrough(:picker, code, mods, state), do: picker_fallthrough(code, mods, state)

  # Select mode is a mode, not a trap: a printable key it does not use goes
  # back to the composer and types there.
  defp fallthrough(context, code, [], %{layers: []})
       when context in [:main, :inspector] and is_binary(code),
       do: result({:compose, code})

  defp fallthrough(_context, _code, _mods, _state), do: :ignore

  defp editor_fallthrough(code, mods, state) do
    operation =
      cond do
        code == :backspace and mods == [] -> :delete_backward
        code == :delete and mods == [] -> :delete_forward
        code == :backspace and mods == [:alt] -> :delete_word_backward
        code == :delete and mods == [:alt] -> :delete_word_forward
        code in [:left, :right, :up, :down, :home, :end] -> movement(code, mods)
        is_binary(code) and mods == [] -> {:insert, code}
        true -> nil
      end

    if operation, do: edit(state, operation), else: :ignore
  end

  # The run views keep a plain query string rather than a cursor, so a keystroke
  # is an append or a delete of the last grapheme.
  defp picker_fallthrough(code, mods, %{layers: [{kind, _} | _]})
       when kind in [:runs_dashboard, :run_palette] do
    cond do
      code == :backspace and mods == [] -> result({:dashboard_filter, :backspace})
      is_binary(code) and mods == [] -> result({:dashboard_filter, {:append, code}})
      true -> :ignore
    end
  end

  # The go-to popup is a which-key list. There is nothing to type into it.
  defp picker_fallthrough(_code, _mods, %{layers: [{:jump, _} | _]}), do: :ignore

  defp picker_fallthrough(code, mods, state), do: editor_fallthrough(code, mods, state)

  defp movement(code, mods) do
    base = Enum.reject(mods, &(&1 == :shift))

    movement =
      case {code, base} do
        {:left, [:alt]} -> :word_left
        {:right, [:alt]} -> :word_right
        {:home, [:control]} -> :buffer_start
        {:end, [:control]} -> :buffer_end
        {:home, []} -> :line_start
        {:end, []} -> :line_end
        {code, []} when code in [:left, :right, :up, :down] -> code
        _ -> nil
      end

    if movement, do: {if(:shift in mods, do: :extend_selection, else: :move), movement}
  end

  # ------------------------------------------------------------ grace window

  # An approval or question that opened by itself does not take the keys that
  # were already on their way to the draft: until the user pauses, printable
  # keys and Backspace keep typing underneath it, Esc dismisses it, and
  # everything else (Enter above all) waits.
  # Hint mode, opened over the card, reads its own keys (pass72 F).
  defp grace?(%{hint: %{}}), do: false

  defp grace?(%{interaction_grace: grace, auto_opened: id, layers: [{kind, id} | _]})
       when not is_nil(grace) and kind in [:approval, :question],
       do: true

  defp grace?(_state), do: false

  defp grace(:escape, [], _state), do: result(:close_top_layer)
  defp grace(:backspace, [], state), do: draft_edit(state, :delete_backward)
  defp grace(code, [], state) when is_binary(code), do: draft_edit(state, {:insert, code})
  # pass72 F: the hint chord is deliberate and its keys never answer, so it
  # opens hint mode over a card that has just appeared, as it does later.
  defp grace(code, mods, _state) when mods != [] do
    case Bindings.lookup(:composer, code, mods) do
      %{id: :hint_mode, action: action} -> result(action)
      _ -> :ignore
    end
  end

  defp grace(_code, _mods, _state), do: :ignore

  # pass72 G10 (QA Q11): a card that opened by itself answers only to its
  # own keys (y Y A d D n) while the draft is empty. Any other character, or
  # any character once the draft has text, types into the composer under the
  # card, where the user sees it; "abc" used to approve a command with its
  # "a". A card the user focused (^N, a badge) keeps the whole grammar.
  @card_answers ~w(y Y A d D n)

  defp typing_over_card?(_code, _mods, %{hint: %{}}), do: false

  defp typing_over_card?(code, mods, %{auto_opened: id, layers: [{:approval, id} | _]} = state)
       when not is_nil(id) and (mods == [] or mods == [:shift]) do
    typing? = String.trim(draft_text(state)) != ""

    cond do
      code == :backspace -> typing?
      not is_binary(code) -> false
      not String.printable?(code) or String.length(code) != 1 or code == " " -> typing?
      typing? -> true
      true -> code not in @card_answers
    end
  end

  defp typing_over_card?(_code, _mods, _state), do: false

  defp draft_edit(state, operation) do
    case State.current_draft_key(state) do
      nil -> :ignore
      key -> result({:editor, key, operation})
    end
  end

  # ------------------------------------------------------------ mouse wheel

  # pass70 F (E6's second half, B10's opt-in `SWARM_MOUSE=1` reports): a wheel
  # notch scrolls three lines of what is under the pointer and never moves
  # focus. A paged layer (help, an approval card, a report) takes the wheel
  # while it is open; any other layer (a picker, a form) ignores it.
  @wheel_lines 3

  defp wheel(kind, column, row, state) do
    delta = if kind == :wheel_up, do: -@wheel_lines, else: @wheel_lines

    case state.layers do
      [:help | _] ->
        result({:scroll, "dialog", {:line, delta}})

      [{layer, _} | _] when layer in [:approval, :command_report] ->
        result({:scroll, "dialog", {:line, delta}})

      [_ | _] ->
        :ignore

      [] ->
        result({:scroll, wheel_region(column, row, state), {:line, delta}})
    end
  end

  defp wheel_region(column, row, state) do
    case state.size && Layout.for_state(state).rects do
      %{inspector: %{x: x, y: y, width: w, height: h}}
      when column >= x and column < x + w and row >= y and row < y + h ->
        "inspector"

      _ ->
        "main"
    end
  end

  # ------------------------------------------------------- tiny exit escape

  # At :too_small there is no dialog to read and no focus ring to walk, so the
  # unsent-changes confirmation accepts exactly one key and nothing else.
  defp tiny_unsent?(%{layers: [{:unsent_changes, _} | _]} = state),
    do: Layout.for_state(state).class == :too_small

  defp tiny_unsent?(_state), do: false

  defp confirm_exit?("X", [], :press, %{layers: [{:unsent_changes, kind} | _], exit_pending: kind}),
       do: true

  defp confirm_exit?(_code, _mods, _phase, _state), do: false

  defp tiny_exit("X", _mods, :press, %{
         layers: [{:unsent_changes, kind} | _],
         exit_pending: kind
       }) do
    if kind == :plain,
      do: result({:presenter_handoff_confirmed, :plain}),
      else: result({:quit_confirmed, :detach})
  end

  defp tiny_exit(:escape, [], :press, _state), do: result(:close_top_layer)
  defp tiny_exit(_code, _mods, _phase, _state), do: :ignore

  # ------------------------------------------------------------- activation

  @doc false
  def modal_activate(_, %{focus: focus}, _) when focus in ["cancel", "close"],
    do: result(:close_top_layer)

  def modal_activate({:unsent_changes, kind}, %{focus: "confirm"} = state, table) do
    target =
      if kind == :plain,
        do: {:presenter_handoff_confirmed, :plain},
        else: {:quit_confirmed, :detach}

    activate({:local, target}, state, table)
  end

  def modal_activate({:confirm_intent, intent}, %{focus: "confirm"} = state, table),
    do: activate({:intent, intent}, state, table)

  def modal_activate({:question, id}, state, table) do
    case Map.get(state.read_model.interactions, id) do
      nil ->
        :ignore

      %{question: %{multiple: true}} when state.focus not in ["submit", "other"] ->
        activate({:local, {:select_option, id, state.focus}}, state, table)

      item ->
        case Question.answer_intent(state, item, state.focus) do
          :ignore -> :ignore
          intent -> activate({:intent, intent}, state, table)
        end
    end
  end

  def modal_activate({:approval, _}, state, table),
    do: approval_key(state.focus, state, table)

  def modal_activate({:library, _}, %{focus: focus} = state, _) do
    case SwarmCodeCLI.UI.Library.activation(state, focus) do
      nil -> :ignore
      action -> result(action)
    end
  end

  def modal_activate({:research_form, _}, %{focus: "start"}, _), do: result(:research_start)

  def modal_activate({:research_form, _}, %{focus: focus}, _)
      when focus in ["low", "medium", "high", "ultra"],
      do: result({:research_depth, String.to_atom(focus)})

  def modal_activate({:research_form, _}, _, _), do: :ignore

  def modal_activate({:feature_form, _, _}, %{focus: "submit"}, _), do: result(:feature_submit)

  def modal_activate({:feature_form, _, _}, %{focus: "field:" <> key} = state, _),
    do:
      if(SwarmCodeCLI.UI.FeatureForm.choice?(state, key),
        do: result({:feature_cycle, key, 1}),
        else: :ignore
      )

  def modal_activate({:feature_form, _, _}, _, _), do: :ignore

  # The go-to popup's rows come from the table, so Enter on one does exactly
  # what its letter does.
  def modal_activate({:jump, _}, state, table) do
    case Special.jump_action(state.focus) do
      nil -> :ignore
      action -> activate({:local, action}, state, table)
    end
  end

  def modal_activate({kind, _}, state, table) when kind in [:switcher, :action_menu] do
    entries = Switcher.visible(state, table)

    entry =
      Enum.find(entries, &(&1.id == state.focus)) ||
        if(state.focus == "query", do: List.first(entries))

    if entry, do: activate(entry.target, state, table), else: :ignore
  end

  # A picker row carries the command it sends; Enter on the query picks the
  # first row the query leaves, as in the switcher.
  def modal_activate({:model_picker, _, _} = layer, state, table) do
    rows = ModelPicker.rows(state, layer)

    row =
      Enum.find(rows, &(&1.id == state.focus)) || if(state.focus == "query", do: List.first(rows))

    if row, do: activate({:intent, row.intent}, state, table), else: :ignore
  end

  def modal_activate({kind, _}, state, table)
      when kind in [:runs_dashboard, :run_palette] do
    if Map.has_key?(state.read_model.runs, state.focus),
      do: activate({:local, {:navigate, {:run, state.focus}}}, state, table),
      else: :ignore
  end

  def modal_activate({:run_inspector, run_id, _}, state, table) do
    agent_id = state.focus
    find_target(state, table, &match?({:intent, {:stop_agent, ^run_id, ^agent_id, _}}, &1))
  end

  def modal_activate({:detail, _, _}, state, table) do
    direction =
      case state.focus do
        "next" -> :next
        "previous" -> :previous
        _ -> nil
      end

    if direction, do: activate({:local, {:detail_page, direction}}, state, table), else: :ignore
  end

  def modal_activate(_, _, _), do: :ignore

  @doc false
  def content_activate(state, table) do
    selected = Map.get(state.selection, state.focus)
    activity = state.read_model.activity[selected]

    cond do
      activity && activity.interaction ->
        activate(
          {:local, {:open_layer, {activity.interaction.kind, activity.interaction.id}}},
          state,
          table
        )

      activity ->
        activate({:local, {:navigate, {:run, activity.run_id}}}, state, table)

      Map.has_key?(state.read_model.runs, selected) ->
        activate({:local, {:navigate, {:run, selected}}}, state, table)

      # pass70 Q9: Enter on an edit opens its diff (select mode says "Enter
      # open"); before, it only folded the row open onto "edited x: 1
      # replacement(s)".
      diff = diff_target(state, selected) ->
        case find_target(state, table, &(&1 == diff)) do
          :ignore -> find_target(state, table, &match?({:local, {:expand, ^selected, _}}, &1))
          resolved -> resolved
        end

      # pass71 F1/F2 (review R1/R2): a reply or an output the daemon sent
      # only in part opens whole; "(Enter opens)" used to fold it instead.
      detail = text_target(state, selected) ->
        case find_target(state, table, &(&1 == detail)) do
          :ignore -> find_target(state, table, &match?({:local, {:expand, ^selected, _}}, &1))
          resolved -> resolved
        end

      true ->
        find_target(state, table, &match?({:local, {:expand, ^selected, _}}, &1))
    end
  end

  @doc false
  def text_target(state, selected) do
    case Map.get(state.read_model.transcript, selected) do
      %{run_id: run, detail_ref: %{id: ref}} when is_binary(ref) ->
        {:local, {:open_detail, run, ref}}

      _ ->
        nil
    end
  end

  defp diff_target(state, selected) do
    case Map.get(state.read_model.transcript, selected) do
      %{run_id: run, tool: %{diff_ref: %{id: ref}}} when is_binary(ref) ->
        {:local, {:open_detail, run, ref}}

      _ ->
        nil
    end
  end

  @doc false
  def approval_key("approval_details", %{layers: [{:approval, id} | _]} = state, table) do
    case Map.get(state.read_model.interactions, id) do
      %{run_id: run, approval: %{arguments_detail_ref: %{id: ref}}} ->
        find_target(state, table, &(&1 == {:local, {:open_detail, run, ref}}))

      _ ->
        :ignore
    end
  end

  # Each approval key, and each control a surface draws for it, names a
  # decision. The intent is built from the pending interaction itself rather
  # than looked up among drawn targets, so the keys work wherever the card is
  # drawn; the reducer still authorizes it against the interaction's own
  # allowed decisions, and the daemon compares-and-sets.
  def approval_key(code, %{layers: [{:approval, id} | _]} = state, _table) do
    wanted =
      case code do
        value when value in ["y", "a", "approve"] -> :approve
        value when value in ["Y", "approve_run"] -> :approve_run
        value when value in ["A", "always_allow", "always_prefix"] -> :always
        value when value in ["d", "deny"] -> :deny
        value when value in ["D", "deny_stop"] -> :deny_stop
        _ -> nil
      end

    with true <- wanted != nil,
         %{kind: :approval, state: :pending} = item <- state.read_model.interactions[id],
         decision when not is_nil(decision) <- decision(item, wanted) do
      result(
        {:invoke,
         {:resolve_approval, item.run_id, item.node_id, item.id, item.expected_revision,
          decision}, elem(State.next_id(state, :request), 0)}
      )
    else
      _ -> :ignore
    end
  end

  def approval_key(_code, _state, _table), do: :ignore

  @doc """
  The decisions an approval offers, in key order.

  `allowed_decisions` when the source sends it (on the interaction or its
  approval), otherwise the older permissions: approve, deny and always allow.
  """
  @spec decisions(map()) :: [atom()]
  def decisions(item) do
    explicit =
      Map.get(item, :allowed_decisions) ||
        (is_map(item.approval) && Map.get(item.approval, :allowed_decisions))

    if is_list(explicit) and explicit != [],
      do: explicit,
      else: Enum.filter([:approve, :deny, :always_allow], &(&1 in item.allowed_actions))
  end

  defp decision(item, wanted) do
    offered = decisions(item)

    case wanted do
      :always ->
        Enum.find([:always_prefix, :always_allow], &(&1 in offered))

      wanted ->
        if wanted in offered, do: wanted
    end
  end

  # -------------------------------------------------------------- editors

  @doc """
  Which editor, if any, the current focus is typing into.

  `{:field_editor, key}` while a layer owns a text field, `{:editor, key}` for
  the composer's draft, `nil` when the keystroke is not typing at all.
  """
  @spec editor_context(map()) :: {:field_editor, term()} | {:editor, term()} | nil
  def editor_context(%{layers: [layer | _]} = state) do
    cond do
      state.focus in ["cancel", "confirm"] ->
        nil

      Switcher.field_key(layer) ->
        {:field_editor, Switcher.field_key(layer)}

      match?({:question, _}, layer) and state.focus == "other" ->
        {:question, id} = layer

        case state.read_model.interactions[id] do
          %{state: :pending, expected_revision: revision} ->
            {:field_editor, {:question_other, id, revision}}

          _ ->
            nil
        end

      match?({:research_form, _}, layer) and state.focus == "question" ->
        {:research_form, owner} = layer

        if state.library.command_id == nil,
          do: {:field_editor, {:research_question, owner}},
          else: nil

      match?({:feature_form, _, _}, layer) and String.starts_with?(state.focus, "field:") ->
        case state.feature_form do
          %{command_id: nil, owner: owner} ->
            {:field_editor,
             {:feature_field, owner, String.replace_prefix(state.focus, "field:", "")}}

          _ ->
            nil
        end

      true ->
        nil
    end
  end

  # The agent overlay's composer takes the typing wherever its focus ring is.
  def editor_context(%{overlay: %{draft_key: key}}) when not is_nil(key), do: {:editor, key}

  def editor_context(%{focus: "composer"} = state) do
    case State.current_draft_key(state) do
      nil -> nil
      key -> {:editor, key}
    end
  end

  def editor_context(_), do: nil

  @doc false
  def edit(state, operation) do
    case editor_context(state) do
      {kind, key} -> result({kind, key, operation})
      _ -> :ignore
    end
  end

  @doc false
  def selected_run(state, selected) do
    cond do
      Map.has_key?(state.read_model.runs, selected) -> selected
      state.read_model.transcript[selected] -> state.read_model.transcript[selected].run_id
      state.read_model.activity[selected] -> state.read_model.activity[selected].run_id
      state.read_model.agents[selected] -> state.read_model.agents[selected].run_id
      match?({:run, _}, state.destination) -> elem(state.destination, 1)
      true -> nil
    end
  end

  @doc false
  def find_target(state, table, predicate) do
    table
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.find(fn {_, target} -> predicate.(target) end)
    |> case do
      nil -> :ignore
      {_, target} -> activate(target, state, table)
    end
  end

  # ------------------------------------------------------------ the turn

  @doc """
  The turn in view: the newest top-level run of the conversation on screen
  whose state is one of `states` and which may be stopped.

  A run launched by another run (a swarm the chat agent started) is not the
  turn; stopping it takes an explicit Stop.
  """
  @spec live_turn(map(), [atom()]) :: map() | nil
  def live_turn(
        state,
        states \\ [:queued, :running, :streaming, :retrying]
      ) do
    case State.current_draft_key(state) do
      {conversation, _} ->
        state.read_model.runs
        |> Map.values()
        |> Enum.filter(
          &(&1.conversation_id == conversation and is_nil(&1.parent_run_id) and
              &1.state in states)
        )
        |> Enum.max_by(&{&1.started_at || 0, &1.created_sequence}, fn -> nil end)

      _ ->
        nil
    end
  end

  @doc "The current draft's text, or `\"\"` when no draft is in view."
  @spec draft_text(map()) :: binary()
  def draft_text(state) do
    case State.current_draft_key(state) do
      nil -> ""
      key -> Editor.text(Drafts.fetch(state.drafts, key).editor)
    end
  end

  @doc "The current draft as a send or queue intent, invoked with a fresh request id."
  def draft_dispatch(state, operation) when operation in [:send, :queue] do
    with key when not is_nil(key) <- State.current_draft_key(state),
         draft = Drafts.fetch(state.drafts, key),
         text = Editor.text(draft.editor),
         true <- String.trim(text) != "" do
      target = if draft.target == :none, do: :main, else: draft.target
      refs = Enum.map(draft.attachments, & &1.reference)

      result(
        {:invoke, {:dispatch, operation, text, target, refs},
         elem(State.next_id(state, :request), 0)}
      )
    else
      _ -> :ignore
    end
  end

  defp destructive?({:run_control, :stop, _}), do: true
  defp destructive?({:stop_agent, _, _, _}), do: true
  defp destructive?(_), do: false

  @doc false
  def result(action) do
    case Action.validate(action) do
      {:ok, _} = ok -> ok
      _ -> :ignore
    end
  end
end
