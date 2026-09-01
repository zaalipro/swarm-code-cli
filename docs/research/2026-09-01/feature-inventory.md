# SwarmCode CLI/TUI feature-parity inventory

**Audit date:** 2026-09-01  
**Source repository:** `/Users/zaali/dev/swarm-code` (read-only)  
**Target discussed by the parent workflow:** a separate `swarm-code-cli` repository, installable on Ubuntu and macOS, with Elixir/OTP bundled

## 1. Scope, method, and truth hierarchy

This inventory is based on:

- every numbered file under `.specs/` (`01` through `52`, including the `43a/43b` and `51a/51b/51c` review documents);
- the product overview in `README.md`;
- the workflow product model in `grok_workflows.md`;
- the actual routes in `lib/swarm_code_web/router.ex`;
- the current schemas, contexts, engine/tool registries, and LiveView/component surfaces under `lib/`;
- focused nearby tests under `test/swarm_code/**` and `test/swarm_code_web/**`.

The numbered specs are chronological, not all simultaneously normative. Later specs deliberately replace earlier behavior. Important current-truth corrections are:

1. `.specs/19_reliability_security_performance_spec.md` is explicitly superseded by `.specs/20_pane_polish_and_hardening_spec.md` (spec 19, opening note).
2. The mode selector began with five modes in `.specs/38_mode_selector_spec.md §0`; `.specs/50_pass44_compact_commands_planner_spec.md §2.1` adds **Workflow**, making the current menu six modes.
3. Deep-research shapes in `.specs/24_deep_research_spec.md §1` were changed by `.specs/47_pass41_fastest_research_spec.md §§1–3` and `.specs/48_pass42_faster_deep_levels_spec.md §§1–5`. Current values come from `lib/swarm_code/research/levels.ex`.
4. Inline edit originally forked in `.specs/07_polish4_spec.md §17`; `.specs/52_pass46_edit_resend_in_place_spec.md §§1–3` supersedes that. Current edit-and-resend supersedes the old turn **in place**; explicit Fork remains a separate faithful fork.
5. `grok_workflows.md §“Control flow is deterministic, and resume is journaled”` says an interrupted process-restart run is terminal, but `.specs/09_workflows_spec.md` explicitly records the agreed deviation that interrupted workflow runs are resumable, and `test/swarm_code_web/live/resume_after_restart_test.exs` verifies it.
6. The original baseline's out-of-scope list (`.specs/01_swarm_code_spec.md §Out of Scope`) is no longer current: later specs added Git, MCP, images, worktrees, pausing/resuming, reasoning display, workflows, research, scheduling, and compacting.

`spec.md` and `priv/spec_master.md` are duplicate spec-writing instructions rather than end-user app functionality. `CHANGELOG.md` corroborates the implemented chronology. `.specs/sakana_findings.md` is a non-numbered review/fix log; it informs hardening but is not a distinct product surface.

## 2. Priority legend

The user asked for full parity. These labels are an implementation sequence, **not** a recommendation to omit anything:

- **MVP** — needed before the TUI is a credible SwarmCode coding client.
- **CORE** — explicitly requested or central to parity; should be in the first full-parity release after the MVP spine.
- **LATER** — real current functionality, but can follow the interactive coding/mode surfaces.
- **GUI-SPECIFIC** — the exact browser/desktop mechanism should not be cloned; preserve its intent with a terminal-native equivalent or deliberately omit it.

## 3. Executive inventory

The current product is much more than a chat screen. It is a local, persistent, asynchronous orchestration harness with six mutually exclusive composer modes, several non-mode slash operations, agent/process observability, deterministic workflows, standalone deep research, scheduled automation, and local project/Git/file tooling.

A faithful TUI needs four persistent concepts from day one:

1. **Conversation state** — projects, sessions, messages, modes, goals, model overrides, queue, attachments, compact floors, forks/superseded turns.
2. **Run state** — chat, swarm, workflow, research, and compact runs with lifecycle, totals, ownership, resumability, and parent/implementation links.
3. **Node state** — agent and operation trees, streamed deltas/reasoning, approvals/questions, prompts, outputs, costs, branches/worktrees, phases/groups.
4. **Background/global state** — MCP clients, scheduler, workflow journal, deep-research programs/reports, settings, storage cleanup, notifications.

The current route inventory confirms the large top-level surfaces (`lib/swarm_code_web/router.ex:30-43`): workspace/session, scheduled tasks, workflow runs/library/definitions, research index/detail, usage history, settings, attachment serving, and research HTML serving. Exact routes are:

- `/` and `/c/:id` — workspace/new or selected conversation;
- `/scheduled` — schedule calendar/agenda and task controls;
- `/workflows`, `/workflows/runs/:id`, `/workflows/library`, `/workflows/library/:scope/:name` — workflow runs and definitions;
- `/research`, `/research/:id` — research index and detail;
- `/history` — usage/cost history;
- `/settings` — all settings sections;
- `/attachments/:id` — safe stored-image response;
- `/research/:id/report.html` — open/download the self-contained HTML report.

## 4. Detailed parity matrix

### 4.1 Runtime, installation, local persistence, and lifecycle

| Priority | Capability to preserve in CLI/TUI | Current behavior and evidence | Terminal adaptation |
|---|---|---|---|
| MVP | Single local runtime with bundled Elixir/OTP | The app is Elixir/Phoenix/Ecto/SQLite and packaged as a release (`README.md §§Run, Build`; `mix.exs:24-29`; `.specs/01_swarm_code_spec.md Requirements 1, 13`). | Ship a self-contained Mix release per OS/arch. “Elixir bundled” should mean ERTS + Elixir stdlib included; clarify whether the compiler/Mix are also expected for user workflow scripts. |
| MVP | Local SQLite database and migrations | Packaged data currently goes under macOS Application Support (`config/runtime.exs:20-49`; `.specs/01… Requirement 13.2`). Startup recovery runs before work producers (`lib/swarm_code/bootstrap.ex`; `.specs/20… Requirements 6–7`; `.specs/33… §1`). | Use an OS-neutral data-dir abstraction (XDG on Linux, Application Support on macOS), migrate automatically, and add a single-instance/DB lock. |
| MVP | Structured concurrency and ownership | Runs belong to `RunSupervisor → RunSup → RunServer`, with owned agents/operations; workflows and research have their own supervised programs (`AGENTS.md §Runtime architecture`; `.specs/01… Requirements 5–6`; `.specs/09… §4`; `.specs/24… §3`; `.specs/51… §§2,4,5`). | Keep OTP ownership independent of the renderer. The TUI process must not be the run owner; terminal detach/reconnect must not kill work unless explicitly requested. |
| MVP | Crash/restart reconciliation | Running rows are settled/interrupted, stale scheduled claims reconciled, MCP restarted, stale attachments pruned, orphan research/design passes settled (`lib/swarm_code/bootstrap.ex:15-103`; `.specs/33… §§1–2`; `.specs/51… §4`). | Show a startup recovery summary and resumable/interrupted runs in the TUI. |
| CORE | Pause/continue/stop/resume semantics | Pause lets agents finish their current step and hold; continue releases them; stop is terminal; resume starts a continuity run for stopped/failed/interrupted chat/swarm, while workflow resume replays its journal (`.specs/45… §5`; `Chat.control_buttons` in `lib/swarm_code_web/components/chat.ex`; focused tests `pass39_pause_test.exs`, `pass39_resume_test.exs`, `resume_after_restart_test.exs`). | Provide consistent keys and commands on every run surface; do not overload “resume” and “continue.” |
| LATER | Graceful quit and background ownership | Desktop Quit detects chat/swarm/workflow/research/compact work, confirms, pauses workflows, stops others, flushes and tears down MCP/external processes (`.specs/27–29`; `.specs/35…`; `.specs/51… §§4.1–4.2`; `lib/swarm_code/quit.ex`). | Decide whether closing the TUI detaches from a daemon or terminates it. This is a foundational product question for scheduling/background work. |

### 4.2 TUI shell, navigation, and information architecture

| Priority | Capability | Current behavior and evidence | Terminal adaptation |
|---|---|---|---|
| MVP | Global navigation | Rail items are Chats, Scheduled, Workflows, Deep research, Usage, Settings (`lib/swarm_code_web/components/frame.ex:322-415`; routes above). | Persistent left nav or command palette; numbered tabs and global shortcuts. |
| MVP | Project/conversation sidebar | Search, pinned chats, project groups, projectless conversations, status/unread/waiting/queued markers, scheduled section, fold state, recent limits (`.specs/04… §Layout`; `.specs/08… §B`; `.specs/21… §§1–4`; `.specs/40… §3`; `.specs/44… §1`; `test/.../sidebar_live_test.exs`). | A virtualized list with filter and collapsible groups. Mouse support is optional; every action needs a key/menu path. |
| MVP | Main workspace split | Transcript plus Agents/Timeline/Changes pane; optional run side-chat is a third column; widths and pane visibility persist (`.specs/17… §3`; `.specs/16… §3`; `workspace_live/workspace.html.heex`). | Resizable terminal panes; responsive fallback to tabbed/stacked panes on narrow terminals. |
| CORE | Side chat / run-focused sub-session | One selected run opens a second split with kind-specific bodies: ordinary thread, goal board, swarm agent feed/filter, workflow phases, consensus ticker, inline interview, and its own composer (`.specs/16… §3`; `.specs/17… §2`; `.specs/34… §§2–3`; `.specs/41… §3.2/§3.4`; `lib/swarm_code_web/components/side_chat.ex`). | A focusable run detail pane or modal workspace; preserve reply/steer targeting and independent scroll. |
| CORE | Runs dock / “needs you” visibility | Live/unread/waiting run pills, selected-run focus, pending approvals/questions, and open-to-pane behavior (`.specs/15… §4`; `.specs/18… §1`; `.specs/34…`; tests `polish15_needs_you_test.exs`, `question_live_test.exs`). | Status line/dock with one-key jump to next run requiring input. |
| LATER | Persistent presentation preferences | Folded cards, open operations/prompts, timeline focus/zoom/scroll, sidebar folds/scroll, pane widths/density survive patches/remounts (`.specs/10… §18`; `.specs/12… §§4–10`; `.specs/40… §3.3`; `.specs/45… §8`; `SwarmCodeWeb.UIState`). | Persist layout/focus per conversation and terminal size; do not persist transient modal state. |
| GUI-SPECIFIC | Browser hover/minimap/tooltip/drag animation fidelity | Transcript minimap, hover cards, animated connectors, body tooltip layer, custom modal focus traps, drag shields, CSS themes/motion (`.specs/05–08`; `.specs/10… §§4–5,9,17`; `.specs/36… Part B`; `.specs/43b…`). | Preserve navigation outcomes (jump to turn, inspect relation, resize) with keys and simple terminal highlights; do not port browser hooks literally. |

