# Pass 70 owner A notes: engine sync and schema

Branch `p70/A` (worktree `/Users/zaali/dev/swarm-code-cli-wt/p70-A`), from main `a65745f`.
This file is how the finisher merges the branch. Newest state first in each section.

## Sync point

- `p70-A-sync` = `150a7f2450723ef7eccb58b3370f5e007f6166e6` ("pass70 A: notes for p70-A-sync",
  the child of `f02a670`; lightweight, local). B and C: `git merge --no-edit p70-A-sync`.
  Everything after it (A5, A6, notes) touches only tests, `provenance/**`, the sync tool and
  this file.
- After merging it, read "Requests for other owners" below: B6's three runtime children are
  needed before any tool call works in a saved session.

## Landed

| Task | Commit | What |
| --- | --- | --- |
| A1 | `1fef98e` | `mix swarm_code.provenance.sync` + rules + patches + `--check` in precommit |
| A2 | `9dcc3f2`, re-record in the tag commit | domain synced to desktop 6dd8d82; `pending_interactions/1` rows extended |
| A3+A4 | `f02a670` | 4 migrations, `Schema.Contract` 6dd8d82 (57), manifest + fixtures, gate points at it; `forward_compatible` allowlist, human refusals |
| tag | `150a7f2` | `p70-A-sync`: notes + the RunServer patch re-recorded |
| A5 | `e3ec21c` | 20 more pure upstream test files synced (24 in all), pure parts of five more ported by hand |
| A6 | `ef1b0c1` | loopback-HTTP saved-mode turn through the synced engine under the guarded Repo |

## The sync tool (A1)

`mix swarm_code.provenance.sync --ref <sha> [--upstream <path>] [--resolved <dest> ...]` and
`mix swarm_code.provenance.sync --check [--upstream <path>]` (in `mix precommit`, after
`swarm_code.provenance.verify`). Upstream defaults to `$SWARM_CODE_UPSTREAM`, else
`~/dev/swarm-code`; it is read only through `git rev-parse`/`ls-tree`/`cat-file`.

- Rules: `provenance/sync-rules.json` = the pin (`upstream_commit`), the eight ordered rewrite
  rules (arch §2.2; rule 7 split in two), the mappings (upstream prefix → destination prefix,
  classification, `rewrite`, `format`, `include` globs or explicit `files`) and the exclusions
  (`application.ex`, `bootstrap.ex`, `desktop.ex`, `desktop/**`, `menu_bar.ex`, `quit.ex`,
  `tray_menu.ex`).
- Every synced file = `format(rewrite(upstream@pin))` (migrations are rewritten, not formatted;
  `priv/agents`, `priv/workflows`, `priv/skills`, `priv/spec_master.md` are byte copies), plus a
  recorded CLI patch `provenance/patches/<destination>.diff` when the CLI changes it. The patch
  is a unified diff (`git apply`-able onto the derivation) generated in-process
  (`List.myers_difference/2`), so it does not depend on the git version.
- A sync to a new ref: untouched files take the new derivation; patched files are 3-way merged
  (`git merge-file --diff3`, base = old derivation); a conflict writes only
  `<destination>.sync-conflict` and nothing else; resolve and rerun with `--resolved <dest>`.
  New upstream files become new ledger entries; files deleted upstream are removed (refused if
  patched). A new upstream file landing on a CLI-local file (e.g. `domain/runtime.ex`) stops.
- To record a deliberate edit of a synced file: `mix swarm_code.provenance.sync --ref <pin>`
  (re-derives, keeps your file, rewrites its patch and ledger sha). `--check` fails otherwise.
- Ledger entries outside every mapping's destination stay frozen and are only covered by
  `provenance.verify`: the un-namespaced live-runtime copies (`lib/swarm_code/{llm,tools}`,
  `daemon/runtime/run.ex`), the web shims (`domain/{chat,markdown,markdown_cache,ui_state}.ex`,
  `domain/markdown/scrubber.ex`), `core/.../commands.ex`, `commands/files.ex`,
  `service/command_dispatcher.ex`.
- `SwarmCode.Governance.Provenance` accepts 6dd8d82 as an adaptation pin.

## Contract published for C: `RunServer.pending_interactions/1` rows (A2, frozen)

`SwarmCode.Domain.Engine.RunServer.pending_interactions(run_id) :: [row]` (≤ 64 rows, `[]` for an
unknown/stopped run, 250 ms call). The projection lives in the CLI-local module
`SwarmCode.Domain.Engine.PendingInteractions` (not synced). Every row, approval or question,
has exactly these keys:

