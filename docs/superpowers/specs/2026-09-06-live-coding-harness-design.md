# Live coding harness

The user explicitly requested filling the executable/runtime gaps identified in
chat. The goal is a fully powered TUI coding harness, including real providers,
agent/tool execution, persistence, workspace/Git features, approvals, advanced
modes, settings, reconnect and distributable startup. A scripted demo or isolated
history browser does not meet this goal. This design applies the already approved
standalone architecture to the current CLI checkout.

## Runtime direction

Retain the three applications. Core owns bounded shared protocol/domain contracts;
the daemon owns provider network IO, tools, agent/run supervision, persistence,
credentials and the service endpoint; CLI owns presentation and its transport
adapter. The existing renderer/editor/reducer stays reusable. Never import daemon,
Repo or provider implementations into the client application.

Adapt the desktop runtime at pinned commit
`fb1b4ff82354ac8ff2e82d4f6516121fd55ff212`, read-only. Preserve behavioral tests and
source attribution. The existing owner authorization and current explicit request
to adapt/fill the desktop harness gaps authorize these local changes. Every
adapted file records source commit/path/hash and current destination hash. Existing
legacy extraction records remain inspectable; no push or publication follows.

Providers use real HTTP streaming with explicit terminal-event validation,
bounded response/tool arguments, timeout/retry semantics, cancellation and usage.
Implement OpenAI-compatible and Anthropic adapters with configuration supplied by
the daemon credential/configuration layer. Model names are configuration, never
invented defaults. No credential value goes into logs or evidence. Local fixture
HTTP servers test transport behavior; paid live calls require actual configured
credentials and are recorded separately from fixture tests.

The agent loop is a supervised state machine: user message, streamed model step,
validated tool requests, policy/approval decision, owned tool operations, ordered
results, next model step, and a durable terminal outcome. It preserves pause,
continue, steer, cancellation and scoped child ownership. Unknown tools and invalid
arguments produce model-visible errors without execution. Context limits, retries,
turn limits and usage budgets terminate truthfully.

Initial repository tools are list/read/search/write/edit and shell/test execution.
All path tools enforce the selected project root; mutation tools preserve exact
edit preconditions. Shell commands are explicit shell tool input, have bounded
output/deadlines, stream progress and own descendant cleanup. Tool permissions
are enforced by the daemon and can block for a correlated user approval; the
client never grants itself permissions. Git/worktrees/checkpoints, attachments,
MCP, memory and web tools extend this same registry and ownership model.

## Persistence and service handoff

Do not turn the current Ready struct into authority by reopening its pathname.
The guarded exact-object, one-use Foundation-to-Repo predecessor remains required
for production canonical writes. Keep the verified complete SourceSnapshot probe;
never put private SHM beside live main/WAL. Establish daemon-owned supervision and
lease lifetime, guarded initial/replacement connections, atomic run/message
transitions, restart recovery and migrations/new-database startup. The desktop
checkout and daily database remain untouched during development.

Provider/tool/agent components may be implemented and tested before Repo promotion,
but their temporary test stores do not count as persistence or production startup.
This is sequencing within the full goal, not a substitute architecture.

A bounded local service connects the daemon to the existing client DataSource
behavior using core contracts. Daemon events carry scope, instance epoch,
revision/sequence and request correlation. Queries page data; disconnect cancels
view-owned requests while daemon-owned coding runs continue. Reconnect resnapshots;
commands use durable request identity and truthful unknown-outcome handling.

## Product and completion

The primary executable must open a project, configure/select a provider and model,
create/resume a conversation, submit a coding task, show real streamed text and
tool output, obtain approvals, edit files, execute tests, show changes, stop/pause/
steer a run, and reopen saved sessions. Plain/headless entrypoints use the same
service. Built artifacts include required runtimes and do not require Mix.

Complete desktop coverage additionally includes six modes (Build, Plan, Goal,
Ultra, Workflow, Consensus), subagents, research, schedules, settings/usage/budgets,
MCP, attachments, memory, custom commands and Git recovery. These remain tracked
until real behavior is verified; unsupported actions must be hidden or refuse
honestly rather than mutate fake state.

Meaningful acceptance uses a disposable real repository and a local scripted HTTP
provider that asks the actual runtime to inspect/edit code and run an actual test
command. It must verify resulting filesystem changes, streamed TUI output,
approval/cancel behavior, persisted restart and client detach/reconnect. Live API
acceptance is separate evidence. Native terminal PTY and all supported platform
release checks remain required. Browser smoke tests, when applicable, use ego-lite
and close only the task space, never sessions/cookies.
