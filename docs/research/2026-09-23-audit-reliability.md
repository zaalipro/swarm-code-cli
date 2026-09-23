# rel — SwarmCode CLI trust audit (2026-09-23)

Auditor: rel (Opus 5.5). Scope: crashes, hangs, dead ends, data-safety risks and startup friction in
real use of the release at CLI HEAD cd0b1e8 (`/private/tmp/p70cli/rel-head`) and, for comparison,
the installed 2026-09-17 build (`~/.local/share/swarmcode`), always under a sandbox HOME
(`/private/tmp/p70cli/rel/home*`, copies of the prod DB). Nothing in `~/dev/swarm-code-cli`,
`~/dev/swarm-code` or `~/dev/ailogic` was modified. Real LLM prompts used: 8 (one of them sent by
accident through a TUI dead end, see F6). All screen sessions I created are closed.

Evidence files: `/private/tmp/p70cli/rel/caps/*.txt` (screen hardcopies), `/private/tmp/p70cli/rel/logs/*`
(stderr of every launch, `trace.log`), `/private/tmp/p70cli/rel/exp/*.exs` (+ `.out`, the repro
scripts run through `bin/swarm_code_cli eval` / `rpc`).

## Verdict in one screen

The CLI does boot, resume and answer (launch-to-composer 2.4-4.9 s, clean Esc-q quit in 1.2-1.9 s,
resume works, `/stop` works, a read prompt, an edit and a tiny `/swarm` all completed). Its core
problem is that almost every failure is fatal and silent. A dropped DB connection, a 1-second
stall, or a scene one node too big each close the whole session and stop its runs. The reason is
printed into the alternate screen, where it is wiped. The top issues:

1. **The first-prompt crash is reproduced and root-caused (F1).** Any process killed while it holds
   a DB checkout crashes a pooled connection with exactly the owner's MatchError. The guarded exqlite
   fork closes with `sqlite3_close` (v1), and Ecto's query cache pins prepared statements. The dead
   connection's native handle is then pinned as garbage in the idle `CrossAppLease` heap. Guarded
   cleanup can never finish, and quit raises "Guarded storage cleanup remains pending". A forced GC
   makes it finish, which proves the mechanism.
2. **Approvals cannot be granted in the TUI (F2).** `n` jumps to the run view, which drops the
   interaction from the read model. The dialog then says "Read-only at this size; resize to act"
   at 160x45. There is no other path. Every new project defaults to `approval_mode = auto`, which
   asks for every shell command, and `SWARM_APPROVAL` is ignored in saved sessions. So any turn in
   which the model wants a shell command hangs forever until `/stop`. The owner never saw this only
   because their ailogic project row is `full_access`.
3. **A long transcript in a big terminal kills the session (F3).** At 200x55,
   `Paint.Budget.count_node/1` exceeds `@max_nodes 4096`. `Owner` stops with
   `:terminal_draw_failed`, and the release tears everything down, including the in-flight run.
   This was reproduced four times and traced with `:erlang.trace`.
4. **1-second tripwires everywhere (F4).** Watches carry `timeout_ms: 1000` (DataSource default).
   The daemon's `Connection` closes the whole socket when any request misses its timeout, and the
   client shuts the session down when a delta is not consumed within 1 s. Any stall of 1 s or more
   (busy SQLite writer with `busy_timeout` 15 s, a big snapshot, a GC pause, a SIGSTOP) therefore
   produces "SwarmCode closed: the daemon connection closed". This is the most likely first link
   in the owner's crash chain.
5. **Secrets.** The launcher `set -a`-sources the whole `~/.secrets` (GitHub, npm, Linear, Tavily,
   …) into the BEAM environment. `run_command` passes that environment to every model-chosen shell
   command (no scrub; desktop has `shell_env_scrub` since pass 60). `SessionConfiguration` also
   writes the plaintext API key into the shared `providers` table on every launch (F5).
6. **Startup friction.** `sname` distribution with a fixed node name means a second `swarmcode`
   dies with a raw Erlang error. Every failure exits 0 with a stack trace. There is no plain or
   headless mode in the release, although the too-small screen tells you to "RERUN --plain". The
   schema pin fails closed the moment the desktop at HEAD migrates, and it is 4 migrations, not 3
   (F7-F10).

## Fix order (details per finding below)

1. F1 exqlite/lease close path (small, stops the crash-and-hang on quit) + F4 timeouts (small).
2. F2 approval path (medium): open the dialog without re-scoping, add an approve affordance, and
   honour `SWARM_APPROVAL` per session.
3. F3 scene budget: never stop the session on `capacity_exceeded`; virtualise the transcript.
4. F5 secret hygiene (scrub child env, load only provider keys, never persist plaintext keys).
5. F7-F10 startup: distribution off, non-zero exit codes and human errors, ship `--plain`,
   re-pin schema to desktop HEAD (57 migrations incl. FTS5) before the owner installs it.
