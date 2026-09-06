defmodule SwarmCodeCLI.UI.MutationState do
  @moduledoc "Closed correlated mutation presentation states."
  @type outcome ::
          :accepted
          | :needs_input
          | :rejected
          | :deadline_exceeded
          | :interrupted
          | :revision_conflict
          | :outcome_unknown
  @type t ::
          :idle
          | {:pending, binary(), SwarmCodeCLI.UI.Intent.t()}
          | {:settled, binary(), outcome()}
  def pending?({:pending, _, _}), do: true
  def pending?(_), do: false
end
