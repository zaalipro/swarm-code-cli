# SwarmCode CLI: engine extraction and OTP architecture audit

**Audit date:** 2026-09-01  
**Source audited:** `/Users/zaali/dev/swarm-code` at `f51c8d48eb666e538ac987cac17e512c55c7702d`  
**Scope:** read-only inspection of the engine, supervision trees, agents/operations, workflows, scheduler, deep research, providers, MCP, tool policy, persistence, storage, project/Git/filesystem code, PubSub, and desktop/web boundaries.  
**Safety:** no source file, database, Git state, or remote in the original repository was changed. The requested new repository was not initialized by this audit.

## 1. Executive findings

1. **The reusable engine is substantial, but it is not presently a package boundary.** Most execution code is under `lib/swarm_code/**`, and Phoenix itself is not needed by the agent loop. However, several essential product semantics are implemented in LiveView: slash-command dispatch, queued-turn draining, edit/resend routing, goal mode transitions, workflow command parsing, plan approval/decline UI actions, and some presentation projections. Copying only `lib/swarm_code/engine/**` would not produce parity. See `lib/swarm_code_web/live/workspace_live.ex:1659-1721,4981-5300,5330-5390,5450-5517,5585-5699` and `lib/swarm_code_web/live/workspace_live/workflows_panel.ex:186-455`.

2. **The current ownership spine is worth preserving.** A normal run is `RunSupervisor -> RunSup -> AgentsSup -> AgentSup -> {operation Task.Supervisor, AgentServer}`, with a significant temporary `RunServer` controlling the whole run. `RunSup` is `:one_for_all` with `auto_shutdown: :any_significant`; `AgentSup` has the same shape. This gives stop/crash propagation that a CLI must not flatten into ad-hoc tasks. See `lib/swarm_code/engine/run_supervisor.ex`, `run_sup.ex:17-29`, `agents_sup.ex`, `agent_sup.ex:16-29`, `operation.ex:17-51`, and tests in `test/swarm_code/engine/run_server_crash_test.exs`, `swarm_run_test.exs`, and `polish45a_lifecycle_test.exs`.

3. **The TUI must be an adapter/client, not the owner of work.** Runs, workflows, research, schedules, MCP ports, commands, timers, and their database rows need to survive a TUI repaint or client disconnect. Full schedule/background parity also means there must be a long-lived local daemon (or a clearly documented foreground-only mode); a process cannot both exit and keep its BEAM processes/scheduler alive.

4. **A separate repo cannot be permanently drift-free while the desktop remains untouched unless one side consumes a versioned artifact from the other.** Under the current “do not change the original repo” constraint, the practical initial path is a provenance-preserving extraction into the new repo plus golden parity tests and an upstream-commit manifest. A shared private Hex/git dependency becomes the clean long-term answer only if a later change is permitted in the desktop repo so both products consume it.

5. **Do not point the CLI at the live desktop SQLite file.** Startup intentionally marks prior live rows interrupted, and two runtimes on one file can mark each other’s runs dead. `Bootstrap` explicitly documents this failure mode (`lib/swarm_code/bootstrap.ex:58-76`), while dev/prod use five SQLite connections with WAL and IMMEDIATE transactions (`config/dev.exs:4-26`, `config/runtime.exs:20-49`). Use a distinct CLI database and an offline, backed-up import command if desktop history import is desired.

6. **The latest contributor rules and current credential implementation disagree.** `AGENTS.md:69-72` requires provider/search/MCP secret references backed by macOS Keychain (or the isolated test adapter), yet provider/search API keys and MCP headers/env are still ordinary SQLite fields (`providers/provider.ex:18-30`, `search/search_provider.ex:16-23`, `mcp/server.ex:9-20`; migrations `20260820000001`, `20260821000000`, `20260908000000`). Redaction is good but is not secret-at-rest protection. A new public/installable CLI must introduce a cross-platform credential boundary before copying this storage design.

7. **There is no root `LICENSE` or `COPYING` file.** The repository remote is `git@github.com:zaalipro/swarm-code.git`, but repository ownership does not by itself specify redistribution terms. Before code is copied into a separately distributed repository, the owner should explicitly authorize that copy and choose compatible license/notice terms. This is a release blocker, not an engineering inference.

8. **Several current seams violate the stricter current ownership/security rules and should not be fossilized merely for source parity.** Examples include global untracked HTTP MCP tasks, direct `String.to_atom/1` in workflow schema atomization, plaintext secrets, synchronous scheduler work in its GenServer callback, some non-atomic content writes, and direct core-to-web/desktop calls. These are called out in §11.

## 2. What the current application actually starts

`SwarmCode.Application.start/2` starts, in order:

- telemetry;
- `SwarmCode.Repo` and `Ecto.Migrator`;
- `Phoenix.PubSub` (`SwarmCode.PubSub`);
- a unique `Registry` (`SwarmCode.Registry`);
- the global `SwarmCode.TaskSupervisor`;
- provider-capability ETS owner;
- pending-question ETS owner;
- engine `RunSupervisor`;
- research supervisor;
- MCP supervisor;
- synchronous `Bootstrap` recovery;
- workflow watchdog and scheduler;
- web UI state/cache, Phoenix endpoint, desktop window/guards/memory sampler.

Source: `lib/swarm_code/application.ex:9-56`.

Important details:

