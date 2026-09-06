defmodule SwarmCodeCLI.UI.Activity do
  @moduledoc "Stable Activity ordering; sorting never changes navigation or logical focus."
  def sort(items), do: Enum.sort_by(items, &sort_key/1)

  defp sort_key(%{kind: kind} = item) when kind in [:question, :approval] do
    if is_nil(item.interaction) or item.interaction.state == :pending,
      do:
        {0, item.deadline || (item.interaction && item.interaction.deadline) || :infinity,
         item.created_at, item.id},
      else: {3, -item.created_at, 0, item.id}
  end

  defp sort_key(%{kind: kind} = item) when kind in [:running, :paused],
    do: {1, item.created_at, 0, item.id}

  defp sort_key(%{kind: :failure} = item), do: {2, -item.created_at, 0, item.id}
  defp sort_key(item), do: {3, -item.created_at, 0, item.id}
end