### 4.3 Projects and workspaces

| Priority | Capability | Current behavior and evidence |
|---|---|---|
| MVP | Add/edit/delete/switch project directories | Validate existing absolute directory, unique root, editable name, per-project approval mode; deletion stops/cascades its conversations (`.specs/01… Requirement 2`; `lib/swarm_code/projects.ex`; `test/swarm_code/projects_test.exs`). |
| MVP | Projectless conversations | A hidden scratch project named “No project” provides a safe working root under the app config dir; these sessions have their own sidebar section (`.specs/21… §2`; `lib/swarm_code/projects.ex:22-66`; `test/.../polish16_no_project_test.exs`). |
| CORE | Move a conversation between project / no project | Composer-level project switcher; refuse while a run is live so an agent’s root cannot change underneath it (`.specs/21… §3`; `Conversations.set_project/2`). |
| CORE | Project instructions | First safe regular file among `AGENTS.md`, `SWARMCODE.md`, `CLAUDE.md`; editable; injected into every run, capped and path-confined (`.specs/03… §2`; `lib/swarm_code/engine/project_context.ex:49-97`; `test/.../memory_live_test.exs`). |
| CORE | Project metadata/actions | Current branch/path/conversation counts, rename, edit instructions, remove, create chat, project folding and status (`.specs/04… §Layout`; `.specs/44… §1`; `Frame.chat_panel`). |
| LATER | Native folder chooser and reveal | macOS desktop chooser/Finder behavior exists (`.specs/01… Requirement 2.2–2.3`; `.specs/31… Requirement 8.4`; `SwarmCode.Desktop.pick_folder/open_path`). This is GUI-specific; TUI should accept a path, shell completion, and optionally `$EDITOR`/`xdg-open`/`open`. |

### 4.4 Conversations, transcripts, history, and session operations

| Priority | Capability | Current behavior and evidence |
|---|---|---|
| MVP | Persistent conversations and ordered transcript | Titles, messages, runs, nodes, newest/seen state, token/cost, project binding; first prompt derives title (`.specs/01… Requirements 3–4`; schemas under `lib/swarm_code/conversations/`). |
| MVP | Chronological run-card transcript | User launch message and its run become one collapsible thread card; messages, standalone cards, workflow cards and follow-ups remain chronological; streaming answer lives in the card (`.specs/14… §§3–5,9`; `.specs/15… §§1–2`; `.specs/34… §1`; `Chat.transcript_items/3`). |
| CORE | Reply/steer targeting | Composer mark targets exactly one run/agent; ordinary message otherwise starts a new chat. A steer goes into the active run; an ask/follow-up starts a nested turn (`.specs/15… §3`; `.specs/17… §2.2–2.4`; `.specs/34… §3`; `workspace_live.ex:1693-1720`). |
| CORE | Sub-sessions and nested follow-ups | Root run + one-level follow-ups, dock folding, minimap exclusion, kind-specific contextual follow-up behavior (`.specs/17… §2`; tests `polish14_subsession_test.exs`, `polish12_threads_test.exs`). |
| CORE | Rename, pin, unread/seen, search | Header/sidebar inline rename, global pinned section, show fewer/all rules, live status and unread markers (`.specs/06… §10`; `.specs/08… §B`; `.specs/13… §§6–7`; `.specs/21… §§1,4`). |
| CORE | Explicit fork | Fork before a message/header; copies prior stable non-superseded transcript and model/consensus/effort/research settings; atomic and one `Fork:` prefix (`.specs/03… §10`; `.specs/52… §3`; `test/swarm_code/conversations_fork_test.exs`). It does **not** snapshot live run state. |
| CORE | Edit and resend in place | Editing a user message stops/supersedes only that turn and its run, clears its linked goal as abandoned, folds/dims it, excludes it from model history/pane/dock/resume, then redispatches the edited content through the same command/mode path. Other runs stay live (`.specs/52… §§1–2`; `conversations_supersede_test.exs`; `polish46_edit_resend_test.exs`). Assistant messages are not editable. |
| CORE | Queue and prompt history | Option/Alt+Enter queues text while chat work runs; chips can be removed and next starts automatically; Ctrl+R prompt history filters, navigates, and reinserts prior distinct prompts (`.specs/03… §12`; `test/.../queue_live_test.exs`; `WorkspaceLive.start_next_queued/1`). |
| LATER | Usage history page | 7/30/90-day views, rows by run with date/project/session/model/kind/tokens/cost, view-all, monthly headline/budget (`.specs/04… §History`; `history_live.*`; `history_live_test.exs`). |
| LATER | Session cleanup/pruning | See §4.17 below. |

### 4.5 Composer and command interaction

| Priority | Capability | Current behavior and evidence |
|---|---|---|
| MVP | Streaming multiline composer | Auto-grow/resizable, main and side heights, send/stop state, queued chips, notices, attachment thumbnails (`.specs/04… §Composer`; `.specs/22… §1`; `Chat.composer`). |
| MVP | Slash-command palette | Opens/filter-ranks on `/`, supports keyboard navigation, dynamic workflows and project/global commands, name precedence built-in > workflow > custom, command chip and command-specific placeholder (`.specs/04… §Composer`; `.specs/05–08`; `.specs/09… §5.2`; `Chat.@commands`, `Chat.commands/3`; `composer_live_test.exs`). |
| MVP | Model/effort/approval/mode controls | Composer exposes chat and swarm models, per-row efforts, approval mode, and one exclusive mode selector (`.specs/04… §Composer`; `.specs/37… §5`; `.specs/38… §§0–2`; `.specs/45… §§3–4`; `.specs/50… §2`). |
| CORE | Custom command chips in sent content | Known slash tokens render as inline neutral badges and titles/minimap excerpts strip or interpret them (`.specs/07… §14`; `.specs/08… §A`). |
| GUI-SPECIFIC | Exact chip/caret indent, popover hover bridges, browser keyboard hooks | Extensively specified in `.specs/05–08`, `.specs/22–23`, `.specs/42`, `.specs/44`, `.specs/46`, `.specs/50 §5`. | A TUI parser should retain the same command token semantics but use a terminal completion popup and caret-safe text editor widget. |

#### Current built-in slash commands

Source of truth: `lib/swarm_code_web/components/chat.ex:46-92`, dispatched in `lib/swarm_code_web/live/workspace_live.ex:5163-5299`.

| Priority | Command | Semantics |
|---|---|---|
| MVP | `/swarm <task>` | Starts a lead-run swarm. Empty task shows usage. |
| MVP | `/goal <text>` | Creates and immediately pursues a goal; bare `/goal` reports the newest open goal or usage. |
| MVP | `/plan` | Toggles Build ⇄ Plan, clearing other modes. |
| MVP | `/review` | Runs a fixed uncommitted-change review prompt. |
| MVP | `/effort <key>` | Changes this conversation’s chat effort; sends no message. |
| MVP | `/swarm_effort <key>` | Changes swarm-worker effort independently; sends no message. |
| CORE | `/rewind` | Opens checkpoint/turn restore selection. |
| MVP | `/stop` | Stops all running work in the conversation. |
| CORE | `/resume` | Resumes newest eligible stopped/failed/interrupted chat or swarm as a new continuity run. |
| CORE | `/compact [focus]` | Summarizes history into a compact floor without deleting transcript rows. |
| CORE | `/workflow …` | Launch/control/save a deterministic workflow. Unknown free text enters workflow authoring. |
| CORE | `/workflows` | Opens workflow dashboard. |
| CORE | `/create-workflow [description]` | Starts assistant-guided authoring/smoke-check/save/launch. |
| CORE | `/ultra [on|off]` | Toggles Ultra mode; substantive work is routed through workflow discovery/authoring/launch. |
| CORE | `/deep_research [id]` | Opens finished-research picker or attaches a specific finished research to the next turn. It does **not** start a research. |
| CORE | `/<saved-workflow> [args]` | Launches the saved workflow by name. |
| CORE | `/<custom-command> [args]` | Expands project/global Markdown prompt template; optional `swarm` and `mode` front matter determine launch. |

