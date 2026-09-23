defmodule SwarmCode.Domain.Research.Prompts do
  @moduledoc "The three prompts and two schemas a deep research runs on (spec 24 §6)."

  alias SwarmCode.Domain.Research.Levels

  # A step lead sees this much of what is already known; newest notes first, so
  # what gets cut is the oldest round, not the most recent one.
  @notes_cap 24_000

  # Spec 51 §5.14: the reporter sees every note (≈ 75 K tokens, under the
  # `Context` trim and every current window); a deep round lead sees the newest
  # round in full and the older rounds as one compact block each, under this.
  @reporter_notes_cap 300_000
  @lead_notes_cap 60_000

  # ------------------------------------------------------------------ schemas

  @doc "What a step lead must return."
  def plan_schema do
    %{
      "type" => "object",
      "properties" => %{
        "interpretation" => %{
          "type" => "string",
          "description" =>
            "How you read the question: scope, entities, time range, what is out of scope. One paragraph."
        },
        "title" => %{
          "type" => "string",
          "description" =>
            "3-6 words naming this research as a list entry — a label like " <>
              "\"Air-cooled bikes under 3,500 rpm\", not the question rephrased, not a sentence"
        },
        "step_title" => %{
          "type" => "string",
          "description" => "3-6 words naming what this round goes after"
        },
        "tasks" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "title" => %{"type" => "string", "description" => "2-5 words"},
              "question" => %{
                "type" => "string",
                "description" => "The one question this agent has to answer"
              },
              "queries" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" => "2-4 distinct search queries to start from"
              }
            },
            "required" => ["title", "question", "queries"]
          }
        }
      },
      "required" => ["interpretation", "step_title", "tasks"]
    }
  end

  @doc "What a worker must return."
  def note_schema do
    %{
      "type" => "object",
      "properties" => %{
        "summary" => %{"type" => "string", "description" => "What you found, in a paragraph"},
        "facts" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" =>
            "Concrete: numbers, dates, versions, names. Each fact ends with the URL it came from."
        },
        "sources" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "url" => %{"type" => "string"},
              "title" => %{"type" => "string"},
              "quality" => %{"type" => "integer", "minimum" => 1, "maximum" => 5}
            },
            "required" => ["url", "title", "quality"]
          },
          "description" => "Only pages you actually opened"
        },
        "open_questions" => %{
          "type" => "array",
          "items" => %{"type" => "string"},
          "description" => "What you could not settle, for the next round"
        }
      },
      "required" => ["summary", "facts", "sources"]
    }
  end

  # ------------------------------------------------------------------ prompts

  @doc "The step lead: plan exactly `fanout` independent tasks for round `index`."
  def plan(ctx, index, notes) do
    if Levels.fast?(ctx.level), do: fast_plan(ctx), else: deep_plan(ctx, index, notes)
  end

  # Spec 47 §2.2: one call, no tools, no earlier round to aim past. Everything
  # the deep prompt says about follow-up rounds and sanity-checking angles is
  # gone; what is left is the shape of the answer and the fan-out.
  defp fast_plan(ctx) do
    """
    You are the lead of a FAST deep research: one round, #{ctx.fanout} agents working in
    parallel, and the whole thing has to be finished in minutes rather than hours.

    RESEARCH QUESTION
    #{ctx.question}

    YOUR JOB
    Plan **exactly #{ctx.fanout}** tasks and return them through structured_output.
    This is your only turn and you have no tools: plan from the question alone.

    RULES
    - Each task must be answerable on its own, in parallel with the others. Never make
      one task depend on another's result.
    - Spread them across genuinely different angles: what the thing actually is, the hard
      numbers, who disagrees, and what changed most recently.
    - Give each task ONE or TWO concrete search queries — real queries someone would type,
      not restatements of the title. Each agent has about a minute; a longer list of
      queries only slows it down.
    - `interpretation` records how you are reading the question: the entities, the time
      range and what you are treating as out of scope. One short paragraph.
    - `title` is 3-6 words naming the research for its list entry — a label, not the
      question rephrased and not a sentence.

    Do not research here. Call structured_output once and stop.
    """
  end

  # Spec 48 §1: the lead's sanity-check searches are batched for the same reason —
  # they sit on the round's critical path, before any agent has started.
  defp deep_plan(ctx, index, notes) do
    """
    You are the lead of round #{index} of #{ctx.steps_total} in a deep research.

    RESEARCH QUESTION
    #{ctx.question}

    Depth: #{Levels.label(ctx.level)} — #{ctx.steps_total} round(s), #{ctx.fanout} agents per round.

    #{known(index, notes)}

    YOUR JOB
    Plan **exactly #{ctx.fanout}** tasks and return them through structured_output.

    RULES
    - Each task must be answerable on its own, in parallel with the others. Never
      make one task depend on another's result.
    - #{angle_rule(index)}
    - Give each task 2-4 concrete search queries to start from — real queries, not
      restatements of the title.
    - `interpretation` records how you are reading the question: the entities, the
      time range and what you are treating as out of scope. Write it even on later
      rounds; only round 1's is kept.
    - `title` is 3-6 words naming the research for its list entry — a label, not the
      question rephrased and not a sentence. Only round 1's is kept.
    - You may use web_search yourself to sanity-check that an angle exists before
      you spend an agent on it, but do not do the research here. If you check several
      angles, issue every check as one batch in a single turn — the calls of one turn
      run in parallel — and do not open pages.
    """
  end

  defp angle_rule(1),
    do:
      "This is the opening round: spread the tasks across genuinely different angles — " <>
        "official documentation and primary sources, recent discussion and issues, " <>
        "comparisons and critiques, and hard numbers or benchmarks."

  defp angle_rule(_index),
    do:
      "This is a follow-up round: aim **only** at what the notes below leave open — " <>
        "contradictions between sources, unanswered `open_questions`, claims with a " <>
        "single weak source, and quantities nobody has pinned down. Never repeat a " <>
        "task that has already run."

  defp known(1, _notes), do: "Nothing has been researched yet."

  # Spec 51 §5.14: two tiers — the newest round's notes in full, the older
  # rounds compacted (task, summary, open questions, a source count) — so a
  # round-3 lead still sees every earlier task instead of the last three notes.
  defp known(_index, notes) do
    newest = notes |> Enum.map(&note_round/1) |> Enum.max(fn -> nil end)

    {recent, older} =
      Enum.split_with(notes, &(note_round(&1) == newest or is_nil(note_round(&1))))

    """
    WHAT IS ALREADY KNOWN (newest first, older material may be truncated)

    #{render_notes(recent, @lead_notes_cap)}

    EARLIER ROUNDS, IN BRIEF
    #{if older == [], do: "(none)", else: older |> Enum.reverse() |> Enum.map(&brief_note/1) |> cap(@lead_notes_cap)}
    """
  end

  defp note_round(note), do: note["round"]

  defp brief_note(note) do
    open = note["open_questions"] || []

    "- #{note["task"] || "note"}: #{one_line(note["summary"] || "")}" <>
      if(open == [], do: "", else: " Open: " <> Enum.join(open, "; ")) <>
      " (#{length(List.wrap(note["sources"]))} sources)"
  end

  # A headline is one line about one round; it never needs more than this much
  # of what the round found.
  @headline_cap 6_000

  # The numbered source list only has to resolve the `[n]` markers.
  @sources_cap 12_000

  @html_retry_note """
  YOUR FIRST ATTEMPT PRODUCED NO FILE. Something went wrong before `write_file`
  landed. Do not explore, do not explain, do not plan: call `write_file` with
  the whole document as your very first action this turn.

  """

  @doc "What the headline agent must return (spec 26 §4.1)."
  def headline_schema do
    %{
      "type" => "object",
      "properties" => %{
        "headline" => %{
          "type" => "string",
          "description" =>
            "What this round found, in AT MOST TEN WORDS. No trailing full stop, " <>
              "no quotes, no colon-prefixed label."
        }
      },
      "required" => ["headline"]
    }
  end

  @doc """
  The headline prompt (spec 26 §4.1).

  Spec 54 §5 (54c H8): the ten-word limit is the schema field's contract and
  `SwarmCode.Domain.Research.headline/1` clamps it — and the trailing full stop —
  whatever comes back, so the prompt states neither a second time. No wording
  here can change the output, and a duplicated rule is prefix cost a model that
  follows prompts literally has to reconcile.
  """
  def headline(question, notes) do
    """
    A round of a deep research just finished. Write its headline.

    THE RESEARCH QUESTION
    #{one_line(question)}

    WHAT THIS ROUND FOUND
    #{notes |> Enum.map(&("- " <> one_line(&1["summary"] || &1["task"]))) |> cap(@headline_cap)}

    RULES
    - Say what was *found*, not what was *done*. "Texas exurbs drive every top
      growth rate" — not "Researched Texas exurb growth rates".
    - No quotes, no "Round 2:" prefix, no emoji.

    Call structured_output once with the headline and nothing else.
    """
  end

  @doc "Everything gathered so far, newest first, capped (spec 51 §5.14: the cap is the caller's)."
  def render_notes(notes, cap \\ @notes_cap)
  def render_notes([], _cap), do: "(nothing yet)"

  def render_notes(notes, cap) do
    notes
    |> Enum.reverse()
    |> Enum.map(&render_note/1)
    |> cap(cap)
  end

  defp render_note(note) do
    facts = Enum.map_join(note["facts"] || [], "\n", &("- " <> to_string(&1)))
    open = note["open_questions"] || []

    urls =
      note["sources"]
      |> List.wrap()
      |> Enum.map_join(", ", fn s -> "#{s["url"]} (#{s["quality"]}/5)" end)

    """
    ### #{if note["partial"], do: "PARTIAL — ", else: ""}#{note["task"] || "note"}
    #{note["summary"]}
    #{facts}
    #{if open == [], do: "", else: "Open: " <> Enum.join(open, "; ")}
    Sources: #{urls}
    """
  end

  # spec 73 T88: the callers feed newest-first lists and promise "what gets
  # cut is the oldest round". The reduce used to skip an overflowing part and
  # keep scanning, so a large newest note was dropped while smaller older
  # ones after it were kept — a hole in the most recent round. Now the first
  # overflow ends the scan, with that part truncated to fill the remainder.
  defp cap(parts, limit) do
    parts
    |> Enum.reduce_while({[], 0}, fn part, {kept, size} ->
      length = String.length(part)

      cond do
        size + length <= limit ->
          {:cont, {[part | kept], size + length}}

        limit - size > 0 ->
          {:halt, {[String.slice(part, 0, limit - size) | kept], limit}}

        true ->
          {:halt, {kept, size}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join("\n")
    |> case do
      "" -> "(nothing yet)"
      text -> text
    end
  end

  @doc "One worker: answer one task's question with sources it actually opened."
  def worker(ctx, task, opts \\ []) do
    if Levels.fast?(ctx.level), do: fast_worker(ctx, task), else: deep_worker(ctx, task, opts)
  end

  # Spec 47 §2.3: the deep worker is told to run "several distinct web_search
  # calls" and to open at least `max_sources` pages — five fetches of 20 000
  # characters each, re-sent on every turn. The fast one is told the opposite,
  # and told that being late is the only unrecoverable mistake.
  defp fast_worker(ctx, task) do
    queries = task["queries"] |> List.wrap() |> Enum.map_join("\n", &("- " <> to_string(&1)))

    """
    You are one of #{ctx.fanout} research agents in a FAST deep research. Answer exactly one
    question, and answer it within about a minute.

    OVERALL RESEARCH QUESTION
    #{ctx.question}

    YOUR QUESTION
    #{task["question"]}

    STARTING QUERIES
    #{queries}

    RULES
    - Run ONE web_search, two at most, with max_results 8. Do not keep rephrasing.
    - Open at most TWO pages with web_fetch — the two that look most likely to carry the
      answer. Opening a third is almost never worth the time it costs.
    - A search snippet may back a minor fact: rate that source 2 and say it came from a
      snippet. A page you actually opened rates 3-5.
    - Every number, date and version you report ends with the URL it came from. Never
      state one you did not read.
    - If you cannot settle something, say so in `open_questions` instead of guessing.
    - Answer only your question. Do not summarise the whole research.

    Report early rather than perfectly: partial and honest beats late. The moment you have
    something worth saying, call structured_output and stop.
    """
  end

  # Spec 48 §1: the deep worker's rules are the same rules — several searches, at
  # least `max_sources` pages, a URL on every fact — asked for in *batches*. A
  # measured worker (research #9004) spent 24 turns on 23 tool calls, one call per
  # turn, re-sending its whole history each time: 600 989 input tokens and 159 s for
  # 41 s of actual searching. `AgentServer` already runs every tool call of a turn
  # concurrently (`agent_server.ex:296`); nothing had ever asked for more than one.
  defp deep_worker(ctx, task, opts) do
    queries = task["queries"] |> List.wrap() |> Enum.map_join("\n", &("- " <> to_string(&1)))

    """
    You are one research agent in a deep research. Answer exactly one question.

    OVERALL RESEARCH QUESTION
    #{ctx.question}

    YOUR QUESTION
    #{task["question"]}

    STARTING QUERIES
    #{queries}
    #{partial_block(opts[:partial])}
    HOW TO WORK — IN BATCHES, NOT ONE CALL AT A TIME
    Every tool call you make in the same turn runs in parallel, and a turn costs far
    more than a call does. Never make one call and wait for it.
    1. FIRST TURN: issue ALL your starting queries at once — one web_search per query
       above, in this single turn, plus any obvious rephrasing of them.
    2. NEXT TURN: open EVERY page worth reading at once — at least #{ctx.max_sources}
       web_fetch calls in that one turn, picked from all of those results together.
    3. THEN, only for what is still open: one more batch of web_search calls, and one
       more batch of web_fetch calls on whatever they turn up.
    4. Finish with structured_output.
    Five calls in one turn cost about what one call costs. Spending a turn on a single
    call is the one thing that makes this slow.

    RULES
    - The queries above are a starting point, not a limit; rephrase and narrow when the
      first results are thin — but send each new set of queries as one batch.
    - Open at least #{ctx.max_sources} pages with web_fetch. A snippet is not a source.
    - Every fact you report ends with the URL it came from. Never state a number,
      date or version you did not read on a page you opened.
    - Rate every source 1-5: 5 is a primary or official source, 1 is hearsay.
    - If you cannot settle something, say so in `open_questions` instead of guessing.
    - Answer only your question. Do not summarise the whole research.

    Finish with structured_output.
    """
  end

  # Spec 40 §1.6: a retry starts from what the timed-out agent already had.
  defp partial_block(nil), do: ""

  defp partial_block(note) do
    urls = note["sources"] |> List.wrap() |> Enum.map_join("\n", &to_string(&1["url"]))

    """

    WHAT A PREVIOUS AGENT FOUND BEFORE IT TIMED OUT
    #{note["summary"]}
    Pages already opened:
    #{if urls == "", do: "(none)", else: urls}
    Start from these; do not re-open them unless a fact needs checking. You have
    the same clock — report early rather than perfectly.
    """
  end

  @doc "The reporter: write result.md from the notes and nothing else."
  def reporter(ctx, notes, sources) do
    if Levels.fast?(ctx.level),
      do: fast_reporter(ctx, notes, sources),
      else: deep_reporter(ctx, notes, sources)
  end

  # Spec 47 §2.5: no tools, so no `write_file` round trip and no chance of a
  # reporter that answers with a plan for writing the file. The reply *is* the
  # file; `Program.report/2` puts it on disk.
  defp fast_reporter(ctx, notes, sources) do
    numbered =
      sources
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {s, i} -> "[#{i}] #{s["title"]} — #{s["url"]}" end)

    """
    You are the reporter of a FAST deep research. Your reply is the finished document.

    RESEARCH QUESTION
    #{ctx.question}

    HOW THE QUESTION WAS READ
    #{ctx.interpretation || "(not recorded)"}

    NOTES FROM #{length(notes)} RESEARCH AGENTS
    #{if Enum.any?(notes, & &1["partial"]), do: "Notes marked PARTIAL came from agents that ran out of time or turns; cite them only for what they actually opened.\n", else: ""}
    #{render_notes(notes)}

    NUMBERED SOURCES — use these exact numbers for inline citations
    #{numbered}

    YOUR JOB
    You have NO TOOLS. Reply with the whole document as Markdown and nothing else — no
    preamble, no "here is the report", no code fence around it. Start at the `#` heading:

    # <a title for the report, not the raw question>

    > **Question** — #{one_line(ctx.question)}
    > **#{Levels.label(ctx.level)}** · #{ctx.steps_total} round · #{length(sources)} sources · #{Date.utc_today()}

    ## Answer
    ## Findings
    ## Open questions
    ## Sources

    RULES
    - `Answer` is 3-5 sentences: the short version, for someone who reads nothing else.
    - `Findings` is the substance, organised by theme rather than by agent, with inline
      `[n]` citations matching the numbered list above.
    - `Open questions` says what one round could not settle. If nothing is open, say so
      in one line.
    - `Sources` reproduces the numbered list, each with one clause on what it gave you.
    - Use ONLY the notes above. Never invent a URL, a number or a source.
    - Under 1 500 words. This is the fast level: a reader wants it now.
    """
  end

  defp deep_reporter(ctx, notes, sources) do
    numbered =
      sources
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {s, i} -> "[#{i}] #{s["title"]} — #{s["url"]}" end)

    """
    You are the reporter of a deep research. Write the final document.

    RESEARCH QUESTION
    #{ctx.question}

    HOW THE QUESTION WAS READ
    #{ctx.interpretation || "(not recorded)"}

    NOTES FROM #{length(notes)} RESEARCH AGENTS OVER #{ctx.steps_total} ROUND(S)
    #{if Enum.any?(notes, & &1["partial"]), do: "Notes marked PARTIAL came from agents that timed out; cite them only for what they actually opened.\n", else: ""}
    #{render_notes(notes, @reporter_notes_cap)}

    NUMBERED SOURCES — use these exact numbers for inline citations
    #{numbered}

    YOUR JOB
    Call write_file once with path `result.md` and this exact shape:

    # <a title for the report, not the raw question>

    > **Question** — #{one_line(ctx.question)}
    > **#{Levels.label(ctx.level)}** · #{ctx.steps_total} round(s) · #{length(sources)} sources · #{Date.utc_today()}

    ## Interpretation
    ## Answer
    ## Findings
    ## Disagreements and uncertainty
    ## Open questions
    ## Sources

    RULES
    - `Answer` is 3-5 sentences: the short version, for someone who reads nothing else.
    - `Findings` is the substance, organised by theme rather than by agent, with
      inline `[n]` citations matching the numbered list above.
    - `Disagreements and uncertainty` says where the sources conflict and which you
      trust more, and why. If everything agrees, say that in one line.
    - `Sources` reproduces the numbered list, each with one clause on what it gave you.
    - Use ONLY the notes above. Never invent a URL, a number or a source.
    - After write_file succeeds, reply with the `Answer` section's text and nothing else.
    """
  end

  @doc """
  The HTML reporter (spec 25 §2.1). It reads the finished `result.md` rather
  than the raw notes, so the two documents cannot disagree.
  """
  def html_reporter(_ctx, markdown, sources, attempt \\ 1) do
    # Spec 26 §5.3: 197 sources was 33 818 characters of prompt for a pass that
    # only needs the numbering to resolve the `[n]` markers, so the titles are
    # clipped and the tail is summarised rather than listed.
    numbered =
      sources
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {s, i} ->
        "[#{i}] #{String.slice(one_line(s["title"]), 0, 90)} — #{s["url"]}"
      end)
      |> String.slice(0, @sources_cap)

    """
    #{if attempt > 1, do: @html_retry_note, else: ""}Turn this finished research into a single-file HTML report.

    Follow the `html-report` skill in your instructions exactly: its six hard
    constraints, its component vocabulary, one palette and one font pairing.

    THE REPORT (result.md, already written and already correct)

    #{markdown}

    NUMBERED SOURCES — the `[n]` markers in the Markdown resolve to these
    #{numbered}

    YOUR JOB
    Call write_file exactly once with path `report.html` and the whole document.

    RULES
    - Say nothing the Markdown does not say. You are designing it, not rewriting
      it. No new numbers, no new claims, no invented sources.
    - Keep every `[n]` marker, as `<sup class="ref">[n]</sup>`.
    - Choose the palette from the subject matter, and hold one accent per entity
      for the whole document.
    - Between four and seven sections. The hero's stat-strip takes the three to
      five numbers a reader should remember.
    - End with a `verdict` block: the judgement in one sentence.
    - After write_file succeeds, reply with the palette and font pairing you
      chose and nothing else.
    """
  end

  defp one_line(text),
    do: text |> to_string() |> String.replace(~r/\s+/, " ") |> String.trim()
end
