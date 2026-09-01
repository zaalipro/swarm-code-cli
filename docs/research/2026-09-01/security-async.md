# SwarmCode CLI/TUI — security, lifecycle, persistence, and asynchronous-runtime research

**Date:** 2026-09-01  
**Scope:** read-only analysis of `/Users/zaali/dev/swarm-code`; no repository was changed.  
**Target:** a local-first Elixir/OTP CLI/TUI for macOS and Ubuntu with semantic parity for chat,
goal, plan, swarm, consensus, Ultra, deep research, compact, workflows, slash commands,
approvals, MCP, tools, scheduling, history, and asynchronous multi-run operation.

## Executive decision brief

The safest architecture is **one non-distributed OTP core per data directory, with every unit of
work in an explicit supervision subtree and a terminal renderer that never receives raw external
bytes**. An interactive TUI can run in the same foreground release initially. If “work continues
after the terminal disconnects” is required, add an explicit local daemon later and connect through
a mode-`0600` Unix socket authenticated with OS peer credentials; do not turn on distributed Erlang,
EPMD, a localhost HTTP API, or an implicit background service.

The CLI must **not open the desktop application's SQLite file in read/write mode**. The two products
have separate process registries, boot reconciliation, schedulers, migrations, and secret models.
WAL makes same-machine readers and a writer coexist, but it does not make those higher-level owners
coherent. Use a separate CLI database and an explicit, manifest-verified import made from SQLite's
online backup API. Imported active work is interrupted, imported schedules and MCP servers are
disabled pending review, and plaintext desktop credentials are moved directly into the OS secret
store rather than copied into the CLI database.

The highest-risk deltas from the web application are:

1. **Terminal control injection.** Model text, repo filenames, Git output, command output, MCP
   metadata/results, URLs, and logs are all attacker-controlled. They must become styled text spans;
   raw bytes must never be concatenated to terminal output. OSC 52 clipboard, OSC 8 hyperlinks,
   DCS/APC/PM, CSI, C0/C1 controls, carriage return, backspace, and bidi/zero-width deception need
   explicit policy.
2. **Model-authored Elixir workflows.** The current app evaluates validated source with
   `Code.eval_quoted/3` inside the main VM and limits a task heap. That is not an isolation boundary:
   parsing creates atoms and a process heap limit does not cap every VM-global/off-heap resource.
   Preserve Elixir workflows by executing them in a disposable, non-distributed child BEAM that can
   communicate only with a capability-checking JSON broker.
3. **MCP trust.** Stdio startup commands are arbitrary executables, MCP annotations are untrusted,
   and HTTP/stdio collectors need generations, caller monitors, absolute deadlines, bounded queues,
   bounded frames, and owner-mediated settlement. Never auto-start MCP definitions imported from a
   database. Never use `readOnlyHint` to bypass approval unless the user explicitly trusts that
   server/tool policy; the MCP specification says annotations are hints and must be treated as
   untrusted.
4. **Credential storage.** The current schemas persist provider, search, and MCP secrets in SQLite.
   The CLI should store only opaque references: Keychain Services on macOS, Secret Service/libsecret
   on Linux, an in-memory adapter in tests, and environment/session-only input when a headless Linux
   secret service is unavailable. Do not silently fall back to a plaintext file.
5. **SSRF and host execution.** `web_fetch` must keep localhost/private use possible, but through a
   distinct network permission and a resolver/connector that revalidates and pins every DNS answer
   and redirect. Shell tools are arbitrary host execution, not a project sandbox. Path checks must
   be descriptor-relative at the operation itself, not check-a-string then use-a-string.

These are release blockers, not polish items.

---

## 1. What parity means at the security boundary

Parity should be defined as **domain behavior and persisted semantics**, not reuse of every current
implementation detail. Required invariants include:

- multiple chat, swarm, workflow, research, compact, scheduled, and consensus runs remain live while
  the user navigates elsewhere;
- `pause` holds before the next step, `continue` releases held work, and `stop` cancels descendants,
  settles questions/approvals/waiters once, and writes a truthful terminal state;
- plan mode never receives mutation tools; an approved plan becomes a separately linked
  implementation run; command-owned modes cannot inherit stale consensus/workflow state;
- workflow panels preserve input order, budget accounting, replay fingerprints, gate state, and
  `nil`/failure semantics without unbounded fan-out;
- provider stream retry resets failed text/reasoning attempts rather than appending them;
- contracted tool output, assistant text, reasoning, tool arguments, journals, costs, and transcript
  order remain exact; only duplicated/derived/queued state may be bounded or evicted;
- “needs you” questions and approvals remain correlated to one run/node and never migrate to the
  currently viewed conversation;
- explicit cleanup/retention previews remain non-destructive until confirmed, and running/open work
  is rechecked at execution time.

The source application already encodes many of these rules:

- one `RunServer` owns a run's node tree and coalesces broadcasts at 100 ms
  (`lib/swarm_code/engine/run_server.ex:1-10,23-31`);
- `RunSup` is `one_for_all` and shuts down when its significant `RunServer` ends, while each agent has
  an operation `Task.Supervisor` and a significant `AgentServer`
  (`lib/swarm_code/engine/run_sup.ex:17-29`, `lib/swarm_code/engine/agent_sup.ex:17-29`);
- stop settles pending approvals/questions once and clears the queue before agent teardown
  (`lib/swarm_code/engine/run_server.ex:2441-2490`);
- workflow panels bound enumeration and concurrency and preserve order
  (`lib/swarm_code/workflows/api.ex:131-215`);
- stream assembly uses chunk lists and coalesced flushes rather than per-token materialization
  (`lib/swarm_code/llm/chunks.ex`, `lib/swarm_code/engine/run_server.ex:1503-1655`);
- the current web renderer sanitizes raw HTML and unsafe URL schemes before marking Markdown safe
  (`lib/swarm_code_web/components/markdown.ex:63-84,103-161`).

The clone should carry these contracts forward while correcting the gaps identified below.

---

## 2. Threat model

### 2.1 Assets

1. **User work:** project files, Git index/refs/worktrees, commits, attachments, checkpoints,
   workflows, commands, skills, research reports, and memory.
2. **Conversation integrity:** exact prompts, messages, reasoning, tool calls/results, run trees,
   approvals, answers, journals, schedules, usage, and cost.
3. **Credentials:** provider/search keys, MCP headers/environment, session tokens, Git/SSH agent
   access, clipboard contents, and secrets inherited in the launcher environment.
4. **Host integrity and availability:** the user's account, filesystem, processes, terminal,
   network position, atom table, BEAM schedulers/heaps, disk, and provider budget.
5. **Human intent:** what operation was actually shown and approved, for which project/run and with
   which exact arguments.

### 2.2 Untrusted inputs

Treat all of the following as hostile even in a local-first app:

- model text, reasoning, tool names, JSON arguments, workflow source, proposed commands, branch names,
  and labels;
- project files and metadata, including `AGENTS.md`, command/skill/workflow files, symlinks, filenames,
  Git refs/config/hooks/filters, diffs, commit messages, and command stdout/stderr;
- web bodies, URLs, redirects, DNS answers, compressed content, search/reader results, and prompt
  injection in those results;
- MCP configuration, executable path/args, tool schemas, annotations, cursors, notifications,
  stdout/stderr, HTTP headers, session IDs, and tool results;
- imported SQLite rows and legacy paths/MIME values;
- terminal input, bracketed paste payloads, resize/suspend/hangup events, terminal capability claims,
  and remote SSH/tmux behavior;
- environment variables and `PATH`; they are configuration, not proof of provenance.

The model is not a principal and cannot grant authority. Prompt instructions, “read-only” tool
descriptions, and MCP annotations are advisory data. Every effect is authorized at the broker that
performs the effect.

### 2.3 Adversaries and failure sources

- a malicious or prompt-injected model/provider response;
- a malicious repository, dependency, Git hook/filter, MCP server/package, web page, or imported
  desktop configuration;
- an accidental race between parallel model tool calls (for example, `run_command` swapping a
  symlink while `write_file` is validating it);
- a compromised process under the same user account;
- crashes, forced kills, SSH disconnects, laptop sleep/wake, disk-full/read-only filesystems,
  SQLite contention/corruption, network partitions, and reordered/late messages.

### 2.4 Explicit non-goals