Potential parity ambiguity: there is no current slash command whose job is “start standalone deep research”; the web route’s hero starts it. A TUI needs a command such as `/research <question>` or a dedicated research screen, but that is a new CLI surface rather than literal parity.

### 4.6 Composer modes and run kinds

The current mode menu is six mutually exclusive entries (`lib/swarm_code_web/components/chat.ex:4784-4816`; `.specs/38… §0`, extended by `.specs/50… §2.1`):

| Priority | Mode | Current semantics |
|---|---|---|
| MVP | **Build** | Normal coding assistant: reads, writes and runs under project approvals. |
| MVP | **Plan** | Read-only tool set; lead may still fan out read-only exploration; produces a step-by-step plan. Finished plan has Approve / Revise / Decline. Approve chooses Assistant or Swarm implementation, switches to Build, links/nests the implementation and instructs it not to re-plan (`.specs/01… goal/plan feature changelog`; `.specs/38…`; `.specs/50… §§4,6,7`; `polish44b_plan_gate_test.exs`). |
| MVP | **Goal** | The **next message** creates a goal and exits other modes. Multiple independent goals can coexist; each is chat or swarm mode, active/paused/done/cleared, linked to its run (`.specs/07… §§15–16`; `.specs/10… §§7,16,19`; `.specs/38… §2.1`; `goals_live_test.exs`). |
| CORE | **Ultra** | For substantive multi-file/audit/research/review/migration work, assistant must list/reuse or author, smoke-check, save and immediately launch a workflow; trivial questions/one-line edits remain inline (`.specs/09… §5.8`; `lib/swarm_code/engine/prompts.ex:70-92`; `WorkflowPrompts`). This is distinct from Deep Research’s “Ultra” depth. |
| CORE | **Workflow** | The next ordinary message is treated as `/create-workflow …`; visible authoring flag cannot leak into later Plan/Build turns (`.specs/50… §§2,6`; `polish44a_command_mode_test.exs`). |
| CORE | **Consensus** | Normal assistant becomes planner; separate judge reviews plan and optionally changes, with configurable checks/rounds/models and user gate (`.specs/37…`; `.specs/45… §§4,6–7`; `.specs/51… §5.4–5.8`). |

**Swarm is a run kind/command, not a persistent mode.** **Compact** is a run kind/command. **Research** is a standalone object backed by a hidden conversation and research run. Run kinds accepted by the current schema are `chat`, `swarm`, `workflow`, `research`, `compact` (`lib/swarm_code/conversations/run.ex:16-79`).

### 4.7 Chat, goals, swarms, and asynchronous control

| Priority | Capability | Current behavior and evidence |
|---|---|---|
| MVP | Tool-using streamed chat | User/assistant rows persist immediately; text and reasoning stream independently; tool calls loop until final or max turns; exact token/cost totals (`.specs/01… Requirements 4, 5, 12, 14`; engine tests `chat_run_test.exs`, `context_test.exs`, provider tests). |
| MVP | Reasoning display | Provider reasoning/thinking can be separately disclosed; setting controls default visibility (`.specs/03 gap analysis reasoning`; `.specs/30… §§1–5`; `workspace_live_test.exs` reasoning cases; `settings.show_reasoning`). Provider continuation blocks remain wire-only where required. |
| MVP | Swarm orchestration | Lead decomposes, spawns nested agents in parallel up to per-run max, queues excess FIFO, integrates worktree branches, verifies and reports. Lead has no edit tools and must delegate. Sub-agents may recursively spawn until max depth (`.specs/01… Requirement 6`; `.specs/03… §1`; `.specs/10… §7`; `.specs/51… §§5.1–5.3`; `swarm_run_test.exs`, `worktree_test.exs`). |
| MVP | Agent-directed swarm from ordinary chat | Root assistant can call `start_swarm` when user asks for sub-agents/parallel work without typing `/swarm`; prevents duplicate live swarms in one conversation (`.specs/11… dynamic workflow vs swarm decisions`; `lib/swarm_code/tools/start_swarm.ex`). |
| CORE | Multiple goals | Goal bars stack; edit/pause/resume/clear act on one goal and steer its own linked run; goal mode remains chat or swarm; Ask vs Steer in side chat (`.specs/10… §19`; `.specs/17… §2.3`; `.specs/32… §5`; `goals_live_test.exs`). |
| CORE | Interview / structured user questions | Assistant and lead can ask 1–4 questions, 2–4 options, single/multi-select, custom answer, recommended-first, back/next/skip; run becomes waiting, answer persists in transcript and returns to the tool (`.specs/10… §1`; `.specs/18… §2`; `.specs/41… §3.4`; `ask_user_test.exs`, `question_live_test.exs`). |
| CORE | Per-op approvals | Read-only/Auto/Full Access; Auto allows writes but asks for execute, with Approve/Deny/Always; questions/approvals visibly mark “needs you” (`.specs/01… Requirement 8`; `lib/swarm_code/engine/policy.ex`; `approval_test.exs`). |
| CORE | Pause/continue/stop at run and agent subtree | One shared control vocabulary across transcript, side chat and pane; stopping one agent settles its spawn operation without killing the rest (`.specs/01… Requirements 6.7–6.8`; `.specs/45… §5`; `run_server_test.exs`). |
| CORE | Continuity resume | Resumed run records `resumed_from_run_id`, shows its origin and incorporates completed-op context/old branches; superseded runs are ineligible (`.specs/45… §5`; `.specs/51… §5.2/§5.7`; `.specs/52… §1`; `polish46_edit_resend_test.exs`). |
| LATER | AI short run labels and notifications | Swarm/goal labels generated from chat model, used across surfaces; notifications on finish/waiting/schedule, optional focus-on-finish (`.specs/10… §§13–14`; `.specs/43… §1.7`; `SwarmCode.Desktop.notify_*`). | TUI can use terminal bell/OSC notifications and always retain an in-app event log. |

### 4.8 Consensus mode

Consensus is a first-class requested feature and must not be reduced to “ask two agents.”

| Priority | Capability | Current contract and evidence |
|---|---|---|
| CORE | Planner, judge, optional implementer roles | Planner uses chat model; judge defaults to swarm but can be separately chosen; optional implementer has no fallback (“Planner implements” when unset). Every role has independent effort (`.specs/37… §§1–4`; `.specs/45… §4`; `polish39_consensus_popover_test.exs`). |
| CORE | 1–3 judged rounds | Planner calls `submit_plan`; judge returns structured APPROVED/REVISE plus findings/check results; planner disposes findings and resubmits until approval or cap. Later rounds see previous findings (`.specs/37… §§2–4`; `.specs/51… §§5.5–5.8`; `consensus_test.exs`, `pass38_consensus_rounds_test.exs`). |
| CORE | Configurable checks | Catalogue: avoid over-engineering; judge plan; judge changes; minimal changes; compare against codebase; scope guard; missing requirements/edge cases; risk/safety; verification; simpler alternative; decision completeness; ask before implementing (`lib/swarm_code/engine/consensus.ex:23-203`; `.specs/45… §4.3`). Seven defaults are tested. |
| CORE | Code-grounded judging | “Compare against codebase” gives judge read-only repo tools; otherwise judge has only structured verdict. Judge batches reads and has bounded turns (`.specs/37… §2/§3`; `.specs/51… §5.5`; `polish31_consensus_test.exs`). |
| CORE | User gate on every outcome | If gate is enabled, approval, rounds exhausted, judge crash, or stopped judge all wait for user; it does not time out into implementation. Choices are Implement / Plan only / Revise; a stopped/lost gate means Plan only (`.specs/51… §5.4`; `polish45a_consensus_gate_test.exs`). |
| CORE | Optional spec-driven implementer | Planner writes numbered Markdown under `.swarm_code/specs`, implementer executes tasks up to 120 turns, ticks boxes, reports; UI/TUI must show Spec and Implement stages and progress (`.specs/45… §6`; `write_spec.ex`; `pass39_write_spec_test.exs`). |
| CORE | Optional post-change judge | `judge_changes` reviews actual diff after implementation and can require fixes (`.specs/37… catalogue/engine`; `.specs/45… §6.4`). |
| CORE | Persisted observability | Transcript consensus card/docket, round plan/verdict/disposition/check marks/findings, side ticker, pane bench/ledger, round/stage folding and jumping, models/efforts/outcome (`.specs/40… §2`; `.specs/41… §3`; `.specs/44… §§4–5`; `.specs/45… §§6–7`; `.specs/46… §§4–6`). | In TUI use a rounds/stages tree with expandable Plan, Verdict, Disposition, Spec, Implement, Changes nodes. The visual “docket/ticker/scales” artwork itself is GUI-specific. |

### 4.9 Plan mode and compact

| Priority | Capability | Current behavior and evidence |
|---|---|---|
| MVP | Read-only Plan | Only read-only tools, with a read-only exploring lead allowed to spawn read-only children; root named Planner and persists run.mode (`.specs/01 feature pass`; `.specs/38…`; `.specs/50… §§4,6`; `polish44b_planner_test.exs`). |
| CORE | Plan approval gate | Finished plan: Approve opens Assistant/Swarm choice; Revise starts a nested Plan follow-up; Decline records without work; idempotent and visually linked (`.specs/50… §7`; `polish44b_plan_gate_test.exs`). |
| CORE | `/compact [focus]` | One-turn, tool-less Compactor on chat model; summary headings Goal, Decisions, Files touched, Open threads, User’s last request; under 800 words. A compact message becomes the newest history floor; older transcript stays visible. Second compact summarizes prior summary + since, keeping chain one deep. Not resumable and does not block chat (`.specs/50… §1`; `polish44a_compact_test.exs`; `Conversations.list_history_window/2`). |
| LATER | Automatic context meter/auto-compact | Explicitly out of scope in `.specs/50… §1.9`; do not invent as parity. |

