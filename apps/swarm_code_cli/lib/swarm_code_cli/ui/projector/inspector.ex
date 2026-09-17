defmodule SwarmCodeCLI.UI.Projector.Inspector do
  @moduledoc """
  The docked inspector: three tabs over the run you are looking at.

    * agents — the lead card, what waits on you, the verdict of a judged run,
      the sub-agent cards and the operations of the selected agent;
    * timeline — the run's transcript as a list of events;
    * changes — the ledger of files the run's agents touched.

  `[` and `]` rotate the tabs; the strip on the first row names them and each
  name is clickable. When the run waits on you the strip carries the count in
  an amber pill after `agents`. Every tab budgets its rows to the region's
  width and stops at its height, since the region does not scroll.
  """
  alias SwarmCodeCLI.UI.Theme
  alias SwarmCodeCLI.UI.Keymap.Bindings
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  alias SwarmCodeCLI.UI.Projector.{Density, RunRow, Support}
  alias SwarmCodeCLI.UI.Projector.Inspector.{Agents, Changes, Hive, Timeline}

  def project(state, rect, class) do
    run = Support.run(state)
    tab = tab(state)
    width = rect.width
    height = max(0, rect.height - 1)
    # A compressed class keeps mutation targets off the screen, as before.
    opts = [stop?: class not in [:compressed_small, :too_small]]

    body =
      case tab do
        :agents -> agents(state, run, width, height, opts)
        :timeline -> Timeline.tab(state, run, width, height)
        :changes -> Changes.tab(state, run, width, height)
      end

    [strip(tab, state, run, width) | Enum.take(body, height)]
  end

  @doc """
  The tab the inspector shows. `:overview` (the run_inspector layer's older
  spelling) and `:thread` (the retired first tab) both mean the agents; so does
  anything unknown.
  """
  def tab(state) do
    case Map.get(state.tabs, :inspector, :agents) do
      tab when tab in [:agents, :timeline, :changes] -> tab
      _other -> :agents
    end
  end

  defp agents(state, run, width, height, opts), do: Agents.tab(state, run, width, height, opts)

  # One clickable name per tab, the current one lit on the hover surface, and
  # the count of what waits on you as an amber pill after `agents`. The deck
  # joins its items with two spaces, so the names carry no padding of their own.
  defp strip(current, state, run, width) do
    caps = state.capabilities
    pending = Hive.pending(state, run)

    tabs =
      Enum.flat_map(Bindings.inspector_tabs(), fn tab ->
        style =
          if tab == current,
            do: %{
              RunRow.tinted(:accent, state)
              | modifiers: [:bold],
                background: Theme.style(:hover, caps).background
            },
            else: Theme.style(:text_faint, caps)

        label = Atom.to_string(tab)

        action =
          Support.action(Density.safe(label, state, width), {:local, {:set_tab, tab}}, style)

        if tab == :agents and pending > 0,
          do: [action, pill(pending, state, width)],
          else: [action]
      end)

    %Block.ActionDeck{actions: tabs}
  end

  defp pill(count, state, width) do
    text = " " <> Integer.to_string(count) <> " "

    %Span{
      text: Density.safe(text, state, min(width, 6)),
      style: %{RunRow.tinted(:on_warn, state) | modifiers: [:bold]}
    }
  end
end
