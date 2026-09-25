defmodule SwarmCodeCLI.UI.Projector.HiveStrip do
  @moduledoc """
  The swarm on one row (ux M8). Below the width that docks the inspector, a
  live run with more than one agent draws its hive on the composer's edge
  instead of the plain hairline:

      ── hive ⬢ lead  ⬢ worker-a-accounts ✓  ⬢ worker-b-live !  ⬡ merge ──── Ctrl-B pane

  Every agent is its cell in the hive colours (lit while it runs, amber while
  it waits on you, red when it failed, grey once done), its name, and a mark
  for done, waiting or failed. Names are whole while they fit; only when the
  row is full are they shortened, then the rest counted as `+N`. The key that
  opens the pane is read off the binding table.
  """
  alias SwarmCodeCLI.UI.{Layout, SafeText, Theme, Width}
  alias SwarmCodeCLI.UI.Keymap.Bindings
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  alias SwarmCodeCLI.UI.Projector.{Density, KeyLabel, Markdown, RunRow, Support}
  alias SwarmCodeCLI.UI.Projector.Inspector.{Hive, Words}

  @short_name 12

  @doc "The strip for the current run at `width` cells, or `nil` when there is none to draw."
  @spec block(map(), pos_integer()) :: Block.RichText.t() | nil
  def block(state, width) do
    run = Support.run(state)
    agents = if run, do: Hive.agents(state, run.id), else: []

    cond do
      run == nil or length(agents) < 2 or not Words.live?(run.state) -> nil
      docked?(state) -> nil
      true -> draw(run, agents, state, width)
    end
  end

  defp docked?(state) do
    # pass72: the side panel or its strip (R17) already shows the swarm.
    layout = Layout.for_state(state)
    Map.has_key?(layout.rects, :inspector) or Map.has_key?(layout.rects, :tabline)
  end

  defp draw(run, agents, state, width) do
    {_letter, live_role} = run.kind |> RunRow.theme_kind() |> Theme.run_kind()
    policy = state.capabilities.ambiguous_width
    rule = Markdown.hairline(%{ascii?: state.capabilities.ascii?, policy: policy})
    ghost = RunRow.tinted(:text_ghost, state)
    faint = RunRow.tinted(:text_faint, state)

    head = [{rule <> rule <> " ", ghost}, {"hive", faint}, {" ", ghost}]

    tail =
      case Bindings.keys_for(:toggle_inspector, SwarmCodeCLI.UI.Keymap.overrides(state)) do
        [key | _] ->
          [
            {" ", ghost},
            {KeyLabel.label(key, state.capabilities.ascii?),
             %{RunRow.tinted(:key, state) | modifiers: [:bold]}},
            {" pane ", faint}
          ]

        [] ->
          []
      end

    room = width - cells(head, policy) - cells(tail, policy) - 2

    lanes =
      [nil, @short_name]
      |> Enum.map(fn limit -> Enum.map(agents, &lane(&1, live_role, limit, state)) end)
      |> Enum.find(fn lanes -> cells(List.flatten(lanes), policy) <= room end)

    {shown, more} =
      case lanes do
        nil -> fit(Enum.map(agents, &lane(&1, live_role, @short_name, state)), room, policy)
        lanes -> {lanes, 0}
      end

    more = if more > 0, do: [{"+#{more} ", faint}], else: []
    body = List.flatten(shown) ++ more
    fill = max(0, room - cells(body, policy))
    filler = [{String.duplicate(rule, div(fill, max(1, cells([{rule, nil}], policy)))), ghost}]

    pieces = head ++ body ++ filler ++ tail

    %Block.RichText{
      spans:
        Enum.map(pieces, fn {text, style} ->
          %Span{text: Density.safe(text, state, width), style: style}
        end)
    }
  end

  defp lane(agent, live_role, limit, state) do
    policy = state.capabilities.ambiguous_width
    name = Hive.name(agent)
    name = if limit, do: Width.elide(name, limit, :end, policy), else: name
    name_role = if Words.finished?(agent.state), do: :text_muted, else: :text_primary

    [
      {SafeText.value(Support.glyph(Hive.glyph_token(agent), state)),
       RunRow.tinted(Hive.cell_role(agent, live_role), state)},
      {" " <> name, RunRow.tinted(name_role, state)}
    ] ++ mark(agent, state) ++ [{"  ", RunRow.tinted(:text_ghost, state)}]
  end

  defp mark(agent, state) do
    cond do
      Words.waiting?(agent.state) ->
        [
          {" " <> SafeText.value(Support.glyph(:waiting, state)),
           %{RunRow.tinted(:warning, state) | modifiers: [:bold]}}
        ]

      agent.state == :failed ->
        [{" " <> SafeText.value(Support.glyph(:fail, state)), RunRow.tinted(:error, state)}]

      agent.state == :done ->
        [{" " <> SafeText.value(Support.glyph(:check, state)), RunRow.tinted(:success, state)}]

      true ->
        []
    end
  end

  # As many whole lanes as fit with room for "+N ".
  defp fit(lanes, room, policy) do
    {shown, _} =
      Enum.reduce_while(lanes, {[], 0}, fn lane, {acc, used} ->
        c = cells(lane, policy)

        if used + c <= room - 5,
          do: {:cont, {[lane | acc], used + c}},
          else: {:halt, {acc, used}}
      end)

    {Enum.reverse(shown), length(lanes) - length(shown)}
  end

  defp cells(pieces, policy),
    do: Enum.reduce(pieces, 0, fn {text, _}, sum -> sum + Width.cells(text, policy) end)
end
