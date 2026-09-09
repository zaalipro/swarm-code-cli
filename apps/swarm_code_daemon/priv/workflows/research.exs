meta = %{
  name: "research",
  description: "One-pass research inside this conversation: sweep a few angles, read the best pages, write research.md into the project",
  when_to_use: "Quick, in-project questions where a single sourced note is enough. For a multi-round report with an HTML version, use Deep research (the beaker in the rail, or /deep_research to attach one).",
  phases: ["Sweep", "Read", "Synthesize"],
  budget: 24,
  args: %{
    query: %{type: :string, required: true, doc: "The research question"},
    angles: %{type: :integer, default: 4, doc: "Independent search angles (1-8)"},
    sources: %{type: :integer, default: 6, doc: "Sources to read deeply"}
  }
}

leads_schema = %{type: :object, properties: %{leads: %{type: :array, items: %{type: :object,
  properties: %{url: %{type: :string}, title: %{type: :string}, why: %{type: :string}}, required: [:url, :title, :why]}}}, required: [:leads]}

notes_schema = %{type: :object, properties: %{url: %{type: :string}, summary: %{type: :string},
  facts: %{type: :array, items: %{type: :string}}, quality: %{type: :integer, minimum: 1, maximum: 5}},
  required: [:url, :summary, :facts, :quality]}

lenses = ["official documentation", "recent discussions and issues", "comparisons and critiques",
  "tutorials and examples", "primary or academic sources", "changelogs and release notes", "source code", "benchmarks"]
angles = args.angles |> max(1) |> min(8)

phase("Sweep")
leads =
  panel(Enum.take(lenses, angles), fn lens, i ->
    agent("""
    Research question: #{args.query}
    Angle #{i + 1}: #{lens}.
    Use web_search (several distinct queries) and web_fetch to find the 5 most useful sources for this angle.
    Return leads with url, title and why it matters. Only URLs you actually opened.
    """, schema: leads_schema, capability: :read_only, name: "sweep #{i + 1}")
  end)
  |> Enum.filter(&present?/1)
  |> Enum.flat_map(& &1.leads)
  |> Enum.uniq_by(& &1.url)
  # spec 60 T49: an unbounded `sources` would read (and pay for) as many pages as
  # the sweep happened to find.
  |> Enum.take(args.sources |> max(1) |> min(12))

log("#{length(leads)} unique leads")
if leads == [], do: pause(:no_progress, "The sweep found no sources for: #{args.query}")

phase("Read")
notes =
  panel(leads, fn lead ->
    agent("""
    Read #{lead.url} (#{lead.title}) with web_fetch. Summarize what it says about: #{args.query}
    List concrete facts (numbers, names, versions). Rate the source quality 1-5.
    """, schema: notes_schema, capability: :read_only, name: "read:" <> String.slice(lead.title, 0, 18))
  end)
  |> Enum.filter(&present?/1)

# spec 60 T49: synthesising from nothing is not a research report.
if notes == [], do: pause(:no_progress, "None of the #{length(leads)} sources could be read")

phase("Synthesize")
body = Enum.map_join(notes, "\n\n", fn n -> "### #{n.url} (quality #{n.quality})\n#{n.summary}\n" <> Enum.map_join(n.facts, "\n", &("- " <> &1)) end)
report = agent("""
  Write a sourced research report answering: #{args.query}
  Use ONLY the notes below and cite URLs inline. Sections: Answer (3 sentences), Details, Disagreements and uncertainty, Sources.

  #{body}
  """, capability: :read_only, name: "synthesize")

# spec 60 T49: an empty research.md is a failed run, not a finished one.
if String.trim(to_string(report || "")) == "", do: pause(:no_progress, "Synthesis produced no report")

path = write_report("research.md", report)
complete(%{summary: String.slice(report, 0, 600), report: path, sources: Enum.map(notes, & &1.url)})
