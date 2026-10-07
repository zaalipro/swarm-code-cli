defmodule SwarmCode.Domain.Tools.UpdatePlan do
  @moduledoc """
  Pass 72 F11 (CLI 0.2.0, competitors-14): a live plan for the turn.

  The agent sends the whole checklist each time; the plan is the `input` of
  its newest `update_plan` op node (already persisted, windowed to 8 KB by
  `Engine.Operation`), so nothing new is stored. Root agents only (the chat
  assistant and the swarm Lead, `Tools.for_agent/5`), never workers. The
  desktop shows it as an ordinary tool row this pass; the CLI reads it into
  its run summary.
  """
  @behaviour SwarmCode.Domain.Tools.Tool

  @statuses ~w(pending in_progress done)
  @max_items 30
  @max_text_bytes 200
  # The op node keeps the first 8 192 bytes of the arguments' JSON
  # (`Operation.input_of/1`); a plan that does not fit there could not be read
  # back whole.
  @max_json_bytes 8_192

  @impl true
  def name, do: "update_plan"

  @impl true
  def description,
    do:
      "Keep a live checklist of the steps of this task. Send the whole plan every time " <>
        "(1-30 items, each a short text and a status: pending, in_progress or done; at most " <>
        "one in_progress). Update it as steps finish."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "items" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => @max_items,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "text" => %{"type" => "string", "description" => "The step, at most 200 bytes"},
              "status" => %{"type" => "string", "enum" => @statuses}
            },
            "required" => ["text", "status"]
          }
        }
      },
      "required" => ["items"]
    }
  end

  @impl true
  def permission(_args), do: :read

  # One plan per agent, and the newest op node is the plan: never two at once.
  @impl true
  def parallel?, do: false

  @impl true
  def title(args) do
    case validate(args) do
      {:ok, items} -> "plan (#{progress(items)})"
      {:error, _reason} -> "plan"
    end
  end

  @impl true
  def run(args, _ctx, progress) do
    case validate(args) do
      {:ok, items} ->
        progress.(100, progress(items))
        {:ok, "plan updated (#{progress(items)})"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp progress(items),
    do: "#{Enum.count(items, &(&1["status"] == "done"))}/#{length(items)} done"

  defp validate(%{"items" => items} = args) when is_list(items) do
    cond do
      items == [] ->
        {:error, "the plan needs at least one item"}

      length(items) > @max_items ->
        {:error, "a plan has at most #{@max_items} items"}

      not Enum.all?(items, &valid_item?/1) ->
        {:error,
         "every item needs a text of 1-#{@max_text_bytes} bytes and a status " <>
           "(pending, in_progress or done)"}

      Enum.count(items, &(&1["status"] == "in_progress")) > 1 ->
        {:error, "at most one item can be in_progress"}

      not fits?(args) ->
        {:error, "the plan is too long: shorten the item texts"}

      true ->
        {:ok, items}
    end
  end

  defp validate(_args), do: {:error, "the plan needs an items list"}

  defp fits?(args) do
    case Jason.encode(args) do
      {:ok, json} -> byte_size(json) <= @max_json_bytes
      {:error, _reason} -> false
    end
  end

  defp valid_item?(%{"text" => text, "status" => status})
       when is_binary(text) and status in @statuses,
       do: String.trim(text) != "" and byte_size(text) <= @max_text_bytes

  defp valid_item?(_item), do: false
end
