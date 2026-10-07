defmodule SwarmCodeCLI.UI.Projector.Panel.PlanSection do
  @moduledoc """
  cli020 E29 (competitors-14): the selected run's live plan (C23
  `RunSummary.plan`, the lead's newest `update_plan`, F11), drawn above the
  agents:

      Plan 3/7
        ✓ Read the router
        ▸ Run mix test
        · Fix the failures
        … 2 more

  `✓` done, `▸` in progress, `·` pending (ASCII `+ > .`); at most 7 steps,
  then `… N more`. The strip shows the counter alone. The plan is C23's
  `RunSummary.plan` (`Map.get`, so fixtures without the field draw none).
  """
  alias SwarmCodeCLI.UI.Projector.Panel
  alias SwarmCodeCLI.UI.Projector.Panel.Draw

  @shown 7

  @doc "The run's plan steps as `{text, :done | :in_progress | :pending}`, `[]` without one."
  @spec steps(map() | nil) :: [{String.t(), :done | :in_progress | :pending}]
  def steps(nil), do: []

  def steps(run) do
    case Map.get(run, :plan) do
      [_ | _] = plan -> plan |> Enum.map(&step/1) |> Enum.reject(&is_nil/1)
      _ -> []
    end
  end

  defp step(%{} = item) do
    text = Map.get(item, :text) || Map.get(item, "text")
    status = Map.get(item, :status) || Map.get(item, "status")
    if is_binary(text) and text != "", do: {one_line(text), status(status)}
  end

  defp step(_item), do: nil

  defp one_line(text), do: text |> String.split(["\r\n", "\n", "\r"]) |> hd() |> String.trim()

  defp status(s) when s in ["done", :done], do: :done
  defp status(s) when s in ["in_progress", :in_progress], do: :in_progress
  defp status(_pending), do: :pending

  @doc "`Plan 3/7`: the done steps over all, `nil` without a plan."
  @spec counter([tuple()]) :: String.t() | nil
  def counter([]), do: nil
  def counter(steps), do: "Plan #{Enum.count(steps, &(elem(&1, 1) == :done))}/#{length(steps)}"

  @doc "The panel's rows for the run's plan (none without one)."
  @spec rows(map(), map() | nil) :: [Panel.row()]
  def rows(ctx, run) do
    case steps(run) do
      [] ->
        []

      steps ->
        {shown, rest} = Enum.split(steps, @shown)
        head = Panel.row(ctx, [{counter(steps), :text_primary, [:bold]}])

        more =
          if rest == [],
            do: [],
            else: [Panel.row(ctx, [{"  … #{length(rest)} more", :text_faint}])]

        [head | Enum.map(shown, &step_row(ctx, &1))] ++ more
    end
  end

  defp step_row(ctx, {text, status}) do
    {mark, role, text_role} = look(status, ctx.state.capabilities.ascii?)
    room = max(ctx.width - 6, 4)

    Panel.row(ctx, [
      {"  ", :plain},
      {mark, role},
      {" " <> Draw.elide(text, room, ctx.state), text_role}
    ])
  end

  defp look(:done, ascii?), do: {if(ascii?, do: "+", else: "✓"), :success, :text_muted}
  defp look(:in_progress, ascii?), do: {if(ascii?, do: ">", else: "▸"), :accent, :text_primary}
  defp look(:pending, ascii?), do: {if(ascii?, do: ".", else: "·"), :text_faint, :text_muted}

  @doc "The strip's part: `   Plan 3/7`, `[]` without a plan."
  @spec strip_part(map() | nil) :: list()
  def strip_part(run) do
    case counter(steps(run)) do
      nil -> []
      words -> [{"   ", :plain}, {words, :text_muted}]
    end
  end
end
