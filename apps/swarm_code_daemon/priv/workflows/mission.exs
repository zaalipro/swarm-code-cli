# Spec 75 (pass 71): Ultra missions. The orchestrator's plan arrives in
# args.plan (validated by SwarmCode.Missions.Plan); this program writes the
# shared files, waits for the user's approval, then per milestone runs the
# features as parallel workers, merges them one by one (a conflict is redone
# once on the new HEAD, then handed to the user — never conflict markers),
# validates the milestone with two validators and turns failures into fix
# features. Agent names and log lines are a contract with Mission Control
# (spec 75 §5.7) — keep them exact.
#
# Spec 75 §11.1: every agent started after the user approved the plan carries
# `allow_commands: true`. The engine honours it only for this builtin program
# (a user or model-authored workflow passing it gets nothing), so approving the
# plan lets the mission's workers run non-dangerous commands without asking.
meta = %{
  name: "mission",
  description:
    "Ultra mission: validation contract, approval, parallel feature workers, validators and fix rounds",
  phases: ["Contract", "Build", "Validate", "Fix", "Report"],
  budget: 64,
  args: %{
    title: %{type: :string, required: true, doc: "Mission title"},
    plan: %{type: :map, required: true, doc: "The mission plan (mission_start)"},
    parallel: %{type: :integer, default: 1, doc: "Live workers at once (1-4)"},
    isolate: %{type: :boolean, default: false, doc: "Each feature in its own worktree"},
    max_fix_rounds: %{type: :integer, default: 2, doc: "Fix rounds before the user decides"}
  }
}

assertion_schema = %{
  type: :object,
  properties: %{
    assertions: %{
      type: :array,
      items: %{
        type: :object,
        properties: %{
          id: %{type: :string},
          pass: %{type: :boolean},
          evidence: %{type: :string}
        },
        required: [:id, :pass, :evidence]
      }
    },
    notes: %{type: :string}
  },
  required: [:assertions]
}

scrutiny_schema = %{
  type: :object,
  properties: %{
    findings: %{
      type: :array,
      items: %{
        type: :object,
        properties: %{
          file: %{type: :string},
          title: %{type: :string},
          detail: %{type: :string},
          severity: %{type: :string, enum: ["low", "medium", "high"]}
        },
        required: [:title, :detail, :severity]
      }
    },
    summary: %{type: :string}
  },
  required: [:findings]
}

fix_schema = %{
  type: :object,
  properties: %{
    blocked: %{type: :boolean},
    question: %{type: :string},
    fix_features: %{
      type: :array,
      items: %{
        type: :object,
        properties: %{
          title: %{type: :string},
          spec: %{type: :string},
          claims: %{type: :array, items: %{type: :string}}
        },
        required: [:title, :spec, :claims]
      }
    }
  },
  required: [:blocked, :fix_features]
}

plan = args.plan || %{}
milestones = plan["milestones"] || []
contract = plan["contract"] || []
isolate = args.isolate == true
# Spec 75 critic: clamped, so the fix loop below is bounded by a constant and
# every round number fits Mission Control's `\d{1,2}` (contract §5.7).
max_rounds = min(max(args.max_fix_rounds || 2, 0), 6)
isolation = if isolate, do: :worktree, else: :shared

files_text = fn files ->
  shown = Enum.take(files, 5)
  more = length(files) - length(shown)
  Enum.join(shown, ", ") <> if(more > 0, do: " +#{more}", else: "")
end

conflict_files = fn err -> Regex.scan(~r/"([^"]+)"/, err) |> Enum.map(fn [_, f] -> f end) end

handoff = fn text ->
  case Regex.run(~r/HANDOFF\s*(\{.*\})/s, to_string(text)) do
    [_, json] ->
      case Jason.decode(json) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end

    _ ->
      %{}
  end
end