- The endpoint is a `Desktop.Endpoint`, not a normal Phoenix-only endpoint (`lib/swarm_code_web/endpoint.ex:1-55`).
- Production always enables the endpoint and desktop window and uses a random loopback port (`config/runtime.exs:51-60`). Development supports `DESKTOP=0` (`config/dev.exs:34-49,109`).
- The root supervisor currently uses `:one_for_one` (`application.ex:53-56`). Initial child start order gates first boot because a child’s `init/1` must return before the next starts, but a later `Bootstrap` restart would not automatically stop/restart the downstream scheduler/endpoint. The target should use a `:rest_for_one` gate or split foundation/runtime supervisors.
- `Bootstrap.run/1` serially performs interrupted-run settlement, boot notice, stale scheduled-claim reconciliation, provider seed, legacy search-key adoption, MCP startup, research recovery, then non-fatal attachment pruning (`bootstrap.ex:15-55`). It retries its fatal steps and stops application boot on exhaustion (`bootstrap.ex:117-170`).

The app is intentionally local and single-node. The contributor contract says so (`AGENTS.md:33-49`), and the release disables distribution by default (`rel/linux/run.eex:45-53`). A CLI daemon should retain this posture and use authenticated local IPC rather than turning Erlang distribution on.

## 3. Engine and run supervision

### 3.1 Run tree

```text
SwarmCode.Engine.RunSupervisor (DynamicSupervisor)
└── SwarmCode.Engine.RunSup (temporary; one per run)
    ├── SwarmCode.Engine.AgentsSup (temporary DynamicSupervisor)
    │   ├── SwarmCode.Engine.AgentSup (temporary; one per agent)
    │   │   ├── Task.Supervisor (one per agent; owns operation tasks)
    │   │   └── SwarmCode.Engine.AgentServer (temporary, significant)
    │   ├── ... more AgentSup children
    │   └── Workflow Runner (workflow runs only; temporary, monitored by RunServer)
    └── SwarmCode.Engine.RunServer (temporary, significant)
```

`RunSup` and `AgentSup` use `:one_for_all` plus `auto_shutdown: :any_significant` (`run_sup.ex:17-29`, `agent_sup.ex:16-29`). The run and agent supervisors themselves are temporary. This prevents a finished/crashed state machine from being restarted with stale state and ensures its sibling subtree is stopped.

### 3.2 RunServer’s role

`RunServer` is the single in-memory owner of one run’s node tree. Its public contract covers node registration/update, stream deltas/resets, steer, approvals, questions, consensus rounds, child-agent admission/await, workflow/research completion, pause/continue/stop, and state lookup (`run_server.ex:1-258`). It registers as:

```elixir
{:via, Registry, {SwarmCode.Registry, {:run, run_id}, {conversation_id, kind}}}
```

(`run_server.ex:50-60`). `Engine.running_runs/1`, `running_run_ids/0`, and `chat_run_ids/1` select those registry entries rather than treating database status as liveness (`engine.ex:971-995`).

The server:

- assigns every node’s UUID/position/started time and persists it;
- enforces per-run live-agent slots and FIFO queuing;
- owns approval/question callers and timers;
- monitors agents, the workflow Runner, worktree tasks, and finalization tasks;
- holds bounded streaming tails and coalesces events every 100 ms;
- aggregates run totals;
- writes final messages and terminal run/goal state;
- cancels/settles callers on stop or crash.

See `run_server.ex:330-406` (state), `555-905` (calls), `907-1231` (events/monitors), `1499-1694` (bounded stream/flush), `1817-2321` (agents/worktrees), and `2399-2622` (cancellation/finalization).

Event ordering is deliberate: on a flush, nodes are sent first, then assistant text, reasoning, and finally the run row (`run_server.ex:1626-1654`). Terminal code writes the final message and settles the goal before announcing the finished run (`run_server.ex:2514-2622`). Keep that ordering in the TUI; do not rebuild it by independently polling tables.

### 3.3 Agent loop and operation ownership

`AgentServer` is a non-blocking state machine:

```text
LLM operation -> zero or more concurrent tool operations -> next LLM operation
```

until a no-tool answer, structured output, failure, or turn cap (`agent_server.ex:1-6,113-184,238-293,313-455`). Each operation is a task beneath that agent’s own `Task.Supervisor`, not a global detached task (`operation.ex:17-51`). LLM stream deltas go directly to `RunServer`; the agent receives only final `Result`/tool outcomes (`operation.ex:125-164`). Tool calls in one assistant response execute concurrently (`agent_server.ex:313-380`).

The model only receives the agent’s allow-listed tool refs. Invented tool names cannot reach the global registry except the two interaction fallbacks (`structured_output`, `ask_user`) (`agent_server.ex:295-311`). This is important for plan mode and workflow capabilities.

Pause semantics are cooperative: finish the current LLM/tool batch, then hold before the next LLM call (`agent_server.ex:52-63,231-236`). Stop semantics are structural: terminate the agent/RunServer and let supervisors take operation tasks and OS descendants down (`run_server.ex:2283-2321`, `operation.ex:102-122`).

Focused behavioral evidence:

- chat streaming/tool loop/steering/error/reasoning: `test/swarm_code/engine/chat_run_test.exs`;
- swarm parallelism/queue/depth/stop: `test/swarm_code/engine/swarm_run_test.exs`;
- approval modes: `test/swarm_code/engine/approval_test.exs`;
- crash cleanup and terminal persistence: `test/swarm_code/engine/run_server_crash_test.exs`;
- worktree isolation/integration: `test/swarm_code/engine/worktree_test.exs`;
- responsiveness/cancellation of blocked Git work: `test/swarm_code/engine/hardening_test.exs`.

### 3.4 Engine launch facade

`SwarmCode.Engine` is the non-web entry point for chat, goal, compact, swarm, run control, resume, answers, and approvals (`engine.ex`). It resolves models, writes transcript/run rows, builds history/prompts/project context, and starts the run supervisor.

Notable flows:

