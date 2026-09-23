defmodule SwarmCode.Domain.Research.HtmlRender do
  @moduledoc """
  `result.md` → `report.html`, rendered rather than written (spec 47 §2.6).

  The designed HTML pass (`Prompts.html_reporter/4`) is a second reporter agent
  emitting a whole single-file document — minutes of output tokens for a report
  that carries no fact the Markdown does not. On the Fastest level that is the
  single biggest item on the clock, so this module does the job in microseconds:
  the app's own Markdown pipeline inside a static shell that borrows the
  `html-report` skill's first palette.

  "Build the designed report" still runs the real pass on request
  (`Research.build_report/1`) — this is the floor, not the ceiling.

  ## Safety

  Everything here comes from a model: the report body, the source titles, the
  URLs. The body goes through `SwarmCode.Domain.Markdown.render/1` — Earmark with
  `escape: true`, then `Markdown.Scrubber`, then the `href`/`src` policy — and
  every other interpolation goes through `escape/1`. Nothing model-written is
  ever concatenated into the document raw.
  """

  alias SwarmCode.Domain.Research
  alias SwarmCode.Domain.Research.Levels

  require Logger

  # Spec 25 §2.1: under this, the Open-report button treats the file as a
  # truncated write and stays hidden. The shell alone is ~5 KB, so this is a
  # guard against a broken render, not a real limit.
  @min_bytes 2_000

  @themes "priv/skills/html-report/themes.css"

  # A verbatim copy of palette 1 ("terminal") from the file above, so a build
  # that cannot read its priv dir still renders in the right colours.
  @fallback_palette """
  :root {
    --bg: #060912;
    --surface: #0d1220;
    --surface-2: #121826;
    --border: rgba(255, 255, 255, .07);
    --border-2: rgba(255, 255, 255, .12);
    --text: #e8eaf2;
    --text-dim: #7a8099;
    --text-muted: #4a5068;
    --a1: #00cfb4;
    --a2: #ff6b35;
    --gold: #f0c040;
    --a1-dim: rgba(0, 207, 180, .12);
    --a2-dim: rgba(255, 107, 53, .12);
  }
  """

  # No raw hex below `:root` (the skill's third hard constraint), no JavaScript
  # and no external font: a report opened offline must look the same.
  @css """
  * { box-sizing: border-box }
  html { -webkit-text-size-adjust: 100% }
  body {
    margin: 0; background: var(--bg); color: var(--text);
    font: 15px/1.65 ui-sans-serif, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    font-variant-numeric: tabular-nums;
  }
  .wrap { max-width: 860px; margin: 0 auto; padding: 0 24px 96px }
  .hero { padding: 72px 0 40px; border-bottom: 1px solid var(--border) }
  .eyebrow {
    margin: 0 0 18px; font-size: 10.5px; text-transform: uppercase;
    letter-spacing: .14em; color: var(--text-dim);
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  }
  .hero h1 { margin: 0 0 14px; font-size: 2.5rem; line-height: 1.12; letter-spacing: -.02em; font-weight: 650 }
  .hero .q { margin: 0; color: var(--text-dim); font-size: 15.5px; max-width: 62ch }
  .stats { display: flex; gap: 36px; list-style: none; margin: 32px 0 0; padding: 0 }
  .stats li { display: flex; flex-direction: column; gap: 4px }
  .stats b {
    font-size: 1.7rem; font-weight: 600; color: var(--a1); letter-spacing: -.02em;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  }
  .stats span {
    font-size: 10px; text-transform: uppercase; letter-spacing: .12em; color: var(--text-muted);
  }
  .prose { padding: 8px 0 0 }
  .prose h1 { display: none }
  .prose h2 {
    margin: 72px 0 20px; font-size: 1.35rem; letter-spacing: -.01em; font-weight: 620;
    padding-top: 22px; border-top: 1px solid var(--border);
  }
  .prose h3 { margin: 34px 0 10px; font-size: 1.02rem; font-weight: 600; color: var(--text) }
  .prose p, .prose li { color: var(--text-dim) }
  .prose p { margin: 0 0 16px }
  .prose strong, .prose b { color: var(--text); font-weight: 600 }
  .prose ul, .prose ol { margin: 0 0 18px; padding-left: 22px }
  .prose li { margin: 0 0 8px }
  .prose a { color: var(--a1); text-decoration: none; border-bottom: 1px solid var(--a1-dim) }
  .prose a:hover { border-bottom-color: var(--a1) }
  .prose blockquote {
    margin: 0 0 28px; padding: 16px 20px; border-left: 2px solid var(--a1);
    background: var(--surface); border-radius: 0 6px 6px 0; color: var(--text-dim);
  }
  .prose blockquote p:last-child { margin: 0 }
  .prose code {
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .88em;
    background: var(--surface-2); padding: 1px 5px; border-radius: 4px; color: var(--gold);
  }
  .prose pre {
    background: var(--surface); border: 1px solid var(--border); border-radius: 8px;
    padding: 16px; overflow-x: auto;
  }
  .prose pre code { background: none; padding: 0; color: var(--text-dim) }
  .md-table { overflow-x: auto; margin: 0 0 22px }
  .prose table { border-collapse: collapse; width: 100%; font-size: 13.5px }
  .prose th, .prose td { text-align: left; padding: 9px 12px; border-bottom: 1px solid var(--border) }
  .prose th {
    font-size: 10px; text-transform: uppercase; letter-spacing: .1em; color: var(--text-muted);
    font-weight: 600;
  }
  .prose td.num { text-align: right; font-family: ui-monospace, SFMono-Regular, Menlo, monospace }
  .prose hr { border: 0; border-top: 1px solid var(--border); margin: 40px 0 }
  .sources { margin-top: 72px; padding-top: 22px; border-top: 1px solid var(--border) }
  .sources h2 { margin: 0 0 20px; font-size: 1.35rem; font-weight: 620; letter-spacing: -.01em }
  .sources table { border-collapse: collapse; width: 100% }
  .sources td { padding: 10px 10px 10px 0; border-bottom: 1px solid var(--border); vertical-align: top }
  .sources td.n {
    width: 44px; color: var(--text-muted); font-size: 12px;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  }
  .sources td.t a { color: var(--text); text-decoration: none; font-size: 14px }
  .sources td.t a:hover { color: var(--a1) }
  .sources td.t .h {
    display: block; margin-top: 3px; color: var(--text-muted); font-size: 11.5px;
    font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
  }
  .sources td.q { width: 72px; text-align: right; color: var(--a1); font-size: 10px; letter-spacing: .12em }
  .sources td.q .off { color: var(--text-muted) }
  .foot {
    margin-top: 56px; padding-top: 20px; border-top: 1px solid var(--border);
    color: var(--text-muted); font-size: 12px;
  }
  .foot code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace }
  @media (max-width: 620px) {
    .wrap { padding: 0 18px 64px }
    .hero { padding: 44px 0 30px }
    .hero h1 { font-size: 1.9rem }
    .stats { gap: 24px }
  }
  """

  @doc """
  Renders `markdown_path` into the research's `report.html` and returns the
  path, or nil when the render produced nothing usable.
  """
  @spec write(map(), String.t(), [map()]) :: String.t() | nil
  def write(ctx, markdown_path, sources) do
    markdown = File.read!(markdown_path)
    path = Research.report_path(ctx.id)

    html =
      render(
        title: title_of(markdown) || Research.fallback_title(ctx.question),
        question: ctx.question,
        level: Levels.label(ctx[:level]),
        rounds: ctx[:steps_total] || 1,
        # The row's own shape, not the level's: a research created before its
        # level was reshaped keeps the fan-out it was frozen with, and the
        # strip must count what actually ran.
        agents: agents_of(ctx),
        markdown: markdown,
        sources: sources
      )

    # spec 73 T87: atomic, confined to the research directory; the size check
    # stays on the final path.
    with :ok <- SwarmCode.Domain.AtomicFile.replace(Research.dir(ctx.id), path, html),
         {:ok, %{size: size}} <- File.stat(path) do
      if size >= @min_bytes do
        path
      else
        Logger.info("swarm_code research #{ctx.id}: the rendered report was only #{size} bytes")
        nil
      end
    else
      {:error, reason} ->
        Logger.warning(
          "swarm_code research #{ctx.id}: could not write report.html: " <>
            SwarmCode.Domain.AtomicFile.format_error(reason)
        )

        nil
    end
  rescue
    error ->
      Logger.warning(
        "swarm_code research #{ctx[:id]} could not render its report: #{Exception.message(error)}"
      )

      nil
  end

  @doc """
  The document. `:title`, `:question`, `:level`, `:markdown` and `:sources`,
  plus the optional `:date`, `:rounds` and `:agents`.
  """
  @spec render(keyword()) :: String.t()
  def render(opts) do
    sources = opts |> Keyword.get(:sources, []) |> List.wrap()
    date = Keyword.get(opts, :date) || Date.utc_today()
    rounds = Keyword.get(opts, :rounds, 1)
    {body, _tail} = split_sources(Keyword.fetch!(opts, :markdown), sources)

    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{escape(Keyword.fetch!(opts, :title))}</title>
    <style>
    #{palette()}
    #{@css}
    </style>
    </head>
    <body>
    <div class="wrap">
    <header class="hero">
      <p class="eyebrow">Deep research · #{escape(Keyword.get(opts, :level, "Fastest"))} · #{Date.to_iso8601(date)}</p>
      <h1>#{escape(Keyword.fetch!(opts, :title))}</h1>
      <p class="q">#{escape(Keyword.fetch!(opts, :question))}</p>
      <ul class="stats">
        <li><b>#{length(sources)}</b><span>sources</span></li>
        <li><b>#{rounds}</b><span>round#{if rounds == 1, do: "", else: "s"}</span></li>
        <li><b>#{Keyword.get(opts, :agents, 6)}</b><span>agents</span></li>
      </ul>
    </header>
    <main class="prose">
    #{markdown_html(body)}
    </main>
    #{sources_block(sources)}
    <footer class="foot">
      <p>Rendered by SwarmCode from <code>result.md</code>. For the designed version, use
      <b>Build the designed report</b> on the research page.</p>
    </footer>
    </div>
    </body>
    </html>
    """
  end

  @doc """
  Splits a report's trailing `## Sources` section off the body (spec 47 §2.6).

  The rated table below carries the same list with its quality marks, so
  keeping both would print the sources twice. With no rated sources to show,
  the Markdown's own section stays where it is.
  """
  @spec split_sources(String.t(), [map()]) :: {String.t(), String.t()}
  def split_sources(markdown, []), do: {markdown, ""}

  def split_sources(markdown, _sources) do
    case Regex.scan(~r/^##+\s+Sources\s*$/mi, markdown, return: :index) do
      [] ->
        {markdown, ""}

      matches ->
        {at, _len} = matches |> List.last() |> List.first()
        {binary_part(markdown, 0, at), binary_part(markdown, at, byte_size(markdown) - at)}
    end
  end

  @doc "The report's own `# heading`, which reads better than the raw question."
  @spec title_of(String.t()) :: String.t() | nil
  def title_of(markdown) do
    case Regex.run(~r/^#\s+(.+)$/m, markdown) do
      [_full, title] -> title |> String.trim() |> String.slice(0, 120)
      _other -> nil
    end
  end

  @doc """
  The `:root` token block of the `html-report` skill's first palette
  ("terminal"), or a built-in copy of it when the skill file is gone.

  The file holds five alternative palettes; only the first is taken, because
  five `:root` blocks in one document are a cascade, not a palette.
  """
  @spec palette() :: String.t()
  def palette do
    with {:ok, css} <- File.read(Application.app_dir(:swarm_code_daemon, @themes)),
         [block] <- Regex.run(~r/:root\s*\{[^}]*\}/, css) do
      block
    else
      _other -> @fallback_palette
    end
  end

  # ------------------------------------------------------------------ pieces

  # A lead and its workers per round, plus the one reporter (spec 47 §1).
  defp agents_of(ctx) do
    rounds = ctx[:steps_total] || 1
    fanout = ctx[:fanout] || Levels.fanout(ctx[:level])
    rounds * (fanout + 1) + 1
  end

  defp markdown_html(markdown) do
    markdown
    |> SwarmCode.Domain.Markdown.render()
    |> SwarmCode.Domain.HTML.safe_to_string()
  end

  defp sources_block([]), do: ""

  defp sources_block(sources) do
    rows =
      sources
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {source, index} ->
        url = to_string(source["url"])
        quality = quality(source["quality"])

        href =
          if SwarmCode.Domain.Markdown.safe_href?(url),
            do: ~s( href="#{escape(url)}" target="_blank" rel="noopener noreferrer"),
            else: ""

        """
        <tr>
          <td class="n">[#{index}]</td>
          <td class="t"><a#{href}>#{escape(source["title"] || url)}</a>
            <span class="h">#{escape(host(url))}</span></td>
          <td class="q" title="#{quality}/5">#{String.duplicate("●", quality)}<span class="off">#{String.duplicate("●", 5 - quality)}</span></td>
        </tr>
        """
      end)

    """
    <section class="sources">
      <h2>Sources</h2>
      <table>#{rows}</table>
    </section>
    """
  end

  defp host(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _other -> url
    end
  end

  # spec 68 T36: delegate to the shared Research.rating/1
  defp quality(q), do: SwarmCode.Domain.Research.rating(q)

  defp escape(text),
    do:
      text
      |> to_string()
      |> SwarmCode.Domain.HTML.html_escape()
      |> SwarmCode.Domain.HTML.safe_to_string()
end
