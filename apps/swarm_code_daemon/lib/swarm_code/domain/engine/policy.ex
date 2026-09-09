defmodule SwarmCode.Domain.Engine.Policy do
  @moduledoc "Approval decisions."

  def decide(_mode, :read, _always), do: :allow

  def decide("read_only", permission, _always) when permission in [:write, :execute],
    do: {:deny, "blocked by Read-only approval mode"}

  def decide("auto", :write, _always), do: :allow

  def decide("auto", :execute, always) do
    if MapSet.member?(always, :execute), do: :allow, else: :ask
  end

  def decide("full_access", _permission, _always), do: :allow

  def decide(_mode, _permission, _always), do: :ask
end