- chat: `engine.ex:58-185`;
- compaction: `engine.ex:207-298`;
- steer: `engine.ex:323-365`;
- swarm: `engine.ex:367-450`;
- supervisor start and compensation: `engine.ex:558-665`;
- pause/continue/resume: `engine.ex:674-943`;
- stop/answer/approval/liveness: `engine.ex:945-995`.

`start_run/1` catches supervisor failures, redacts them, settles the run as failed, writes a kind-specific error, and pauses an active goal (`engine.ex:564-665`). That is useful, but launch writes before `start_run/1` are not one transaction in chat/swarm paths. This matters in §11.

## 4. Consensus, plan, compact, ultra, goals, commands

These are not separate execution engines:

- **Consensus** is a normal chat run whose root assistant gets `submit_plan`; the judge/implementer are worker agents. The run stores its config/round outcomes. See `.specs/37_consensus_spec.md:17-40`, `engine/consensus.ex`, `tools/submit_plan.ex`, `tools/write_spec.ex`, and `run_server.ex:611-627,1087-1099,1807-1815`.
- **Plan mode** is a persisted conversation/run mode that reduces the tool allow-list to read-only tools (with lead fan-out retained) (`tools.ex:105-152`) and changes the system prompt/persona.
- **Compact** is its own run kind and transcript role, with a model-history floor but no deleted history (`engine.ex:207-298`, `conversations.ex:475-574`).
- **Ultra** is a conversation flag/prompt mode; it uses the same run tree.
- **Goals** are rows linked to current runs; clean completion marks done, failure/stop pauses (`run_server.ex:2624-2646`).
- **Custom slash commands** are Markdown files in project/global config directories (`commands.ex:1-165`).

The critical extraction issue is that the product-level dispatcher is web-coupled. `WorkspaceLive.dispatch_send/3` decides built-ins, mode changes, custom commands, workflow names, compact, goals, resume, rewind, research attachments, and normal sends (`workspace_live.ex:5160-5300`). `WorkflowsPanel` implements `/workflow`, `/ultra`, `/create-workflow`, and direct workflow-name launches (`workflows_panel.ex:186-455`). The next queued chat turn is also launched only by `WorkspaceLive.start_next_queued/1` (`workspace_live.ex:5053-5075`). A headless CLI/TUI must move these semantics into a core `CommandDispatcher`/conversation coordinator; otherwise queueing stops when no LiveView is connected and slash behavior drifts.

The latest relevant product contracts include:

- workflows: `.specs/09_workflows_spec.md`;
- consensus: `.specs/37_consensus_spec.md`;
- compact/mode ownership/plan gate: `.specs/50_pass44_compact_commands_planner_spec.md`;
- edit/resend superseding in place: `.specs/52_pass46_edit_resend_in_place_spec.md`.

## 5. Workflows

### 5.1 Persistence and execution

A workflow definition is an `.exs` file. Visible definitions are built-in, project, then user scope; a run freezes source and args into a 1:1 `workflow_runs` row, with deterministic results in `workflow_journal` (`workflows.ex:19-109`, `.specs/09_workflows_spec.md:24-110`).

Launch validates limits, creates the engine `runs` row and workflow row in one transaction, broadcasts only after commit, then starts the ordinary run supervisor (`workflows.ex:529-653,792-822`). A workflow `RunServer` registers a workflow root and starts a `Workflows.Runner` beneath the run’s dynamic subtree; it monitors the Runner and fails the run if it disappears without reporting (`run_server.ex:441-499,1191-1207`).

The Runner owns:

- one script task;
- journal replay and sequence/fingerprint checks;
- panel admission/budget;
- worker calls through the same `RunServer.start_agent/2` path;
- pause/gate/complete/error terminalization;
- panel task PIDs for teardown.

See `workflows/runner.ex:1-13,44-116,131-319,420-571`. Resume evaluates the frozen script and replays committed calls; missing calls execute live (`workflows.ex:824-918`, `runner.ex:186-210`). Focused tests are in `test/swarm_code/workflows/runner_test.exs`.

### 5.2 Trust boundary

The Runner explicitly evaluates workflow AST as Elixir (`Code.eval_quoted/3`) and calls definitions “trusted as the app itself” (`runner.ex:1-13,104-116`). Save/smoke paths now apply a static allow-list (`workflows.ex:335-360`, `workflows/smoke.ex`), and the script task has a 512 MB max-heap guard (`workflows/api.ex:37-56`). This is still not an OS sandbox. An installable CLI must state that model-authored/user-approved workflow source executes inside the local BEAM, and should not imply that tool approval modes sandbox arbitrary Elixir.

## 6. Deep research

Research has two coordinated supervision trees:

```text
Research.Supervisor
└── Research.Sup
    └── Research.Server (significant)
        └── linked Program task

Engine.RunSupervisor
└── RunSup(kind: research)
    └── RunServer
        └── research lead/worker/reporter AgentSup children
```

`Research.Server` owns the research row, hidden conversation, engine run id, and linked program; stop/crash/finish converge on idempotent `close/3` (`research/server.ex:1-9,51-69,196-220,244-390`). The engine `RunServer` owns actual research agents; its research root has no AgentServer (`run_server.ex:501-525`). Each side tells the other when it terminates.

`Research.Program` executes sequential compound rounds while fan-out agents run concurrently; it records tasks/notes/steps and finally produces Markdown plus HTML (`research/program.ex:1-9,59-146,275-435,603-710`). Research-level settings freeze fanout/round count and concurrency (`research/research.ex:61-89`, `research/levels.ex`). The Fastest/deep timeout and turn caps are separate (`research/program.ex:21-53,571-594`).

