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

## QA #1 and the polish (G11–G25)

QA #1 (`/Users/zaali/.cache/c74/Q1/qa.md`) reported F-1 to F-10 as P1 and F-11 to F-23 as P2. Its
report had no P0. Each fix has a regression test in `c74_qa1_test.exs` or in the section's own
test. The daemon fixes are tested in `c74_attention`, `c74_backend_settings`, `c74_search` and
`c74_transfer`. Each new test was run against the code without its fix and failed.

| Finding | Result | Commit |
| --- | --- | --- |
| F-1 a created provider or MCP server kept its draft and pasted key | fixed: the create drops the draft, and the new record's page replaces the draft's | G11 2c89b5b |
| F-2 undo overwrote a change made elsewhere | fixed: undo and redo are CAS writes. Section commands with an inverse (toggles, moves, prices) are now undo steps | G12 45730a2 |
| F-3 Esc after a search result's editor closed the layer | fixed: the editor ends back on the results. Esc clears the query, then leaves the search | G12 45730a2 |
| F-4 a result below an info row could not be reached | fixed: ↓ reaches every result. Enter picks the best-ranked result. Enter on an action result runs it in its own section | G12 45730a2, G24 838f450 |
| F-5 the keys sheet listed 7 keys | fixed: the sheet lists the bindings of the page under it, in groups, plus the marks and the value layers. The marks line up with the keys' help column | G13 7e6629b, G23 0bf1be8 |
| F-6 a typed MCP secret value was drawn | fixed: `NAME=` after a secret-looking name, or a token prefix after `=`, opens the paste on the add row | G16 a232775, G21 6348dc6 |
| F-7 `D` never deleted on a record page | fixed: `D` works from any row of a provider's or an MCP server's page | G14 869a054 |
| F-8 a deleted MCP server stayed listed until Ctrl-R | fixed: `mcp_changed` now produces a `settings_update` for `mcp` and `overview` | G15 c423b2a |
| F-9 a failed MCP server was not counted | fixed: the daemon's overview kept only one item because it read atom-keyed items with string keys. Items are now unique per id and target on both sides | G14 869a054, G15 c423b2a |
| F-10 `a apply all` did nothing | fixed: `a` and `+` work from any row of the page. The Models row lists the difference | G14 869a054 |
| F-11 `Couldn't save` printed twice; field error not under its row | fixed | G11 2c89b5b, G12 45730a2 |
| F-12 number messages | fixed: `is invalid`, `can't be blank` (core `TextValue` and the editor) | G17 97bcd01 |
| F-13 frame amendments | fixed: the search count (`search 130 settings, …`, `7 of 130 · 3 sections`), `writes to <layer> · <meaning>` on the status row, and the rail record counts. Deferred: the Overview header context (§4.1.11) and the `‹ … ›` segmented editor (§4.5). Both are new drawing work | G18 f2f501c, G19 22aac5c, G20 c402637 |
| F-14 Appearance preview cut at 160 columns | fixed: each box is 37 cells | G17 97bcd01 |
| F-15 truncations that hide the value | deferred. Wrapping a value under itself (§4.2) changes the row layout of the whole projector, which is too large for a polish pass | — |
| F-16 key binding rows repeated their tag | fixed | G17 97bcd01 |
| F-17 Desktop app rows carry a second line | no change. The spec asks for it: §3.7.5 and U3-11 require the `no effect in the terminal` line on every desktop row | — |
| F-18 NO_COLOR: no focus mark on a search result | fixed: the focused result carries `▌`/`>`. Under NO_COLOR and 16 colours, the focused row, picker option and confirmation button are reverse video (§4.11). Before, a picker's focused option looked like the others | G12 45730a2, G25 442b78e |
| F-19 `config export --help` wrote a file named `help` | fixed: `--help`/`-h` after a subcommand prints the usage | G17 97bcd01 |
| F-20 import preview listed unchanged terminal keys as changes | fixed: the preview compares against the client's `cli.json` and marks each key `same` or `change` | G19 22aac5c |
| F-21 words | fixed: `Moved Exa above Tavily`; the pending question names records (`the new MCP server`, `changes to github`); Storage counts in thin groups; the welcome card names the rebound palette key. Kept as the spec says: `medium (not set)` (`null_label` of `efforts.implementer`) and `at least 0 B reclaimable` (§2.20). Deferred: the lease refusal's `(<dir>)`, because the lease owner record holds no directory, and adding one changes the lease format the desktop shares | G16 a232775, G18 f2f501c |
| F-22 a renamed price did not open its row | fixed: `after_ops` accepts `{:open_record, section, kind, id}` | G12 45730a2 |
| F-23 Esc after a paste on Environment | not reproduced. A test keeps it working | G16 a232775 |