- No local application can protect secrets from root or a fully compromised same-UID account.
- `run_command` and user-approved stdio MCP servers are not OS sandboxes. They can read the account
  and use the network unless a separately designed sandbox is enabled.
- Escaping terminal controls prevents display execution/spoofing; it does not make prompt-injected
  text trustworthy to the model.
- Exactly-once arbitrary external side effects are impossible across a crash unless the remote tool
  accepts an idempotency key. The honest state after an ambiguous timeout is `unknown / review
  required`, not an automatic retry.

---

## 3. Recommended runtime and ownership model

### 3.1 Process topology

Use a single local BEAM node and no Erlang distribution. Erlang's own documentation states that node
cookies are not cryptographically strong security and ordinary distribution is clear text; avoiding
distribution is the correct default for a local CLI [R15]. A Mix release can include ERTS by default,
so Ubuntu/macOS users need no system Erlang or Elixir [R16].

```text
SwarmCli.Supervisor (rest_for_one)
├─ DataDirGuard                    # exclusive instance/migration lock
├─ RepoSupervisor                 # read pool + serialized writer
├─ CredentialBroker               # Keychain / Secret Service / memory
├─ Bootstrap                      # migrate → verify → reconcile → activate
└─ RuntimeSupervisor
   ├─ EventHub                    # scoped, sequenced, byte-bounded subscriptions
   ├─ MCP.Supervisor              # one client/connection generation per approved server
   ├─ RunSupervisor               # one RunSup per run
   │  └─ RunSup (one_for_all, temporary)
   │     ├─ RunServer             # canonical state owner, no blocking I/O
   │     ├─ RunJobSupervisor      # DB/Git/prep/finalization work owned by this run
   │     └─ AgentsSupervisor
   │        └─ AgentSup (one_for_all)
   │           ├─ AgentServer
   │           └─ OperationSupervisor
   ├─ WorkflowSandboxSupervisor   # disposable child BEAMs + broker sessions
   ├─ ResearchSupervisor
   └─ Scheduler

TerminalSessionSupervisor          # foreground/client-side; never owns engine work
├─ TerminalOwner                   # raw mode, alt screen, input decoder, cleanup
├─ Projection                     # current scope + snapshot/event revision
└─ Renderer                        # trusted spans → terminal sequences
```

`rest_for_one` around bootstrap/runtime prevents the scheduler, MCP startup, TUI, or optional daemon
socket from accepting work before migration and recovery complete. The current app correctly orders
Repo/migrator, PubSub/registries, supervisors, and `Bootstrap` before watchdog/scheduler/endpoint
(`lib/swarm_code/application.ex:15-50`), and `Bootstrap` retries and reconciles interrupted work before
activating new work (`lib/swarm_code/bootstrap.ex:15-56,134-171`). Keep that property.

### 3.2 Hard ownership rules

1. Every task, port, socket, timer, monitor, queue entry, spill file, and subscriber has exactly one
   owner and one settlement path.
2. A state owner (`RunServer`, `AgentServer`, MCP client, scheduler, terminal projection) performs no
   filesystem, Git, network, secret-store, external command, long database, or terminal-render work
   in a callback. It starts monitored work, stores `{generation, request_ref, monitor, deadline}`, and
   applies only an exact matching result.
3. Workers never call `GenServer.reply/2` directly. They send a result to the owner; the owner cancels
   timers/monitors and replies once. This prevents a dead caller, reconnect, or replacement from being
   answered by an obsolete task.
4. Cancellation invalidates the generation first, clears/freeze queues second, signals children
   third, and settles callers from the owner. Slow cleanup never blocks the control call.
5. A child may not schedule cleanup under a global fire-and-forget supervisor. Cleanup belongs to
   the run/repo owner and survives only as long as its explicit durable cleanup intent. The current
   app still starts some worktree cleanup and notification tasks globally without tracking them
   (`lib/swarm_code/engine/run_server.ex:2141-2195,2493-2509`); do not copy that pattern.
6. Parent/child slots are leases. A parent parked in `await_agent` yields its slot; teardown clears
   queued leases before releasing active ones.
7. All deadlines are absolute monotonic deadlines from admission, not a fresh timeout for DNS,
   redirect, MCP page, queue wait, retry, or body read. Wall clock is used only for persisted user
   timestamps. Sleep/wake behavior must be specified and tested.

Elixir recommends supervised tasks because they expose counts and make result/error/timeout handling
explicit [R14]. The source app's MCP HTTP path is an example not to preserve: it starts a global task
that calls `GenServer.reply/2` itself and is not recorded in client state
(`lib/swarm_code/mcp/client.ex:288-315`).

### 3.3 Stop, pause, detach, and shutdown

| action | required semantics |
|---|---|
| **Pause** | Admit no new agent/tool/LLM step. Let the current indivisible step settle, then hold. Persist `paused`; do not kill work silently. |
| **Stop run/agent** | Invalidate generations, freeze/remove its queue, deny approvals, fail questions/waiters as stopped, cancel HTTP/tasks/ports/process groups, persist node/run terminal state, then end its subtree. |
| **TUI navigation** | Cancel only view-owned work and subscriptions. Engine work continues. Drop late view results by full scope identity. |
| **TUI detach** | In foreground-only v1, ask before stopping active work. With an explicit daemon, detach only the terminal session; runs remain daemon-owned. |
| **Daemon/application quit** | Stop admission/scheduler, settle or pause workflows by contract, stop run/research/MCP subtrees, checkpoint/flush, restore terminal clients, close DB, then exit within a documented bound. |
| **SIGTSTP/SIGCONT** | Restore cooked mode and leave alternate screen before suspension; re-enter, re-detect size/capabilities, and redraw from a snapshot on continue. |
| **SIGHUP/SSH loss** | Foreground mode performs bounded stop/recovery. Daemon mode closes only the session socket and keeps work. Never leave a raw terminal or orphan OS tree. |

The source app distinguishes pause from stop and handles runner loss, pending interaction settlement,
and crash state (`lib/swarm_code/engine/run_server.ex:629-655,803-870,1190-1295`;
`lib/swarm_code/workflows/runner.ex:451-510`). Preserve the semantics, not its synchronous DB calls.

### 3.4 Streaming and backpressure

Canonical data must never be dropped because a terminal is slow.

- Accumulate LLM text/reasoning/tool arguments as iodata/chunk deques. Materialize only for a bounded
  persistence/render flush (50–100 ms) and once at finalization.
- Give every stream an `attempt_id`, channel, and monotonic byte offset. A retry marks the old attempt
  superseded and emits exactly one text reset and one reasoning reset before new deltas.
- Persist final contracted bytes. If crash-visible partial output is a requirement, spool sequenced
  chunks to a mode-`0600` run-owned file/table and mark them partial; never put partial failed-attempt
  text into resumed model history.
- Bound every queue by both count and bytes: model tool calls per turn, queued agents, workflow panel
  enumeration, MCP session-establishment calls, UI events, pending clipboard data, and external
  stdout/stderr. Refuse admission with a visible backpressure error; do not silently drop.
- A TUI subscriber receives `{scope, revision, seq, event}`. On a sequence gap or byte budget breach,
  EventHub replaces only derived pending events with `snapshot_required`; canonical state remains in
  the owner/DB. The client reloads a projection at `revision` and resumes. Never PubSub per token.
- Coalesce render invalidations, not semantic event order. A hidden/detached session receives no
  render ticks.
- External collectors enforce limits while reading. A final 100 kB tool contract must not first
  accumulate 1 GB. Track compressed and decompressed bytes to stop compression bombs.

The current command collector's fixed head/tail and process-tree cleanup are useful patterns
(`lib/swarm_code/tools/run_command.ex:133-249`). Its MCP line buffer (`state.buffer <> data` followed
by `String.split`) is not (`lib/swarm_code/mcp/client.ex:138-154,631-662`).

---

## 4. SQLite, data directories, migrations, and desktop interoperability

### 4.1 Do not share the live desktop database

SQLite WAL permits concurrent readers and a writer on one machine, but only one writer at a time;
WAL also requires all readers to be on the same machine and is unsuitable for a network filesystem
[R2]. That does **not** solve application-level ownership:

- each BEAM has a separate `Registry`, so each sees the other product's live rows as ownerless;
- desktop bootstrap globally marks interrupted runs and reconciles schedules; the CLI would do the
  same to desktop-owned work;
