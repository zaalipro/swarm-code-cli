# CLI Parity Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Turn the CLI from a synthetic TUI demo into a usable terminal client with real local daemon connectivity, web-compatible slash commands, and terminal-native access to the major web capabilities.

**Architecture:** Keep the renderer/reducer and typed `DataSource` boundary in the CLI. Finish the daemon socket transport and production launcher first, then add a canonical slash-command dispatcher that maps to typed requests. Add terminal-native pages for workflows, research, schedules, history, settings, and changes without importing Phoenix or mutating the web checkout.

**Tech Stack:** Elixir 1.18, OTP 28, umbrella Mix, Jason, Ecto/SQLite in daemon, native terminal Port, existing renderer-neutral Scene pipeline.

**Spec:** `docs/superpowers/specs/2026-09-06-live-coding-harness-design.md`

## Global Constraints

- Modify only `/Users/zaali/dev/swarm-code-cli`.
- Do not import Phoenix, LiveView, Desktop, or the web repository at runtime.
- Preserve existing guarded storage, protocol bounds, ownership, and safe-text rules.
- Never wipe user databases, ego-lite sessions, cookies, local storage, or browser data.
- Use deterministic fixture providers and disposable repositories for tests.

### Task 1: Production service connection

**Files:**
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/daemon.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/service.ex`
- Create: `apps/swarm_code_daemon/lib/swarm_code/daemon/service/request_router.ex`
- Test: `apps/swarm_code_cli/test/swarm_code_cli/ui/data_source/daemon_integration_test.exs`

- [ ] Add a supervised Unix-domain listener with hello handshake, bounded frames, request correlation, watch snapshots/deltas, and acknowledgement receipts.
- [ ] Route `query`, `detail`, `dispatch`, run controls, steering, and approval resolution through typed request validation.
- [ ] Add loopback integration tests that start the daemon, bind a client, dispatch a prompt, receive ordered events, and reconnect with a fresh snapshot.
- [ ] Run the focused daemon/client test files and the formatter.

### Task 2: CLI launcher and real session wiring

**Files:**
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/application.ex`
- Create: `apps/swarm_code_cli/lib/mix/tasks/swarm_code.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/init.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/session_runtime.ex`
- Test: `apps/swarm_code_cli/test/swarm_code_cli/launcher_test.exs`

- [ ] Add a production command that validates TTY/options, starts the daemon and terminal owner under supervision, and selects a project/session.
- [ ] Replace the production fake source with `DataSource.Daemon`; keep `swarm_code.demo.*` explicitly synthetic.
- [ ] Add clean detach/reconnect and signal restoration tests.

### Task 3: Slash command parity

**Files:**
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/commands.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/plain/command.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/keymap.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/reducer/commands.ex`
- Test: `apps/swarm_code_cli/test/swarm_code_cli/commands_test.exs`

- [ ] Port built-in command metadata and prefix/word-boundary ranking for `/swarm`, `/goal`, `/plan`, `/review`, `/effort`, `/swarm_effort`, `/rewind`, `/stop`, `/resume`, `/workflow`, `/workflows`, `/create-workflow`, `/ultra`, `/consensus`, `/deep_research`, and `/compact`.
- [ ] Add custom project/global Markdown command loading, `$ARGUMENTS` expansion, workflow-name precedence, and safe unknown-command diagnostics.
- [ ] Map each command to an explicit typed intent; never atomize user input.
- [ ] Add conformance tests for every built-in command and precedence rule.

### Task 4: Feature pages and controls

**Files:**
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/page_state.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/reducer/pages.ex`
- Modify: `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/library.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/settings.ex`
- Create: `apps/swarm_code_cli/lib/swarm_code_cli/ui/projector/research.ex`
- Test: `apps/swarm_code_cli/test/swarm_code_cli/ui/pages_parity_test.exs`

- [ ] Add terminal pages for Chats, Scheduled, Workflows, Deep Research, Usage, and Settings with responsive tab fallback.
- [ ] Add workflow library/run controls, research depth/source/report controls, schedule list/manual run, usage/budget summary, and settings diagnostics.
- [ ] Reuse typed daemon queries/commands and preserve bounded paging.

### Task 5: End-to-end acceptance and docs

**Files:**
- Create: `apps/swarm_code_cli/test/swarm_code_cli/live_vertical_slice_test.exs`
- Modify: `README.md`
- Create: `scripts/dev/smoke_cli.sh`

- [ ] Verify disposable repo flow: prompt → provider stream → tool approval → edit/test → final outcome → reconnect.
- [ ] Verify all six modes, swarm controls, planning, workflows, deep research, and slash commands through typed requests.
- [ ] Run `mise exec -- mix precommit`, terminal PTY suites, and the ego-lite browser smoke test against the CLI’s local status/help page if applicable.
- [ ] Close only the dedicated ego-lite task space after smoke testing.

## Execution checkpoint

See `docs/research/2026-09-08-command-service-checkpoint.md` for exact verified
changes and remaining work. Command parsing/discovery and listener/transport
components are implemented; Tasks 1–5 are not complete end-to-end. The existing
shared-storage architecture remains in force pending the data-choice reply.
