defmodule SwarmCodeCLI.UI.Reducer.Overlay do
  @moduledoc """
  The agent overlay's state (pass 72, P8 and K5): one agent of one run, full
  screen, until Esc.

  `state.overlay` is nil or

      %{run_id, node_id, draft_key, focus: :band | :activity | :composer,
        raw_ops?: boolean, page: 0..2, cursor: non_neg_integer,
        expanded: MapSet, restore: %{scroll, draft, focus}}

  Opening remembers the chat's scroll, the composer draft in view and the
  focus; closing puts all three back exactly, whatever the overlay did in
  between (a steer, for one, makes the chat follow its tail). The overlay's
  composer is its own draft, `{conversation, {:agent, node_id}}`, so what is
  typed there never touches the chat's draft and comes back when the same
  agent is opened again.

  Under 120 columns the three columns are pages: the focus ring walks the
  band, each page, then the composer.
  """

  alias SwarmCodeCLI.UI.Keymap
  alias SwarmCodeCLI.UI.Reducer.Hint

  @narrow_columns 120
  @pages 3

  @doc "True when the terminal is too narrow for the three columns."
  def narrow?(state), do: state.size != nil and state.size.columns < @narrow_columns

  @doc "The number of pages the narrow overlay has."
  def pages, do: @pages

  @doc "The agent the overlay shows, or nil (also when it has gone from the read model)."
  def agent(%{overlay: %{node_id: node}} = state), do: Map.get(state.read_model.agents, node)
  def agent(_state), do: nil

  @doc "The oldest request of the overlay's agent waiting on the user, or nil."
  def request(%{overlay: %{run_id: run, node_id: node}} = state),
    do: state |> Hint.pending(run, node) |> List.first()

  def request(_state), do: nil

  @doc "Opens the overlay on `node_id` of `run_id`; `{:error, notice}` when there is no such agent."
  def open(state, run_id, node_id) do
    case {Map.get(state.read_model.runs, run_id), Map.get(state.read_model.agents, node_id)} do
      {%{conversation_id: conversation}, %{run_id: ^run_id}} ->
        restore =
          case state.overlay do
            %{restore: restore} -> restore
            nil -> restore_point(state)
          end

        key = {conversation, {:agent, node_id}}

        overlay = %{
          run_id: run_id,
          node_id: node_id,
          draft_key: key,
          focus: :activity,
          raw_ops?: false,
          page: 0,
          cursor: 0,
          expanded: MapSet.new(),
          restore: restore
        }

        state = %{state | overlay: overlay, hint: nil}
        focus = if request(state), do: :band, else: :activity
        {:ok, %{state | overlay: %{overlay | focus: focus}}}

      _ ->
        {:error, "That agent is not in this conversation any more."}
    end
  end

  defp restore_point(state) do
    %{
      scroll: Map.get(state.scrolls, :main),
      focus: state.focus,
      draft: Map.get(state.selection, "composer_draft", :none)
    }
  end

  @doc "Closes the overlay, putting the chat's scroll, draft and focus back as they were."
  def close(%{overlay: %{restore: restore}} = state) do
    scrolls =
      case restore.scroll do
        nil ->
          state.scrolls

        scroll ->
          current = Map.get(state.scrolls, :main, scroll)
          # What arrived while the overlay was up stays counted as unseen.
          Map.put(state.scrolls, :main, %{scroll | unseen: unseen(scroll, current)})
      end

    selection =
      case restore.draft do
        :none -> Map.delete(state.selection, "composer_draft")
        key -> Map.put(state.selection, "composer_draft", key)
      end

    %{state | overlay: nil, scrolls: scrolls, selection: selection, focus: restore.focus}
  end

  def close(state), do: state

  defp unseen(%{follow?: true} = restored, _current), do: restored.unseen
  defp unseen(_restored, current), do: current.unseen

  @doc "The overlay's focus ring as `{focus, page}` stops."
  def ring(state) do
    band = if request(state), do: [{:band, 0}], else: []

    middle =
      if narrow?(state),
        do: for(page <- 0..(@pages - 1), do: {:activity, page}),
        else: [{:activity, state.overlay.page}]

    band ++ middle ++ [{:composer, state.overlay.page}]
  end

  @doc "Moves the focus one stop along the ring, wrapping."
  def cycle(%{overlay: overlay} = state, direction) do
    ring = ring(state)
    current = {overlay.focus, if(overlay.focus == :activity, do: overlay.page, else: nil)}

    index =
      Enum.find_index(ring, fn {focus, page} ->
        focus == elem(current, 0) and (elem(current, 1) == nil or page == elem(current, 1))
      end) || 0

    step = if direction == :next, do: 1, else: -1
    {focus, page} = Enum.at(ring, Integer.mod(index + step, length(ring)))
    page = if focus == :activity, do: page, else: overlay.page
    %{state | overlay: %{overlay | focus: focus, page: page}}
  end

  @doc "The agents `[` and `]` walk: the overlay run's agents in panel order."
  def neighbours(%{overlay: %{run_id: run}} = state), do: Hint.agents(state, run)

  @doc "The agent `step` places away from the overlay's, wrapping; nil when it is alone."
  def step(%{overlay: %{node_id: node}} = state, direction) do
    agents = neighbours(state)
    index = Enum.find_index(agents, &(&1.id == node))

    case {agents, index} do
      {[], _} ->
        nil

      {_, nil} ->
        List.first(agents)

      {[_single], _} ->
        nil

      {_, index} ->
        Enum.at(
          agents,
          Integer.mod(index + if(direction == :next, do: 1, else: -1), length(agents))
        )
    end
  end

  @doc "The next agent in panel order (after this one, wrapping) that needs the user, or nil."
  def next_needing(%{overlay: %{run_id: run, node_id: node}} = state) do
    agents =
      state
      |> Hint.entries()
      |> Enum.flat_map(fn
        {:agent, r, n, true} -> [{r, n}]
        _ -> []
      end)

    case Enum.find_index(agents, &(&1 == {run, node})) do
      nil ->
        List.first(agents)

      index ->
        agents
        |> Enum.split(index + 1)
        |> then(fn {a, b} -> b ++ a end)
        |> Enum.find(&(&1 != {run, node}))
    end
  end

  @doc "The approval intent `code` answers the overlay's request with, or nil."
  def decision(state, code) do
    with %{kind: :approval, state: :pending} = item <- request(state),
         wanted when not is_nil(wanted) <- wanted(code),
         decision when not is_nil(decision) <- pick(Keymap.decisions(item), wanted) do
      {:resolve_approval, item.run_id, item.node_id, item.id, item.expected_revision, decision}
    else
      _ -> nil
    end
  end

  defp wanted(code) when code in ["y", "a"], do: :approve
  defp wanted("Y"), do: :approve_run
  defp wanted("A"), do: :always
  defp wanted("d"), do: :deny
  defp wanted("D"), do: :deny_stop
  defp wanted(_code), do: nil

  defp pick(offered, :always), do: Enum.find([:always_prefix, :always_allow], &(&1 in offered))
  defp pick(offered, wanted), do: if(wanted in offered, do: wanted)

  @doc "The steer intent the overlay's composer sends, or nil when there is nothing to send."
  def steer(%{overlay: %{run_id: run, node_id: node}} = state) do
    text = Keymap.draft_text(state)
    if String.trim(text) == "", do: nil, else: {:steer, run, node, text, []}
  end

  def steer(_state), do: nil

  @doc "The draft key the overlay types into."
  def draft_key(%{overlay: %{draft_key: key}}), do: key
  def draft_key(_state), do: nil
end
