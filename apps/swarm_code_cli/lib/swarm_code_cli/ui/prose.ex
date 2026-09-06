defmodule SwarmCodeCLI.UI.Prose do
  @moduledoc "Word-aware wrapping of bounded, already-escaped transcript text."
  alias SwarmCodeCLI.UI.Width

  @spec wrap(binary(), pos_integer(), :narrow | :wide) :: [binary()]
  def wrap(text, width, policy)
      when is_binary(text) and is_integer(width) and width > 0 and policy in [:narrow, :wide] do
    if text == "" do
      []
    else
      {lines, _} =
        text
        |> String.split(["\r\n", "\n"])
        |> Enum.map_reduce(nil, fn line, fence ->
          marker = fence_marker(line)

          next_fence =
            cond do
              fence && String.trim(line) == fence -> nil
              fence -> fence
              marker -> marker
              true -> nil
            end

          wrapped =
            cond do
              line == "" -> [""]
              fence || marker -> Width.wrap(line, width, policy)
              true -> word_lines(line, width, policy, [])
            end

          {wrapped, next_fence}
        end)

      List.flatten(lines)
    end
  end

  defp fence_marker("```" <> _), do: "```"
  defp fence_marker("~~~" <> _), do: "~~~"
  defp fence_marker(_), do: nil

  defp word_lines("", _, _, lines), do: Enum.reverse(lines)

  defp word_lines(text, width, policy, lines) do
    {head, tail, _} = Width.take_cells(text, width, policy)

    cond do
      head == "" ->
        {grapheme, rest} = String.next_grapheme(text)
        word_lines(rest, width, policy, [grapheme | lines])

      tail == "" ->
        Enum.reverse([head | lines])

      String.ends_with?(head, " ") or String.starts_with?(tail, " ") ->
        word_lines(tail, width, policy, [head | lines])

      true ->
        # Retain whitespace in its source order. Only move a partial word to
        # the next row; tokens wider than the viewport use ordinary cell wrap.
        case whitespace_boundary(head) do
          boundary when is_integer(boundary) ->
            complete = binary_part(head, 0, boundary)
            rest = binary_part(text, boundary, byte_size(text) - boundary)
            word_lines(rest, width, policy, [complete | lines])

          _ ->
            word_lines(tail, width, policy, [head | lines])
        end
    end
  end

  defp whitespace_boundary(text) do
    text
    |> String.graphemes()
    |> Enum.reduce({0, nil}, fn grapheme, {offset, boundary} ->
      next = offset + byte_size(grapheme)
      # A space can own combining marks; never split their cluster at its
      # first byte, or the next viewport would escape a new leading mark.
      boundary = if offset > 0 and String.starts_with?(grapheme, " "), do: next, else: boundary
      {next, boundary}
    end)
    |> elem(1)
  end
end
