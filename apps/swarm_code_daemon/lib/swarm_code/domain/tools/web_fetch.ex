defmodule SwarmCode.Domain.Tools.WebFetch do
  @moduledoc "Fetch a URL and return its readable text."
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Search.Body

  @impl true
  def name, do: "web_fetch"

  @impl true
  # Spec 54 §5 (54c H9): "no JavaScript runs" is the failure mode the one-liner
  # left the model to discover on an empty page.
  def description,
    do:
      "Fetch one http(s) URL and return its readable text, with the HTML markup, scripts and " <>
        "navigation stripped. It is a plain fetch: no JavaScript runs, so a page that renders " <>
        "client-side comes back nearly empty, and a login wall comes back as the login page. " <>
        "The text is truncated at max_chars (20 000 by default) with a marker. Use it to read " <>
        "a page you already have the URL of; use web_search to find one."

  @impl true
  def parameters do
    %{
      "type" => "object",
      "properties" => %{
        "url" => %{"type" => "string", "description" => "http(s) URL"},
        "max_chars" => %{"type" => "integer", "description" => "Max characters (default 20000)"}
      },
      "required" => ["url"]
    }
  end

  @impl true
  def permission(_args), do: :read

  @impl true
  def title(args), do: "fetch " <> to_string(args["url"] || "")

  @impl true
  def run(args, ctx, progress) do
    url = to_string(args["url"] || "")

    if String.starts_with?(url, ["http://", "https://"]) do
      progress.(30, "fetching")
      timeout = SwarmCode.Domain.Tools.timeout(ctx)

      # Spec 24 §4.4: a configured reader (Jina, Firecrawl) returns markdown
      # with the tables and code blocks intact, which is worth far more to a
      # research agent than a stripped DOM. It is never fatal — anything that
      # goes wrong falls straight through to the plain fetch below.
      # spec 73 T105: a localhost, private or link-local address is never
      # handed to the reader — `http://localhost:4812/…` or an intranet URL
      # with a token in its query went to the third party first.
      if private_host?(url) do
        fetch(url, args, progress, timeout)
      else
        case SwarmCode.Domain.Search.read(url, timeout: timeout) do
          {:ok, text} -> readable(url, text, args, progress)
          {:error, _reason} -> fetch(url, args, progress, timeout)
        end
      end
    else
      {:error, "invalid url: #{url}"}
    end
  end

  defp readable(url, text, args, progress) do
    progress.(70, "extracting")
    # Spec 51 §7.4 (M7): a reader is free to hand back a Latin-1 page verbatim.
    text = String.replace_invalid(text)
    max = clamp(args["max_chars"] || 20_000, 100, 100_000)
    # spec 73 T106: one grapheme walk over a page that can be 4 MB, not three.
    chars = String.length(text)

    body =
      if chars > max,
        do: String.slice(text, 0, max) <> "…[truncated]",
        else: text

    progress.(100, "#{chars} chars")
    {:ok, "#{url} (markdown, #{chars} chars)\n#{body}"}
  end

  # Spec 51 §7.4 (M7): the body is streamed into a 4 MB cap and refused up front
  # when the type is not text, and `retry: false` is gone — a stale keep-alive
  # connection ended 28 of this project's `web_fetch` ops with "socket closed"
  # when Req's own safe-GET retry would have answered them.
  defp fetch(url, args, progress, timeout) do
    case Req.get(url,
           retry: :safe_transient,
           max_retries: 1,
           receive_timeout: timeout,
           into: Body.collector()
         ) do
      {:ok, %{status: s}} when s < 200 or s >= 300 ->
        {:error, "HTTP #{s} for #{url}"}

      {:ok, resp} ->
        case Body.read(resp) do
          {:skip, :type, ct} -> {:error, "unsupported content type: #{ct}"}
          {:skip, :length, _ct} -> {:error, "the page is larger than 4 MB"}
          {:ok, raw} -> extracted(url, raw, Body.content_type(resp), args, progress)
        end

      {:error, e} ->
        {:error, "fetch failed: " <> Exception.message(e)}
    end
  end

  defp extracted(url, raw, ct, args, progress) do
    progress.(70, "extracting")

    text =
      if String.contains?(ct, "text/html"),
        do: html_to_text(raw),
        else: String.replace_invalid(raw)

    max = clamp(args["max_chars"] || 20_000, 100, 100_000)
    # spec 73 T106
    chars = String.length(text)

    body =
      if chars > max,
        do: String.slice(text, 0, max) <> "…[truncated]",
        else: text

    progress.(100, "#{chars} chars")
    {:ok, "#{url} (#{ct}, #{chars} chars)\n#{body}"}
  end

  # Spec 51 §7.4 (M7): `~r/\s+/u` raised `ArgumentError` on a page that is not
  # valid UTF-8 and the op died as "crashed: argument error" (3 in the dev
  # database). The bytes are repaired first, and the pattern drops the `u` flag:
  # on valid UTF-8 it only ever collapses ASCII whitespace, which is the point.
  defp html_to_text(html) do
    html = String.replace_invalid(html)

    case Floki.parse_document(html) do
      {:ok, doc} ->
        doc
        |> Floki.filter_out("script")
        |> Floki.filter_out("style")
        |> Floki.filter_out("noscript")
        |> Floki.text(sep: " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()

      _ ->
        Regex.replace(~r/<[^>]+>/, html, " ")
    end
  end

  # spec 73 T105: the host literal alone — localhost and its subdomains,
  # `.local`/`.internal`/`.home.arpa`, loopback, RFC 1918, link-local, IPv6
  # unique-local/link-local and their IPv4-mapped forms. A URL without a host
  # counts as private: nothing to send anywhere.
  @doc false
  @spec private_host?(String.t()) :: boolean()
  def private_host?(url) do
    case host_of(URI.parse(url)) do
      host when is_binary(host) and host != "" ->
        host = host |> String.downcase() |> String.trim_trailing(".")

        host == "localhost" or
          String.ends_with?(host, [".localhost", ".local", ".internal", ".home.arpa"]) or
          private_ip?(host)

      _no_host ->
        true
    end
  end

  # `URI.parse/1` cuts an IPv6 literal with a zone id (`[fe80::1%25en0]`) at
  # the `%`; the bracketed authority still holds the whole literal.
  defp host_of(%URI{authority: authority} = uri) when is_binary(authority) do
    case Regex.run(~r/(?:^|@)\[([^\]]*)\]/, authority, capture: :all_but_first) do
      [literal] -> literal
      _plain -> uri.host
    end
  end

  defp host_of(%URI{host: host}), do: host

  defp private_ip?(host) do
    # A zone id (`fe80::1%en0`, `%25` in a URL) is not part of the address.
    host = host |> String.split(["%25", "%"], parts: 2) |> hd()

    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {10, _, _, _}} -> true
      {:ok, {127, _, _, _}} -> true
      {:ok, {169, 254, _, _}} -> true
      {:ok, {172, b, _, _}} when b in 16..31 -> true
      {:ok, {192, 168, _, _}} -> true
      {:ok, {0, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 0}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      {:ok, {0, 0, 0, 0, 0, 0xFFFF, hi, lo}} -> private_ip?(mapped_v4(hi, lo))
      {:ok, {a, _, _, _, _, _, _, _}} when a in 0xFC00..0xFDFF -> true
      {:ok, {a, _, _, _, _, _, _, _}} when a in 0xFE80..0xFEBF -> true
      _public_or_name -> false
    end
  end

  defp mapped_v4(hi, lo), do: "#{div(hi, 256)}.#{rem(hi, 256)}.#{div(lo, 256)}.#{rem(lo, 256)}"

  # spec 68 T19: delegate to the shared Tools.clamp/3.
  defp clamp(value, min_v, max_v), do: SwarmCode.Domain.Tools.clamp(value, min_v, max_v)
end
