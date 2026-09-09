defmodule SwarmCode.Domain.Markdown.Scrubber do
  @moduledoc """
  The allowlist every rendered Markdown document is passed through (spec 36 §B1).

  Earmark's `escape: true` only escapes **span-level** HTML. Block-level HTML in
  the source — `<script>`, `<iframe>`, `<img onerror=…>`, `<div style=…>` — went
  straight through `SwarmCode.Domain.HTML.raw/1` into the assistant's bubble, a workflow
  summary or the Changes preview of a `.md` file, and LiveView pages carry no
  CSP. A model repeating a web page back at the user was enough to run script in
  the app's own window.

  The list is **empirical**: it is exactly the tags and attributes Earmark emits
  for the fixture in `test/swarm_code_web/components/markdown_test.exs`
  ("the scrubber keeps every construct the app renders"), and nothing else.
  Anything absent from that document — `style` in general, every `on*` handler,
  `script`, `iframe`, `object`, `embed`, `form`, `input`, `svg`, `math` — is
  dropped. Only the three `text-align` values Earmark writes on an aligned
  GFM table cell survive as `style`.

  URLs are **not** this module's job: `href` and `src` keep their attribute
  here and `SwarmCode.Domain.Markdown.safe_links/1` + `safe_images/1` apply the
  app's own (stricter) URL policy right after — they decode entities and
  percent-encoding, and they refuse protocol-relative and CR/LF hrefs, none of
  which this library's scheme check does.
  """

  use HtmlSanitizeEx

  # Block structure.
  allow_tag_with_these_attributes("p", [])
  allow_tag_with_these_attributes("br", [])
  # Earmark writes `<hr class="thin">`.
  allow_tag_with_these_attributes("hr", ["class"])
  allow_tag_with_these_attributes("blockquote", [])
  allow_tag_with_these_attributes("h1", [])
  allow_tag_with_these_attributes("h2", [])
  allow_tag_with_these_attributes("h3", [])
  allow_tag_with_these_attributes("h4", [])
  allow_tag_with_these_attributes("h5", [])
  allow_tag_with_these_attributes("h6", [])

  # Lists.
  allow_tag_with_these_attributes("ul", [])
  allow_tag_with_these_attributes("ol", [])
  allow_tag_with_these_attributes("li", [])

  # Inline.
  allow_tag_with_these_attributes("strong", [])
  allow_tag_with_these_attributes("em", [])
  allow_tag_with_these_attributes("del", [])
  allow_tag_with_these_attributes("a", ["href", "title"])
  allow_tag_with_these_attributes("img", ["src", "alt", "title"])

  # Code: `class` carries the fence's language (`language-elixir`) and the
  # `inline` marker the prose CSS keys on.
  allow_tag_with_these_attributes("pre", [])
  allow_tag_with_these_attributes("code", ["class"])

  # GFM tables. `style` is allowed on `th`/`td` for the three column alignments
  # Earmark emits and for nothing else; the `.md-table` wrapper and the
  # `td.num` class are added by `Markdown.tables/1` *after* this scrubber, so
  # they never have to be allowed here.
  allow_tag_with_these_attributes("table", [])
  allow_tag_with_these_attributes("thead", [])
  allow_tag_with_these_attributes("tbody", [])
  allow_tag_with_these_attributes("tr", [])

  allow_tag_with_this_attribute_values("th", "style", [
    "text-align: left;",
    "text-align: center;",
    "text-align: right;"
  ])

  allow_tag_with_this_attribute_values("td", "style", [
    "text-align: left;",
    "text-align: center;",
    "text-align: right;"
  ])

  allow_tag_with_these_attributes("th", [])
  allow_tag_with_these_attributes("td", [])
end
