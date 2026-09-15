defmodule SwarmCodeCLI.UI.Projector.Shell do
  @moduledoc false
  alias SwarmCodeCLI.UI.{SafeText, Theme, Width}
  alias SwarmCodeCLI.UI.Scene.{Block, Region, Span, Style}
  alias SwarmCodeCLI.UI.Projector.{Composer, Density, Inspector, Status, Support, Workspace}
  @order [:title, :navigator, :main, :inspector, :activity, :composer, :status]
  def project(state, layout) do
    Enum.reduce(@order, {[], nil}, fn role, {regions, cursor} ->
      case Map.get(layout.rects, role) do
        nil ->
          {regions, cursor}

        rect ->
          {blocks, new_cursor} = blocks(role, state, rect, layout.class)
          id = Atom.to_string(role)
          focus = if state.focus == id and state.layers == [], do: :active, else: :inactive

          label =
            case role do
              :title -> Composer.mode_label(state)
              :composer -> Composer.label(state)
              :navigator -> SafeText.chrome(:workspace_label)
              _ -> SafeText.chrome(role)
            end
            |> Density.safe(state, rect.width)

          region = %Region{
            id: id,
            role: role,
            rect: rect,
            label: label,
            blocks: blocks,
            focus: focus
          }

          region =
            case {role, blocks} do
              {:navigator, blocks} when is_list(blocks) ->
                window = Enum.find(blocks, &match?(%Block.VirtualList{}, &1))

                if window do
                  scroll = Map.get(state.scrolls, :navigator)

                  %{
                    region
                    | scroll_offset: window.first_index,
                      visible_range:
                        {window.first_index, window.first_index + length(window.items)},
                      follow: if(scroll && scroll.follow?, do: :end, else: :none)
                  }
                else
                  region
                end

              _ ->
                region
            end

          {regions ++ [region], new_cursor || cursor}
      end
    end)
  end

  @doc """
  Number of fixed rows before the VirtualList in the navigator.
  destination_count + 1 blank row + 1 RUNS heading.
  """
  def navigator_fixed_rows(state) do
    length(destinations(state)) + 2
  end

  defp blocks(:title, state, rect, class) do
    policy = state.capabilities.ambiguous_width

    banner =
      (Map.get(state, :banner) || Density.budget(class).banner)
      |> SafeText.chrome()
      |> SafeText.value()

    workspace = Map.get(state.read_model.snapshots, :workspace)
    mode = Composer.mode_label(state)
    model = workspace && Map.get(workspace, :chat_model)

    triple =
      if is_binary(model) and model != "",
        do: banner <> " · " <> mode <> " · " <> model,
        else: banner <> " · " <> mode

    logo_mark = SafeText.value(Support.glyph(:logo_mark, state))
    wordmark = SafeText.value(SafeText.chrome(:swarmcode_wordmark))
    left_text = logo_mark <> " " <> wordmark <> "  " <> triple
    left_cells = Width.cells(left_text, policy)

    # Right-aligned live counts from ShellSnapshot.counts
    shell_snapshot = Map.get(state.read_model.snapshots, :shell)
    counts = shell_snapshot && Map.get(shell_snapshot, :counts)

    right_parts = counts_parts(counts, state)
    right_text = Enum.join(right_parts, " · ")
    right_cells = if right_text == "", do: 0, else: Width.cells(right_text, policy)

    # Accent bold without the RUNNING prefix cue
    accent_style = Theme.style(:accent, state.capabilities)
    wordmark_style = %{accent_style | role: :plain, prefix: nil, cues: [], modifiers: [:bold]}
    counts_style = %{accent_style | role: :plain, prefix: nil, cues: []}

    spans =
      [
        %Span{text: Density.safe(logo_mark, state, rect.width), style: wordmark_style},
        %Span{text: Density.safe(" ", state, rect.width), style: wordmark_style},
        %Span{text: Density.safe(wordmark, state, rect.width), style: wordmark_style},
        %Span{text: Density.safe("  ", state, rect.width), style: %Style{role: :text_primary}},
        %Span{text: Density.safe(triple, state, rect.width), style: %Style{role: :text_primary}}
      ]

    spans =
      if right_text != "" and left_cells + right_cells + 2 <= rect.width do
        pad = String.duplicate(" ", rect.width - left_cells - right_cells)

        spans ++
          [
            %Span{text: Density.safe(pad, state, rect.width), style: %Style{role: :text_primary}},
            %Span{text: Density.safe(right_text, state, rect.width), style: counts_style}
          ]
      else
        spans
      end

    {[%Block.RichText{spans: spans}], nil}
  end

  defp blocks(:main, state, rect, class), do: {Workspace.project(state, rect, class), nil}
  defp blocks(:inspector, state, rect, class), do: {Inspector.project(state, rect, class), nil}

  defp blocks(:composer, state, rect, _), do: Composer.project(state, rect)
  defp blocks(:status, state, rect, class), do: {Status.project(state, class, rect.width), nil}

  defp blocks(:activity, state, rect, _class) do
    needs = state.read_model.interactions |> Map.values() |> Enum.count(&(&1.state == :pending))

    activity_text = "NEEDS #{needs} · Activity"

    block =
      if needs > 0 do
        # Use accent color for the strip when needs > 0, without the RUNNING prefix
        accent_style = Theme.style(:accent, state.capabilities)
        clean_style = %{accent_style | role: :plain, prefix: nil, cues: []}

        %Block.RichText{
          spans: [
            %Span{
              text: Density.safe(activity_text, state, rect.width),
              style: clean_style
            }
          ]
        }
      else
        Support.text(activity_text, state, rect.width)
      end

    {[block], nil}
  end

  defp blocks(:navigator, state, rect, _class) do
    fallback = state.read_model.runs |> Map.keys() |> Enum.sort()
    ids = Map.get(state.read_model.order, :shell, fallback)

    items =
      Enum.flat_map(ids, fn id ->
        case Map.fetch(state.read_model.runs, id) do
          {:ok, run} -> [{id, run}]
          :error -> []
        end
      end)

    fixed = navigator_fixed_rows(state)
    capacity = max(0, rect.height - 1 - fixed)
    scroll = Map.get(state.scrolls, :navigator)

    anchor =
      case scroll do
        %{anchor: {id, _, _}} -> Enum.find_index(items, fn {key, _} -> key == id end) || 0
        _ -> 0
      end

    selected = Map.get(state.selection, "navigator")
    selected_index = Enum.find_index(items, fn {id, _} -> id == selected end)
    first = if scroll && scroll.follow?, do: max(0, length(items) - capacity), else: anchor

    first =
      cond do
        is_integer(selected_index) and selected_index < first ->
          selected_index

        is_integer(selected_index) and selected_index >= first + capacity ->
          selected_index - capacity + 1

        true ->
          first
      end
      |> min(max(0, length(items) - capacity))
      |> max(0)

    display_items =
      if items == [],
        do: [:empty, :hint, :features],
        else: items

    rows =
      display_items
      |> Enum.drop(first)
      |> Enum.take(capacity)
      |> Enum.map(fn
        :empty ->
          Support.text("No runs yet", state, rect.width)

        :hint ->
          Support.text("Send a prompt to begin", state, rect.width)

        :features ->
          Support.text("Ctrl-K  Features", state, rect.width)

        {id, run} ->
          kind_glyph = Support.glyph(:glyph_selected, state)

          title =
            SafeText.concat([
              Density.safe(" ", state, 1),
              kind_glyph,
              Density.safe(" ", state, 1),
              Density.safe(run.title, state, rect.width)
            ])

          title =
            if id == selected,
              do:
                Density.safe(
                  SafeText.concat([SafeText.chrome(:selection_marker), title]),
                  state,
                  rect.width
                ),
              else: Density.safe(title, state, rect.width)

          # Decision D4: a run row is coloured by its state. The prefix cue is
          # cleared so the row does not gain a textual status prefix it never had.
          {_word, role} = Theme.status(run.state)
          status_style = Theme.style(role, state.capabilities)
          row_style = %{status_style | role: :plain, prefix: nil, cues: []}

          Support.action(title, {:local, {:navigate, {:run, id}}}, row_style)
      end)

    page = Map.get(state.pages, :shell)

    # Build destination entries
    dest_blocks = destination_blocks(state, rect)

    # Blank separator row
    blank = Support.text(" ", state, rect.width)

    # RUNS section heading (with leading space for indentation)
    runs_label = SafeText.concat([Density.safe(" ", state, 1), SafeText.chrome(:runs_label)])
    runs_heading = Support.section_heading(runs_label, state, rect.width)

    nav_blocks =
      dest_blocks ++
        [blank, runs_heading] ++
        [
          %Block.VirtualList{
            total_count: length(display_items),
            first_index: first,
            items: rows,
            before_cursor: page && page.before_cursor,
            after_cursor: page && page.after_cursor,
            overscan: 0
          }
        ]

    {nav_blocks, nil}
  end

  # Destination entries for the navigator
  defp destinations(state) do
    base = [
      {:conversation, :glyph_selected, :nav_conversation,
       {:navigate, current_conversation(state)}},
      {:activity, :glyph_inactive, :nav_activity, {:navigate, :activity}}
    ]

    library =
      if state.banner in [:live_banner, :persisted_banner] do
        [
          {:workflows, :glyph_workflows, :nav_workflows, {:open_layer, {:library, :workflows}}},
          {:research, :glyph_research, :nav_research, {:open_layer, {:library, :research}}},
          {:memory, :glyph_memory, :nav_memory, {:open_layer, {:library, :memory}}}
        ]
      else
        []
      end

    base ++ library
  end

  defp current_conversation(state) do
    case state.destination do
      {:conversation, id} when is_binary(id) ->
        {:conversation, id}

      {:run, id} ->
        run = Map.get(state.read_model.runs, id)
        conv_id = run && run.conversation_id
        if is_binary(conv_id), do: {:conversation, conv_id}, else: :activity

      _ ->
        :activity
    end
  end

  defp destination_blocks(state, rect) do
    dests = destinations(state)

    Enum.map(dests, fn {_key, glyph_token, label_token, target} ->
      glyph = Support.glyph(glyph_token, state)
      label = SafeText.chrome(label_token)

      entry_text =
        SafeText.concat([
          Density.safe(" ", state, 1),
          glyph,
          Density.safe(" ", state, 1),
          label
        ])

      Support.action(Density.safe(entry_text, state, rect.width), {:local, target})
    end)
  end

  defp counts_parts(nil, _state), do: []

  # Glyphs go through Support.glyph/2 so they degrade to their one-cell ASCII twins in ASCII mode
  # (a bare SafeText.chrome/1 here would leave Unicode on screen; see ORCHESTRATOR_NOTES_2 #36).
  defp counts_parts(counts, state) do
    for {field, token, word} <- [
          {:running, :glyph_selected, "running"},
          {:waiting, :glyph_inactive, "waiting"},
          {:failed, :glyph_failed, "failed"}
        ],
        count = Map.get(counts, field, 0),
        count > 0 do
      SafeText.value(Support.glyph(token, state)) <>
        " " <> Integer.to_string(count) <> " " <> word
    end
  end
end