### 4.10 Agent/run observability and TUI clone requirements

| Priority | Capability | Current behavior and evidence |
|---|---|---|
| MVP | Live run cards | Every run shows persona/glyph/name, status, elapsed, token/cost, progress, current activity, controls, nested operations and final output (`.specs/01… Requirement 5`; `.specs/14…`; `Chat.run_card`; `SwarmPane`). |
| MVP | Agent tree and queue | Recursive Lead/sub-agent tree, queued/running/done/failed/stopped/paused/waiting/approval/question states, connectors, collapsed/full detail (`.specs/06… §4`; `.specs/07–08`; `swarm_pane_test.exs`). |
| CORE | Tree/Grid and Full/Compact | Two layouts and two densities share open/collapse state; expand/collapse all; swarms remain inspectable (`.specs/07… §§7,12–13`; `.specs/08… §C`; `.specs/10… §§11,15,18`; `.specs/20… Requirements 3–5`). | A terminal can offer Tree and Flat/Grid-equivalent list; “Grid” may become multi-column when width permits. |
| CORE | Operation drawer | Aligned rows with tool/reasoning glyph, args, status, duration, tokens, output/error; last/current previews; independent Prompt drawer with S/M/L truncation (`.specs/22… §§2–5`; `SwarmPane.agent_card`). |
| CORE | Timeline | Persisted lanes/rows across runs; All or selected run; S/M/L zoom; All/Tools/Thinking/Errors filters; hover detail replaced by Inspector modal with Output/Input/Error/Prompt facts (`.specs/04… §Swarm pane`; `.specs/22… §6`; `.specs/45… §8`; `timeline_restart_test.exs`). |
| CORE | Changes view | Git status summary, tree, folders, diff, Markdown Preview/Edit/Diff, per-agent filters, branches, commit, merge/discard, Create PR (`.specs/03… §4`; `.specs/04… §Swarm pane`; `.specs/05… §12`; `.specs/08… §C`; `.specs/10… §§6,8`; `changes_live_test.exs`; `WorkspaceLive.Changes`). |
| CORE | File chips in transcript | Per-run changed paths, numstat, Open, inline diff, copy path, scoped Revert via checkpoint (`.specs/04… §Chat transcript`; `.specs/10… §6`; `changes_live_test.exs`, `rewind_live_test.exs`). |
| CORE | “Needs you” and live status vocabulary | One shared mapping for running/waiting/done/failed/stopped/idle; pending approvals/questions and workflow gates must be visible everywhere (`.specs/07… §§5–6`; `.specs/18… §1`; `.specs/43… §3.3`). |
| LATER | Transcript minimap and animated visual polish | `.specs/05–07`, `.specs/10 §5`, `.specs/42 §1`. | Replace with jump list/search/turn index; exact hover/animation is GUI-specific. |

### 4.11 Files, Git, checkpoints, worktrees, and commands

| Priority | Capability | Current behavior and evidence |
|---|---|---|
| MVP | File tools | `read_file`, `list_dir`, `grep`, `write_file`, `edit_file` with exact limits/errors/progress and final-path confinement (`.specs/01… Requirement 7`; tool modules; tests under `test/swarm_code/tools/`). |
| MVP | Shell tool | `/bin/sh -c`, project cwd, live detail, timeout, bounded head/tail, stdin `/dev/null`, kill subprocess tree (`.specs/01… Requirement 7.7`; `.specs/51… §§7.3,7.6`; `run_command_test.exs`). |
| MVP | Git read/write tools | `git_status`, `git_diff`, `git_log`, `git_commit`; UI commit and review prompt (`.specs/03… §4`; `lib/swarm_code/tools/git_tools.ex`; `git_tools_test.exs`). |
| CORE | Checkpoints and rewind | First write/edit per run/path snapshots previous content; restore one or rewind a run and later turns; huge files recorded non-restorable; atomic/scoped/idempotent and truthful partial failure (`.specs/03… §10`; `.specs/32… §2`; `.specs/51… §§1.3–1.4`; `checkpoints_test.exs`, `rewind_live_test.exs`). |
| CORE | Worktree isolation | Sub-agents may receive `.swarm_code/worktrees` Git worktrees/branches; integrate explicitly; cleanup on finish/stop; nested/resumed integration support (`.specs/03… §1`; `.specs/51… §§5.1–5.3`; `worktree_test.exs`, `integrate_agent.ex`). |
| CORE | Branch management / PR | Changes tab merges/discards only branches owned by current conversation/project; `gh pr create --fill` when CLI installed (`.specs/03… §4`; `.specs/32… §4`; `changes_live_test.exs`). |
| CORE | Custom slash commands | Markdown files under project `.swarm_code/commands` or global config; optional front matter `description`, `swarm`, `mode`; project overrides global; `$ARGUMENTS`; create/open directories (`.specs/03… §8`; `lib/swarm_code/commands.ex`; `commands_test.exs`). |
| CORE | Durable memory | Project `.swarm_code/MEMORY.md` plus global memory, injected into prompts; `remember` tool appends dated facts; editable/clearable settings surfaces (`.specs/03… §14`; `lib/swarm_code/memory.ex`; `memory_test.exs`, `memory_live_test.exs`). |
| CORE | Instruction/memory prompt scoping | Every run gets project instruction file plus project/global memory once; goals injected appropriately; no foreign conversation or research data (`.specs/20… Requirement 8`; `ProjectContext`; `context_test.exs`). |
| LATER | Skills | Built-in/project skill folders with `SKILL.md` and assets, scope precedence/cache; currently notably used by HTML report generation (`.specs/25… §1`; `lib/swarm_code/skills.ex`; `skills_test.exs`). There is not yet a general user-facing skill browser. |

### 4.12 Built-in tools and permissions

Current ordinary-agent registry (`lib/swarm_code/tools.ex:12-48`) includes:

- read: `read_file`, `list_dir`, `grep`, `web_search`, `web_fetch`, `git_status`, `git_diff`, `git_log`, `ask_user`, `submit_plan`;
- write: `write_file`, `edit_file`, `git_commit`, `remember`, `integrate_agent`, `write_spec`, workflow save;
- execute: `run_command`, non-read-only MCP, workflow run/control;
- orchestration: `spawn_agent`, `start_swarm`, workflow list/smoke/save/run/control;
- structured-output pseudo-tool for schema-constrained workers.

Role/mode restrictions are product behavior, not merely security implementation (`.specs/09… §§3.2–3.3,5.7`; `Tools.for_agent/5`, `Tools.for_worker/2`):

- root assistant gets workflow tools and `start_swarm`, except explicit `/swarm` or `/create-workflow` gating;
- lead gets `ask_user` and `spawn_agent`, but no direct write/edit;
- sub-agents do not get root workflow controls;
- workflow workers get capability-specific tools and never spawn/integrate/remember/workflow-control directly;
- plan mode filters to read-only, except lead keeps read-only delegation;
- consensus tools appear only on appropriate root consensus runs;
- MCP tools are global plus current-project scope, and read-only annotations govern Plan/read-only workers.

A TUI must display tool calls and permission prompts with exact scope, target, input, and timeout. The permission system cannot be replaced by a single global `--yes` flag.

### 4.13 Providers, models, reasoning effort, search, and attachments

| Priority | Capability | Current behavior and evidence |
|---|---|---|
| MVP | LLM providers | CRUD OpenAI-compatible and Anthropic endpoints, model list, default model, fetch-models, masked key, default seed from environment (`README.md §Configure`; `.specs/01… Requirement 9`; `Provider`, `Providers`, `settings_live_test.exs`). |
| MVP | Per-conversation model roles | Chat and swarm overrides; consensus planner/judge/implementer; workflow/scheduled/research defaults; research per-run override (`Settings.Setting`; `.specs/40… §1.0`; `.specs/45… §4`). |
| MVP | Streaming transports/retry/continuation | SSE, OpenAI tool deltas, Anthropic thinking/signature/redacted blocks, in-band errors, prompt caching, deadlines/retry-after/fail-fast, live provider key refresh (`.specs/30… §§1–5`; `.specs/31… Requirement 5`; `.specs/51… §6`; tests under `test/swarm_code/llm/`). |
| CORE | Configurable effort profiles | Provider- and model-level arbitrary effort keys, deep-merged request bodies/drop keys, presets for OpenAI, Anthropic, DeepSeek, DashScope/Qwen, vLLM/SGLang, Z.ai, Gemini, OpenRouter, xAI, Venice, MiniMax, or off (`.specs/45… §3`; `lib/swarm_code/llm/efforts.ex`; `efforts_test.exs`). All relevant pickers use the model’s actual list. |
| CORE | Search-provider chain | Tavily, Exa, Brave, Serper search; Jina/Firecrawl readers; enabled/order/fallback/test/latency; chat search is open web while research can apply recency/domain filters (`.specs/24… §4`; `.specs/39… §§1.4,2.1,2.7`; `lib/swarm_code/search.ex`; `search_test.exs`). |
| CORE | Image attachments | Paste/drop PNG/JPEG/GIF/WebP, four per message, 6 MB each, thumbnail/remove, image-only messages, OpenAI/Anthropic multimodal formatting, recent image context with byte/token ceilings, attachment route (`.specs/03… §7`; `.specs/32… §3`; `.specs/51… §6.5`; `attachments_test.exs`, `attachments_live_test.exs`). | Terminal needs an explicit path picker/`/attach`, clipboard/file-drop protocol, or both. Exact browser drag/drop is GUI-specific. |
| SECURITY NOTE | Secret storage | Current schemas still contain `providers.api_key`, search-provider keys, and MCP env/headers in SQLite (`Provider`, `SearchProvider`, `MCP.Server`). The large Keychain migration in spec 19 was superseded; `.specs/31… Out of Scope` explicitly did not implement it. Contributor rules now require Keychain/reference storage for new writes. | Do **not** blindly clone current plaintext persistence. Define macOS Keychain plus Linux Secret Service/keyring or a mode-0600 encrypted/file fallback. This needs a user decision. |