# Spec 75 critic: the branch comes from the host's own note — the LAST
# "[Changes on branch <name> (<stat>)." in the text (run_server.ex:3383-3388).
# `integrate/1` given the raw text takes the FIRST "branch <word>" anywhere
# (api.ex:420), and a worker's own report easily says "the else branch …".
branch_of = fn text ->
  case Regex.scan(~r/\[Changes on branch (\S+) \(/, to_string(text)) do
    [] -> nil
    found -> found |> List.last() |> List.last()
  end
end

has_branch? = fn text -> is_binary(text) and branch_of.(text) != nil end

# integrate/1 with a map reads `:branch` (api.ex:414); the journal payload is
# `{:integrate, branch}`, as before.
merge_branch = fn text -> integrate(%{branch: branch_of.(text)}) end

phase("Contract")

if milestones == [] or contract == [] do
  complete(%{
    summary:
      "The mission plan has no milestones or no contract — revise it and call mission_start again.",
    status: "revise",
    feedback: "",
    report: nil,
    contract: [],
    milestones: [],
    features: []
  })
end

assertion_line = fn a ->
  "- **#{a["id"]}** (#{a["method"]}) #{a["assertion"]} — evidence: #{a["evidence"]}"
end

by_id = Map.new(contract, fn a -> {a["id"], a} end)

claims_text = fn claims ->
  claims
  |> Enum.map(fn id -> by_id[id] end)
  |> Enum.filter(&present?/1)
  |> Enum.map_join("\n", assertion_line)
end

feature_count = Enum.reduce(milestones, 0, fn m, n -> n + length(m["features"] || []) end)

write_report(
  "contract.md",
  "# Validation contract — #{args.title}\n\n" <>
    Enum.map_join(contract, "\n", assertion_line) <> "\n"
)

write_report("guidelines.md", "# Guidelines\n\n" <> (plan["guidelines"] || "") <> "\n")
write_report("knowledge.md", "# Knowledge\n\n" <> (plan["knowledge"] || "") <> "\n")

write_report(
  "features.md",
  "# Features — #{args.title}\n\n" <>
    Enum.map_join(milestones, "\n", fn m ->
      "## #{m["id"]} #{m["title"]}\n\n" <>
        Enum.map_join(m["features"] || [], "\n", fn f ->
          "### #{f["id"]} #{f["title"]}\nClaims: #{Enum.join(f["claims"] || [], ", ")}\n\n#{f["spec"]}\n"
        end)
    end)
)

log(
  "Contract · #{length(contract)} assertions · #{length(milestones)} milestones · #{feature_count} features"
)

pending_result = fn status, summary, feedback ->
  %{
    summary: summary,
    status: status,
    feedback: feedback,
    report: nil,
    contract: Enum.map(contract, fn a -> %{id: a["id"], status: "pending"} end),
    milestones: Enum.map(milestones, fn m -> %{id: m["id"], status: "pending", rounds: 0} end),
    features: []
  }
end

answer =
  String.trim(to_string(await_user("Approve the mission plan?", options: ["Approve", "Cancel"])))

cond do
  answer == "Approve" ->
    :ok

  answer == "Cancel" ->
    complete(
      pending_result.(
        "cancelled",
        "The user cancelled the mission before it started — nothing was changed.",
        ""
      )
    )

  true ->
    complete(
      pending_result.(
        "revise",
        "The user asked for changes to the mission plan before approving it:\n\n> #{String.slice(answer, 0, 2000)}\n\nRevise the plan and call mission_start again.",
        String.slice(answer, 0, 2000)
      )
    )
end

worker_prompt = fn item, milestone, conflicts ->
  conflict_note =
    if conflicts == nil,
      do: "",
      else:
        "\nYOUR FIRST ATTEMPT CONFLICTED with features merged before it (#{files_text.(conflicts)}). The project now contains those features; build this feature again on top of them.\n"

  """
  You are a mission worker. Build exactly this one feature in the project, test-first, and nothing else.

  MISSION: #{args.title}
  MILESTONE #{milestone["id"]}: #{milestone["title"]}
  FEATURE #{item["id"]}: #{item["title"]}

  #{item["spec"]}

  ASSERTIONS THIS FEATURE MUST MAKE TRUE:
  #{claims_text.(item["claims"] || [])}

  GUIDELINES:
  #{plan["guidelines"] || ""}

  WHAT THE ORCHESTRATOR LEARNED:
  #{plan["knowledge"] || ""}
  #{conflict_note}
  Rules: write or extend the tests first and watch them fail; then implement; run the tests and the build until they pass. Change only what this feature needs. Do not commit — the host does. Other workers build the other features of this milestone at the same time in their own copies of the project.

  End your answer with one line: HANDOFF followed by a JSON object {"done": ["what you built"], "tests": ["each command you ran and its result"], "left": ["anything not done"]}.
  """
end

ask_merge = fn name, reason ->
  await_user(
    "#{name} could not be merged into your project: #{String.slice(reason, 0, 300)}. Fix the cause (for example commit or stash your own changes) and retry, skip this feature, or stop the mission?",
    options: ["Retry merge", "Skip it", "Stop"]
  )
end

# One result -> %{"id", "status", "handoff"}. Never leaves a conflict behind:
# integrate/1 aborts a failed merge (Git.merge/3 runs `merge --abort`).
merge = fn item, result, milestone ->
  name = item["name"]
  done = fn status, text -> %{"id" => name, "status" => status, "handoff" => handoff.(text)} end

  cond do
    not present?(result) ->
      log("#{name} failed")
      done.("failed", nil)

    not isolate ->
      log("#{name} done")
      done.("done", result)

    not has_branch?.(result) ->
      log("#{name} no changes")
      done.("no changes", result)

    true ->
      case merge_branch.(result) do
        :ok ->
          log("#{name} merged")
          done.("merged", result)

        {:error, err} ->
          {retry_with, reason} =
            if String.contains?(err, "{:conflicts,") do
              files = conflict_files.(err)
              log("#{name} conflict · #{files_text.(files)}")
              redo_name = name <> " redo"

              redo =
                agent(worker_prompt.(item, milestone, files),
                  name: redo_name,
                  role: :worker,
                  capability: :execute,
                  isolation: isolation,
                  allow_commands: true
                )

              cond do
                not present?(redo) ->
                  log("#{redo_name} failed")
                  {nil, "its redo failed"}

                not has_branch?.(redo) ->
                  log("#{redo_name} no changes")
                  {nil, "its redo changed nothing"}

                true ->
                  case merge_branch.(redo) do
                    :ok -> {:merged, redo}
                    {:error, err2} -> {redo, err2}
                  end
              end
            else
              {result, err}
            end

          case retry_with do
            :merged ->
              log("#{name} redo merged")
              done.("merged", result)

            nil ->
              done.("failed", result)

            text ->
              log("#{name} merge failed · #{String.slice(reason, 0, 200)}")

              case ask_merge.(name, reason) do
                "Retry merge" ->
                  case merge_branch.(text) do
                    :ok ->
                      log("#{name} merged")
                      done.("merged", text)

                    {:error, err3} ->
                      log("#{name} merge failed · #{String.slice(err3, 0, 200)}")
                      done.("merge failed", text)
                  end

                "Stop" ->
                  done.("stopped", text)

                _skip ->
                  done.("merge failed", text)
              end
          end
      end
  end
end

build = fn items, milestone ->
  work = fn item ->
    agent(worker_prompt.(item, milestone, nil),
      name: item["name"],
      role: :worker,
      capability: :execute,
      isolation: isolation,
      allow_commands: true
    )
  end

  # Spec 75 critic: parallel only in isolated trees. In the shared tree the
  # features run one after another whatever `max_live` the run carries.
  results = if isolate, do: panel(items, work), else: Enum.map(items, work)

  # A "Stop" answer at a merge gate halts the loop: the remaining features are
  # reported as stopped and are neither merged nor asked about.
  {merged, _stopped?} =
    items
    |> Enum.zip(results)
    |> Enum.reduce({[], false}, fn {item, result}, {acc, stopped?} ->
      if stopped? do
        {[%{"id" => item["name"], "status" => "stopped", "handoff" => %{}} | acc], true}
      else
        out = merge.(item, result, milestone)
        {[out | acc], out["status"] == "stopped"}
      end
    end)

  Enum.reverse(merged)
end

validate = fn milestone, round, base, built ->
  mid = milestone["id"]
  claims = milestone["features"] |> Enum.flat_map(&(&1["claims"] || [])) |> Enum.uniq()
  diff = String.slice(host(:git_diff, base: base), 0, 60_000)

  # Shared tree: there is no milestone-start commit, so the diff is the project's
  # uncommitted changes — new files are untracked and absent from it, and earlier
  # milestones (or the user's own edits) are in it. Say so, and list every
  # changed or new file so the validator reads what the diff cannot show.
  diff_label =
    if isolate do
      "DIFF (against the milestone start):"
    else
      changed = host(:changed_files, base: "")
      listed = if is_list(changed), do: Enum.join(changed, "\n"), else: to_string(changed)

      "DIFF (the project's uncommitted changes: earlier milestones' work and the user's own edits may be in it, and files created by the workers are NOT shown — read them from this list):\n" <>
        String.slice(listed, 0, 4_000) <> "\n\nDIFF OF TRACKED FILES:"
    end

  handoffs =
    String.slice(
      json_encode(Enum.map(built, &Map.take(&1, ["id", "status", "handoff"]))),
      0,
      8_000
    )

  [scr, tst] =
    panel([:scrutiny, :testing], fn kind ->
      if kind == :scrutiny do
        agent(
          """
          You are the scrutiny validator of milestone #{mid} (#{milestone["title"]}) of the mission "#{args.title}". Review the code the workers wrote: correctness, missed edge cases, broken existing behaviour, tests that do not test what they claim, security problems. Read the changed files, not only the diff. Report findings; never fix anything. Severity high = an assertion below cannot be true or existing behaviour broke.

          ASSERTIONS OF THIS MILESTONE:
          #{claims_text.(claims)}

          WORKER HANDOFFS:
          #{handoffs}

          #{diff_label}
          #{diff}
          """,
          name: "#{mid} scrutiny r#{round}",
          role: :validator,
          capability: :read_only,
          schema: scrutiny_schema,
          allow_commands: true
        )
      else
        agent(
          """
          You are the user-testing validator of milestone #{mid} (#{milestone["title"]}) of the mission "#{args.title}". Check every assertion below the way a user would, with its method: test = run the named or relevant tests; command = run the command and read its output; read = read the code and quote it. Run the project's test command from the guidelines too. You may run commands but you must not change any file. pass is true only when you captured the evidence the assertion asks for; quote it in evidence (the command and the decisive output lines, or the file:line you read). Answer for every id below, in order.

          ASSERTIONS:
          #{claims_text.(claims)}

          GUIDELINES:
          #{plan["guidelines"] || ""}
          """,
          name: "#{mid} testing r#{round}",
          role: :validator,
          capability: :verify,
          schema: assertion_schema,
          allow_commands: true
        )
      end
    end)

  # Spec 75 critic: model output is read with `[:key]` (Access), never `.key` —
  # Schema.atomize/2 keeps only the keys the model sent (schema.ex:215-225).
  answers =
    if present?(tst), do: Map.new(tst[:assertions] || [], fn a -> {a[:id], a} end), else: %{}

  passed =
    Enum.filter(claims, fn id ->
      a = answers[id]
      a != nil and a[:pass] == true and String.trim(to_string(a[:evidence] || "")) != ""
    end)

  failing = claims -- passed

  findings =
    if present?(scr),
      do: scr[:findings] || [],
      else: [
        %{
          title: "the scrutiny validator did not answer",
          detail: to_string(last_error() || ""),
          severity: "high"
        }
      ]

  high = Enum.filter(findings, &(&1[:severity] == "high"))

  log(
    "#{mid} r#{round} verdict · #{length(passed)} pass · #{length(failing)} fail" <>
      if(failing == [], do: "", else: " · failing " <> Enum.join(failing, " "))
  )

  log("#{mid} r#{round} scrutiny · #{length(high)} high · #{length(findings) - length(high)} other")

  %{
    ok: present?(tst) and failing == [] and high == [],
    passed: passed,
    failing: failing,
    high: high,
    answers: answers
  }
end

# The fix planner is the orchestrator role and read-only: no allow_commands.
fix_plan = fn milestone, round, verdict, note ->
  mid = milestone["id"]

  failures =
    Enum.map_join(verdict.failing, "\n", fn id ->
      a = verdict.answers[id]

      "- #{id}: " <>
        ((by_id[id] || %{})["assertion"] || "") <>
        " — validator: " <> to_string((a && a[:evidence]) || "no answer")
    end)

  problems =
    Enum.map_join(verdict.high, "\n", fn f -> "- #{f[:file] || ""} #{f[:title]}: #{f[:detail]}" end)

  agent(
    """
    You are the mission orchestrator. Milestone #{mid} (#{milestone["title"]}) of "#{args.title}" failed validation round #{round - 1}. Turn the failures into at most 4 fix features, each self-contained for a fresh worker (what is wrong, where, how to verify), each claiming the assertion ids it repairs. Fix features of one round run in parallel: they must not edit the same files. If a fix needs a decision only the user can make, set blocked to true and ask one question.

    FAILING ASSERTIONS:
    #{failures}

    HIGH-SEVERITY FINDINGS:
    #{problems}
    #{if note == "", do: "", else: "\nTHE USER ANSWERED YOUR QUESTION: " <> note <> "\n"}
    GUIDELINES:
    #{plan["guidelines"] || ""}
    """,
    name: "#{mid} fixplan r#{round}",
    role: :orchestrator,
    capability: :read_only,
    schema: fix_schema
  )
end

run_milestone = fn milestone ->
  mid = milestone["id"]
  features = milestone["features"] || []

  base =
    if isolate,
      do:
        (case host(:git_log, n: 1) do
           [%{sha: sha} | _] -> sha
           _ -> ""
         end),
      else: ""

  phase("Build")
  log("#{mid} started · #{length(features)} features")

  items = Enum.map(features, fn f -> Map.put(f, "name", f["id"]) end)
  built = build.(items, milestone)

  if Enum.any?(built, &(&1["status"] == "stopped")) do
    %{id: mid, status: "stopped", rounds: 0, built: built, verdict: nil}
  else
    phase("Validate")
    first = validate.(milestone, 0, base, built)

    settle = fn acc ->
      cond do
        acc.status != "pending" ->
          acc

        acc.verdict.ok ->
          log("#{mid} passed")
          %{acc | status: "passed"}

        true ->
          log("#{mid} handed back")
          %{acc | status: "handed back"}
      end
    end

    settle.(
      Enum.reduce_while(
        1..(max_rounds + 2),
        %{id: mid, status: "pending", rounds: 0, built: built, verdict: first},
        fn round, acc ->
          cond do
            acc.verdict.ok ->
              log("#{mid} passed")
              {:halt, %{acc | status: "passed"}}

            true ->
              decision =
                if round > max_rounds,
                  do:
                    await_user(
                      "#{mid} still fails after #{round - 1} fix rounds (failing: #{Enum.join(acc.verdict.failing, " ")}). Fix again, move on to the next milestone, or stop the mission?",
                      options: ["Fix again", "Next milestone", "Stop"]
                    ),
                  else: "Fix again"

              cond do
                decision == "Stop" ->
                  log("#{mid} handed back")
                  {:halt, %{acc | status: "stopped"}}

                decision != "Fix again" ->
                  log("#{mid} handed back")
                  {:halt, %{acc | status: "handed back"}}

                true ->
                  phase("Fix")
                  plan_a = fix_plan.(milestone, round, acc.verdict, "")

                  plan_b =
                    if present?(plan_a) and plan_a[:blocked] == true do
                      note =
                        to_string(
                          await_user(
                            "#{mid}: " <> to_string(plan_a[:question] || "The fix needs your decision."),
                            []
                          )
                        )

                      fix_plan.(milestone, round, acc.verdict, note)
                    else
                      plan_a
                    end

                  fixes =
                    if present?(plan_b) and plan_b[:blocked] != true,
                      do: Enum.take(plan_b[:fix_features] || [], 4),
                      else: []

                  if fixes == [] do
                    log("#{mid} handed back")
                    {:halt, %{acc | status: "handed back", rounds: round}}
                  else
                    log("#{mid} fix round #{round} · #{length(fixes)} fix features")

                    items =
                      fixes
                      |> Enum.with_index(1)
                      |> Enum.map(fn {f, i} ->
                        name = "#{mid} fix#{round}.#{i}"

                        %{
                          "id" => name,
                          "name" => name,
                          "title" => to_string(f[:title] || ""),
                          "spec" => to_string(f[:spec] || ""),
                          "claims" => f[:claims] || []
                        }
                      end)

                    fixed = build.(items, milestone)

                    if Enum.any?(fixed, &(&1["status"] == "stopped")) do
                      {:halt, %{acc | status: "stopped", rounds: round, built: acc.built ++ fixed}}
                    else
                      phase("Validate")
                      verdict = validate.(milestone, round, base, acc.built ++ fixed)
                      {:cont, %{acc | rounds: round, built: acc.built ++ fixed, verdict: verdict}}
                    end
                  end
              end
          end
        end
      )
    )
  end
end

outcomes =
  Enum.reduce_while(milestones, [], fn milestone, done ->
    outcome = run_milestone.(milestone)
    if outcome.status == "stopped", do: {:halt, done ++ [outcome]}, else: {:cont, done ++ [outcome]}
  end)

stopped? = Enum.any?(outcomes, &(&1.status == "stopped"))
if stopped?, do: log("Mission stopped by the user")

reached = Map.new(outcomes, fn o -> {o.id, o} end)

contract_status =
  Enum.map(contract, fn a ->
    owner =
      Enum.find(milestones, fn m ->
        Enum.any?(m["features"] || [], &(a["id"] in (&1["claims"] || [])))
      end)

    o = owner && reached[owner["id"]]

    status =
      cond do
        o == nil or o.verdict == nil -> "pending"
        a["id"] in o.verdict.passed -> "pass"
        true -> "fail"
      end

    %{id: a["id"], status: status}
  end)

milestone_status =
  Enum.map(milestones, fn m ->
    case reached[m["id"]] do
      nil -> %{id: m["id"], status: "pending", rounds: 0}
      o -> %{id: m["id"], status: o.status, rounds: o.rounds}
    end
  end)

feature_status =
  Enum.flat_map(outcomes, fn o -> Enum.map(o.built, &%{id: &1["id"], status: &1["status"]}) end)

status =
  cond do
    stopped? -> "stopped"
    Enum.all?(milestone_status, &(&1.status == "passed")) -> "passed"
    true -> "partial"
  end

pass_n = Enum.count(contract_status, &(&1.status == "pass"))
failing_ids = for c <- contract_status, c.status == "fail", do: c.id

phase("Report")

report_text =
  "# Mission report — #{args.title}\n\n" <>
    "Status: **#{status}** · #{pass_n}/#{length(contract)} assertions pass\n\n" <>
    "## Milestones\n\n" <>
    Enum.map_join(milestone_status, "\n", fn m -> "- #{m.id}: #{m.status} (#{m.rounds} fix rounds)" end) <>
    "\n\n## Contract\n\n" <>
    Enum.map_join(contract_status, "\n", fn c ->
      "- #{c.id}: #{c.status} — " <> ((by_id[c.id] || %{})["assertion"] || "")
    end) <>
    "\n\n## Features\n\n" <>
    Enum.map_join(feature_status, "\n", fn f -> "- #{f.id}: #{f.status}" end) <> "\n"

report = write_report("mission-report.md", report_text)

summary =
  "Mission \"#{args.title}\" #{status}: #{pass_n}/#{length(contract)} assertions pass. " <>
    Enum.map_join(milestone_status, ", ", fn m -> "#{m.id} #{m.status}" end) <>
    "." <>
    if(failing_ids == [], do: "", else: " Failing: " <> Enum.join(failing_ids, " ") <> ".") <>
    " Report: #{report}"

complete(%{
  summary: String.slice(summary, 0, 4000),
  status: status,
  report: report,
  contract: contract_status,
  milestones: milestone_status,
  features: feature_status
})
