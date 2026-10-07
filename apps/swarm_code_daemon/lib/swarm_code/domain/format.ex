defmodule SwarmCode.Domain.Format do
  @moduledoc """
  The pure text helpers of the desktop's `SwarmCodeWeb.Format`
  (`lib/swarm_code_web/components/format.ex` at 4c7c577a): `preview/2`,
  `clip_line/3` and `window/2`, unchanged. The synced
  `Conversations.Run.preview/1` calls `clip_line/3` (the web-shims rewrite
  maps `SwarmCodeWeb.Format` here); the rest of the desktop module formats
  numbers and times for templates the CLI does not have.
  """

  @doc "First `n` characters of `text` on a single line, for result previews."
  def preview(text, n \\ 140)

  def preview(text, n) when is_binary(text) and is_integer(n) and n >= 0 do
    case clip_line(text, n, n) do
      {"", false} -> nil
      {line, false} -> line
      {head, true} -> head <> "…"
    end
  end

  def preview(_text, _n), do: nil

  @doc false
  # Spec 74 EFFICIENCY-28: `text` on one line — every run of whitespace (what
  # `~r/\s+/u` matched) one space, trimmed — as `{line, false}` when that has
  # at most `n` graphemes, or `{first keep graphemes, true}` when it has more.
  # Exactly `String.replace(~r/\s+/u, " ") |> String.trim()` and
  # `String.length/1` / `String.slice/3` on the whole text, but it scans a
  # bounded window (grown ×8 until it decides) with no regex: that regex was
  # compiled on every call under OTP 28 and ran over the whole input — 4.1 ms
  # for a 20 KB prompt. `Run.persona/3` shares it.
  @spec clip_line(String.t(), non_neg_integer(), non_neg_integer()) :: {String.t(), boolean()}
  def clip_line(text, n, keep) when is_binary(text), do: clip_line(text, n, keep, n * 8 + 64)

  defp clip_line(text, n, keep, bytes) do
    {prefix, cut?} = window_with_cut(text, min(bytes, byte_size(text)))
    line = one_line(prefix)
    {count, head} = head_and_count(line, line, 0, keep, n + 2, nil)

    cond do
      # Cut inside the text: only the window's last grapheme (and a trailing
      # space) can differ from the whole text's, so `n + 2` graphemes decide.
      cut? and count < n + 2 -> clip_line(text, n, keep, min(bytes * 8, byte_size(text)))
      count > n -> {head, true}
      true -> {line, false}
    end
  end

  # PCRE's `\s` under `/u` (UCP): the Unicode spaces plus U+180E. Every
  # character `String.trim/1` removes is one of these.
  defguardp space?(cp)
            when cp in 0x09..0x0D or cp == 0x20 or cp == 0x85 or cp == 0xA0 or cp == 0x1680 or
                   cp == 0x180E or cp in 0x2000..0x200A or cp == 0x2028 or cp == 0x2029 or
                   cp == 0x202F or cp == 0x205F or cp == 0x3000

  # Collapse and trim in one pass, copying whole words (`binary_part/3`).
  defp one_line(text), do: scan(text, 0, 0, :lead, [], text)

  # Printable ASCII, the common case, without decoding.
  defp scan(<<c, rest::binary>>, pos, from, :word, acc, text) when c > 0x20 and c < 0x7F,
    do: scan(rest, pos + 1, from, :word, acc, text)

  defp scan(<<cp::utf8, rest::binary>>, pos, from, state, acc, text) when space?(cp) do
    size = cp_size(cp)
    acc = if state == :word, do: [acc | binary_part(text, from, pos - from)], else: acc
    scan(rest, pos + size, pos + size, if(state == :lead, do: :lead, else: :gap), acc, text)
  end

  defp scan(<<cp::utf8, rest::binary>>, pos, from, state, acc, text),
    do: scan_word(rest, pos, cp_size(cp), from, state, acc, text)

  # A byte that is not UTF-8 is kept as it is, like any other character.
  defp scan(<<_byte, rest::binary>>, pos, from, state, acc, text),
    do: scan_word(rest, pos, 1, from, state, acc, text)

  defp scan(<<>>, pos, from, :word, acc, text),
    do: IO.iodata_to_binary([acc | binary_part(text, from, pos - from)])

  defp scan(<<>>, _pos, _from, _state, acc, _text), do: IO.iodata_to_binary(acc)

  defp scan_word(rest, pos, size, _from, :lead, acc, text),
    do: scan(rest, pos + size, pos, :word, acc, text)

  defp scan_word(rest, pos, size, _from, :gap, acc, text),
    do: scan(rest, pos + size, pos, :word, [acc | " "], text)

  defp scan_word(rest, pos, size, from, :word, acc, text),
    do: scan(rest, pos + size, from, :word, acc, text)

  defp cp_size(cp) when cp < 0x80, do: 1
  defp cp_size(cp) when cp < 0x800, do: 2
  defp cp_size(cp) when cp < 0x10000, do: 3
  defp cp_size(_cp), do: 4

  # The grapheme count of `line`, capped at `stop`, and its first `keep`
  # graphemes (nil when it has fewer).
  defp head_and_count(_line, _rest, count, _keep, stop, head) when count >= stop,
    do: {count, head}

  # Printable ASCII followed by more ASCII is a grapheme of its own (only a
  # non-ASCII mark can extend it): one byte, no segmentation.
  defp head_and_count(line, <<c, next, _::binary>> = rest, count, keep, stop, head)
       when c >= 0x20 and c < 0x7F and next < 0x80 and count != keep do
    <<_c, rest::binary>> = rest
    head_and_count(line, rest, count + 1, keep, stop, head)
  end

  defp head_and_count(line, rest, count, keep, stop, head) do
    head =
      if count == keep, do: binary_part(line, 0, byte_size(line) - byte_size(rest)), else: head

    case String.next_grapheme(rest) do
      {_grapheme, rest} -> head_and_count(line, rest, count + 1, keep, stop, head)
      nil -> {count, head}
    end
  end

  @doc "A UTF-8-safe prefix containing at most `bytes` bytes."
  def window(text, bytes) when is_binary(text) and is_integer(bytes) and bytes >= 0 do
    text |> window_with_cut(bytes) |> elem(0)
  end

  defp window_with_cut(text, bytes) when byte_size(text) <= bytes, do: {text, false}
  defp window_with_cut(text, bytes), do: {valid_prefix(text, bytes, 0), true}

  # A UTF-8 codepoint is at most four bytes, so a byte window can intersect at
  # most three trailing bytes of one codepoint.
  defp valid_prefix(text, bytes, dropped) when dropped <= 3 do
    prefix = binary_part(text, 0, bytes - dropped)
    if String.valid?(prefix), do: prefix, else: valid_prefix(text, bytes, dropped + 1)
  end
end