| key | approval | question |
| --- | --- | --- |
| `node_id` | the **op** node that waits (the id `resolve_approval/3` takes) | the `ask_user` op |
| `agent_id` | the op's parent agent node id, or nil | same |
| `kind` | `:approval` | `:question` |
| `permission` | `:read \| :write \| :execute` | nil |
| `tool` | op type (`"run_command"`, `"edit_file"`, MCP tool, …) | nil |
| `args` | redacted JSON of the arguments (≤ 8 KiB) | `"{}"` |
| `command` | the `run_command` command (≤ 2000 B, redacted), else nil | nil |
| `cwd` | `run_command`: project root joined with `workdir`; others: project root | nil |
| `path` | the `path` argument of a file tool, else nil | nil |
| `reason` | the model's `justification` argument (≤ 500 B), or nil | nil |
| `command_family` | the server-computed family `always_prefix` remembers; nil when nothing may be remembered (dangerous, non-`run_command`) | nil |
| `classification` | `:safe \| :normal \| :dangerous` (`CommandSafety`) | nil |
| `allowed_decisions` | `[:approve, :approve_run, (:always_prefix if family), :deny, :deny_stop]` | `[]` |
| `requested_at` | `DateTime` UTC when the run started waiting | same |
| `questions` | `[]` | unanswered `%{index, question, options: [%{label, description}], multiple}` |

