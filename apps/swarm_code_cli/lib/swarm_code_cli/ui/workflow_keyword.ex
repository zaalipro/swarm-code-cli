defmodule SwarmCodeCLI.UI.WorkflowKeyword do
  @moduledoc """
  pass73 T5: the word "workflow" in a message.

  A message that does not start with `/` and names `workflow` or `workflows`
  as a whole word, in any case and outside backticks, is sent as
  `/create-workflow <text>`; the composer and the sent user message highlight
  the word (Theme `run_workflow`, bold), and a one-line hint above the
  composer says so. The opt-out key (`Keymap.Bindings`, `:send_plain`) sends
  that one message as it is.

  Whole word means the letters are not part of a longer name: nothing that
  continues an identifier or a path touches them (`create-workflow`,
  `workflow_id`, `priv/workflows/`, `workflow.ex`, `@workflow`, `#workflows`),
  while ordinary punctuation does not stop a match ("a workflow.", "workflow:
  the plan", "the workflow's steps"). A run of N backticks opens a code span
  that the next run of exactly N backticks closes (inline code and fenced
  blocks alike); an unmatched run is literal text.

  Pure and linear in the text; every function takes any binary and never
  raises on invalid UTF-8 (it has no keyword then).
  """

  @type span :: {non_neg_integer(), pos_integer()}

  # Letters, digits, marks and the characters that continue an identifier or a
  # path may not touch the word; a `.` or `:` after it only ends a sentence
  # when whitespace or the end follows.
  @keyword ~r/(?<![\p{L}\p{M}\p{N}_\-\/.@#\\$`])workflows?(?![\p{L}\p{M}\p{N}_\-\/@#\\$`])(?![.:][^\s])/iu
  @ticks ~r/`+/

  @doc """
  The keyword occurrences of `text` as `{byte_offset, byte_length}`, in
  order; `[]` for a slash command (leading whitespace ignored) or text with
  no keyword outside backticks.
  """
  @spec spans(binary()) :: [span()]
  def spans(text) when is_binary(text) do
    if String.valid?(text) and not command?(text) do
      code = code_ranges(text)

      @keyword
      |> Regex.scan(text, return: :index)
      |> Enum.map(fn [{start, length}] -> {start, length} end)
      |> Enum.reject(fn {start, _} -> inside?(start, code) end)
    else
      []
    end
  end

  def spans(_text), do: []

  @doc """
  The same occurrences in grapheme indices (`{first grapheme, graphemes}`),
  the unit the composer's editor counts its cursor in.
  """
  @spec grapheme_spans(binary()) :: [span()]
  def grapheme_spans(text) when is_binary(text) do
    {spans, _} =
      Enum.map_reduce(spans(text), {0, 0}, fn {start, length}, {byte, grapheme} ->
        at = grapheme + String.length(binary_part(text, byte, start - byte))
        count = String.length(binary_part(text, start, length))
        {{at, count}, {start + length, at + count}}
      end)

    spans
  end

  def grapheme_spans(_text), do: []

  @doc """
  `text` cut into `{:text | :keyword, part}` segments in order, for a
  renderer that styles the keyword: concatenating the parts gives `text`.
  """
  @spec segments(binary()) :: [{:text | :keyword, binary()}]
  def segments(text) when is_binary(text) do
    {parts, rest_at} =
      Enum.flat_map_reduce(spans(text), 0, fn {start, length}, at ->
        before = if start > at, do: [{:text, binary_part(text, at, start - at)}], else: []
        {before ++ [{:keyword, binary_part(text, start, length)}], start + length}
      end)

    tail = byte_size(text) - rest_at
    if tail > 0, do: parts ++ [{:text, binary_part(text, rest_at, tail)}], else: parts
  end

  def segments(_text), do: []

  @doc "Whether Enter sends `text` as `/create-workflow` (it has a keyword)."
  @spec routes?(binary()) :: boolean()
  def routes?(text), do: spans(text) != []

  @doc "The command a routed message is sent as: `/create-workflow <text>`."
  @spec command(binary()) :: binary()
  def command(text) when is_binary(text), do: "/create-workflow " <> String.trim(text)

  @doc "The words of the hint line above the composer, `key` naming the opt-out."
  @spec hint(binary()) :: binary()
  def hint(key) when is_binary(key),
    do: "workflow · sends as /create-workflow · #{key} plain message"

  defp command?(text), do: String.starts_with?(String.trim_leading(text), "/")

  # Byte ranges {from, to} (to exclusive) that sit inside backtick code.
  defp code_ranges(text) do
    runs =
      @ticks
      |> Regex.scan(text, return: :index)
      |> Enum.map(fn [{start, length}] -> {start, length} end)
      |> List.to_tuple()

    # The next run of the same length after each run, found from the end in
    # one pass, so pairing stays linear however many runs are unmatched.
    {following, _} =
      Enum.reduce((tuple_size(runs) - 1)..0//-1, {%{}, %{}}, fn index, {next, last} ->
        {_, length} = elem(runs, index)
        {Map.put(next, index, Map.get(last, length)), Map.put(last, length, index)}
      end)

    pair(runs, following, 0, [])
  end

  defp pair(runs, _following, index, ranges) when index >= tuple_size(runs),
    do: Enum.reverse(ranges)

  defp pair(runs, following, index, ranges) do
    case Map.get(following, index) do
      nil ->
        pair(runs, following, index + 1, ranges)

      close ->
        {start, _} = elem(runs, index)
        {close_start, length} = elem(runs, close)
        pair(runs, following, close + 1, [{start, close_start + length} | ranges])
    end
  end

  defp inside?(offset, ranges),
    do: Enum.any?(ranges, fn {from, to} -> offset >= from and offset < to end)
end
