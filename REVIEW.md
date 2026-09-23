# swarm-code-cli review

Elixir umbrella at `/Users/zaali/dev/swarm-code-cli` (apps: `swarm_code_cli`,
`swarm_code_core`, `swarm_code_daemon`), a web-to-CLI conversion of the Phoenix
LiveView app at `/Users/zaali/dev/swarm-code`.

Status: **PARTIAL — delivered at end of day 4.** Findings below come only from
reviewer runs that COMPLETED with a full result, or from files I read myself.
Reviewer provenance:

- COMPLETED with full findings: storage-gates, terminal-unicode, and
  conversion-fidelity (rev-conversion-r2, ~230 probes; its delivery envelope
  failed but its analysis was recovered from its session log and is reproduced
  in the "Conversion fidelity" section).
- FAILED (no usable output, died on a search-tool misuse bug): engine-runtime
  (both attempts), ipc-service (both attempts), tui-architecture (first
  attempt), conversion-fidelity (first attempt), tools-providers (first
  attempt), entry-release.
- STILL RUNNING when this report was handed over: tui-architecture (retry),
  tools-providers (retry), conversion-fidelity (retry). Their results, if they
  land, are not reflected here.

Everything in "Unresolved / not covered" is genuinely uncovered. This is a
bounded sample, not an exhaustive review.

FINDING PROVENANCE:
- Findings #1-#4 and #12-#13 come from the storage-gates reviewer (a COMPLETED
  run whose full text I read).
- Findings #5-#11 come from the terminal-unicode reviewer (a COMPLETED run whose
  full text I read).
- No finding has been independently re-verified by a second reviewer or by me
  reading the cited code myself; severities are the reporting reviewer's
  judgment. The two items I verified myself are in "Test & verification gaps"
  (the provenance failure and the two test-invocation traps), which I confirmed
  by running the commands.
- Nothing in this report is sourced from a FAILED or truncated child run.
- Findings #14-#15 were verified inline by the parent (me) by reading the cited
  code, after the tools-providers reviewer lane died twice on runtime failures.
- Findings #16-#25 are the conversion reviewer's, recovered from its session log
  after its delivery failed. The parent spot-checked #16 and #17 against the
  cited lines (codec.ex:382/394, persisted_backend.ex:527, switcher.ex:284,
  intent.ex:63/159, request.ex:211) and they hold.

## Executive summary

The conversion is architecturally serious and largely sound: the domain layer was
moved wholesale into a daemon behind a Unix-socket service, and the TUI is a
genuine Elm-style projector/reducer/paint stack rather than a terminal-shaped
afterthought. The test suite is green (1907 tests, 0 failures) and the build is
clean, which is more than most ports of this size achieve.

The single biggest risk is **storage safety that only holds in one direction**.
The CLI refuses to start while the macOS desktop app runs, but the desktop app
has no knowledge of the CLI's lease and opens the same SQLite database with its
own connection pool. Two writers on one WAL database is exactly the corruption
case the lease subsystem exists to prevent.

