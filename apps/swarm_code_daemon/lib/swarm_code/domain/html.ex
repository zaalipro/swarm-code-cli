defmodule SwarmCode.Domain.HTML do
  @moduledoc "HTML escaping and safe-iodata conversion for standalone report export."
  @type safe :: {:safe, iodata()}
  def raw(value), do: {:safe, value}
  def safe_to_string({:safe, value}), do: IO.iodata_to_binary(value)
  def html_escape({:safe, _} = value), do: value
  def html_escape(nil), do: {:safe, ""}

  def html_escape(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")
      |> String.replace("\"", "&quot;")
      |> String.replace("'", "&#39;")

    {:safe, escaped}
  end
end
