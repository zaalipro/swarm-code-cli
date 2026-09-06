defmodule SwarmCodeCLI.UI.Projector.Workspace do
  @moduledoc false
  alias SwarmCodeCLI.UI.{ReadModel, SafeText, Theme}
  alias SwarmCodeCLI.UI.Scene.Block
  alias SwarmCodeCLI.UI.Paint.{Metrics, Options}
  alias SwarmCodeCLI.UI.Projector.{Composer, Density, Status, Support}

  def project(state, rect, class) do
    chrome = chrome(state, rect, class)
    height = content_height(state, rect, class, chrome)

    content =
      cond do
        state.destination == :activity -> activity_content(state, rect.width, height)
        chrome.run -> content(state, chrome.run, rect.width, height)
        true -> []
      end

    chrome.mandatory ++ chrome.summary ++ Enum.take(chrome.notices, 2) ++ chrome.deck ++ content
  end

  @doc "Exact Main text viewport rows after required chrome, notices and action decks."
  def content_height(state, rect, class),
    do: content_height(state, rect, class, chrome(state, rect, class))

  defp content_height(state, rect, _class, chrome) do
    blocks = chrome.mandatory ++ chrome.summary ++ Enum.take(chrome.notices, 2) ++ chrome.deck
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

    cond do
      state.destination == :activity -> remaining
      chrome.run -> min(remaining, div(rect.height * 45, 100))
      true -> 0
    end
  end

  defp chrome(state, rect, class) do
    run = Support.run(state)

    needs =
      state.read_model.interactions
      |> Map.values()
      |> Enum.count(&(Map.get(&1, :state) == :pending and not superseded?(state, &1)))

    facts = Composer.facts(state, rect.width)

    needs_summary =
      if needs > 0 or state.preferences.activity_height == 0,
        do: [Support.text("NEEDS #{needs}", state, rect.width)],
        else: []

    mandatory = needs_summary ++ facts

    notices =
      Status.notice(state, rect.width) ++
        Status.mutations(state, rect.width) ++ recovery(state, rect.width, class)

    summary =
      if run, do: [card(state, run, rect.width, class)], else: [Support.chrome(:status_empty)]

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

    %{run: run, mandatory: mandatory, notices: notices, summary: summary, deck: deck}
  end

  defp activity_content(state, width, height) do
    items = state.read_model.activity |> Enum.sort_by(&elem(&1, 0))

    blocks =
      items
      |> Enum.take(height)
      |> Enum.map(fn {_, item} ->
        {word, role} = Theme.status(item.state)
        Support.styled(SafeText.value(word) <> " · " <> item.title, role, state, width)
      end)

    [%Block.VirtualList{total_count: length(items), first_index: 0, items: blocks, overscan: 0}]
  end

  defp detail_actions(state) do
    run = Support.run(state)

    state.read_model.transcript
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.filter(fn {_, item} ->
      run && item.run_id == run.id
    end)
    |> Enum.flat_map(fn {_, item} ->
      for {label, ref} <- [
            {"Full text", item.detail_ref},
            {"Full reasoning", item.reasoning_detail_ref}
          ],
          not is_nil(ref),
          do: {item.run_id, label, ref}
    end)
    |> Enum.take(2)
    |> Enum.map(fn {run_id, label, ref} ->
      Support.action(
        Density.safe(label, state, 40),
        {:local, {:open_detail, run_id, ref.id}}
      )
    end)
  end

  defp seen_actions(state) do
    workspace = Map.get(state.read_model.snapshots, :workspace)

    conversation =
      if workspace && is_binary(workspace.conversation_id) &&
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
    {prefix, _role} = Theme.run_kind(kind(run.kind))
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

    # The RunCard boundary already carries the canonical status. Only surface
    # additional information here when it changes the user's next action.
    body =
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
              %Block.Progress{
                label: Density.safe(SafeText.value(prefix) <> " LIVE", state, width),
                value: run.progress || 0,
                maximum: if(is_nil(run.progress), do: 0, else: 100)
              }
            ],
        else: body

    body = body ++ if(actions == [], do: [], else: [%Block.ActionDeck{actions: actions}])
    # Run-kind identity is textual in monochrome as well as color; the boundary is singular.
    title = Density.safe(SafeText.value(prefix) <> " " <> run.title, state, width)
    %Block.RunCard{id: opaque(run.id), title: title, status: run.state, body: body}
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
            SwarmCodeCLI.UI.Transcript.window(
              item,
              run.kind,
              width,
              state.capabilities,
              line,
              left,
              follow?
            )

          if block do
            {:cont,
             {[block | blocks], max(0, left - rows), if(follow?, do: item_index, else: first)}}
          else
            {:cont, {blocks, left, first}}
          end
      end)

    blocks = if follow?, do: blocks, else: Enum.reverse(blocks)

    [
      %Block.VirtualList{
        total_count: length(items),
        first_index: min(first, length(items)),
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
end