Full CLI parity therefore needs all of `lib/swarm_code/research/**`, search providers/readers, skills, hidden conversations, report files, and the core event feed—not just an LLM “research prompt.” Tests: `test/swarm_code/research/server_test.exs`, `rounds_test.exs`, `report_test.exs`, `polish45a_research_test.exs`, and `polish42_faster_research_test.exs`.

One extraction seam is mandatory: `Research.HtmlRender` calls `SwarmCodeWeb.Markdown.render/1` and `safe_href?/1` (`research/html_render.ex:18,300-318`). Move those safe Markdown functions into a core renderer and let both Web and TUI adapters consume it.

## 7. Scheduler and background operation

`Scheduler` ticks every 30 seconds, reconciles scheduled-run status, settles stale claims before firing due work, applies catch-up policy, and invokes storage retention (`scheduler.ex:1-18,26-79,90-184`). `Scheduled.claim/2` uses a unique `{task_id, scheduled_for}` insert with `on_conflict: :nothing` (`scheduled.ex:390-412`). Launch staging writes the conversation id before engine start, catches raise/throw/exit, stops partial work, settles the claim, and advances the schedule (`scheduled.ex:230-336`). This is a strong pattern to retain.

A TUI-only foreground executable cannot provide scheduled parity after the terminal closes. The target must choose one of these explicit products:

- a per-user local daemon that starts on demand and is installed as `launchd`/`systemd --user`, with TUI/headless commands as clients; or
- foreground-only scheduling, documented as active only while the CLI process is open.

For the requested “everything asynchronously like the app,” the daemon is the parity-preserving option. Keep it a single BEAM node with a mode-0600 local Unix socket; do not enable distributed Erlang merely to attach clients.

The current scheduler performs reconciliation, launch, and retention synchronously in its GenServer callbacks (`scheduler.ex:37-67`). The target should make the Scheduler a coordinator and run each tick/launch in a monitored owned worker, with one tick in flight and generation/ref correlation, so a slow database/provider launch cannot block timer/control messages.

## 8. MCP, providers, permissions, tools, files and Git

### 8.1 Providers/LLM

The provider-neutral boundary is already useful:

- `SwarmCode.LLM.Provider` behavior (`llm/provider.ex`);
- `Request`, `Result`, tool calls and streaming event types (`llm/request.ex`, `result.ex`);
- OpenAI-compatible and Anthropic adapters;
- incremental SSE and iodata chunks (`llm/sse.ex`, `chunks.ex`);
- retry/deadline/redaction HTTP layer (`llm/http.ex`).

`LLM.HTTP` uses Req, bounds error bodies, retries only transport/transient failures, honors an absolute monotonic deadline, resets partial stream state before retry, and redacts known credential shapes (`http.ex:1-30,57-244,267-339`). Keep Req; the contributor rules explicitly prohibit adding a second HTTP client (`AGENTS.md:9-14`).

### 8.2 Tool policy

Tools are refs over builtin, MCP, or structured implementations (`tools/ref.ex`). `Tools.for_agent/5` and `for_worker/2` produce role/mode/capability allow-lists (`tools.ex:105-193`). `Operation` then asks `Engine.Policy` for the current permission decision (`operation.ex:180-221`; `policy.ex`). The project approval modes are:

- `read_only`: deny write/execute;
- `auto`: allow write, ask execute;
- `full_access`: allow all.

Tests: `engine/approval_test.exs`, `engine/command_gating_test.exs`, `workflows/commands_test.exs`.

The TUI interaction layer must render approvals/questions from the same pending state and resolve them via `Engine.resolve_approval/3` / `Engine.answer/3`; it must not duplicate policy decisions client-side.

### 8.3 MCP

`MCP.Supervisor` owns ETS tables and `ClientSup`; one `MCP.Client` owns each enabled stdio port/HTTP session (`mcp/supervisor.ex`, `mcp.ex:74-117`). Tool discovery lands in ETS and is scoped global-or-project (`mcp.ex:119-220`). Stdio calls are correlated by JSON-RPC id and have timers; the client reaps the entire subprocess tree (`mcp/client.ex:1-19,237-273,382-415,482-529`). Configured secret values are redacted at every textual exit (`mcp/server.ex:122-142`, `mcp/client.ex:471-478,694-721`).

The target must change the HTTP-call ownership: `dispatch_http/5` currently starts a global `TaskSupervisor` child, stores no task/caller monitor, and lets that task reply directly (`mcp/client.ex:288-315`). Give each client a child `Task.Supervisor`, track `{request_id, task_ref, caller_monitor, deadline, generation}`, cancel on caller/client/reconnect, and discard late generations. This matches the current contributor contract (`AGENTS.md:33-48`) better than source-copy parity.

### 8.4 Files, commands and Git

Strong reusable primitives:

- `Tools.Path`: lexical + resolved-symlink confinement and pruned traversal (`tools/path.ex`);
- `AtomicFile`: same-directory mode-0600 temp, sync, mode preservation, rename, cleanup (`atomic_file.ex`);
- `OSProcess`: process-tree discovery/termination (`os_process.ex`);
- `RunCommand`: bounded head/tail output, deadline, `/dev/null` stdin, clean release env, process-tree kill (`tools/run_command.ex`);
- `Git`: argument arrays, revision validation, bounded Port collection, worktree/merge helpers (`git.ex`);
- `Checkpoints`, `Attachments`, `Memory`.

Tests: `tools/path_test.exs`, `atomic_file_test.exs`, `tools/run_command_test.exs`, `tools/write_edit_test.exs`, `git_test.exs`, `attachments_test.exs`, `checkpoints_test.exs`.