The polish sandbox found three more problems:

- G22 d31ee59: after a refused Ctrl-S, the `✗ can't be blank` line stayed under a field the user
  had filled in since.
- G24 838f450: Enter on an action search result did nothing, although its detail said `Enter
  run`.
- G25 442b78e: the NO_COLOR picker selection described under F-18.

The live check used a sandbox home (`/Users/zaali/.cache/c74/F/polish1/sb`), a loopback models
stub on 127.0.0.1:18743, and the release built from G20, then from G23, then from G25. It was
rendered with `vt.py`/`svg2png.py` into `sb/shots/`. The shots show:

- F-1: `p05`, `p06`. F-3: `f3a`–`f3e`; the sandbox DB `storage_retention_days` is 90. F-5:
  `f5`, `s18`. F-7: `p09`, `m10`. F-10: `p07`, `p08`. F-11: `p03`, `s14`.
- F-6: `m06`–`m08`, `s06`; the pasted value reads `●●●●●●●● secret · set · ends ECHO`.
- F-8 and F-9: `m02` shows `! 3 need attention` and `MCP servers !1`. After `D D`, `m11`
  shows the list without `fakesrv`, the toast `Deleted fakesrv`, `! 2`, and a DB count of 0,
  with no Ctrl-R.
- F-2: `u09`. `Max concurrent agents` went 6 → 7, then 9 was written straight into the sandbox
  DB. `u` showed `! changed while you edited … Enter keep yours (6) · Esc take theirs (9)`, and
  the DB kept 9.
- G22: `s15`. G24: `a01` → `a02` (80×24, NO_COLOR, ASCII). G25: `a04`, `a05`.

The only real network call was the first session's tavily MCP connect. Tavily was disabled in
the sandbox DB for the later sessions. The release copy in `/Users/zaali/.cache/p70cli/rel-c74/`
is the G25 build that was checked live, and `_build/prod` was removed before the final precommit.

Final checks at G25 (442b78e), with `_build/prod` removed first:

- `mise exec -- mix precommit`: core 194 tests, daemon 1 240 tests, and CLI 10 properties and
  2 418 tests, all with 0 failures. Provenance verify, `provenance.sync --check`, the schema
  snapshot (12 Python tests) and the unicode-width attestation all pass. The run exited 0.
- `scripts/dev/check_terminal_port.sh`: 58 Rust tests pass, and it verified 58 locked crate
  records and 108 license texts.
- `mix swarm_code.keymap --check`: `docs/keybindings.md matches the binding table`.
- Running `mix test` inside `apps/swarm_code_cli` alone gives 26 failures, all from the
  environment. `:public_key`, `SwarmCode.Domain.Repo` and the daemon's test support are not on a
  single app's code path. The same tests pass in the umbrella run above.

## QA #2 and the polish (G27–G40)