### 4.14 MCP

| Priority | Capability | Current behavior and evidence |
|---|---|---|
| CORE | MCP server CRUD | Stdio command/args/env or HTTP URL/headers, enabled toggle, global or project scope, add/edit/delete/test/reconnect, status and discovered tool list (`.specs/03… §3`; `.specs/22… §8`; `lib/swarm_code/mcp/server.ex`; `mcp_settings_test.exs`). |
| CORE | Namespaced dynamic tools | `mcp__<server-slug>__<tool>`, input schema/description/read-only annotation; global plus project servers injected into role/mode-specific tool lists (`lib/swarm_code/mcp.ex:134-219`; `Tools`). |
| CORE | Concurrent calls and reconnection | Stdio and HTTP JSON-RPC handshake/tools pagination, concurrent calls, absolute deadlines, request ownership/generation, one reconnect, caller-specific slow timeout, process-tree cleanup (`.specs/31… Requirement 4`; `.specs/33… §3`; `.specs/51… §7.8`; MCP client/http tests). |
| CORE | Credential redaction | Exact configured secret values plus generic Bearer/sk patterns redacted from errors/results/status/log/transcript (`.specs/33… §3`; `MCP.Server.secrets/1`; MCP HTTP tests). |

### 4.15 Deterministic workflows and Ultra

The workflow product distinction in `grok_workflows.md §§What a workflow is / What it is not` must be preserved:

- Chat is a conversational assistant.
- Swarm is a Lead improvising decomposition for one run.
- Custom command is a prompt template.
- Goal is a persistent objective.
- **Workflow is a named host-run deterministic program** whose agents judge but whose program controls flow.

| Priority | Capability | Current behavior and evidence |
|---|---|---|
| CORE | Definition scopes/discovery | Built-in `priv/workflows`, project `.swarm_code/workflows`, user config workflows; built-in > project > user; names/metadata/args/phases/budget/max-live/when-to-use (`.specs/09… §§1–2`; `grok_workflows.md`; `definition_test.exs`). |
| CORE | Elixir script language | Literal `meta`, then program using `phase`, `agent`, `panel`, `log`, `await_user`, `pause`, `complete`, `budget`, deterministic `host`, `write/read_report`, `integrate`, helper functions (`.specs/09… §§2–3`; current expanded reference in `lib/swarm_code/engine/workflow_prompts.ex`). |
| CORE | Parallel panels and budgets | Panel is the only concurrency primitive and a barrier; whole panel charged before launch; logical agent budget 1–1024, live cap 1–64, ordered results, failed slot nil, capability/isolation per worker (`.specs/09… §3`; runner/panel tests). |
| CORE | Structured output | JSON-schema subset, host validation/correction retry, atomize only declared keys, valid call terminates worker (`.specs/09… §3.2`; schema/runner tests). |
| CORE | Journal and deterministic resume | Frozen source/args; host calls/panel admission/results journaled by sequence/slot/fingerprint; replay reuses completed results and never double-charges; mismatch fails; interrupted runs resumable (`.specs/09… §§3.1,4`; `.specs/33… §2`; `.specs/51… §§5.10–5.13`). |
| CORE | Human gates and pauses | `await_user` returns answer after resume; pause kinds missing_input/blocked/infrastructure/no_progress/manual/budget; budget resume requires higher cap (`.specs/09… §3`; workflow pane/runner tests). |
| CORE | Launch/control paths | Dynamic named slash command; `/workflow run|pause|resume|stop|save`; launch args grammar `key=value`, flags, JSON/input; run again/carry, retry failed slots, answer gate, approve-all pending (`.specs/09… §5`; `.specs/11…`; `workflows/commands_test.exs`; `WorkflowsPanel`). |
| CORE | Assistant authoring | `/create-workflow` or unknown `/workflow <free text>` gathers intent (structured questions when needed), inspects project, authors, smoke-checks against real read-only host helpers/canned agents, saves and launches immediately (`grok_workflows.md §What /create-workflow does`; `.specs/11… §10`; `WorkflowPrompts`). |
| CORE | Ultra orchestration | Substantive task must reuse appropriate saved workflow or author/smoke/save/launch one immediately; result auto-continues assistant (`.specs/09… §5.8`; `Prompts.ultra`). |
| CORE | Workflow run observability | Phase rail, agents/cards/tiles, drawer, logs, approvals, gate/pause/result/error, progress, timeline phase lanes, transcript card/result (`.specs/09… §§6.1–6.3`; `.specs/11–13`; `workflow_pane_test.exs`). |
| CORE | Workflow dashboard/library | Runs filters; Pipeline/Script/Journal/Result; Save as; Library scopes/detail/shape preview/editor/check/run/duplicate/delete; arg launch form; rail project scope (`.specs/09… §§6.4–6.7`; `workflows_page_test.exs`). |
| CORE | Built-ins | `review-changes` (parallel lenses → adversarial verification → report) and `research` (sweep/read/synthesize) under `priv/workflows` (`.specs/09… §7`). Standalone Deep Research is a separate, richer feature. |
| LATER | Full-screen workflow source editor parity | Retain library/check/launch in first parity if possible; rich terminal editing can delegate to `$EDITOR` later. |
| SECURITY NOTE | Workflow evaluator | Model-authored Elixir executes in-VM. Current pass adds heap/CPU guard (`.specs/51… §7.7`) but it is not a general sandbox; `.specs/09` initially chose no sandbox. | Bundled Elixir makes this feasible, but the threat model and allowed APIs must be explicitly accepted. |

### 4.16 Standalone Deep Research

This is separate from the built-in `research` workflow and from Ultra mode.

| Priority | Capability | Current behavior and evidence |
|---|---|---|
| CORE | Asynchronous standalone research | Integer handle, question/title/interpretation/summary, hidden conversation, own supervised program/run, result directory `~/.swarmcode/research/<id>`, fire-and-forget and navigable away (`.specs/24… §§0,2–3,7`; `lib/swarm_code/research.ex`). |
| CORE | Four depth levels | Current: Fastest = 1 round × 4 workers; Medium = 2 × 3; High = 3 × 4; Ultra = 4 × 10. Each round also has a lead; non-Fastest may have headline; one reporter; optional designed-report agent after completion (`lib/swarm_code/research/levels.ex`; `.specs/47…`; `.specs/48…`). |
| CORE | Adaptive compound rounds | Round lead sees all prior notes, plans gaps, workers search/open sources and return structured notes; later rounds compound; final reporter sees all notes (`.specs/24… §§3,6`; `.specs/48… §§1,4`; server/round tests). |
| CORE | Current performance semantics | Fastest: one plan call without tools, four workers with small search/page/turn budget, no headline/designed pass on critical path, rendered HTML, bounded <5 minute worst-case. Deeper levels batch tool calls, run headline beside next round, close non-final round after 75% + straggler threshold while preserving late notes, max live default 10 (`.specs/47… §§2–5`; `.specs/48… §§1–6`). |
| CORE | Model configuration | Global lead/worker/reporter provider/model/effort tiers with swarm fallback, plus a per-research model override applied to every agent; retry-with-another-model (`.specs/24… §3.3/§5`; `.specs/40… §§1.0–1.3`). |
| CORE | Research controls | Start, stop, retry, retry-with model, pin, delete, reveal folder; failed/stopped research can retry as new id; restart marks standalone research failed rather than resuming (`.specs/39… §§1.2,3`; `.specs/40… §1`; `.specs/41… §1`; server tests). |
| CORE | Research index | Ask hero, level cards, estimates, project tag, model pill, status/search/level/project filtering, progress rows/cards, pinned ordering (`.specs/39… §3.1`; `.specs/40… §1.1`; `.specs/41… §§1,4.1`; research LiveView tests). |
| CORE | Research detail | Head/actions; stats Rounds/Agents/Sources/Tokens/Cost/Elapsed; round/report stepper; exact state line; report with TOC; rated sources; expandable rounds/tasks/notes; live agent rail/timeline and selection (`.specs/39… §3.2`; `.specs/41… §4.2–4.5`; `.specs/42… §§4–6`). |
| CORE | Reports | Reporter writes `result.md`; instant sanitized self-contained `report.html`; optional richer designed HTML pass after answer; Open/Download/Copy/Build/Rebuild; designed-pass state rendered/designing/designed/failed (`.specs/25… §2`; `.specs/26… §5`; `.specs/47… §2.6`; `.specs/48… §2`; report/controller tests). |
| CORE | Continue/attach in chat | “Continue in chat” opens a conversation with research preattached; `/deep_research` picker attaches finished report context without putting report text into the user message; sent chip links back (`.specs/25… §3`; `.specs/39… §§3.2.2,3.4`; attach tests). |
| CORE | Search settings | Engines/readers, max live/sources, recency, include/exclude domains, reader, agent timeout/retries, headlines, auto-designed report, model tiers (`.specs/24… §5`; `.specs/39… §2`; `Settings.Setting`). |
| GUI-SPECIFIC | HTML report browser viewer and visual rail | TUI should render Markdown, list sources, and offer `open`/`xdg-open` for HTML; exact HTML hero/scroll-spy/rail animation is not a terminal requirement. |