Worktrees are not cosmetic: sub-agents normally receive a branch/worktree and completion commits/statistics before returning to the lead (`run_server.ex:1902-2203`). Preserve this path for swarm parity.

## 9. Persistence and migration contract

There are **43 ordered migrations** from `20260820000001` through `20260926000000`. The final logical store includes:

| Area | Tables / important keys |
|---|---|
| preferences/providers/projects | `settings`, `providers`, `projects`, `search_providers`, `mcp_servers` |
| transcript/runtime | `conversations`, `messages`, `runs`, `nodes`, `goals` |
| workflows | `workflow_runs` (PK = engine `run_id`), `workflow_journal` |
| scheduling | `scheduled_tasks`, `scheduled_runs` |
| research | `researches` (integer id), `research_steps` |
| rewind | `checkpoints` |

Important database-enforced uniqueness:

- provider name;
- project root path;
- MCP server name;
- message `{conversation_id, position}`;
- scheduled occurrence `{task_id, scheduled_for}`;
- workflow journal `{run_id, seq, slot}`;
- research step `{research_id, index}`.

See `priv/repo/migrations/20260820000001_create_swarm_code_schema.exs`, `20260821000000_add_gap_features.exs`, `20260823000000_scheduled_tasks.exs`, `20260829000000_workflows.exs`, `20260905000000_unique_message_position.exs`, `20260905000001_unique_scheduled_occurrence.exs`, and `20260908000000_deep_research.exs`.

The CLI should initially copy the complete historical migration chain unchanged (apart from OTP-app/module namespace mechanics) and add CLI-only migrations after it. Reasons:

- it provides a tested fresh-schema path;
- it permits an offline import of a copied desktop database;
- several migrations contain data transforms, not only DDL (e.g. deep-research Tavily adoption and workflow-mode reset);
- squashing would create a second schema lineage immediately.

Never let desktop and CLI open the same database concurrently. An import command should:

1. require both applications stopped;
2. create a consistent independently restorable mode-0600 backup and manifest;
3. run `quick_check`, row counts, checksum, and restore verification;
4. copy into the CLI state directory;
5. migrate the copy;
6. rewrite credential values into secret-store references before normal boot;
7. preserve legacy values in a protected rollback quarantine until a reference-aware rollback is verified.

Those rules follow the repository contract (`AGENTS.md:15-20,51-72`) and the migration/recovery requirements in `.specs/19_reliability_security_performance_spec.md:69-108` (although spec 19 itself notes later supersession, these same invariants are repeated in `AGENTS.md`).

Use platform path abstraction. Current production storage is hard-coded under `~/Library/Application Support/SwarmCode` (`config/runtime.exs:20-31`) and global project assets call `Desktop.config_dir/0` (`projects/workspace.ex:1-49`). For CLI, resolve paths through an interface, e.g. XDG state/config/data/runtime dirs on Linux and native Application Support/Cache paths on macOS.

## 10. Reuse/coupling map

### 10.1 Reuse essentially as core code (with namespace/config changes)

- `LLM.*`, `Search.*`, `Pricing`;
- `Engine.Context`, `Policy`, `Consensus`, prompt builders, `Operation`, agent/run supervisors and servers;
- tool behavior/ref/registry and builtin tools;
- `AtomicFile`, `OSProcess`, `Git`;
- Ecto schemas and most contexts for projects, conversations, providers, settings, schedules, workflows, research;
- `Workflows.Args`, `Definition`, `Schema`, `Host`, `Runner`, API and smoke checker;
- scheduler cron/next calculations;
- attachments/checkpoints/memory/skills/commands.

These are not “pure” in every case, but their product responsibility belongs in core rather than in a TUI.

### 10.2 Reuse only after introducing an adapter seam

| Current module | Coupling to remove |
|---|---|
| `SwarmCode.Application` | starts Phoenix/Desktop/UI children; replace with core foundation/bootstrap/runtime supervisors |
| `SwarmCode.Bootstrap` | calls desktop alert on boot failure (`bootstrap.ex:127-131`) |
| `Engine.RunServer` | directly calls desktop waiting/finish notifications (`run_server.ex:2493-2509,2616-2723`) |
| `Projects.Workspace` | config directory comes from `Desktop.config_dir/0` |
| `Conversations` | deletes Web Markdown cache/UI state and uses Web `Chat.launch_messages` (`conversations.ex:451-463,727`) |
| `Storage` | asks `SwarmCodeWeb.UIState` which sessions are open (`storage.ex:349-351`) |
| `Research.HtmlRender` | uses `SwarmCodeWeb.Markdown` |
| `Quit` | desktop window/dialog handshake; replace with daemon detach/stop lifecycle |
| repair Mix tasks | one aliases `SwarmCodeWeb.Chat`; extract projection logic |
| settings row | engine settings and web-only appearance/layout fields share one schema; expose separate core/preferences facades even if the row is retained for compatibility |
| all PubSub callers | depend on concrete `SwarmCode.PubSub`; wrap in `Core.EventBus` so local IPC/TUI can consume typed events |

### 10.3 Do not bring into the core package

- `lib/swarm_code_web/**` LiveViews, controllers, components, endpoint/router/telemetry/UI caches;
- `Desktop`, desktop memory/close guard, menu bar and tray menu;
- Phoenix/LiveView/Bandit/Desktop deployment, Tailwind/esbuild/heroicons dependencies;
- browser assets and installer-specific macOS window resources.

Some pure presentation logic currently lives in Web and must be **moved/reimplemented**, not omitted: command catalogs/dispatch, transcript/run projections, safe Markdown, workflow command parsing, and plan-gate actions.

### 10.4 Minimal core dependency set

The engine can plausibly compile with:

