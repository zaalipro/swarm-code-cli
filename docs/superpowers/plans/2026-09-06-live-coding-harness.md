# Live coding harness implementation plan

> Use superpowers:subagent-driven-development for independent provider/tool work
> and scoped review, then sequential integration. The user has explicitly asked
> to fill all identified gaps; continue within this checkout without routine
> approval prompts. This plan preserves the full goal across turns.

**Goal:** ship the full live coding workflow and fill the desktop runtime gaps.
**Architecture:** core contracts, daemon runtime/services, existing TUI client.
**Tech stack:** Elixir1.18.4/OTP28.4.2, pinned SQLite/Ecto, native terminal Port;
Req HTTP transport in the daemon only.
**Spec:** `docs/superpowers/specs/2026-09-06-live-coding-harness-design.md`.

## Global constraints

- Only modify this CLI checkout. Desktop current pin is fb1b4ff82354ac8ff2e82d4f6516121fd55ff212.
- Preserve current green schema/backup safety. No pathname-only canonical Repo.
- Adaptations retain current source and destination digests and MIT attribution.
- No Phoenix/desktop/web server dependency in product runtime or CLI daemon imports.
- Root coordinates Mix dependency/compile/test runs to avoid concurrent BEAM writes.
- Tests use private fixture repositories, local protocol servers and explicit owners.
- Test evidence must distinguish fixture providers, paid live APIs and native targets.

## Task 1: Real streaming provider backend

Files: daemon `lib/swarm_code/llm.ex`, `lib/swarm_code/llm/*.ex`, plain provider
configuration struct, provider tests; root daemon mix/dependencies and provenance.

Adapt the desktop OpenAI-compatible/Anthropic provider implementation and its
bounded SSE, chunks, tool-argument, effort, capability and retry behavior. Remove
Ecto provider-configuration coupling: use a validated plain configuration value
with redacted inspection. Preserve wire/continuation/cache/usage semantics.
`SwarmCode.LLM.stream(Request.t(), callback)` returns Result or explicit error.
`list_models(config)` and provider selection must function without desktop app.

- [x] Write/replay provider behavior tests RED before backend extraction.
- [x] Implement actual transport and configuration, no fake production adapter.
- [x] Test chunked real loopback HTTP SSE, malformed/truncated streams, tool args,
  authentication/rate failures, redirect credential protection and cancellation.
- [x] Review and record source/destination provenance; root dependency integration.

## Task 2: Coding tool registry and owned operations

Files: daemon `lib/swarm_code/tools/*.ex`, tool registry, operation supervisor;
focused temporary-project tests. Independent of provider internals.

Tool behavior: name/description/JSON parameters/permission/title and
`run(args, %{project_root: root, ...}, progress) -> {:ok, text}|{:error, text}`.
Preserve exact-edit preconditions and path confinement. Registry invokes only
closed installed tools. Implement read/list/search/write/edit first; shell tool
uses owned process cancellation/deadline/output and deterministic result ordering.

- [x] RED tests perform actual fixture read/search/edit and reject root escapes,
  ambiguous edits and malformed arguments; no mutation on refusal.
- [x] Adapt tool implementations with provenance, remove desktop UI dependencies.
- [x] Verify shell command/test execution, bounded output, timeout and stop cleanup.
- [x] Review scoped tool implementation and operation ownership.

## Task 3: Live agent/run engine

Files: daemon `engine/*`, core runtime request/event/result contracts and tests.
Consumes the real provider/backend and tool registry. A supervised run owns
model/tool operations, approvals and child agents. No slow IO in state callbacks.

- [x] RED integration sends a prompt through actual loopback provider, receives
  read/edit/run_command requests, executes them, and returns final model output.
- [ ] Implement streamed events, ordered tool results, turn/context/usage limits,
  policy questions, pause/continue/steer and structural stop.
- [x] Verify actual project changes/test exit status, refusal and cancellation.

## Task 4: Production ownership and persistence

Files: guarded Exqlite/Repo handoff, foundation supervision, daemon persistence
contexts and migrations/recovery. Reconcile the existing residual design with
SourceSnapshot; preserve the exact-object writable-open gate.

- [x] Prove pinned native descriptor/Exqlite/Ecto feasibility in one SQLite image.
- [ ] Supervise lease/binding/Repo and guard initial/replacement connections.
- [ ] Implement current-schema new-store/migrations and durable conversations,
  messages/runs, command admission/idempotency, terminal settlement and recovery.
- [ ] Verify restart persistence and daemon-owned runs surviving client detach.

## Task 5: Service, TUI and executable

Files: core wire contracts, daemon local listener, CLI DataSource adapter,
production launcher/settings flow and terminal integration.

- [ ] Build bounded query/command/event service with peer identity and correlation.
- [ ] Replace production data source with the real service; keep demos explicitly demos.
- [ ] Real provider/model/project/session selection, composer dispatch, transcript,
  tool output, questions/approvals, changes, cancellation and reconnect.
- [ ] Run end-to-end real tool/filesystem/provider transport through terminal PTY.

## Task 6: Full desktop capabilities and distribution

- [ ] Git/worktrees/checkpoints/recovery, attachments, memory and custom commands.
- [ ] All six execution modes, subagents, MCP, research and durable schedules.
- [ ] Full settings, usage/pricing/budgets, credentials and diagnostics.
- [ ] Plain/headless commands, installable bundled release and platform acceptance.
- [ ] Live API smoke with configured credentials; scope evidence honestly.
- [ ] Final requirement-by-requirement audit of all gaps, not just passing tests.

## Execution record

Each task has its own failing/passing evidence and review. The runtime is not
complete after any single task. More detailed task briefs are written from the
actual interfaces before dispatch; this plan is the persistent full-scope ledger.


## Verified backend checkpoint

Full precommit seed774991 passed972tests/fiveproperties/12nativechecks and
production compile passed. See `docs/research/2026-09-06-live-backend-checkpoint.md`.
Task3 already executes realmodel/tool operations in tests; durable event/admission,
usage budgets and child-agent behavior remain. Task4 now selects the reviewed
source-built Exqlite fork; its exact-descriptor API is still limited to read-only
development/test fixtures and refuses in production. A closed 12-operation core
service request codec is implemented, but there is no service transport yet.
Full precommit seed126450 passed984tests/fiveproperties/12nativechecks, including
the fork integration and service codec; production compilation also passed.
Writable guarded storage, reliable Run persistence, and Tasks5/6 remain open.
The full goal is unchanged.

The next checkpoint adds daemon process ownership, asynchronous acknowledged Run
events, actual operation identities, full outcomes and client approval/reasoning
details. Full precommit seed259396 passed1016tests/fiveproperties/12nativechecks;
production compilation/boot and eight terminal-demo PTY checks passed. See
`docs/research/2026-09-07-canonical-sink-checkpoint.md`. Writable persistence,
transactional producer/command admission, service/adapter and the complete
advanced/release scope still remain; passing event-sink tests does not close them.