QA #2 (`/Users/zaali/.cache/c74/Q2/qa.md`) reported two P0s (P0-1, P0-2), seven P1s (P1-1 to
P1-7) and twelve P2s (P2-1 to P2-12). Each fix has a regression test in `c74_qa2_test.exs`, which
drives the reducer against `Fake.Settings`. The undo and conflict fixes are also tested in the
daemon's `c74_qa2_e2e_test.exs`. That test drives the terminal's reducer and sections against the
real service, over its socket, on the Appendix A database. It found the price CAS and the three
undos listed after the table, which the fake had let through. Each new test failed without its
fix. `Fake.Settings` now takes a `strict_expected` seed option: with it, the fake refuses a
command without `expected`, as the service does.

The subjects of G28, G33 and G35 number some P2s one off from the report. G28's "P2-7" is P2-8.
G33's "P2-4, P2-5, P2-9, P2-11" are P2-5, P2-6, P2-10, P2-2. G35's "P2-2" is P2-4. The table,
the tests and the code comments use the report's numbers; G37 renumbered the tests and comments.

| Finding | Result | Commit |
| --- | --- | --- |
| P0-1 the model picker was never drawn | fixed: the picker draws as F4's box under its row. The border holds the title and the provider and model counts. Inside are the filter, the column names, the provider groups, a window around the focused row (`… N more, type to filter`), the keys and `N of M`. The box moves up when it does not fit below the row. Tested at 160 and 80 columns | G27 ae6add0 |
| P0-2 a fresh session offered only the null choice, so Enter erased the model | fixed: the picker asks for its options each time it opens, and Enter waits while they load. The sandbox then found a second cause: the options came in one page of 100, and llmotions alone has 142 models, so a later provider (stubprov) was never offered. The picker now reads page after page to the end, up to 50 pages, and a page read again drops the older chain's next page | G27 ae6add0, G36 aa4fab7 |
| P1-1 a model value showed its provider's UUID | fixed: a value names its provider by name, or `unnamed provider` | G27 ae6add0 |
| P1-2 undo of a search-engine move: `expected is missing for order` | fixed: the undo expects the order the move left (the neighbour swap of `Search.move/2`) | G29 dda44df, G29b eaabf81 |
| P1-3 a record field changed elsewhere dropped the user's value | fixed: the row keeps yours as §3.7.9 draws it: `! changed while you edited (…): now <theirs>` and `Enter keep yours (<yours>) · Esc take theirs (<theirs>)`. Enter writes yours again, expecting theirs; Esc takes theirs | G32 4f4aa90 |
| P1-4 an MCP tool switch threw the focus to the top | fixed: the cursor keeps its row while a load is in flight, or while the page's loads have not all been answered | G30 a1c170b |
| P1-5 undo of `N`/`A` on MCP tools: `expected is missing for disabled_tools` | fixed: the undo expects the disabled list the switch left | G29 dda44df |
| P1-6 `▸ Test it first` on a new server showed nothing | fixed: the row shows the draft's `mcp.test` task as it runs, then `✓ connected · N tools: a, b, c` or the failure. Enter and `t` both start it | G31 b24c37a |
| P1-7 after a secret variable, no other variable could be saved | fixed. The root cause: the service's env entries decode with an atom `secret` key, but `IntegrationRows.field/2` reads string keys, and `secret` was missing from its atom map. So the stored secret read as plain, and the staged list sent its masked value. The secret is now staged as `keep` | G28 31b55d5 |
| P2-1 the enum editor cut its choices (Firecrawl hidden) | fixed: when the choices do not fit, the editor draws a `‹ … Jina Reader … ›` window around the focused choice | G34 57d084e |
| P2-2 a new provider's Default model stayed `none` | fixed with P0-2: the picker offers the provider's models. The row reads `none · Enter picks one of its N models` | G27, G33 75fe1a8, G36 |
| P2-3 row tags run into long values | deferred with F-15. It needs the row layout that wraps a value under itself (§4.2) | — |
| P2-4 the search did not find records | fixed: opening the search loads the providers, the search engines and the MCP servers, and the query runs again as they arrive. A search engine's result is named by its label | G35 74ed02b |
| P2-5 ids in words (`Search & web › exa`, `pages through firecrawl`) | fixed: `Search & web › Exa`, and the Overview's `Exa first` and `pages through Firecrawl` | G33 75fe1a8 (test in G37) |
| P2-6 Key bindings: `2 match`, fixed bindings without keys, vim first | fixed. The filter says `1 match` / `2 matches` (G33). The binding labelled `Ctrl-C` was taken for its own name column, which shifted the table and dropped the keys column; the name is now the first column (G37). A table's name is the first cell that reads as the label, so `Up` (key name `Up`) keeps its key-name column last in importance (G38). Under the standard keymap the vim group is listed last (G37) | G33, G37 22bf770, G38 19a9030 |
| P2-7 the keys sheet lacked §4.3's `←→ step` and split the change group | partly fixed: the first clause of ← and → now reads `Back to the rail or step down` and `Open the section or step up`, and `docs/keybindings.md` was regenerated. Deferred: the change group has 29 entries, more than a 45-row column holds; keeping it together needs a different sheet layout | G39 17fb1e3 |
| P2-8 the env paste did not name the variable; a saved secret drew as pending | fixed: `FAKE_TOKEN · paste the value · Cmd-V`. The saved secret keeps `secret · set · ends …` | G28 31b55d5 |
| P2-9 ASCII `>  > Add…`, `✓` as `v` | no change. The spec's ASCII twins are ▌→`>`, ▸→`>`, ✓→`v` (§4.11, T§15.2) | — |
| P2-10 after `Fetch every provider's models` the row said `not fetched this session` | fixed: after a finished `provider.fetch_all` the row says `fetched this session HH:MM` | G33 75fe1a8 |
| P2-11 the rail counted records only after a visit; no storage glance | fixed: the rail falls back to the Overview's glance counts. The storage glance reads the service's keys: `214 sessions · never cleaned up · deletes sessions after 90 days` | G33 75fe1a8 |
| P2-12 `:goto` Providers focused `▸ Add a provider…` | fixed: the cursor waits for the page's records, then lands on the first record | G33 75fe1a8 |