- `ecto_sql`, `ecto_sqlite3`;
- `req`, `jason`;
- `phoenix_pubsub` (not full Phoenix) or a replacement event bus;
- `tzdata`;
- `floki` for readable HTML extraction;
- `earmark`/`html_sanitize_ex` only if research HTML/Markdown rendering stays in core;
- standard OTP applications `logger`, `runtime_tools`, `ssl`, `crypto`.

The current full dependency list is in `mix.exs:47-83`. Avoid carrying Phoenix, LiveView, Bandit, Desktop, asset builders, and heroicons into the CLI release merely because source modules refer to Web today.

## 11. Confirmed risks/gaps not to copy blindly

These are architectural audit findings, not claims that every one is currently user-visible.

1. **Secret-at-rest mismatch:** provider/search keys and MCP header/env secrets are plaintext database fields despite the current Keychain rule. Redaction (`Provider`’s custom `Inspect`, `LLM.HTTP.redact`, MCP exact-secret redaction) protects output, not disk.

2. **Linux secret backend is undecided:** macOS Keychain cannot satisfy Ubuntu. Define a `Credentials` behavior with a macOS Keychain adapter, Linux Secret Service/libsecret adapter, isolated test adapter, and a deliberate non-interactive fallback policy. Do not silently fall back to plaintext SQLite.

3. **HTTP MCP task ownership:** `mcp/client.ex:288-315` launches global tasks without task/caller tracking.

4. **Runtime atom creation:** `Workflows.Schema.atomize_key/1` calls `String.to_atom/1` (`workflows/schema.ex:227-228`), contrary to `AGENTS.md:58`. The spec itself says only schema-declared existing atoms should be used (`.specs/09_workflows_spec.md:193-200`). Fix with the declared property atom or a closed mapping; never atomize arbitrary decoded keys.

5. **Launch atomicity is incomplete:** chat/swarm paths create user/assistant/run rows in separate writes and pattern-match successful later writes (`engine.ex:76-179,382-433`). Supervisor-start compensation handles one class of failure, but a database failure between those writes can leave partial state. Move launch preparation into one transaction/outbox-style state transition, then start ownership and compensate idempotently.

6. **Steer persistence ordering:** the message is delivered to the AgentServer before the transcript row is inserted (`engine.ex:333-357`); a database-busy result admits that the model may have received text that history did not. A command coordinator should persist an intent first or store a durable delivery marker.

7. **Workflow display-name race:** `next_display_name/1` is query-then-select (`workflows.ex:436-455`) with no unique display-name constraint. The contributor contract requires a constraint and retry (`AGENTS.md:53-57`).

8. **Settings singleton race:** `Settings.get/0` inserts a row when none exists (`settings.ex:9-10`) without a database singleton constraint.

9. **Background jobs escape their logical owner:** examples include run labels (`engine.ex:453-489`), post-run worktree cleanup (`run_server.ex:2141-2193`), delayed research design (`research.ex:438-483`), and some notifications. They are under an application TaskSupervisor, but not all have a tracked logical owner/cancel path. Add named job supervisors/registries and durable cleanup jobs where work intentionally outlives a run.

10. **Scheduler owner can block:** long database/launch/retention work occurs inside `Scheduler` callbacks.

11. **Core-to-Web dependencies:** `Conversations`, `Storage`, and research rendering make a clean headless build impossible without extraction seams (see §10.2).

12. **Direct/non-atomic content writes remain:** examples include custom command creation (`commands.ex:67-83`), workflow report writes (`workflows/api.ex:295-311`), and research result/source writes (`research/program.ex:603-645`). The current contributor rule requires same-directory atomic replacement for these content classes (`AGENTS.md:64-66`).

13. **`web_fetch` destination hardening is not evident in the tool path:** `tools/web_fetch.ex:31-90` accepts HTTP(S) and hands redirects/DNS to Req. Current rules require retaining localhost/private fetch while validating destinations/redirects, not blanket blocking (`AGENTS.md:59-63`). Implement a network destination policy/connector boundary.

14. **Workflow scripts are in-process trusted code:** static checks and heap limits reduce mistakes but do not create a sandbox. This needs explicit UX/documentation and an approval model for saving/running generated workflows.

15. **Database/platform assumptions:** `Storage.free_disk_bytes/0` calls `df`; release/config paths are macOS-specific; shell execution assumes `/bin/sh`. Ubuntu/macOS are compatible with the latter two commands but path/keyring/service behavior needs platform adapters and tests.

16. **No source license:** copying/publishing is not safe to assume merely because both remotes have the same owner account.

## 12. Source-sharing options under “original untouched”

| Option | Works now without original edits? | Parity/drift characteristics | Distribution implications |
|---|---:|---|---|
| Copy/extract core into new repo | Yes, after rights authorization | Fastest initial parity; independent copies drift unless gated by manifests/golden tests | Self-contained; easiest for prebuilt releases |
| Git subtree/submodule of original | Technically | Preserves provenance/pin, but brings a Phoenix desktop app rather than a compilable core; selective overlays become awkward | Source checkout needs original access; poor single-command/offline story |
| Depend directly on original Git repo from Mix | No practical clean build | Original Mix app compiles Phoenix/Desktop and uses the same module/application namespace; not a library boundary | Private SSH/network dependency; unsuitable for general installation |
| New private Hex/git `swarm_code_core` package | New CLI can use it now; desktop cannot share it without later edits | Best eventual single source once desktop also consumes it | Private registry/auth or public licensing needed; releases can still vendor deps |
| Runtime RPC/HTTP into desktop app | No standalone parity | No duplicated engine, but requires desktop running and couples lifecycle/schema | Violates standalone requirement; not recommended |
| Reimplementation from specs only | Yes | Avoids literal copy but has the highest semantic drift risk across hundreds of tests/43 migrations | Clearer independent code ownership, much slower and less faithful |