- both schedulers could fire automation, and uniqueness only deduplicates some occurrence shapes;
- migrations, cleanup/VACUUM, MCP auto-start, settings broadcasts, and per-window state are not a
  cross-process protocol;
- current database rows contain plaintext credentials, while the CLI should not.

Therefore:

1. the CLI has its own database and application identity;
2. it never honors the desktop `DATABASE_PATH` variable implicitly;
3. `--data-dir` and `SWARM_CODE_CLI_HOME` must point to a CLI-owned directory, refuse symlinked or
   insecure ownership/mode, and acquire an exclusive instance/migration lock;
4. any advanced `--desktop-db` mode is read-only inspection/import, never normal operation.

### 4.2 Directory layout

Use platform conventions and split durable data, user-authored configuration, state/logs, cache, and
runtime files. The XDG Base Directory specification defines the Linux locations and requires
`XDG_RUNTIME_DIR` to be user-owned, mode `0700`, and login-lifetime [R1].

| purpose | macOS | Ubuntu/Linux |
|---|---|---|
| durable DB, attachments, research | `~/Library/Application Support/SwarmCodeCLI/` | `${XDG_DATA_HOME:-~/.local/share}/swarm-code-cli/` |
| global commands/workflows/skills/config | `~/Library/Application Support/SwarmCodeCLI/config/` | `${XDG_CONFIG_HOME:-~/.config}/swarm-code-cli/` |
| logs/diagnostic state | `~/Library/Logs/SwarmCodeCLI/` | `${XDG_STATE_HOME:-~/.local/state}/swarm-code-cli/` |
| recreatable caches | `~/Library/Caches/com.zaalipro.swarm-code-cli/` | `${XDG_CACHE_HOME:-~/.cache}/swarm-code-cli/` |
| daemon socket/locks | per-user `$TMPDIR/swarm-code-cli/` | `$XDG_RUNTIME_DIR/swarm-code-cli/` |

Set umask `077`; directories `0700`; DB, WAL, SHM, logs, manifests, backups, spill files, and sockets
`0600`. Recheck sidecars after each connection creates them. The current `Repo` already hardens its
SQLite files/sidecars and publishes a newly created DB securely (`lib/swarm_code/repo.ex:6-58`;
`test/swarm_code/repo_permissions_test.exs:8-46`).

Project-authored artifacts may retain the interoperable `.swarm_code/{MEMORY.md,commands,skills,
workflows,specs}` format, but writes need atomic compare-and-swap/locking because desktop and CLI can
touch the same project. Put transient worktrees under a product/run-specific subdirectory, for
example `.swarm_code/worktrees/cli/<run>/<agent>`, and validate exact ownership before cleanup.

### 4.3 Connection and writer policy

- Pin and report the bundled SQLite source ID. **Require SQLite >= 3.51.3**: SQLite's official release
  history says 3.51.3 fixed the WAL-reset corruption bug [R5]. The currently checked-out desktop
  dependency embeds SQLite 3.53.3 (`deps/exqlite/c_src/sqlite3.h:149-151`).
- `foreign_keys=ON` on every connection; WAL only on local filesystems; `busy_timeout`; small bounded
  read pool; one serialized domain writer using `BEGIN IMMEDIATE` for read-then-write allocation.
- Prefer `synchronous=FULL` for launch/message/journal durability until benchmarks justify a weaker
  documented contract. A speed mode must say it can lose recently acknowledged commits after power
  loss.
- Assign message positions, display names, schedule occurrences, and terminal messages with database
  constraints plus conflict retry, never `count + 1` outside a write transaction. The current app's
  immediate transaction and unique `(conversation_id, position)` pattern is a useful baseline
  (`lib/swarm_code/conversations.ex:576-615`).
- Keep database work out of `RunServer`. The domain writer returns a correlated result; control calls
  remain responsive during contention.
- On `SQLITE_FULL`, corruption, or failed migration, stop new work and enter inspectable read-only
  recovery. Never reset or recreate automatically.

### 4.4 Atomic launch and terminal state

Process startup and a SQLite transaction cannot be one atomic primitive. Use an idempotent state
machine:

1. resolve project/model/policy/context before launch writes;
2. in one `BEGIN IMMEDIATE` transaction create the user message (if any), assistant placeholder,
   run, goal link, and a unique launch intent in `starting` state; emit no event before commit;
3. start the supervised owner with the launch ID and wait for registry/owner acknowledgment;
4. transition `starting → running` by compare-and-set and emit committed events in sequence;
5. if owner admission fails, one idempotent compensation transaction marks the run failed, updates
   the existing placeholder once, pauses the linked goal, and closes the intent;
6. bootstrap reconciles any `starting` or live status without an owner lease into an inspectable
   interrupted/failed state.

Likewise, terminal transitions are compare-and-set and have a unique terminal-message key. The
current `Engine.start_chat_turn` still performs several separately broadcasting writes before
`start_run/1`, then compensates owner-start failure (`lib/swarm_code/engine.ex:65-179,558-665`). A
new codebase should implement the stronger atomic graph described in current spec 31 requirements
(`.specs/31_surgical_correctness_and_efficiency_spec.md:20-43`) rather than porting that sequence.

### 4.5 Migration gates

Use `PRAGMA application_id`, an internal schema semantic version, and Ecto migrations. Never infer
compatibility merely because table names exist.

Before any destructive rebuild/backfill:

1. acquire the exclusive data-dir lock and stop runtime work;
2. make a consistent online backup (not a raw `.db` copy while WAL is live). SQLite's online backup
   API guarantees a consistent completed snapshot even while the source is updated [R3];
3. write a mode-`0600` manifest with app/schema/source IDs, SQLite source ID, sizes, SHA-256, row
   counts, `quick_check`, and `foreign_key_check` results;
4. open the backup at a new path, verify checks and representative reads, then fsync backup and
   containing directory;
5. quarantine every changed legacy row losslessly before enforcing a new constraint;
6. run migration transactionally where SQLite permits; make backfills resumable/idempotent;
7. rerun integrity/FK/count/checksum equations and a cold boot;
8. leave the backup until the user has run the new version successfully.

`quick_check` does not include all referential validation; run `foreign_key_check` separately. The
current orphan repair demonstrates `VACUUM INTO`, SHA-256 manifesting, mode hardening, and independent
read-only verification (`lib/mix/tasks/swarm_code.repair_orphans.ex:80-149`).

### 4.6 Desktop import contract

Provide `swarm import desktop` only as an explicit command:

1. discover the macOS desktop source (`~/Library/Application Support/SwarmCode/swarm_code.db`) but do
   not mutate it;
2. inspect source migration set/schema hash; refuse an unknown newer schema;
3. use online backup to a temporary mode-`0600` source snapshot and verify it;
4. import into a new/empty CLI DB in one logical batch, preserving UUIDs and UTC microsecond times;
5. derive attachment filenames/MIME from validated UUID/file content, never stored legacy paths;
6. copy project/global commands, workflows, skills, memory, attachments, and research through
   confined relative-path manifests and checksums;
7. mark `running/queued/claimed` work interrupted. Do not automatically replay external effects;
8. import schedules disabled, retention disabled, and MCP servers disabled/untrusted. Require the
   user to review executable, args, cwd, env keys, headers, URL, and project scope before enabling;
9. move provider/search/MCP secret values directly to the CLI credential adapter, read back for
   equality, write only refs to the destination DB, and make sure temporary manifests/logs never
   contain them;
10. write import provenance, counts, warnings, and hashes; only then delete the temporary snapshot.

Initial import should require an empty destination. A future merge importer must allocate an ID map
and rewrite every foreign key; “upsert by ID/name” would silently combine unrelated histories.
There is no bidirectional live sync until a real cross-process ownership protocol exists.

---

## 5. Credential architecture

### 5.1 Current-state finding

The desktop source stores secrets in ordinary Ecto fields:

- provider `api_key` (`lib/swarm_code/providers/provider.ex:18-29`);
- search provider keys and legacy Tavily settings;
- MCP `env` and `headers` (`lib/swarm_code/mcp/server.ex:9-20`);
- settings `tavily_api_key` (`lib/swarm_code/settings/setting.ex:31-38`).

The DB/WAL/SHM are mode `0600` and provider structs omit `api_key` from `Inspect`, but plaintext-at-rest
remains. Spec 20 explicitly deferred the Keychain cutover
(`.specs/20_pane_polish_and_hardening_spec.md:445-458`). A new CLI need not inherit that debt.

