meta = %{
  name: "review-changes",
  description: "Review the uncommitted changes from several angles and keep only findings that survive an adversarial check",
  phases: ["Review", "Verify", "Report"],
  budget: 48,
  args: %{
    base: %{type: :string, default: "", doc: "Git ref to diff against (empty = working tree vs HEAD)"},
    dimensions: %{type: :list, default: ["correctness", "security", "performance", "maintainability"], doc: "Review lenses, one agent each"}
  }
}

findings_schema = %{
  type: :object,
  properties: %{
    findings: %{type: :array, items: %{type: :object, properties: %{
      file: %{type: :string}, line: %{type: :integer}, title: %{type: :string},
      detail: %{type: :string}, severity: %{type: :string, enum: ["low", "medium", "high"]}},
      required: [:file, :title, :detail, :severity]}}},
  required: [:findings]
}

# spec 60 T48: a verdict without quoted evidence is not a confirmation, so the
# schema demands it and the filter below re-checks it.
verdict_schema = %{type: :object, properties: %{real: %{type: :boolean}, reason: %{type: :string}, evidence: %{type: :string}}, required: [:real, :reason, :evidence]}

phase("Review")
diff = host(:git_diff, base: args.base)
if String.trim(diff) == "", do: complete(%{summary: "No changes to review.", confirmed: []})
files = host(:changed_files, base: args.base)
log("#{length(files)} changed files · #{length(args.dimensions)} dimensions")

reviews =
  panel(args.dimensions, fn dim ->
    agent("""
    You review code changes for #{dim} problems only.
    Changed files: #{Enum.join(files, ", ")}
    Read every changed file with read_file and inspect the diff below. Report only concrete problems with file and line.
    An empty list is valid only after you have read every changed file.

    DIFF:
    #{String.slice(diff, 0, 60_000)}
    """, schema: findings_schema, capability: :read_only, name: "review:#{dim}")
  end)

# spec 60 T48: every reviewer failing is not the same as a clean diff.
if Enum.all?(reviews, &is_nil/1), do: pause(:no_progress, "Every reviewer failed")

findings =
  reviews
  |> Enum.filter(&present?/1)
  |> Enum.flat_map(& &1.findings)
  |> Enum.uniq_by(&{&1.file, &1[:line], &1.title})
  # spec 60 T48: a finding about a file this diff never touched is not reviewable.
  |> Enum.filter(&(&1.file in files))

log("#{length(findings)} findings before verification")
if findings == [], do: complete(%{summary: "No findings in #{length(files)} changed files.", confirmed: []})

phase("Verify")
verdicts =
  panel(findings, fn f ->
    agent("""
    Try to REFUTE this finding about #{f.file}#{if f[:line], do: ":#{f[:line]}", else: ""}: #{f.title} — #{f.detail}
    Open the file, inspect the code and decide. Be skeptical: real=false unless you can quote the exact code that proves the problem.
    """, schema: verdict_schema, capability: :read_only, name: "verify:#{Path.basename(f.file)}")
  end)

confirmed =
  Enum.zip(findings, verdicts)
  |> Enum.filter(fn {_f, v} -> present?(v) and v.real and String.trim(v[:evidence] || "") != "" end)
  |> Enum.map(fn {f, v} -> Map.put(f, :evidence, v[:evidence] || "") end)

log("#{length(confirmed)}/#{length(findings)} confirmed")

phase("Report")
report =
  "# Review\n\n#{length(confirmed)} confirmed of #{length(findings)} findings (#{Enum.join(args.dimensions, ", ")}). #{Enum.count(reviews, &present?/1)}/#{length(reviews)} reviewers answered.\n\n" <>
    Enum.map_join(confirmed, "\n", fn f ->
      "- **#{f.severity}** `#{f.file}#{if f[:line], do: ":#{f[:line]}", else: ""}` — #{f.title}\n  #{f.detail}\n  _evidence:_ #{f.evidence}"
    end)
path = write_report("review.md", report)
complete(%{summary: "#{length(confirmed)} confirmed findings (#{length(findings)} reviewed) — see #{path}", confirmed: confirmed, report: path})