The second risk is now CONFIRMED: **LiveView-era PubSub broadcasts with no
consumer**. The conversion reviewer enumerated every topic and found many with
live producers and zero subscribers (finding #18), plus four `ui` events the
persisted_backend silently ignores. A broadcast with no subscriber is a UI that
never updates and no test failure.

## Critical & High

**1. High — the cross-app database guard is one-way; the desktop app can still
open the CLI's database.**
[foundation_gate.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_daemon/lib/swarm_code/daemon/foundation_gate.ex:117)
and [paths.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_daemon/lib/swarm_code/daemon/platform/paths.ex:46).
The CLI runs `detect_desktop` before and after lease acquisition and refuses to
start when the desktop is running. The protection does not extend the other way:
the desktop repo contains zero references to `instance_lease.db`,
`instance_owner.json`, `GuardedLease`, `DatabaseBinding`, or `cli-daemon`, and
uses stock hex `exqlite 0.39.0` rather than the vendored guarded fork. Both apps
resolve to the identical path
`~/Library/Application Support/SwarmCode/swarm_code.db` (desktop
`config/runtime.exs:21-30`, CLI `paths.ex:46`).
Failure scenario: the CLI daemon starts and holds the lease; the user then
launches the desktop app, which never checks for a CLI owner and opens the same
file with its own pool of 5 connections. The CLI's `assert_held`/`verify_physical`
checks begin failing mid-flight, and the desktop's writes bypass every binding
and slot authorization the lease exists to enforce. Two independent connection
pools on one WAL database is the corruption and lost-update case this subsystem
is built to prevent.
Fix: make the desktop app acquire (or at minimum honor) the same
`instance_lease.db` before opening `swarm_code.db`, or have the CLI hold an
`flock` on the database file itself that a plain SQLite open would conflict
with. Until then the mutual-exclusion claim holds in one direction only and
should not be documented as cross-app safety.

## Architecture

- **One-way safety invariant.** As above: the lease/foundation-gate design
  assumes both participants speak the lease protocol. Only one of them does.
  Any documentation or comment claiming "the CLI and desktop cannot both open
  the database" is currently false in the desktop→CLI direction.
- **CONFIRMED — LiveView ghosts in the daemon.** `domain/ui_state.ex`'s GenServer
  IS started (runtime.ex:11) so its ETS table exists, but its presence API is
  dead: no process calls get/put/update/opened; only `delete/1`
  (conversations.ex:477) and `open_conversation_ids` (storage.ex) are called, and
  `open_conversation_ids` always returns [] because `opened/1` is never called.
  The original had 55 UIState callers. The per-conversation UI state is dead
  code in the CLI (finding #24 covers the stale docs).
- **CONFIRMED — PubSub broadcasts with no consumer.** See finding #18: many
  topics have producers and zero subscribers, and four `ui` events are silently
  ignored by the only subscriber.
- **Deferred-transaction mismatch.** The guarded Repo omits
  `default_transaction_mode: :immediate` that the shared domain code assumes
  (see Medium #2), which is an architectural seam: the desktop deliberately sets
  `:immediate` and recorded why, but the CLI ships the same domain modules
  without it.

## Medium

**2. The guarded Repo drops `default_transaction_mode: :immediate` that the
shared domain code assumes.**
[cross_app_lease.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_daemon/lib/swarm_code/daemon/cross_app_lease.ex:234).
The `admit_repo` option list sets `busy_timeout: 2_000` but omits
`default_transaction_mode`, so it falls back to `:deferred`
([vendor connection.ex](/Users/zaali/dev/swarm-code-cli/vendor/exqlite/lib/exqlite/connection.ex:659)).
The desktop sets `:immediate` deliberately with the rationale recorded at
`config/runtime.exs:53-58`: a read-then-write transaction under DEFERRED is
refused outright with SQLITE_BUSY when another writer slips in between, and the
busy handler cannot help. The CLI ships the same domain modules and
[conversations/writes.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_daemon/lib/swarm_code/domain/conversations/writes.ex:4)
still documents "each function is one IMMEDIATE transaction", but nothing in
`config/` or the guarded option list provides it. `Repo.retry/3` masks this in
most paths, yet [storage.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_daemon/lib/swarm_code/domain/storage.ex:761)
and [storage.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_daemon/lib/swarm_code/domain/storage.ex:819)
call `Repo.transaction` bare with no retry wrapper.
Failure scenario: a storage cleanup batch and a concurrent agent write contend;
the deferred transaction raises SQLITE_BUSY; the
`{:ok, {count, _}} = Repo.transaction(...)` match at line 760 crashes the cleanup
task mid-sweep, leaving `storage_last_cleanup_at` already stamped so the day's
retention never reruns.
Fix: add `default_transaction_mode: :immediate` to the guarded option list and
raise `busy_timeout` toward the desktop's 15 s.

**3. `Storage.batch_delete/4` asserts on a transaction result it cannot
guarantee.**
[storage.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_daemon/lib/swarm_code/domain/storage.ex:760).
`{:ok, {count, _}} = Repo.transaction(...)` is a hard match; any
`{:error, ...}` (busy, disk full, closed connection) raises `MatchError` out of
the recursive loop. Because `run/1` executes inside a `Task.Supervisor` child
registered under `:storage_cleanup`, the crash leaves the Registry entry cleaned
up but the sweep half-finished with no `{:storage_done, ...}` or
`{:storage_failed, ...}` broadcast — `execute/2` at
[storage.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_daemon/lib/swarm_code/domain/storage.ex:672)
only notifies on the success path. A UI awaiting progress on `topic/0` waits
forever. The same bare-match pattern repeats at
[storage.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_daemon/lib/swarm_code/domain/storage.ex:818).
Fix: match the result, broadcast a failure event, and return state recording
partial progress rather than raising.

**4. A partial backup is never presented as complete, but a failed cleanup can
mask a good one.**
[backup/gate.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_daemon/lib/swarm_code/daemon/backup/gate.ex:654).
In `create_new`, `operation_result` may be `{:ok, %Artifact{}}` — fully
published, `mark_committed` called, directory fsynced — yet if
`finish_ownership/5` returns anything but `:ok` the whole result is discarded and
replaced with `{:error, :cleanup_pending}`. The artifact is genuinely complete
on disk (publication is link-then-commit and `validate_published` confirms the
staging names are gone), so the user is told the backup failed while a valid one
sits in `backups/`. On retry the `:committed` branch runs `revalidate_existing`
and succeeds, so this is self-healing rather than corrupting — but the reported
status is wrong in the opposite direction from the usual failure mode, and
`cleanup_pending_error/0` tells the user to "retry after the cleanup owner
reports terminal evidence" for a backup that needs no retry.
Fix: when `operation_result` is already `{:ok, artifact}` and `state.committed?`
is true, return the artifact and surface the cleanup state separately rather
than downgrading a verified result.

**5. HIGH — pasted text reaches the editor buffer and backend egress with zero
control-character filtering.**
[input.rs](/Users/zaali/dev/swarm-code-cli/native/terminal_port/src/input.rs:317)
through [input.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_cli/lib/swarm_code_cli/ui/input.ex:144),
[operation.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_cli/lib/swarm_code_cli/ui/editor/operation.ex:120),
[keymap.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_cli/lib/swarm_code_cli/ui/keymap.ex:94),
[commands.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_cli/lib/swarm_code_cli/ui/reducer/commands.ex:272).
Every layer only checks `String.valid?` (UTF-8 well-formedness); none rejects
C0/C1 controls. A bracketed paste containing a raw ESC byte (U+001B) — trivially
produced by copying a cell's rendered text or a colored log line — is stored
verbatim in the editor buffer. The DISPLAY path is safe: the composer runs the
slice through `SafeText`, which escapes ESC, and the cell re-validates before
paint. The EGRESS path is not: the raw editor text goes into `editor_text` and
the only gate, `Intent.valid_context_text?`, is `String.valid?` plus a byte cap,
so the raw ESC leaves the process in the dispatch payload. Any downstream
consumer that echoes it to a terminal, log, or shell re-injects the escape
sequence.
Fix: filter or escape C0/C1 controls at the ingress boundary (`Input.paste/1` or
`Operation.validate({:paste, _})`), and add the same check to
`Intent.valid_context_text?/1` so egress fails closed independently of display.

**6. MEDIUM — the unicode-width CI gate is a hash comparison, not a regeneration
gate.**
[sync_unicode_width.exs](/Users/zaali/dev/swarm-code-cli/scripts/dev/sync_unicode_width.exs:69).
`check!()` only calls `verify_hash!` against pinned constants; `generate_table!`
— the code that actually derives `width/table.ex` from `tables.rs` — runs only
under `--accept`. So the gate cannot detect a bug in the generator, drift
between `tables.rs` and the committed `table.ex`, or a hand-edit that happens to
match the recorded hash. It proves "the file on disk is the file we hashed once",
not "the file is correctly derived from its source". By contrast
`sync_unicode_variants.py` genuinely re-runs `generate()` and compares
byte-for-byte, so the two scripts sitting side by side in the same
`verify_unicode` task have asymmetric strength.
Fix: make `check!()` generate into a temp path and diff against the committed
`table.ex`, as the variants script does.

**7. MEDIUM — `generate_vectors!/0` is a no-op self-copy; the width regression
fixture is 14 hand-written vectors.**
[sync_unicode_width.exs](/Users/zaali/dev/swarm-code-cli/scripts/dev/sync_unicode_width.exs:306).
`atomic_write!(source, File.read!(source))` reads the file and writes it back
unchanged; it never derives vectors from the vendored, hash-pinned
`emoji-test.txt` (otherwise unused). The only consumer, `width_test.exs`,
compares `Width.cells/2` against literals in that same 14-entry fixture. A
3082-line generated table covering 1.1M codepoints is guarded by 14 vectors, and
the regeneration step that should refresh them does nothing. A real width
regression in e.g. the Tifinagh state machine would pass both the hash gate and
the vector test.
Fix: implement `generate_vectors!` to emit vectors from the vendored
`emoji-test.txt` plus a sample of `tables.rs` ranges, or delete the function and
state plainly that vectors are hand-maintained.

**8. MEDIUM — `Width.take_cells/3` is O(n²) and sits on the untrusted-content
wrap path.**
[width.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_cli/lib/swarm_code_cli/ui/width.ex:102).
Each iteration rebuilds `candidate = prefix <> grapheme` and calls `cells/2` on
the entire growing prefix, so one pass over an n-grapheme line costs ~n²/2 cell
operations. Reachable on untrusted long content: `prose.ex` calls `take_cells`
on each remaining tail while wrapping LLM/tool output, and the projector does
the same. Measured shape: 1,000 graphemes ≈ 500K cell-ops; 20,000 ≈ 200M. A
single unbroken 20K-character line from a model response (no spaces, so
`word_lines` falls through to the per-grapheme branch) makes one repaint pass
quadratic, and `Prose.wrap` repeats it per tail.
Fix: carry the running width and parser state through `take_prefix` instead of
re-measuring the whole prefix, or binary-search grapheme offsets as
`editor.ex`'s `cell_boundary` already does for vertical motion.

**9. LOW — `inert_glyph?/1` re-validates with hardcoded `:narrow` while the frame
honors a runtime `:wide` policy.**
[cell.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_cli/lib/swarm_code_cli/ui/paint/cell.ex:28)
and [safe_text.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_cli/lib/swarm_code_cli/ui/safe_text.ex:1569).
`ambiguous_width` is a live capability threaded through the composer and paint
plan, but the second line of defense fixes it to `:narrow`. Verified divergence
is currently narrow: scanning all 1.1M codepoints, exactly two differ — U+FE01
and U+FE0E are width-3 in `:narrow` but width-0 in `:wide`, and both are
variation selectors already caught by `scalar_token`'s `variation?` branch, so
this is not currently exploitable. It is a latent coupling: if a future table
revision makes any printable character zero-width only in `:wide`, `cell.ex`
would admit it while the projector measures it as zero-width, desyncing the
cursor.
Fix: thread the active `ambiguous_width` into `inert_glyph?/2`.

**10. LOW — the Rust frame filter passes non-control invisibles that `SafeText`
escapes.**
[frame.rs](/Users/zaali/dev/swarm-code-cli/native/terminal_port/src/frame.rs:162).
It rejects `is_control()` and the Trojan Source set U+202A–202E / U+2066–2069
(good), but admits ZWSP, ZWNJ, CGJ, SHY, WORD JOINER, BOM, the U+206A–206F
inhibit/activate block, and the Tag range U+E0000–E007F. Defense-in-depth only,
not a live hole: the Elixir producer escapes all of these before they reach a
cell, and the cell re-checks. But the Rust port is the last process before
`write_all`, and it trusts the producer; a bug in or bypass of the Elixir
sanitizer would let invisible homoglyph/tag smuggling through to the terminal.
Fix: extend the frame filter to reject zero-width characters that are not
attested combining marks or validated emoji-join components, so the port is
independently safe.

**11. INFO — raw mode restoration on panic is sound; the guard parent owns it.**
Recorded as verified-not-a-defect because it was in scope. There is no
`panic = "abort"` and no panic hook, so a panic in the writer child unwinds to
`libc::_exit`; the guard parent's loop breaks on `waitpid` and unconditionally
calls `tty.restore()`, which resets termios even when the escape-sequence writes
failed. SIGTSTP/SIGCONT are handled with a Resume barrier. The `.unwrap()` on
`protocol::failure` is safe because all reason values originate from a literal
set the function accepts.

## Low

**12. `tool_command` reports a killed child's status ambiguously and can hold a
zombie on a stuck descendant.**
[native/tool_command/main.c](/Users/zaali/dev/swarm-code-cli/native/tool_command/main.c:142).
`128 + WTERMSIG(status)` for SIGKILL yields 137, indistinguishable from a child
that legitimately exited 137 — acceptable. Combined with the timeout path at
line 139, the `T` and `X` packets are mutually exclusive by construction, so a
command that times out and is killed reports only `T`; that is the documented
contract, so not a defect. The real issue: on Linux `PR_SET_CHILD_SUBREAPER`
(line 67) makes the process inherit all orphaned descendants, and the reap loop
at line 132 runs once per outer iteration. A descendant in uninterruptible sleep
(`D` state, e.g. stuck NFS) is not reapable, and the guardian can sit in the
poll loop holding a zombie.
Fix: bound the post-reap wait with the same `deadline` that governs the child.

**13. `platform_identity` treats a `calloc` failure and a `sysctl` short read as
identical to "desktop not detected".**
[native/platform_identity/main.m](/Users/zaali/dev/swarm-code-cli/native/platform_identity/main.m:106).
`calloc` is checked and `count >= capacity` is rejected, so the buffer cannot
overflow. But an allocation failure or a short `sysctl` read falls through to the
same "not detected" answer as a genuine absence, so a resource-exhausted host is
misreported as desktop-free — which feeds the one-way guard in finding #1.
Fix: distinguish the error paths and fail closed (report "unknown" rather than
"absent") when the probe could not complete.

## Verified inline by the parent (after the reviewer lanes died)

These two scopes had no completed reviewer, so I checked them directly by reading
the code. They are verified by me, not by a child.

**14. INFO (verified) — the tool approval gate IS enforced server-side in the
daemon, not bypassable by a second socket client.**
[run_server.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_daemon/lib/swarm_code/domain/engine/run_server.ex:8)
and [run_server.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_daemon/lib/swarm_code/domain/engine/run_server.ex:664).
The RunServer moduledoc states it "gates operations on user approval", and line
664 puts the operation node into `status: "awaiting_approval"` — the operation
does not execute until the interaction is settled via
`settle_pending_interactions/2`. `pending_interactions/1` is only a read-only
projection for the UI. So the gate is authoritative in the daemon: a second
client connecting to the socket cannot skip an approval, because execution is
blocked inside the RunServer process, not in the UI. This resolves the
tools-providers reviewer's key question in the codebase's favor.

**15. INFO (verified) — the shell tool's path containment is genuinely
symlink-safe, with the prior escapes documented and fixed.**
[path.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_daemon/lib/swarm_code/domain/tools/path.ex:21).
`inside?/2` checks containment twice: once on the expanded path and once after
resolving every symlink of the deepest existing ancestor (`real_path/1`), and
returns an error on symlink cycles or unreadable parents. The comments record
the historical bugs this closes (a `ln -s / esc` inside the repo letting every
path tool read/write anywhere; a grep wildcard following directory symlinks to
`/etc`). `run_command.ex` passes the command to `/bin/sh -c` with no allowlist,
which is by design for a shell tool — its safety rests on the approval gate in
finding #14 plus `clean_env/0` stripping release ERTS variables from children.
Not a defect; recorded so the shell tool is not re-flagged as unguarded.

## Conversion fidelity (from the conversion reviewer's completed analysis)

The conversion reviewer (rev-conversion-r2) ran ~230 targeted probes and reached
conclusions before its delivery envelope failed. Its analysis is reproduced here
because it is the single most valuable result of the run. Severities are its
judgment; the parent spot-checked the two highest-impact claims (mark_seen and
:always_allow) against the cited lines and they hold.

**16. HIGH — `mark_seen` is a dead request path: offered by the UI, validated by
intent and request, then rejected by the codec.**
[codec.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_core/lib/swarm_code/protocol/codec.ex:394).
The chain: the UI offers mark_seen (workspace.ex:384, keymap 'm'); intent.ex:63
defines `{:mark_seen, kind, id, revision}`; request.ex:211 validates it; but
codec.ex has NO `request_body` clause for mark_seen, so it falls through to
`request_body(_) -> {:error, AdmissionError.new(:not_allowed)}` at line 394, and
daemon.ex:674 `request_capability(_) -> nil`. In the original web app this was a
direct `Conversations.mark_seen(conv.id)` DB call (workspace_live.ex:361) with no
wire hop. The fake data source DOES handle mark_seen (compose.ex:81), so tests
pass while production fails. Failure scenario: user presses 'm' to mark a
conversation seen; the TUI shows a not-allowed error; the unread badge never
clears.
Fix: add a `request_body` clause for mark_seen in codec.ex and a capability in
daemon.ex, or remove the UI affordance.

**17. HIGH — `:always_allow` is dead at three layers, and the CLI's always-allow
semantics silently widened from per-command-prefix to per-permission-class.**
[codec.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_core/lib/swarm_code/protocol/codec.ex:382)
and [persisted_backend.ex](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_daemon/lib/swarm_code/daemon/service/persisted_backend.ex:527).
switcher.ex:284 offers `[:approve, :deny, :always_allow]`; intent.ex:159
validates `:always_allow`; but codec.ex:382's guard is
`when decision in [:approve, :deny]`, so `:always_allow` fails the guard and
falls to the not-allowed fallback; service_request.ex:194 rejects the string
'always'; and persisted_backend.ex:527 maps anything != 'approve' to `:deny`.
So the engine's `resolve_approval/3` accepts `:always` but never receives it.
Separately and more seriously: the ORIGINAL remembered an "Always allow" as a
command PREFIX (e.g. "git") and never offered the pill for `:dangerous`
commands; the CLI has no `CommandSafety.classify/1` at all (the module is gone),
`Policy.decide/3` lost its safety parameter, and "Always allow" now remembers
the PERMISSION CLASS (`:execute`) — so approving one shell command
auto-approves ALL shell commands. This is a security-relevant semantic
regression introduced by the conversion.
Fix: restore command-family (prefix) scoping for always-allow and a
dangerous-command classification, or deliberately document the widened
semantics; and either wire `:always_allow` end-to-end or remove the switcher
entry.

**18. HIGH — many PubSub topics have producers but ZERO subscribers, so whole
feature areas silently never update.**
The reviewer enumerated every topic. Zero-subscriber topics with live producers:
`notifications` (5 producers: scheduled.ex:385, run_server.ex:3003/3126/3244/3293),
`settings` (settings.ex:28), `projects` (projects.ex:125), `providers`
(providers.ex:115), `mcp` (mcp.ex:89,93), `scheduled` (7 producers), `storage`
(storage.ex:659), `search_providers` (search.ex:97), `runs` (5+ producers:
conversations.ex:1140/1196/1207/1506, writes.ex:115/173), `research` and
`research:<id>` (many producers). The `ui` topic has one subscriber
(persisted_backend) but its refresh list (persisted_backend.ex:204-228) covers
only 16 event types and IGNORES four that the original web app handled in
ui_topic.ex: `research_runs_changed`, `workflows_changed`,
`workflow_runs_changed`, and `toast`. So research status changes, workflow
definition/run changes, and watchdog toasts are invisible to the TUI. This
confirms the earlier UNVERIFIED hypothesis: broadcasts with no consumer produce
a UI that never updates and no test failure.
Fix: either subscribe the persisted_backend to the missing topics/events, or
delete the dead producers; do not leave silent no-op broadcasts.

**19. MEDIUM — the Scheduler and Watchdog are never started, so scheduled tasks
never fire and storage retention never runs.**
The original started both in its Application children; the CLI daemon's
supervision tree (daemon/service.ex children, session_runtime.ex) starts
neither. `Scheduler.start_link` and the Watchdog have no callers. Consequence:
Library exposes `:schedules` but scheduled tasks never fire; `Storage.apply_retention`
is only called by the Scheduler, so retention never runs; and the Storage
feature is otherwise unreachable (its only other caller was the web SettingsLive).

**20. MEDIUM — MCP servers configured in the DB are not started at boot.**
The original's Bootstrap called `MCP.start_all`; the CLI has no Bootstrap
equivalent and `MCP.start_all` has no callers, so configured MCP servers are
never launched. Likewise `Providers.seed_defaults`, `Attachments.prune_abandoned`,
`Search.adopt_legacy_key`, and `Conversations.mark_interrupted` (boot recovery)
are all dead code — every boot-recovery step the original ran is now unreachable.

**21. MEDIUM — the CLI exit path skips workflow pause, survivor reaping, and
journal flush.**
The original's `Quit.stop_everything` paused active workflows, then
`Engine.stop_all`, reaped survivors, and waited up to 30 s for journal flush.
The CLI does `Engine.stop_all()` then `Application.stop(:swarm_code_daemon)`.
`Engine.stop_run` calls `RunServer.stop` for ALL runs with no workflow check
(whereas `pause_run` does check kind == "workflow"), so workflow runs are
stopped without being paused first. Missing: workflow pause, survivor reaping,
flush wait.

**22. MEDIUM — the CLI dropped 6 tool modules plus CommandSafety and
BackgroundProcs, and run_command lost 5 parameters.**
Original `Tools` registry had FindFiles, Lsp, EditFiles, MessageAgent,
FileOps.MoveFile, FileOps.DeleteFile; the CLI `Domain.Tools` has none of them.
`run_command` lost `yield_ms`, `poll`, `stop`, `max_output_chars`,
`justification` (no yield/background support). `SwarmCode.Tools` (the 6-tool
registry) is entirely dead code in lib (only live_backend.ex:977 references it,
and the TUI uses persisted_backend).

**23. LOW — conversation switching at runtime is limited.**
switcher.ex:77 offers conversation entries and navigate opens
`Watch.open(:workspace, :conversation, id)`, but persisted_backend's `member?`
only allows `id == state.opts[:conversation_id]`, so switching to a different
conversation is refused at the backend. The original remounted the whole
workspace LiveView on switch.

**24. LOW — numerous stale LiveView-era moduledoc/comment references.**
ui_state.ex ("survive LiveView remounts", "started next to the Endpoint"),
cache.ex ("The LiveViews keep reading rows"), settings.ex, run_server.ex:3008
("SwarmCode.Domain.Desktop asks wx whether the window is active"), scheduled.ex:424,
storage.ex:874, conversations.ex:1131, workflows.ex:346, research/events.ex:21,
engine/events.ex:15, questions.ex:3, and the never-called `subscribe/0` in
mcp.ex, providers.ex, projects.ex, search.ex, settings.ex. Mostly stale comments
(dead code), but they mislead readers about what is live.

**25. INFO — web features now UNREACHABLE from the TUI.**
Scheduled-task management, MCP server management, Settings (theme/mode/
reduce_motion/sidebar_width), usage history (HistoryLive), research detail page,
workflows detail page, and command-safety classification. The Library switcher
lists several of these as destinations but the backing behaviour is absent or
never started.

## Refuted (recorded so they are not re-litigated)

- **mix.exs stamp-ordering suspicion — REFUTED.** The suspicion was that
  `File.write!(temporary, platform)` at
  [mix.exs](/Users/zaali/dev/swarm-code-cli/apps/swarm_code_daemon/mix.exs:108)
  writes to a path already moved away by `File.rename!(temporary, destination)`
  at line 107, so nothing lands and the staleness check can never pass. It is
  not a bug: `File.rename!/2` moves the directory entry, the name `temporary`
  ceases to exist, and `File.write!/2` then re-creates it as a brand-new file
  which line 109 renames to `stamp_path`. The reviewer executed the exact
  three-step sequence in isolation and confirmed `dest` holds the binary at
  0o755, `dest.platform` holds the full stamp at 0o644, the temp name is gone,
  and the staleness expression evaluates true. The real build tree agrees:
  `priv/native/swarm-schema-snapshot.platform` and
  `swarm-tool-command.platform` contain the correct triple. The code reads oddly
  but is correct; a clarifying comment is the only worthwhile change.

## Test & verification gaps

- `mix swarm_code.provenance.verify` FAILS (pre-existing). Commit `03bc991`
  changed `apps/swarm_code_core/lib/swarm_code/commands.ex` and
  `apps/swarm_code_daemon/lib/swarm_code/daemon/service/command_dispatcher.ex`
  without re-pinning `provenance/extracted-files.json`. The verify task has no
  re-pin path, and that manifest is the machine-readable record of the
  web-to-CLI conversion, so it should be re-pinned deliberately rather than
  silenced.
- Two test-invocation traps, both confirmed:
  - `mix test apps/swarm_code_cli` from the umbrella root silently runs NOTHING
    (0-byte output, exit 0). It looks like a pass.
  - Running from inside `apps/swarm_code_cli` yields 15 bogus failures because
    the CLI's `mix.exs` does not declare `swarm_code_daemon`, so
    `SwarmCode.Test.LoopbackHTTP` from the daemon's `test/support/` is
    unavailable.
  Only `mix test` at the umbrella root is authoritative.
- The unicode gates are ASYMMETRIC (finding #6): `sync_unicode_variants.py
  --check` is a genuine regeneration gate, but `sync_unicode_width.exs --check`
  is only a hash comparison and cannot catch generator bugs or table drift. The
  width table is further guarded by only 14 hand-written vectors (finding #7).

## Unresolved / not covered

COMPLETED and reflected above: storage-gates, terminal-unicode.

STILL RUNNING / died-on-delivery when handed over: tui-architecture (retry) and
tools-providers (retry) produced no usable output. conversion-fidelity (retry)
died on delivery but its analysis WAS recovered and is reflected above.

FAILED with no usable output — these scopes are UNCOVERED: engine-runtime (both
attempts), ipc-service (both attempts), tui-architecture (first attempt),
conversion-fidelity (first attempt), tools-providers (first attempt),
entry-release. The failures were a tool-misuse bug (the child passed the search
tool's `paths` field as a JSON string instead of an array), not a code problem.

Notably NOT yet covered: run-lifecycle and streaming correctness, socket
permission bits and IPC framing, TUI reducer purity and memory growth,
tool/approval-gate enforcement, release and shutdown correctness, and the full
conversion-fidelity matrix.

This report is therefore a bounded sample, not an exhaustive review.
