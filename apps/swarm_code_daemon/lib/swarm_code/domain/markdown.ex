defmodule SwarmCode.Domain.Markdown do
  @moduledoc "Safe Markdown rendering for chat messages."

  alias SwarmCode.Domain.Markdown.Scrubber

  # A cell that is only digits, separators and signs is a number (spec 11 §1).
  @numeric ~r/^[\d.,%+\-]+$/

  @doc """
  `render/1` memoised per message (spec 12 §11.2): the same content is turned
  into HTML once and reused until it changes. Streaming messages hash their
  live text, so a re-render between two deltas costs nothing.
  """
  @spec render_cached(term(), String.t() | nil) :: SwarmCode.Domain.HTML.safe()
  def render_cached(nil, md), do: render(md)

  def render_cached(id, md) do
    if Process.get(:swarm_code_md_memo, true), do: memoised(id, md), else: render(md)
  end

  defp memoised(id, md) do
    hash = :erlang.phash2(md)

    case SwarmCode.Domain.MarkdownCache.get(id, hash) do
      nil ->
        {:safe, html} = render(md)
        SwarmCode.Domain.MarkdownCache.put(id, hash, html)
        {:safe, html}

      html ->
        {:safe, html}
    end
  end

  @doc """
  Splits streaming text into the part that can no longer change and the growing
  tail (spec 12 §11.2). Earmark re-parsed the *whole* answer on every delta
  batch — 25 ms for a 30 KB reply, ~65 % of the LiveView's CPU under load, and
  the patch carried the whole rendered answer every time. The stable half is
  memoised and its dynamic stops changing, so only the tail is parsed and sent.

  The cut is the last blank line that is not inside a fenced code block, so no
  Markdown construct is ever split in half.
  """
  @spec split_stream(String.t() | nil) :: {String.t(), String.t()}
  def split_stream(nil), do: {"", ""}

  def split_stream(text) when is_binary(text) do
    text
    |> :binary.matches("\n\n")
    |> Enum.reverse()
    |> Enum.find_value({"", text}, fn {at, len} ->
      stable = binary_part(text, 0, at + len)

      if rem(fences(stable), 2) == 0 do
        {stable, binary_part(text, at + len, byte_size(text) - at - len)}
      end
    end)
  end

  defp fences(text), do: length(:binary.matches(text, "```"))

  def render(nil), do: SwarmCode.Domain.HTML.raw("")
  def render(""), do: SwarmCode.Domain.HTML.raw("")

  def render(md) when is_binary(md) do
    md
    |> Earmark.as_html!(%Earmark.Options{
      gfm_tables: true,
      smartypants: false,
      code_class_prefix: "language-",
      escape: true
    })
    # Spec 36 §B1: `escape: true` escapes span-level HTML only — block-level
    # `<script>`, `<iframe>` and `<img onerror=…>` reached `raw/1` intact. The
    # scrubber runs first so `tables/1`'s own `.md-table` wrapper and `td.num`
    # class (ours, not the document's) never have to be on the allowlist.
    |> Scrubber.sanitize()
    |> tables()
    |> safe_links()
    |> safe_images()
    |> SwarmCode.Domain.HTML.raw()
  rescue
    _ -> SwarmCode.Domain.HTML.html_escape(md)
  end

  # Post-processes the tables of an Earmark document (spec 11 §1): each one is
  # wrapped in a `.md-table` scroller — the prose styles wrap letter by letter
  # otherwise — and numeric cells are tagged so the CSS can right-align them.
  # Spec 36 §B9: private — only `render/1` calls it.
  @spec tables(String.t()) :: String.t()
  defp tables(html) when is_binary(html) do
    if String.contains?(html, "<table>") do
      html
      |> String.replace("<table>", ~s(<div class="md-table"><table>))
      |> String.replace("</table>", "</table></div>")
      |> numeric_cells()
    else
      html
    end
  end

  # Strips the `href` of every link the app must not follow (spec 13 §11 B-8 and
  # sakana task 20). Earmark passes `javascript:` and `data:` URLs straight
  # through and the desktop WebView happily runs them, so only `http`, `https`,
  # `mailto`, hash anchors and scheme-free relative paths survive.
  #
  # The href is decoded — HTML entities first, then percent-encoding — before its
  # scheme is read, because `jav&#x61;script:` and `jav%61script:` are the same
  # URL to a browser. Protocol-relative (`//host`, `\\host`) and CR/LF-carrying
  # hrefs are stripped too: the first would replace the app with a remote page,
  # the second is a header-injection shape. The link text and every other
  # attribute stay exactly as they were.
  #
  # Spec 36 §B9: private — the policy is exercised through `safe_href?/1`.
  @spec safe_links(String.t()) :: String.t()
  defp safe_links(html) when is_binary(html) do
    Regex.replace(~r{<a\s([^<>]*)href=(["'])(.*?)\2([^<>]*)>}i, html, fn full,
                                                                         before,
                                                                         _quote,
                                                                         href,
                                                                         rest ->
      if safe_href?(href), do: full, else: ~s(<a #{before}#{rest}>)
    end)
  end

  # The same policy for `<img src>` (spec 36 §B1). `![i](javascript:alert(1))`
  # rendered an `img` whose source a WebView is free to run, and a `data:` image
  # is an exfiltration channel; only `http`, `https`, `#` and scheme-free
  # relative sources keep their `src`. The `alt` text and the rest stay.
  @spec safe_images(String.t()) :: String.t()
  defp safe_images(html) when is_binary(html) do
    Regex.replace(~r{<img\s([^<>]*)src=(["'])(.*?)\2([^<>]*)>}i, html, fn full,
                                                                          before,
                                                                          _quote,
                                                                          src,
                                                                          rest ->
      if safe_href?(src), do: full, else: ~s(<img #{before}#{rest}>)
    end)
  end

  @doc "True when this raw href may keep its `href` attribute."
  @spec safe_href?(String.t()) :: boolean()
  def safe_href?(href) do
    raw = to_string(href)
    probe = raw |> decode_entities() |> percent_decode() |> strip_blanks() |> String.downcase()

    cond do
      # A URL a browser would treat as two lines is never handed on.
      String.match?(raw, ~r/[\r\n]/) -> false
      probe == "" -> false
      String.starts_with?(probe, "//") -> false
      String.starts_with?(probe, "\\\\") -> false
      String.starts_with?(probe, "#") -> true
      String.starts_with?(probe, "http://") -> true
      String.starts_with?(probe, "https://") -> true
      String.starts_with?(probe, "mailto:") -> true
      # Any other scheme — javascript:, data:, file:, vbscript:, … — is out.
      Regex.match?(~r{\A[a-z][a-z0-9+.\-]*:}, probe) -> false
      true -> true
    end
  end

  @named_entities %{
    "colon" => ":",
    "sol" => "/",
    "tab" => "\t",
    "newline" => "\n",
    "amp" => "&",
    "lt" => "<",
    "gt" => ">",
    "quot" => "\"",
    "apos" => "'",
    "nbsp" => " "
  }

  defp decode_entities(text) do
    Regex.replace(~r/&(#[xX]?[0-9a-fA-F]+|[a-zA-Z]+);?/, text, fn full, body ->
      cond do
        String.starts_with?(body, "#x") or String.starts_with?(body, "#X") ->
          codepoint(String.slice(body, 2..-1//1), 16, full)

        String.starts_with?(body, "#") ->
          codepoint(String.slice(body, 1..-1//1), 10, full)

        true ->
          Map.get(@named_entities, String.downcase(body), full)
      end
    end)
  end

  defp codepoint(digits, base, fallback) do
    case Integer.parse(digits, base) do
      {number, ""} when number > 0 and number < 0x110000 -> <<number::utf8>>
      _ -> fallback
    end
  rescue
    _ -> fallback
  end

  defp percent_decode(text) do
    URI.decode(text)
  rescue
    _ -> text
  end

  # Browsers ignore whitespace and control characters inside a URL before they
  # read its scheme, so the probe does too.
  defp strip_blanks(text), do: String.replace(text, ~r/[\x00-\x20\x7f]/, "")

  defp numeric_cells(html) do
    Regex.replace(~r{<td([^<>]*)>([^<>]*)</td>}, html, fn full, attrs, text ->
      cond do
        String.contains?(attrs, "class=") -> full
        not Regex.match?(@numeric, String.trim(text)) -> full
        true -> ~s(<td class="num"#{attrs}>#{text}</td>)
      end
    end)
  end
end