The daemon e2e test found four defects QA did not report. All four are fixed in G29 dda44df:

- The price CAS compared rows that still carried nil keys, while the service stores a row
  without them. Every edit of a row without cache rates was a conflict.
- A rename sent `row` and `rename_row` the wrong way round.
- Three undos were refused: an applied MCP connection change, saved effort levels, and applied
  models. Each now reads its `expected` from the record in the answer.

G38 was found in the sandbox after G37. G40 was found by the first final precommit: A31's
rail check now drops the record count (`Providers 4`) that the rail shows since G33.

The live check used the sandbox home `/Users/zaali/.cache/c74/F/polish2/sb` and a loopback
models stub (127.0.0.1:18743, three `GET /v1/models`). The release was built at G27, G36, G37,
G38 and G39. Sessions g2a–g2f (160×45) were rendered with `vt.py`/`svg2png.py` into
`sb/shots/`, and the PNGs were read. The shots show:

- P0-1: `a02`/`a03` (the Chat model box). Those shots also found the 100-option page behind
  G36: the box counted `1 provider · 100 models`.
- P0-2/P2-2: `b14`, before G36: stubprov's picker read `0 providers · 0 models`. At G36, `c01`
  reads `2 providers · 144 models` and `c05` reads `1 provider · 2 models` with stub-a and
  stub-b. Enter on stub-a gave `✓ Default model → stub-a` (`c06`), and the sandbox DB changed.
  Enter on the null choice before the options loaded left the DB unchanged.
- P1-1: `c02`: `deepseek-v4-pro · llmotions`, with no UUID on the page.
- P2-11: `b01`: `Providers 1` and `MCP servers 1` on the rail before either section was opened.
- P1-2: Exa `J` gave the order tavily, brave, exa; `u` gave tavily, exa, brave with `✓ Undid:
  Moved Exa below Brave`; `U` redid it (`c11`–`c13`, DB checked each time).