### 5.2 Adapter and reference model

```text
CredentialBroker
  put(kind, owner_id, field, secret) -> {:ok, opaque_ref}
  fetch(opaque_ref)                  -> {:ok, secret} | :locked | :missing
  delete(opaque_ref)                 -> :ok
  redact(value, known_refs/secrets)  -> sanitized value

Adapters:
  macOS   Keychain Services (stable signed helper/API)
  Linux   Secret Service/libsecret over the user's D-Bus session
  test    isolated in-memory map
  headless environment/session input (read-only; never silently persisted)
```

Apple says Keychain is the best place for small secrets such as passwords and cryptographic keys
[R6]. The freedesktop Secret Service API stores secrets in a service in the user's login session,
but its transfer can use a `plain` D-Bus session and D-Bus messages can pass through/cache in multiple
processes, so use libsecret's negotiated session, minimize copies, and do not log bus payloads [R7].

Rules:

- DB rows hold an opaque random reference and non-secret metadata only. Backups are therefore not
  credential backups.
- Save is two-phase: write a new secret, fetch/read-back equality, transactionally swap the DB ref,
  then delete the old item. On DB failure delete the new item. Orphan cleanup is idempotent.
- Resolve the secret inside the short-lived provider/MCP request worker on every call so rotation
  reaches the next request. Do not keep keys in `RunServer`, EventHub, TUI assigns, crash state, or
  long-lived provider structs.
- BEAM binaries cannot be reliably zeroized. Minimize lifetime/copies, never interpolate keys, and
  ensure `Inspect` implementations redact every secret-bearing struct/request.
- Exact configured secret values, generic credential patterns, URL userinfo/query tokens, and
  `Authorization` values are redacted **before** logs, DB, events, terminal rendering, and errors.
  Redaction after persistence/output is too late.
- MCP secret fields are explicit (for example `!TOKEN=` or separate `secret_env_refs`); heuristics
  only assist legacy import. MCP error/result echoes still pass through exact-value redaction. The
  current server heuristic and client `safe/2` boundary are useful compatibility inputs
  (`lib/swarm_code/mcp/server.ex:122-142`; `lib/swarm_code/mcp/client.ex:471-478,694-721`).
- Never pass a key as a command-line argument. On macOS, `/usr/bin/security` itself warns that
  `-p/-w <password>` is insecure and recommends prompting with `-w` last. Prefer a small, signed
  Keychain Services helper/API whose secret enters over a private pipe, not argv.
- Do not use Keychain `-A` (“allow any application”), and keep a stable signed identity across CLI
  updates. Apple's keychain technote notes that data-protection keychain access is user-context and
  command-line tools differ from app bundles [R8].
- On Linux, detect both the D-Bus session and an unlocked Secret Service. In headless SSH/containers,
  support `SWARM_CODE_*_API_KEY` or an interactive per-session prompt. If persistence is requested
  without a service, fail with instructions; do not silently create `credentials.json`.
- Strip provider/search keys from child process environments. A key supplied to launch the CLI must
  not automatically reach `run_command`, Git, workflow sandboxes, or MCP servers.

---

## 6. Permission model and host effects

### 6.1 Capabilities, not three vague labels

The current modes are `read_only`, `auto`, and `full_access`, and read operations are always allowed
(`lib/swarm_code/engine/policy.ex`). Keep the familiar modes in UI, but evaluate a richer fixed
capability at every effect:

```text
project_fs_read       project_fs_write       project_git_read
project_git_mutate    host_execute            network_public
network_private       mcp_call:<server/tool>  clipboard_write
open_external_url     automation_enable       destructive_storage
```

Map modes to defaults, then apply project/run/tool grants. An approval key includes project identity,
conversation, run, node, tool, capability, canonical argument hash, and expiry. “Always” is scoped to
the narrowest useful tuple (normally project + tool + capability for this run), never all execute.
Re-evaluate policy immediately before the effect because a mode can change while approval is open.

Approval UI is trusted chrome:

- render exact escaped arguments, canonical root/origin, environment **names** (not values), and
  destructive/network class;
- do not use model/MCP title or annotation as the authoritative description;
- first compare-and-set decision wins across multiple TUI clients;
- a stopped/replaced/generation-mismatched operation cannot consume a late approval;
- high-risk approvals require an explicit key/typed confirmation, not Enter inherited from a paste.

Plan mode is enforced twice: do not advertise mutating tools, and deny them at dispatch. The current
app learned this after globally resolving an invented tool could bypass an agent's offered allow-list
(`lib/swarm_code/engine/agent_server.ex:295-355`).

### 6.2 Model-authored Elixir workflow isolation

Current workflows are described as trusted scripts but are assistant-authored, parsed with
`Code.string_to_quoted/2`, validated by an AST allow-list, and evaluated with `Code.eval_quoted/3`
inside a supervised task (`lib/swarm_code/workflows.ex:111-207`;
`lib/swarm_code/workflows/smoke.ex:67-147,271-360`;
`lib/swarm_code/workflows/runner.ex:91-116`). A max heap of roughly 512 MB limits only the script
process (`lib/swarm_code/workflows/api.ex:34-56`).

This is insufficient for the CLI core:

- atoms are global and not garbage collected; the Erlang Ecosystem Foundation warns atom-table
  exhaustion crashes the VM [R17];
- `Code.string_to_quoted/2` defaults `existing_atoms_only: false`; Elixir documents that its
  tokenizer's static atoms include aliases, calls, variables, atoms, and keyword keys, and suggests
  a custom encoder only for analysis because the resulting AST is not evaluable [R18];
- process heap limits do not provide an OS memory/CPU/filesystem/network boundary and do not contain
  every off-heap/global resource;
- AST allow-lists are valuable defense-in-depth, not a proof that future language/stdlib forms are
  harmless.

Preserve the Elixir workflow language through a **disposable workflow worker release**:

1. spawn a fresh child BEAM with no distribution, cookie, EPMD, shell, inherited secrets, project
   write access, or network channel;
2. send source/args over length-prefixed JSON, never ETF or Erlang distribution;
3. in the child: byte/token/AST-depth limit, parse, existing closed allow-list, determinism lint,
   per-process heap limit, OS process-group ownership, wall deadline, and (where available) OS memory/
   CPU limits;
4. the only effects are JSON RPCs to a parent `WorkflowBroker`; the broker owns budget, journal,
   capability checks, agents, host reads, gates, and cancellation;
5. journal fingerprints are SHA-256 over canonical versioned JSON `{source_hash,args,seq,slot,kind,
   payload,opts}`, not collision-prone/runtime-dependent `phash2`;
6. on resume, pure recorded results replay. Side-effecting/ambiguous operations require an idempotency
   key or user review; shutdown never starts a new worker;
7. kill the child process group on runner/daemon stop, then settle the run. No child response can
   create atoms in the core.

Built-in workflows go through the same broker so security and replay semantics do not fork.

### 6.3 Shell and external processes

`run_command` is explicit arbitrary host execution via `/bin/sh -c`; project cwd is not confinement.
State this in approval text. Default child environment should be a constructed allow-list (`PATH`,
locale, minimal `HOME` if required), with explicit per-project passthrough names. Always remove
provider/MCP/search secrets, release variables, `ERL_*`, `ELIXIR_*`, proxy variables unless intended,
and terminal prompt variables. Use `/dev/null` stdin and `GIT_TERMINAL_PROMPT=0` as the current app
does (`lib/swarm_code/tools/run_command.ex:64-131`).

Launch every command/Git/MCP child in its own OS process group/session. Store pid + process-group
identity/start information. On stop: TERM group, bounded grace, recheck, KILL group, close pipes, and
settle. A `ps` tree snapshot is a useful fallback but races forks, daemonization, depth, and PID reuse;
the current implementation necessarily has those limits (`lib/swarm_code/os_process.ex:18-47,
64-85`). Capture and bound **both** stdout and stderr; no child descriptor may point directly at the
user's terminal.

### 6.4 Path confinement and atomic writes

The source app expands and resolves symlinks, writes a same-directory mode-`0600` temp, fsyncs it,
preserves mode, renames, and removes the temp (`lib/swarm_code/atomic_file.ex:1-180`). It explicitly
has no read-modify-write lock. Validation and use still occur via path strings, leaving a TOCTOU
window; in this application a parallel approved shell/tool can exploit that race, not only an
already-compromised local account.

