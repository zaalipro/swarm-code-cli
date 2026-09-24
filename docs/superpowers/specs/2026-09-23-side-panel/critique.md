# Side agent panel: critique of A, B and C, the global rules, and the recipe for D

Reviewer: principal-design pass, 2026-09-23. Sources: `A.html`, `B.html`, `C.html` (read as text and as
the Menlo renders `A-look.png`, `B-look.png`, `C-look.png`), `owner-notes.md`, `current-*.png`, and the
CLI itself (`docs/keybindings.md`, `ui/theme.ex` `run_mark/1`, `ui/safe_text.ex`, `ui/capabilities.ex`).
Line references are to the mockup titles (`#### Full · swarm`, and so on) and the rows under them.

The owner liked v1. So this is not a rethink. It asks what has to change before any of these
can ship, and which parts from each direction belong in the final design.

---

## 0. Findings that apply to all three (fix these first)

1. **The approval keys are wrong in every direction.** The CLI already has an approval grammar
   (`docs/keybindings.md`, the Act table): `y`/`a` allow once, `Y` for this run, `A` always allow this
   command family, `d` deny, `D` deny and stop, `n` **next waiting item**. All three mockups print
   `n deny` (A `Full · swarm` band: "y allow    n deny"; B `Full terminal` approval card: "allow once
   always allow mix test deny"; C dock: "Ctrl-F then y allow  n deny  e open"). A and C also print `a`
   as "always" (A overlay: "a  always allow mix test here"; C overlay: "a  always allow mix test in this
   run"). In the real client, `a` means *once*. A user who follows the mockup would skip the request
   when they meant to deny it, or allow it once when they meant always. This is a safety bug, not a
   style issue.
2. **The "jump to what needs you" key already exists.** `Ctrl-N` opens the next approval or question
   waiting (composer, runs and panel contexts). All three directions add `Ctrl-F Ctrl-F` and never
   mention `Ctrl-N`. Keep `^F^F` as an alias, but label the needs-you surfaces with `^N`. It is one
   chord, it is documented, and it already goes through every run.
3. **The run glyphs ignore the catalogue.** `Theme.run_mark/1` defines chat `✳`, swarm `⋔`,
   consensus `⚖`, goal `◉`, workflow `⧉`, research `⌕`, and failed `✗`, each with an ASCII twin
   (`* S C * # /`, and `x`). The directions use:
   - A: `✦` chat, `»` workflow, `✧` research, `✳` consensus, `▪` plan
   - B: `✦` swarm, `✳` chat, `⋔` **consensus**, `✧` goal, `»` research, `▸` workflow
   - C: `⎇` workflow, `✧` for **both** goal and research, `⬢` consensus. C's header also uses `⬢`
     for the app.

   So B's `⋔` means consensus while the header tab strip uses `⋔` for swarm. All three use `✕` for
   failure, but the catalogue glyph is `✗`.
4. **The renders show missing-glyph boxes (tofu).** The PNGs are drawn with Menlo, the default font
   of Terminal.app, with no font fallback. Every braille sparkline in A (`A-look.png`: all the
   `⣀⣠⣤…` rows, the compact column, the "SWARM RATE" row) and every `⋔ ⬢ ⎇ ⚖`-class mark comes out
   as a box. Real terminals do fall back to other fonts, but the fallback font's advance width is not
   guaranteed. `capabilities.ex` already downgrades from `:rich` to `:measured` when ambiguous width
   is not narrow. Treat the renders as a warning: no design element should *depend* on braille. Any
   decorative mark needs an ASCII twin through `Support.glyph/2`.
5. **The metrics are dishonest.** The CLI does not know an ETA, a percentage of progress for one
   agent, how many plan steps are still to come, or a meaningful tokens-per-second figure (usage
   arrives per call, and "1.4k tok/s" for one model is not plausible). The mockups invent all of
   these; see section 5.
6. **The in-chat highlight is inconsistent.** A uses `▸` plus a background (`Compact · heavy`,
   "▸⋔ architecture review"). B uses `▎` plus the words "‹ in chat" (`Full · same heavy load`).
   C uses `▌` in compact and "▾ … in chat" in full. The owner asked for one clear highlight.
   B's form, a left bar plus the words "in chat", is the only one that still works in NO_COLOR.

---

## 1. Direction A: Mission control telemetry

### Usefulness
- **`Full · chat`** has about 25 rows, and most of them answer questions nobody asks mid-run:
  - "TOKEN RATE last 90s 1.4k tok/s" plus a 44-cell braille trace
  - "ELAPSED ▰▰▰▰▱…" (a gauge for elapsed time has no maximum, so the bar is meaningless)
  - "THIS CONVERSATION cost per turn ▂▃▅▂▇▃▆"
  - "turn 64%" in the header (turn progress cannot be known)

  The useful rows are "now editing the retry backoff", the TRACE ("✓ read 3 files ─── ✕ tests: 2 fail
  ─── ●") and PRODUCED ("lib/app/retry.ex +12 -3"). That is 3 of 12 blocks. "NEEDS YOU ✓ nothing
  waits on you" takes 2 rows to say nothing. When nothing waits, show nothing.
- **`Full · swarm` hive tiles.** Each tile answers who, state, elapsed, now, tokens and cost, which is
  good. The done tile shows the finding ("stream retries may / repeat a tool call"), which is the
  best "what was found" treatment at the tile scale. But each tile's inner width is 18 cells, so the
  sentences get cut ("mix test …/web", "reads RunServer"), and a quarter of each tile is border.
  With 4 agents, 10 rows of the panel go to boxes.
- **The needs-you band** (`Full · swarm`, "! NEEDS YOU web-ui-desktop wants to run / mix test
  test/swarm_code_web --only ui") is the best in the set. It is pinned on top, it shows the literal
  command, and it stays lit in hint mode. Keep it. Its key line, "y allow  n deny", is wrong (see §0.1)
  and would not work anyway: in the composer, letters always type.
- **Compact (`Compact · heavy load`)** is the most scannable table of the three. Every agent row has
  the same shape: state glyph, name, trace, word or two, time. "approve run" and "approve edit" in amber are
  excellent: they say the action, not a state. But:
  - the two-word "now" ("RunServer", "WAL flushes", "idempotency") has lost its verb, so it no
    longer reads as human words;
  - the braille column is noise;
  - the top pair of "! web-ui-desktop …" and "! rate-limits …" repeats the ! rows further down,
    so each item that needs you shows twice.
- **Folded runs in full (`Full · the same heavy load`)**: "⋔ api hardening ⬢⬢✓!" followed by a braille
  line and "2 live · rate-limits waits" is good. The orb string plus one sentence is the right grammar
  for a folded run. B does it better (see below).

### Beauty
- The colour discipline breaks. `A-look.png` has a different hue on almost every row: teal Lead bar,
  lane colours on the tile names, green done, amber needs you, orange accent on "▰▰" and "▴", blue
  and purple gauges, and a yellow-green agreement bar. The accent orange appears on the cost arrow
  "$0.19 ▴", the progress gauges and the badges, so accent no longer means anything.
- Uppercase section labels (TOKEN RATE, CONTEXT, BUDGET, ELAPSED, TRACE, PRODUCED, NEEDS YOU, THIS
  CONVERSATION) at 46 columns make the panel read like a form. The instrument-cluster idea turns
  into a spec sheet.
- The rounded tile borders are the one real piece of structure, and they are the costliest element.

### Terminal realism
- Braille is everywhere: channel traces, the compact trace column, the swarm rate, and the overlay
  activity heat strip. In the Menlo render it is all tofu. Even with fallback, a 2×4 dot trace at
  12 px is texture, not data.
- `▰▱` gauges are fine (Menlo has them). `▮` in "PRODUCED ▮▮▮▮▮▮▮▮" and "DOMAINS ▮▮▮▮" is the
  same message as the number next to it.
- **At 80×24:** `Full · swarm` needs 29 rows before the footer. On 24 rows the hive's second row and
  the footer are gone, and the done/needs-you tiles are exactly the bottom row, so they drop off.
  The most important information is at the bottom of the most expensive layout.
- NO_COLOR: tiles keep "● working", "! needs you" and "✓ done" as words, which is good. The gauges
  and traces lose everything.

### Data honesty
- Invented or fake-precision:
  - `Full · chat`: "turn 64%", "1.4k tok/s", "BUDGET $0.03/0.50" (only if a budget is configured),
    and the ELAPSED gauge
  - `Full · workflow`: "~3 min left" and the "retrying in 8s ▰▰▰▱" gauge (the countdown is real only
    if the Runner exposes a backoff deadline)
  - `Full · plan`: "drafting 5 of ~7", "6 …… 7 ……" and "est. +420 -60"
  - `Full · consensus`: the "no → yes" axis with cell-precise positions and "SPREAD 19 › 8 › 2 cells".
    Model stances are free text, and plotting them on a continuous axis invents a number.
  - "AGREEMENT 86%": fine only if the judge emits it
  - `Compact · heavy load`: "7.8k tok/s"
- Honest and good: the "✓ read 3 files ─── ✕ tests: 2 fail" trace (from operations), files
  changed/+/−, criteria met per iteration, the source funnel counts, and the domain counts.

### Keys
- "digits 1-9 on runs … Shift+letter shows the agent's lane in the chat". Shift+letter hints double
  the key surface for a feature nobody asked for. Drop it.
- "o shows every raw operation" in the overlay is good: raw operations stay one key away.
- "Tab cycles brief, activity and finding" treats Tab as a *page* switch. In a 160-column overlay all
  three are already visible, so Tab should move *focus*.
- The badge letters a s d f g include `a` and `d`, the approval keys. That is harmless in the hint
  context, but see rule K4.

### Overlay (`Agent overlay · web-ui-desktop-review`)
- This overlay answers "what did it find" best. "FINDING SO FAR 2 issues · 1 drafting" is numbered,
  has severity ("major", "minor") and has a file:line ("workspace_live.ex:2140"). Keep this.
- The ACTIVITY column does the grouping well ("✓ explored lib/swarm_code_web/components … 14 files ·
  6.2k lines", "6 searches · 23 hits in 9 files"). The per-kind braille heat strip above it
  (read/search/think/run) cannot be read.
- The TELEMETRY column is mostly things you do not need there: token rate, peak rate, and an
  "elapsed" gauge. It spends 42 columns on what fits in one header row.
- "FILES TOUCHED read, not changed · lines read" bars are a nice idea for a read-only reviewer.
  Keep them as numbers.
- The neighbour rail on row 2 ("engine-lifecycle ● · data-persistence ◐ · [ ‹ llm-tools-review ✓ done
  web-ui-desktop-review ! needs you Lead ● coordinating › ]") is too long and repeats the agent's own
  name.

### Consistency across the seven modes
Each mode gets its own gauge grammar, so no two look alike: phase rail in workflow and research,
beads in goal, steps in plan, a scatter plot in consensus. The channel block (▌name / trace / now /
meta) is the only constant, and plan and research do not have it.

**Verdict on A:** keep the needs-you band, the compact table's shape and the "approve run" wording,
the done tile's finding, and the overlay's numbered findings with file:line. Drop braille, the
tiles, the gauges without a maximum, and the invented numbers.

---

## 2. Direction B: Constellation

### Usefulness
- **`Full · swarm`** is the clearest "who, state, what now" of the three. Each agent is 3 rows:
  "├──● engine-lifecycle-review working", then "│ tracing how RunServer stops agents" (a full
  sentence with a verb, 36 cells), then "╰ ▰▰▰▰▰▱▱▱ 01:48 · 18k". The done agent's finding uses
  "» Fake provider never reaches the / refusal branch · 2 files cited". "2 files cited" is a small
  evidence count that makes the finding trustworthy.
- The needs-you line under the header is good ("◉ 1 needs you · web-ui-desktop-review ^F^F"), but it
  does not say *what* is being asked. You have to find the tree row ("wants to run mix test …/live")
  to learn it. A's band, which carries the literal command, is better.
- "team 1 done · 2 working · 1 needs you" is a useful one-second summary. "about 2 min left at this
  pace" is an invented ETA.
- The legend "● working ◐ thinking ✓ done ◉ needs you" on every screen spends a row to explain the
  glyphs. That is a sign the glyphs need words, and B already prints the words, so drop the legend.
- **`Compact · heavy load`** is the most beautiful compact of the three: 2 rows per run, the orb
  string ("⬢┬●◐✓◉"), and one sentence chosen by priority ("◉ web-ui wants to run a test",
  "◉ lead asks: rotate on every refresh?", "✕ store failed · retry 2 of 3 in 8s"). But it is not a
  panel *of agents*. You cannot tell which orb is engine and which is data, so "who is stuck" needs
  a hint key. It is excellent for runs that are *not* in view, and too lossy for the one that is.
- **`Full · same heavy load`**: the in-view tree plus "4 more runs, folded to their orbits" is the
  right structure. The paragraph "a folded run unfolds when the chat / scrolls to it … the needs-you
  line never folds" is designer commentary drawn inside the product. Delete it.
- **Workflow (`Full · workflow`)** is the best mode drawing across all directions. The pipeline
  "scan plan implement verify report / ✓──✓──●──○──○" has the parallel steps hanging from the live
  phase ("├─● api client", "├─✕›● store retry 2 of 3", "╰─✓ ui +40 -6"). You see the shape of the
  work and who failed without reading.
- **Plan (`Full · plan`)**: the step spine plus open questions, where "◉ … you" marks what is
  yours, and a gate box ("gate nothing runs until you / approve & execute revise") is clear and
  honest. There is no "~7".
- **Research (`Full · deep research`)**: the funnel "found 42 / read 18 / used 9" with indented,
  shrinking bars is the honest and legible form. "where it read ●●●●○○" with used/read dots is good.
  The quoted report excerpt ("The WAL grows without bound…") is delightful and useful.
- **Consensus (`Full · consensus`)**: positions as letters A/B/C with a one-line label, rails per
  model "opus A────A──╮", and "what moved gpt" quoted. This is the only consensus design where you
  learn *why* the models converged. Honest if the consensus runner labels positions (it has to,
  for the judge).

### Beauty
- It has the best hierarchy and whitespace. It is light and typographic, and the connectors carry
  the structure without boxes. In `B-look.png` colour is used on state words (orange "working",
  purple "thinking", green "done", amber chip "needs you") and lane colours on names.
- Problems:
  - there is too much air in `Full · chat`: 8 blank rows, and the "pulse" braille block
  - **orange for "working"** clashes with orange as the accent/assistant colour
  - two different amber treatments: the full-width fill bar at the top, and the chip on the row
- The glyph for the Lead (`⬢`) is tofu in Menlo. It is the same glyph the owner complained about:
  "hexagon glyph floats alone".

### Terminal realism
- The tree indentation costs 6 cells at depth 1 and 9 at depth 2 ("│   │  ╰ "). Nested spawns
  (workers spawning workers) run out of width at 46 columns by depth 3. Give a rule: never indent
  past depth 2, and show deeper agents as "↳ 2 more under data-persistence".
- The compact orb strings ("✓✓‹●✕✓›○○", "AAB›◌") are dense and clever, but `‹ ›` brackets for the
  parallel group are unreadable at a glance.
- **At 80×24:** `Full · swarm` fits in about 22 rows, the best of the three.
- NO_COLOR: fine, because every state has a word.

### Data honesty
- "▰▰▰▰▰▱▱▱" per agent in `Full · swarm`: there is no known maximum for a single agent's progress,
  so this is fake. B's workflow bar "58%" is honest only as phases done over phases total.
- The ETA ("about 2 min left at this pace").
- "passed · 1 flake in 20 runs" in chat parses test output. That is fine as the tool result's own
  summary line, and invented otherwise.

### Keys
- "Agents that need you get the first letters" is the best idea in hint mode. The first key you
  reach for is the one you need.
- "Up/Down and Enter fold and unfold activity groups" and "Left/Right and Enter answer the approval
  card" in the overlay invent a second approval grammar (a picker). Reuse the existing letters
  y a Y A d D n.
- In `Hint mode`, **the badge replaces the orb** ("g Lead", "s engine-lifecycle-review"), so in hint
  mode you lose the state glyph at the moment you are choosing whom to open. Put the badge *before*
  the glyph.
- The footer "a - g open 1 show run ^F needs you Esc" is good. It fits at 44 columns.

### Overlay (`Agent overlay · 160 × 30`)
- Header row 1 has the breadcrumb, state ("◉ waiting for your approval"), and the neighbour rail
  "[ ‹ llm-tools-review ✓   ⬢┬●◐✓◉   Lead ◌ › ]". That is compact and complete. Take this header.
- The **approval sits inline in the activity**, in time order ("◉ asks to run … now" followed by
  the card). This is truthful ("this is where it stopped"), but it is 30 rows down, below the fold on
  a 24-row terminal. It needs A's top band as well.
- "where it sits" is a mini tree with "‹ here". It is cheap and orients you. Keep it.
- "finding so far · 2 found · still looking" uses severity and file:line. It is as good as A's.
- "thought 41s · 'SideChat starts its summary task detached…'" shows the agent's reasoning quoted
  in one line. This is the best activity row in the set, because it shows *why* it did the next
  thing.

### Consistency across the seven modes
It is strong. Each mode is a shape, but the grammar is shared: orb + name + state word, an indented
sentence, and a meta line. The header is always "mark kind title time" plus a meta line.

**Verdict on B:** B is the skeleton for D. Take the full-mode tree, the workflow pipeline, the
plan/research/consensus drawings, the folded-run orbit line, needs-you-first hint letters, and the
overlay header. Drop the per-agent fake gauge, the ETA, the legend and the commentary text.

---

## 3. Direction C: Story river

### Usefulness
- **The lane is the one new, honest, per-agent visual in the whole set.** "▂ think ▅ tools
  █ write ▒ you" can be derived exactly from the operation rows the engine already persists: kind,
  start and end. It answers questions no other element does: *is this agent stalled?* (a flat ▂▂▂▂
  run: "data-persistence … ▂▂▂▂▂▂▂▂▂▂▂▂▂"), *is it blocked on me?* (▒▒▒▒), *did it write anything?*
  (█). This replaces A's braille rate and B's fake progress gauge. It is the one idea from C that D
  must have.
- **The shared absolute time axis** ("┬18:42 ┬18:43 ▾ now") and **the full-height "now" line** do not
  pay for their width at 46 columns. The now line is a column at cell 38 that runs through every
  row, including the sentence rows and the "right now" text in `Full · chat`, and it pushes a
  permanent 7-cell gutter to the right ("│ 02:14", "│ ⠹ 14k"). That leaves the sentences 36 cells
  and wraps them ("the stream parser drops the last / chunk on an early EOF"). Worse, an absolute
  axis compresses badly: in a 14-minute goal each cell is about 25 s, and a worker that started late
  is a sliver ("            ▂▂▅▅…", 12 cells of leading blank on every worker row in `Full · swarm`).
  Compact's **rolling "last 40 s"** window is the version that works.
- The **story brackets** ("└read┘ └ran┘ └edit┘ └testing───", overlay "└live views──┘ └read the
  workspace──┘ … └asks you────") under the lane are the best single-row answer to "what did this
  agent do". They belong in the **overlay** (160 columns), not in a 46-column panel.
- **Compact (`Compact · five runs at once`)**: one row per agent ("● ▅▅▂▅▅▅▅▅▂▅│ engine tracing
  stop cleanup") and 5 runs, 17 agents in 23 rows. This is the best density and still reads as
  words. Short names ("engine", "data", "llm", "web") come from a trimmed suffix and prefix, which is
  good. "✓ ▅▂████✓ │ llm ✦ parser drops a chunk" puts the finding in compact. That is excellent.
- The **needs-you dock at the bottom** is permanently 5 rows (`Full · swarm`, `Compact`), and it sits
  where the eye goes last. The `Full · plan` gate also takes the dock's slot, so a plan gate and an
  approval would fight over it. On 24 rows the dock pushes the fifth agent off.
- `Full · goal`: the per-iteration "judge ✕ ✕ · / met 2 3 4" rows under the lane are compact and
  honest.
- `Full · consensus`: braided strands ("A opus ─────┬──── A / B gpt-5 ───╯ moved to A") tell the
  convergence story in 3 rows, as well as B does, and "A B positions, not colours" is the right
  principle.

### Beauty
- `C-look.png` is the most *alive* of the three. Coloured lanes read like a timeline. But every row
  carries 3 or 4 hues (lane colour + state colour + orange now line + gutter colour), and the orange
  vertical line through the middle of the panel is the loudest element on screen while it
  communicates the least. Accent overuse.
- Rhythm: in `Full · swarm` each agent block has a different height (2, 3, 4 rows) because
  sentences wrap. That is ragged.

### Terminal realism
- `▂▅█▒` are block elements that Menlo covers. They render correctly in `C-look.png`, which is the
  only direction whose main visual survived the render.
- Braille spinners in the gutter ("⠹ 14k", "⠼ 11k") come out as tofu in Menlo, and animating them
  per agent means a redraw every tick for every row. Use one spinner per run header at most, or none.
- `├scan─┤├plan──┤` section rulers are fine.
- **At 80×24:** `Full · swarm` needs 29 rows, plus 5 for the dock.
- NO_COLOR: the lane heights still read, which is good. "▒" needs you still reads, and so does
  "needs you" as a word.

### Data honesty
- Lanes are honest (derived from operations). "1 cell · 0.7 s" in the overlay is honest.
- Invented:
  - `Full · chat` "12 of 31 passed so far" (stream parsing of test output)
  - overlay "PROGRESS ▰▰▰▰▰▰▱▱▱▱ about 60 %" and "2 of 3 findings drafted, the 3rd needs a test run"
    (no such structure exists)
  - `Full · research` "▪▪▪●●▪ sources over time" (fine if fetch ops are timestamped; they are)

### Keys
- It is the only direction that thought about letter collisions ("y, n and e are never agent
  letters"). But the actual approval grammar needs `y a Y A d D n` reserved, not `y n e`.
- "y or n answers the oldest need" in hint mode answers without showing you what you are
  approving, unless the dock is on screen. Only answer where the request text is visible.
- "y, a (always) and n answer an approval, but only while the composer is empty; otherwise they
  type" is the right guard, with the wrong letters.
- "Ctrl-F 2-5 unfolds a run" is good. The footer shows it.

### Overlay (`Agent overlay · 160 x 37`)
- It has the best *top*: its own lane with story brackets across 140 columns, "thought 41 s of
  1:37". In two rows you know what it did and where the time went.
- BRIEF, SCOPE and "THE SWARM · where this agent sits" are good. The ACTIVITY groups ("▾ read 14
  files 1:02" expanding to paths with line counts; "▸ thought 5 times 0:41 longest: whether UIState
  is the owner") are as good as B's.
- "FINDING SO FAR" ("✦ 1 Dialogs restore focus only on Esc high" + explanation + files) is the
  richest finding. "the Lead gets this when the agent finishes; you can see it now" is an honest
  and useful note.
- The dock plus the steer box at the bottom take 7 rows. The needs-you band belongs at the top.

### Consistency across the seven modes
The lane-plus-sentence unit is constant. The mode shapes are sections on the axis. The panel width
is spent on the axis and the gutter in every mode.

**Verdict on C:** take the activity lane (as a *rolling* 10–12 cell strip, not an absolute axis),
the compact one-row-per-agent grammar with short names and the finding in the row, the story
brackets and the lane for the overlay header, the consensus braid, and the "only when the composer
is empty" guard. Drop the full-height now line, the gutter column, the bottom dock and the braille
spinners.

---

## 4. Cross-cutting comparisons (one line each)

| Question | A | B | C | Best |
|---|---|---|---|---|
| Is "needs you" unmissable? | top band with the command | a count only, top | bottom dock | A's band |
| Is it actionable? | wrong keys | ^F^F only | wrong keys, hint y/n | ^N + the existing grammar |
| Who is stuck, in 1 s? | braille (unreadable) | no signal | flat lane ▂▂▂ | C's lane |
| Who is done, and what was found? | tile finding | "» finding · 2 files cited" | "✦ finding" in compact | B's line + C's compact |
| Compact under 5 runs | 1 row/agent, verbs lost | 2 rows/run, agents lost | 1 row/agent with a sentence | C |
| Folded runs in full | orb + braille + sentence | orbit line | braided lane | B |
| 80×24 full swarm | 29 rows | 22 rows | 34 rows | B |
| Overlay: did/found/needs | found ✓, needs ✓ top | did ✓ (thought quote) | did ✓✓ (brackets) | A+B+C |
| Honesty | worst | one fake gauge + ETA | one fake % | C |

---

## 5. Global rules every refined direction must follow

### Content (the owner's contract)
- **R1. Per agent, only these fields:** who (name), state (glyph + word), now (one sentence with a
  verb, ≤ 1 row in compact, ≤ 2 in full), elapsed, tokens · cost (one meta row, dim), produced
  (finding sentence, or `+N −M` / "N files"), and needs-you. No operation rows, no tool names as
  chips, no branch or worktree names (owner bug: "isolated in swarm/2404157a/…").
- **R2. Choosing the sentence:** needs-you request > failure + retry > finding (when done) > now.
  The sentence comes from the agent's own status line or latest thought. Never from an internal
  label.
- **R3. Exactly one needs-you surface in the panel:** a band pinned under the panel header. It is
  never folded or dimmed (it stays lit in hint mode), shows the *literal* request (the command, the
  file, or the question in full, wrapped to at most 3 rows), gives a count when there is more than
  one ("! 2 need you · oldest first"), and ends with `^N answer`. The agent row repeats it only as an
  amber state word ("needs you"), not as a second copy of the text. When nothing waits, the band is
  absent (0 rows).
- **R4. Highlight the in-chat run** with a left `▌` in the accent colour plus the words "in chat" on
  its header. No background fill. Same form in full, compact and narrow.

### Honesty
- **R5. Forbidden:** ETA or "min left", per-agent percentage, tokens/second, "~N" step totals, "est."
  diff sizes, stance axes, test pass counts parsed from streams, and progress gauges whose maximum is
  unknown. Gauges are allowed only for known ratios: phases done/total, iterations/limit, criteria
  met/total, reviewers reported/spawned, sources used/read/found, context used/window, and budget
  used/limit *when a limit is configured*.
- **R6.** Cost changes when a call's usage arrives, so it updates in steps. Show `$0.14`, with no `▴`
  "ticking" arrow. Tokens use `k` with no decimals under 100k (`18k`, not `18.4k`) in the panel. The
  overlay may show the exact figure.
- **R7.** The activity lane (C) is the only per-agent time visual. It is derived from persisted
  operation start/end and kind: think `▂`, tools `▅`, write `█`, waiting on you `▒`, idle ` `. It is
  a **rolling window**: panel full 12 cells, compact 8 cells, each cell = window/cells with the window
  fixed at 60 s. It is never an absolute axis in the panel. The overlay may show the whole life of
  the agent on an absolute axis.

### Glyphs and colour
- **R8. Run marks come from `Theme.run_mark/1` only:** ✳ chat, ⋔ swarm, ⚖ consensus, ◉ goal,
  ⧉ workflow, ⌕ research, and plan uses the mode chip. All go through `Support.glyph/2` with ASCII
  twins.
- **R9. One agent-state set for all seven modes:** `●` working, `◐` thinking, `◌` waiting on other
  agents, `!` needs you, `✓` done, `✗` failed, `○` queued, `⏸` paused → ASCII `* ~ . ! v x o =`.
  **Every state glyph is followed by its word in full mode.** `◉` is never a state (it is goal).
  `⬢` is never used (tofu, and the owner complained about it).
- **R10. Banned from the panel:** braille (tofu in Menlo, ambiguous width, unreadable) and per-row
  spinners. At most one spinner, on the in-chat run header, and it respects `reduced_motion?`.
- **R11. Colour budget per row: at most 2 hues plus grey.** Assign roles:
  - lane colours `l1…l5`: agent names only
  - `wa` amber: needs-you only (band, state word, `▒`)
  - `er`: failure only
  - `ok`: done glyph/word only
  - accent orange: the in-chat `▌` and hint badges (`.key`) only, never "working", gauges or cost
  - working and thinking: `tp`/`tm` text weight, not a hue
- **R12. NO_COLOR and ASCII:** every mockup must also be drawn once in mono. Meaning must survive
  through words, `!`, and lane heights.

### Geometry
- **R13. Panel content width 44 in a 46-column panel.** No right gutter column, and no full-height
  vertical rules. The meta goes on the agent's own row, right-aligned.
- **R14. Names:** strip the common suffix and prefix shared by siblings ("-review" → shown once in the
  group header: "4 reviewers · *-review"). Truncate in the middle only past 22 cells. Never cut a name
  while there is free space (owner bug).
- **R15. Height budget:** full = 2 rows per agent (name row with state word and meta, sentence row
  with the lane) + 1 blank row between groups. Compact = 1 row per agent. A folded run = 2 rows.
  A full swarm of 4 must fit in 16 rows so that 80×24 shows all of it.
- **R16. Tree depth:** indent at most 2 levels. Deeper agents collapse to "↳ 3 under data" and open
  in the overlay.
- **R17. Narrow (< 120 columns):** a one-row strip under the tab line: run mark + title, then each
  agent as `short-name glyph`, then a right-aligned "! 1 needs you ^N". Hints drop down as a sheet
  anchored to the strip.

### Keys
- **K1. Leader:** `Ctrl-F`, plus `Ctrl-Space` (NUL) where the terminal delivers it. Pressing the
  leader again in hint mode = `Ctrl-N` (the next needs-you), and the band says `^N`. Note that
  Ctrl-F takes Emacs forward-char from the composer; document it in the keymap table (`mix
  swarm_code.keymap`).
- **K2. Hint badges** are a 3-cell `.key` chip placed *before* the state glyph. The glyph stays.
  Agents that need you get letters first, then home row `s d f g h j k l`, then `w e r t u i o p`,
  then two-letter labels `sa sd …` when there are more than 16 agents. **Never badge `y a Y A d D n`
  or `q` / `?`**: `y a d n` are the approval keys, `?` is help, and `q` is reserved.
- **K3. Digits in hint mode = runs** in panel order (1–9). `0` opens the runs dashboard (same as
  `Ctrl-G`) when there are more than 9. Outside hint mode digits keep their meanings (question
  options, `Alt-1…4` tabs).
- **K4. Hint mode never answers approvals.** Answering happens only where the request is visible (the
  approval dialog, or the overlay's band) with the existing grammar `y`/`a` once, `Y` run, `A` always
  family, `d` deny, `D` deny and stop, `n` next, and only while the composer is empty (C's guard).
- **K5. Overlay keys:** Esc closes it and restores the chat scroll offset and the composer draft.
  `[` `]` go to the previous/next agent in panel order (wrapping, with the Lead first). Tab moves
  *focus* between band → activity → composer (not pages; pages only in the narrow stacked overlay).
  `Enter` on a group expands it. `o` shows all raw operations. Enter in the composer steers this agent
  only.
- **K6. Ctrl-B** cycles full → compact → hidden (it already toggles the dock; the new cycle replaces
  the toggle). `/panel full|compact|off` sets the mode, and the choice persists in UIState. Under 120
  columns, Ctrl-B cycles strip → off.

---

## 6. Recipe for direction D: "Constellation with a pulse"

### Idea in one sentence
B's typographic tree and mode shapes are the body. C's honest activity lane is the pulse on every
agent. A's pinned needs-you band and its numbered findings are the voice.

### D1. Panel header (1–2 rows), from A + B
Row 1: `▌⋔ architecture review · in chat        02:14` (the run mark from R8; `▌` + "in chat" from B
is R4). Row 2 (dim): `read-only · 4 reviewers · 55k · $0.14` (B's meta line). When there is more than
one run, a panel-wide row 0 reads `5 runs · 17 agents · 11 live · $1.82` (A/B).

### D2. Needs-you band, from A (content) and B (placement under the header), with honest keys
```
 ! NEEDS YOU · web-ui-desktop                  2
   mix test test/swarm_code_web --only ui
   read-only run, so commands ask       ^N answer
```
Amber `!` and title, the literal request in `tp`, a count on the right, and `^N` (K1). It is
absent when nothing waits. From A because it is the only one that carries the literal request. The
key is `^N` because it exists and it is safe.

### D3. Agent block (full: 2 rows), from B (sentence) + C (lane) + A (meta)
```
 ├ ● engine-lifecycle   working    1m12 · 18k
 │   ▂▅▅▅▂▅▅▅▅▂▅▅ tracing how RunServer stops agents
```
- Row 1: B's tree connector, the state glyph + word (R9), the name in its lane colour, and the meta
  right-aligned (A's elapsed · tokens; the cost moves to the overlay and the run header).
- Row 2: C's 12-cell rolling lane (R7) followed by B's human sentence. Where the sentence needs more
  than 30 cells it wraps onto a third row. This replaces A's braille trace and B's fake
  `▰▰▰▰▱▱` gauge.
- Done: `✓ llm-tools done 0:58 · 12k` / `✓` lane frozen + `» stream retries may repeat a tool call ·
  2 files cited` (B's finding line + evidence count; A's tile content).
- Failed: `✗ payment-retry failed · retry 2/3` / the lane + `tests failed: double charge on replay`.
  The words come from A's workflow channel.
- Needs you: the state word `needs you` in amber and a `▒▒▒` lane tail; the sentence is short
  ("wants to run a command") because the band carries the text (R3).
- The Lead goes first, at tree depth 0, with no hexagon. Its glyph is its state.

### D4. Mode shapes (full), from B except where noted
- **chat:** a single agent block + B's "produced" list + the context gauge (the only gauge). No
  pulse, no cost-per-turn.
- **swarm:** B's tree with D3 blocks, and the group header `4 reviewers · *-review` (A's suffix
  trim, R14). The footer row is B's "team 1 done · 2 working · 1 needs you" (no ETA).
- **workflow:** B's pipeline `scan plan implement verify report / ✓──✓──●──○──○` with parallel steps
  hanging from the live phase as D3 blocks. The retry countdown is shown only if the Runner exposes
  its deadline.
- **goal:** B's iteration orbs `✗──◐──●──○──○` + A's criteria checklist with "met in it N" + C's
  one-row "judge ✗ ✗ · / met 2 3 4" under the iteration rail + the last verdict quoted (all three).
- **plan:** B's step spine (no "~7"), open questions as amber rows that feed the needs-you band, and
  B's gate box. "touches 7 files · 1 migration" appears only once the plan states it.
- **research:** B's shrinking funnel (found / read / used) + B's "where it read ●●○" + A's report
  sections with state marks + B's one quoted line from the section being written.
- **consensus:** B's position legend (A/B/C + one line each) and per-model rails converging on
  the judge, with C's "moved B › A" annotation; "what moved gpt" quoted (B). Agreement is shown
  only as "2 of 3 on A". No percent unless the judge emits one. No stance axis (A).

### D5. Compact, from C (rows) + A (run header) + B (priority sentence)
```
▌⋔ architecture review        1/4 reported 2:14
  ◌ Lead    ▂··▂▅··· waiting on 3 of 4
  ● engine  ▅▅▂▅▅▅▅▂ tracing stop cleanup
  ◐ data    ▂▂▂▂▂▂▂▂ weighing flush safety
  ✓ llm     ▅▂███✓   » parser drops a chunk
  ! web     ▅▅▂▒▒▒▒▒ approve: mix test …/web
```
One row per agent: glyph, a short name (≤ 8 cells, R14), an 8-cell lane, and the sentence. The
needs-you row says the *action* ("approve: …", from A's "approve run"). The run header shows the
known ratio + elapsed (A). **Overflow rule:** when the rows exceed the panel height, the runs that
are not in chat fold to B's 2-row orbit line (`⧉ ship retry  ✓✓●✗✓○○ 04:12` / priority sentence per
R2), and a run with more than 6 agents collapses its done agents to `✓ 3 done: llm, cfg, ui`. The
needs-you band (D2) sits above everything, and compact keeps it at 2 rows maximum.

### D6. Full under load, from B
The in-chat run unfolds (D4). Every other run is B's orbit line + its priority sentence. `^F`+digit
unfolds one. No commentary text.

### D7. Hint mode, B's letter order + C's layout + A's lit band
The panel dims to `tf`. The badges (`.key` chips) sit before the glyphs, and the state glyphs stay
(fixing B). Needs-you agents get the first letters (B), and the band stays lit (A). The footer is:
` s-k open · 1-5 run · ^F again: needs you · Esc`. Letters follow K2, so there is no `a d y n`.

### D8. Agent overlay (full screen), assembled
- **Header row:** B's breadcrumb + state + neighbour rail `[ ‹ llm-tools ✓   ●◐✓!  Lead ◌ › ]`
  (shortened: prev, the run's orb string, next) + `Esc back to chat`.
- **Meta row:** B's `reviewer · read-only · deepseek-v4-pro · 1m20 · 21k · $0.05`.
- **Needs-you band** (only when something is pending): A's top band, full width, with the literal
  request and the real grammar
  `y once  Y this run  A always mix test  d deny  D deny + stop  · or type a reply`.
- **Story row:** C's whole-life lane on an absolute axis with story brackets (2 rows + a legend
  folded into the axis line: "thought 41 s of 1:37").
- **Three columns:**
  1. BRIEF (from Lead) + FINDING / RESULT: A's numbered findings with severity and `file:line`,
     plus C's "the Lead gets this when it finishes" note; for writers, the diff summary with
     `enter` opening the full diff.
  2. ACTIVITY, grouped: B/C groups (explored, read N files, searched N patterns with hits, thought ×N
     with **B's one-line quoted thought**), `Enter` expands, `o` shows raw operations (A). The
     approval also appears in time order at the bottom (B), linked to the band.
  3. A narrow column: B's "where it sits" mini tree + FILES TOUCHED as numbers (A) + tokens in/out,
     context used/window, and budget only if one is set. No rate, no peak, no elapsed gauge.
- **Composer:** "steer web-ui-desktop only ›" (all three agree). One row that grows.
- **Footer:** `Esc back · [ ] agents · Tab focus · o operations · Enter steer · ^F hints`.
- **Narrow (< 120 columns):** the columns stack as Tab pages (A/C), and the band and composer stay
  fixed.

### D9. Transcript, from C + B
One line per agent inside the Lead's block (fixing the owner's duplicate bug), with the same glyph,
state word and sentence as the panel. The approval card is inline under the agent that asks, and
the card also says `^N` and `^F <letter> opens the agent`.

### D10. Narrow strip, from A's strip with C's right tag
`⋔ architecture review 1/4 · Lead◌ engine● data◐ llm✓ web!        ! 1 needs you ^N`.

### Mockups D must add
The seven modes in full; compact with 5 runs and 17 agents; full under load; hint mode; the overlay
for a reviewer (read-only, needs you) *and* for a writer (done, with a diff); the 160-column
terminal; narrow at 100 columns; and **the same swarm on 80×24 and in NO_COLOR/ASCII**. D is not
done until the 80×24 and mono frames read correctly.