6. Then the REVIEW.md leftovers (§3), the orphaned-port hang (F17) and the dead ends (F6, F11-F16).

---

## F1 — crash: first-prompt "daemon connection closed" + "Guarded storage cleanup remains pending"

**What the owner saw.** Reply persisted, then "SwarmCode closed: the daemon connection closed",
MatchError on `db_conn_4` "client #PID exited", "Application swarm_code_daemon exited: :stopped",
then `RuntimeError Guarded storage cleanup remains pending` (persisted_session.ex:279 from :84).

**Reproduced exactly (HEAD release, sandbox home3b/c/d).** The script is
`/private/tmp/p70cli/rel/exp/kill_client.exs`. It starts the guarded Repo through `RepoLauncher`,
warms Ecto's query cache with 16 concurrent `Repo.all`, then kills one process while it is inside
`Repo.checkout`. Output (`kill.out`):

```
[info] Exqlite.Connection (#PID<0.223.0> ("db_conn_1")) disconnected: ** (DBConnection.ConnectionError) client #PID<0.243.0> exited
[error] :gen_statem #PID<0.223.0> terminating
** (MatchError) no match of right hand side value: {:error, %Exqlite.Error{message: "unable to close due to unfinalized statements or unfinished backups", statement: nil}}
    (db_connection 2.10.2) lib/db_connection/connection.ex:167: DBConnection.Connection.handle_event/4
close: {:error, {:cleanup_pending, #PID<0.197.0>}}
launcher STILL ALIVE after 12s (cleanup pending forever)
```

`kill_gc.exs` shows `native connections (pending): 1`. After `:erlang.garbage_collect/1` on every
process, "launcher down after GC: :normal". `kill_find.exs` GCs processes one at a time. The first
process whose GC releases the handle is `{SwarmCode.Daemon.CrossAppLease, :init, 1}`.
The control run (`nokill.out`, no kill) closes normally.

**Root cause chain (all verified in code):**

1. `vendor/exqlite/c_src/sqlite3_nif.c:676-679`. The guarded fork closes bound connections through
   `swarm_bound_close` (`swarm_binding_vfs.c:438`), which calls `sqlite3_close` (v1) instead of
   upstream's `sqlite3_close_v2`. The upstream comment right above (l.668-672) warns that v1
   "will return error if any unfinalized statements, which we likely have, as we rely on the
   destructors".
2. Ecto (`ecto_sql` `execute!/5` + `maybe_update_cache/3`, `deps/ecto_sql/lib/ecto/adapters/sql.ex:1024-1091`)
   stores `%Exqlite.Query{ref: statement}` in the Repo's ETS query cache. So every pooled
   connection always has live statements while the Repo lives. `vendor/exqlite/lib/exqlite/connection.ex:703`
   re-prepares per execute, so the cached ref is never used again but keeps pinning its connection.
3. When a client dies holding a checkout, the pool calls `disconnect`
   (`deps/db_connection/lib/db_connection/connection_pool.ex:152`).
   `Exqlite.Connection.disconnect/2` (`vendor/exqlite/lib/exqlite/connection.ex:249-263`) returns
   `{:error, …}`, and `DBConnection.Connection` does `:ok = apply(mod, :disconnect, …)`
   (`deps/db_connection/lib/db_connection/connection.ex:167`). The result is a MatchError crash;
   the native handle stays open.
4. The pool restarts the slot. `CrossAppLease.handle_call({:authorize_slot…})`
   (`apps/swarm_code_daemon/lib/swarm_code/daemon/cross_app_lease.ex:259-283`) overwrites
   `slots[slot]`, so the old `%{db: ref}` becomes garbage in the idle lease heap and its resource
   destructor never runs.
5. At quit, `close_native_binding/1` (cross_app_lease.ex:452-460) closes only the current
   `state.slots` and then requires `DatabaseBinding.connections == 0`. That count is 1 forever, so
   `RepoLauncher` `:cleanup` retries every 100 ms without end (repo_launcher.ex:255-268). `close`
   replies `cleanup_pending` at 3 s (:250), and `PersistedSession` raises after another 10 s
   (persisted_session.ex:209-218). The VM then exits 0 with a stack trace.

Who gets killed in real use: `Application.stop(:swarm_code_daemon)` at teardown
(persisted_session.ex:201) kills RunServer/AgentServer/ops mid-write. Other killers are
`Task.shutdown(task, 100)` (run_server.ex:307/311/2936/2937), `Process.exit(server, :shutdown)`
for agents (run_server.ex:2815), and the 30 s `query_worker` await. Every such kill is harmless on
the desktop (stock exqlite, `close_v2`) and fatal here.
The owner's MatchError came *before* "Application … exited: :stopped", which fits a kill during
teardown after the TUI had already closed for the F4 reason.

**Data safety.** Low: committed WAL frames are durable (`synchronous: :full`) and the next launch
recovers. The user-visible damage is the session dying, runs being stopped, and a scary stack
trace.