For every read/write/edit/remove/checkpoint/attachment/workflow/memory operation:

- keep a descriptor to the canonical project root and traverse relative components with dirfd APIs;
- Linux: `openat2` with `RESOLVE_BENEATH|RESOLVE_NO_MAGICLINKS` (and a deliberate symlink policy);
  the Linux API is specifically designed to constrain resolution beneath a trusted dirfd [R12];
- macOS: component-by-component `openat`/`fstatat` with `O_NOFOLLOW`, held directory FDs, bounded
  in-root symlink resolution, and `renameat`; never validate, close all FDs, then reopen by string;
- reject NUL, invalid UTF-8 where APIs require it, overlong components, and unexpected object types;
  handle macOS case/Unicode-normalization collisions by inode identity, not text equality;
- create a same-directory `O_CREAT|O_EXCL` temp at `0600`; write in chunks; fsync/fdatasync; apply the
  original mode; atomically `renameat`; then fsync the containing directory. Linux `fsync(2)` notes
  that syncing the file alone does not guarantee the directory entry is durable [R13];
- clean only this invocation's temp on success, error, timeout, cancellation, or crash recovery;
- edit with optimistic concurrency: record `{dev,ino,size,mtime,sha256}` at read and compare before
  replace. A mismatch is a visible conflict, not last-writer-wins;
- checkpoint and mutation share one higher-level serialized transaction/intent so “snapshot made” and
  “file replaced” do not lie about each other.

### 6.5 Git safety

- Never shell-concatenate Git. Pass argv directly with stdin closed and output captured/sanitized.
- Validate branch/ref names with `git check-ref-format`; validate arbitrary revisions using
  `git rev-parse --verify --end-of-options "$REV^{commit}"`, which Git documents for untrusted
  revision variables [R10]. Resolve to an object ID and use the ID in subsequent operations to avoid
  option ambiguity and moving-ref TOCTOU. Still place `--` before paths/refs where the subcommand
  supports it.
- Treat repository paths/pathspecs separately from revisions; derive worktree paths from internal
  IDs, never model text.
- Scope integrate/discard to the exact unintegrated node joined through run → conversation → project,
  expected branch/base SHA, expected worktree inode, and current integration state. The current
  implementation's scoped node validation is the right baseline
  (`lib/swarm_code/tools/integrate_agent.ex:36-114`).
- Serialize index/ref mutations per repository. Re-check HEAD/base and dirty state immediately before
  merge/commit; make retry detect an already completed internal operation.
- Git “read” can invoke repo-controlled textconv filters, external diff helpers, pagers, credential
  helpers, and some operations can invoke hooks. Disable pagers/external diff/textconv where not
  needed and classify any path that can execute repo configuration as host execution, not harmless
  read.
- Sanitize ref names, filenames, commit text, and diff output before the terminal.

---

## 7. `web_fetch`, search/readers, and SSRF

The current `web_fetch` accepts any HTTP(S) URL, delegates to a configured cloud reader, then falls
back to Req with a bounded 4 MB text collector (`lib/swarm_code/tools/web_fetch.ex:31-109`;
`lib/swarm_code/search/body.ex`). It has no destination/redirect/peer policy. Because `:read` is
auto-approved, prompt injection can reach loopback services, RFC1918/ULA, link-local and cloud
metadata endpoints.

Do **not** blanket-ban localhost/private access—the product needs it. Instead:

1. parse with a real URI parser; accept absolute `http`/`https`, no userinfo, fragments removed from
   requests, valid normalized host/port, and no alternate numeric-IP notation bypasses;
2. classify every A/AAAA answer as public, loopback, private, link-local, CGNAT, multicast,
   unspecified, or non-connectable. IPv4-mapped IPv6 and scoped addresses must normalize first;
3. public fetch uses `network_public`; loopback/private/link-local uses `network_private` and an
   explicit per-origin/project grant. Cloud metadata ranges and Unix/admin sockets are denied by
   default and need a separate expert override;
4. reject an empty or mixed-trust answer set. Connect to an approved numeric peer while retaining the
   logical Host/SNI/certificate hostname; verify the actual peer before accepting application data;
5. disable implicit redirects and proxies. Resolve/reclassify/re-pin every redirect, cap hops, reject
   downgrade/cycles, and strip credentials on cross-origin redirects. OWASP calls out DNS pinning/
   rebinding and redirect validation as core SSRF concerns [R9];
6. a connection pool key includes scheme, numeric peer, port, logical hostname, and TLS options, or
   reuse is disabled;
7. one deadline covers DNS, connect, retry, redirects, headers, compressed input, decompression, and
   body collection. Cap wire bytes, decoded bytes, parse depth, DOM nodes, and final chars;
8. never send a private/localhost URL to Jina/Firecrawl or another cloud reader. For a public URL,
   disclose that reader delegation sends the URL (and possibly content) to a third party and honor a
   user setting/grant;
9. do not forward browser cookies, environment proxy credentials, provider keys, or arbitrary model
   headers. Log only origin/class/status/error category, not query/userinfo/body.

Spec 19 contained a strong pinned-target design even though spec 20 later dropped it as too large for
that desktop pass (`.specs/19_reliability_security_performance_spec.md:845-872`). A new CLI should
implement the boundary from the start because terminal/headless automation increases exposure.

---

## 8. MCP security and lifecycle

### 8.1 Trust and enablement

Stdio MCP configuration is a startup command. The MCP security guide explicitly lists malicious
startup commands and insecure localhost servers as attack vectors [R22]. Therefore:

- adding/enabling a stdio server requires a trusted approval showing the resolved absolute executable,
  argv, cwd, project scope, inherited environment names, and secret-ref names;
- imported servers are disabled; changes to executable/args/cwd/URL/secrets invalidate trust;
- resolve executables once to an absolute path; optionally record signer/package/hash for drift
  warnings, but allow an explicit user-approved update;
- start only enabled **and approved** servers after bootstrap; never execute MCP during migration/import;
- HTTP MCP supports HTTPS by default; plaintext HTTP is allowed only for explicitly approved local
  origins. If the CLI ever hosts HTTP MCP, validate `Origin`, bind loopback, and authenticate, as the
  transport spec requires to prevent DNS rebinding [R11].

### 8.2 Annotations and permissions

MCP says tool annotations are untrusted hints and clients should show inputs, confirm sensitive
operations, validate results, use timeouts, and audit calls [R19]. The current app maps
`readOnlyHint == true` into a trusted `read_only?` flag (`lib/swarm_code/mcp.ex:134-147`) and then
offers those tools to read-only workers (`lib/swarm_code/tools.ex:161-192`). Do not port that
authorization shortcut.

Default every new/untrusted MCP tool to `mcp_call` plus its server's network/execute risk. Let a user
establish an explicit server/tool capability policy; a trusted annotation can help propose a default,
not decide it. Re-confirm when name/schema/annotation hash changes.

### 8.3 One request, owner, generation, and deadline

Each client state contains:

```text
generation
connection/session identity
pending[id] = {token, task_or_port_ref, caller_monitor, timer_ref,
               admitted_at, absolute_deadline, request_bytes}
one tagged reconnect timer
bounded pre-session queue {count, bytes}
```

- caller death cancels its HTTP task or forgets its stdio reply without affecting peers;
- timeout settles that caller once. For stdio, a separate bounded ping may test transport health;
  one slow tool must not fail every caller;
- reconnect/disable/terminate increments generation, cancels tasks/timers, fails queued/pending calls,
  kills stdio process group, closes transport, forgets tools, and permits at most one reconnect;
- workers send `{generation,id,token,outcome}` to the client; only the client replies;
- old results/timeouts/reconnect messages are no-ops;
- one 30 s handshake deadline spans all `tools/list` pages; cursor set detects repetition; accumulate
  linearly; do not publish partial tools;
- cap tool count, tool-name/description/schema bytes/depth, session-ID/header sizes, in-flight calls,
  queue bytes, JSON depth, and response/frame bytes.

Current spec 31 states these exact lifecycle requirements
(`.specs/31_surgical_correctness_and_efficiency_spec.md:99-124,520-537`), while current implementation
still lacks HTTP task ownership/generations. Treat the spec as the target.

