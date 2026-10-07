# cli020 lane A notes: sync to desktop 4c7c577a, schema 58, drift gate, version 0.2.0

Branch `cli020/A` from CLI `main` `f46b5fe`, worktree `~/dev/swarm-code-cli-wt/cli020-A`
(§4.1 recipe: APFS clones of `deps`, `_build`, `priv/native`; no `_build/prod`). Desktop
read-only at `4c7c577aa909274b009dc1bf0f216e5179acddc9` (desktop `main`, untouched).

## A1 sync: what happened

`mix swarm_code.provenance.sync --ref 4c7c577a… --upstream /Users/zaali/dev/swarm-code`
(the desktop's untracked `.claude/` and `.omc/` do not count: the sync's clean check uses
`--untracked-files=no`). Result: 14 created, 83 updated from upstream, 8 merged with their
CLI patch, 6 conflicts. All six conflicts were inside patched files (X15 held):

| File | Conflict | Resolution |
| --- | --- | --- |
| `domain/providers.ex` | `seed_defaults/0` | took the desktop's (it now says the same no-provider BYOK stub); **patch dropped** |
| `domain/tools/run_command.ex` | the script head (`umask_prefix() <>`) vs BUGS-54's EXIT trap | desktop's trap script with `umask_prefix() <>` in front of it again; the CLI hunks (poll permission, `umask_prefix/0`, the comment) stay |
| `domain/engine/project_context.ex` | `NCODE.md` in two lists and a doc line | took the desktop's (it added `NCODE.md` the same way); **patch dropped** |
| `domain/engine/run_server.ex` | 3 hunks: `request_approval` became a `cond` (BUGS-48), `ask_user` moved to `ask_user_call/5`, the CLI's `pending_interactions`/`answer_question` calls vs the new `:finish_totals` call | took the desktop's structure, re-added the CLI fields `requested_at` (approvals) and `answers: %{}, requested_at` (questions) in the new places, kept both handler groups |
| `test/…/engine/project_context_test.exs` | the CLI's two NCODE.md tests vs the desktop's one | took the desktop's (covers both); the patch keeps only the `TestGlobalDir.isolate!/0` line |
| `test/…/engine/prompts_test.exs` | `"You are ncode"` literal vs `Fixtures.assistant_identity()` | took the desktop's; added `assistant_identity/0` to the CLI's `test/support/domain_fixtures.ex` |

Patches now (12): `engine.ex`, `engine/prompts.ex` (A6, new content), `engine/run_server.ex`,
`hooks.ex`, `repo.ex`, `storage.ex`, `tools.ex` (A6, new), `tools/run_command.ex`,
`tools/spawn_agent.ex`, and the tests `commands_test.exs`, `engine/project_context_test.exs`,
`engine/prompts_test.exs`. Dropped because the desktop now says the same: `providers.ex`,
`engine/project_context.ex`, `llm/openai.ex` (the llmotions wording), and the old
`engine/prompts.ex` patch (the "SwarmCode" → "ncode" strings), whose file now carries only A6.

One compile warning after the sync: the synced `Conversations.Run.preview/1` calls
`SwarmCodeWeb.Format.clip_line/3` (desktop spec 74 EFFICIENCY-28). Smallest fix that keeps
the code derived: the `web-shims` rewrite rule gains `Format`
(`SwarmCodeWeb.(Markdown|MarkdownCache|UIState|Chat|Format)` → `SwarmCode.Domain.…`), and a
new ledger entry outside every mapping, `apps/swarm_code_daemon/lib/swarm_code/domain/format.ex`
(`SwarmCode.Domain.Format`), holds the desktop module's pure part only (`preview/2`,
`clip_line/3`, `window/2` and their private helpers, verbatim from
`lib/swarm_code_web/components/format.ex` at 4c7c577a; the rest of that module formats for
templates and calls `SwarmCodeWeb.Frame`). `engine/operation.ex` mentions
`SwarmCodeWeb.Format.window/2` in a comment; the rule rewrites that too. **A' must know:** the
Format file is frozen (repin after an edit); a later desktop change to `clip_line/3` is not
picked up by the sync.

New upstream files arrived as the contract listed (`missions*.ex`, `llm/speed.ex`,
`engine/research_context.ex`, `mcp/login_path.ex`, `mcp/sse_framer.ex`,
`conversations/launch_pairing.ex`, `scheduled/run_dates.ex`, `tools/mission_start.ex`,
`tools/web_fetch/raw_strip.ex`, `workflows/run_rows.ex`) plus `priv/workflows/mission.exs` and
the migration `20261018000001_mission_validator_models.exs`.

