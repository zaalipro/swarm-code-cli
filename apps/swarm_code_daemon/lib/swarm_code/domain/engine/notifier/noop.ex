defmodule SwarmCode.Domain.Engine.Notifier.Noop do
  @moduledoc "The notifier of a build without a platform shell: it notifies nobody."
  @behaviour SwarmCode.Domain.Engine.Notifier

  @impl true
  def notify_waiting(_text), do: :ok

  @impl true
  def notify_finished(_text), do: :ok
end
