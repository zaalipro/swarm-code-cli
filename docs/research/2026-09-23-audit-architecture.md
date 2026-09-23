# Pass 70 CLI audit: architecture (auditor "arch", 2026-09-23)

Scope: how `~/dev/swarm-code-cli` gets the desktop's current engine and keeps it, and what the
CLI has to expose before it is useful. I read both repos (read-only git only), ran a mechanical
re-sync experiment in a scratch APFS clone (`/private/tmp/p70cli/arch/cli`), and drove the
release TUI once in my own sandbox HOME. That session made one real LLM call, through the
desktop's own provider row with no `SWARM_*` environment.

## 0. Verdict

- **Re-syncing is mechanical, and I measured it.** I took all 160 desktop `lib/swarm_code/**`
  files at HEAD `6dd8d82` (the 128 already extracted plus 32 new ones) and put them through
  seven rewrite rules. Then I three-way merged the 14 files that carry CLI-local patches
  (base = rewritten `fb1b4ff`, ours = the CLI copy, theirs = rewritten HEAD, all
  `mix format`-normalised). Result: **0 conflicts, and the daemon compiles with 0 warnings**
  (`mise exec -- mix compile`, 25 s incremental). Without the merge the only fallout was two
  undefined functions, `RunServer.answer_question/5` and `pending_interactions/1`, which are
  the CLI patch, plus two `Phoenix.HTML` calls handled by rule 7.
- **Compiling is not the same as running.** The HEAD domain reads the three `settings` columns
  added by migrations 20261016000001/2 and 20261017000004. So the sync is only usable
  together with the schema re-pin to HEAD's 57 migrations and a forward migration of the
  53-migration prod DB. That migration takes a verified backup and is additive. There are
  **four** new migrations, not three: `20261015000004_messages_fts` also lands after the
  CLI's pin.
- **Timing matters.** The CLI fails closed (`schema_incompatible`) the moment the owner
  installs the desktop at HEAD. `Schema.Gate.verify_prefix/2` accepts only a prefix of the
  CLI's own 53-entry manifest (`apps/swarm_code_daemon/lib/swarm_code/daemon/schema/gate.ex:128-143`).
  The re-pin is therefore mandatory for this pass, not optional.
- **Recommendation for this pass: (a).** Re-sync the fork to `6dd8d82` now with a repeatable
  `mix swarm_code.provenance.sync` tool, re-pin the schema, and wire the HEAD runtime
  (supervisors, boot recovery, shutdown). Then spend the rest of the pass on the service
  boundary and the TUI. The other two options:
  - **(b) path dependency: reject.** It fails on module collisions, a dependency conflict, the
    desktop `Application`, and a repo rule (§4).
  - **(c) attach to a running desktop: defer.** It is the right long-term shape, with one DB
    owner and the one-way lease gone, but it needs a desktop-side API that this pass may not
    build (§4).
- **Why it feels useless today.** It is not only the missing engine features:
  1. The first-prompt crash has a concrete root cause: the vendored exqlite's guarded close
     uses `sqlite3_close` v1 (§6 F1).
  2. Only one conversation per process: no list, no new, no switch.
  3. A fixed Erlang node name allows one `swarmcode` per machine.
  4. The CLI overrides the conversation's model with `~/.secrets` values on every launch and
     writes plaintext-keyed "CLI …" provider rows into the canonical DB.
  5. It looks for global memory, skills, commands, workflows and attachments in
     `~/.config/swarm-code` instead of the desktop's `~/Library/Application Support/SwarmCode`.
  6. MCP servers, boot recovery and notifications never start.
- **Providers already work if you get out of their way.** With every `SWARM_*`, `OPENAI_*` and
  `ANTHROPIC_*` variable unset, the release TUI opened on the desktop default
  (`deepseek-v4-pro` via the `llmotions` row). It answered a prompt (5.2k tokens, $0.01) and
  quit cleanly. `/model` listed 145 DB models (captures `/private/tmp/p70cli/arch/cap1.txt`,
  `cap2.txt`). HEAD has **no Keychain code**: `grep -ril keychain lib` in the desktop is
  empty and `providers.api_key` is a plaintext column. The CLI can use the DB rows as they are.

## 1. Drift: what passes 54-69 added that the CLI fork lacks

`git diff --stat fb1b4ff..HEAD -- lib/swarm_code`: 110 files, +13 983 / -1 138, 32 new files,
0 deleted. Commits per pass: 54-65 about 15; 66: 74; 67: 46; 68: 53; 69: 131 (pass 69 has
no CHANGELOG entry yet, so read the commit subjects). The CLI has the DB **schema** of `ccb1973`
(pass 63, 53 migrations) but the **code** of `fb1b4ff` (pass 53).

Value to a terminal user, highest first. Files are desktop paths.