### 4.17 Scheduling and automation

| Priority | Capability | Current behavior and evidence |
|---|---|---|
| LATER | Scheduled task CRUD | Chat, swarm, or workflow; project; Build/Plan; per-task provider/model/effort; prompt or workflow name/args; color; enabled; catch-up (`.specs/04… §Scheduled tasks`; `.specs/08… §D`; `Scheduled.Task`). |
| LATER | Schedule kinds | Once, daily, weekly, monthly, 5-field cron; local timezone/DST-safe; monthly missing days skipped; cron names/ranges/steps; occurrence cap (`.specs/04…`; `scheduler/cron_test.exs`, `scheduler/next_test.exs`). |
| LATER | Reliable occurrences | Unique claim, one launch, staged conversation, settle/reschedule, catch-up <24h, opt-out/skip, boot reconciliation, paused/waiting workflow occurrence status (`.specs/31… Requirement 1`; `.specs/33… §1`; scheduler tests). |
| LATER | Calendar/day/task UI | Month navigation, selected-day occurrences, dots, filters, cards/run history, run-now/edit/pause/delete/export JSON, model chooser (`.specs/04… §Scheduled tasks`; `.specs/08… §D`; `scheduled_live_test.exs`). | TUI can provide agenda/month list plus form; exact 6×7 CSS calendar is GUI-specific. |
| LATER | Background requirement | Current scheduler works only while app runtime is alive. Desktop hides rather than exits. | For CLI parity, decide on daemon/service (`launchd`/systemd user) versus “schedules run only while `swarm-code` is running.” |

### 4.18 Usage, settings, storage, and administration

| Priority | Capability | Current behavior and evidence |
|---|---|---|
| MVP | Core settings | Provider/default models, per-role efforts, limits (agent count/depth/turns, command/tool timeout, worktrees), approvals per project (`Settings.Setting`; `.specs/01… Requirements 8–10`). |
| CORE | Appearance as semantic palette | Carbon, Obsidian, Graphite & Amber, Aurora; dark/light; reduce motion; card density/views (`.specs/04… design system/settings`; `Settings.themes`). | Map to terminal palettes and `NO_COLOR`; reduce-motion disables spinners/animated glyphs. |
| CORE | Full settings sections | General, Deep research, Appearance, Providers & models, Pricing, MCP, Memory, Storage, Commands, Limits, Budget (`lib/swarm_code_web/live/settings_live.ex:32-47`). |
| LATER | Pricing and cost | Per-model input/output $/1M; aggregate costs only when pricing exists; message/agent/run/operation display (`.specs/01… Requirement 12`; `Pricing`; History). |
| LATER | Monthly budget | Usage bar/headline/left and Settings value. It is informational; there is no hard spending cutoff (`.specs/04… §History`; history tests). |
| LATER | Storage measurement | DB/WAL/reclaimable/free disk and five kind buckets: sessions, agent details, rewind snapshots, workflow journals, research (`.specs/49… §§1.1–1.3,2`; `Storage.overview`). |
| LATER | Cleanup presets/session selection/advanced | Filter/sort/select sessions; age-based session deletion, payload prune, checkpoint/journal/research cleanup, empty sessions, Review, progress, skipped reasons, VACUUM; never touch open/running sessions and preserve pinned unless explicit (`.specs/49… §§1.4–1.7,3–4`; `storage_test.exs`). |
| LATER | Retention policy | Daily session deletion and agent-detail pruning; transcript/tokens/cost/timing retained on prune; no automatic VACUUM (`.specs/49… §2`; scheduler/storage tests). |
| CORE | Toasts/notices/errors | Every settings save and operation error has visible feedback; exact error messages often carry corrective setting path (`.specs/07… §§9–10`; `.specs/20… Requirement 15`). | Terminal event/toast line plus durable notifications pane/log. |

### 4.19 Security, correctness, and performance contracts that parity must carry

These are invisible until something goes wrong, but they are part of functionality:

1. **Scope confinement and atomic replacement** — untrusted path/revision/branch/attachment/checkpoint inputs must be revalidated at use; no atoms from runtime strings; writes use same-directory atomic replacement and clean temps (`.specs/19… Requirements 5–6` as audit context; normative implemented slices `.specs/20…`, `.specs/31… Requirements 2,4,6`; `.specs/32… §§1–5`; `AtomicFile`, `Tools.Path`).
2. **Output preservation with bounds** — large shell/Git/tool/web results bounded while reading, valid UTF-8, documented truncation markers; tool max output 100k; file size/window limits (`.specs/01… Requirement 7`; `.specs/51… §§6.7,7.1–7.5`).
3. **Linear streaming** — do not repeatedly concatenate/rescan; coalesced updates; reset failed retry contribution; final visible text/reasoning/tool args exact (`.specs/20… Requirements 9,13,16`; `.specs/30… §§4–5`; `.specs/43… §§1–4`; `.specs/51… §§2–3,6`).
4. **SQLite contention/atomic launches** — start turn graphs are transactional/retried; failure leaves inspectable terminal state and no orphan process (`.specs/31… Requirement 1`; `.specs/51… §1.2/§4.3`).
5. **Secret redaction** — exact configured keys and bearer values never enter logs, noncredential persistence, PubSub, transcript, or crash reports (`.specs/33… §3`; `.specs/51… §§6.9–6.10`).
6. **Owned external processes** — shell/MCP/Git tasks and timers have teardown; stop/quit reaps descendants (`.specs/31… Requirements 3–4,6`; `.specs/51… §§4,7`).
7. **No silent loss/spend** — queue/workflow budget/research failures, oversize image, storage pruning, truncated details all tell the user; terminal states remain inspectable (`.specs/20… Requirement 15`; `.specs/49…`; `.specs/51…`).
8. **Accessibility equivalents** — current GUI requires keyboard activation, ARIA, focus traps, reduced motion (`.specs/19… Requirement 10`; `.specs/20… Requirement 12`; `.specs/36… Part B`). A TUI must be fully keyboard operable, expose stable text to screen readers, and support `NO_COLOR`/nonanimated mode.

## 5. Proposed delivery classification by subsystem

This is a compact summary of the labels above.

### TUI MVP spine

- self-contained macOS/Linux release, installer/updater seam, SQLite migrations, bootstrap/recovery;
- project and projectless workspace selection;
- persistent conversation list/search/new/rename/delete, transcript and run cards;
- OpenAI-compatible + Anthropic setup, default/override chat/swarm models and efforts;
- Build and Plan modes, `/swarm`, `/goal`, `/plan`, `/review`, `/effort`, `/swarm_effort`, `/stop`;
- streaming text/reasoning, operation tree, token/cost accounting, stop and per-op approvals;
- file/list/grep/write/edit, shell, Git status/diff/log/commit, web search/fetch;
- swarm Lead/sub-agent concurrency, nesting, queue, depth and worktree integration;
- terminal-native slash palette, notices, “needs you” dock, run tree/detail pane;
- path/secret/process/atomic-write hardening from the start.

### Full core parity immediately after the spine

- multiple goals, Ask/Steer side flow, structured interviews;
- pause/continue/resume and continuity links;
- reply/steer sub-sessions, side chat, explicit forks, edit/resend supersession;
- checkpoints/rewind, changes viewer, branches/merge/discard/PR, per-agent changes;
- image attachments;
- custom commands, AGENTS/SWARMCODE/CLAUDE instructions and project/global memory;
- MCP stdio + HTTP with scoping/redaction/reconnect;
- Consensus in full: checks, rounds, gate, optional implementer, Spec/Implement/Changes stages;
- finished-plan Approve/Revise/Decline and Assistant/Swarm execution;
- `/compact` history floor;
- workflows: authoring, library, run dashboard, panels, structured output, journal/replay, controls, reports, built-ins;
- Ultra mode over workflows;
- standalone Deep Research, reports/sources/rounds/models/search engines, attach-to-chat;
- Agents Tree/Flat, Full/Compact, operation/prompt drawers, Timeline Inspector, Changes;
- all relevant settings and terminal themes.

### Later parity

- scheduled automation plus daemon/service integration;
- usage history, pricing and budget screen;
- storage overview/cleanup/retention/VACUUM;
- rich `$EDITOR` integration for workflow definitions/commands/memory;
- terminal/system notifications, desktop opener conveniences;
- designed HTML report refinements and browser opening;
- exact persistence of every minor UI fold/zoom/scroll preference.

### Inherently GUI-specific; adapt rather than clone

- wx native window, webview auth, macOS menu bar, Dock reopen, tray menu, hide-on-close, Space-activation workaround;
- native folder picker and Finder reveal;
- CSS pixel sizes, hover-only controls, hover tooltips, animated SVG connectors, minimap tick geometry, popover bridge timers;
- modal backdrop blur, browser focus trapping/ARIA markup, morphdom-specific preservation hooks;
- drag/drop and clipboard-image plumbing as implemented in JavaScript;
- 6×7 graphical calendar and HTML designed-report viewport.