**Exact fix (effort S-M):**
- `vendor/exqlite/lib/exqlite/connection.ex:260` makes `disconnect/2` always return `:ok`. On
  `{:error, _}` for a bound connection, leave the handle to its owner (the NIF keeps it).
- `cross_app_lease.ex:259` (authorize_slot): when replacing an entry whose pid is dead, move
  `existing.db` into `state.retired`. `close_native_binding/1` (:452) then calls
  `Exqlite.Sqlite3.close/1` on current slots **and** retired handles, after
  `:erlang.garbage_collect(self())`.
- `cross_app_lease.ex:231-253` (admit_repo opts): add `prepare: :unnamed`. Ecto then stops caching
  statement refs for the Repo lifetime, so v1 close normally succeeds (verify throughput; SQLite
  prepare is cheap).
- Alternatively, in `sqlite3_nif.c` on SQLITE_BUSY for a bound connection, set
  `conn->close_deferred` and finish the close plus `connections--` in `statement_type_destructor`
  (l.1593) once `sqlite3_next_stmt(db, NULL) == NULL`.
- `repo_launcher.ex:255`: bound `:cleanup` retries (for example 50 × 100 ms). Then reach a
  terminal `:cleanup_unconfirmed` state that `PersistedSession` reports as one human line ("storage
  closed with 1 handle pending; data is safe"), not a raise.
- Regression test: the kill_client scenario as an ExUnit test in `repo_launcher_test.exs`
  (kill a `Repo.checkout` holder, assert `close/1 == :ok` within 3 s).

---

## F2 — dead end + bug: approvals cannot be resolved in a saved session (TUI or plain)

**Repro (TUI, HEAD, 160x45, new project, SWARM_APPROVAL=ask and =auto).** Ask for any edit. The
model reaches for `run_command` first (both times: `tail -c 120 AGENTS.md | od -c`), and the run
goes to "waiting for you" / "NEEDS APPROVAL" with the arguments shown in the right pane.
The only key hint is `! WAITING Waiting for you · 1` and nothing says how to act. `Tab` only
toggles composer/main, Enter/j/k do nothing, and `a` opens a 24-item action menu with no Approve
(search "appro": NO RESULTS). The documented path is Esc, then `n`. `n` navigates to the run view,
and the dialog opens as **"Read-only at this size; resize to act"** with only Cancel
(`caps/r1-p2d.txt`). Esc + `n` again says "Nothing is waiting on you". `/stop` is the only way out.

**Repro (plain presenter through the release, `exp/plain_session_rel.exs`).** It prints
`APPROVAL <id>@<rev>` and `approve …`. `approve` gives `OUTCOME plain-request-4 rejected`, and
`deny` gives `OUTCOME plain-request-5 rejected` (`logs/plain.out:966-973`).

**Root causes.**
1. Backend (both presenters): `persisted_backend.ex:901` builds `node_ids` from
   `grouped_agents` (agent nodes only). Real approvals live on the **op** node (`c0baa1bd…` is the
   `run_command` op). So `persisted_backend.ex:441`
   (`params["node_id"] not in run.node_ids`) rejects every real approval `:not_allowed`.
   The only test (`persisted_backend_test.exs:739-805`) puts approvals on *agent* nodes through a
   fake owner, so it passes.
2. TUI: `reducer.ex:520-541` (`open_interaction`) first navigates to `{:run, id}`.
   `navigate/3` (reducer.ex:1015-1052) re-opens the workspace watch with run scope. That watch is
   refused (the header loses project and model and shows "SAVED · DEV"; `persisted_backend.ex:102-122`
   returns `wire_error(:invalid_request)`), so the slot's interactions vanish.
   `dialog.ex:561-567` then falls back to the misleading `:read_only_resize` text for *any* missing
   or non-pending item.
3. Policy: approval mode is per project (`projects.approval_mode`, default `'auto'`), and
   `policy.ex:11-13` asks for every `:execute` in `auto`. `SWARM_APPROVAL` (advertised in
   `swarmcode --help`) is parsed into `Configuration.from_env` (`runtime/configuration.ex:16`) but
   never applied to the saved session. No CLI surface changes `approval_mode`.

**Exact fix (M):**
- `persisted_backend.ex:901`: `node_ids: Enum.map(ns, & &1.id) ++ Enum.map(pending_for_run, & &1.node_id)`,
  or drop the check at :441 for `:approval_resolve`, whose :444-447 id/node/revision match is already
  authoritative. Add a test with an **op** node from a real RunServer.
- `reducer.ex:520`: open `{kind, id}` over the current destination and navigate only after the
  dialog closes. `navigate/3`: keep the old watch until the new snapshot lands.
- `dialog.ex:561-567`: separate "no longer pending" from "too small".
- Composer and status line: when something is waiting, show `n Review · a Approve · d Deny`, and let
  Enter on a waiting op row open the dialog.
- `SessionConfiguration.prepare/2`: map `SWARM_APPROVAL` to a per-session mode (never silently
  rewrite `projects.approval_mode`). Add a `/approvals ask|auto|full` command.

## F3 — crash: a long transcript in a large terminal kills the session and its runs

**Repro (HEAD, conversation f5c01508 in sandbox home3a: 5 runs incl. an 80-line reply and a 21-op
run).** Launch at 160x45 (fine), then `screen -X width -w 200 55`. Within 1-15 s:
`SwarmCode closed: the terminal port went away.` Reproduced 4×. It first happened *mid-run*: the
in-flight run was torn down by `Application.stop` (`caps/r4-dead.txt`). Traced with
`:erlang.trace` over rpc (`exp/trace3.exs`, `logs/trace.log`):

```
SwarmCodeCLI.UI.Paint.Budget.count_node/1 -> {:error, :capacity_exceeded}
SwarmCodeCLI.UI.Paint.Budget.validate_scene/1 -> {:error, :capacity_exceeded}
SwarmCodeCLI.UI.Paint.build/2 -> {:error, :capacity_exceeded}
```

**Root cause.** `paint/budget.ex:17,174` caps a scene at `@max_nodes 4096`. The projector emits
the whole transcript/ops into the scene, not the visible window, so node count grows with history
× terminal height. `ratatui_port/owner.ex:113-119` turns *any* draw error into
`{:stop, :terminal_draw_failed}`, and `persisted_session.ex:165-166` raises "Saved terminal
failed", which stops every owned run. The same conversation is fine at 160x45, so the failure only
shows on big monitors.

**Exact fix (M):** `owner.ex:116`: on `{:error, :capacity_exceeded}`, do not stop. Ask the runtime
for a degraded frame (the existing minimum-size scene plus "view too large, press End") and keep
the port. Projector: window the transcript to `viewport_rows × 2` items and the ops drawer to its
visible rows. Longer term, scale the budget by `rows × cols`. Add a regression test that projects
this fixture at 250x70 and asserts `Paint.build/2` succeeds.

## F4 — crash/hang: 1-second tripwires close the whole session

- Client: `data_source/daemon.ex:54` defaults `timeout: 1_000`, and `persisted_session.ex:117-118`
  passes none. Watches send `timeout_ms: state.timeout` (daemon.ex:155/510). The client shuts the
  session down when a control goes unanswered, a partial frame lingers, or a delivered delta is not
  consumed within 1 s (daemon.ex:278-290).
- Daemon: `service/connection.ex:136-146` brutal-kills the worker and **closes the connection** on
  any request timeout. `:158-160`: backend DOWN closes the connection too. `persisted_backend.ex:1360-1363`:
  more than 128 queued deltas, more than 1 MiB, or one delta over 128 KiB closes the connection.
- The backend is one GenServer that does every snapshot, command, and ledger write (two durable
  writes per command, `persisted_backend.ex:262-290`) plus PubSub refresh queries. The guarded
  Repo's `busy_timeout` is 15 s (cross_app_lease.ex:243), so one contended write can hold it far
  past the client's 1 s.
- The reason is logged with `Logger.warning` (connection.ex:180) to **stdout**, which is the tty
  under the alternate screen, and is wiped on exit. I saw it only in screen scrollback
  (`caps/r4-dead.txt`: "SwarmCode daemon closed a client connection: a delta could not be
  sent: :closed"). This is why the owner's log shows the teardown MatchError but not the cause.

**Exact fix (S):** give watches the same 30 s deadline as commands (`Init.deadline_ms`) and pass
`timeout: 30_000` in `persisted_session.ex:118`. On a watch timeout, fail that watch
(`wire_error`) instead of `{:stop, :normal}` (connection.ex:143-145). Resync on overflow instead
of closing (persisted_backend.ex:1363: send a `resync_required` and let the client re-snapshot).
In release mode, route Logger to `~/Library/Logs/SwarmCode/cli.log` (config `:logger,
:default_handler, config: [file: …]` in a runtime.exs), and print the last error line after
restoring the terminal.

## F5 — data-safety: every secret in ~/.secrets reaches every model-run shell command; plaintext keys persisted

- `bin/load_provider_env.sh` (`rel/overlays` → release `bin/`) does `set -a; source ~/.secrets`.
  Verified by sourcing it with `env -i`: it exports `AGRENTING_API_KEY GITHUB_ACCESS_TOKEN
  LINEAR_API_KEY LLMOTIONS_API_KEY META_API_KEY NPMJS_ACCESS_TOKEN SWARM_API_KEY TAVILY_API_KEY
  TAVILY_HIKARI_TOKEN …` into the BEAM.
- `domain/tools/run_command.ex:116-137` `clean_env/0` removes only `RELEASE_*`/ERTS variables, so
  every approved or auto-run shell command, MCP stdio server (`mcp/client.ex:596`) and git call
  inherits all of them. One prompt-injected `env | curl …` from a fetched page exfiltrates the
  owner's GitHub/npm tokens. The desktop fixed this in pass 60/61 (`shell_env_scrub` default true,
  `settings/setting.ex:110`), and the column already exists in the CLI's pinned schema but is
  ignored.
- `service/session_configuration.ex:73-78` writes the env API key into `providers.api_key`
  (row "CLI openai_compatible <hash>") on **every** launch. It also rewrites the resumed
  conversation's `chat_provider_id/model/effort` (:19-26) whenever `SWARM_MODEL` etc. are set, which
  they always are, since `~/.secrets` sets them. So opening a desktop conversation in the CLI
  silently switches its model. The sandbox DB already holds a stale loopback row
  `CLI openai_compatible 8d70905d… http://127.0.0.1:9/v1`, and 6 `/private/tmp/swarm-cli-plain.*`
  projects written to the canonical DB by past PTY smoke runs.

**Fix (S-M):** load only `SWARM_*|OPENAI_*|ANTHROPIC_*` from the env file (parse lines instead
of `source`, or source in a subshell and re-export the whitelist). Port the desktop's
`shell_env_scrub`/`shell_env_keep` into `clean_env/0`, dropping `*_KEY|*_TOKEN|*_SECRET` and the
provider variables. Keep the key in memory only: pass it to the provider through the session,
never `Providers.create/update` it, and never re-point an existing conversation without an explicit
`/model`. Make PTY smoke tests use a sandbox HOME.

## F6 — dead end / safety: keystrokes meant for a dialog become a real, tool-using prompt

**Repro (HEAD, home3a, full_access project).** Open Usage from Ctrl-P, press Esc once, then type
`Ctrl-P Checkpoints Enter`. The palette was already open (Esc returned from Usage to it), so Ctrl-P
toggled it **closed**, "Checkpoints" went into the composer, and Enter sent it. The run
(`runs.prompt = 'Checkpoints'`) spent tokens and ran `git tag`, `git stash list`, `git log --all …`,
and `git status` through `run_command` (`caps/r4-dead.txt`).
Separately, fast input into the palette query **drops characters** ("appro" → "appr",
"Conversation 679" → "Conversati"), while the composer keeps every character. So a filter
silently matches the wrong thing.

**Cause.** `Ctrl-P` is a global toggle (`keymap/bindings.ex:103-110`, key at :105). The layer stack returns to
the palette after a library closes, and nothing marks focus moving back to the composer.
**Fix (S):** make Ctrl-P idempotent-open (it closes only when the palette already has focus and
its query is empty). After a layer closes, show the composer as inactive until the user types
`i`/Tab. Buffer query input like the composer, and add a test that stuffs 20 characters in one
packet into the switcher query.

## F7 — friction/crash: a second `swarmcode` dies with a raw Erlang error (fixed node name)

**Repro.** Start `swarmcode` in two terminals (another auditor's session was running):
`Protocol 'inet_tcp': the name swarm_code_cli@macbook seems to be in use by another Erlang node`,
exit 1, nothing else. **Cause:** the release `start` uses `RELEASE_DISTRIBUTION=sname` and
`RELEASE_NODE=swarm_code_cli` (release `bin/swarm_code_cli:33,41`). So every launch also opens
Erlang distribution (epmd plus a listener on all interfaces), with a cookie that
`releases/COOKIE` stores **0644** (`-rw-r--r--`, the same cookie since 09-14, also in
`~/.local/share/swarmcode`). Any local user who reads it can `rpc` arbitrary code into the
session. I used exactly that for tracing (F3).
**Fix (S):** `rel/env.sh.eex`: `export RELEASE_DISTRIBUTION=none` (nothing in the TUI needs
distribution). Generate the cookie at install time with 0600, or drop it. The second instance
then reaches the lease and gets `data_lease_held`, which needs a human sentence (F8).

## F8 — friction: every failure is a stack trace with exit status 0; the log goes to the tty

- Non-TTY: `echo | swarmcode` prints `{exit, terminating, …}` plus
  `** (RuntimeError) SAVED DEV SESSION requires a real terminal and -noinput`, then **rc=0**.
- Schema too new, desktop running, lease held, terminal unbindable, or provider missing: all go
  through `persisted_session.ex:238-241` `unwrap!` into
  `raise "Saved … failed: %SwarmCode.Daemon.StartupError{…}"`. `application.ex:22-28` runs the
  session in a Task under the app supervisor and calls `:init.stop()` in `after`, so the exit
  status is always 0 and the output is an inspected struct plus stack.
- Labels say `SAVED DEV SESSION` in the installed product.
- Logger writes to stdout, which is the tty under the alternate screen, so in-session
  warnings/errors are painted over, and after exit the screen is a stack trace.
**Fix (S):** in the release, catch `StartupError` in `PersistedSession.launch/1` and print
`message` + `action` as two lines on stderr. Then `System.halt(n)` with a distinct status per code
(2 usage, 3 desktop running, 4 schema, 5 lease held, 6 provider missing), instead of
`:init.stop()`. Replace "SAVED DEV SESSION" with "swarmcode". Configure a file log handler in
release `runtime.exs` and print its path on abnormal exit.

## F9 — friction: no plain/headless mode ships; the TUI tells you to use one

`swarmcode` accepts only `[DIR]`/`--help` (`rel/overlays/bin/swarmcode:42-47`). `swarm-code`
accepts `tui`/`--help`, and its help says `Usage: swarm-code tui` with a different variable list
(`release.ex:7-10`). The plain presenter (README "for pipes, CI, SSH") exists only as
`scripts/dev/plain_session.exs`, run via `mix run` in a checkout. The too-small screen still says
**"P EXIT; RERUN --plain"** (`caps/rs-40x10.txt`), and `swarmcode --plain` answers
`unknown option '--plain'` (rc 2). The plain presenter itself works from the release: I ran it via
`bin/swarm_code_cli eval "$(sed 's/Mix.raise(/raise(/' plain_session.exs)"`, and it listed runs,
streamed text, and printed APPROVAL lines. Its approvals are broken only by F2.
**Fix (S-M):** move `scripts/dev/plain_session.exs` into `SwarmCodeCLI.Release.PlainSession`
(replace `Mix.raise`) and add `swarmcode --plain [--ndjson] [DIR]`, auto-selected when stdout is not
a TTY. Add `swarmcode -p "prompt"` (one-shot: send, stream, exit with the run status) for scripts.

## F10 — friction (imminent outage): the schema pin fails closed as soon as the desktop at HEAD runs

The desktop HEAD adds **4** migrations after the CLI pin, not 3:
`20261015000004_messages_fts` (FTS5 virtual table + 3 triggers on `messages` + `rebuild`),
`20261016000001_lsp_servers`, `20261016000002_keybindings`, and
`20261017000004_isolation_backend` (all `settings` columns). I applied exactly that DDL to a
sandbox copy (home4, 57 migrations) and launched HEAD:
`StartupError{code: :schema_incompatible, message: "The canonical database could not pass the
read-only schema probe.", action: "Use a supported SwarmCode version and restore only from a
verified backup."}`, as a RuntimeError stack trace with rc=0 (`logs/mig.err`, `caps/mig.txt`).
The action text suggests data damage when the real remedy is "update the CLI".

**Fix (M, do before the owner installs the desktop):**
1. Re-pin per AGENTS.md: add the four upstream migrations to `priv/domain_repo/migrations`, a
   `Schema.Contract` entry for 6dd8d82, and a regenerated manifest (`generate_manifest.exs`), and
   bump the pinned counts in the daemon schema tests.
2. The vendored SQLite has FTS5 (`vendor/exqlite/Makefile:116`), and `sb_authorize` denies only
   ATTACH/DETACH (`swarm_binding_vfs.c:371-374`), so the `messages_fts_*` triggers will fire from
   CLI inserts. Test an insert, update, and delete of `messages` under the guarded Repo.
3. Change the `schema_incompatible` action to name the two versions and say "update swarmcode".
4. Longer term, accept *additive* unknown migrations (new nullable/defaulted columns, new tables)
   read-write when the probe proves the pinned subset intact. The desktop migrates every pass,
   so fail-closed on any unknown migration guarantees a broken CLI every week.

## F11 — bug: stopped ops keep showing "awaiting approval" forever

After `/stop` of a run blocked on approval, the DB node is `op|stopped` (verified in the sandbox
DB), but the transcript and OPERATIONS drawer still say "run_command awaiting approval". After a
relaunch it reads "awaiting approval 5m 34s" (`caps/r2-boot.txt`). The label comes from the node's
progress text, not its status. **Fix (S):** derive the op line from `status` when it is terminal
(persisted projection), and emit a node delta on stop.

## F12 — friction/data-safety: the release bakes the builder's home into sys.config

`config/config.exs:6-9` evaluates `domain_config_dir` at **build** time, and the release's
`sys.config` contains `/Users/zaali/.config/swarm-code`. Any other user or machine, and every
sandbox HOME, reads and writes user-scope workflows and commands in the builder's directory.
**Fix (S):** move it to `config/runtime.exs` (or resolve `System.user_home!()` at call time).

## F13 — data-safety: running the desktop alongside the CLI still races (REVIEW #1 holds, with nuance)

The CLI checks for the desktop only at startup (`foundation_gate.ex:119`, bundle
`com.zaali.swarmcode`, `platform/macos.ex:12`; it matches `/Applications/SwarmCode.app`). The
desktop at 6dd8d82 has no lease awareness (no `instance_lease`/`instance_owner` in `lib/`) and
uses stock `exqlite 0.39.0`. SQLite pages are **not** at risk: the binding VFS uses the standard
unix shm lock bytes (DMS byte 128 held shared, lock slots 120+i via `fcntl`;
`vendor/exqlite/c_src/swarm_binding_vfs.c:140-148,191`). The application state is at risk. The
desktop's boot recovery (`lib/swarm_code/bootstrap.ex:22-45` → `Conversations.mark_interrupted/0`)
marks the CLI's live runs `interrupted`, and both processes would run engines on the same rows.
**Fix (M):** have the desktop's `Bootstrap` read `instance_owner.json` and refuse to start, or
start read-only, when the owner pid is alive. That is a small desktop-side patch, the only way to
make the guard two-way. Until then, the CLI should re-run `detect_desktop` every 30 s and pause
new turns when the desktop appears.

## F14 — bug: nothing the desktop does at boot happens in the CLI (REVIEW #19/#20 hold)

`domain/runtime.ex:6-18` starts no Scheduler, no Workflows Watchdog, and no MCP servers.
`Conversations.mark_interrupted`, `MCP.start_all`, `Providers.seed_defaults` and
`Attachments.prune_abandoned` have 0 callers. So scheduled tasks never fire, configured MCP
servers (e.g. the owner's `tavily`) are absent, and a run left `running` by a hard kill (SIGKILL,
OOM, power loss) stays `running` forever in the CLI. Teardown paths do stop runs cleanly: no
`running` rows remained in my sandboxes after F3/F1 teardowns. **Fix (S-M):** add a
`SwarmCode.Daemon.Bootstrap` step after `RepoLauncher` is live that runs `mark_interrupted` (only
for runs not owned by a live RunServer) and `MCP.start_all`. Start the Scheduler only when the
user opts in (`SWARM_SCHEDULER=1`), since the desktop may be the owner of scheduled tasks.

## F15 — data-safety: the canonical DB collects test and accident rows

The prod DB copy contains 6 projects `/private/tmp/swarm-cli-plain.*` (2026-09-09) and a provider
`CLI openai_compatible 8d70905d…` pointing at `http://127.0.0.1:9/v1` (a test fixture), so some
smoke run wrote into the real canonical DB. AGENTS.md says tests never do. Every launch in a new
directory creates a `projects` and a `conversations` row *before* the terminal is bound. My failed
no-TTY launch left conversation `cb9d56c9…` behind, so `swarmcode` typed in `~/Downloads` by
mistake leaves a permanent project. **Fix (S):** create the conversation lazily on first send.
Make `test_*_pty.py`/`run_plain_session.sh` smoke tests set a sandbox HOME. Ship a one-off
idempotent cleanup (backup + quarantine first, per the desktop AGENTS.md) for the 6 temp projects
and the loopback provider.

## F16 — perf: startup/quit numbers (no action needed yet)

Launch-to-composer on a 49 MB DB: HEAD 2.4 / 3.3 / 3.6 / 4.2 / 4.7 / 4.9 s; the 09-17 build
2.6-2.9 s. Esc-q quit: 1.2-1.9 s. `/swarm` with one worker: 53 s end to end (model time). Resize
across all size classes is correct, and below 50x14 a fallback screen is shown (but see F9's
"--plain" hint).

---

## F17 — hang: the terminal port outlives a failed session and wedges the terminal

**Observed.** After two sessions failed around terminal binding (the no-TTY `script` run gave
"SwarmCode closed: the terminal could not be bound" / `:terminal_initialization_failed`, and one
launch had its screen window killed during startup), two `swarm-terminal-port --beam-port` processes
stayed alive with **PPID 1** in state `U`/`?s` for 7-12 min. Even `ps -p` on them hung. While they
lived, every new `screen` window hung in `login -pflq … (state U)`. `kill -9` on the two ports
released all four stuck `login`s at once.
**Cause (likely).** `ratatui_port/owner.ex` closes the Port (EOF on stdin) but never kills the OS
process. A port blocked opening or restoring `/dev/tty` of a vanished pty never sees the EOF.
**Fix (S):** on init failure, timeout or terminate, `Port.info(port, :os_pid)` → `kill -TERM`, then
`-KILL` after 500 ms. In Rust, open `/dev/tty` with `O_NONBLOCK|O_NOCTTY` plus a bounded wait, and
exit on SIGHUP. Add a PTY-suite case "pty closed during bind → no surviving helper".

## §3 REVIEW.md (2026-09-20) verified at HEAD cd0b1e8

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| 1 | one-way desktop/CLI guard | **holds** (app-level, not page-level) | F13 |
| 2 | guarded Repo lacks `:immediate`, busy 2 s | **fixed at HEAD** (8988e3a: `cross_app_lease.ex:243-245` busy 15 s, timeout 15 s, immediate). The installed 09-17 build still had 2 s/5 s/deferred. The 15 s busy wait now conflicts with the 1 s watch timeout (F4) | |
| 3 | `Storage.batch_delete` hard match, no failure broadcast | **fixed** (9d1f223, `storage.ex:691,696,840,918`) and moot, since Storage runs only from the Scheduler, which is never started (F14) | |
| 4 | backup gate downgrades a committed artifact | not re-verified. `gate.ex` changed in 8988e3a (+16/-4) and is reached only on `migration_required` | |
| 5 | paste control chars reach egress | **holds**: `ui/input.ex:144-150`, `editor/operation.ex:120-123`, `intent.ex:88-90` check only `String.valid?` | |
| 6,7 | unicode gate is hash-only; vectors hand-written | not re-verified (not a reliability issue) | |
| 8 | `Width.take_cells` O(n²) | **holds**: `width.ex:102-115` re-measures `prefix <> grapheme` per step | |
| 9-12 | cell/frame filters, tool_command zombie | not re-verified | |
| 13 | platform_identity fails open | **refuted**: allocation/sysctl failures `return 1` (`native/platform_identity/main.m:103-110,116-118`), which the Elixir side maps to `macos_platform_helper_unavailable` (`foundation_gate.ex:466-478`) and fails closed | |
| 14 | approval gate is server-side | **holds**, so strictly that real approvals are rejected (F2) | |
| 16 | `mark_seen` dead on the wire | **holds**: client `data_source/daemon/codec.ex:394` fallback, no clause, no backend handler | |
| 17 | `:always_allow` dead; widened semantics | **holds**: `codec.ex:382` guard, `persisted_backend.ex:527` maps non-approve to deny, `policy.ex:11-13` remembers the `:execute` class. Nuance: `CommandSafety` never existed at fb1b4ff (desktop added it later), so this is drift, not a conversion loss | |
| 18 | PubSub producers with no consumer | **holds** for `ui`: `research_runs_changed`, `workflows_changed`, `workflow_runs_changed`, `toast` have 0 references in `persisted_backend.ex` | |
| 19 | Scheduler/Watchdog never started | **holds** (`domain/runtime.ex:6-18`) | F14 |
| 20 | boot-recovery steps dead | **holds**: `mark_interrupted`, `MCP.start_all`, `seed_defaults`, `prune_abandoned` have 0 callers | F14 |
| 21 | exit skips workflow pause and reaping | **holds** (`persisted_session.ex:196-203`: `Engine.stop_all` + `Application.stop`) | |
| 22 | 6 tools + CommandSafety + BackgroundProcs dropped | **refuted as a conversion loss**: `domain/tools/` equals desktop@fb1b4ff `lib/swarm_code/tools/` file for file. The missing tools are desktop passes 54-69 (drift, needs a domain re-sync) | |
| 23 | runtime conversation switch refused | **holds** (`persisted_backend.ex:1285`) | |

Additional test evidence: `mix test persisted_backend_test.exs:739` passes ("multiple approvals
require the exact selected node", `logs/test_pb.out`). It uses agent-node approvals with a fake
owner, which is exactly why F2 escaped.

## §4 Startup friction: what a new user must do today

1. Build: the installer runs `build_release.sh`, which needs mise, Erlang/Elixir, Rust 1.97, cc,
   python3 and codesign. There is no prebuilt artifact.
2. Provider: `~/.secrets` (or `SWARM_ENV_FILE`) with `SWARM_MODEL`/`SWARM_BASE_URL`/`SWARM_API_KEY`,
   **or nothing**. With an empty env file the session opens on the desktop's default provider
   (`settings.default_chat_provider_id`, plaintext `providers.api_key`), which I verified. The desktop
   at 6dd8d82 does not use the Keychain at all (no references in `lib/`). When it moves to Keychain
   references, the CLI will send the reference as the key.
3. Quit the desktop. The message is good (`foundation_gate.ex:1408-1417`: "Quit the detected
   com.zaali.swarmcode desktop (PID n) …") but is buried in a RuntimeError stack (F8). Opening
   the desktop *while* the CLI runs is undetected (F13).
4. One instance only (F7). Real TTY ≥ 50x14 only, with no pipe/CI mode (F9).
5. Shell commands in any new project need approvals, which do not work (F2). The workaround today
   is to set the project to Full access in the desktop Settings.
6. The moment the desktop at HEAD runs once: nothing works until the CLI re-pins (F10).

## §5 Not covered / caveats

- I could not trigger F4's timeout on demand: my SIGSTOP probe came after F3 had already killed
  that session. The code paths are unambiguous, and the owner's log fits "F4 closes the socket,
  then F1 on teardown". I saw the "SwarmCode daemon closed a client connection: a delta could not
  be sent: :closed" warning myself (after F3).
- All my screen sessions are closed and no process of mine is left. The four stuck `login`
  processes cleared once I SIGKILLed the two orphaned terminal ports (F17).
- Not tested: `/attach`, workflows, deep research, the companion web page, Anthropic provider,
  vim keymap, Linux.