`4c7c577a…` is in `@adaptation_pins` (`core/governance/provenance.ex`).
**Contradiction:** the contract says to add it to `governance/source-policy.json` "the way
`6dd8d82` is recorded", but that file records no pin at all (only the audit baseline and the
authorization flags; `provenance.ex` checks `audit_baseline`). `6dd8d82` is recorded in
`SOURCE_AUTHORIZATION.md` (an addendum) and `@adaptation_pins`, so 4c7c577a got the same: an
addendum "desktop commit 4c7c577a (CLI 0.2.0, 2026-10-07)" that cites the contract rather than
claiming a new owner authorization. `source-policy.json` is unchanged.

`tools/polish74_o2_protected_paths_test.exs` is **not** mapped: it `use`s
`SwarmCode.DataCase` (and `LLM.Fake`), which the CLI does not have. Its three tool-level cases
are ported to the CLI-local `test/swarm_code/domain/tools/cli_protected_paths_test.exs` (against
the synced domain) and the same refusals for the live copy are in `tools/path_test.exs` (A5).
Its fourth case (an `LLM.Fake` turn) is not ported; the refusal it observes is the write
tools' refusal, pinned by both files.

Tests the sync broke and how (all CLI-local or support files):

- `domain/engine/run_server_answer_question_test.exs` builds a RunServer state by hand: gained
  `totals_dirty: false` (the synced state key, spec 74 EFFICIENCY-4).
