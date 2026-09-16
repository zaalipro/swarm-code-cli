defmodule SwarmCodeCLI.UI.Projector.Workspace do
  @moduledoc false
  # The palette chord comes from the binding table at compile time, so a
  # rebind re-spells this text.
  @palette_key SwarmCodeCLI.UI.Projector.KeyLabel.primary(
                 SwarmCodeCLI.UI.Keymap.Bindings.fetch(:command_palette)
               )
  alias SwarmCodeCLI.UI.{ReadModel, SafeText, Theme, Width}
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  alias SwarmCodeCLI.UI.Paint.{Metrics, Options}
  alias SwarmCodeCLI.UI.Projector.{Composer, Density, RunRow, Status, Support}
  alias SwarmCodeCLI.UI.Projector.Workspace.Turns

  # Paint's card chrome: a two-cell left gutter and one cell of right padding.
  # The title is cut to the header width that leaves, so it never wraps.
  @card_gutter 2
  @card_pad 1

  def project(state, rect, class) do
    chrome = chrome(state, rect, class)
    height = content_height(state, rect, class, chrome)

    content =
      cond do
        state.destination == :activity ->
          activity_content(state, rect.width, height)

        chrome.run ->
          # Mode summaries live in the measured chrome above. Keep the actual
          # transcript on the shared viewport so Home/End/PageUp/PageDown use
          # the same logical anchors and wrapped-row metrics for every mode.
          content(state, chrome.run, rect.width, height)

        true ->
          welcome_content(state, rect.width, height)
      end

    head =
      chrome.mandatory ++
        chrome.summary ++
        Enum.take(chrome.notices, 2) ++ chrome.deck ++ chrome.separator

    bottom_anchor(head, content, state, rect)
  end

  # A conversation reads from the bottom: the newest turn sits just above the
  # composer, the way every chat surface behaves. Without this the transcript
  # pins to the top and a short conversation leaves the screen looking broken.
  #
  # The chrome does not ride down with it. `NEEDS n`, the composer facts and the
  # run card are a prominence contract: a pending question has to be in the same
  # place on main's first row whether the transcript is empty or a thousand turns
  # long, and a header that drifts with content length is not a header. So the
  # spacer goes BETWEEN the chrome and the transcript, never before the chrome.

  # `Blocks.lines/6` measures at most 200 rows, so a pane taller than that cannot
  # be measured honestly; it keeps the transcript where it is.
  defp bottom_anchor(head, content, _state, rect) when rect.height > 200,
    do: head ++ content

  defp bottom_anchor(head, content, state, rect) do
    {measured, _actions} = Support.finalize(head ++ content, state.revision)

    options = %Options{
      color_mode: state.capabilities.color_mode,
      ascii?: state.capabilities.ascii?
    }

    case Metrics.height(
           measured,
           min(rect.width, 500),
           options,
           rect.height,
           state.capabilities.ambiguous_width
         ) do
      {:ok, painted} when painted < rect.height ->
        spacer = List.duplicate(Support.text(" ", state, rect.width), rect.height - painted)
        head ++ spacer ++ content

      _ ->
        head ++ content
    end
  end

  @doc "Exact Main text viewport rows after required chrome, notices and action decks."
  def content_height(state, rect, class),
    do: content_height(state, rect, class, chrome(state, rect, class))

  defp content_height(state, rect, _class, chrome) do
    blocks =
      chrome.mandatory ++
        chrome.summary ++ Enum.take(chrome.notices, 2) ++ chrome.deck ++ chrome.separator

    {blocks, _measurement_actions} = Support.finalize(blocks, state.revision)

    options = %Options{
      color_mode: state.capabilities.color_mode,
      ascii?: state.capabilities.ascii?
    }

    # Run cards, wrapped action decks and notice prefixes consume painted rows,
    # rather than one row per top-level semantic block.
    {:ok, chrome_height} =
      Metrics.height(
        blocks,
        min(rect.width, 500),
        options,
        min(rect.height, 200),
        state.capabilities.ambiguous_width
      )

    remaining = max(0, rect.height - chrome_height)

    # The transcript takes every row the chrome leaves. The old 45% cap came in
    # with the first demo and left the lower half of a tall terminal blank.
    if chrome.run,
      do: remaining,
      else: min(remaining, max(1, div(rect.height * 65, 100)))
  end

  defp chrome(state, rect, class) do
    run = Support.run(state)

    needs =
      state.read_model.interactions
      |> Map.values()
      |> Enum.count(&(Map.get(&1, :state) == :pending and not superseded?(state, &1)))

    facts = Composer.facts(state, rect.width)

    # Plain words, and only when there is something to say: nothing waits, so
    # nothing is shown; the pending interactions themselves stay in the deck.
    needs_summary =
      if needs > 0,
        do: [tinted("Waiting for you · #{needs}", :warning, state, rect.width)],
        else: []

    mandatory = needs_summary ++ facts

    notices =
      Status.notice(state, rect.width) ++
        Status.mutations(state, rect.width) ++ recovery(state, rect.width, class)

    summary =
      if run,
        do: [card(state, run, rect.width, class) | mode_panel(state, run, rect.width, class)],
        else: []

    actions =
      if class == :compressed_small do
        [
          Support.action(SafeText.chrome(:resize_help), {:local, {:open_layer, :help}}),
          Support.action(SafeText.chrome(:help), {:local, {:open_layer, :help}}),
          Support.action(SafeText.chrome(:detach), {:local, {:quit_requested, :detach}}),
          Support.action(
            SafeText.chrome(:plain_exit),
            {:local, {:presenter_handoff_requested, :plain}}
          )
        ]
      else
        Composer.actions(state, class) ++
          interaction_actions(state, class) ++ seen_actions(state) ++ detail_actions(state)
      end

    deck = if actions == [], do: [], else: [%Block.ActionDeck{actions: actions}]

    # Blank separator row between chrome and transcript (decision 34):
    # produced inside chrome/3 so BOTH project/3 AND content_height/4 see it.
    separator = if run, do: [Support.text(" ", state, rect.width)], else: []

    %{
      run: run,
      mandatory: mandatory,
      notices: notices,
      summary: summary,
      deck: deck,
      separator: separator
    }
  end

  defp welcome_content(state, width, height) when height > 0 do
    mode = Composer.mode_label(state)

    {headline, detail} =
      case mode do
        "Plan" -> {"READY TO PLAN", "Describe the change and I will map the safest steps."}
        "Goal" -> {"GOAL MODE READY", "Set the objective for every run in this conversation."}
        "Ultra" -> {"READY FOR ULTRA", "Big tasks become staged workflows with visible progress."}
        "Workflow" -> {"WORKFLOW AUTHORING READY", "Describe the automation you want to create."}
        "Consensus" -> {"READY FOR CONSENSUS", "Ask for a plan that a second model will judge."}
        _ -> {"READY TO BUILD", "Ask for a change, inspect the project, or choose a mode."}
      end

    workspace = Map.get(state.read_model.snapshots, :workspace)
    model = if workspace, do: Map.get(workspace, :chat_model), else: nil

    model_line =
      if is_binary(model) and model != "",
        do: "Model · " <> model,
        else: "Model · configured in Settings"

    blocks = [
      Support.styled(headline, :heading, state, width),
      Support.text(detail, state, width),
      Support.styled("FIRST STEPS", :info, state, width),
      Support.text("1  Type a request below and press Enter", state, width),
      Support.text("2  Type / to browse slash commands", state, width),
      Support.text(
        "3  Press " <> @palette_key <> " to open workflows, research, memory, and settings",
        state,
        width
      ),
      Support.styled(model_line, :text_muted, state, width),
      %Block.VirtualList{total_count: 0, first_index: 0, items: [], overscan: 0}
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
        [Support.styled("GOAL PROGRESS", :run_goal, state, width), progress(run, state, width)]

      run.kind == :ultra ->
        [Support.styled(pipeline_stages(state), :run_ultra, state, width)]

      run.kind == :workflow ->
        [Support.styled("WORKFLOW RUN  ·  inputs and stages", :run_workflow, state, width)]

      run.kind == :consensus ->
        [Support.styled("CONSENSUS  ·  plan ↔ changes", :run_consensus_judge, state, width)]

      run.kind == :research ->
        [Support.styled("RESEARCH  ·  report and sources", :run_research, state, width)]

      run.kind == :swarm ->
        [Support.styled("SWARM  ·  parallel agent lanes", :run_swarm, state, width)]

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

    heading = [Support.section_heading("PLAN STEPS", state, width)]

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

        actions = approve_action ++ steer_action ++ decline_action
        if actions == [], do: [], else: [%Block.ActionDeck{actions: actions}]

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

    text =
      case Enum.find(items, &(not is_nil(&1.detail_ref))) do
        %{role: :user} = item -> [{"Full prompt", item}]
        %{} = item -> [{"Full reply", item}]
        nil -> []
      end

    reasoning =
      case Enum.find(items, &(not is_nil(&1.reasoning_detail_ref))) do
        %{} = item -> [{"Full reasoning", item}]
        nil -> []
      end

    Enum.map(text ++ reasoning, fn {label, item} ->
      ref = if label == "Full reasoning", do: item.reasoning_detail_ref, else: item.detail_ref

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

  def card(state, run, width, class) do
    {prefix, role} = Theme.run_kind(kind(run.kind))
    enabled = class not in [:compressed_small, :too_small] and run.state != :superseded
    retry? = enabled and run.state == :failed and Support.allowed?(state, run, :retry)
    resume? = enabled and run.state == :interrupted and Support.allowed?(state, run, :resume)

    actions = if enabled, do: run_actions(state, run, retry?, resume?), else: []

    actions =
      if class in [:compressed_small, :too_small],
        do: [],
        else:
          actions ++
            [
              Support.action(
                SafeText.chrome(:inspect),
                {:local, {:open_layer, {:run_inspector, run.id, :overview}}}
              )
            ]

    # The card's header carries the canonical status word; its first row says
    # the same thing in plain words with the facts that matter next.
    body = [tinted(state_words(run, state), elem(Theme.status(run.state), 1), state, width)]

    body =
      body ++
        cond do
          retry? -> [Support.text("RETRY AVAILABLE", state, width)]
          resume? -> [Support.text("RESUME AVAILABLE", state, width)]
          true -> []
        end

    body =
      if run.state in [:running, :streaming],
        do:
          body ++
            [
              %Block.Gauge{
                tone: role,
                value: run.progress || 0,
                maximum: if(is_nil(run.progress), do: 0, else: 100),
                style: :ticks,
                label: nil
              }
            ],
        else: body

    body = body ++ if(actions == [], do: [], else: [%Block.ActionDeck{actions: actions}])
    # Run-kind identity is textual in monochrome as well as color; the boundary is singular.
    title = card_title(run, prefix, state, width)
    %Block.RunCard{id: opaque(run.id), title: title, status: run.state, body: body}
  end

  # The title gets the cells Paint's card header leaves after the kind letter,
  # the boundary and the status word, and is cut on a word boundary with an
  # ellipsis so it never ends mid-word and never wraps into a second row.
  defp card_title(run, prefix, state, width) do
    policy = state.capabilities.ambiguous_width
    {status_text, _} = Theme.status(run.state)
    boundary = if state.capabilities.ascii?, do: " - ", else: " — "
    lead = SafeText.value(prefix) <> " "
    inner = max(1, width - @card_gutter - @card_pad)

    avail =
      inner - Width.cells(lead, policy) - Width.cells(boundary, policy) -
        Width.cells(SafeText.value(status_text), policy)

    Density.safe(lead <> word_cut(run.title, max(avail, 1), state), state, width)
  end

  defp word_cut(title, avail, state) do
    policy = state.capabilities.ambiguous_width
    title = title |> Density.safe(state, 500) |> SafeText.value()

    if Width.cells(title, policy) <= avail do
      title
    else
      ellipsis = if state.capabilities.ascii?, do: "...", else: "…"
      budget = avail - Width.cells(ellipsis, policy)

      {kept, _used} =
        title
        |> String.split(" ", trim: true)
        |> Enum.reduce_while({[], 0}, fn word, {acc, used} ->
          needed = Width.cells(word, policy) + if(acc == [], do: 0, else: 1)

          if used + needed <= budget,
            do: {:cont, {[word | acc], used + needed}},
            else: {:halt, {acc, used}}
        end)

      # A cut that ends on a bare separator ("Swarm ·…") reads worse than one
      # word shorter; under one word there is no boundary to cut on.
      case Enum.drop_while(kept, &(&1 in ["·", "-", "—", ":", "|", "/"])) do
        [] -> title |> Density.safe(state, avail) |> SafeText.value()
        words -> Enum.join(Enum.reverse(words), " ") <> ellipsis
      end
    end
  end

  # "running · 3 agents", "done · 02:14", "stopped by you", "waiting for you".
  defp state_words(run, state) do
    agents =
      case run.agents_total do
        0 -> nil
        1 -> "1 agent"
        n -> "#{n} agents"
      end

    case run.state do
      :stopped -> "stopped by you"
      s when s in [:waiting_question, :waiting_approval] -> "waiting for you"
      s when s in [:running, :streaming] -> words(["running", agents, elapsed(run, state)])
      :done -> words(["done", elapsed(run, state)])
      :failed -> words(["failed", run.error])
      :queued -> "queued"
      :paused -> "paused"
      :retrying -> "retrying"
      :interrupted -> "interrupted"
      :superseded -> "superseded by a newer turn"
    end
  end

  defp elapsed(%{started_at: started, finished_at: finished}, _state)
       when is_integer(started) and is_integer(finished) and finished >= started,
       do: mmss(finished - started)

  # A live run counts from its start on the state clock, which only moves once
  # the reducer has ticked; fixtures at clock zero show no elapsed time.
  defp elapsed(%{started_at: started, finished_at: nil}, %{now: now})
       when is_integer(started) and started > 0 and is_integer(now) and now > started,
       do: mmss(now - started)

  defp elapsed(_, _), do: nil

  defp mmss(ms) do
    total = div(ms, 1000)
    hours = div(total, 3600)
    minutes = rem(div(total, 60), 60)
    seconds = rem(total, 60)

    if hours > 0,
      do: "#{hours}:#{pad2(minutes)}:#{pad2(seconds)}",
      else: "#{pad2(minutes)}:#{pad2(seconds)}"
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  defp words(parts) do
    parts
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" · ")
  end

  # A role's colour on one bold row, without the role's prefix cue: the words
  # are the label, so "! WAITING Waiting for you" would say it twice.
  defp tinted(value, role, state, width) do
    style = RunRow.tinted(role, state)

    %Block.RichText{
      spans: [
        %Span{text: Density.safe(value, state, width), style: %{style | modifiers: [:bold]}}
      ]
    }
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

  defp content(state, run, width, height) do
    ids = Map.get(state.read_model.order, :workspace, [])
    ids = if ids == [], do: state.read_model.transcript |> Map.keys() |> Enum.sort(), else: ids

    items =
      Enum.flat_map(ids, fn id ->
        case Map.get(state.read_model.transcript, id) do
          %{run_id: run_id} = item when run_id == run.id -> [{id, item}]
          _ -> []
        end
      end)

    scroll = Map.get(state.scrolls, :main)
    anchor = scroll && scroll.anchor

    index =
      case anchor do
        {id, _, _} -> Enum.find_index(items, fn {key, _} -> key == id end) || 0
        _ -> 0
      end

    follow? = scroll && scroll.follow?
    candidates = items |> Enum.with_index()
    candidates = if follow?, do: Enum.reverse(candidates), else: Enum.drop(candidates, index)

    # Each item knows the run's item before it: that decides whether a blank
    # row opens a new turn or the item continues a burst of tool calls.
    previous_by_id =
      [nil | Enum.map(items, &elem(&1, 1))]
      |> Enum.zip(Enum.map(items, &elem(&1, 0)))
      |> Map.new(fn {previous, id} -> {id, previous} end)

    {blocks, _left, first} =
      Enum.reduce_while(candidates, {[], height, index}, fn
        _, {blocks, 0, first} ->
          {:halt, {blocks, 0, first}}

        {{id, item}, item_index}, {blocks, left, first} ->
          item = ReadModel.transcript_item(state.read_model, id) || item

          line =
            case anchor do
              {^id, offset, _} -> offset
              _ -> 0
            end

          {block, rows} =
            item
            |> Turns.rows(Map.get(previous_by_id, id), run, state, width)
            |> Turns.window(line, left, follow?, state)

          if block do
            {:cont,
             {[block | blocks], max(0, left - rows), if(follow?, do: item_index, else: first)}}
          else
            {:cont, {blocks, left, first}}
          end
      end)

    blocks = if follow?, do: blocks, else: Enum.reverse(blocks)

    # Detached-from-bottom indicator: when not following and newer items exist below
    visible_count = length(blocks)
    newer = length(items) - first - visible_count

    detached_indicator =
      if not (follow? || false) and newer > 0,
        do: [Support.styled("#{newer} new", :info, state, width)],
        else: []

    [
      %Block.VirtualList{
        total_count: length(items),
        first_index: min(first, length(items)),
        items: blocks ++ detached_indicator,
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

  defp recovery(state, width, class) do
    pages =
      Enum.reduce(state.watches, state.pages, fn {slot, watch}, pages ->
        if watch.status in [:stale, :resyncing, :disconnected] do
          page = Map.get(pages, slot, %SwarmCodeCLI.UI.PageState{})
          Map.put(pages, slot, %{page | status: watch.status})
        else
          pages
        end
      end)

    pages
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {slot, page} ->
      if page.status in [
           :stale,
           :disconnected,
           :resyncing,
           :error,
           :loading_before,
           :loading_after
         ] do
        key =
          case page.status do
            :stale -> :status_stale
            :disconnected -> :status_disconnected
            :resyncing -> :status_resyncing
            :error -> :page_error
            x -> x
          end

        notice = %Block.Notice{
          text:
            Density.safe(
              Atom.to_string(slot) <> " · " <> SafeText.value(SafeText.chrome(key)),
              state,
              width
            ),
          severity: :warning
        }

        actions =
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

        [notice] ++ if(actions == [], do: [], else: [%Block.ActionDeck{actions: actions}])
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
  defp opaque(id), do: :crypto.hash(:sha256, id) |> Base.url_encode64(padding: false)

  # The stage arrow is catalogue chrome, so it must go through Support.glyph/2 to get its
  # one-cell ASCII twin; a literal ❯ would survive into ASCII mode (NOTES_2 #36).
  defp pipeline_stages(state) do
    arrow = SafeText.value(Support.glyph(:pipeline_arrow, state))
    "PLAN " <> arrow <> " BUILD " <> arrow <> " VERIFY"
  end
end
