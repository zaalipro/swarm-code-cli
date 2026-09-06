defmodule SwarmCodeCLI.UI.DataSource.DTO.Details do
  @moduledoc false
  alias SwarmCodeCLI.UI.DataSource.DTO

  def refs(%DTO.TranscriptItem{} = item),
    do: Enum.reject([item.detail_ref, item.reasoning_detail_ref], &is_nil/1)

  def refs(%DTO.PendingInteraction{approval: %DTO.Approval{arguments_detail_ref: ref}}),
    do: if(ref, do: [ref], else: [])

  def refs(_), do: []

  def find(items, run_id, ref_id) do
    Enum.find_value(items, fn item ->
      if item.run_id == run_id, do: Enum.find(refs(item), &(&1.id == ref_id))
    end)
  end
end
