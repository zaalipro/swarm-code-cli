# CLI pass 74 outcome: `/settings`

Finisher report on `c74/integrate` (worktree `/Users/zaali/dev/swarm-code-cli-wt/c74-F`). The branch
starts from main `fb99d0f`. The five owners' branches were merged in plan order with `--no-ff`:

- `c74/S1`: the settings registry, the service core and the wire. Merged as 8899cfa.
- `c74/S2`: the integration actions (providers, search, MCP, pricing, storage, library, files).
  Merged as 1026f45.
- `c74/U1`: the layer, the reducer, the projector, the editors and the tasks. Merged as f78021a.
- `c74/U2`: the eight integration sections and `Fake.SettingsIntegrations`. Merged as 92077e5.
- `c74/U3`: the terminal sections, key capture, `swarmcode config` and the launch. Merged as 0f7fcbd.

After the merges come the finisher commits F1 to F45 (F2 went into F1's second commit). F1–F21
are in `git log`; F22–F45 are listed at the end. The pass was interrupted once, while the finisher was at F21. The rerun did not redo the
merges or F1 to F21. It committed the README/AGENTS edits (F22) and then kept testing in the
sandbox; F23 to F45 are what that testing and the final checks found.

The sandbox:

- `HOME=/Users/zaali/.cache/c74/sb/<run>/home`, a `cp -c -R` copy of
  `~/.cache/p70cli/sandbox-home` (57 migrations, the owner's providers copied earlier). The runs
  used are `r1` to `r9`; `r8` and `r9` unset every provider variable (`extra.env`), because a shell
  `SWARM_API_KEY` made first-run onboarding add a provider before A36 could look.
- A loopback models stub, `sb/stub.py`, on 127.0.0.1:18741. It answers `GET /v1/models` with
  `stub-a` and `stub-b`, answers `401` when the key contains `BAD`, never answers under `/hang`, and
  lists 2 500 models under `/big`. `sb/requests.log` records method, path and key length only.
- The release built with `scripts/dev/build_release.sh` from this branch. The final copy, at F44,
  is in `/Users/zaali/.cache/p70cli/rel-c74/`.
- GNU screen with `-L` raw logs, replayed by `sb/vt.py` and turned into PNGs by `sb/svg2png.py`
  (`sb/shot.sh`). Contact sheets come from `sb/sheet.py`. A screenshot is `sb/<run>/shots/NAME.png`
  with `NAME.txt` (the text) and `NAME.raw` beside it.
- DB checks: `sb/q.sh`, which runs `sqlite3` read-only (`mode=ro`, `immutable=1` when no `-shm`)
  on the sandbox database only.
- Real provider calls: none. Every test and fetch went to the loopback stub.

## What the owner will notice

- `/settings`, `/config`, `/prefs`, F2, the palette row and `swarmcode settings [QUERY]` open one
  layer. It has 22 sections: Overview plus 21 in six groups. There is a rail, a page and a drawer
  that explains the focused row: what it is, where its value comes from and when a change applies.
  Esc gives back the chat exactly as it was.
- Each value says where it comes from (`global · shared with the desktop app`, `project`, `this
  conversation`, `cli.json`, `env SWARM_THEME`). The desktop app reads the same database columns,
  so a change made here shows up there, and a change made there reaches an open layer within one
  frame, marked `changed elsewhere`.
- Providers work end to end. The steps are `a`, then a preset, a name and a URL, then a paste of
  the key (it is never shown or echoed). Ctrl-S creates the provider, opens it and tests it:
  `✓ listed 2 models in 3 ms · 09:54`. `f` shows the difference (`+ stub-a new`,
  `0 → 2 after this fetch`) and writes only after `a`. `t`/`f` on a list row open the provider
  first, so the result can be seen (F39).
- Storage measures when its page opens: `50 MB on disk · 65 KB write-ahead log`, a bar per kind,
  and the Clean up wizard with preset counts (`27 items · 12 MB`). Before F41 to F44, against the
  real service, this page said `— on disk` and `✓ 0 B on disk`.
- At 120 columns the drawer moves under the page. From 90 to 119 columns a one-row section strip
  replaces the rail. From 80 to 89 columns the sections are a page of their own, and Esc steps
  back one level at a time. Below 80 × 20 there is one sentence that names `swarmcode config`.
- `swarmcode config get|set|list|records|secret|export|import` does the same from scripts and SSH.
  Secrets come only from `--stdin`, and nothing is echoed.
- The header counts `• 31 changed from default  ! 1 need attention  1 from env` on every page, and
  it stays after a write (F38).

## Catalogue coverage

`Registry.all()` has 170 entries (the A3 test prints the number). Every one appears once on its
section page and is found by label, key and each synonym (A3, `c74_acceptance_test.exs`). The
130 scalar settings, by section (from `docs/settings.md`, generated, checked by
`c74_settings_docs_test`):

| Section | Scalar settings | Records / actions on the page |
|---|---|---|
| Overview | — | 18 attention sources, "changed from default", where values come from |
| Models & effort | 23 | Apply a profile, Fetch every provider's models, Reset this section |
| Providers | — | providers (record + draft + key paste + test + fetch + delete with replacements), effort levels sub-page, models list sub-page |
| Pricing | — | pricing rows, used-but-unpriced group |
| Search & web | 1 | search providers (order, key, test) |
| Deep research | 17 | — |
| MCP servers | — | servers (env/headers with masking, tools on/off, reconnect, `.mcp.json` import) |
| Language servers | 13 | check, stop, unknown keys |
| Agents & limits | 14 | — |
| Approvals & trust | 4 | trust/untrust, always-allowed commands |
| Project file | 5 | hooks, profiles, raw file edit |
| Memory & instructions | — | memory files, instructions file |
| Library | — | commands, agent definitions, skills, workflows (templates, smoke) |
| Appearance | 6 | — |
| Layout & transcript | 6 | — |
| Keys & input | 6 | key bindings (capture, `+`, `x`, `X`) |
| Session & startup | 2 | — |
| Storage | 2 | measure, Clean up wizard (Quick / Sessions / Advanced), VACUUM, apply retention |
| Budget & usage | 1 | by-model usage table |
| Desktop app | 30 | window state (read-only) |
| Files & environment | — | paths, doctor, environment (secret values masked), Make it private |
| Import & export | — | export, import preview, Reset everything |

By scope: 88 global, 20 cli, 13 session, 4 project, 5 project_file (read-only here).

## Acceptance

`test` = an ExUnit test in the precommit run. The files are under `apps/*/test/**/c74_*`; the main
one is `apps/swarm_code_cli/test/swarm_code_cli/c74_acceptance_test.exs`. `sandbox` = seen in the
release, with the screenshot or DB dump named.

| Id | Result | Evidence |
|---|---|---|
| A1 | pass | test (`c74_acceptance`, `c74_terminal_preferences`); sandbox `swarmcode settings [providers\|storage]` in r9 |
| A2 | pass | test: 22 sections × 160×45, 120×30, 90×30, 80×24. Sandbox walks: `r9/shots/Z160-01…22.png`, `Z120-01…22.png`, `Z80-00…02.png`; sheets `r9/sheets/Z160-a.png`, `Z160-b.png`, `Z120-a.png`, `Z80.png` |
| A3 | pass | test (170 entries, label/key/synonym, `/settings <key>`) |
| A4 | pass | test (every record kind page) |
| A5 | pass | test |
| A6 | pass | test (a loop over every writable scalar) |
| A7 | pass | sandbox r2: `a7.settings/project/conv.before/.after` dumps. `monthly_budget_usd` → 50, `research_max_live` → 12, `research_reader` → jina, `storage_retention_days` → 90, `approval_mode` → auto, `consensus` = 1, `ultra` = 0, `authoring_workflow` = 0, `mode` = build. `max_concurrent_agents` 6 and `mode` light were already those values in this sandbox. No other column changed apart from `updated_at` |
| A8 | pass | test |
| A9 | pass | test; F24 (the env line once) |
| A10 | pass | test |
| A11 | pass | test |
| A12 | pass | test |
| A13 | pass | test (`c74_config_command`) |
| A14 | pass | test |
| A15 | pass | test |
| A16 | pass | test |
| A17 | pass | test; sandbox r8: `g2-paste.png`, `g2-rec.png` (key stored, row `●●●●●●●● set · ends …`) |
| A18 | pass | test (`c74_secret_canary`, `c74_acceptance`) |
| A19 | pass | test (`c74_secret_canary`) |
| A20 | pass | test |
| A21 | pass | test |
| A22 | pass | test; sandbox r9 `m4-00.txt`: `✓ listed 2 models in 3 ms · 09:54`, `requests.log` one `GET /v1/models`, `providers.models` still `[]` |
| A23 | pass | test (`c74_tasks`, `c74_backend_settings`) |
| A24 | pass | test (`c74_tasks`, `c74_mcp`) |
| A25 | pass | test; sandbox r9 `m8-00.txt` (`0 → 2 after this fetch`, `+ stub-a new`, nothing written) |
| A26 | pass | test |
| A27 | pass | test; sandbox r9 `m7-00.png` (the measured overview) and `m7-02.png` (the Clean up wizard). Nothing was deleted in the sandbox |
| A28 | pass | test |
| A29 | pass | test; `mix swarm_code.keymap --check` (see below) |
| A30 | pass | test |
| A31 | pass | test |
| A32 | pass | test (F33 brought the section strip) |
| A33 | pass | test (F33); sandbox r9 `Z80-00.png` (a page with `Esc sections`), `Z80-01.png` (the sections page), `Z80-02.png` |
| A34 | pass | test (F25: NO_COLOR rows stay one row each) |
| A35 | pass | test |
| A36 | pass | test; sandbox r8 `g2-a36-open.png` (fresh database, no provider variables) |
| A37 | pass | test |
| A38 | pass | test |
| A39 | pass | test |
| A40 | pass | test |
| A41 | pass | test |
| A42 | pass | `mix precommit` on the final tree (see below) |
| A43 | pass | test (`c74_client_e2e`, `c74_secret_canary`); F12, F16 |
| A44 | pass | test (`c74_pricing`, `c74_f_table_rows`) |
| A45 | pass | test; F13, F14 (found in the sandbox) |
| A46 | pass | test (`c74_lsp`, `c74_f_table_rows`); F15 |
| A47 | pass | test (`c74_project_config`, `c74_approvals`) |
| A48 | pass | test (`c74_library`) |
| A49 | pass | test (`c74_memory`, `c74_files`) |
| A50 | pass | test (`c74_budget_desktop`) |
| A51 | pass | test (`c74_editors_u3`, `c74_budget_desktop`) |
| A52 | pass | test (`c74_files_env`); sandbox r9 `m8-01.txt` (Database row filled, F43) |
| A53 | pass | test (`c74_import_export`, `c74_transfer`); sandbox r5 `f6-reset-done.png`, `f7-reset-done.png` (F32) |
| A54 | pass | test (`c74_approvals`) |
| A55 | pass | test (`c74_effort_levels`); F35 (the preset picker answers) |
| A56 | pass | test (`c74_providers`, `c74_client_e2e`) |
| A57 | pass | test (`c74_values`, `c74_overview`) |
| A58 | pass | test (`c74_connection`, `c74_data`, `c74_settings_codec`) |
| A59 | pass | test (`c74_values`) |
| A60 | pass | test (`c74_search`) |
| A61 | pass | test (`c74_config_command`); F10, F11 (found in the sandbox) |
| A62 | pass | test |
| A63 | pass | test |

## Checks run at the end

- `mix precommit` on the final tree, with `_build/prod` removed first: core 194 tests, daemon 1 237
  tests, CLI 10 properties and 2 387 tests, 0 failures; provenance verify, `provenance.sync
  --check`, the schema snapshot (12 Python tests) and both Unicode checks pass. Two earlier runs
  of this rerun did not pass. In the first, `Backup.GateTest` "VACUUM INTO includes committed WAL
  rows…" failed once; the same file passed its 55 tests alone and in the next full run, and the
  pass did not touch the backup code. The second run stopped at provenance verify, because F42
  had edited the synced `domain/storage.ex`. F45 recorded that edit as the file's CLI patch.
- `(cd apps/swarm_code_cli && mix swarm_code.keymap --check)`: `docs/keybindings.md matches the
  binding table`.
- `scripts/dev/check_terminal_port.sh`: `cargo fmt --check`, 58 Rust tests, 58 locked crate
  records and 108 license texts verified.
- PTY suites: `scripts/dev/test_terminal_demo_pty.py` 8 tests OK,
  `scripts/dev/test_saved_session_pty.py` 1 test OK.

## What the finisher fixed after the rerun (F22–F45)

The sandbox found almost all of these. Each commit has a test that fails without it.

- F24 the Theme row said `SWARM_THEME` wins twice; F25 NO_COLOR rows grew a second row; F26
  `config records provider` refused the singular kind; F27 a test sat in a LockedBranchTest
  campaign path; F28 an import preview did not know the database's providers by name.
- F29 a paste on a key row before Enter was dropped; F30 action rows repeated their label; F31
  Enter after a typed confirmation word pressed Cancel; F32 Reset everything left the database
  values alone.
- F33 the 90–119 section strip and the 80–89 sections page (T§6.1) were missing.
- F34 no draft page could keep a field (`draft_put` stored fields at the draft's top level while
  every page read `draft.fields`); F35 the provider and effort-level preset pickers did nothing;
  F36 Ctrl-S on a new provider did not test it, and a pasted draft key said "kept for the import".
- F37 the provider header printed UTC beside a local test time.
- F38 the attention count vanished from every page but the Overview after any write.
- F39 `t`/`f` on the Providers list gave no visible result.
- F40 a fast task (a 3 ms loopback test) ended before its command was answered and then counted up
  forever as "testing".
- F41 and F44 task summaries: the layer stored a wrapper, and then the raw result, where the pages
  read the service's page summary. Storage, the fetch difference, the wizard, the imports and the
  LSP check all read the wrong map.
- F42 and F43 Storage and Files & environment could not find the database. The guarded repo opens
  a VFS name and its config has no path, so they said `0 B on disk` and `Database …`. The launcher
  now records the file while its pool runs.
- F45 records F42/F43's edit of the synced `domain/storage.ex` as its provenance patch.

## What is open

- The QA passes that follow in the workflow have not run yet.
- The CLI repo has no `CHANGELOG.md` for F-7's pass-74 entry. As in passes 70–73, this document
  is the record of the pass.
- U2's note: `x` on an unknown `lsp_servers` key sends `lsp.remove_key` with `undo: false`, so it
  cannot be undone. §2.8 says it can. An `lsp.restore_key` action (target `{key}`, attributes
  `{value}`) would close that gap.
- The sandbox did not delete anything with the Clean up wizard or run VACUUM on the sandbox
  database. Those paths are covered by `c74_storage_test` / `c74_safety_test` only.
- The sandbox did not repeat A7's `max_concurrent_agents` and `desktop.mode` with values that
  differ from the sandbox's own; the tests cover the columns.
- F43 adds two lines to `RepoLauncher` (record the database file after the pool starts, forget it
  when the pool stops). The guarded-repo test covers it. It is the only change this pass made in
  the daemon's boot path.
- Pricing briefly drew `!1` and then cleared it when the layer opened straight at Providers.
  F38 fixed that; it did not happen again in `m2-00`/`m3`.
