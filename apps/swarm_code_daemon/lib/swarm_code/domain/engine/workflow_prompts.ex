defmodule SwarmCode.Domain.Engine.WorkflowPrompts do
  @moduledoc """
  The authoring instruction (`/create-workflow`, `/workflow <free text>`, Ultra):
  the procedure, the language reference, the patterns and two worked examples
  (spec 09 §5.8, rewritten for spec 11 §10/§2/§R).
  """

  @doc "The whole authoring instruction appended to the assistant's system prompt."
  def create_workflow do
    """
    WORKFLOW AUTHORING MODE. The user asked for work that is worth a workflow, so you author one
    for THIS request and THIS project, save it into the project and launch it. A workflow is a
    host-run, deterministic pipeline: the host steps the program, agents only fill the slots the
    program opens. Talk about "the workflow", never about the file format.

    PROCEDURE — follow it in order, in at most two of your turns:

    1. REUSE FIRST. Call `workflow_list`. If a saved workflow's `when_to_use` covers this request,
       launch it with `workflow_run` instead of authoring anything and say which one you picked.
    2. INTERVIEW ONLY WHEN AMBIGUOUS. If the request has a clear scope and an obvious shape, skip
       this step entirely. Otherwise call `ask_user` ONCE with AT MOST 3 questions, each with 2-4
       option buttons, the RECOMMENDED option FIRST so the user can click straight through:
         · scope / work-list — "Which parts? (a) every dir under lib/ (b) only lib/<x> (c) the
           changed files"
         · verification — "(a) one skeptic per finding, fail-closed (recommended) (b) two skeptics
           (c) none"
         · artifact / budget — "(a) ranked markdown report, ≤ 24 agents (recommended) (b) …"
       Never ask these in prose. If the user answers "defaults are fine" or skips, take the first
       option of each question. Do not ask a fourth question and do not ask again later.
    3. INSPECT THE PROJECT while you author: `list_dir`, `read_file`, `grep` the tree with your own
       tools so the work-list is real. Prefer a work-list you HARD-CODE at authoring time (an array
       of units with a name and a scope) over one the script discovers; use `host(:subdirs)` /
       `host(:files)` only when the list must be recomputed at run time.
    4. AUTHOR the definition: `meta` (with `when_to_use`) → output schemas as variables → one
       section per phase. Child prompts are imperative and self-contained; the PROGRAM, not the
       prompt text, enforces scope, dedup and evidence.
    5. `workflow_smoke_check` with representative args. It runs the read-only host helpers against
       the real project, so "0 agents" means your work-list is empty — fix the discovery and check
       again. Iterate until it passes with at least one agent on the path.
    6. `workflow_save` (scope "project", name derived from the request: lowercase, 2-3 words,
       unique, hyphenated).
    7. `workflow_run` IMMEDIATELY, with the args of step 5. Never ask "shall I launch it?".
    8. One short message: what it will do (phases, fan-out, budget), the run's display name, and
       "I'll report when it finishes". Then stop — you are re-invoked with the result.

    HARD RULES
    - Never offer a pre-coded pipeline as if it were the only option; the built-ins are examples.
    - Never touch the file system from the script: no `File.*`, no `System.cmd`, no `Path.expand`,
      no `Path.wildcard`. They are smoke-check ERRORS. Use `host(...)`.
    - Guard every agent/panel result with `present?/1`; a failed slot is `nil`, never an exception.
    - Every invariant lives in program code, not in prompt text.

    #{reference()}

    #{patterns()}

    #{examples()}
    """
  end

  # The static API reference every authoring turn gets (spec 09 §5.8).
  # spec 73 T53: read only by `create_workflow/0`.
  defp reference do
    """
    THE WORKFLOW LANGUAGE

    A definition is a plain Elixir script. Its FIRST expression must be `meta = %{…}` with a
    LITERAL map (no calls, no variables):
      name        required, ~r/^[a-z][a-z0-9-]{1,40}$/, must equal the file name
      description required, string, at most 200 characters
      when_to_use optional string (≤ 2048): the situations this workflow is the right answer to.
                  Write it — it is how you (and the user) find the workflow again.
      phases      optional list of strings, or of %{title: "Hunt", detail: "one agent per shard"}
      budget      optional integer 1..1024 (agents one run may spend)
      max_live    optional integer 1..64 (agents live at once)
      args        optional map %{key => %{type: :string | :integer | :boolean | :list | :path |
                  :enum, required: bool, default: any, doc: "…", values: [..] (enum only)}}

    Everything after `meta` is the program. It runs with the bindings `args` (atom keys, cast and
    defaulted; `args[:carry]` holds the previous run's result when the user re-ran it with
    "Run again with these results…", otherwise nil) and `meta`, and these functions imported:

      phase(title)            Marks the phase the following agents belong to. Not journaled.
                              Not allowed inside a panel slot.
      agent(prompt, opts)     One child agent. Journaled. Returns its final text, or the
                              validated map when `schema:` is given, or nil when it failed.
                              opts: name: (≤24 chars), schema:, model:, provider:, effort:
                              ("low"|"medium"|"high"|"max"), capability: (:read_only default |
                              :read_write | :execute | :all), isolation: (:shared | :worktree),
                              max_turns:, context:, images:.
                              At most ONE agent/2 per panel slot.
      panel(items, fun)       The only concurrency primitive: a barrier. `fun` takes (item) or
                              (item, index). Returns the slot results in item order; a failed
                              slot is nil. The WHOLE panel is charged against the budget before
                              anything launches; if it does not fit the run pauses with
                              pause_kind "budget" and nothing starts.
      log(text)               A progress line in the run dashboard.
      await_user(q, opts)     Human gate. opts: options: ["yes","no"]. The run waits; on resume
                              the function RETURNS what the user answered. Not allowed in panels.
      pause(kind, message)    Terminal: :missing_input | :blocked | :infrastructure | :no_progress.
                              A resume re-runs the program and hits the same pause unless the
                              world changed. Never use it for a decision — that is await_user.
      complete(value)         Terminal: ends the run with `value` as its result. `value.summary`
                              becomes the conversation message; `value.report` a report path.
      budget()                %{total:, spent:, remaining:}
      present?(x)             not is_nil(x) — guard EVERY agent and panel result with it.
      last_error()            Text of the most recent failed agent call, or nil — for `log/1`.
      fingerprint(value)      Stable 16-hex digest; dedup with
                              `Enum.uniq_by(findings, &fingerprint(&1.file <> "::" <> &1.title))`
                              and detect a round that added nothing new.
      json_encode(value)      Compact JSON of any value (to hand data to a child agent).
      host(op, opts)          The ONLY way to look at the project. Deterministic and journaled,
                              every path relative to the project root:
                              :list_dir (path:) -> [%{name:, path:, dir?:}]
                              :subdirs (path:)  -> ["lib/core", "lib/web"] (child dirs, sorted)
                              :files (pattern:) -> files matching a glob, e.g. "lib/**/*.ex"
                              :glob (pattern:)  -> files and directories
                              :exists? (path:), :dir? (path:) -> booleans
                              :read_file (path:) -> text (or "Error: …")
                              :grep (pattern:, path:) -> [%{file:, line:, text:}]
                              :changed_files (base:), :git_diff (base:, paths:)
                              :git_log (n:, path:) -> [%{sha:, date:, subject:}]
                              :now -> ISO-8601 string (the only blessed way to get "today")
      write_report(name, txt) Writes into the run's scratch space, returns the project-relative
                              path. `read_report(name)` reads one back (nil when missing).
      integrate(result)       Merges the branch of an `isolation: :worktree` agent. Pass the
                              agent's own text result (it ends with `[Changes on branch …]`) or a
                              branch name. An isolated writer you want to integrate must NOT use
                              `schema:` — its answer would be JSON with no branch in it.

    Structured output (`schema:`) uses this subset: type (:object :array :string :integer :number
    :boolean), properties, required (atoms), items, enum, minimum, maximum, description. The host
    validates the object; correction retries cost NO budget. Write schemas as variables before
    their first use.

    Determinism: branches may depend only on `args` and on host-call results. No wall clock, no
    randomness, no shell, no file writes. Every host call and every agent result is journaled, so a
    resume (after a pause, a crash or an app restart) replays what already came back instead of
    paying for it twice. To change a program you edit it and launch a NEW run; resume never takes a
    new script or new args.
    """
  end

  # The patterns and anti-patterns the procedure teaches (spec 73 T53: only
  # `create_workflow/0` reads it).
  defp patterns do
    """
    PATTERNS to reach for (every real workflow uses several of them):
    - Fan out → adversarially verify → synthesize → write the report from the host:
      one hunter per shard, then ONE skeptic per finding told to REFUTE it (`real: false` by
      default, evidence required), keep only what survives, then a single synthesis agent, then
      `write_report/2` and `complete(%{summary: …, report: path})`.
    - Fail CLOSED for proof gates (a missing or failed verdict is NOT confirmation) and fail OPEN
      for advisory panels (fall back to the raw list when the synthesis agent dies) — decide which
      one each gate is, in the code, and say so in a comment.
    - Cap the verify fan-out against `budget().remaining` and `log/1` what you dropped; never
      truncate silently. `budget().remaining` is what is left AFTER the earlier panels, so the cap
      is `min(length(items), max(budget().remaining - reserve, 0))` where `reserve` is only the
      agents still to come (a synthesis or gate agent — usually 1 or 2). Never subtract the item
      count itself: that makes the cap negative and silently verifies nothing.
    - Dedup with `fingerprint/1`; filter agent-discovered items back to the authored scope in the
      program (a live run once shipped ~50 out-of-scope findings because the script trusted the
      agents).
    - Loop until dry: repeat a find-round until two consecutive rounds add no new fingerprints.
    - Sequential "one implementer per numbered task" loops: stop on the first `status: "blocked"`
      or when `budget().remaining <= 3`, then a verify panel, then one final gate agent that runs
      the real test suite with `capability: :execute`.
    - Idempotent re-runs: tell the implementer "if the task is already done, verify it instead of
      redoing it".
    - Prefer agents that run the project's own scripts (`capability: :execute`) over re-implementing
      what the project already does.
    - Isolated writers: `isolation: :worktree` + `integrate/1` when several agents change files.

    ANTI-PATTERNS:
    - Terse child prompts (a child inherits no conversation: repeat the scope, the format and the
      definition of done in every prompt).
    - Using an agent result without `present?/1`.
    - `pause` on a result branch — it re-fires on every resume; a human decision is `await_user`.
    - A work-list built from a shape you never verified against this project (that is what the
      smoke check's "0 agents" error catches).
    - Invariants that live only in prompt text instead of in the program.
    """
  end

  @doc "Two short worked examples (spec 11 §10.4); commands_test reads them too."
  def examples do
    """
    EXAMPLE A — shard fan-out review (hunt → refute → synthesize → report):

    meta = %{
      name: "arch-review",
      description: "Architecture review of lib/, one architect per subtree, skeptic-verified",
      when_to_use: "The user wants architectural or design problems found across a whole tree,
        with evidence, not a diff review",
      phases: [
        %{title: "Hunt", detail: "one architect agent per subdirectory"},
        %{title: "Verify", detail: "one skeptic per finding, fail-closed"},
        %{title: "Report", detail: "synthesis agent + markdown report"}
      ],
      budget: 24,
      args: %{path: %{type: :path, default: "lib", doc: "Directory to review"}}
    }

    findings_schema = %{
      type: :object,
      properties: %{findings: %{type: :array, items: %{type: :object, properties: %{
        title: %{type: :string}, file: %{type: :string}, evidence: %{type: :string},
        suggestion: %{type: :string}, severity: %{type: :string, enum: ["low", "medium", "high"]}},
        required: [:title, :file, :evidence, :suggestion, :severity]}}},
      required: [:findings]
    }

    verdict_schema = %{type: :object, properties: %{real: %{type: :boolean},
      reason: %{type: :string}, evidence: %{type: :string}}, required: [:real, :reason]}

    phase("Hunt")
    shards = host(:subdirs, path: args.path)
    if shards == [], do: pause(:missing_input, "No subdirectories under \#{args.path}")
    log("\#{length(shards)} shards: \#{Enum.join(shards, ", ")}")

    hunts =
      panel(shards, fn shard ->
        agent(\"\"\"
        You are an architect reviewing the \#{shard} subtree of this project.
        Read every source file under \#{shard} (list_dir, then read_file) before you answer.
        Report only structural problems — god-modules, cycles, misplaced logic, supervision gaps —
        each with a quoted code EVIDENCE snippet, a concrete SUGGESTION and a severity.
        An empty list is valid only after you have read every file in \#{shard}.
        \"\"\", schema: findings_schema, capability: :read_only, name: "hunt:\#{Path.basename(shard)}")
      end)

    findings =
      hunts
      |> Enum.filter(&present?/1)
      |> Enum.flat_map(& &1.findings)
      |> Enum.filter(fn f -> Enum.any?(shards, &String.starts_with?(f.file, &1)) end)
      |> Enum.uniq_by(fn f -> fingerprint(f.file <> "::" <> f.title) end)

    if findings == [], do: complete(%{summary: "No architectural findings in \#{args.path}."})

    phase("Verify")
    keep = min(length(findings), max(budget().remaining - 1, 0))
    if keep < length(findings), do: log("capping verification at \#{keep} findings")
    to_verify = Enum.take(findings, keep)

    verdicts =
      panel(to_verify, fn f ->
        agent(\"\"\"
        Try to REFUTE this claim about \#{f.file}: \#{f.title}
        Claimed evidence: \#{f.evidence}
        Open the file yourself. real=true only if you can quote the code that proves it.
        \"\"\", schema: verdict_schema, capability: :read_only, name: "verify:\#{Path.basename(f.file)}")
      end)

    # Fail closed: no verdict is not confirmation.
    confirmed =
      Enum.zip(to_verify, verdicts)
      |> Enum.filter(fn {_f, v} -> present?(v) and v.real end)
      |> Enum.map(fn {f, v} -> Map.put(f, :evidence, v[:evidence] || f.evidence) end)

    phase("Report")
    digest = Enum.map_join(confirmed, "\\n", fn f -> "- [\#{f.severity}] \#{f.file}: \#{f.title}" end)
    synth = agent("Rank these confirmed findings by impact and write a markdown report:\\n" <> digest,
                  capability: :read_only, name: "synthesize")
    report = if present?(synth), do: synth, else: "# Findings\\n\\n" <> digest
    path = write_report("arch-review.md", report)
    complete(%{summary: "\#{length(confirmed)} confirmed findings — see \#{path}", report: path})

    EXAMPLE B — implement a spec, one isolated worker per task, then a real test gate:

    meta = %{
      name: "implement-spec",
      description: "Implements a numbered task list, one isolated agent per task, then verifies",
      when_to_use: "The user has a spec or a checklist of independent tasks to implement here",
      phases: ["Plan", "Implement", "Verify"],
      budget: 32,
      args: %{spec: %{type: :path, required: true, doc: "The spec file"}}
    }

    task_schema = %{type: :object, properties: %{tasks: %{type: :array, items: %{type: :object,
      properties: %{title: %{type: :string}, files: %{type: :array, items: %{type: :string}}},
      required: [:title, :files]}}}, required: [:tasks]}

    phase("Plan")
    spec_text = host(:read_file, path: args.spec)
    plan = agent("Split this spec into independent tasks with the files each one owns:\\n" <>
                 spec_text, schema: task_schema, capability: :read_only, name: "plan")
    if !present?(plan) or plan.tasks == [], do: pause(:blocked, "The spec has no tasks")

    phase("Implement")
    results =
      Enum.reduce_while(plan.tasks, [], fn task, acc ->
        if budget().remaining <= 3 do
          log("stopping early: budget nearly spent")
          {:halt, acc}
        else
          # No schema on an isolated writer: its text report carries the branch,
          # which is what integrate/1 merges.
          r = agent(\"\"\"
              Implement: \#{task.title}
              Files you own: \#{Enum.join(task.files, ", ")}
              If it is already implemented, verify it instead of redoing it.
              Finish with a line "STATUS: done" or "STATUS: blocked <why>".
              \"\"\", capability: :execute, isolation: :worktree,
              name: String.slice(task.title, 0, 24))

          if present?(r) and String.contains?(r, "STATUS: done") do
            integrate(r)
            {:cont, acc ++ [task.title]}
          else
            log("blocked on \#{task.title}: \#{last_error() || "see the agent's report"}")
            {:halt, acc}
          end
        end
      end)

    phase("Verify")
    gate = agent("Run the project's test suite and report failures verbatim.",
                 capability: :execute, name: "test-gate")
    complete(%{summary: "\#{length(results)}/\#{length(plan.tasks)} tasks implemented. " <>
                        "Tests: \#{(present?(gate) && String.slice(gate, 0, 400)) || "not run"}"})
    """
  end
end
