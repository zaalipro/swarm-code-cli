defmodule SwarmCodeCLI.UI.Projector.Workspace do
  @moduledoc false
  # The palette chord comes from the binding table at compile time, so a
  # rebind re-spells this text.
  @palette_key SwarmCodeCLI.UI.Projector.KeyLabel.primary(
                 SwarmCodeCLI.UI.Keymap.Bindings.fetch(:command_palette)
               )
  alias SwarmCodeCLI.UI.{SafeText, SlashPalette, Theme}
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  alias SwarmCodeCLI.UI.Paint.{Metrics, Options}
  alias SwarmCodeCLI.UI.Projector.{ApprovalCard, Composer, Density, RunRow, Support}
  alias SwarmCodeCLI.UI.Projector.Workspace.Turns

  @enter_key SwarmCodeCLI.UI.Projector.KeyLabel.primary(
               SwarmCodeCLI.UI.Keymap.Bindings.fetch(:send)
             )

  # Main is the conversation. What used to sit above it (the title again, a
  # "Waiting for you" banner, a headline, a notice, an action row) is gone:
  # the run is on the tab row, what waits is on the status line and in the
  # composer slot, feedback is a toast on the status line, and the actions
  # are keys. What stays above the transcript is only what nothing else
  # says: a draft's target or validation, and the plan, goal or ultra panel.
  def project(state, rect, class) do
    head = head(state, rect, class)
    popup = popup(state, rect)
    height = content_height(state, rect, class, head) - length(popup)

    content =
      cond do
        state.destination == :activity -> activity_content(state, rect.width, height)
        Turns.view_order(state) != [] -> content(state, rect.width, height)
        true -> welcome_content(state, rect.width, height)
      end

    # The transcript fills what is left; a short one leaves blank rows between
    # it and the popup, so the popup always sits on the composer.
    filler =
      if popup == [],
        do: [],
        else: List.duplicate(Support.text(" ", state, 1), max(0, height - painted_rows(content)))

    head ++ content ++ filler ++ popup
  end

  # What sits at the bottom of main, on the composer: the rows an approval
  # card grew into main, else the slash popup completing the draft.
  defp popup(state, rect) do
    case ApprovalCard.layout(state, rect.width) do
      %{rows: rows, growth: growth} ->
        rows |> Enum.take(growth) |> Composer.card_blocks(state, rect.width)

      nil ->
        cond do
          state.layers != [] ->
            []

          SlashPalette.open?(state) ->
            Enum.take(Composer.slash_popup(state, rect.width), max(0, rect.height - 4))

          (paths = path_completion(state)) != [] ->
            Enum.take(Composer.path_popup(paths, state, rect.width), max(0, rect.height - 4))

          true ->
            []
        end
    end
  end

  # E5's `@path` completion (`state.path_completion`: `%{items, index,
  # dismissed?}`, kept by `Reducer.PathCompletion`, which clears it whenever
  # the caret leaves the token): the window of eight rows around the
  # selection, as `PathCompletion.visible/2` makes it. Read with Map.get so
  # this compiles before owner E's branch is merged.
  @path_rows 8

  defp path_completion(state) do
    case Map.get(state, :path_completion) do
      %{items: [_ | _] = items, index: selected} = completion ->
        if Map.get(completion, :dismissed?, false) do
          []
        else
          first = max(0, min(selected, length(items) - @path_rows))

          items
          |> Enum.with_index()
          |> Enum.drop(first)
          |> Enum.take(@path_rows)
          |> Enum.map(fn {item, position} -> Map.put(item, :selected?, position == selected) end)
        end

      _ ->
        []
    end
  end

  defp painted_rows([%Block.VirtualList{items: items}]),
    do:
      Enum.reduce(items, 0, fn
        %Block.RichText{spans: spans}, sum -> sum + newline_count(spans) + 1
        _, sum -> sum + 1
      end)

  defp painted_rows(_), do: 0

  defp newline_count(spans), do: Enum.count(spans, &(SafeText.value(&1.text) == "\n"))

  @doc "Exact Main text viewport rows after the few rows of head that remain."
  def content_height(state, rect, class),
    do: content_height(state, rect, class, head(state, rect, class)) - length(popup(state, rect))

  defp content_height(_state, rect, _class, []), do: max(0, rect.height)

  defp content_height(state, rect, _class, head) do
    {blocks, _measurement_actions} = Support.finalize(head, state.revision)

    options = %Options{
      color_mode: state.capabilities.color_mode,
      ascii?: state.capabilities.ascii?,
      glyph_tier: state.capabilities.glyph_tier
    }

    {:ok, head_height} =
      Metrics.height(
        blocks,
        min(rect.width, 500),
        options,
        min(rect.height, 200),
        state.capabilities.ambiguous_width
      )

    max(0, rect.height - head_height)
  end

  defp head(state, rect, class) do
    run = Support.run(state)
    facts = Composer.facts(state, rect.width)
    panel = if run, do: mode_panel(state, run, rect.width, class), else: []
    panel = if panel == [], do: [], else: panel ++ [Support.text(" ", state, rect.width)]
    facts ++ trust_banner(state, rect.width) ++ panel
  end

  # A project the user has not trusted runs read-only (pass 63 trust): say so
  # once, above the conversation, with the command that changes it.
  defp trust_banner(state, width) do
    workspace = Map.get(state.read_model.snapshots, :workspace)

    if workspace && Map.get(workspace, :trusted) == false do
      warn = %{RunRow.tinted(:warning, state) | modifiers: [:bold]}
      text = RunRow.tinted(:text_muted, state)
      key = %{RunRow.tinted(:key, state) | modifiers: [:bold]}

      # pass72: beside the docked panel main can be 73 columns; the short
      # form keeps the command on the row.
      words =
        if width >= 80,
          do: "This project is not trusted, so SwarmCode only reads it. ",
          else: "This project is not trusted: read only. "

      spans =
        [
          {"  ! ", warn},
          {words, text},
          {"/trust", key},
          {" trusts it.", text}
        ]
        |> Enum.map(fn {words, style} ->
          %Span{text: Density.safe(words, state, width), style: style}
        end)

      [%Block.RichText{spans: spans}, Support.text(" ", state, width)]
    else
      []
    end
  end

  @doc """
  The actions the keys reach that are no longer drawn: the run's controls,
  send and steer, what waits on the user, mark seen, the full-text openers,
  the page retries and the plan gate. The projector puts them in the action
  table without a block, so `Keymap.find_target/3` still finds them.
  """
  def keyboard_actions(state, class) do
    run = Support.run(state)

    if class in [:compressed_small, :too_small] do
      [
        Support.action(SafeText.chrome(:resize_help), {:local, {:open_layer, :help}}),
        Support.action(SafeText.chrome(:detach), {:local, {:quit_requested, :detach}}),
        Support.action(
          SafeText.chrome(:plain_exit),
          {:local, {:presenter_handoff_requested, :plain}}
        )
      ]
    else
      run_deck_actions(state, run, class) ++
        Composer.actions(state, class) ++
        interaction_actions(state, class) ++
        slot_decisions(state) ++
        seen_actions(state) ++
        detail_actions(state) ++
        recovery_actions(state, class) ++
        if(run, do: plan_gate_actions(state, run) ++ agent_stop_actions(state, run), else: [])
    end
  end

  # pass72: the side panel draws no controls (P1), so stopping one agent of the
  # run in view stays reachable from the keys (the palette, the agent overlay)
  # through these undrawn actions, each only where the daemon allows it.
  defp agent_stop_actions(state, run) do
    for agent <- SwarmCodeCLI.UI.Projector.Inspector.Hive.agents(state, run.id),
        agent.id != run.id,
        Support.allowed?(state, agent, :stop_agent),
        do:
          Support.action(
            SafeText.chrome(:stop),
            {:intent, {:stop_agent, run.id, agent.id, agent.revision}}
          )
  end

  # An empty conversation: what this is, the three keys that start everything,
  # and the model that will answer.
  defp welcome_content(state, width, height) when height > 0 do
    mode = Composer.mode_label(state)

    {headline, detail} =
      case mode do
        "Plan" -> {"Ready to plan", "Describe the change and I will map the safest steps."}
        "Goal" -> {"Goal mode", "Set the objective for every run in this conversation."}
        "Ultra" -> {"Ready for ultra", "Big tasks become staged workflows with visible progress."}
        "Workflow" -> {"Workflow authoring", "Describe the automation you want to create."}
        "Consensus" -> {"Ready for consensus", "Ask for a plan that a second model will judge."}
        _ -> {"Ready to build", "Ask for a change, inspect the project, or choose a mode."}
      end

    workspace = Map.get(state.read_model.snapshots, :workspace)
    model = if workspace, do: Map.get(workspace, :chat_model), else: nil
    project = if workspace, do: Map.get(workspace, :project), else: nil
    mark = SafeText.value(Support.glyph(:assistant_mark, state))
    accent = RunRow.tinted(:accent, state)
    faint = RunRow.tinted(:text_faint, state)
    muted = RunRow.tinted(:text_muted, state)
    plain = RunRow.tinted(:text_primary, state)

    line = fn spans ->
      %Block.RichText{
        spans:
          Enum.map(spans, fn {text, style} ->
            %Span{text: Density.safe(text, state, width), style: style}
          end)
      }
    end

    keys = [
      {@enter_key, "send"},
      {"/", "commands"},
      {@palette_key, "workflows, research, memory, settings"}
    ]

    blocks =
      [
        line.([{" ", plain}]),
        line.([
          {"  " <> mark <> " ", %{accent | modifiers: [:bold]}},
          {headline, %{plain | modifiers: [:bold]}}
        ]),
        line.([{"    " <> detail, muted}]),
        line.([{" ", plain}])
      ] ++
        Enum.map(keys, fn {key, words} ->
          line.([
            {"    " <> String.pad_trailing(key, 8),
             %{RunRow.tinted(:key, state) | modifiers: [:bold]}},
            {words, muted}
          ])
        end) ++
        [
          line.([{" ", plain}]),
          line.(
            [{"    ", plain}] ++
              if(project, do: [{project, plain}, {"  ·  ", faint}], else: []) ++
              [
                {if(is_binary(model) and model != "", do: model, else: "model from Settings"),
                 faint}
              ]
          )
        ]

    [
      %Block.VirtualList{
        total_count: length(blocks),
        first_index: 0,
        items: Enum.take(blocks, height),
        overscan: 0
      }
    ]
  end

  defp welcome_content(_state, _width, _height), do: []

  defp mode_panel(state, run, width, class) do
    plan? = match?(%{mode: :plan}, Map.get(state.read_model.snapshots, :workspace))

    cond do
      run.kind == :goal and class in [:xl, :wide] ->
        # Goal sidecard at xl/wide: title bold in run_goal, subtitle, progress
        [
          Support.styled(run.title, :run_goal, state, width),
          Support.styled("Persistent objective", :text_muted, state, width),
          progress(run, state, width)
        ]

      run.kind == :goal ->
        [Support.styled("Goal progress", :run_goal, state, width), progress(run, state, width)]

      run.kind == :ultra ->
        [Support.styled(pipeline_stages(state), :run_ultra, state, width)]

      plan? ->
        plan_panel(state, run, width)

      true ->
        []
    end
  end

  defp progress(run, _state, _width) do
    {_prefix, role} = Theme.run_kind(kind(run.kind))

    %Block.Gauge{
      tone: role,
      value: run.progress || 0,
      maximum: if(is_nil(run.progress), do: 0, else: 100),
      style: :ticks,
      label: nil
    }
  end

  defp plan_panel(state, run, width) do
    items =
      state.read_model.transcript
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.filter(fn {_, i} -> i.run_id == run.id end)
      |> Enum.flat_map(fn {_, i} ->
        Regex.scan(~r/^\s*- \[([ xX])\]\s+(.+)$/m, i.text || "", capture: :all_but_first)
        |> Enum.map(fn [mark, label] -> {mark in ["x", "X"], label} end)
      end)

    heading = [Support.section_heading("Plan steps", state, width)]

    checklist =
      if items == [] do
        [Support.styled("No checklist items reported yet.", :text_muted, state, width)]
      else
        Enum.map(items, fn {done, label} ->
          glyph =
            if done,
              do: SafeText.value(Support.glyph(:plan_done, state)),
              else: SafeText.value(Support.glyph(:glyph_inactive, state))

          Support.styled(glyph <> " " <> label, :body, state, width)
        end)
      end

    gate = plan_gate_actions(state, run)
    heading ++ checklist ++ gate
  end

  defp plan_gate_actions(state, run) do
    # Decision 23: plan gate uses :approve / :deny from pending approval interactions.
    # Find pending approval interactions for this run.
    approval =
      state.read_model.interactions
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.find(fn {_, item} ->
        item.run_id == run.id and item.kind == :approval and item.state == :pending and
          not superseded?(state, item)
      end)

    case approval do
      {id, _item} ->
        approve_action =
          if Support.allowed?(state, run, :approve),
            do: [
              Support.action(
                SafeText.chrome(:plan_approve),
                {:local, {:open_layer, {:approval, id}}}
              )
            ],
            else: []

        decline_action =
          if Support.allowed?(state, run, :deny),
            do: [
              Support.action(
                SafeText.chrome(:plan_decline),
                {:local, {:open_layer, {:approval, id}}}
              )
            ],
            else: []

        steer_action =
          if Support.allowed?(state, run, :steer),
            do: [
              Support.action(
                SafeText.chrome(:plan_revise),
                {:local, {:open_layer, {:approval, id}}}
              )
            ],
            else: []

        approve_action ++ steer_action ++ decline_action

      nil ->
        []
    end
  end

  defp activity_content(state, width, height) do
    items =
      state.read_model.activity |> Enum.sort_by(fn {_, item} -> urgency_rank(item.state) end)

    blocks =
      items
      |> Enum.take(height)
      |> Enum.map(fn {_, item} ->
        {word, role} = Theme.status(item.state)
        Support.styled(SafeText.value(word) <> " · " <> item.title, role, state, width)
      end)

    [%Block.VirtualList{total_count: length(items), first_index: 0, items: blocks, overscan: 0}]
  end

  # Activity urgency sort: pending first, then running/streaming, then failed, then everything else.
  defp urgency_rank(:waiting_question), do: 0
  defp urgency_rank(:waiting_approval), do: 0
  defp urgency_rank(:running), do: 1
  defp urgency_rank(:streaming), do: 1
  defp urgency_rank(:failed), do: 2
  defp urgency_rank(_), do: 3

  defp detail_actions(state) do
    run = Support.run(state)

    # One action per kind of detail, for the newest item that has it, labelled
    # by what it opens: two anonymous "Full text" buttons told the user nothing.
    items =
      state.read_model.transcript
      |> Enum.sort_by(&elem(&1, 0), :desc)
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(&(run && &1.run_id == run.id))

    # pass71 F1/F2 (review R1/R2): the selected item's own text first, so
    # Enter and `o` on a cut reply or a long command output open that item.
    chosen = Map.get(state.read_model.transcript, Map.get(state.selection, "main"))

    chosen =
      if (match?(%{detail_ref: %{id: _}}, chosen) and run) && chosen.run_id == run.id,
        do: chosen,
        else: Enum.find(items, &(not is_nil(&1.detail_ref)))

    text =
      case chosen do
        %{role: :user} = item -> [{"Full prompt", item}]
        %{kind: :tool} = item -> [{"Full output", item}]
        %{} = item -> [{"Full reply", item}]
        nil -> []
      end

    reasoning =
      case Enum.find(items, &(not is_nil(&1.reasoning_detail_ref))) do
        %{} = item -> [{"Full reasoning", item}]
        nil -> []
      end

    # The selected edit's diff, else the newest one in the conversation.
    selected = Map.get(state.selection, "main")

    edits =
      state.read_model.transcript
      |> Map.values()
      |> Enum.filter(&match?(%{tool: %{diff_ref: %{id: id}}} when is_binary(id), &1))
      |> Enum.sort_by(&{&1.created_sequence, &1.id}, :desc)

    diff =
      case Enum.find(edits, &(&1.id == selected)) || List.first(edits) do
        nil -> []
        item -> [{"Open diff", item}]
      end

    Enum.map(text ++ reasoning ++ diff, fn {label, item} ->
      ref =
        case label do
          "Full reasoning" -> item.reasoning_detail_ref
          "Open diff" -> item.tool.diff_ref
          _ -> item.detail_ref
        end

      Support.action(
        Density.safe(label, state, 40),
        {:local, {:open_detail, item.run_id, ref.id}}
      )
    end)
  end

  defp seen_actions(state) do
    workspace = Map.get(state.read_model.snapshots, :workspace)

    conversation =
      if workspace && is_binary(Map.get(workspace, :conversation_id)) &&
           state.destination == {:conversation, workspace.conversation_id} &&
           Support.allowed?(state, workspace, :mark_seen),
         do: [
           Support.action(
             SafeText.chrome(:mark_seen),
             {:intent, {:mark_seen, :conversation, workspace.conversation_id, workspace.revision}}
           )
         ],
         else: []

    activity =
      if state.destination == :activity do
        state.read_model.activity
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.filter(fn {_, item} -> Support.allowed?(state, item, :mark_seen) end)
        |> Enum.take(2)
        |> Enum.map(fn {id, item} ->
          Support.action(
            SafeText.chrome(:mark_seen),
            {:intent, {:mark_seen, :activity, id, item.revision}}
          )
        end)
      else
        []
      end

    conversation ++ activity
  end

  # The decisions of the approval in the composer slot: the card draws them
  # as key hints, so their targets live here for the keys to find.
  defp slot_decisions(state) do
    case Composer.waiting_approvals(state) do
      [item | _] ->
        decisions =
          for {_decision, _key, words, target} <- Composer.approval_decisions(state, item),
              do: Support.action(Density.safe(words, state, 40), target)

        # The whole arguments, when the preview is only their start.
        full =
          case item.approval && item.approval.arguments_detail_ref do
            %{id: ref} ->
              [
                Support.action(
                  Density.safe("Full arguments", state, 40),
                  {:local, {:open_detail, item.run_id, ref}}
                )
              ]

            _ ->
              []
          end

        decisions ++ full

      [] ->
        []
    end
  end

  defp interaction_actions(state, _class) do
    state.read_model.interactions
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.filter(fn {_, item} -> item.state == :pending and not superseded?(state, item) end)
    |> Enum.take(2)
    |> Enum.map(fn {id, item} ->
      label =
        if item.kind == :question, do: :status_waiting_question, else: :status_waiting_approval

      Support.action(SafeText.chrome(label), {:local, {:open_layer, {item.kind, id}}})
    end)
  end

  defp run_deck_actions(_state, nil, _class), do: []

  defp run_deck_actions(state, run, class) do
    enabled = class not in [:compressed_small, :too_small] and run.state != :superseded
    retry? = enabled and run.state == :failed and Support.allowed?(state, run, :retry)
    resume? = enabled and run.state == :interrupted and Support.allowed?(state, run, :resume)

    if enabled,
      do:
        run_actions(state, run, retry?, resume?) ++
          [
            Support.action(
              SafeText.chrome(:inspect),
              {:local, {:open_layer, {:run_inspector, run.id, :overview}}}
            )
          ],
      else: []
  end

  defp run_actions(state, run, retry?, resume?) do
    retry =
      if retry?,
        do: [
          Support.action(SafeText.chrome(:retry), {:intent, {:retry_run, run.id, run.revision}})
        ],
        else: []

    resume =
      if resume?,
        do: [Support.action(SafeText.chrome(:resume), {:intent, {:run_control, :resume, run.id}})],
        else: []

    controls =
      for operation <- [:pause, :continue, :stop],
          Support.allowed?(state, run, operation),
          do:
            Support.action(
              SafeText.chrome(operation),
              {:intent, {:run_control, operation, run.id}}
            )

    seen =
      if Support.allowed?(state, run, :mark_seen),
        do: [
          Support.action(
            SafeText.chrome(:mark_seen),
            {:intent, {:mark_seen, :run, run.id, run.revision}}
          )
        ],
        else: []

    retry ++ resume ++ controls ++ seen
  end

  defp content(state, width, height) do
    {blocks, first, total} = Turns.viewport(state, width, height)

    [
      %Block.VirtualList{
        total_count: total,
        first_index: first,
        items: blocks,
        before_cursor: cursor(state, :before_cursor),
        after_cursor: cursor(state, :after_cursor),
        overscan: 0
      }
    ]
  end

  defp cursor(state, key) do
    case Map.get(state.pages, :workspace) do
      nil -> nil
      page -> Map.get(page, key)
    end
  end

  # A slot whose page failed or went stale can be asked again; the status line
  # says which, and these are the keys' targets.
  defp recovery_actions(state, class) do
    state
    |> Support.recovering_pages()
    |> Enum.flat_map(fn {slot, page} ->
      if page.status in [:error, :stale, :disconnected, :resyncing] and
           class != :compressed_small do
        direction = if page.direction in [:before, :after], do: page.direction, else: :after

        [
          Support.action(SafeText.chrome(:retry), {:local, {:retry_page, slot, direction}}),
          Support.action(SafeText.chrome(:diagnostics), {:local, {:open_layer, :help}})
        ]
      else
        []
      end
    end)
  end

  defp superseded?(state, interaction) do
    case Map.get(state.read_model.runs, interaction.run_id) do
      %{state: :superseded} -> true
      _ -> false
    end
  end

  defp kind(:chat), do: :assistant
  defp kind(:consensus), do: :consensus_judge
  defp kind(kind), do: kind

  # The stage arrow is catalogue chrome, so it must go through Support.glyph/2 to get its
  # one-cell ASCII twin; a literal ❯ would survive into ASCII mode (NOTES_2 #36).
  defp pipeline_stages(state) do
    arrow = SafeText.value(Support.glyph(:pipeline_arrow, state))
    "Plan " <> arrow <> " build " <> arrow <> " verify"
  end
end