Decision mapping to `RunServer.resolve_approval(run_id, node_id, decision)`:
`approve` → `:approve`; `approve_run` → `:always` (every call of this tool for the rest of the
run; the desktop shows it as "Allow all <tool> this run" and only when there is no family);
`always_prefix` → `{:always_prefix, family}` (the server ignores the client's family and uses the
node's own `approval_prefix`; a dangerous command is approved once and never remembered);
`deny` → `:deny`; `deny_stop` → `:deny_stop` (denies and stops the run).
`answer_question/5` is unchanged.

## What the synced domain needs at runtime (for B6)

Compared with desktop `application.ex:31-66` and `bootstrap.ex` at 6dd8d82. Already in
`domain/runtime.ex`: `Registry SwarmCode.Domain.Registry` (also used by LSP clients),
`Task.Supervisor SwarmCode.Domain.TaskSupervisor`, `PubSub`, `MarkdownCache`, `UIState`, `Cache`,
`LLM.ProviderCaps`, `Engine.Questions`, `Engine.RunSupervisor`, `Research.Supervisor`,
`MCP.Supervisor` (owns the MCP ETS tables via `MCP.ensure_tables/0`).

Missing, in the desktop's order:

1. `SwarmCode.Domain.Tools.BackgroundProcs` (GenServer + ETS; before `Engine.RunSupervisor`: a run
   may leave a yielded command running).
2. `{Task.Supervisor, name: SwarmCode.Domain.Hooks.TaskSupervisor}` (hooks fire-and-forget).
3. `SwarmCode.Domain.LSP.Supervisor` (starts `DynamicSupervisor SwarmCode.Domain.LSP.ClientSup`;
   clients register in `SwarmCode.Domain.Registry` under `{:lsp, root, language}`).
4. Not in the CLI: `Scheduler`, `Workflows.Runner.Watchdog` (the desktop owns them), `Endpoint`,
   `Desktop.*`, `SwarmCodeWeb.Telemetry`.

Boot (desktop `Bootstrap.run/1`, in this order, each retried 100/250/500 ms):
`Conversations.mark_interrupted/0` → `Scheduled.reconcile_claimed/0` →
`Providers.seed_defaults/0` → `Search.adopt_legacy_key/0` → `MCP.start_all/0` → research sweep
(`for r <- Research.orphans(), do: Research.update(r, %{status: "failed", error: "interrupted by a
restart", finished_at: now})`) → `Attachments.prune_abandoned/0`. Then (desktop
`application.ex:92`, 5 s after boot, under `TaskSupervisor`): for each `Projects.list()` project,
`Isolation.Ownership.cleanup_stale(Projects.Workspace.worktrees_dir(root), root)` when that dir
exists.

Shutdown (desktop `quit.ex` `stop_everything/0` at 6dd8d82, in this order):
`Workflows.control(run_id, :pause, [])` for every active workflow with a live runner (desktop
only; the CLI starts none) → `Engine.stop_all()` → for every
`%{run_id: r, os_pid: p} <- Tools.BackgroundProcs.list_all()`, `Tools.BackgroundProcs.kill(r, p)`
(a yielded or `&` command outlives its run, so `stop_all` never reaches it) → poll
`Engine.running_run_ids() == []` for up to 30 s (the runs' final flush) → then
`Supervisor.terminate_child` of `Engine.RunSupervisor`, `Research.Supervisor`,
`MCP.Supervisor`, 5 s each (brutal kill after). The desktop leaves LSP clients to the VM halt;
a CLI daemon that outlives a session should also stop `LSP.Supervisor` (it owns the
language-server ports). `domain/engine/pass70_saved_turn_test.exs` does the stop/poll part.

`Application.get_env(:swarm_code_daemon, …)` keys the synced domain reads (all optional,
defaults in code): `:domain_config_dir` (fetch!, via `domain/paths.ex`), `:llm_providers`,
`:llm_deadline_ms`, `:llm_retry_sleep`, `:mcp_backoff`, `:mcp_ping_timeout`,
`:mcp_max_stdio_buffer`, `:research_timeout_ms`, `:research_straggler_grace_ms`,
`:research_background_design`, `:label_runs`, `:engine_run_starter`, `:workflow_run_starter`,
`:scheduled_launch_step`, `:run_server_git_adapter`, `:busy_write_seam`,
`:storage_transaction_seam`, and the search base URLs (`:tavily_base_url`, `:brave_base_url`,
`:serper_base_url`, `:exa_base_url`, `:jina_base_url`, `:firecrawl_base_url`).

## Schema (A3, A4)

- Contract `desktop-6dd8d82`: 57 migrations, last `20261017000004_isolation_backend.exs`,
  migration set `4c0a8ec7…`, final schema `a0145e85…`, lineage `ffdb70fb…`.
  Manifest `priv/schema/desktop-6dd8d82.json`; `FoundationGate.@manifest_source` points at it.
  Fixtures: four new prefix SQL files and a regenerated `desktop-current.sql` (older fixtures
  byte-identical). The generator now leaves FTS5 shadow tables out of fixture DDL (the virtual
  table recreates them); schema hashes still include them.
- Allowlist: `forward_compatible` in the contract = the four new versions. `Schema.Gate.
  admit_migration/2` (called by `FoundationGate` right after the schema check, before any backup)
  admits `:ready`, `:new_database`, and `:migration_required` only when every pending version is
  allowlisted. So a 53-DB (desktop pass 63) is backed up and moved to 57; anything older is
  refused before backup with "This SwarmCode database needs an upgrade that only the SwarmCode
  app makes." / "Open the SwarmCode app once to upgrade the database, quit it, then run
  swarmcode again." A DB with a migration newer than the manifest (58 rows, or a newer version
  in place of a known one) is refused as "…upgraded by a newer SwarmCode app than this
  swarmcode supports." / "Update swarmcode to a build made for your SwarmCode app; the database
  was not changed." Both keep the code `:schema_incompatible` (the directory protocol and the
  launchers treat them like before); `SwarmCode.Daemon.Schema.Refusal` holds the words.
- Same SQLite (3.53.3), `ecto_sql` 3.14.0 and `ecto_sqlite3` 0.24.1 as the desktop at 6dd8d82,
  so a desktop-migrated 57-DB hashes identically to the generated manifest.

## Upstream unit tests (A5)

- The `test/swarm_code/` mapping lists 24 desktop test files explicitly (`files`, not globs):
  every file at 6dd8d82 that runs without the desktop `DataCase`, `LLM.Fake`, the web layer or
  a second module in the file. They land under `apps/swarm_code_daemon/test/swarm_code/domain/`
  with classification `test`, rewritten and formatted like the source. Covered: command safety
  (polish60/62), project context, prompts (+ pass60), consensus, context, policy, git + git
  tools, skills, commands, pricing, scheduler cron/next, workflows host/panel bound, llm
  chunks/sse/tool args, research levels, projects workspace, atomic file, polish53 tools.
- Two of them wrote to and deleted in the real global directory (`Paths.config_dir/0`):
  `commands_test.exs` and `engine/project_context_test.exs`. Their recorded patches call
  `SwarmCode.Domain.TestGlobalDir.isolate!/0` (new, `test/support/domain_global_dir.ex`) in
  `setup`. `prompts_test.exs` keeps its earlier patch. `SwarmCode.Domain.Fixtures.tmp_dir/0`
  (`test/support/domain_fixtures.ex`) is the one desktop fixture they use.