- `domain/git_test.exs` (synced) calls `Fixtures.eventually/2`: added to `domain_fixtures.ex`
  (the desktop's helper, same semantics).
- `domain/feature_catalog_test.exs` (C's test file): the synced `Workflows.validated/2` runs a
  project-scope workflow only in a trusted project (desktop spec 74), so the workflow-launch
  test now calls `Projects.trust/1` first. One line; C should know.
- `domain/engine/pass70_saved_turn_test.exs`: 53 → 58 after the guarded migration.
- `domain/hooks.ex`: the CLI hunk that added an `NCODE_*` twin for every `SWARMCODE_*` hook
  variable merged without a conflict but crashed (`FunctionClauseError` on the desktop's own
  `NCODE_EVENT`, which 4c7c577a now sends). The full precommit found it (C's
  `c74_project_config_test`, 2 tests). The hunk is gone; the patch keeps only the
  `RunCommand.umask_prefix()` hunk (commit "cli020 A1: drop the obsolete NCODE_* twin hunk").
- `daemon/service/command_dispatcher_test.exs` (C's): the workflow-alias test trusts its project
  (same rule as `feature_catalog_test`). One line plus a comment.
- `settings/c74_registry_parity_test.exs`: **stub**, see "Stubs" below.

## What A' (re-sync to Fm) must know

- `engine/run_server.ex` carries the CLI patch in three places: `requested_at:` in the approval
  map built by `request_approval` (now a `cond`, desktop BUGS-48), `answers: %{}, requested_at:`
  in the question map in `ask_user_call/5`, and the `:pending_interactions` /
  `{:answer_question, …}` handlers placed right after the desktop's `:finish_totals` handler. F
  edits `run_server.ex` (F1/F2/F5): expect a conflict in `request_approval` again; keep F's
  `mode:` and re-add `requested_at:`.
- `tools/run_command.ex`: the CLI's `umask_prefix() <>` sits in front of the desktop's
  `"exec </dev/null\n…trap…"` script head (BUGS-54); keep it there.
- `engine/prompts.ex` and `tools.ex` carry A6 (below); F edits both (F3/F6). Keep the CLI
  `@ultra` text, the `authoring? = opts[:authoring] || opts[:ultra] || create_workflow?` line,
  the rules bullet "…or /workflow, or turned Ultra mode on.", and the `opts[:ultra]` branch of
  `Tools.for_agent/5` returning `@workflow_modules ++ @swarm_modules`.
- `domain/format.ex` is frozen (see above). If F changes `SwarmCodeWeb.Format.clip_line/3` or
  `preview/2`, re-extract by hand and repin.
- `test/support/domain_fixtures.ex` now has `assistant_identity/0` and `eventually/2` (the
  desktop's `SwarmCode.Fixtures` helpers the mapped tests call). A mapped test that calls another
  desktop fixture helper needs it added there.
- `domain/hooks.ex` keeps one CLI hunk (`RunCommand.umask_prefix() <>` in the hook's shell
  script). F9 adds hook events there: a clean 3-way merge is not enough. Run the hooks tests
  (C's `c74_project_config_test`) after the re-sync, because the old `NCODE_*` hunk also merged
  cleanly and crashed.
- The `requested_at`/`answers` question fields are what `PendingInteractions` reads; if F's
  `ask_user` change moves the map again, the CLI's pending-interactions test breaks loudly.

## A2 boot, quit and supervision (deviations)

- `Domain.Runtime` children in the desktop's `application.ex` order (Registry, TaskSupervisor,
  `BackgroundProcs.Supervisor`, `LLM.HTTP.finch_child_spec()`, PubSub, MarkdownCache, UIState,
  ProviderCaps, Cache, `LLM.Speed`, `Engine.ResearchContext`, Questions, BackgroundProcs,
  `Engine.CleanupSupervisor`, `Hooks.TaskSupervisor`, Research/MCP/LSP supervisors,
  RunSupervisor last). No Scheduler (the CLI never starts it), no web children.
- Deviation: `Conversations.repair_unfinished_nodes/0` runs inline as a Boot step before the
  attachment prune (the desktop runs both 3 s after its window is up, spec 74 EFFICIENCY-23).
  The CLI has no window to wait for: `Boot.run/0` runs in the saved session's query worker
  before its first snapshot (`release/persisted_session.ex`), so a deferred task would only race
  that snapshot. Each step keeps Boot's bounded retry (100, 250, 500 ms) and cannot stop the
  session.
- The isolation sweep (`Isolation.sweep_orphans` plus the new `sweep_deltas`) is started under
  `Engine.CleanupSupervisor` after `:isolation_delay_ms`, so `Shutdown` can wait for it.
- `Shutdown` gains `:wait_for_cleanups` after the flush: monitors every `CleanupSupervisor`
  child, waits until `:cleanup_ms` (default 15 000), leaves a child still running at the deadline
  alone (the supervisor's own shutdown kills it). `Quit.now_async` has no CLI caller (no
  LiveView), so it is not mirrored; the moduledoc says so.

## A3/A4 schema (deviations)

- `generate_manifest.exs` refuses an upstream checkout with any untracked file; the desktop
  checkout has untracked `.claude/` and `.omc/` (the owner's, not ours to remove). The generator
  ran against `~/.cache/ncode/cli020/A/desktop-4c7c577` (`git clone --shared` of the desktop,
  detached at 4c7c577a; read-only for the desktop repo). Outputs:
  `priv/schema/desktop-4c7c577.json`, `priv/schema/fixtures/desktop-20261018000001.sql`, and the
  refreshed `desktop-current.sql`. Hashes: migration_set `32dd14f0…8779`, final_schema
  `a95f2a13…9bb`, lineage `e34dfec0…1d53`, last source `e2ed2c9f…2ad8`.
- `FoundationGate.desktop_running?/1`: true only when the signed detector reports
  `:desktop_active`; any other result, an identity failure or non-keyword options give false.
  Its test-seam options are honoured only in test builds.
- The 57-row case: the CLI runs `20261018000001` itself after the verified backup (it is in
  `forward_compatible`). The 59-row case is `Refusal.database_ahead/0`, whose action now reads
  "Install the ncode CLI that matches your ncode app (ncode --version shows this one: 0.2.0); the
  database was not changed." (A4).

## A5 the 34 frozen entries: per-file decisions

The count is 34 (V5 holds): the ledger has 39 entries at `fb1b4ff8` outside every mapping; 5 of
them are the `domain/` web shims (`markdown_cache.ex`, `ui_state.ex`, `chat.ex`, `markdown.ex`,
`markdown/scrubber.ex`), which the contract's count leaves out. `domain/format.ex` (A1) is a new
40th frozen entry, at 4c7c577a. "Reached" means `Daemon.Runtime.Run` (the unsaved-session
runtime) calls the code: it uses `SwarmCode.LLM.stream/2`, `Tools.specs/0`, `Tools.permission/2`,
`Tools.run/4` (which rescues), `RunCommand.timeout_for/2`, `Path.real_path/1` and
`Efforts.key_format/0`. It never calls a tool's `title/1`. Commits counted `fb1b4ff8..4c7c577a`
on the upstream path.

| # | Live file (upstream) | Desktop commits | Decision |
| --- | --- | --- | --- |
| 1 | `daemon/runtime/run.ex` (`engine/agent_server.ex`) | 34 | CLI-only: a CLI runtime written against the AgentServer, not a copy; the AgentServer fixes (BUGS-21 peers, BUGS-30/33/53/76 history and compaction, EFFICIENCY-40..44 caching) concern features the live runtime does not have (peers, compaction, research, cache markers) |
| 2 | `llm.ex` | 3 | not ported: pass 61/63 features and EFFICIENCY-68 (rate-limit broadcast); no fix the live runtime reaches |
| 3 | `llm/anthropic.ex` | 13 | **reached, not ported**: BUGS-28 (retry on what was sent), BUGS-29 (cut-off tool call), BUGS-49 (deadline as no-progress bound). The hunks do not apply (2/4, 1/2, 1/2 fail): they sit on pass 62/63 LLM work the copy lacks. See "Open" below |
| 4 | `llm/chunks.ex` | 0 | unchanged |
| 5 | `llm/efforts.ex` | 3 | **reached, not ported**: BUGS-51/52 and EFFICIENCY-41 need the per-model ProviderCaps rejections (same reason) |
| 6 | `llm/http.ex` | 5 | **reached, not ported**: BUGS-49 (no-progress deadline) and BUGS-50 (256-connection pool, checkout timeout retried). The live copy is 282 lines from upstream (the CLI's monotonic, suspend-aware deadline); 6/9 and 2/2 hunks fail |
| 7 | `llm/openai.ex` | 14 | **reached, not ported**: BUGS-28/29/49/51/52/77 (4/5, 6/8, 2/10 hunks fail) |
| 8 | `llm/provider.ex` | 0 | unchanged |
| 9 | `llm/provider_caps.ex` | 6 | **reached, not ported**: the BUGS-51/52/77 caps (paired with 5 and 7) |
| 10 | `llm/request.ex` | 6 | not ported: `speed`, `cache: :none`, the third cache marker are features of the synced engine |
| 11 | `llm/result.ex` | 1 | **reached, not ported**: BUGS-29 (paired with 3 and 7) |
| 12 | `llm/sse.ex` | 0 | unchanged |
| 13 | `llm/tool_args.ex` | 0 | unchanged |
| 14 | `providers/provider.ex` | 0 | unchanged |
| 15 | `tools/atomic_file.ex` (`atomic_file.ex`) | 0 | unchanged |
| 16 | `tools/edit_file.ex` | 8 | **ported**: `Path.resolve_write/2` (BUGS-1). Not reached: BUGS-12 (title), BUGS-3 (rewind; no checkpoints live). Not fixes: fuzzy passes, multi-file edit, T18/T19 efficiency |
| 17 | `tools/grep.ex` | 6 | not reached: BUGS-22 is the ripgrep path; the live grep is the Elixir scan only. BUGS-12 is the title |
| 18 | `tools/list_dir.ex` | 1 | not reached: BUGS-12 title |
| 19 | `tools/path.ex` | 6 | **ported**: a64d6ff6 `resolve_write/2` whole (`.git`, `.claude`, `.swarm_code/memory.md` and `config.json` with its own message, case-folded on the lexical and the real relative path) |
| 20 | `tools/read_file.ex` | 3 | **ported**: BUGS-44 (09774f87, the resume hint follows the returned lines). Not reached: BUGS-12 title |
| 21 | `tools/run_command.ex` | 11 | **ported**: the secret-name env scrub of desktop pass 60 (ff6ac47c: `@secret_name`, `clean_env/1`, keeps `GITHUB_TOKEN`/`GH_TOKEN`; the A5 commit message calls it BUGS-55, which is wrong) and the CLI `umask_prefix()`. Not reached: BUGS-23/54, UX-9 and 3b4eefdf (yield, poll, background: the live copy has no yield). Not fixes: T101 rolling tail, the higher output cap, wording |
| 22 | `tools/tool.ex` | 2 | not reached: BUGS-47 is web_fetch's callback |
| 23 | `tools/write_file.ex` | 3 | **ported**: `resolve_write/2`. Not reached: BUGS-12, BUGS-3 (description text about rewind) |
| 24 | `test/…/llm/chunks_test.exs` | 0 | unchanged |
| 25 | `test/…/llm/efforts_test.exs` | – | unchanged (follows 5) |
| 26 | `test/…/llm/sse_test.exs` | 0 | unchanged |
| 27 | `test/…/llm/tool_args_test.exs` | 0 | unchanged |
| 28 | `test/…/tools/grep_test.exs` | – | unchanged (follows 17) |
| 29 | `test/…/tools/path_test.exs` | – | **changed**: `describe "resolve_write/2"`: config.json, `.SWARM_CODE/CONFIG.JSON`, a symlink to it, memory.md and `.git`/`.claude` refused; `.swarm_code/specs` writable |
| 30 | `test/…/tools/read_list_test.exs` | – | **changed**: the two BUGS-44 suffix assertions (desktop 09774f87) |
| 31 | `test/…/tools/write_edit_test.exs` | – | unchanged |
| 32 | `core/…/commands.ex` (`components/chat.ex`) | – | CLI-only (the core command registry, extracted from chat.ex once); not reached by the live runtime |
| 33 | `commands/files.ex` (`commands.ex`) | 1 | not ported: T97 deletes `Commands.template/0` (dead code) |
| 34 | `daemon/service/command_dispatcher.ex` (`live/workspace_live.ex`) | 101 | CLI-only (C owns it, may repin); not the live runtime |

New live test files (not ledger entries): `test/swarm_code/tools/read_file_resume_test.exs` (the
desktop's `polish74_o2_read_file_test.exs` against the live copy; watched failing 3/3 before the
port) and `test/swarm_code/tools/run_command_env_test.exs` (env names only; never prints values).

Repinned in A5: `tools/path.ex`, `write_file.ex`, `edit_file.ex`, `run_command.ex`,
`read_file.ex`, `test/…/tools/path_test.exs`, `test/…/tools/read_list_test.exs`.

**Open (A5, needs a decision).** The LLM correctness fixes the live runtime reaches (BUGS-28,
29, 49, 50, 51, 52, 77) are not ported. Their hunks need the desktop's pass 62/63/69 LLM work
under them (error kinds, rate limits, per-provider-and-model caps), which is 275 (anthropic),
558 (openai) and 633 (http) diff lines from the live copies. A hand port would mean writing a
third LLM stack. Proposed fix: point `Daemon.Runtime.Run` at the synced `SwarmCode.Domain.LLM`
(which has every fix) and drop the 13 frozen LLM entries. That folds them into mappings, which
the contract forbids in this pass, so it needs an owner decision.

## A6 Ultra stays "workflows" (deviation)

Desktop pass 71 gives Ultra the mission tools and an orchestrator prompt. The CLI keeps its
Ultra until the missions pass. There are two recorded patches:

- `domain/tools.ex`: the `opts[:ultra]` branch returns `@workflow_modules ++ @swarm_modules`.
- `domain/engine/prompts.ex`: the CLI `@ultra` text.

Deviation: the patch also restores
`authoring? = opts[:authoring] || opts[:ultra] || create_workflow?`. The desktop dropped
`opts[:ultra]` from that line. Without it, the CLI's Ultra text points to "the procedure below",
and that procedure is not in the prompt. The rules bullet ends "…or /workflow, or turned Ultra
mode on." as it did in 0.1.0.

Test: `test/swarm_code/domain/engine/cli_ultra_test.exs` (4 tests):

- the Ultra tool set has the workflow tools and no `mission_start`;
- the Ultra prompt has the CLI text, the bullet and `WORKFLOW AUTHORING MODE`, and no mission
  wording;
- a plain turn names no mission;
- `Workflows.list/1` does not list the builtin `mission` workflow.

## A7 drift gate

`mix swarm_code.provenance.drift [--ref REF] [--upstream PATH] [--strict]` is the contract's
output. It adds two outputs the contract does not specify:

- the clean line `ncode CLI drift: none (desktop main (4c7c577) adds no migration and no domain
  commit since the pin 4c7c577).`
- the error `cannot resolve <ref> in <path>.` (exit 1).

It is read-only: `rev-parse`, `ls-tree` and `rev-list` only, each bounded to 30 s.

The test, `apps/swarm_code_core/test/mix/tasks/swarm_code.provenance.drift_test.exs` (5 tests),
uses a scratch git repo. Deviation: it was written after the task, so I never saw it fail.

The gate runs from two places:

- `mix precommit`, without `--strict`, after `sync --check`.
- `scripts/dev/build_release.sh`, as `--strict`, right after `cd "$root"`. `NCODE_ALLOW_DRIFT=1`
  skips it and says so.

## A8 version and the parity checklist

- Every `mix.exs` now says 0.2.0. The umbrella's change went into the A7 commit, staged together
  with the precommit alias.
- Test literals that mean "this app" are now 0.2.0 or `Application.spec(…, :vsn)`:
  - `foundation_gate_test`
  - `cross_app_lease_test` and `test/production/cross_app_lease.exs`
  - `guarded_repo_test`
  - `repo_launcher_test`
  - the `backup/gate_test` application assertion and its `app_version:` literal
  - `os_process.ex`
- C's `ui/data_source/fake/settings.ex` `"service"` is now 0.2.0; the contract names it.
- These stay 0.1.0 because they describe an old reader or self-consistent fixtures: the schema
  `gate_test` `app_version:` arguments, the launcher tests' `start_erl.data` fixtures and their
  "ncode 0.1.0" text, and `minimum_reader` "0.1.0-dev".
- `git tag -l v0.1.0`: the annotated tag `02ef4cd` points at commit `c0808ea`, as the contract
  says. I created no tag.
- Deviation: the version test is `apps/swarm_code_cli/test/swarm_code_cli/version_test.exs`, not
  `…/release/version_test.exs`. `release/` is in `locked_branch_test`'s conditional campaign
  paths, and the audit failed with the file there. It checks:
  - vsn `~c"0.2.0"` for the three apps;
  - the synced MCP and LSP `clientInfo` are `%{"name" => "ncode", "version" => "0.2.0"}`
    (`domain/mcp/client.ex`, `domain/lsp/client.ex`, no patch).
- The README now says 0.2.0, desktop `4c7c577`, 58 migrations, the 57- and 53-row upgrades and
  the drift gate.

Parity checklist, desktop 0.2.0 → CLI 0.2.0:

| Desktop 0.2.0 | CLI state |
| --- | --- |
| Ultra missions (engine: `Missions*`, `mission_start`, `priv/workflows/mission.exs`) | synced (code present), **not wired**: the CLI Ultra stays workflows (A6). Deferred to the missions pass: mission card, approval card with Worker and Validator pickers, Mission Control |
| Worker and Validator models (`20261018000001`, `validator_provider_id`/`validator_model`) | schema synced (58), and the CLI may run the migration itself. The CLI's labels ("Sub agent model" → "Worker model", the Validator row) are D/E's surfaces, not A's: deferred to the missions pass |
| Speed monitor | `LLM.Speed` synced and started (A2). Deferred: the CLI speed strip |
| Workflows cockpit (desktop pass 58) | deferred to the missions pass |
| ncode rename (model-facing strings, `NCODE.md`, `NCODE_*` hook vars, clientInfo) | synced (A1). `providers.ex`, `project_context.ex` and `llm/openai.ex` patches dropped |
| BYOK, no seeded provider | synced (`Providers.seed_defaults/0` is the desktop's) |
| Spec 74 fixes in the domain (BUGS-1 protected paths, BUGS-59 clone at HEAD, BUGS-44, BUGS-48/54, EFFICIENCY-*) | synced. Live-runtime copies: see A5 |
| Boot/quit: repair, cleanup supervisor, sweep deltas | ported (A2) |
| Version 0.2.0 | ported (A8) |
| macOS 15 plist floor, `.app` names | n/a (desktop bundle only) |

## A9: what the sync fixed (one part reported to F)

### Protected paths (contract part 1)

- `polish74_o2_protected_paths_test.exs` is not mapped. It `use`s `SwarmCode.DataCase`, which the
  CLI does not have.
- Its cases are ported in `test/swarm_code/domain/tools/cli_protected_paths_test.exs` (3 tests,
  green). They run against the synced `SwarmCode.Domain.Tools`:
  - Every write tool (`write_file`, `edit_file`, `edit_files`, `move_file` from/to,
    `delete_file`) refuses each of six protected paths, with or without case folding. Every
    file stays byte-identical.
  - `config.json` gets its own message.
  - `.swarm_code/specs` and `commands` stay writable.
- The `LLM.Fake` turn case is not ported.

### Dirty tree (contract part 2)

The test is `test/swarm_code/domain/engine/cli_dirty_tree_test.exs`.

Setup:
- The project is a git repo with `a.txt` modified, `b.txt` staged and `wip.txt` untracked.
- `Engine.start_swarm/2` runs with `isolation_backend` `worktree` and with `clone`.
- The lead calls `spawn_agent`. The worker answers without a tool call.
- The CLI domain has no `LLM.Fake`, so the provider is a loopback OpenAI-compatible server
  (`SwarmCode.Test.LoopbackHTTP`). The guarded Repo launch follows `pass70_saved_turn_test`.

Outcome on desktop 4c7c577a, both backends:
- The worker is clean:
  - its report has `[No file changes.]`;
  - there is no "Changes on branch";
  - the project's four files and `git status --porcelain` are unchanged.
- So 93b58ea6 (BUGS-59, a clone starts at HEAD) holds for both backends.
- **The contract's strict assertion fails.** The report ends:

  ```
  Nothing to change.

  [No file changes.]
  Delta patch captured: 0 bytes, 0 files changed
  ```

  `RunServer.finalized_result/4` appends the spec 72 D3 delta note after
  `report_with_note/5`'s note. It does this whenever `delta_info` is `{:ok, …}`, even with
  0 files.

**Report to F (desktop):**
- Problem: `finalized_result/4` should not append "Delta patch captured" when `files == 0`, or
  should put the delta line before the note.
- Recommended desktop fix: in `finalized_result/4`, use `""` for
  `{:ok, %{files: 0}}`.
- CLI status:
  - Not patched here, as A9 says.
  - The strict form is two `@tag skip` tests in the same file. Their skip reason says "reported
    to F".
  - A' unskips them after the re-sync.
  - The two running tests pin everything else, and require a 0-file count if the delta line is
    present.
- The tests also wait for the run's `CleanupSupervisor`/`TaskSupervisor` children before the
  module's guarded Repo closes. Without that wait, the post-run cleanup logs a "repo not started"
  error.

## Deviations (all of A)

1. A1:
   - The `Format` web shim, plus `domain/format.ex` as a new frozen entry.
   - The web-shims rule pattern was widened.
2. A1: `source-policy.json` records no pins. 4c7c577a went into the `SOURCE_AUTHORIZATION.md`
   addendum and `@adaptation_pins` instead.
3. A1: `polish74_o2_protected_paths_test.exs` is not mapped (DataCase). It is ported as the
   CLI-local test (A9).
4. A1: I touched C's `feature_catalog_test.exs` (one `Projects.trust/1` line) and the support
   file `domain_fixtures.ex`.
5. A2: the unfinished-node repair runs inline in Boot.
6. A3: the manifest generator ran on a scratch `--shared` clone, because the desktop checkout has
   untracked files.
7. A5: LLM correctness fixes were not ported. The review reached them, but they need an owner
   decision (tasks_open).
8. A5: the commit message names the env scrub "BUGS-55". It is pass 60 (ff6ac47c).
9. A6: the authoring flag is restored for Ultra.
10. A7: the drift task's clean and error lines are my wording. Its test was written after the
    code.
11. A8:
    - `version_test.exs` path moved (locked_branch_test).
    - The umbrella version is in the A7 commit.
    - C's fake `settings.ex` was edited, as the contract names it.
12. A9:
    - Loopback provider instead of `LLM.Fake`.
    - The strict dirty-tree assertion is skipped and reported to F.
13. My own literal moduledoc/comment sha strings that mean "the current pin" are updated. Not
    changed:
    - C's `persisted_backend.ex:1928` and `persisted_backend_test.exs:41`. They say "engine
      6dd8d82" for what pass 70 was written against, so they are historical.
    - `pass70_upstream_units_test.exs`, which is historical too.

Stubs the finisher must remove:

- `apps/swarm_code_daemon/test/swarm_code/settings/c74_registry_parity_test.exs`:
  `@validator_stub` (the three `default_validator_*` settings columns of migration
  `20261018000001`) is counted and exempted. Once E1's `models.validator` / `efforts.validator`
  entries store them, remove `@validator_stub` and its two uses. The count becomes `79 + 3 + 3`,
  or whatever E1 decides.

## AGENTS.md text for the finisher (CLI)

Replace the pin-specific lines (the "desktop `6dd8d82`"/"57 migrations" mentions) with:

> The domain is synced to desktop `4c7c577a` (desktop 0.2.0); its schema contract is
> `desktop-4c7c577` (58 migrations, `apps/swarm_code_daemon/priv/schema/desktop-4c7c577.json`),
> and `forward_compatible` lets the CLI run `20261015000004`, `20261016000001`,
> `20261016000002`, `20261017000004` and `20261018000001` itself after the verified backup.
> `mix swarm_code.provenance.drift` (in `mix precommit`; `--strict` in
> `scripts/dev/build_release.sh`, override `NCODE_ALLOW_DRIFT=1`) fails when the desktop's `main`
> has migrations the pin lacks: re-pin (sync, contract, manifest) before any release.
> `SwarmCodeWeb.Format` maps to the frozen `SwarmCode.Domain.Format` (the pure `preview/2`,
> `clip_line/3`, `window/2`); repin it by hand when the desktop changes them.
> The CLI keeps its own Ultra (workflow + swarm tools, the CLI `@ultra` text): two recorded
> patches in `domain/tools.ex` and `domain/engine/prompts.ex`; keep them on every sync until the
> missions pass.
> The 13 frozen `dmn/llm/**` entries are behind the synced `domain/llm` by the spec 74 LLM fixes
> (see `docs/superpowers/plans/2026-10-07-cli-0.2.0/notes/A.md`, A5).
> Test fixtures the mapped tests call from `SwarmCode.Fixtures` live in
> `apps/swarm_code_daemon/test/support/domain_fixtures.ex` (`assistant_identity/0`, `eventually/2`).

## Tests and gates run (worktree `cli020-A`)

Focused runs while iterating (`env -u MIX_QUIET mise exec -- mix test <file>`, one app per call):

- All `apps/swarm_code_daemon/test/swarm_code/domain`: 361 tests, 0 failures, 2 skipped. The
  two skips are the strict A9 dirty-tree tests.
- `apps/swarm_code_core/test`: 202 tests, 0 failures. This includes the drift test (5).
- `apps/swarm_code_daemon/test/swarm_code/tools`: 86 tests, 0 failures. This is the live copies
  after A5. `read_file_resume_test` was watched failing 3/3 before the BUGS-44 port.
- `cli_dirty_tree_test`: 4 tests, 0 failures, 2 skipped, run twice. `cli_protected_paths_test`:
  3 tests, 0 failures.
- CLI `version_test` plus `locked_branch_test`: 10 tests, 0 failures.
  - X12: `locked_branch_test` passes in this worktree, whose `deps`/`_build` are APFS clones
    and which has no `_build/prod`.
  - It failed once, on its conditional-path audit, while `version_test` sat under
    `release/`; that is why the file moved.
- The five files the first full precommit failed (`c74_registry_parity`,
  `c74_project_config`, `backup/gate`, `command_dispatcher`, hooks): 88 tests, 0 failures after
  the fixes.

Gates:

- `mise exec -- mix swarm_code.provenance.verify`: "provenance verified".
- `mise exec -- mix swarm_code.provenance.sync --check`: "every synced file derives from the
  pinned commit".
- `mise exec -- mix swarm_code.provenance.drift`:
  - before F merged: "none (desktop main (4c7c577) …)";
  - in the last precommit, after desktop `main` moved to F's merge `7b8f379f`: "9 desktop
    commits since the pin touch the domain (no new migrations)". That is a warning with exit 0,
    and it is A'1's job.
- `sh scripts/dev/check_schema_snapshot.sh`: 12 tests OK.
- `mix compile --warnings-as-errors --force`: 0 warnings. `mix format --check-formatted`: clean.

Full suites (`env -u MIX_QUIET mise exec -- mix precommit`, one suite slot each, line removed
after):

1. Run 1, at about 11:29. Core 202/0. Daemon 1338 tests, 5 failures, 2 skipped:
   - `c74_registry_parity` (the 3 new settings columns);
   - `c74_project_config` ×2 (the hooks hunk);
   - `backup/gate_test` (the manifest version);
   - `command_dispatcher_test` (project trust).

   CLI 2662/0. All five were fixed in "cli020 A1: drop the obsolete NCODE_* twin hunk" and
   "cli020 A8: backup gate decisions carry this build's version".
2. Run 2, at about 11:58.
   - Format, compile, unlock: OK. Core 202/0. Daemon 1338/0 (2 skipped).
   - CLI: 10 properties, 2662 tests, **1 failure**. `SwarmCodeCLI.UI.DataSource.DaemonTest`
     "watch delivery receives an owner receipt and ACK is emitted only after consume"
     (`daemon_test.exs:34`): `CaseClauseError {:error, :enotconn}` in the test's own fixture
     server, `send_frame/2` at line 1030.
   - The provenance verify, sync check, drift, schema snapshot (12 OK) and unicode steps all
     passed.
   - Re-run alone 3 times: 26 tests, 0 failures each time. It also passed in run 1. This is a
     **load flake** under §4.4 (the fixture server's socket closed under load), in C's test file,
     which A does not touch.

## A' (branch `cli020/A2` from M2 `647569ec`, worktree `cli020-A2`)

Done by the integrator (the M2 agent), as owner A for A'.

- **A'1** `mix swarm_code.provenance.sync --ref 7b8f379f5ed5976a191c08708af824d10b919633
  --upstream /Users/zaali/dev/swarm-code`: 15 synced files changed (policy, operation,
  run_server, engine, agent_server, conversations, message, node, prompts, attachments, hooks,
  project_config, tools, command_safety, research/server, mapped policy_test), 2 new
  (`engine/rules.ex`, `tools/update_plan.ex`). One conflict, the one predicted above:
  `run_server.ex`'s approval map (F1's `mode: mode` + the CLI's `requested_at:`, both kept).
  A6 (tools.ex/prompts.ex) and the hooks.ex umask hunk merged cleanly. `agent_server.ex`,
  `command_safety.ex` and `research/server.ex` changed too (F8's ctx key and F10; not in the
  contract's expected list, all unpatched). `7b8f379f…` is the sixth `@adaptation_pins` entry
  plus a `SOURCE_AUTHORIZATION.md` addendum (same deviation as A1: `source-policy.json` records
  no pins). Schema contract unchanged; `drift --strict`: no new migration, no domain commit.
  `domain/format.ex` stays frozen at 4c7c577a (format.ex unchanged upstream).
- **A'2** `pending_interactions.ex`: `mode: "read_only"` → `[:approve, :deny, :deny_stop]`;
  every row has `approval_mode` (the row-key contract test gained it). **Deviation:** the wire
  half the contract gives to C (C's lane closed before A'1) is done here: the persisted
  backend's card carries `"approval_mode"`, `DTO.Approval.approval_mode` (optional, 32 bytes)
  and the codec's optional-field list. New `daemon/service/read_only_ask_test.exs` uses the
  loopback OpenAI-compatible server (no `LLM.Fake` in the CLI domain); the denial is in the op
  node's `error`, not `result`.
- **A'3** `boot.ex`: `prune_abandoned(now, 24, keep: CommandLedger.staged_attachment_ids())`.
- **A'4** `shutdown.ex`: the desktop's `Quit.session_end_hooks/1` (trusted, non-scratch
  projects opened since the VM started, ≤ 20, 5 s cap, `Hooks.TaskSupervisor`), run as the
  first step, before the runs stop (the contract's order; the desktop runs it after
  `stop_everything`). Context `%{reason: "quit", timeout_cap_ms: cap}`.
- A9's two strict dirty-tree tests are unskipped (F4 synced): 4/0 on both backends.
- Stubs left for the finisher (§8.1, not A' tasks): C's `shell_message_role/0` flip to
  `"shell"` (F3 is synced), C's `Rewind.supersede/2` direct `supersede_from/2` call (F2 is
  synced; the `function_exported?` branch now takes it at runtime), B23's `--approval`
  wiring (F8's `opts[:approval_mode]` is synced).
- Tests: domain dir + boot/shutdown/read_only_ask/project_config/pass70_approval/rewind/
  shell_escape: 411 tests, 0 failures, 2 skipped (the two now unskipped: 4/0 alone).
