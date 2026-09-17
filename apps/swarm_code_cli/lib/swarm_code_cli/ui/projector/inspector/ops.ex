defmodule SwarmCodeCLI.UI.Projector.Inspector.Ops do
  @moduledoc """
  Operation rows: what one agent has done, one row per tool call, thought or
  error, oldest first, and the family a tool belongs to.

  A family is a glyph and a colour: commands in the accent, reads in the info
  blue, searches in the goal violet, writes in green, spawns in the swarm teal,
  thinking faint. The web's operation icons are emoji, which carry colour by
  definition; a monochrome glyph has to carry it in its style instead.
  """
  alias SwarmCodeCLI.UI.{SafeText, Theme}
  alias SwarmCodeCLI.UI.Scene.{Block, Span}
  alias SwarmCodeCLI.UI.Projector.{Density, RunRow, Support}
  alias SwarmCodeCLI.UI.Projector.Inspector.{Hive, Words}

  @max_name 12
  @min_arg 6

  @doc "The agent's transcript items that are operations, oldest first."
  def items(state, agent) do
    state.read_model.transcript
    |> Map.values()
    |> Enum.filter(&(&1.agent_id == agent.id and &1.kind in [:tool, :thinking, :error]))
    |> Enum.sort_by(&{&1.at, &1.created_sequence, &1.id})
  end

  @doc "The distinct tool names an agent has used, in first-use order."
  def tools(state, agent) do
    state
    |> items(agent)
    |> Enum.map(&tool_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp tool_name(%{kind: :tool, tool: %{name: name}}) when is_binary(name) and name != "",
    do: name

  defp tool_name(_item), do: nil

  @doc "The glyph token and theme role of an operation family."
  def family(:thinking), do: {:assistant_mark, :text_faint}
  def family(:error), do: {:close_mark, :error}
  def family("run_command"), do: {:command_mark, :accent}
  def family("bash"), do: {:command_mark, :accent}
  def family("shell"), do: {:command_mark, :accent}
  def family("read_file"), do: {:ops_mark, :info}
  def family("list_dir"), do: {:ops_mark, :info}
  def family("glob"), do: {:ops_mark, :info}
  def family("grep"), do: {:search_mark, :run_goal}
  def family("search"), do: {:search_mark, :run_goal}
  def family("web_search"), do: {:search_mark, :run_swarm}
  def family("web_fetch"), do: {:search_mark, :run_swarm}
  def family("write_file"), do: {:write_mark, :success}
  def family("edit_file"), do: {:write_mark, :success}
  def family("edit"), do: {:write_mark, :success}
  def family("write"), do: {:write_mark, :success}
  def family("spawn_agent"), do: {:agent_sub, :run_swarm}
  def family("spawn"), do: {:agent_sub, :run_swarm}
  def family(_other), do: {:dot_small, :text_muted}

  @doc "One row per operation, the newest `height` of them, each `width` cells or fewer."
  def rows(state, agent, width, height) do
    items = state |> items(agent) |> Enum.take(-max(0, height))

    name_width =
      items
      |> Enum.map(&Hive.measure(name(&1), state))
      |> Enum.max(fn -> 0 end)
      |> min(@max_name)

    Enum.map(items, &row(&1, state, width, name_width))
  end

  # `✎ edit_file    +42 −7                  active`
  defp row(item, state, width, name_width) do
    {token, role} = family(key(item))
    status = status(item)
    {word, chip_role} = tail(status)
    duration = if item.kind == :tool, do: duration(item.tool.duration_ms), else: nil

    tail_spans =
      [RunRow.gap(1, state), Support.chip(word, chip_role, state, Hive.measure(word, state) + 2)] ++
        if duration,
          do: [
            RunRow.gap(1, state),
            %Span{
              text: Density.safe(duration, state, Hive.measure(duration, state)),
              style: Theme.style(:text_faint, state.capabilities)
            }
          ],
          else: []

    tail_cells = cells(tail_spans, state)
    arg_width = width - 1 - 1 - name_width - 1 - tail_cells

    {arg_width, tail_spans} =
      if arg_width >= @min_arg,
        do: {arg_width, tail_spans},
        else: {max(0, width - 1 - 1 - name_width - 1), []}

    %Block.RichText{
      spans:
        [
          %Span{
            text: Support.glyph(token, state),
            style: %{RunRow.tinted(role, state) | modifiers: [:bold]}
          },
          RunRow.gap(1, state),
          %Span{
            text: Hive.fit(name(item), name_width, state),
            style: RunRow.tinted(role, state)
          },
          RunRow.gap(1, state),
          %Span{
            text: Hive.fit(argument(item), arg_width, state),
            style:
              if(item.kind == :error,
                do: RunRow.tinted(:error, state),
                else: Theme.style(:text_muted, state.capabilities)
              )
          }
        ] ++ tail_spans
    }
  end

  # `120ms`, `0.4s`, `12s`, then the hive's `mm:ss` from a minute up.
  defp duration(ms) when is_integer(ms) and ms >= 0 and ms < 1_000, do: "#{ms}ms"
  defp duration(ms) when is_integer(ms) and ms < 10_000, do: "#{Float.round(ms / 1000, 1)}s"
  defp duration(ms) when is_integer(ms) and ms < 60_000, do: "#{div(ms, 1000)}s"
  defp duration(ms), do: Words.duration(ms)

  defp key(%{kind: :thinking}), do: :thinking
  defp key(%{kind: :error}), do: :error
  defp key(%{tool: %{name: name}}), do: name
  defp key(_item), do: nil

  defp name(%{kind: :thinking}), do: "thinking"
  defp name(%{kind: :error}), do: "error"
  defp name(%{tool: %{name: name}}) when is_binary(name) and name != "", do: name
  defp name(_item), do: "tool"

  # What the row says the operation did: the tool's detail, else its title,
  # else the item's own words.
  defp argument(%{kind: :thinking, reasoning: reasoning}) when is_binary(reasoning),
    do: one_line(reasoning)

  defp argument(%{kind: :tool, tool: %{detail: detail}}) when is_binary(detail) and detail != "",
    do: one_line(detail)

  defp argument(%{kind: :tool, tool: %{title: title}}) when is_binary(title) and title != "",
    do: one_line(title)

  defp argument(%{text: text}) when is_binary(text), do: one_line(text)
  defp argument(_item), do: ""

  defp one_line(text), do: text |> String.split(~r/\r?\n/) |> List.first("") |> String.trim()

  defp status(%{kind: :tool, tool: %{status: status}}), do: status
  defp status(%{state: state}), do: state

  defp tail(status) do
    cond do
      Words.running?(status) -> {"active", :chip_accent}
      Words.waiting?(status) -> {"waiting", :chip_warn}
      status == :done -> {"done", :chip_ok}
      status == :failed -> {"failed", :chip_err}
      status == :queued -> {"queued", :hover}
      true -> {Words.state(status), :hover}
    end
  end

  defp cells(spans, state),
    do: Enum.reduce(spans, 0, &(Hive.measure(SafeText.value(&1.text), state) + &2))
end