### 8.4 Transport and rendering

- Stdio stdout is protocol-only; capture stderr separately into a bounded, sanitized diagnostic log.
  No MCP child fd may inherit the terminal. A wrapper/helper may be needed because merging stderr
  into stdout corrupts JSON-RPC.
- Incrementally frame UTF-8 JSON-RPC. Never use growing `buffer <> chunk`. If a protocol has no
  reasonable negotiated maximum, spill a single incomplete frame to a mode-`0600` run-owned file or
  fail at a documented cap; clean on every exit. Decode only after framing and release decoded terms.
- HTTP response/SSE collection is equally bounded and uses the same absolute deadline.
- Tool results are untrusted text. Exact-secret redaction occurs before persistence/LLM/TUI. Then the
  terminal sanitizer runs. Structured output is schema/size/depth validated before being passed to
  the model.
- A transport timeout on a non-idempotent tool is `outcome unknown`; do not retry automatically.

---

## 9. Terminal, clipboard, and untrusted rendering

### 9.1 The invariant

**Only the renderer may emit control sequences, and it only emits sequences constructed from fixed
internal enums.** External strings become text cells/spans after sanitization. There is no “supports
ANSI” escape hatch for model/tool output.

Terminal controls can move the cursor, erase/replace the display, set window titles, create
hyperlinks, request device data, and manipulate selections/clipboard. Xterm documents OSC 52 as a
selection/clipboard control [R20]. A recent Rust advisory describes untrusted ANSI in logs as able to
change titles, clear/modify the screen, and mislead users; its mitigation is escaping terminal
controls [R21].

### 9.2 Sanitizer policy

For every model/MCP/web/Git/file/command/log string:

- decode bytes with replacement for invalid UTF-8 and preserve a downloadable/raw file separately
  only when authorized;
- allow printable characters and normalized newlines. Expand tab to spaces. Render CR, BS, BEL, ESC,
  DEL, C0/C1, and all CSI/OSC/DCS/APC/PM/SOS introducers/terminators as visible control pictures or
  `\\xNN` text; do not merely strip SGR color because OSC/DCS remain;
- approvals, filenames, paths, command lines, URLs, tool/MCP names, and logs additionally expose bidi
  overrides/isolates, zero-width characters, and ambiguous newlines visibly. Normalize only for
  display/comparison; retain original bytes for the operation after separate validation;
- calculate terminal width after sanitization with a pinned Unicode width table. Clamp all dimensions
  and handle 0×0/tiny/huge sizes without allocation from attacker-controlled values;
- keep trusted chrome visually and structurally distinct. An approval exists only in a dedicated
  trusted pane/status line; model Markdown that says `[Approve]` is inert prose.

Add property tests over arbitrary bytes and every split point of an escape/string terminator. A test
terminal/emulator must assert that sanitized output changes cells only inside the assigned viewport,
never title/clipboard/mode/input.

### 9.3 Hyperlinks and external open

- Do not pass through OSC 8. Generate it only for a URL that passed the same decoded scheme policy as
  the web Markdown renderer: normally `https/http/mailto`, with `file/data/javascript/vbscript`,
  protocol-relative, CR/LF, and encoded-scheme tricks rejected.
- Show the actual normalized destination, and open only after an explicit action/permission. Invoke
  `open`/`xdg-open` by argv with end-of-options handling; never shell it.
- Remote paths are not local file links. Do not turn model paths into `file://` automatically.

### 9.4 Clipboard and paste

- Never relay OSC 52 from external text. Clipboard writes occur only on an explicit Copy key/button,
  with a byte cap and user feedback. Prefer native local clipboard APIs/commands with content on
  stdin, not argv.
- Under SSH/tmux, OSC 52 **write** is opt-in because it affects the local user's clipboard; OSC 52
  read/query is disabled. Never put clipboard content into model context without an explicit paste.
- Enable bracketed paste only through the input decoder. Pasted data is composer text, never terminal
  commands or auto-submit. Multiline paste and pasted slash commands require the normal send/approval
  action; embedded bracket terminators are handled by the terminal parser, not string replacement.

### 9.5 Terminal lifecycle

`TerminalOwner` alone owns `/dev/tty`, raw mode, alternate screen, mouse/paste mode, cursor visibility,
input reader, SIGWINCH/TSTP/CONT, and restoration. It uses `try/after`/`terminate` plus an emergency
idempotent restore path. Logs and machine-readable output never share the TUI stdout. On non-TTY
stdin/stdout, select headless mode or fail clearly; honor `NO_COLOR` and `TERM=dumb`.

---

## 10. Crash recovery and ambiguous effects

### 10.1 Boot order

1. secure/lock data directory;
2. open SQLite and pin PRAGMAs/source version;
3. migrate only after verified backup gates;
4. integrity check and recovery reconciliation;
5. settle stale launch intents, schedule claims, interrupted runs, workflow sandboxes, research,
   temp/spill files, and worktree cleanup intents idempotently;
6. load secrets by reference (do not require every key just to inspect history);
7. start approved MCP clients;
8. start scheduler;
9. accept TUI/headless/daemon clients.

### 10.2 Recovery classifications

| interrupted point | recovery |
|---|---|
| before launch graph commit | nothing exists |
| committed `starting`, owner never acked | compensate/interrupt once; retain initiating user content |
| LLM partial stream | preserve as partial forensic text if spooled; exclude failed attempt from history; run interrupted/resumable |
| read-only local/MCP call with no reply | may retry only when policy says idempotent and provenance is trusted |
| write/execute/MCP call timed out or process died after dispatch | mark outcome unknown; show exact operation; require inspection/user decision |
| Git commit/merge | inspect operation marker/OID/current repo state before deciding completed vs retry |
| file atomic rename intent | inspect target/temp hashes and finish cleanup; never guess from temp existence alone |
| workflow host journal commit | replay exact committed value; source/args/fingerprint mismatch refuses resume |
| scheduled claim | unique occurrence settles failed/interrupted once and task advances once |
| DB corruption/disk full | stop writes; preserve DB/WAL/SHM; offer verified backup/recovery, never reset |

Do not automatically replay side effects merely because an agent/workflow can resume. The current
scheduled reconciliation and lost-runner rules are strong examples of conditional/idempotent recovery
(`lib/swarm_code/scheduled.ex:338-429`; `.specs/33_recovery_replay_and_secrets_spec.md:13-79`).

### 10.3 Durable cleanup intents

Worktree deletion, secret old-ref deletion, attachment temp cleanup, import temp deletion, and blob/
report finalization need either run-owned synchronous cleanup or a tiny durable cleanup-intent table.
An intent includes type, scoped owner IDs, canonical target identity/hash, attempt count, and last
redacted error. Bootstrap retries only operations whose identity still matches; it never recursively
deletes a path sourced from a stale row.

---

## 11. Remote and headless operation

### 11.1 Foreground-first recommendation

Asynchronous internal work does not require a daemon. A foreground OTP release can run many agents,
workflows, streams, questions, and panels concurrently while the TUI navigates. This is the smallest
attack surface and should ship first unless surviving TUI/SSH exit is an explicit acceptance
criterion.

Headless commands use the same core:

```text
swarm run --json ...       # NDJSON events on stdout; diagnostics on stderr
swarm status --json
swarm stop <run-id>
swarm import desktop
```

No ANSI in JSON/plain output. Every record has schema version, scope IDs, sequence, and event kind;
large detail is fetched separately rather than base64-inlined. Exit codes distinguish rejected,
failed, interrupted, and outcome-unknown.

### 11.2 If persistent detach is required

Use an explicit `swarm daemon start` and `swarm attach`, not a hidden auto-daemon:

- one daemon per data dir, protected by the same exclusive lock;
- Unix-domain socket only: `$XDG_RUNTIME_DIR/...` on Linux and a verified per-user `$TMPDIR` on
  macOS; parent `0700`, socket `0600`, `lstat`/owner checks, random instance nonce;
- authenticate local peer UID (`SO_PEERCRED` Linux, `getpeereid` macOS) and reject mismatches;
- length-prefixed versioned protocol with count/byte limits and no term deserialization/atoms;
- no TCP listener, Phoenix endpoint, distributed Erlang, cookie, or EPMD;
- each attached TUI has its own UI state/subscription generation; disconnect cancels view jobs only;
- approval decisions are compare-and-set and audit which local session answered;
- daemon installation/autostart is opt-in and uninstall removes only its own service file/socket.

