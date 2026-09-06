defmodule SwarmCode.LLM.SSE do
  @moduledoc "Incremental server-sent-events parser shared by the LLM clients."

  @type event :: %{event: String.t() | nil, data: String.t()}

  @doc """
  Appends `chunk` to `buffer`, returns every complete event and the unparsed rest.

      iex> SwarmCode.LLM.SSE.parse("", "event: x\\ndata: 1\\ndata: 2\\n\\ndata: tail")
      {[%{event: "x", data: "1\\n2"}], "data: tail"}
  """
  @spec parse(String.t(), String.t()) :: {[event], String.t()}
  def parse(buffer, chunk) do
    buf = String.replace(buffer <> chunk, "\r\n", "\n")
    parts = String.split(buf, "\n\n")
    {complete, [rest]} = Enum.split(parts, -1)
    events = complete |> Enum.map(&parse_block/1) |> Enum.reject(&is_nil/1)
    {events, rest}
  end

  defp parse_block(block) do
    # Data lines are collected newest-first and reversed once: an event with
    # thousands of `data:` lines used to copy the whole list per line.
    {event, data} =
      block
      |> String.split("\n")
      |> Enum.reduce({nil, []}, fn line, {event, data} ->
        cond do
          String.starts_with?(line, "data:") -> {event, [strip(line, "data:") | data]}
          String.starts_with?(line, "event:") -> {strip(line, "event:"), data}
          true -> {event, data}
        end
      end)

    if data == [], do: nil, else: %{event: event, data: data |> Enum.reverse() |> Enum.join("\n")}
  end

  defp strip(line, prefix) do
    line |> String.replace_prefix(prefix, "") |> String.replace_prefix(" ", "")
  end
end
