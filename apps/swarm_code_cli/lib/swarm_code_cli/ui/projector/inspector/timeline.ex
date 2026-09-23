defmodule SwarmCodeCLI.UI.Projector.Inspector.Timeline do
  @moduledoc """
  The timeline tab: the run's transcript as a list of events, oldest first and
  the newest at the bottom — the time, who, what kind of thing it was, and the
  first forty cells of what it said.
  """
  alias SwarmCodeCLI.UI.{ReadModel, Theme}
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  alias SwarmCodeCLI.UI.Projector.{Density, RunRow, Support}
  alias SwarmCodeCLI.UI.Projector.Inspector.{Hive, Words}

  @time_width 5
  @max_name 10
  @text_cells 40
  @gap 1

  @doc "The tab's rows, budgeted to `width` and capped at `height`; newest last."
  def tab(state, run, width, height) do
    events = events(state, run)

    # A zero is never shown: an empty timeline is headed "Timeline" alone.
    title =
      case events do
        [] -> "Timeline"
        events -> "Timeline · " <> Words.count(length(events), "event", "events")
      end

    header = Support.section_heading(title, state, width)

    body =
      case events do
        [] -> [Support.text("Nothing has happened yet", state, width)]
        events -> rows(events, state, run, width, max(0, height - 1))
      end

    Enum.take([header | body], max(0, height))
  end

  @doc "The run's transcript items in time order."
  def events(_state, nil), do: []

  def events(state, run) do
    state.read_model.transcript
    |> Map.values()
    |> Enum.filter(&(&1.run_id == run.id))
    |> Enum.sort_by(&{&1.at, &1.created_sequence, &1.id})
  end

  defp rows(events, state, run, width, height) do
    agents = Hive.agents(state, run.id)

    names =
      agents |> Enum.with_index() |> Map.new(fn {agent, index} -> {agent.id, {agent, index}} end)

    shown = Enum.take(events, -max(0, height))

    name_width =
      shown
      |> Enum.map(&Hive.measure(who(&1, names), state))
      |> Enum.max(fn -> 3 end)
      |> min(@max_name)

    kind_width = shown |> Enum.map(&Hive.measure(kind(&1), state)) |> Enum.max(fn -> 4 end)

    text_width = width - (@time_width + @gap) - (name_width + @gap) - (kind_width + @gap)
    text_width = text_width |> min(@text_cells) |> max(0)

    Enum.map(shown, &row(&1, state, names, name_width, kind_width, text_width))
  end

  defp row(item, state, names, name_width, kind_width, text_width) do
    {who, role} =
      case Map.get(names, item.agent_id) do
        {agent, index} -> {Hive.name(agent), Hive.lane_role(agent, index)}
        nil -> {who(item, names), if(item.role == :user, do: :text_primary, else: :accent)}
      end

    kind_role =
      case item.kind do
        :error -> :error
        :thinking -> :text_faint
        _ -> :text_muted
      end

    %Block.RichText{
      spans: [
        %Span{
          text:
            Density.safe(
              RunRow.pad_leading(Words.clock(item.at) || "", @time_width, state),
              state,
              @time_width
            ),
          style: Theme.style(:text_faint, state.capabilities)
        },
        RunRow.gap(@gap, state),
        %Span{
          text: Hive.fit(who, name_width, state),
          style: %{RunRow.tinted(role, state) | modifiers: [:bold]}
        },
        RunRow.gap(@gap, state),
        %Span{
          text: Hive.fit(kind(item), kind_width, state),
          style: RunRow.tinted(kind_role, state)
        },
        RunRow.gap(@gap, state),
        %Span{
          text: Density.safe(text(state, item), state, text_width),
          style: Theme.style(:text_primary, state.capabilities)
        }
      ]
    }
  end

  defp who(item, names) do
    case Map.get(names, item.agent_id) do
      {agent, _index} ->
        Hive.name(agent)

      nil ->
        case item.role do
          :user -> "you"
          :assistant -> "assistant"
          :system -> "system"
          :tool -> "tool"
        end
    end
  end

  defp kind(%{kind: :text}), do: "text"
  defp kind(%{kind: :thinking}), do: "thought"
  defp kind(%{kind: :tool}), do: "tool"
  defp kind(%{kind: :error}), do: "error"
  defp kind(%{kind: :system}), do: "system"
  defp kind(_item), do: ""

  # A tool call's title is the event; a thought lives in its reasoning.
  defp text(state, item) do
    materialized = ReadModel.transcript_item(state.read_model, item.id) || item

    cond do
      match?(%{tool: %{title: title}} when is_binary(title) and title != "", item) ->
        item.tool.title

      item.kind == :thinking and materialized.text == "" ->
        materialized.reasoning

      true ->
        materialized.text
    end
  end
end