- The pure parts of five mixed files are ported by hand in
  `domain/pass70_upstream_units_test.exs` (19 tests; source file and test names in its
  moduledoc): FuzzyMatch in bytes (T94), LSP.Language + file URIs, Context hysteresis (B4),
  edit_file's four passes (T9), Ripgrep detection + fallback (C1, C3). These are CLI-local, not
  in the ledger; if upstream changes them, port again.
- `polish67_tools_test.exs` is not synced: it defines a second module that uses `DataCase`. The
  sync tool now removes (and `--check` flags) a ledger entry whose file the rules no longer
  select, like one deleted upstream.

## Engine regression under the guarded Repo (A6)

`apps/swarm_code_daemon/test/swarm_code/domain/engine/pass70_saved_turn_test.exs`, 2 tests, one
guarded launch in `setup_all` (the backup + 53 → 57 migration takes ~9 s; each turn ~0.1-0.3 s):

1. A 53-migration fixture DB goes through `RepoLauncher` (verified backup, allowlisted
   migration to 57), then a loopback openai-compatible provider scripts `run_command`
   (`printf ready`, `yield_ms: 5000`) → `edit_file` (`notes.md` beta → gamma) → text. Asserts:
   run `done`, file changed, the tool results reach turns 2 and 3 of the provider, both op
   nodes `done`, one checkpoint row for `notes.md`, and the pass-69 FTS5 index finds "gamma".
2. An `auto`-mode trusted project: `touch made.txt` waits on a real RunServer approval; the
   `pending_interactions/1` row carries `tool`, `command`, `cwd`, `reason` (justification),
   `command_family: "touch"`, `classification: :normal`, `permission: :execute`, the five
   `allowed_decisions`, `requested_at`, and an `agent_id` ≠ `node_id`; the op row is persisted
   as `awaiting_approval`; `resolve_approval(run, node, {:always_prefix, "anything"})` runs it,
   and the project remembers the server's `"touch"`, not the client's value.

It starts `BackgroundProcs`, `Hooks.TaskSupervisor` and `LSP.Supervisor` itself when
`domain/runtime.ex` does not (B6) and sets `:llm_providers` like `persisted_backend_test.exs`.

## Files outside my set that I had to touch (count bumps only)

The re-pin moves pinned counts in tests other owners own. I changed only these lines; please
keep them on merge:

- `apps/swarm_code_daemon/test/swarm_code/daemon/backup/gate_test.exs` (B): 53 → 57 (3 lines).
- `apps/swarm_code_daemon/test/swarm_code/daemon/guarded_repo_test.exs` (B): `[[53]]` → `[[57]]`
  and the two migration tests' `@tag lineage` from the 43-prefix to the 53-prefix (a 43-DB is now
  refused by the allowlist; the 53-DB is the real "backed up and migrated" case).
- `apps/swarm_code_daemon/test/swarm_code/daemon/platform/directory_protocol_test.exs` (B):
  53 → 57, "54th" → "58th".
