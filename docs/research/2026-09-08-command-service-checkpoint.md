# Command discovery and local service checkpoint

This is an implementation checkpoint, **not full CLI parity or a production
launcher**. Work is confined to `/Users/zaali/dev/swarm-code-cli`; web source at
`fb1b4ff82354ac8ff2e82d4f6516121fd55ff212` was read only. Its pre-existing untracked
`.specs/` remains unchanged.

## Implemented

- `SwarmCode.Commands` in core defines all 16 web built-ins, the six composer
  modes, structured command parsing, workflow-name aliases/control/arguments,
  custom command expansion, precedence and ranked discovery. It never executes
  a parsed command.
- The terminal composer offers bounded slash suggestions. Up/Down choose; Tab
  completes as an undoable edit. Enter preserves the literal command for the
  dispatcher. Narrow layouts retain the caret and clip descriptions by cells.
- `SwarmCode.Commands.Files` loads project/global Markdown commands with shared
  count/byte limits, bounded reads, UTF-8/front-matter validation and confinement.
  Creation uses a private same-directory temporary file and exclusive publication.
- The daemon has an owned Unix-socket listener, nonce/capability handshake,
  bounded request workers, watch snapshots/credit, deadlines, pending-watch
  cancellation and socket-identity cleanup. It requires a caller-supplied backend
  and is not started by the application.
- The in-progress client transport is integrated with receipt consumption in the
  TUI/plain owners. Queue saturation preserves unknown outcomes for written
  commands. Local request IDs map to stable wire UUIDs across reconnections.
- Service/client integration uses an explicitly test-only backend. No production
  backend simulates a successful provider run or saved mutation.

## Verification

Final `mise exec -- mix test`, seed **195534**, exited zero:
**119 core + 433 daemon + 566 CLI = 1,118 tests**, with five properties.
Formatting and warning-free compilation passed afterward. Source provenance,
12 native schema checks and both Unicode source checks passed. The synthetic
plain demo passed. Native terminal suites passed **8 demo + 14 Port = 22** PTY
checks, including restoration and owned cleanup.

Earlier precommit runs exposed fixture timing/closure problems. The fixture
sender now accepts expected peer closure, the TUI test waits for its workspace
stream acknowledgment, and the pre-existing asynchronous canonical-command
assertion has the same two-second test allowance as its snapshot helper. Runtime
deadlines are unchanged. The final full test run above includes these fixes.
No successful *single final* precommit invocation is claimed: final tests and its
remaining formatting/compile/provenance/schema/Unicode stages were verified
separately after those test-only corrections.

Ego-lite task space **15** rendered palette cell previews at 80x24, 120x40 and
160x50. All SVGs loaded, the gallery had no horizontal overflow, and a screenshot
was inspected. `completeTaskSpace(15, {keep:false})` returned `done:true`.
No sessions, cookies or user browser data were cleared. This is visual cell
preview evidence, not provider/runtime acceptance.

## Remaining delivery work

1. Production writable store/admission, durable command idempotency/event sink,
   recovery, provider setup, launcher and live service backend. The current
   approved shared-data design requires the guarded Foundation-to-Repo handoff.
   An optional user question about independent versus shared CLI data is pending;
   no change to that storage architecture has been assumed or activated.
2. Connect real provider/tool events, transcript, approvals and controls through
   the service, then verify prompt -> edit/test -> persisted reconnect.
3. Execute all parsed slash operations, including filesystem command metadata
   delivery to the palette. A parsed command is not execution parity.
4. Full swarm/planning/goal/Ultra/consensus/workflow execution, research depths,
   sources/reports, workflow library/journal/resume, schedules, settings, budgets,
   MCP, Git/worktrees/checkpoints, attachments and memory through terminal-native
   interfaces. Existing demo scenes do not establish these capabilities.
5. Installable launcher/headless release, supported-platform artifacts and real
   configured-provider acceptance.

The September 6 full live-harness plan remains the delivery authority. Neither
this checkpoint nor passing component tests closes those outstanding tasks.
