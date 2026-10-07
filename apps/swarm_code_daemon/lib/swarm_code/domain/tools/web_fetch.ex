defmodule SwarmCode.Domain.Tools.WebFetch do
  @moduledoc """
  Fetch a URL and return its readable text.

  spec 74 BUGS-47: private-network fetches stay supported, behind the
  permission model. `call_permission/1` resolves the host (A and AAAA, 2 s)
  and asks for `:private_network` when it is a dotless intranet name, a
  private literal, or resolves to any loopback, private or link-local
  address. `run/3` then checks every hop again as it fetches it:

    * redirects are followed by hand (at most #{10}), each `Location`
      re-classified — a hop from a public address to a private one is an
      error, and a private hop must stay on the host the user approved;
    * a plain `http` hop connects to the address it classified (the `Host`
      header carries the name), so a second DNS answer cannot move it to
      `127.0.0.1` — DNS rebinding. An `https` hop connects by name: the
      certificate check refuses a server that is not that name;
    * if the host resolves privately now but did not when the call was
      checked, the fetch is refused;
    * non-http(s) targets, URLs carrying a user name or password, and
      unspecified, multicast or broadcast addresses are refused; a private
      hop never goes to the third-party reader.

  The result header names the final URL.
  """
  @behaviour SwarmCode.Domain.Tools.Tool

  alias SwarmCode.Domain.Search.Body

  # spec 74 BUGS-47: what `call_permission/1` decided, for `run/3` in the same
  # operation process (the same hand-off `MCP.take_images/0` uses).
  @gate {__MODULE__, :gate}
  @max_hops 10
  @dns_timeout 2_000

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
        "a page you already have the URL of; use web_search to find one. A localhost, private " <>
        "or intranet address needs the user's approval, and a redirect from a public page to " <>
        "one is refused."

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

  # spec 74 BUGS-47: pure — the registry calls it with `%{}`. The per-call
  # answer is `call_permission/1`.
  @impl true
  def permission(_args), do: :read

  @doc """
  spec 74 BUGS-47: `:private_network` for a URL whose host is a dotless name,
  a private literal, or resolves (A and AAAA, 2 s) to any loopback, private or
  link-local address; `:read` otherwise, including every URL `run/3` refuses
  before it touches the network. The answer is kept for `run/3` in this
  process.
  """
  @impl true
  def call_permission(args) do
    url = args["url"]

    permission =
      with true <- is_binary(url),
           {:ok, _uri, host} <- target(url) do
        case inspect_host(host) do
          {:ok, :private, _addrs} -> :private_network
          # `run/3` refuses an unroutable target before it connects.
          {:ok, _public_or_unroutable, _addrs} -> :read
          {:error, _unresolved} -> if private_name?(host), do: :private_network, else: :read
        end
      else
        _invalid -> :read
      end

    if is_binary(url), do: Process.put(@gate, {url, permission})
    permission
  end

  @impl true
  def title(args), do: "fetch " <> SwarmCode.Domain.Tools.arg_text(args["url"] || "")

  @impl true
  def run(args, ctx, progress) do
    url = if is_binary(args["url"]), do: args["url"], else: ""
    gate = take_gate(url)

    if String.starts_with?(url, ["http://", "https://"]) do
      progress.(30, "fetching")
      timeout = SwarmCode.Domain.Tools.timeout(ctx)
      hop(url, %{gate: gate, first: nil, hops_left: @max_hops}, args, progress, timeout)
    else
      {:error, "invalid url: #{SwarmCode.Domain.Tools.arg_text(args["url"] || "")}"}
    end
  end

  # What the permission check decided for this URL: `:public_only` when it
  # found a public address (so a private one now is a second, different DNS
  # answer), `:private` when the user was asked about a private address (or
  # full access allowed it). A call with no check before it — a test, an
  # internal caller — is `:direct`, gated by nothing here but the redirects.
  defp take_gate(url) do
    case Process.delete(@gate) do
      {^url, :read} -> :public_only
      {^url, :private_network} -> :private
      _none -> :direct
    end
  end

  # One hop of the fetch: check the URL, resolve its host, decide whether this
  # hop may go there, then read it (the reader only for a public first hop)
  # or follow its redirect.
  defp hop(url, state, args, progress, timeout) do
    with {:ok, uri, host} <- target(url),
         {:ok, class, addrs} <- inspect_host(host),
         :ok <- allowed(state, class, host, url) do
      state = if state.first, do: state, else: %{state | first: {host, class}}

      # Spec 24 §4.4: a configured reader (Jina, Firecrawl) returns markdown
      # with the tables and code blocks intact, which is worth far more to a
      # research agent than a stripped DOM. It is never fatal — anything that
      # goes wrong falls straight through to the plain fetch below.
      # spec 73 T105: a localhost, private or link-local address is never
      # handed to the reader — `http://localhost:4812/…` or an intranet URL
      # with a token in its query went to the third party first. spec 74
      # BUGS-47: nor is a name that only resolves to one, or a dotless name.
      if class == :public and state.hops_left == @max_hops do
        case SwarmCode.Domain.Search.read(url, timeout: timeout) do
          {:ok, text} -> readable(url, text, args, progress)
          {:error, _reason} -> fetch(url, uri, host, addrs, state, args, progress, timeout)
        end
      else
        fetch(url, uri, host, addrs, state, args, progress, timeout)
      end
    end
  end

  defp allowed(_state, :public, _host, _url), do: :ok

  defp allowed(_state, :unroutable, host, _url),
    do: {:error, "fetch refused: #{host} is an unspecified, multicast or broadcast address"}

  defp allowed(%{first: nil, gate: :public_only}, :private, host, _url),
    do:
      {:error,
       "fetch refused: #{host} now resolves to a private or loopback address, and it did " <>
         "not when this call was checked"}

  defp allowed(%{first: nil}, :private, _host, _url), do: :ok

  defp allowed(%{first: {_first, :public}}, :private, host, url),
    do:
      {:error,
       "redirect refused: #{url} is on a private or loopback address (#{host}), and the " <>
         "fetch started on a public one"}

  defp allowed(%{first: {host, :private}}, :private, host, _url), do: :ok

  defp allowed(%{first: {_first, :private}}, :private, host, url),
    do:
      {:error,
       "redirect refused: #{url} is another private host (#{host}) than the one approved; " <>
         "fetch it directly to be asked"}

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
  # spec 74 BUGS-47: `redirect: false` — every `Location` is a new hop, checked
  # like the first — and a plain-http hop is pinned to its checked address.
  defp fetch(url, uri, host, addrs, state, args, progress, timeout) do
    {request_url, headers} = pinned(uri, host, addrs)

    options =
      [
        headers: headers,
        redirect: false,
        retry: :safe_transient,
        max_retries: 1,
        receive_timeout: timeout,
        into: Body.collector()
      ] ++ Application.get_env(:swarm_code_daemon, :web_fetch_req_options, [])

    case Req.get(request_url, options) do
      {:ok, %{status: s} = resp} when s in [301, 302, 303, 307, 308] ->
        redirect(url, uri, s, resp, state, args, progress, timeout)

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

  defp redirect(url, uri, status, resp, state, args, progress, timeout) do
    case Req.Response.get_header(resp, "location") do
      [] ->
        {:error, "HTTP #{status} for #{url}"}

      [_location | _] when state.hops_left == 0 ->
        {:error, "too many redirects (more than #{@max_hops}) from #{url}"}

      [location | _] ->
        case merge(uri, location) do
          {:ok, next} ->
            hop(next, %{state | hops_left: state.hops_left - 1}, args, progress, timeout)

          :error ->
            {:error, "HTTP #{status} for #{url} with an unreadable Location"}
        end
    end
  end

  defp merge(uri, location) do
    {:ok, uri |> URI.merge(location) |> URI.to_string()}
  rescue
    _bad_location -> :error
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
  @doc false
  def html_to_text(html) do
    html = String.replace_invalid(html)
    # spec 74 EFFICIENCY-52: script/style/comment bodies are cut before the parse,
    # which only ever discarded them; the filter_outs below still run.
    parse_input =
      case SwarmCode.Domain.Tools.WebFetch.RawStrip.strip(html) do
        {:ok, iodata} -> IO.iodata_to_binary(iodata)
        :unknown -> html
      end

    case Floki.parse_document(parse_input) do
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

  # ------------------------------------------------------------------ spec 74 BUGS-47

  # The URL as one hop sees it: http(s) only, a host, no credentials in it.
  # The host comes back lower-cased, without a trailing dot.
  defp target(url) do
    uri = URI.parse(url)
    host = host_of(uri)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, "invalid url: #{url}"}

      not is_binary(host) or host == "" ->
        {:error, "invalid url: #{url}"}

      uri.userinfo != nil ->
        {:error, "a URL with a user name or password in it is not fetched"}

      true ->
        {:ok, uri, host |> String.downcase() |> String.trim_trailing(".")}
    end
  end

  # Private by its name alone: the literal rules above, or a dotless name
  # (`http://jenkins/…`), which only an intranet resolver answers.
  defp private_name?(host) do
    private_host?("http://" <> bracket(host)) or
      (not String.contains?(host, ".") and not ip_literal?(host))
  end

  defp bracket(host), do: if(String.contains?(host, ":"), do: "[" <> host <> "]", else: host)

  defp ip_literal?(host), do: match?({:ok, _ip}, parse_ip(host))

  defp parse_ip(host),
    do:
      host
      |> String.split(["%25", "%"], parts: 2)
      |> hd()
      |> String.to_charlist()
      |> :inet.parse_address()

  # `{:ok, :public | :private | :unroutable, addresses}` (IPv4 first) or
  # `{:error, reason}`. One private answer makes the host private; one
  # unspecified, multicast or broadcast answer makes it no destination.
  defp inspect_host(host) do
    case resolve(host) do
      {:ok, [_ | _] = addrs} ->
        classes = Enum.map(addrs, &address_class/1)

        cond do
          :unroutable in classes -> {:ok, :unroutable, addrs}
          :private in classes or private_name?(host) -> {:ok, :private, addrs}
          true -> {:ok, :public, addrs}
        end

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      _nothing ->
        {:error, "fetch failed: could not resolve #{host}"}
    end
  end

  defp resolve(host) do
    case parse_ip(host) do
      {:ok, ip} ->
        {:ok, [ip]}

      {:error, _not_literal} ->
        with {:ok, addrs} when is_list(addrs) <- lookup(host),
             do: {:ok, Enum.sort_by(addrs, &(tuple_size(&1) == 8))}
    end
  end

  # The test seam: `config :swarm_code_daemon, :web_fetch_resolver, fn host -> … end`.
  defp lookup(host) do
    case Application.get_env(:swarm_code_daemon, :web_fetch_resolver) do
      fun when is_function(fun, 1) -> fun.(host)
      _default -> dns(host)
    end
  end

  # A and AAAA at once, both inside one 2 s budget, in tasks this operation
  # owns (linked; killed with it, and shut down when they overrun).
  defp dns(host) do
    name = String.to_charlist(host)

    addrs =
      [:inet, :inet6]
      |> Enum.map(fn family -> Task.async(fn -> getaddrs(name, family) end) end)
      |> Task.yield_many(@dns_timeout + 200)
      |> Enum.flat_map(fn
        {_task, {:ok, {:ok, found}}} ->
          found

        {task, nil} ->
          Task.shutdown(task, :brutal_kill)
          []

        _failed ->
          []
      end)

    case addrs do
      [] -> {:error, "fetch failed: could not resolve #{host}"}
      found -> {:ok, Enum.uniq(found)}
    end
  end

  defp getaddrs(name, family) do
    :inet.getaddrs(name, family, @dns_timeout)
  rescue
    _bad_name -> {:error, :einval}
  end

  # spec 74 BUGS-47: loopback, RFC 1918, CGNAT, link-local, IPv6 unique-local
  # and link-local are private; `0.0.0.0/8`, `::`, multicast and broadcast are
  # no destination at all (`0.0.0.0` is this host on macOS and Linux).
  defp address_class({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: address_class({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})

  defp address_class({0, _, _, _}), do: :unroutable
  defp address_class({a, _, _, _}) when a in 224..239, do: :unroutable
  defp address_class({255, 255, 255, 255}), do: :unroutable
  defp address_class({10, _, _, _}), do: :private
  defp address_class({127, _, _, _}), do: :private
  defp address_class({169, 254, _, _}), do: :private
  defp address_class({172, b, _, _}) when b in 16..31, do: :private
  defp address_class({192, 168, _, _}), do: :private
  defp address_class({100, b, _, _}) when b in 64..127, do: :private
  defp address_class({_, _, _, _}), do: :public
  defp address_class({0, 0, 0, 0, 0, 0, 0, 1}), do: :private
  # `::` and the deprecated IPv4-compatible `::a.b.c.d`.
  defp address_class({0, 0, 0, 0, 0, 0, _, _}), do: :unroutable
  # NAT64 (`64:ff9b::/96`) carries an IPv4 address in its last 32 bits.
  defp address_class({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}),
    do: address_class({div(hi, 256), rem(hi, 256), div(lo, 256), rem(lo, 256)})

  defp address_class({a, _, _, _, _, _, _, _}) when a in 0xFF00..0xFFFF, do: :unroutable
  defp address_class({a, _, _, _, _, _, _, _}) when a in 0xFC00..0xFDFF, do: :private
  defp address_class({a, _, _, _, _, _, _, _}) when a in 0xFE80..0xFEBF, do: :private
  defp address_class({_, _, _, _, _, _, _, _}), do: :public

  # A plain-http hop to a name connects to the address that was checked, with
  # the name in `Host`; a second lookup could answer `127.0.0.1` (DNS
  # rebinding). `https` connects by name — the certificate has to match it,
  # which no server behind a rebound answer can do — and a literal is itself.
  defp pinned(%URI{scheme: "http"} = uri, host, [ip | _]) do
    if ip_literal?(host) do
      {URI.to_string(uri), []}
    else
      host_header = if uri.port in [nil, 80], do: uri.host, else: "#{uri.host}:#{uri.port}"
      {URI.to_string(%{uri | host: ip |> :inet.ntoa() |> to_string()}), [{"host", host_header}]}
    end
  end

  defp pinned(uri, _host, _addrs), do: {URI.to_string(uri), []}

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
