defmodule SwarmCodeCLI.UI.ScrollOperation do
  @moduledoc "Closed logical scrolling operations."

  @type t ::
          {:line, integer()}
          | {:half_page, integer()}
          | {:page, integer()}
          | :first
          | :last
          | :follow
          | :detach

  @spec validate(term()) :: {:ok, t()} | {:error, :invalid_scroll_operation}
  def validate(operation) when operation in [:first, :last, :follow, :detach],
    do: {:ok, operation}

  def validate({kind, delta} = operation)
      when kind in [:line, :half_page, :page] and is_integer(delta),
      do: {:ok, operation}

  def validate(_operation), do: {:error, :invalid_scroll_operation}
end