Keychain/Secret Service may be locked or unavailable over SSH. A daemon must report `credential
locked` and wait; it must not downgrade to plaintext or repeatedly prompt an invisible GUI.

---

## 12. Deterministic verification strategy

### 12.1 Injectable seams

Tests control clock/UUID/RNG/backoff, provider stream, DNS resolver and actual connector peer, HTTP
transport, SQLite writer/fault point, credential adapter, Git/external process launcher, workflow
sandbox, terminal capabilities/size/input, clipboard, and filesystem operations. Production modules
are fixed behaviors selected by application config at boot—not model/user module names.

Avoid `Process.sleep` and `Process.alive?` assertions. Synchronize on monitors, owner acknowledgments,
barriers, fake clocks, and `:sys.get_state`/explicit inspection calls.

### 12.2 Required suites

**Lifecycle/concurrency**

- fault-inject every launch write, post-commit owner admission, owner ack, terminal write, and event;
- stop/pause/continue during worktree prep, LLM stream, tool batch, approval, question, workflow panel,
  MCP call, and finalization; assert descendants/ports/process groups/timers/waiters reach zero once;
- caller death, TUI scope replacement, detach/reattach, old generation result, queued timeout, runner
  `:normal/:shutdown/:kill`, and daemon SIGTERM/HUP;
- 50 concurrent message inserts yield exactly positions 1..50; concurrent schedule occurrence gives
  one launch; simultaneous approvals give one decision.

**Streaming/backpressure**

- fragment SSE/JSON/tool-argument/MCP frames at every byte boundary, including Unicode and terminator
  boundaries; long streams are linear and final bytes/callback order equal golden fixtures;
- retry after partial text/reasoning produces resets and only successful-attempt final bytes;
- 100 MiB command/MCP/HTTP producers stay within collector budgets while pipes drain and cancellation
  reaps descendants;
- overload subscriber/agent/MCP queues and prove visible refusal/snapshot recovery with no canonical
  data loss.

**Filesystem/Git**

- lexical escapes, absolute paths, symlink cycles, symlink swaps between every operation step,
  in-root symlinks, mount/case/Unicode aliases, hard links, non-regular files, permission/disk-full,
  failure before/after fsync/rename/dir-fsync, and concurrent edit CAS conflict;
- option-looking revisions/pathspecs, invalid refs, moving refs, branch owned by another project/run,
  malicious filenames/control bytes, Git hook/filter fixtures, merge conflict/abort, timeout and
  daemonizing descendants.

**Network/MCP**

- IPv4/IPv6/mapped/decimal/hex/zone forms; mixed DNS answers; rebinding between validation/connect;
  redirects public↔private, scheme downgrade, cycle, cross-origin header stripping, proxy env, peer
  mismatch, compressed bombs, oversized headers/body/DOM;
- MCP fragmented/oversized/malformed JSON, repeated cursor, tool/schema/name bounds, conflicting
  session IDs, untrusted `readOnlyHint`, direct stderr escape bytes, admission failure, caller death,
  reconnect/disable during call, late result/timeout, and non-idempotent outcome unknown.

**Terminal**

- arbitrary bytes and known CSI/OSC 0/2/8/9/52/1337, DCS/APC/PM/SOS, C1, BEL, CR/BS, bidi and
  zero-width payloads from every source; approval-spoof fixtures; assert terminal title/clipboard/
  modes/input remain unchanged;
- bracketed paste with embedded escape/terminator strings, tiny/huge resizes, SIGWINCH, TSTP/CONT,
  INT/TERM/HUP, panic/kill recovery, SSH/tmux capability matrix, `TERM=dumb`, `NO_COLOR`, non-TTY JSON.

**SQLite/migrations/import**

- fixture for every released schema; forward migration, kill/restart at every backfill batch,
  unknown-newer refusal, backup restore and checksum/count equations, FK/quick check, busy writer,
  disk-full/read-only/corruption, WAL/source version gate;
- import live WAL source through backup API; missing/forged attachments; plaintext credential cutover;
  imported MCP/schedules disabled; active work interrupted; collision/empty-destination gate; source
  unchanged byte-for-byte.

**Privacy/secrets**

- exact provider/search/MCP keys, Bearer/cookies, URL encodings, short/overlapping/transformed values,
  crash/supervisor reports, SQL errors, debug logs, events, TUI, JSON output, diagnostic bundle, child
  argv/env/proc listing; no exact secret appears;
- Keychain locked, Secret Service missing/locked, DB commit fails after secret put, old-secret deletion
  fails, rotation while run active, headless env value never persists.

### 12.3 Evidence, not timing guesses

Performance/resource claims use a locked fixture, warm-up, multiple runs, post-GC retained memory,
process/port/message-queue/SQL/event/render counts, and golden output/provider-request checksums. Wall
time may be reported but deterministic structural assertions (bounded bytes/counts, one event, no
full-string rescan) are the gate.

---

## 13. Telemetry, logs, and privacy

The current app defines local Telemetry metrics but no reporter
(`lib/swarm_code_web/telemetry.ex:9-19`). Preserve **no network telemetry by default**.

- Metrics: coarse duration/count/bytes/status/error class, queue depth, retries, dropped-stale count,
  SQLite busy time, process/port counts, render rate, and resource high-water marks.
- Never export prompt/message/reasoning text, tool args/results, file paths/content, repo/project names,
  command lines/output, URLs/query, MCP schemas/payloads, headers, clipboard, environment, keys, or raw
  exception/process state.
- Avoid high-cardinality IDs. If correlation is necessary outside local logs, use an installation-
  keyed ephemeral hash and rotate it; do not export stable conversation/run/project UUIDs.
- Redact at event creation and again at log/export sinks. Logs are structured, mode `0600`, bounded/
  rotated, terminal-sanitized when viewed, and never include full GenServer state/SASL reports.
- Crash reporting is opt-in, previews the exact bundle, and excludes VM dumps/process dictionaries/
  request bodies by default. A diagnostic export is explicit, checksummed, and user-reviewable.
- Update checks and package downloads are documented network actions; no hidden analytics piggyback.

OpenTelemetry's guidance makes the implementer responsible for sensitive data and recommends data
minimization—collect only what serves an observability purpose, avoid personal information, and use
aggregation/anonymization where possible [R23].

---

## 14. Launch gates

### Gate 0 — architecture decisions (before feature code)

- [ ] Separate CLI data directory/database; no live desktop read/write sharing.
- [ ] Foreground-only v1 vs explicit daemon is decided; if daemon, Unix peer-auth protocol is in scope.
- [ ] Fixed capability matrix and approval scoping are written.
- [ ] Model-authored workflow execution is out-of-process; no `Code.eval_*` in the core.
- [ ] Terminal structured-span invariant and control policy are written.
- [ ] Import is one-way/offline snapshot with MCP/schedules disabled.

### Gate 1 — runtime skeleton

- [ ] Bootstrap/runtime supervision ordering; one owner for every task/port/timer/socket.
- [ ] Per-run tree; owner-tagged generations/deadlines; responsive control calls.
- [ ] Bounded EventHub/subscribers with snapshot recovery.
- [ ] Terminal restoration proven under normal exit, crash, INT/TERM/HUP, TSTP/CONT.
- [ ] No distributed Erlang/EPMD and no network listener by default.

### Gate 2 — persistence and recovery

- [ ] SQLite >= 3.51.3 (prefer current maintained bundled patch), pinned source ID.
- [ ] Permissions/umask/sidecars, WAL-local-FS guard, writer serialization, constraints/retry.
- [ ] Atomic launch graph, idempotent terminal states/outbox ordering, crash reconciliation.
- [ ] Verified backup/restore/migration fixtures and read-only failure mode.
- [ ] Import manifest/count/hash/credential/MCP/schedule safety tests.

### Gate 3 — credentials and privacy

- [ ] macOS Keychain and Linux Secret Service adapters plus isolated memory test adapter.
- [ ] Locked/unavailable headless behavior; no plaintext fallback.
- [ ] Two-phase key save/rotation/deletion and exact-value redaction at every sink.
- [ ] Child argv/env and crash reports proven secret-free.
- [ ] No telemetry exporter by default; opt-in diagnostic bundle reviewed.

### Gate 4 — tools and workflows