The **intent** behind many of these still matters: discoverability, keyboard access, jumping between turns/agents, visible background work, safe quit/detach, and responsive narrow layouts.

## 6. Ambiguities and questions for the user/parent workflow

These should be resolved before a final architecture plan; they materially affect the repo shape and install contract.

1. **Process lifetime:** When the TUI exits, should work keep running in a background daemon, or should all work stop? Scheduling and desktop hide-on-close parity strongly imply a daemon, but the request did not explicitly say so.
2. **Single-command install:** Is the desired command `curl … | sh`, Homebrew, a GitHub release installer, or all three? Ubuntu CPU/libc targets (x86_64 only vs arm64; glibc baseline) are unspecified.
3. **“Elixir bundled”:** Is a standard self-contained OTP release sufficient, or must `elixir`, `iex`, and `mix` executables be exposed? Workflow evaluation needs Elixir modules but not necessarily Mix.
4. **Source sharing/reuse:** May the new CLI copy/reuse core modules from SwarmCode under the current license, or must it reimplement them? No license file was visible in the root audit; this must be checked before code transfer.
5. **Database compatibility:** Should CLI and desktop open the same SQLite database/config folders, import them once, or be completely separate? Concurrent use of one DB is unsafe without an explicit single-instance/ownership protocol.
6. **Secrets on Linux:** macOS Keychain has an obvious adapter; should Ubuntu use Secret Service/libsecret, `pass`, an encrypted local vault, or a mode-0600 config fallback?
7. **TUI library:** The user left it open. Required inputs include image support, mouse, wide-character correctness, popup layers, virtualized logs, resize, terminal restore on crash, and testability. This deserves an explicit proof-of-concept before choosing.
8. **Deep-research launch UX:** Current `/deep_research` attaches finished research; it does not start one. Should the CLI add `/research <question>` / `/research --level ultra`, or rely on a Research screen?
9. **“Ultra” naming:** There are two Ultras: composer Ultra (workflow orchestration) and Deep Research Ultra (4×10 workers). TUI labels/help must distinguish them.
10. **Scheduling:** If a daemon is accepted, should installer register a systemd user unit and launchd agent automatically? What happens on laptops/offline/locked keyring?
11. **Notifications:** Terminal bell/OSC, native notifications, both, or only an internal inbox? Native notifications introduce OS-specific code but mirror current waiting/finish/schedule behavior.
12. **Attachments:** Required interaction on ordinary terminals: `/attach path`, file picker, clipboard protocols (Kitty/iTerm), or all? Inline image preview cannot be universal.
13. **Workflow trust:** Is in-VM evaluation of model-authored Elixir acceptable in the CLI, matching current behavior, or should the new product sandbox/out-of-process it even if that is a deliberate behavioral change?
14. **Remote/headless use:** Current product is loopback/local/single-user. Should SSH/headless TUI be supported? That changes open-browser, keyring, clipboard, notifications, and daemon design.
15. **Update mechanism:** “Single-command installable” does not say whether self-update, uninstall, version pinning, or signed artifacts are required.
16. **Parity cutoff:** Does “all functionality” include Storage cleanup, scheduling, HTML design, native notifications, and usage budgets in v1, or is the MVP/Core/Later sequence acceptable?
17. **Current security mismatch:** Contributor rules demand secret references/Keychain, but current schemas still store plaintext. Should the CLI implement the stricter rule from launch (strongly safer) even though that prevents byte-for-byte database compatibility?
18. **Current macOS-centric paths:** Research uses `~/.swarmcode/research`, while main DB/config uses `~/Library/Application Support/SwarmCode`. Choose a cross-platform directory contract and migration/import story.

## 7. Numbered-spec audit ledger

This ledger demonstrates coverage of every numbered `.specs` document and identifies its parity contribution.

| Spec | Primary parity contribution / current status |
|---|---|
| `.specs/01_swarm_code_spec.md` | Baseline desktop shell, projects, conversations, streamed chat, operation tree, swarm, tools, approvals, providers/models, settings, layout, usage/cost, packaging, error handling (Requirements 1–14). Later specs expand its former out-of-scope list. |
| `.specs/02_gap_analysis_vs_claude_code_codex.md` | Prioritized missing features that drove worktrees, instructions, MCP, Git, images, commands, checkpoints, queue/background, memory. Historical rationale, not a separate surface. |
| `.specs/03_gaps_spec.md` | Tool refs/MCP, worktrees, AGENTS context, Git/PR/review, images, custom commands, checkpoints/rewind/fork, queue/history/edit, background/resume, memory (§§A–C, 1–14). |
| `.specs/04_redesign_spec.md` | Carbon design shell, rail/sidebar, composer/model chooser/effort, Agents/Timeline/Changes, transcript file chips, modals, scheduled tasks, usage history, settings. Semantic IA transfers; exact CSS is GUI-specific. |
| `.specs/05_polish_spec.md` | Pane sizing, select/date/time widgets, transcript follow, composer overflow, approval selector, slash-palette persistence, diff preview/edit, rename. Mostly terminal interaction polish. |
| `.specs/06_polish3_spec.md` | Sidebar/model sizing, tree connectors, live progress cards, per-model efforts, inline rename, thinking-op rendering. |
| `.specs/07_polish4_spec.md` | Efforts, minimap, unified statuses, sidebar running state, Tree/Full toggle, footer actions, toasts/timeouts, grid, command badges, goal, old edit behavior. Edit behavior superseded by spec 52. |
| `.specs/08_polish5_spec.md` | Searchable model flyout, goal+swarm command composition, queue/palette keys, unread/scheduled sidebar, density/connectors/Changes diff, scheduled per-task model/timezone correctness, confirm modal. |
| `.specs/09_workflows_spec.md` | Complete deterministic workflow storage/language/API/journal/engine/launch/dashboard/library/built-ins contract (§§1–8). |
| `.specs/10_polish6_spec.md` | Swarm-goal correctness and mandatory delegation, interview tool, user bubbles/file rows, agent Changes, run labels, notifications, expand/collapse, multiple goals (§§1–19). |
| `.specs/11_polish7_spec.md` | Prompt-driven workflow authoring/robustness, workflows page, sidebar/timeline/thin assistant rows, Markdown tables, global quit. |
| `.specs/12_polish8_spec.md` | Swarm vs workflow routing, workflow resume after close, durable timeline, pane folding, workflow progress/open behavior, lag/overflow corrections. |
| `.specs/13_polish9_spec.md` | Run-row/card toggling, goal placement, Lead naming, sticky sidebar visibility, workflow Tree/Grid, correctness review fixes. |
| `.specs/14_polish10_spec.md` | Collapse-all, composer/live update stability, chronological transcript, unified goal/card box, folded Lead row, useful timeline jump, in-card Open. |
| `.specs/15_chat_threads_spec.md` | Thread items/seen marker, one card per run, Reply/Steer marks, Runs dock, enforced `/create-workflow` vs `/swarm`. |
| `.specs/16_side_chat_spec.md` | Kind colors, second split run-focused side chat, kind-specific bodies, side composer/live updates, user-message/run panel. |
| `.specs/17_sub_sessions_spec.md` | Progress bars, nested follow-up sub-sessions, no swallowed sends, goal Ask/Steer, message/run pairing, per-run rename, independent resize. |
| `.specs/18_pane_polish_spec.md` | “Needs you” detection, in-run interview answers, single run header/Lead card, robust narrow pane/hover association. |
| `.specs/19_reliability_security_performance_spec.md` | Large proposed reliability/security/performance program; explicitly superseded by spec 20. Useful audit context only. |
| `.specs/20_pane_polish_and_hardening_spec.md` | Normative proportional hardening: visible waiting runs, in-run answers, one header, responsive Lead, boot/owner correctness, context scope, bounded/linear streaming, accessible/fast UI, no silent loss/spend (Requirements 1–16). |
| `.specs/21_no_project_conversations_spec.md` | Short sidebar, projectless scratch sessions, composer project switcher, pinned sessions (§§1–4). |
| `.specs/22_composer_cards_and_prompt_spec.md` | Resizable visible composers, long-prompt clamps, operation layout, Prompt drawer, Timeline S/M/L + All, independent side scroll, MCP proxy compatibility. |
| `.specs/23_chat_polish_spec.md` | Command-chip placeholder, no duplicate follow-up, one status word, Workflow author persona, proxy-cleaned tool names. |
| `.specs/24_deep_research_spec.md` | Standalone research engine, storage/process tree, search providers, settings, prompts, routes/pages. Level/performance details later superseded. |
| `.specs/25_research_reports_spec.md` | Skills, designed self-contained HTML report, serving/download, `/deep_research` attachment/picker/context. |
| `.specs/26_research_rounds_spec.md` | Ultra/depth labeling, round progress/cost/headlines/disclosures, result/report reachability. |
| `.specs/27_quit_means_quit_spec.md` | Disable Erlang heart relaunch and define actual quit semantics. Desktop-specific intent: never resurrect after explicit quit. |
| `.specs/28_quit_from_the_tray_spec.md` | Functional menubar/tray host-driven quit and phantom-work detection. GUI-specific surface. |
| `.specs/29_dock_quit_spec.md` | Reconstruct macOS Dock quit and quantify listener cost. GUI-specific. |
| `.specs/30_provider_wire_and_dead_ends_spec.md` | Anthropic continuation blocks, 200-stream errors, linear assembly/reasoning separators, functional notification/folder buttons. Transport behavior is core. |
| `.specs/31_surgical_correctness_and_efficiency_spec.md` | Atomic launch settlement, scoped mutations, workflow teardown/replay, MCP generations, provider continuation, owned background jobs, linear hot paths, small UI blockers (Requirements 1–8). |
| `.specs/32_scope_and_atomic_writes_spec.md` | Atomic file primitive; conversation-scoped checkpoints; id-derived attachments; project/conversation-owned branches; goal-owned steering (§§1–5). |
| `.specs/33_recovery_replay_and_secrets_spec.md` | Scheduled-claim recovery, lost workflow Runner/panel replay, MCP exact-secret redaction, coalesced run events/demand tick. |
| `.specs/34_watching_a_run_work_spec.md` | Live streamed run content in transcript/side chat and reliable side-chat sends. |
| `.specs/35_quit_means_quit_and_what_it_costs_spec.md` | Prevent self-start/relaunch, measure runtime cost, durable file logs/quit trace. Mostly lifecycle/desktop. |
| `.specs/36_bug_sweep_spec.md` | Crash/stop cleanup, event dedupe, MCP reconnect, atomic fork, research rebuild, XSS sanitization, hook/focus/clock hygiene and stale-code removal. |
| `.specs/37_consensus_spec.md` | Consensus data/catalogue, `submit_plan`, planner/judge engine, settings and initial UI (§§0–7). |
| `.specs/38_mode_selector_spec.md` | Exclusive one-mode model and selector; Build/Plan/Goal/Ultra/Consensus, command/mode normalization. Extended to Workflow by spec 50. |
| `.specs/39_research_redesign_spec.md` | Research engine/search fixes, unified settings, rich index/detail/rail/picker with stats/report/sources/round notes (§§1–3). |
| `.specs/40_consensus_cards_and_research_ops_spec.md` | Per-research model/retry/progress/timeouts, consensus card/bench/layout, sidebar state, global quit, real RAM metric. |
| `.specs/41_pass35_consensus_research_design_spec.md` | Pinned research rows, consensus Docket/Ticker/Scales and inline interview, research Rail/timeline. Exact visual metaphors are GUI-specific; data is core. |
| `.specs/42_pass36_composer_hint_rail_follow_spec.md` | Composer hint, consensus naming/status, research scroll-spy/agent targets/facts, sources-before-report. |
| `.specs/43_pass37_lean_runtime_spec.md` | Lower-memory engine/LiveView/browser behavior, demand ticks, shared status/a11y, hook/CSS cleanup. Renderer-specific parts should inform TUI efficiency. |
| `.specs/43a_pass37_review_runtime.md` | Read-only runtime architecture/RAM/CPU/process/bug review feeding spec 43. No new end-user surface. |
| `.specs/43b_pass37_review_web.md` | Read-only LiveView/component/hook/CSS performance and accessibility audit feeding spec 43. No new semantic surface. |
| `.specs/44_pass38_sidebar_menu_consensus_ledger_spec.md` | Project action menu, composer caret/model name, unified consensus name, rounds ledger, one composer strip. |
| `.specs/45_pass39_efforts_implementer_pause_timeline_spec.md` | Arbitrary effort profiles/presets, planner/judge/implementer, pause/continue/resume, consensus spec implementer/stages, Timeline Inspector, side section folds. |
| `.specs/46_pass40_switcher_preset_fold_consensus_marks_spec.md` | Stable model filter, visible effort preset, persistent research/consensus folds, explicit Consensus card, bounded activity log, detailed consensus bench. |
| `.specs/47_pass41_fastest_research_spec.md` | Renames low to Fastest and defines a genuinely fast three-phase research path, rendered HTML and measured bounds. |
| `.specs/48_pass42_faster_deep_levels_spec.md` | Batched tools, designed report off critical path, concurrent headline, straggler threshold, max-live 10, quality measurements for Medium/High/Ultra. |
| `.specs/49_pass43_storage_cleanup_spec.md` | Storage measurement, session/payload/checkpoint/journal/research cleanup, retention, safe VACUUM, Settings UI. |
| `.specs/50_pass44_compact_commands_planner_spec.md` | `/compact`, Workflow as sixth mode, slash command owns mode, Planner persona, authoring leak fix, finished-plan Approve/Revise/Decline and linked implementation. |
| `.specs/51_pass45_lean_runtime_spec.md` | Current deep hardening: SQLite cache/contention, light nodes, per-card updates, complete teardown, swarm/consensus/workflow/research reliability, transport/context/tools safety (§§1–8). |
| `.specs/51a_pass45_review_lean_runtime.md` | Verified synthesis/measurements and acceptance plan for spec 51; no distinct product surface. |
| `.specs/51b_pass45_review_reader_A.md` | Memory/process/data/LLM/tool findings used by spec 51; useful regression checklist. |
| `.specs/51c_pass45_review_reader_B.md` | Reliability/efficiency/architecture/security findings used by spec 51; useful regression checklist. |
| `.specs/52_pass46_edit_resend_in_place_spec.md` | Current edit/resend: supersede old turn in same session, dispatcher parity, folded old content, stable resizable editor, faithful explicit fork. |