- P2-5: `c14`: `Search & web › Exa`. P2-1: `c19`/`c20`: `‹ Plain fetch (strip HTML) … ›`, then
  `‹ … Jina Reader … ›`.
- P1-3: while the Base URL was being edited, `https://theirs.example` was written straight into
  the DB. Enter on `https://mine.example` drew the conflict row (`c16`), and a second Enter wrote
  mine (`c17`, DB `https://mine.example`).
- P1-4 and P1-5: Space on `beta` kept the cursor on `beta` (`c25`). `N` turned all three tools
  off, and `u` restored `["beta"]` with the cursor still on `beta` (`c26`, `c27`).
- P1-7 and P2-8: `FAKE_TOKEN=` showed `FAKE_TOKEN · paste the value · Cmd-V` (`c29`). After the
  paste, `MODE=fast` was staged, then Esc and `s`. The DB then held both variables, and the
  server output read `token len 23` (`c38`, `c39`).
- P1-6: `c46`: `✓ connected · 3 tools: alpha, beta, gamma`. The draft was then discarded with
  `d`, and no server was created.
- P2-6 at G38: `e03` (the settings group, no key-name column) and `e04` (`/ctrl-c`: `Interrupt
  Ctrl-C` and `Ctrl-C  Ctrl-C`). The vim group is last (`e02`).
- P2-7 at G39: `f01`, the keys sheet.

Budget: no real prompts and no real provider or network calls. The only network traffic was the
three loopback stub requests. Screen sessions g2a–g2f were closed. The stub (its own pid) was
killed, and no `mcpfake.py` or sandbox process is left. The release copy in
`/Users/zaali/.cache/p70cli/rel-c74/` is now the G39 build that was checked live (`f01`),
replacing the G25 copy. `_build/prod` was removed before the final precommit.

Final checks at G40 (f574b59), with `_build/prod` removed first. G40 changes only a test, so the
G39 release copy matches it:

- `mise exec -- mix precommit` (the third run): core 194 tests, daemon 1 247 tests, and CLI 10
  properties and 2 452 tests, all with 0 failures. Provenance verify, `provenance.sync --check`,
  the schema snapshot (12 Python tests) and the unicode-width attestation (31 730 pairs) all
  pass. The run exited 0.
- The first run failed A31, which G40 fixed. The second run failed one timing assertion:
  `daemon_test.exs:368` ("closed within 100 ms"). That test passed alone three times in a row,
  and nothing in G27–G40 touches the data source. The third run was clean.
- `scripts/dev/check_terminal_port.sh`: 58 Rust tests pass, and it verified 58 locked crate
  records and 108 license texts.
- `mix swarm_code.keymap --check`: `docs/keybindings.md matches the binding table`. G39 had
  regenerated the file with `--write`.

## What is open

- QA #1 and QA #2 ran, and the two polishes above answer them.
- Deferred from QA #2: P2-3 (with F-15) and the column split of P2-7's change group (see the
  table). The model picker reads at most 50 pages (5 000 options).
- A record conflict's origin reads `elsewhere in this session` even for a change another process
  made. This is the same `Commit.outcome/4` origin noted below for value conflicts. Its two lines
  are cut at the page column's width. The status row repeats `Enter keeps yours · Esc takes
  theirs` in full.
- An empty Key bindings filter says `Nothing here yet.`, not `nothing matches`. QA did not report
  it.
- Deferred from QA #1: F-13's Overview header context, F-15's wrapping of values under
  themselves, and F-21's lease directory (see the table). F-13's `‹ … ›` segmented editor came
  with G34 (QA #2 P2-1).
- A value conflict row keeps the row's old value (`7` in `u09`) until Ctrl-R. Its origin always
  reads `elsewhere in this session`, even for a change from another process. This existed before
  the pass (`Commit.outcome/4`), and QA #1 did not report it.
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