**Recommended staged source strategy (subject to explicit rights/licensing approval):**

1. Create an umbrella in the new repo with `apps/swarm_code_core` and `apps/swarm_code_cli`.
2. Preserve the `SwarmCode.*` module namespace in core initially to reduce behavioral edits; use OTP app `:swarm_code_core` and centralize app-env/priv-dir lookup behind `SwarmCode.Config`.
3. Extract the core code and focused Fake-driven tests at the pinned upstream commit.
4. Record `UPSTREAM_SWARM_CODE_COMMIT`, per-file SHA-256/source path, and copy authorization/license in a machine-readable provenance manifest.
5. Maintain a read-only `upstream/swarm-code` Git remote/ref in the new repo; a CI job reports changes to any mapped source/spec/test file.
6. Add golden cross-repo parity fixtures for normalized provider requests, tool results, rows, events, workflow replay, and research output. Do not rely on textual diff alone because adapter seams will intentionally differ.
7. Tag core releases. If the owner later permits desktop changes, make the desktop depend on that tagged core package and delete its duplicate modules. That is the point at which drift becomes structurally impossible rather than procedurally detected.

A subtree/private Hex package does not solve drift by itself if the desktop continues compiling its old embedded copy.

## 13. Proposed target supervision tree

```text
SwarmCodeCLI.RootSupervisor (:rest_for_one)
├── SwarmCodeCore.FoundationSupervisor
│   ├── SwarmCode.Repo
│   ├── Ecto.Migrator
│   ├── SwarmCodeCore.EventBus
│   ├── SwarmCode.Registry
│   ├── SwarmCodeCore.JobSupervisor
│   ├── SwarmCode.LLM.ProviderCaps
│   ├── SwarmCode.Engine.Questions
│   ├── SwarmCodeCore.Credentials
│   └── SwarmCode.MCP.Supervisor
├── SwarmCodeCore.BootstrapGate
│   └── recovery/seed/credential-cutover/MCP startup (synchronous, idempotent)
├── SwarmCodeCore.RuntimeSupervisor
│   ├── SwarmCode.Engine.RunSupervisor
│   ├── SwarmCode.Research.Supervisor
│   ├── SwarmCodeCore.ConversationSupervisor
│   │   └── one ConversationCoordinator per active/queued conversation
│   ├── SwarmCode.Workflows.Runner.Watchdog
│   ├── SwarmCode.Scheduler
│   ├── SwarmCodeCore.StorageJobSupervisor
│   ├── SwarmCodeCore.CleanupJobSupervisor
│   └── SwarmCodeCore.NotificationSupervisor
├── SwarmCodeCLI.DaemonSupervisor
│   ├── local Unix-socket listener (0600)
│   ├── authenticated client supervisors
│   └── command/query/event protocol
└── SwarmCodeCLI.UISupervisor (only for interactive invocation)
    ├── TUI session/render loop
    ├── input/terminal-signal owner
    ├── EventBridge
    └── bounded request workers
```

Use `:rest_for_one` so failure/restart of the boot gate takes every work producer and client gateway below it down before recovery repeats. Foundation processes needed by recovery remain up.

Inside each run, retain the current `RunSup`/`AgentSup` shapes. Add a per-run auxiliary task supervisor for worktree preparation/finalization and labels. Work that must outlive the run should become a tracked cleanup job with an idempotency key, not a fire-and-forget task.

For MCP, put an HTTP request supervisor under each Client and track caller monitors/deadlines/generation. For research, put the Program/await/headline tasks under a research-local task supervisor instead of only the global one. For workflows, continue tracking the script and every panel task and kill them before Runner exit.

## 14. Boundary interfaces

The following boundaries keep TUI/headless/web semantics from diverging.

### 14.1 Command/launch boundary

```elixir
@type request :: %SwarmCodeCore.Command{
  ref: reference_or_uuid,
  conversation_id: binary,
  text: binary,
  attachments: [attachment_ref],
  research_ids: [integer],
  reply_target: nil | %{run_id: binary, node_id: binary | nil},
  queue?: boolean,
  source: :tui | :headless | :scheduled | :model
}

@callback dispatch(request()) ::
  {:ok, %Outcome{kind: atom, ids: map, notices: [notice]}}
  | {:needs_input, input_spec}
  | {:error, typed_reason}
```

This core dispatcher owns built-in/custom/workflow slash parsing, mode adoption, goal creation, edit/resend routing, queueing, and launch calls. `ConversationCoordinator` starts the next queued item when the relevant chat run’s terminal event arrives, whether or not any UI is attached.

### 14.2 Run control

```elixir
pause(run_id)
continue(run_id)
resume(run_id)
stop(run_id)
stop_agent(run_id, node_id)
steer(run_id, node_id_or_nil, text, attachments)
answer(run_id, node_id, answers)
resolve_approval(run_id, node_id, :approve | :deny | :always)
```

Back these with the existing Engine/RunServer functions. Every call validates ownership/scope server-side.

### 14.3 Query/read model

```elixir
snapshot(%{conversation_id: id, page: cursor, include: set})
list_projects(cursor)
list_conversations(project_id, cursor)
list_runs(conversation_id, cursor)
run_detail(run_id, node_cursor)
list_pending_interactions(scope)
list_workflows/filter/research/schedules/storage(...)
```

Return page-limited DTOs, not Ecto structs with secrets or huge payloads. Large result/reasoning/diff/source fields are fetched on demand. The TUI must not call `RunServer.get_state/1` for routine rendering; current code already added narrower calls because full state copies were expensive (`run_server.ex:148-157`).

