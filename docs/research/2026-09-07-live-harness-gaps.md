# Live TUI coding harness: current gaps

Checked against the CLI checkout on 2026-09-07, committed baseline `a691531`
plus the current uncommitted native lease and client facade work.

There is no supported command that starts a saved, live coding session yet.
The interactive terminal executable uses scripted conversations and run events.
It demonstrates navigation, editing, rendering and controls; it does not send a
user's prompt to the working provider/tool engine. A full coding harness remains
the delivery requirement.

## What is implemented

- OpenAI-compatible and Anthropic HTTP streaming, including cancellation and
  bounded provider output.
- Six actual coding tools: list, read, search, write, exact edit and shell command.
- A supervised run loop with tool approvals, pause, continue, steer and stop;
  acknowledged event boundaries and actual run/operation identities.
- TUI and plain presentation, editor, navigation, approval arguments, long detail
  paging, reasoning display and terminal restoration.
- Schema/backup admission, a source-built SQLite fork, native directory/lease
  ownership and pure client request/response/watch codecs.

The backend has been exercised with local HTTP providers, temporary repositories
and real shell commands. This is component/integration evidence, not a live API
or complete product acceptance result. See the existing
[backend](2026-09-06-live-backend-checkpoint.md),
[run sink](2026-09-07-canonical-sink-checkpoint.md) and
[directory/codec](2026-09-07-directories-codec-checkpoint.md) checkpoints.

## What prevents normal use

| Area | Remaining work | User-visible completion condition |
|---|---|---|
| Launch and first use | Production entrypoint, daemon startup, platform admission, provider credentials, model/effort selection, project and session creation | One command opens the TUI; select a repository and configured model, then send a prompt |
| Live TUI connection | Local service, socket adapter, bounded delivery acknowledged after UI consumption, real composer and control wiring | The prompt runs the real engine and streams actual text, reasoning, tool output and approvals into the terminal |
| Durable storage | Guarded application database/WAL/SHM binding, initial/replacement pool admission, additive migrations, transactional event sink and command identity | Conversations, messages, tool outcomes and approvals are saved; duplicate requests cannot repeat a mutation |
| Detach and recovery | Durable reconnect/resnapshot, interrupted-run reconciliation, stale approval handling, missing-worker settlement | Close/reopen the terminal without losing history or duplicating tools; daemon restart reports interrupted work truthfully |
| Daily coding workflow | Project/conversation management, history search, edit/resend/fork/compact, Git diff/status, worktrees, checkpoints and recovery, attachments, memory and custom commands | Work through a real repository task, inspect changes and recover prior work from the TUI |
| Execution capabilities | Build, Plan, Goal, Ultra, Workflow and Consensus semantics; child agents and scoped controls; MCP; research with sources/reports; durable schedules | Each advertised mode and integration executes real work with owned cancellation and persisted outcomes |
| Settings and accounting | General, Deep research, Appearance, Providers & models, Pricing, MCP servers, Memory, Storage, Commands, Limits and Budget; credentials and diagnostics | Settings affect execution; usage and budget limits use recorded provider facts |
| Distribution and acceptance | Real plain/headless commands and exit codes, bundled installable release, terminal performance/input acceptance and supported-platform builds | Run the installed app outside the source checkout and complete the same coding workflow |

The native SQLite lease integration has passed focused daemon and actual-production
checks. It protects only the fixed lease database. It does not yet provide a writable
application database, an Ecto connection pool, or a service endpoint.

The current macOS desktop exclusion and shared-storage constraints also remain:
production startup must satisfy the platform gate, and concurrent desktop/CLI
operation is unsupported. Completing the launcher includes closing that admission
gap; simply bypassing the gate is not completion.

## Evidence in the current source

- `SwarmCodeCLI` has no production entrypoint, and the CLI Mix project has no
  executable/release configuration.
- `Demo.Terminal` and `Demo.Plain` explicitly construct `DataSource.Fake`.
- `Daemon.Application` starts only `ProviderCaps` and `Runtime.RunSupervisor`;
  its documentation explicitly excludes canonical storage and a service listener.
- `DataSource.Daemon.Codec` translates requests, responses and watch events; it is not a
  connected transport. The neutral `DataSource` facade is likewise not an adapter.
- `Runtime.Run` supports commit acknowledgements, but the canonical transactional
  store that must issue those acknowledgements is still to be integrated.

## Delivery order

Finish native ownership and guarded durable storage; implement the transactional
service and real client adapter; connect launcher/setup and the existing TUI;
verify a real prompt → approval → edit → test → saved result → reconnect flow.
Protocol/client work can proceed alongside the storage work using explicit test
fixtures, without claiming production persistence. Then complete the remaining
daily coding, advanced execution, settings and distribution requirements.

The [implementation plan](../superpowers/plans/2026-09-06-live-coding-harness.md)
tracks the full scope. Neither a passing component suite nor a usable first live
session closes the remaining parity and release requirements.