| Tier | Capability (pass) | Desktop files | Why a terminal user cares |
|---|---|---|---|
| A | Shell rewrite: exits on process exit, not on pipe close; timeout hands over output; `yield_ms`/`poll`/`stop` background commands; 160k/512k output budget; login shell + `workdir`; env scrub (60, 62, 63) | `tools/run_command.ex` (+821), `tools/background_procs.ex` (new, 347), `os_process.ex` | Test suites and dev servers are the core coding loop. At fb1b4ff a long `mix test` is killed and truncated to 40k. |
| A | Command classification, per-family "Always allow" (`{:always_prefix, "mix test"}`), "Deny & stop" (60, 62) | `tools/command_safety.ex` (new, 432), `engine/policy.ex`, `run_server.ex:152-160,1583-1620` | Removes the approval-spam or YOLO dilemma. The CLI's widened per-class always-allow (REVIEW #17) disappears by syncing. |
| A | Editing: line-fuzzy `edit_file`, multi-edit, `edit_files` all-or-nothing, `move_file`/`delete_file`, `.git`/`.claude`/`MEMORY.md` protected (61, 67) | `tools/edit_file.ex` (+453), `tools/edit_files.ex`, `tools/file_ops.ex`, `tools/path.ex` (+196) | Fewer failed edits and fewer "old_string not found" loops. |
| A | Context: real per-model window, auto-compaction at 80 %, overflow survival, inline compaction, hysteresis trim for a stable prefix (warm cache), `prompt_cache_key`, AGENTS.md root-down, `<environment>` block, doom-loop guard (61-63, 67, 68) | `engine/context.ex`, `agent_server.ex` (+973), `engine/prompts.ex`, `engine/project_context.ex` | Long sessions stop dying on context overflow. Cheaper, because of cache hits. |
| A | Typed errors, rate-limit headers, stop reasons (`turn_budget`, `doom_loop`, `user_stopped`, `spawn_timeout`, …) (63, 68) | `llm/error.ex` (new), `llm/http.ex` (+196), `conversations/node.ex` | The terminal can say *why* something stopped and when to retry. |
| A | Project trust: new projects are read-only and hide the repo's AGENTS.md until trusted; hooks run only when trusted (63, 69) | `projects.ex`, `project_config.ex`, `hooks.ex` | Security. It also **changes CLI UX**: every new directory is read-only until the TUI offers "Trust" (seam C/E). |
| B | Code intelligence: `lsp` tool (14 languages), `find_files`, ripgrep prefilter, `FuzzyMatch` (67) | `lsp*.ex` (4 files, about 720 lines), `tools/find_files.ex`, `tools/ripgrep.ex`, `fuzzy_match.ex` | Better navigation in big repos. It also gives a file finder for the composer (`@file`). |
| B | Sub-agent orchestration: agent definitions (`scout`/`reviewer`/`implementer` + user/project `.swarm_code/agents`), per-spawn model/effort, prewalk, background spawn, mailboxes (`message_agent`/`inbox`/`wait_for_message`), `agent_result`, structured output, soft turn budget (67, 68, 69) | `agents.ex`, `agents/agent_def.ex`, `tools/{spawn_agent,message_agent,inbox,wait_for_message,agent_result}.ex`, `priv/agents/*` | Swarms become useful and cheaper. The TUI's agent view gets real content: model chip and stop reason. |
| B | Copy-on-write isolation (`clone` via `cp -c`, `worktree`), baseline/delta patches, `git apply --3way --check`, ownership markers (68, 69) | `engine/isolation/*` (7 files, about 750 lines), `git.ex` (+201), `tools/integrate_agent.ex` | Parallel workers stop trampling each other. |
| B | Project config `.swarm_code/config.json` + profiles, lifecycle hooks (`session_start`, `pre_tool_use`, `post_tool_use`) (67, 69) | `project_config.ex`, `hooks.ex` | Codex/Claude-Code parity for teams. |
| B | MCP hardening: a single failed call keeps the server alive, protocol-version header, HTTP session DELETE, 64-char names, per-tool disable, images, notifications, bounded buffers (55, 56, 62, 63, 69) | `mcp/client.ex` (+709), `mcp.ex` (+270) | The owner's tavily MCP. It only matters once the CLI actually starts MCP (F7). |
| C | Cross-session FTS search, Markdown export, run diff from checkpoints, telemetry spans (63, 67) | `conversations.ex` (+213), `conversations/export.ex`, `checkpoints.ex` (+224), `engine/telemetry.ex` | `/search` and `/export` are natural terminal commands. |
| C | Web-only sidebars; research/workflow polish; storage prune fixes (57-59, 66, 69) | `workflows/sidebar.ex`, `scheduled/sidebar.ex`, research/* | Low. Sync them for provenance, but they need no TUI now. |

Not domain code, and not synced: `application.ex`, `bootstrap.ex`, `desktop*.ex`, `quit.ex`,
`tray_menu.ex`, `menu_bar.ex`. The CLI needs its own equivalents of `Bootstrap.run/1` and
`Quit.stop_everything/0` (§3.4).

## 2. How mechanical is a re-sync?

### 2.1 What the CLI changed in the extracted files (fb1b4ff → CLI copy)

The script is `/private/tmp/p70cli/arch/cmp2.py`. For every provenance entry under `domain/` it
applies the namespace rewrite and compares the result with whitespace and parentheses removed.
**90 of the 128 files are identical.** The 38 that differ break down like this:

- **Pure mechanics (about 30 files).** `Phoenix.PubSub.*` becomes `SwarmCode.Domain.PubSub.*`,
  a Registry-backed shim (`domain/pub_sub.ex`). `SwarmCode.Desktop.notify*` becomes
  `SwarmCode.Domain.Notifications.*`. `SwarmCode.Desktop.config_dir()` becomes
  `SwarmCode.Domain.Paths.config_dir()`. `SwarmCodeWeb.{Chat,Markdown,MarkdownCache,UIState}`
  become `SwarmCode.Domain.*`. `:swarm_code` becomes `:swarm_code_daemon`. `@table
  :swarm_code_provider_caps` becomes `__MODULE__`. On top of that, `mix format` runs without
  Ecto's `locals_without_parens`, which is why symmetric diffs such as `settings/setting.ex`
  71+/71- are only `field(...)` parentheses.
- **Real CLI-local patches, 4 files:**
  - `engine/run_server.ex`, +221: `answer_question/5` (answers one question at a time) and
    `pending_interactions/1` (a bounded, redacted projection), with helpers.
  - `storage.ex`, +105/-29: a transaction test seam plus the `{:storage_failed, _}` broadcast,
    from commit 9d1f223.
  - `repo.ex`, +19: `init/2` admits only the guarded lease pool.
  - `engine/prompts.ex` and `conversations/writes.ex`: formatting only.
- **Shims kept from the web layer:** `chat.ex` keeps 77 of 5 600 lines (`launch_messages/3`
  only), plus `markdown.ex`, `markdown_cache.ex`, `ui_state.ex` and `html.ex`
  (a `Phoenix.HTML` stand-in).

Two parallel stale copies sit outside `domain/`:

- `lib/swarm_code/llm/*` (11 files) and `lib/swarm_code/tools/*` (9 files) are
  **un-namespaced** `SwarmCode.LLM.*` and `SwarmCode.Tools.*`.
- `daemon/runtime/run.ex` (1 085 lines) is a copy of `agent_server.ex`.

All three serve only the transient "live/unsaved" launcher, which the release does not use.
Two exceptions: `PersistedBackend.init/1` calls `SwarmCode.Tools.Path.real_path/1`
(`persisted_backend.ex:45-46`), and the same copy is what makes option (b) collide (§4).

### 2.2 The experiment: HEAD into the CLI

The artefacts are in `/private/tmp/p70cli/arch/`:

- `sync.py` does the rewrite and copy.
- `merge3.sh` normalises the three sides with `mix format`, then runs `git merge-file`.
- `cli/` is the scratch APFS clone.

The seven rewrite rules, applied in order:

1. `SwarmCode.Desktop.(notify|notify_waiting|notify_finished)(` becomes `SwarmCode.Notifications.\1(`.
2. `SwarmCode.Desktop.config_dir()` becomes `SwarmCode.Paths.config_dir()`.
3. `SwarmCodeWeb.(Markdown|MarkdownCache|UIState|Chat)` becomes `SwarmCode.\1`.
4. `\bSwarmCode\.(?!Domain\b)([A-Z{])` becomes `SwarmCode.Domain.\1`. This also covers
   `alias SwarmCode.{…}`.
5. `Phoenix.PubSub.(subscribe|unsubscribe|broadcast…)(` becomes `SwarmCode.Domain.PubSub.\1(`.
6. `:swarm_code` (not followed by `_`) becomes `:swarm_code_daemon`.
7. `@table :swarm_code_provider_caps` becomes `@table __MODULE__`, and `Phoenix.HTML.` becomes
   `SwarmCode.Domain.HTML.`.

Results:

- Copying the 160 HEAD files (all of `lib/swarm_code/**` minus the 8 desktop-only files) plus
  `priv/agents/**` and `priv/workflows/**`, with no merge, gave 4 compiler warnings: the two
  CLI-only RunServer functions and two `Phoenix.HTML` calls in `research/html_render.ex:309,356`.
  Rule 7 fixes the latter.
- The 3-way merge of the 14 CLI-patched files (run_server, storage, conversations, engine,
  research/{events,html_render,server}, scheduled, settings, mcp, search,
  tools/workflow_tools, conversations/writes, projects) was **clean for all 14**.
- After that, and after restoring the CLI `repo.ex`: **`Generated swarm_code_daemon app`, no
  warnings**. The CLI app compiled unchanged against it, because nothing in `swarm_code_cli`
  reaches into the domain.

Still to do after the files land. These are CLI-local and outside provenance:

- `domain/runtime.ex` must start `Tools.BackgroundProcs`, `LSP.Supervisor` and
  `{Task.Supervisor, name: Hooks.TaskSupervisor}`. HEAD's `application.ex:31-66` shows the
  full list.
- A boot step: `Conversations.mark_interrupted/0`, `Scheduled.reconcile_claimed/0`,
  `Providers.seed_defaults/0`, `Search.adopt_legacy_key/0`, `MCP.start_all/0`,
  `Bootstrap.sweep_researches/0`, `Attachments.prune_abandoned/0` and
  `Isolation.Ownership.cleanup_stale/2`. HEAD's `bootstrap.ex:16-56` is the reference.
- A shutdown step equivalent to `Quit.stop_everything/0`: pause workflows, `Engine.stop_all`,
  kill `BackgroundProcs.list_all/0`, stop the LSP clients.
- Tests. The CLI has no `LLM.Fake` and no desktop `Fixtures`/`DataCase`. The 12 upstream tests
  it carries are pure units. Engine regression coverage for the synced code has to come from
  the CLI's own loopback-HTTP tests, or from porting `test/support/fake_provider.ex`.

### 2.3 The sync tool the CLI should own (`mix swarm_code.provenance.sync`)

Today `swarm_code.provenance.verify` only checks each destination's sha256 against the
manifest (`governance/provenance.ex:112-136`). `repin` only rewrites that one field
(`swarm_code.provenance.repin.ex:1-17`). Neither knows how to fetch upstream, so every past
update was done by hand.

The proposed task: `mix swarm_code.provenance.sync --upstream ~/dev/swarm-code --ref <sha>
[--check]`

1. Refuse unless the upstream worktree is clean and `<ref>` exists. Read only through
   `git show <ref>:<path>` and `git ls-tree`, with no checkout, the same way
   `priv/schema/generate_manifest.exs:211-260` already does.
2. Take the file set from the manifest entries plus the rules file
   `provenance/sync-rules.json`: include `lib/swarm_code/**`, `priv/agents/**`,
   `priv/workflows/*.exs` and `priv/repo/migrations/*`; exclude the 8 desktop-only files; map
   `lib/swarm_code/X` to `apps/swarm_code_daemon/lib/swarm_code/domain/X`. A new upstream file
   becomes a new manifest entry.
3. Rewrite with the ordered regex table (§2.2), then `mix format`.
4. For each file with a CLI-local patch, run the 3-way merge (base = rewrite(pinned upstream),
   ours = current, theirs = rewrite(new upstream)). Stop on conflict and leave `.orig`/`.rej`.
   Keep the patch small by moving the RunServer projection helpers into a daemon module
   (§7 owner C).
5. Write `upstream_commit`, `upstream_sha256` and `sha256` for each entry.
6. `--check` mode (for precommit): re-derive every synced file from the pinned commit and fail
   on a difference. That turns "the CLI silently diverged" into a red gate.

Effort: M, about half a day. It is the one tool that keeps the CLI current after this pass.

### 2.4 Schema: re-pin, both schemas, who migrates

- **Re-pin procedure** (AGENTS.md, end of Architecture):
  - Add a `Schema.Contract` entry for `6dd8d82`: 57 migrations, `last_version`
    20_261_017_000_004, `snapshot_versions` extended with 20261015000004, 20261016000001,
    20261016000002 and 20261017000004. Its three digests come from a first generator run.
  - Run `priv/schema/generate_manifest.exs` with absolute `--output`/`--fixtures-dir`. It reads
    upstream via `git ls-tree`/`git show` and requires a clean worktree
    (`generate_manifest.exs:211-227`). The desktop is clean at HEAD.
  - Point `FoundationGate`'s `@manifest_source` (`foundation_gate.ex:24`) at
    `desktop-6dd8d82.json`.
  - Add the 4 migrations to `priv/domain_repo/migrations` with provenance entries.
  - Bump the pinned counts in `foundation_gate_test.exs:988` and
    `schema/migration_manifest_test.exs:44-45`.

  Effort: M.
- **Accepting both 53 (prod) and 57 (HEAD) is possible, with one caveat.** `verify_prefix/2`
  (`schema/gate.ex:128-143`) already accepts any manifest prefix whose schema hash matches. With
  a 57-entry manifest, a 53-DB becomes `:migration_required` with 4 pending migrations. The
  `FoundationGate` then takes a **verified backup** (`foundation_gate.ex:757-800`,
  `Backup.Gate.create/6`), and `RepoLauncher.run_migrations/4` (`repo_launcher.ex:115-137`)
  migrates it to 57. A 57-DB is `:ready`.
- **The CLI cannot run HEAD code against a 53-DB without migrating.** `Settings.Setting` at HEAD
  selects `lsp_servers`, `keybindings` and `isolation_backend`, and SQLite answers "no such
  column". "Both" therefore means "53 → backup → migrate → 57".
- **Is migrating ahead of the installed desktop safe here?** Yes, for these four:
  - Three are `ALTER TABLE settings ADD` with defaults, one of them `NOT NULL DEFAULT 'auto'`.
  - One is an FTS5 content table plus triggers on `messages`.
  - An older desktop ignores unknown applied versions (`Ecto.Migrator` runs only its own
    pending ones) and its schemas do not select the new columns.
  - The triggers need FTS5 on the desktop too: stock exqlite 0.39 compiles
    `-DSQLITE_ENABLE_FTS5=1` (`deps/exqlite/Makefile:113`), and so does the CLI fork
    (`vendor/exqlite/Makefile:116`).
- **What must NOT happen:**
  1. The CLI migrates past a migration that is not forward-compatible with the installed
     desktop. Make the gate refuse `:migration_required` unless every pending version is in an
     explicit `forward_compatible` allowlist in the contract (the four above). Otherwise it
     should say "open the SwarmCode app once to upgrade the database".
  2. The CLI starts while the desktop runs. The lease is one-way (REVIEW #1), and the desktop
     never checks `instance_lease.db`.
  3. Dev sessions or tests write to the canonical DB. The sandbox copy of prod holds 6 projects
     under `/private/tmp/swarm-cli-plain.*` (2026-09-09) and a provider row
     `CLI openai_compatible 8d70905d…` → `http://127.0.0.1:9/v1` `test-model` that 6
     conversations point at. The `/model` picker lists it first (`cap1.txt`).
  4. A DB that is *ahead* of the manifest gets accepted. It is refused today; keep that.
  5. `mix ecto.*` against the canonical path. There are no callers today; keep it that way.

## 3. Usefulness at the service boundary

### 3.1 What is wired end to end (TUI → `Daemon` data source → socket → `PersistedBackend` → Domain)

The release runs client and daemon in **one BEAM**. `release/persisted_session.ex:90-118` starts
`PersistedBackend` and `Service` on a socket under `/tmp/scl-p-*`, then a `Daemon` data source
that connects to it. So "daemon connection closed" means the in-process domain died. Runs never
outlive the TUI: `close_owned_runtime/1` calls `Engine.stop_all/0`.

| Operation (`protocol/service_request.ex:16-31`) | Backend | Status |
|---|---|---|
| `dispatch_send` (plain text → `Engine.start_chat_turn`; `/cmd` → `CommandDispatcher`) | `persisted_backend.ex:296-362` | **Works.** 19 slash commands map (`command_dispatcher.ex:65-460`): swarm, goal, plan, review, effort/swarm_effort, model/swarm_model, rewind, stop, resume, workflow(s), create-workflow, ultra, consensus, deep_research, attach, compact. |
| `query` / `detail` (runs, records, agents, checkpoints) | `:364-382` | **Works, but** each call and each engine event (`:204-228`, debounced to 20 ms) runs `reload/1` (`:863-870`): 200 runs + 200 records + all their agents + ops + checkpoints re-read from SQLite. During a swarm this is a full reload per `nodes_patch` tick. |
| `question_answer` | `:390-418` → CLI-local `RunServer.answer_question/5` | Works. It rests on the CLI-local RunServer patch. |
| `run_control` / `run_steer` / `approval_resolve` | `:420-462`, `control/4` | Works for approve/deny. **`always_allow` is dead**: `params["decision"] == "approve"` or else `:deny` (`:527`); the codec guard is `[:approve, :deny]` (REVIEW #17, still true). `deny_stop` and `{:always_prefix, family}` exist only at HEAD. |
| `feature_query` / `feature_command` | `FeatureRequest` → `domain/feature_catalog.ex` | Works for 9 libraries: workflows, research, schedules, settings, usage, changes, checkpoints, mcp, memory. |
| `conversation_open` | `:384-388` | **Only the current conversation.** `member?/2` pins every scope to `opts[:conversation_id]` (`:1283-1292`). No list, no new, no switch; Ctrl-P shows one "Conversation <uuid>" row (`cap3.txt`). A new conversation needs `SWARM_CONVERSATION=new` and a relaunch. |
| `mark_seen` | UI (`workspace.ex:384`, keymap `m`) → no codec clause | **Dead** (REVIEW #16, still true). |

### 3.2 What is produced but never consumed

- **PubSub.** `grep subscribe( daemon/ cli/lib` finds only `Events.subscribe(conv)` and
  `Events.ui_subscribe()` (`persisted_backend.ex:53-54`). No subscriber exists for
  `notifications` (the `Notifications` shim that replaced `Desktop.notify_*`, so the TUI never
  hears "waiting for you" or "finished" from other runs), `mcp`, `settings`, `providers`,
  `projects`, `scheduled`, `storage`, `research`/`research:<id>`, `runs` or `search_providers`.
- **UI events.** Of the five kinds sent to `ui_broadcast` in the domain, `research_runs_changed`,
  `workflows_changed`, `workflow_runs_changed` and `toast` fall through the refresh list
  (`:204-228`). REVIEW #18 still holds.
- **Never started or never called.**
  - `MCP.start_all/0`, so the DB's tavily MCP server is never available to CLI agents.
  - `Scheduler` and `Watchdog`. Correct for the CLI: the desktop should own the schedule.
  - `Conversations.mark_interrupted/0`: a CLI crash leaves runs `running` until the desktop
    next boots.
  - `Providers.seed_defaults/0`, `Attachments.prune_abandoned/0` and research orphan sweeps.

  The only runtime children are listed in `domain/runtime.ex:5-19`.
- **Global directory mismatch.** `config/config.exs:6-9` sets `domain_config_dir` to
  `~/.config/swarm-code`, or `SWARM_CODE_CONFIG_DIR`. It is **evaluated at build time**: the
  release `sys.config` contains `/Users/zaali/.config/…` and ignores `HOME`. The desktop's
  `Desktop.config_dir/0` is `~/Library/Application Support/SwarmCode` (`desktop.ex:463-466`).
  Everything that hangs off `Workspace.global_dir/0` diverges: global `MEMORY.md` (injected into
  every system prompt, `project_context.ex:223`), user skills, global commands, user-scope
  workflows, attachments and the scratch project. The CLI agents do not see the owner's global
  memory or workflows. Attachment rows written by one app point at files in a directory the
  other app does not use. `~/.config/swarm-code` does not even exist on this machine.

### 3.3 Providers and models

- **Where the CLI gets provider settings.** `SessionConfiguration.prepare/2`
  (`daemon/service/session_configuration.ex:10-43`) checks whether *any* of `SWARM_PROVIDER`,
  `SWARM_MODEL`, `SWARM_BASE_URL`, `OPENAI_MODEL` or `ANTHROPIC_MODEL` is present.
  - **If one is:** it upserts a provider row named `"CLI <kind> <sha16(base_url)>"` and copies
    `api_key` into the canonical DB **in plaintext** whenever the env has a key (`:59-86`).
    Then it **rewrites the resumed conversation's** `chat_provider_id`, `chat_model`,
    `swarm_provider_id`, `swarm_model`, `effort` and `swarm_effort`. It does this on every
    launch, so a `/model` choice lasts only until the next start.
  - **If none is:** it uses `Providers.effective_model(conversation, :chat)`, which is the
    conversation's own choice, then the settings default. That is exactly the desktop's
    behaviour.
- **Every launch takes the override branch.** The owner's shell exports `SWARM_*` from
  `~/.secrets` (seen with `env | cut -d= -f1`), and `swarmcode` sources the same file when no
  key is exported (`bin/load_provider_env.sh`). Evidence in the sandbox copy of prod:
  - Two "CLI openai_compatible" rows, one of them duplicating `llmotions` with its own stored
    key.
  - The desktop conversation `030bf99a` ("lets do conseus…", created by the desktop on 09-05)
    now points at a CLI row.
- **`/model` already picks from the DB.** `PersistedBackend.model_options/0` (`:1548-1561`)
  lists `Providers.list()` × `provider.models`: 145 entries in the capture, the leaked
  `test-model` first. `CommandDispatcher` resolves a bare id to the conversation's provider,
  then the settings default, then the first provider (`command_dispatcher.ex:198-226`).
- **What "just works" takes:**
  1. Default to DB providers. Treat `SWARM_*` as an explicit, per-process override that is
     *never* persisted into the conversation and never creates provider rows: pass it to
     `Engine.start_chat_turn` as a run-scoped provider, or only use it when
     `effective_model/2` fails.
  2. Stop the launcher from auto-sourcing `~/.secrets` when the DB has a usable default. At
     minimum, do not treat `SWARM_MODEL` from the file as an override.
  3. Add `swarmcode --model <provider|model>` for a deliberate one-off.
  4. Group the `/model` picker by provider, mark the current selection, and hide rows whose
     `base_url` is loopback while the provider has no key.
  5. Write a data-repair note (not a CLI task): the two "CLI openai_compatible" rows and the
     6 `/private/tmp/swarm-cli-plain.*` projects are candidates for an owner-approved,
     backed-up cleanup.

## 4. Alternatives

### (a) Re-sync the fork now, plus a repeatable sync tool: **recommended**

- **For:** measured mechanical. 0 merge conflicts and 0 warnings (§2.2). It keeps every CLI
  safety layer, including the guarded Repo and the ledger. No desktop change. Provenance stays
  auditable, and `--check` makes future drift visible.
- **Against:** it is still a fork. The next desktop pass needs another `sync --ref`, about an
  hour when the rules hold. The 4 CLI-local patches must be kept small. The schema contract has
  to be re-pinned whenever the desktop adds a migration.
- **Cost:** owner A, about a day including the schema re-pin and tests.

### (b) Path or git dependency on `~/dev/swarm-code` for the domain: **rejected**

- **Module collisions.** The desktop compiles `SwarmCode.Commands`, `SwarmCode.LLM.*` (12),
  `SwarmCode.Tools.*` (31), `SwarmCode.Providers.Provider` and `SwarmCode.Repo`. The CLI
  already defines `SwarmCode.Commands` in core (`apps/swarm_code_core/lib/swarm_code/commands.ex`,
  the slash parser, a different module) and un-namespaced `SwarmCode.LLM.*`,
  `SwarmCode.Tools.*` and `SwarmCode.Providers.Provider` in the daemon (§2.1). The build would
  stop on duplicate modules until the CLI renamed its own.
- **Dependency conflict.** The daemon pins `{:exqlite, path: "vendor/exqlite", override: true}`,
  a fork whose native close semantics differ (F1), plus `ecto_sqlite3 == 0.24.1` and
  `ecto_sql == 3.14.0`. The desktop floats `ecto_sqlite3 >= 0.0.0` and `ecto_sql ~> 3.13`, and
  also pulls in `phoenix`, `phoenix_live_view`, `bandit`, `desktop` (wx, from GitHub),
  `desktop_deployment`, `floki`, `earmark` and `heroicons`. `deps.unlock --check-unused` and the
  "pin with ==" policy would have to absorb all of it.
- **The `Application`.** `SwarmCode.Application.start/2` (`application.ex:8-66`) starts the
  Endpoint, the wx window, `CloseGuard`, `Desktop.Memory`, the `Ecto.Migrator` against its own
  Repo config, the Scheduler and the Watchdog. As a dependency it must be `runtime: false` and
  its children hand-started. The domain still calls `SwarmCodeWeb.Markdown`, `MarkdownCache`,
  `UIState`, `Chat.launch_messages` and `SwarmCode.Desktop.{notify*, config_dir}`
  (6 call sites in domain files: `research/html_render.ex:308,323`, `conversations.ex:483,487,772`, `storage.ex:360`), so the web and desktop modules have to
  load anyway.
- **Rule.** CLI `AGENTS.md`: "~/dev/swarm-code, a read-only reference; never modify that
  repo". Making (b) clean needs a desktop refactor: a `swarm_code_domain` umbrella app with no
  web or wx dependencies.
- **Verdict:** revisit only if the owner makes the desktop an umbrella with a pure domain app.

### (c) The CLI attaches to a running desktop engine (single DB owner), with a standalone fallback: **defer**

- **For:** one process owns the DB. That fixes the one-way lease (REVIEW #1) and the
  "quit the desktop first" rule, and with it the whole class of cross-app corruption risk. The
  CLI always runs the desktop's current engine with zero sync. Runs survive the terminal.
  About 19k lines of daemon machinery (`backup/gate.ex` 2 112, `platform/directory_*` 3 600,
  `foundation_gate.ex` 1 509, `cross_app_lease.ex` 709, vendored exqlite guard) shrink to a
  client plus the fallback.
- **Against, for this pass:** the desktop exposes no API. It has a LiveView HTTP endpoint and
  `mix swarm_code.exec` (a mix task, not in the installed app). On Linux the release sets
  `RELEASE_DISTRIBUTION="${SWARMCODE_DIST:-none}"` (`rel/linux/run.eex:50`); the macOS bundle
  exposes nothing either. Attaching means adding a local socket server to the desktop that
  speaks the CLI's `SwarmCode.Protocol` (length-prefixed JSON). That is a desktop change, which
  the CLI rule forbids, and a multi-day design job (auth, versioning, event fan-out).
- **Verdict:** write it up as the target architecture for a later pass, which needs the owner's
  approval to touch the desktop. This pass keeps the standalone path, which becomes the
  fallback later.

**Defer from this pass:** (c) and the desktop API; (b); deleting the transient live runtime
(`lib/swarm_code/{llm,tools}`, `daemon/runtime/run.ex`, `live_backend.ex`). Freeze those and
exclude them from sync. Also defer running the Scheduler in the CLI (the desktop owns it),
Keychain secrets (not in the desktop either), and web-only sidebars.

## 5. Findings

Paths are relative to `~/dev/swarm-code-cli` unless marked `desktop:`. V is value (1-5), E is
effort (S/M/L).

- **F1 bug (critical, V5, E M): one connection drop kills the whole session.**
  - *Evidence:*
    - `vendor/exqlite/c_src/swarm_binding_vfs.c:438`: `swarm_bound_close` calls
      `sqlite3_close()` (v1), not `sqlite3_close_v2()`.
    - `vendor/exqlite/c_src/sqlite3_nif.c:668-686`: the fork's own comment says v1 "will return
      error if any unfinalized statements, which we likely have, as we rely on the destructors".
    - `vendor/exqlite/lib/exqlite/connection.ex:249-263`: `disconnect/2` returns that error.
    - `deps/db_connection/lib/db_connection/connection.ex:167`: `:ok = apply(mod, :disconnect, …)`
      raises `MatchError`. That is exactly the logged `{:error, "unable to close due to
      unfinalized statements or unfinished backups"}` after "client #PID exited".
    - The lease then fences (`cross_app_lease.ex:462-465`), `RepoLauncher` fails
      `database_binding_changed` (`repo_launcher.ex:238-239`), the application stops, and
      `persisted_session.ex:196-221` raises "Guarded storage cleanup remains pending" (`:217`, via `raise_error/1` at `:279`).
  - *Trigger:* any process that exits while holding a checkout, such as a killed or timed-out
    Task.
  - *Fix:*
    1. Close bound connections with `sqlite3_close_v2`, and decrement the binding's connection
       count from the existing close hook (`swarm_bound_install_close_hook`) when SQLite really
       frees the handle.
    2. Make `disconnect/2` return `:ok` after quarantining the slot.
    3. Let a slot re-authorize a replacement connection (already allowed when the old pid is
       dead, `cross_app_lease.ex:259-280`).
  - *Test:* a guarded-pool test kills a client mid-query and asserts the Repo still answers and
    no `:guarded_pool_failed` is sent. Also a saved-session PTY run with a killed worker.
  - *Owner:* B.
- **F2 architecture (critical, V5, E M): the CLI stops opening the DB when the desktop HEAD is
  installed.**
  - *Evidence:* `schema/contract.ex:34-54` pins `ccb1973` with 53 migrations and `last_version`
    20261015000003. `schema/gate.ex:128-143` accepts only a prefix of that list, and desktop
    HEAD adds 4 migrations (§2.4).
  - *Fix:* re-pin to `6dd8d82` (57), with fixtures, tests and the `foundation_gate.ex:24`
    source.
  - *Owner:* A.
- **F3 architecture (high, V5, E M): the domain is frozen at pass 53 and there is no sync
  tool.** Evidence and fix are in §1 and §2. The experiment gives 0 conflicts and 0 warnings.
  Deliver `mix swarm_code.provenance.sync` with `--check` in precommit. *Owner:* A.
- **F4 data-safety (high, V5, E S): launching the CLI rewrites the desktop's data.**
  - *Evidence:* `service/session_configuration.ex:10-43,59-86`. Any `SWARM_MODEL` or
    `SWARM_BASE_URL` in the environment (which `~/.secrets` always sets) creates or updates a
    `CLI <kind> <hash>` provider row with the **plaintext API key** and overwrites the resumed
    conversation's provider, model and efforts on every launch. In the sandbox copy of prod,
    two such rows exist, and conversation `030bf99a`, created by the desktop, was re-pointed.
  - *Fix:* resolve the model through `Providers.effective_model/2` by default. Treat an
    explicit override as run-scoped: no row, no conversation update, no key persisted.
    `/model` remains the only persistent switch.
  - *Owner:* B, with E for the flag.
- **F5 data-safety (medium, V3, E S): dev and verification sessions wrote into the canonical
  DB.**
  - *Evidence:* the prod copy has 6 projects at `/private/tmp/swarm-cli-plain.*` (2026-09-09)
    and a `http://127.0.0.1:9/v1` `test-model` provider that 6 conversations use. The row
    appears first in `/model` (`/private/tmp/p70cli/arch/cap1.txt`).
  - *Fix:*
    - Dev launchers and agent verification must run with a sandbox HOME (document it in
      AGENTS.md). Offer `SWARM_SANDBOX=1`, which copies the DB into a temp HOME.
    - Hide providers whose base URL is loopback when they have no models in use.
    - Clean up the rows through an owner-approved, backed-up repair.
  - *Owner:* B.
- **F6 bug (high, V4, E S): only one `swarmcode` per machine.**
  - *Evidence:* my first launch died with "the name swarm_code_cli@macbook seems to be in use
    by another Erlang node" (`/private/tmp/p70cli/arch/tui_stderr.log`, first attempt).
    `rel/env.sh.eex` only sets `umask 077`, so the default is `RELEASE_DISTRIBUTION=sname`
    with a fixed node name.
  - *Fix:* `export RELEASE_DISTRIBUTION=none` in `rel/env.sh.eex`. Nothing uses distribution.
    A second project, or a second terminal on another project, then works.
  - *Owner:* B.
- **F7 missing-feature (high, V5, E L): the TUI is locked to one conversation.**
  - *Evidence:* `persisted_backend.ex:1283-1292`, where `member?/2` pins scope to
    `opts[:conversation_id]`, and `:384-388`, where `conversation_open` refuses any other id.
    Ctrl-P shows one "Conversation <uuid>" row (`cap3.txt`), and starting fresh needs
    `SWARM_CONVERSATION=new` plus a relaunch.
  - *Fix:* a project-scoped backend: a keyset-paged conversation list (title, updated, unread,
    live runs), `conversation_new`, and `conversation_open` that re-subscribes `Events`, resets
    the projection and bumps the source epoch. In the TUI, a switcher with titles, `n` for
    new, and a resume picker at start.
  - *Owners:* C (wire and backend), E (UI).
- **F8 bug (high, V4, E S): the CLI and the desktop use different global directories.**
  - *Evidence:* `config/config.exs:6-9` sets `~/.config/swarm-code`, baked into the release's
    `sys.config` at build time. The desktop uses `desktop:lib/swarm_code/desktop.ex:463-466`,
    `~/Library/Application Support/SwarmCode`. The mismatch splits global `MEMORY.md`, skills,
    global commands, user workflows, attachments and scratch (§3.2).
  - *Fix:* resolve it in `config/runtime.exs` from the platform: macOS uses the desktop dir,
    Linux uses XDG. Keep `SWARM_CODE_CONFIG_DIR` as an explicit override.
  - *Owner:* B.
- **F9 missing-feature (high, V4, E M): boot and shutdown parity.**
  - *Evidence:* `domain/runtime.ex:5-19` has no BackgroundProcs, LSP or Hooks supervisors. It
    never calls `mark_interrupted`, `reconcile_claimed`, `seed_defaults`, `MCP.start_all` or
    the research sweep. Shutdown is only `Engine.stop_all` plus `Application.stop`
    (`persisted_session.ex:196-201`). For comparison: `desktop:bootstrap.ex:16-56`,
    `desktop:quit.ex`, and the survivor reap in pass 63.
  - *Fix:* add `Daemon.Boot` and `Daemon.Shutdown`, each step bounded and logged. Pause
    workflows, stop runs, reap background commands, and stop LSP and MCP.
  - *Owner:* B.
- **F10 missing-feature (high, V4, E M): the TUI cannot hear anything outside its own
  conversation topic.** No subscriber exists for `notifications`, `mcp`, `research*`,
  `scheduled` or `settings`, and 4 `ui` events are ignored (§3.2, REVIEW #18). *Fix:*
  subscribe in the backend and turn them into typed deltas: toast, waiting elsewhere, MCP
  status, research progress. *Owner:* C.
- **F11 missing-feature (high, V4, E M): approvals are stuck at approve/deny.**
  - *Evidence:* `persisted_backend.ex:527` maps anything other than "approve" to deny; the codec
    guard is `[:approve, :deny]`; `mark_seen` has no codec clause (REVIEW #16, #17, both still
    true).
  - *Fix:* after the sync, carry `:deny_stop` and `{:always_prefix, family}` (desktop
    `run_server.ex:152-160`, `engine.ex:1225-1241`) through intent, codec and backend. Show
    the classified family and the risk class on the card, and wire `mark_seen`.
  - *Owner:* C.
- **F12 missing-feature (medium, V4, E S): no trust or approval-mode control once the sync
  lands.**
  - HEAD makes new projects `read_only` and hides their AGENTS.md until `trusted_at` is set
    (desktop CHANGELOG pass 63 T31).
  - `SWARM_APPROVAL` is read only by the transient `runtime/configuration.ex`.
  - *Fix:* add `/trust` and `/mode read-only|auto|full` mapping to `Projects.trust/1` and
    `set_approval_mode`, plus a trust banner.
  - *Owners:* C, then D and E.
- **F13 missing-feature (medium, V4, E M): no one-shot or headless entry.**
  - *Evidence:* `persisted_session.ex:30` rejects all argv, and `bin/swarmcode` takes only
    `[DIR]`. The plain presenter exists but only through `scripts/dev/run_plain_session.sh`.
    The desktop has `mix swarm_code.exec` with exit codes 0/1/2
    (`desktop:lib/mix/tasks/swarm_code.exec.ex`).
  - *Fix:* add `swarmcode -p "prompt" [--model m] [--new|--continue id] [--json]` on top of the
    plain presenter. The same flags should work in TUI mode.
  - *Owner:* E.
- **F14 architecture (medium, V3, E M): the backend re-reads everything on each event.**
  - *Evidence:* `persisted_backend.ex:204-228` schedules `reload/1` (`:863-870`: 200 runs,
    200 records, all agents, ops and checkpoints) 20 ms after any `nodes_patch` or
    `nodes_upsert`. Queries and controls reload again (`:365`, `:380`, `:392`, `:422`).
  - *Fix:* apply `nodes_upsert`/`nodes_patch` payloads incrementally and reload only on
    structural events. Add a golden-equivalence test that compares the incremental projection
    with a fresh reload.
  - *Owner:* C.
- **F15 data-safety (medium, V4, E S): no rule decides which migrations the CLI may run ahead
  of the desktop.**
  - *Evidence:* after a re-pin, `RepoLauncher` migrates every pending version
    (`repo_launcher.ex:115-137,186-196`).
  - *Fix:* add a `forward_compatible` allowlist per contract. The gate refuses
    `:migration_required` with non-allowlisted pending versions and tells the user to open the
    desktop.
  - *Owner:* A.
- **F16 missing-feature (medium, V4, E M): HEAD run data does not reach the wire.**
  - *Evidence:* `grep -c 'error_kind\|stop_reason'` over `persisted_backend.ex` and
    `persisted_projection.ex` returns 0. There is also no per-agent model, no background
    command list, no rate-limit or retry-after, no mailbox and no isolation branch or delta.
  - *Fix:* extend `PersistedProjection` selects and the DTO schema
    (`ui/data_source/dto/schema.ex`), then render them.
  - *Owners:* C, then D.
- **F17 architecture (low, V2, E S now / L later): a second stale fork survives.** The
  un-namespaced `lib/swarm_code/{llm,tools}` and `daemon/runtime/run.ex` (from `agent_server.ex`
  at fb1b4ff) serve only the unsaved launcher, yet `PersistedBackend.init/1` uses
  `SwarmCode.Tools.Path.real_path/1` (`:45-46`). *Fix now:* switch to
  `SwarmCode.Domain.Tools.Path` and exclude these files from sync. *Later:* delete the live
  runtime. *Owner:* C for the line, deferred for the deletion.

## 6. Recommendation and owner breakdown (5 owners, disjoint files)

**Order.** A lands its first two tasks (the sync plus a daemon that compiles) within about 2
hours, and everyone rebases onto that. B's F1, F6, F8 and F4 touch no A files and start at t0.
C publishes its DTO and wire additions (`dto/schema.ex`, `service_request.ex`) as the first
commit, so D and E can build against them. Only A writes `provenance/extracted-files.json`.

- **A: domain sync and schema.**
  - *Files:*
    - `apps/swarm_code_daemon/lib/swarm_code/domain/**`, except `runtime.ex`,
      `notifications.ex`, `paths.ex`, `pub_sub.ex`, `feature_catalog.ex` and `html.ex`.
    - `apps/swarm_code_daemon/priv/{domain_repo/migrations,agents,workflows,skills,schema}/**`.
    - `apps/swarm_code_daemon/lib/swarm_code/daemon/schema/**`.
    - The `@manifest_source` line in `daemon/foundation_gate.ex`.
    - `provenance/**`, `apps/swarm_code_core/lib/mix/tasks/swarm_code.provenance.*.ex` and
      `governance/provenance.ex`.
    - Tests under `apps/swarm_code_daemon/test/swarm_code/{domain,daemon/schema}/**`,
      `foundation_gate_test.exs` and `apps/swarm_code_core/test/**/provenance*`.
  - *Tasks:*
    - A1: `provenance.sync` with the rules file and `--check`.
    - A2: sync to `6dd8d82`, 3-way merge the 14 patched files, and extend
      `RunServer.pending_interactions/1` rows with `command_family` and `classification` from
      `CommandSafety` for C.
    - A3: add the 4 migrations and re-pin the contract, manifest and fixtures to 57.
    - A4: the `forward_compatible` allowlist (F15).
    - A5: port the pure upstream unit tests (command_safety, fuzzy_match, context hysteresis,
      edit_file fuzzy, ripgrep fallback) as provenance test entries.
  - *Proof:* `provenance.sync --check` is clean. The schema tests pass for four cases: 53-DB →
    backup → 57; 57 ready; an unknown 58th refused; a non-allowlisted pending refused.
    `mix compile --warnings-as-errors` passes.
- **B: runtime, storage safety and the launcher.**
  - *Files:*
    - `vendor/exqlite/**`.
    - `daemon/{cross_app_lease.ex,repo_launcher.ex,runtime/configuration.ex}`.
    - `daemon/service/{session_configuration.ex,session_selection.ex}`.
    - New `daemon/boot.ex` and `daemon/shutdown.ex`.
    - `domain/{runtime.ex,notifications.ex,paths.ex}`.
    - `config/*.exs`, `rel/env.sh.eex`, `rel/overlays/bin/load_provider_env.sh`,
      `apps/swarm_code_cli/lib/swarm_code_cli/release/**` and `scripts/dev/*session*`.
  - *Tasks:* B1 F1; B2 F6; B3 F8; B4 F4 (provider policy plus a run-scoped override read from
    `SWARM_MODEL_OVERRIDE`, which E's flag sets); B5 F9 (runtime children plus Boot and
    Shutdown for HEAD); B6 F5 (sandbox dev launchers, AGENTS.md note).
  - *Proof:*
    - The kill-client-mid-query guarded-pool test.
    - Two concurrent release sessions in the PTY smoke test.
    - Launching with `SWARM_*` set leaves the conversation row and the providers table
      unchanged.
    - Boot marks an orphaned `running` run as interrupted.
    - Quit reaps a yielded `sleep 600` command.
- **C: service boundary (protocol, backend, dispatcher, data source).**
  - *Files:* `apps/swarm_code_core/lib/swarm_code/{protocol/**,commands.ex}`;
    `daemon/service/**` except B's two files; `domain/feature_catalog.ex`;
    `apps/swarm_code_cli/lib/swarm_code_cli/ui/data_source/**`.
  - *Tasks:*
    - C1: DTO and wire additions first (conversation list, stop_reason/error_kind, agent
      model, background commands, rate-limit, trust state, approval family).
    - C2: F7 backend (list/new/open with re-subscribe).
    - C3: F11 (always_prefix, deny_stop, mark_seen).
    - C4: F10 subscriptions.
    - C5: F16 projection fields.
    - C6: `/new`, `/trust`, `/mode`, `/search` (FTS), `/export`, `/agents`, `/profile`
      mappings.
    - C7: F14 incremental projection.
    - C8: F17 `Tools.Path` switch.
  - *Proof:* socket acceptance tests per operation; codec round-trip properties; fake data
    source parity (every real op also exists in `data_source/fake`); golden projection
    equivalence.
- **D: TUI transcript and agent rendering.**
  - *Files:* `apps/swarm_code_cli/lib/swarm_code_cli/ui/{projector/**,projector.ex,scene/**,scene.ex,paint/**,paint.ex,prose.ex,transcript.ex,unified_diff.ex,theme.ex}`
    and `lib/swarm_code_cli/companion/**`.
  - *Tasks:*
    - Tool ops that read well: `edit_file`/`edit_files` diffs, a live `run_command` tail with
      exit code and a background chip, `find_files`/`grep`/`lsp` results.
    - Agent cards with model and stop-reason chips.
    - An approval card with the command family and 4 actions.
    - Trust banner, toasts, rate-limit countdown.
    - Visual direction comes from the UX auditor.
  - *Proof:* projector golden scenes; `mix swarm_code.demo.cells` SVGs regenerated and
    reviewed.
- **E: navigation, sessions and entry points.**
  - *Files:* `apps/swarm_code_cli/lib/swarm_code_cli/ui/{reducer/**,reducer.ex,keymap/**,keymap.ex,switcher.ex,model_picker.ex,slash_palette.ex,library.ex,intent.ex,action.ex,state.ex,init.ex,layer_spec.ex,session_runtime.ex,editor/**}`;
    `apps/swarm_code_cli/lib/swarm_code_cli/{plain/**,release.ex}`;
    `rel/overlays/bin/swarmcode`; `docs/keybindings.md`.
  - *Tasks:*
    - A conversation switcher with titles (F7 UI) and a resume picker.
    - `/model` grouped by provider, with the current selection marked.
    - `@file` completion over a C feature query that uses `FuzzyMatch`.
    - F13 flags: `-p`, `--new`, `--continue`, `--model`, `--json`.
    - Key bindings for approve, always, deny and deny-stop.
  - *Proof:* reducer and keymap tests (`focus: "main"` for letters), `swarm_code.keymap --check`,
    and a PTY test of `swarmcode -p` exit codes 0/1/2.

**Risky seams:**

1. A ↔ C: the shape of `RunServer.pending_interactions/1`, a CLI-local patch in an A file.
   Freeze it in A2 and let C only consume it.
2. A ↔ B: the synced domain expects `BackgroundProcs`, `LSP.Supervisor` and
   `Hooks.TaskSupervisor`, which B starts in `runtime.ex`. The integration check after both
   land: a `run_command` with `yield_ms` and an `lsp` call in a real saved session.
3. C ↔ D ↔ E: new DTO fields reach the projector (D) through `state.ex`/`read_model` (E). If
   D needs a state field, E adds it.
4. B ↔ E: override semantics. Only `bin/swarmcode --model` sets `SWARM_MODEL_OVERRIDE`, and
   plain `SWARM_MODEL` from `~/.secrets` is ignored when the DB has a default.
5. A ↔ B: schema acceptance (A) against backup and migration execution (B's
   `repo_launcher.ex`). A must not change `repo_launcher.ex`.

**Out of this pass:** (c) the desktop-side socket and single-owner attach (needs desktop
changes, the long-term fix for REVIEW #1); (b); deleting the transient live runtime; running
the scheduler in the CLI; Keychain secrets (absent in the desktop too); the prod-DB row cleanup
(an owner decision, with backup).