### 14.4 Typed event bus

Wrap Phoenix.PubSub (which can remain the in-process transport) in a core API and emit a struct/envelope:

```elixir
%Event{
  version: 1,
  sequence: non_neg_integer,
  scope: {:conversation, id} | {:run, id} | {:research, id} | :global,
  type: atom,
  payload: map,
  request_ref: binary | nil,
  occurred_at: DateTime.t()
}
```

Preserve current flush ordering and scopes. Never put provider/MCP credentials in payloads. For daemon clients, include sequence numbers and require a snapshot resync on a gap; do not pretend PubSub is durable replay.

### 14.5 Pluggable environment boundaries

Define behaviors/adapters for:

- `Credentials.get/put/delete(reference)`;
- `Paths.config/state/data/runtime/log_dir`;
- `Notifier.waiting/finished/scheduled/error`;
- `EventBus`;
- `ProcessRunner`/Git adapter;
- `MarkdownRenderer`/safe links;
- `Presence.open_conversation_ids` (storage cleanup protection);
- optional clock/test seams.

This removes direct core calls to Desktop, Web UI state/cache, and platform-specific directories.

## 15. TUI and headless async contract

- The TUI subscribes first, obtains a versioned snapshot, then applies ordered deltas. On scope change it cancels pending UI requests, increments a generation, unsubscribes, and drops buffered old-scope events.
- Rendering never performs filesystem, Git, network, or long Repo work. It sends a request with a ref and later applies the correlated outcome if the generation still matches.
- Input remains responsive while multiple runs stream. Stream text is accumulated as iodata/bounded tails in core; the UI receives the existing 100 ms coalesced slices rather than every provider fragment.
- Questions/approvals are a global “needs you” queue plus scoped run panels. Resolving one is a core command, not a client-only state change.
- Ctrl-C/quit semantics must be decided explicitly:
  - **detach** leaves daemon-owned work/schedules running;
  - **stop current** stops one run;
  - **shutdown daemon** performs the current structured teardown equivalent.
- Headless mode calls the same dispatcher and event/query APIs. It can output human text or NDJSON events and wait for terminal state, or return immediately with a run id under `--detach`.
- A daemon lock/socket prevents two CLI cores from opening the same CLI database. Socket and auth material are owner-only.

## 16. Parity and verification gates

Before calling the CLI a clone, port and run at least these core suites (with module/config changes only):

- engine: `chat_run_test`, `swarm_run_test`, `run_server_test`, `run_server_crash_test`, `approval_test`, `ask_user_test`, `consensus_test`, pause/resume tests, worktree/hardening/hot-path tests;
- LLM: OpenAI, Anthropic, retry, SSE, chunks, tool args, effort tests;
- tools/files/Git: path, read/list/grep, write/edit, run command, web, Git tools, AtomicFile, attachments, checkpoints;
- MCP: stdio client and HTTP/session/credential tests;
- workflows: definition, host, schema/smoke, Runner/replay/budget/pause/stop, commands;
- scheduled: cron/next/scheduler launch recovery;
- research: levels, rounds, Server, report, faster/deep and lifecycle tests;
- persistence: conversations, providers, settings, projects, Repo permissions, storage.

Then add cross-repo golden fixtures that normalize only ids/timestamps and compare:

1. every provider request body/event/final result;
2. message/run/node rows and ordering;
3. PubSub/event ordering for a chat, swarm, consensus, workflow, compact, and research;
4. policy/tool allow-lists per role/mode/capability;
5. workflow journal replay and results;
6. worktree branch lifecycle;
7. scheduled claim/recovery;
8. research Markdown/sources/report;
9. stop/crash process and OS-descendant counts;
10. TUI snapshot-to-screen projections and terminal resize/keyboard behavior.

The repository’s performance/equivalence contract is unusually strict (`AGENTS.md:74-96`; `.specs/19_reliability_security_performance_spec.md:205-239`). Source copy is not evidence of parity; these behavior/golden tests are.

## 17. Decisions/questions the root workflow should put to the user

1. **Code rights/license:** confirm authorization to copy/extract the original source into `swarm-code-cli` and whether the new GitHub repo is public or private; choose a license/NOTICE strategy.
2. **Daemon semantics:** should closing the TUI detach while runs/schedules continue, or should all work stop? Full current background/scheduler parity implies a per-user daemon/service.
3. **Data:** should the CLI start with its own empty database, offer an explicit offline desktop-import command, or intentionally share history through some other export format? Do not share the live file.
4. **Secrets on Ubuntu:** is Secret Service/libsecret an acceptable requirement, and what should non-GUI/server environments do when no keyring is available (environment-only, prompt each start, or an explicitly encrypted vault)?
5. **Long-term sharing:** may the desktop repo later be changed to consume a `swarm_code_core` package? Without that later step, drift can be detected but not structurally prevented.

## 18. Bottom line

A faithful CLI is feasible without modifying the original repository, but it is not “wrap `Engine.start_chat_turn/3` in a terminal.” The core run tree, Ecto schema/migrations, LLM/tool/MCP stack, workflows, scheduler, and research pipeline should be extracted together; the product dispatcher and projections currently living in LiveView must be moved behind core interfaces; and desktop/Web/platform calls must be adapters.

The safest initial architecture is a new umbrella containing an extracted core OTP application plus a daemon/TUI/headless client application, with a separate SQLite file, typed event bus, secure credential references, and source/provenance/golden parity gates. True ongoing no-drift sharing requires a later decision to make both desktop and CLI consume the same versioned core package.
