defmodule SwarmCodeCLI.UI.Projector.Inspector do
  @moduledoc """
  The docked inspector: four tabs over the run you are looking at.

    * thread — the verdict card of a judged run, then the hive;
    * agents — the hive alone: one lane per agent, what it is doing, its gauge
      and its tokens;
    * timeline — the run's transcript as a list of events;
    * changes — the ledger of files the run's agents touched.

  `[` and `]` rotate the tabs; the strip on the first row names them and each
  name is clickable. Every tab budgets its rows to the region's width and stops
  at its height, since the region does not scroll.
  """
  alias SwarmCodeCLI.UI.Theme
  alias SwarmCodeCLI.UI.Keymap.Bindings
  alias SwarmCodeCLI.UI.Scene.Block
  alias SwarmCodeCLI.UI.Projector.{Density, RunRow, Support}
  alias SwarmCodeCLI.UI.Projector.Inspector.{Changes, Hive, Timeline, Verdict}

  def project(state, rect, class) do
    run = Support.run(state)
    tab = tab(state)
    width = rect.width
    height = max(0, rect.height - 1)
    # A compressed class keeps mutation targets off the screen, as before.
    opts = [stop?: class not in [:compressed_small, :too_small]]

    body =
      case tab do
        :agents -> Hive.panel(state, run, width, height, opts)
        :timeline -> Timeline.tab(state, run, width, height)
        :changes -> Changes.tab(state, run, width, height)
        :thread -> thread(state, run, width, height, opts)
      end

    [strip(tab, state, width) | Enum.take(body, height)]
  end

  @doc """
  The tab the inspector shows. `:overview` is the run_inspector layer's
  spelling of `:thread`; anything else unknown falls back to the thread.
  """
  def tab(state) do
    case Map.get(state.tabs, :inspector, :thread) do
      :overview -> :thread
      tab when tab in [:thread, :agents, :timeline, :changes] -> tab
      _other -> :thread
    end
  end

  # The verdict card sits above the hive on a judged run; the card is short and
  # the lanes take what is left.
  defp thread(state, run, width, height, opts) do
    # The hive leads: who is working and on what is the first thing to know;
    # the judge's card, when there is one, reads below it.
    card = Verdict.card(state, run, width)
    Hive.panel(state, run, width, max(0, height - length(card)), opts) ++ card
  end

  # One clickable name per tab, the current one lit.
  defp strip(current, state, width) do
    %Block.ActionDeck{
      actions:
        Enum.map(Bindings.inspector_tabs(), fn tab ->
          style =
            if tab == current,
              do: %{RunRow.tinted(:accent, state) | modifiers: [:bold]},
              else: Theme.style(:text_faint, state.capabilities)

          Support.action(
            Density.safe(Atom.to_string(tab), state, width),
            {:local, {:set_tab, tab}},
            style
          )
        end)
    }
  end
end
