defmodule SwarmCode.Domain.Tools.WebFetch.RawStrip do
  @moduledoc """
  Removes `<script>`, `<style>` and comments from an HTML body before
  `Floki.parse_document/1` sees it (spec 74 EFFICIENCY-52).

  `web_fetch` parsed the whole page (up to 4 MB) and then dropped exactly these
  elements; on a script-heavy 3.9 MB page that was 1.5–2.5 s and a 105 MB peak.
  The scan follows Floki's mochiweb tokenizer where these elements start and
  end, so the text is the same:

    * it walks tags the way the tokenizer does (quoted attribute values, an
      unquoted value ending at whitespace, `>` or `/>`, `find_gt` after the
      attributes), so `<a title="<script>">` is not a script;
    * `<title>`, `<textarea>` and `<![CDATA[…]]>` are raw text the tokenizer
      keeps, so they are skipped over, not searched;
    * a script or style is raw up to `</script`/`</style` followed by `>` or
      whitespace (any case), and its end tag runs to the next `>`; a
      self-closing `<script/>` has no raw content and is left to the parser;
    * a comment runs to `-->` or the end of the input.

  Each removed region becomes one space: the parser kept the text on either
  side as two text nodes, which `Floki.text(sep: " ")` joins with a space, and
  the caller collapses whitespace afterwards.

  Anything the scan does not model (`<?`, a quoted doctype, `&` in a tag or
  attribute name) returns `:unknown`, and the caller parses the page as before.
  """

  @spec strip(binary()) :: {:ok, iodata()} | :unknown
  def strip(html) when is_binary(html) do
    scan(html, 0, 0, [])
  catch
    :unknown -> :unknown
  end

  # `from` is the start of the not-yet-copied slice, `pos` the scan position.
  defp scan(html, from, pos, acc) do
    case :binary.match(html, "<", scope(html, pos)) do
      :nomatch ->
        {:ok, Enum.reverse([slice(html, from, byte_size(html)) | acc])}

      {lt, 1} ->
        case tag_at(html, lt) do
          {:skip, next} ->
            scan(html, from, next, acc)

          {:drop, next} ->
            scan(html, next, next, [" ", slice(html, from, lt) | acc])
        end
    end
  end

  defp tag_at(html, lt) do
    rest = byte_size(html) - lt

    cond do
      prefix?(html, lt, "<!--") ->
        {:drop, find_after(html, lt + 4, "-->")}

      prefix?(html, lt, "<![CDATA[") ->
        {:skip, find_after(html, lt + 9, "]]>")}

      prefix?(html, lt, "<!doctype") or prefix?(html, lt, "<!DOCTYPE") ->
        doctype_end(html, lt + 9)

      prefix?(html, lt, "<?") ->
        throw(:unknown)

      prefix?(html, lt, "</") ->
        end_tag_end(html, lt + 2)

      rest >= 2 and letter?(:binary.at(html, lt + 1)) ->
        start_tag(html, lt)

      true ->
        {:skip, lt + 1}
    end
  end

  # tokenize_literal + find_gt: a name starting with `>` is that one byte.
  defp end_tag_end(html, pos) do
    pos = if byte_at(html, pos) == ?>, do: pos + 1, else: pos
    {:skip, find_after(html, pos, ">")}
  end

  defp doctype_end(html, pos) do
    gt = find_after(html, pos, ">")
    body = slice(html, pos, gt)
    if String.contains?(body, ["\"", "'"]), do: throw(:unknown), else: {:skip, gt}
  end

  defp start_tag(html, lt) do
    {name, pos} = literal(html, lt + 1)
    pos = attributes(html, pos)
    {after_gt, slash?} = find_gt(html, pos, false)

    case String.downcase(name) do
      raw when raw in ["script", "style"] and not slash? ->
        close = raw_end(html, after_gt, raw)
        {:drop, if(close == byte_size(html), do: close, else: end_tag_close(html, close))}

      raw when raw in ["title", "textarea"] and not slash? ->
        {:skip, raw_end(html, after_gt, raw)}

      _other ->
        {:skip, after_gt}
    end
  end

  # The `</name` + `>`/whitespace that ends a raw element (any case), or the end.
  defp raw_end(html, pos, name) do
    size = byte_size(html)
    len = byte_size(name)

    case :binary.match(html, "</", scope(html, pos)) do
      :nomatch ->
        size

      {at, 2} ->
        candidate = at + 2

        if candidate + len < size and
             String.downcase(slice(html, candidate, candidate + len)) == name and
             probable_close?(:binary.at(html, candidate + len)),
           do: at,
           else: raw_end(html, at + 1, name)
    end
  end

  defp end_tag_close(html, at), do: elem(end_tag_end(html, at + 2), 1)

  # tokenize_literal: bytes up to whitespace, `>`, `/` or `=`.
  defp literal(html, pos) do
    stop = literal_stop(html, pos)
    name = slice(html, pos, stop)
    if String.contains?(name, "&"), do: throw(:unknown)
    {name, stop}
  end

  defp literal_stop(html, pos) do
    case byte_at(html, pos) do
      nil -> pos
      c when c in [?\s, ?\t, ?\r, ?\n, ?>, ?/, ?=] -> pos
      _ -> literal_stop(html, pos + 1)
    end
  end

  # tokenize_attributes: stops at `>`, `/`, `?>` or the end.
  defp attributes(html, pos) do
    case byte_at(html, pos) do
      nil ->
        pos

      c when c in [?>, ?/] ->
        pos

      ?? ->
        if byte_at(html, pos + 1) == ?>, do: pos, else: attribute(html, pos)

      c when c in [?\s, ?\t, ?\r, ?\n] ->
        attributes(html, pos + 1)

      _ ->
        attribute(html, pos)
    end
  end

  defp attribute(html, pos) do
    # A literal whose first byte is `=` is that one byte.
    pos =
      if byte_at(html, pos) == ?=,
        do: pos + 1,
        else: elem(literal(html, pos), 1)

    value_pos = skip_ws(html, pos)

    pos =
      if byte_at(html, value_pos) == ?=,
        do: attr_value(html, skip_ws(html, value_pos + 1)),
        else: value_pos

    attributes(html, pos)
  end

  defp attr_value(html, pos) do
    case byte_at(html, pos) do
      nil -> pos
      q when q in [?", ?'] -> find_after(html, pos + 1, <<q>>)
      _ -> unquoted_end(html, pos)
    end
  end

  defp unquoted_end(html, pos) do
    case byte_at(html, pos) do
      nil -> pos
      ?/ -> if byte_at(html, pos + 1) == ?>, do: pos, else: unquoted_end(html, pos + 1)
      c when c in [?>, ?\s, ?\t, ?\r, ?\n] -> pos
      _ -> unquoted_end(html, pos + 1)
    end
  end

  defp skip_ws(html, pos) do
    case byte_at(html, pos) do
      c when c in [?\s, ?\t, ?\r, ?\n] -> skip_ws(html, pos + 1)
      _ -> pos
    end
  end

  # find_gt: to the byte after the next `>`, noting any `/` on the way.
  defp find_gt(html, pos, slash?) do
    case byte_at(html, pos) do
      nil -> {pos, slash?}
      ?> -> {pos + 1, slash?}
      ?/ -> find_gt(html, pos + 1, true)
      _ -> find_gt(html, pos + 1, slash?)
    end
  end

  # The position after `pattern`, or the end of the input.
  defp find_after(html, pos, pattern) do
    case :binary.match(html, pattern, scope(html, pos)) do
      :nomatch -> byte_size(html)
      {at, len} -> at + len
    end
  end

  defp scope(html, pos) do
    pos = min(pos, byte_size(html))
    [scope: {pos, byte_size(html) - pos}]
  end

  defp prefix?(html, pos, prefix) do
    len = byte_size(prefix)
    pos + len <= byte_size(html) and binary_part(html, pos, len) == prefix
  end

  defp slice(html, from, to) when to > from, do: binary_part(html, from, to - from)
  defp slice(_html, _from, _to), do: ""

  defp byte_at(html, pos) when pos < byte_size(html), do: :binary.at(html, pos)
  defp byte_at(_html, _pos), do: nil

  defp letter?(c), do: c in ?a..?z or c in ?A..?Z
  defp probable_close?(c), do: c in [?>, ?\s, ?\t, ?\r, ?\n]
end