## 8. High-value current implementation/test map

Use these as acceptance references when turning the inventory into a CLI spec:

- **Routes/surfaces:** `lib/swarm_code_web/router.ex`.
- **Conversation/run/message/goal truth:** `lib/swarm_code/conversations.ex`, `lib/swarm_code/conversations/*.ex`.
- **Launch/runtime:** `lib/swarm_code/engine.ex`, `lib/swarm_code/engine/run_server.ex`, `agent_server.ex`, `operation.ex`.
- **Modes/commands/transcript:** `lib/swarm_code_web/components/chat.ex`, `lib/swarm_code_web/live/workspace_live.ex`, `workspace_live/workflows_panel.ex`.
- **Run pane:** `lib/swarm_code_web/components/swarm_pane.ex`, `side_chat.ex`, `workflow_pipeline.ex`, `consensus_components.ex`, `research_components.ex`.
- **Tools/security:** `lib/swarm_code/tools.ex`, `lib/swarm_code/tools/*.ex`, `lib/swarm_code/atomic_file.ex`, `lib/swarm_code/git.ex`.
- **Providers/transport:** `lib/swarm_code/providers.ex`, `lib/swarm_code/llm/*.ex`, `lib/swarm_code/search*.ex`.
- **MCP:** `lib/swarm_code/mcp.ex`, `lib/swarm_code/mcp/*.ex`.
- **Workflows:** `lib/swarm_code/workflows.ex`, `lib/swarm_code/workflows/*.ex`, `priv/workflows/`, `grok_workflows.md`.
- **Research:** `lib/swarm_code/research.ex`, `lib/swarm_code/research/*.ex`, `lib/swarm_code_web/live/research_live.*`.
- **Scheduling:** `lib/swarm_code/scheduled.ex`, `lib/swarm_code/scheduled/*.ex`, `lib/swarm_code/scheduler*.ex`.
- **Settings/storage:** `lib/swarm_code/settings/setting.ex`, `settings_live.*`, `storage.ex`, `storage_section.ex`.
- **Focused end-to-end behavior tests:**
  - chat/composer/sidebar: `workspace_live_test.exs`, `composer_live_test.exs`, `sidebar_live_test.exs`;
  - swarms/goals/questions: `engine/swarm_run_test.exs`, `goals_live_test.exs`, `question_live_test.exs`;
  - consensus/plan: `engine/consensus_test.exs`, `polish31_consensus_test.exs`, `polish44b_plan_gate_test.exs`, `polish45a_consensus_gate_test.exs`;
  - compact/edit/fork: `polish44a_compact_test.exs`, `polish46_edit_resend_test.exs`, `conversations_fork_test.exs`, `conversations_supersede_test.exs`;
  - workflows: `workflows/runner_test.exs`, `workflows/commands_test.exs`, `workflow_pane_test.exs`, `workflows_page_test.exs`, `resume_after_restart_test.exs`;
  - research: `research/server_test.exs`, `research/rounds_test.exs`, `research/report_test.exs`, `polish33_research_redesign_test.exs`;
  - tools/MCP/files: tests under `test/swarm_code/tools/`, `test/swarm_code/mcp/`, `checkpoints_test.exs`, `attachments_test.exs`, `changes_live_test.exs`;
  - scheduler/storage: `scheduler_test.exs`, `scheduler/{cron,next}_test.exs`, `storage_test.exs`.

## 9. Top conclusions

1. **The semantic core can be decoupled from Phoenix.** Most orchestration, persistence, tools, providers, MCP, workflows, research, scheduling and storage already live under `SwarmCode.*`; the browser is a renderer/controller. A new repo can preserve the process/data model while replacing LiveView components with a TUI event adapter.
2. **A foreground-only CLI cannot honestly claim parity.** Workflows, research, schedules, hidden-window behavior, waiting questions and notifications are designed to continue while the user navigates away. A daemon/session-owner decision is necessary.
3. **Workflow and consensus are the hardest parity surfaces, not styling.** They have distinct persistence, journals/stages/gates, role-specific models/efforts, and failure semantics. A pretty chat TUI without these is not a clone.
4. **There are two separate “Ultra” concepts.** One is composer workflow orchestration; the other is Deep Research depth. Help and status must never conflate them.
5. **Do not copy browser mechanics or current plaintext-secret storage.** Clone information architecture and behavior, then implement terminal-native navigation and platform-appropriate secret storage.
6. **The TUI should treat every update as asynchronous and scoped.** Runs must continue and stream independently; stale results must carry conversation/run/generation identity; switching screens must never block or cancel unrelated work.