- `apps/swarm_code_daemon/test/support/schema_fixture.ex`: the four new prefix versions.
- New files (no conflict possible): `apps/swarm_code_daemon/test/support/domain_global_dir.ex`
  and `apps/swarm_code_daemon/test/support/domain_fixtures.ex` (the synced tests' support).

## Manifest-listed files edited by others

(none known yet)

## Requests for other owners

Found by running the whole daemon suite on the synced tree (16 failures before the fixes in
my set; the ones below remain and are not in my files):

- **B (blocking, B6)**: add `SwarmCode.Domain.Tools.BackgroundProcs`,
  `{Task.Supervisor, name: SwarmCode.Domain.Hooks.TaskSupervisor}` and
  `SwarmCode.Domain.LSP.Supervisor` to `domain/runtime.ex` (list and order above). Every tool
  call's post-hook starts a task under `Hooks.TaskSupervisor` (`engine/operation.ex:283`); without
  it the tool result is `crashed: {:noproc, … Hooks.TaskSupervisor …}`. Test that shows it:
  `service/persisted_backend_test.exs:410` ("a real agent interview …").
- **B (backup/gate.ex)**: backup verification fails for any database that has the pass-69
  FTS5 index (every 57-DB): `counts_and_proofs/2` asks `SELECT rowid FROM
  messages_fts_config`, a `WITHOUT ROWID` shadow table ("no such column: rowid"). Fix: in
  `table_names/1` skip shadow tables (`name NOT IN (SELECT name FROM pragma_table_list WHERE
  type = 'shadow')`) and give `WITHOUT ROWID` tables (`pragma_table_list.wr = 1`) a count with
  nil rowid proofs. Failing: `backup/gate_test.exs:113` and `:213` (both back up the `:current`
  fixture). The 53 → 57 path (a 53-DB has no FTS yet) is not affected and passes end to end
  (`guarded_repo_test.exs`).
- **B (session_selection_test.exs:18)**: the synced `Projects` creates new projects
  `read_only` until trusted (desktop pass 63 T31), so `first.project.approval_mode == "auto"`
  is now `"read_only"`. Update the assertion (D4: the mode and trust are the desktop's).
- **B (backup/gate.ex:1668)**: `mix compile --force --warnings-as-errors` fails on "this clause
  cannot match because a previous clause at line 1665 matches the same pattern" (pre-existing;
  only visible on a forced/clean build).
- **C (wire_contract_test.exs:603)**: the synced `Checkpoint.changeset/2` no longer casts
  `conversation_id`/`run_id`/`node_id` (desktop spec 68 T3: ownership ids are set from trusted
  context). The fixture must put them on the struct:
  `%Checkpoint{conversation_id: c, run_id: r, node_id: n} |> Checkpoint.changeset(%{path: …,
  previous_content: …, restorable: …, inserted_at: …}) |> Checkpoint.validate() |> Repo.insert!()`
  (or `Checkpoints.insert/3`). Ten `WireContractTest` tests fail on `NOT NULL constraint failed:
  checkpoints.conversation_id` until then.
- **B (config/test.exs, B5)**: keep `:domain_config_dir` on a private temporary directory in
  the test config, and keep `domain/paths.ex` honouring that app-env override before any
  runtime resolution. If B5 resolves the directory to `~/Library/Application Support/SwarmCode`
  at runtime, the synced upstream tests (skills, commands, project context, memory) would read
  and delete a person's real global files. My synced tests that write there call
  `SwarmCode.Domain.TestGlobalDir.isolate!/0` first (patched), but the default must stay safe.
- **C**: consume the frozen `pending_interactions/1` row shape above; map
  `approve_run → :always`, `always_prefix → {:always_prefix, family}`, `deny_stop → :deny_stop`.

## Verification

At `ef1b0c1` plus this notes commit (tree clean, `MIX_QUIET` unset, all through `mise exec --`):

- `mix format --check-formatted`: exit 0. `mix compile --warnings-as-errors`: exit 0 (not
  `--force`; see the B request for `backup/gate.ex:1668`).
- `mix swarm_code.provenance.verify`: "provenance verified". `mix swarm_code.provenance.sync
  --check`: "every synced file derives from the pinned commit".
- Focused: `domain/engine/pass70_saved_turn_test.exs` 2 tests, 0 failures, four runs in a row;
  domain + schema + foundation gate + governance tests 0 failures (earlier in the pass: 333).
- Full umbrella `mix test` (once, exit 2):
  - `swarm_code_core`: 141 tests, 0 failures.
  - `swarm_code_daemon`: 876 tests, 14 failures, all in other owners' files and listed under
    Requests: `session_selection_test` (1, B, read_only default), `wire_contract_test` (10, C,
    Checkpoint ownership ids), `persisted_backend_test` "a real agent interview" (1, B6, no
    `Hooks.TaskSupervisor`), `backup/gate_test` (2, B, FTS5 `WITHOUT ROWID` shadow table).
  - `swarm_code_cli`: 5 properties, 1182 tests, 1 failure: `plain/session_test.exs:208`
    "unresponsive output is bounded and detaches its client" (`assert_receive :output_started`
    within 100 ms under full-suite load). The file passes alone (10 tests, 0 failures) and this
    branch changes nothing under `apps/swarm_code_cli`: a timing flake, not mine.

## Left

- Not started by the CLI and not needed for a chat/swarm session: the desktop's `Scheduler` and
  `Workflows.Runner.Watchdog` (the desktop owns scheduled tasks and workflow orphans).
- The hand-ported units (`pass70_upstream_units_test.exs`) are outside the ledger; a future
  sync does not refresh them.
- The guarded launch of a small 53-migration fixture takes 8.6-9.0 s in `await_ready` (verified
  backup + migration); measured only, not profiled (backup is B's).
- Warnings seen while compiling CLI tests (not mine, not failures): unused `field/3` defaults
  and alias `Editor` in `ui/feature_form_test.exs`, unused `scene` in `ui/projector_test.exs`.