- [ ] Descriptor-relative path operations, CAS edits, file+directory fsync, cancellation cleanup.
- [ ] Process-group ownership; separate bounded stdout/stderr; stdin `/dev/null`; sanitized env.
- [ ] Git ref/revision/path validation, scoped integration, mutation serialization, hook/filter policy.
- [ ] Workflow sandbox/broker, canonical SHA-256 journal, budget/replay/gate/ambiguous-effect tests.
- [ ] Permission check at dispatch as well as tool-list construction.

### Gate 5 — network and MCP

- [ ] Public/private/metadata classification, pinned actual peer, redirect/proxy/header/TLS rules.
- [ ] Cloud reader privacy rule and no private URL delegation.
- [ ] MCP executable trust review; imported definitions disabled.
- [ ] MCP annotations untrusted; per-tool grants.
- [ ] Generations/caller monitors/absolute deadlines/bounded frames+queues/cursor detection/one settlement.
- [ ] MCP stdout/stderr cannot touch terminal; secret/result sanitization proven.

### Gate 6 — TUI acceptance

- [ ] Every external string source passes the sanitizer; source-level lint forbids raw terminal writes.
- [ ] Approval spoof, ANSI/OSC/clipboard/hyperlink/bidi/paste fuzz suite passes.
- [ ] Concurrent runs remain live across navigation; question/approval scope and event ordering hold.
- [ ] Non-TTY JSON/plain modes have stable schemas and zero controls.
- [ ] macOS Terminal/iTerm2/Ghostty and Ubuntu GNOME Terminal/Kitty/SSH/tmux matrix passes, including
      small terminals, Unicode widths, reduced color/motion, suspend/resume, and disconnect.

### Gate 7 — release and installer

- [ ] Per-OS/arch Mix releases include ERTS and the intended SQLite source; no runtime Elixir needed.
- [ ] macOS binaries/helpers have stable Developer ID signatures and are notarized/stapled; Apple
      recommends code signing and notarization for software distributed outside the App Store [R24].
- [ ] Ubuntu/macOS artifacts have SHA-256, SBOM, signed provenance/attestations, and reproducible build
      metadata. GitHub documents verifying binary attestations with `gh attestation verify` [R25].
- [ ] The one-command installer verifies the selected artifact before execution/install, does not put
      secrets in argv, does not require root for a user install, uses atomic replacement, and supports
      rollback/uninstall without deleting user data.
- [ ] Dependency/license/vulnerability audit, full seeded tests, migration/import fixtures, resource
      soak, and smoke matrix are green before publishing.

---

## 15. Focused current-code findings to carry into planning

1. **Good foundations:** explicit run/agent supervisors, 100 ms stream coalescing, bounded command
   head/tail, process-tree reaping, scoped branch integration, atomic same-directory replacement,
   SQLite busy/unique-position handling, startup reconciliation, provider `Inspect` redaction, and
   web Markdown/URL sanitization.
2. **Do not port unchanged:** separately persisted launch graph; blocking DB calls in `RunServer`;
   global detached cleanup/notification tasks; unowned MCP HTTP workers; unbounded MCP line buffer/
   queue/pagination; trust in MCP `readOnlyHint`; plaintext credentials; unpinned `web_fetch`;
   model-authored `Code.eval_quoted` in the core; path validate-then-use TOCTOU; raw terminal output
   surfaces that do not exist in the web app.
3. **Compatibility warning:** spec 19's enterprise-grade backup/keychain/network design was explicitly
   superseded/narrowed by spec 20 for the desktop pass. It remains useful design research, but the
   new CLI must choose and test its own contracts rather than claiming those protections are already
   implemented.

---

## References

### Current repository/spec evidence

- `.specs/20_pane_polish_and_hardening_spec.md` — current hardening requirements and explicit scope
  dropped from superseded spec 19.
- `.specs/31_surgical_correctness_and_efficiency_spec.md` — atomic launch, scoped mutation, workflow
  replay, MCP generation/ownership, provider continuation, and owned async requirements.
- `.specs/32_scope_and_atomic_writes_spec.md` — current atomic-file, checkpoint, attachment, branch,
  and goal ownership behavior.
- `.specs/33_recovery_replay_and_secrets_spec.md` — scheduled claim recovery, lost Runner, panel replay,
  and exact MCP-secret redaction.
- `.specs/51_pass45_lean_runtime_spec.md` — current lifecycle, SQLite, stream/context, workflow,
  transport, tool, and process-resource findings.
- Source/test paths and line ranges cited inline above.

### Authoritative external guidance

- **R1.** freedesktop.org, *XDG Base Directory Specification 0.8*:
  https://specifications.freedesktop.org/basedir/latest/
- **R2.** SQLite, *Write-Ahead Logging* (concurrency and same-machine/network-filesystem limits):
  https://www.sqlite.org/wal.html
- **R3.** SQLite, *Online Backup API* (consistent completed snapshot):
  https://www.sqlite.org/backup.html
- **R4.** SQLite, *PRAGMA statements* (`quick_check`, `foreign_key_check`, `application_id`,
  `user_version`): https://www.sqlite.org/pragma.html
- **R5.** SQLite, *Release History* (3.51.3 WAL-reset fix):
  https://www.sqlite.org/changes.html#version_3_51_3
- **R6.** Apple, *Storing Keys in the Keychain*:
  https://developer.apple.com/documentation/security/storing-keys-in-the-keychain
- **R7.** freedesktop.org, *Secret Service API — Transfer of Secrets*:
  https://specifications.freedesktop.org/secret-service/latest/transfer-secrets.html
- **R8.** Apple, *TN3137: On Mac keychain APIs and implementations*:
  https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
- **R9.** OWASP, *Server-Side Request Forgery Prevention Cheat Sheet*:
  https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html
- **R10.** Git, *git-rev-parse* (`--verify --end-of-options`) and *git-check-ref-format*:
  https://git-scm.com/docs/git-rev-parse and https://git-scm.com/docs/git-check-ref-format
- **R11.** MCP 2025-06-18, *Transports* (Origin validation, loopback binding, authentication):
  https://modelcontextprotocol.io/specification/2025-06-18/basic/transports
- **R12.** Linux man-pages, *openat2(2)* (`RESOLVE_BENEATH`, `RESOLVE_NO_MAGICLINKS`):
  https://man7.org/linux/man-pages/man2/openat2.2.html
- **R13.** Linux man-pages, *fsync(2)* (directory fsync required for directory-entry durability):
  https://man7.org/linux/man-pages/man2/fsync.2.html
- **R14.** Elixir, *Task* (supervised-task ownership/results/errors/timeouts):
  https://hexdocs.pm/elixir/Task.html
- **R15.** Erlang/OTP, *Distributed Erlang — Security*:
  https://www.erlang.org/doc/system/distributed.html#security
- **R16.** Elixir Mix, *mix release* (`include_erts` defaults/recommendation):
  https://hexdocs.pm/mix/Mix.Tasks.Release.html
- **R17.** Erlang Ecosystem Foundation Security WG, *Preventing atom exhaustion*:
  https://security.erlef.org/secure_coding_and_deployment_hardening/atom_exhaustion.html
- **R18.** Elixir, *Code.string_to_quoted/2* options and static atom encoder:
  https://hexdocs.pm/elixir/Code.html#string_to_quoted/2
- **R19.** MCP 2025-06-18, *Tools — Security Considerations / untrusted annotations*:
  https://modelcontextprotocol.io/specification/2025-06-18/server/tools
- **R20.** XTerm, *Control Sequences / OSC 52 selection manipulation*:
  https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
- **R21.** RustSec, *RUSTSEC-2025-0055 — ANSI escape injection in terminal logs*:
  https://rustsec.org/advisories/RUSTSEC-2025-0055.html
- **R22.** MCP, *Security Best Practices* (malicious startup command and DNS-rebinding threats):
  https://modelcontextprotocol.io/specification/draft/basic/security_best_practices
- **R23.** OpenTelemetry, *Handling sensitive data — data minimization*:
  https://opentelemetry.io/docs/security/handling-sensitive-data/
- **R24.** Apple, *Notarizing macOS software before distribution*:
  https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution
- **R25.** GitHub Docs, *Using artifact attestations to establish provenance for builds*:
  https://docs.github.com/actions/security-guides/using-artifact-attestations-to-establish-provenance-for-builds
